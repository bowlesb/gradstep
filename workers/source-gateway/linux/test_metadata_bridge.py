"""Actual pipes/journal with explicitly simulated database and Linux observations."""
import copy
from contextlib import ExitStack, redirect_stdout
import io
import os
import struct
import subprocess
import sys
import threading
import types
import unittest
from unittest.mock import Mock, patch
import uuid

sys.modules.setdefault('frozen_context', types.ModuleType('frozen_context'))
import metadata_bridge as bridge
import metadata_host
import owned_session
import test_metadata_settlement as fixture
from protocol import Refused, clock_ns
from common import canonical, decode


class Database:
    """No SQL/permission evidence: enforces the finite two-capability exchange."""
    def __init__(self, case):
        self.case = case
        self.job = {'id': case.kernel.job, 'kind': 'lookup', 'stage': 'atom', 'source_id': '1706.03762',
                    'requested_revision': 1, 'source_revision': None, 'metadata_id': None,
                    'status': 'queued', 'claim_id': None, 'generation': 0}
        self.granted = False
        self.calls = []
        self.finished = None
        self.outcome = 'perform_stage'
        self.lose_grant = False
        self.late_grant = False
        self.lose_result = False

    def state(self):
        return copy.deepcopy({'job': self.job, 'execution': self.case.observer.execution if self.granted else None,
                              'step_result': self.finished})

    def rpc(self, capability):
        return types.SimpleNamespace(capability=capability, call=lambda name, args: self.call(capability, name, args))

    def call(self, capability, name, args):
        self.calls.append((capability, name, copy.deepcopy(args)))
        if name == 'worker_metadata_execution_state':
            return self.state()
        if name == 'worker_metadata_authority_state':
            return copy.deepcopy(self.case.kernel.authority)
        if name == 'worker_claim_metadata_stage_v2':
            if capability != 'executor' or self.granted:
                raise ValueError('grant_capability_or_replay')
            if self.outcome != 'perform_stage':
                reply = {'granted': False, 'action': self.outcome, 'job': copy.deepcopy(self.job)}
                if self.outcome == 'wait':
                    reply.update(reason='cooldown', next_allowed_at=None)
                return reply
            if not self.late_grant:
                self.commit_grant()
            if self.lose_grant:
                raise Refused('rpc_ack_unknown')
            return {'granted': True, 'action': 'perform_stage', 'job': copy.deepcopy(self.job),
                    'execution': copy.deepcopy(self.case.observer.execution)}
        if name == 'worker_record_metadata_quiescence':
            if capability != 'observer':
                raise ValueError('receipt_capability')
            return self.case.observer.call(name, args)
        if name in ('worker_finish_metadata_stage_v2', 'worker_fail_metadata_stage_v2'):
            if capability != 'executor' or self.case.observer.execution['pending_resources']:
                raise ValueError('result_capability_or_resources')
            if self.finished is not None and self.finished != args:
                raise ValueError('changed_result')
            self.finished = copy.deepcopy(args)
            self.job['status'] = 'complete' if name == 'worker_finish_metadata_stage_v2' else 'failed'
            if self.lose_result:
                self.lose_result = False
                raise Refused('rpc_ack_unknown')
            return copy.deepcopy(self.job)
        raise ValueError('unexpected_rpc')

    def commit_grant(self):
        self.granted = True
        self.job.update(status='leased', claim_id=self.case.kernel.claim, generation=1)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.case = fixture.SettlementTests()
        self.case.setUp()
        c, k = self.case, self.case.kernel
        self.db = Database(c)
        self.fetches = 0
        self.parses = 0
        self.parsed = {'schema_version': 1, 'kind': 'result', 'body_sha256': '',
                       'result': {'revision': 1, 'metadata': {'title': 'A paper'}}}
        self.action = types.SimpleNamespace(journal=c.action, scope=k.scope, capture=k.capture,
                binding=k.binding, ready=k.ready, manifest=k.manifest, boot=k.boot, claim=k.claim, service=k.service)
        for name in ('release', 'retire', 'fence', 'fence_value'):
            setattr(self.action, name, types.MethodType(getattr(metadata_host.HostAction, name), self.action))
        def prepare(job, request, source, authority):
            self.assertEqual(request, k.request)
            self.action.fence()
            return k.binding
        self.action.prepare, self.action.restore = prepare, lambda: None
        k.service_state.update(ActiveState='active', MainPID='400', InvocationID=k.ready['invocation_id'])
        k.group['populated'] = 1
        self.config = {'mode': 'run', 'job_id': k.job, 'claim_id': k.claim, 'fixture': {}}
        self.actual_put = c.action.put
        def put(name, value, **options):
            self.actual_put(name, value, **options)
            if name == 'go.json' and k.group['populated'] == 1:
                self.fetches += 1
                report = c.witness()
                self.parsed['body_sha256'] = report['result']['body_sha256']
        self.writer = patch.object(c.action, 'put', side_effect=put)
        self.writer.start()
        self.control = patch.object(metadata_host.lifecycle, 'run', side_effect=lambda argv: k.stop())
        self.control.start()
        self.authority = patch.object(metadata_host, 'authority_matches')
        self.authority.start()

    def tearDown(self):
        self.writer.stop()
        self.control.stop()
        self.authority.stop()
        self.case.tearDown()

    def pipeline(self, *, recover=False):
        config = dict(self.config, mode='recover' if recover else 'run')
        parent_in, child_out = os.pipe()
        child_in, parent_out = os.pipe()
        parent = bridge.Channel(parent_in, parent_out, lifetime=5)
        child = bridge.Channel(child_in, child_out, lifetime=5)
        errors = []
        def parse(value):
            self.parses += 1
            self.assertEqual(value['body_sha256'], self.parsed['body_sha256'])
            return copy.deepcopy(self.parsed)
        def run():
            try:
                bridge.executor(child, self.db.rpc('executor'), parser=parse)
            except BaseException as error:
                errors.append(error)
            finally:
                os.close(child_in)
                os.close(child_out)
        thread = threading.Thread(target=run)
        thread.start()
        try:
            result = bridge.guardian(parent, self.db.rpc('observer'), self.action, config)
        finally:
            os.close(parent_in)
            os.close(parent_out)
            thread.join(6)
        self.assertFalse(thread.is_alive())
        if errors:
            raise errors[0]
        return result

    def test_normal_exchange_fetches_once_and_recovers_exact_result(self):
        self.assertEqual(self.pipeline()['state'], 'completed')
        original = self.case.action.read('result.json')
        self.assertEqual(self.pipeline(recover=True)['state'], 'completed')
        self.assertEqual(self.case.action.read('result.json'), original)
        self.assertEqual((self.fetches, self.parses), (1, 1))
        self.assertEqual(sum(name == 'worker_claim_metadata_stage_v2' for _, name, _ in self.db.calls), 1)

    def test_lost_result_ack_reuses_result_without_fetch_or_parse(self):
        self.db.lose_result = True
        self.assertEqual(self.pipeline()['state'], 'result_ack_unknown')
        saved = self.case.action.read('result.json')
        self.assertEqual(self.pipeline(recover=True)['state'], 'completed')
        self.assertEqual(self.case.action.read('result.json'), saved)
        self.assertEqual((self.fetches, self.parses), (1, 1))

    def test_known_non_grant_retires_and_converges_without_receipts(self):
        self.db.outcome = 'wait'
        self.assertEqual(self.pipeline()['state'], 'wait')
        self.assertEqual(self.pipeline(recover=True)['state'], 'wait')
        self.assertEqual((self.fetches, self.parses), (0, 0))
        self.assertFalse(any('quiescence' in name or 'finish' in name for _, name, _ in self.db.calls))
        self.assertEqual(sum(name == 'worker_claim_metadata_stage_v2' for _, name, _ in self.db.calls), 1)

    def test_other_known_non_grants_converge_and_unknown_actions_refuse(self):
        for outcome in ('disabled', 'terminal', 'no_interest', 'unreviewed'):
            with self.subTest(outcome=outcome):
                case = BridgeTests()
                case.setUp()
                try:
                    case.db.outcome = outcome
                    if outcome == 'unreviewed':
                        with self.assertRaisesRegex(ValueError, 'invalid_grant_checkpoint'):
                            case.pipeline()
                    else:
                        self.assertEqual(case.pipeline()['state'], outcome)
                        self.assertEqual(case.pipeline(recover=True)['state'], outcome)
                    self.assertEqual((case.fetches, case.parses), (0, 0))
                    self.assertFalse(any('quiescence' in name or 'finish' in name for _, name, _ in case.db.calls))
                finally:
                    case.tearDown()

    def test_go_publication_failures_retire_before_same_inode_repair(self):
        for name in ('go-intent.json', 'go.json'):
            for boundary in ('checkpoint_fsynced', 'checkpoint_linked', 'checkpoint_directory_fsynced'):
                with self.subTest(name=name, boundary=boundary):
                    case = BridgeTests()
                    case.setUp()
                    try:
                        original = case.case.action.put
                        def stop(event):
                            if event == boundary:
                                # A final GO can already have been consumed.
                                if name == 'go.json' and event != 'checkpoint_fsynced':
                                    case.fetches += 1
                                    report = case.case.witness()
                                    case.parsed['body_sha256'] = report['result']['body_sha256']
                                raise OSError('GO publication interrupted')
                        def publish(record, value, **options):
                            return original(record, value, hook=stop if record == name else None)
                        with patch.object(case.case.action, 'put', side_effect=publish), self.assertRaises(OSError):
                            case.pipeline()
                        # The fence predated the grant, so a pending control
                        # does not block stop/empty observation. No promotion yet.
                        case.action.retire()
                        self.assertEqual(case.case.kernel.group['populated'], 0)
                        directory = case.case.layout['control' if name == 'go.json' else 'records']
                        pending = directory / ('.pending-' + name)
                        original_bytes, inode = pending.read_bytes(), pending.stat().st_ino
                        before = case.fetches
                        self.assertEqual(case.pipeline(recover=True)['state'], 'completed')
                        final = directory / name
                        self.assertEqual((final.read_bytes(), final.stat().st_ino), (original_bytes, inode))
                        self.assertFalse(pending.exists())
                        self.assertEqual(case.fetches, before)
                        self.assertEqual(sum(rpc == 'worker_claim_metadata_stage_v2' for _, rpc, _ in case.db.calls), 1)
                    finally:
                        case.tearDown()

    def test_lost_grant_ack_never_goes_and_scope_only_recovery_never_parses(self):
        self.db.lose_grant = True
        self.assertEqual(self.pipeline()['state'], 'completed')
        self.assertEqual(self.pipeline(recover=True)['state'], 'completed')
        self.assertEqual((self.fetches, self.parses), (0, 0))
        self.assertEqual(self.case.action.read('result.json')['name'], 'worker_fail_metadata_stage_v2')
        self.assertTrue(all(row['evidence_kind'] == 'owned_scope_retired_v1'
                            for row in self.case.observer.execution['receipts']))

    def test_null_state_after_lost_grant_can_later_settle_without_regrant(self):
        self.db.lose_grant = self.db.late_grant = True
        self.assertEqual(self.pipeline()['state'], 'grant_still_unknown')
        first = self.case.action.read('grant-status.json')
        self.assertIsNone(first['execution'])
        self.db.commit_grant()
        self.assertEqual(self.pipeline(recover=True)['state'], 'completed')
        self.assertEqual(self.case.action.read('grant-status.json'), first)
        self.assertEqual((self.fetches, self.parses), (0, 0))
        self.assertEqual(sum(name == 'worker_claim_metadata_stage_v2' for _, name, _ in self.db.calls), 1)

    def test_failed_permanent_fence_barrier_causes_zero_grant_calls(self):
        with patch.object(self.action, 'fence', side_effect=OSError('fence fsync failed')):
            with self.assertRaises(OSError):
                self.pipeline()
        self.assertFalse(any(name == 'worker_claim_metadata_stage_v2' for _, name, _ in self.db.calls))
        self.assertEqual(self.fetches, 0)

    def test_wrong_frame_length_fails_before_body_read(self):
        incoming, writer = os.pipe()
        reader, outgoing = os.pipe()
        try:
            os.write(writer, struct.pack('!I', bridge.LIMIT + 1))
            with self.assertRaisesRegex(ValueError, 'controller_frame_limit'):
                bridge.Channel(incoming, outgoing).receive(maximum=bridge.LIMIT)
        finally:
            for fd in (incoming, writer, reader, outgoing):
                os.close(fd)

    def test_controller_cleanup_timeout_does_not_resignal_after_anchor_loss(self):
        child = types.SimpleNamespace(pid=4242, returncode=None)
        with patch.object(bridge.os, 'waitid', return_value=object(), create=True), \
             patch.object(bridge.os, 'P_PID', 1, create=True), patch.object(bridge.os, 'WNOWAIT', 0x1000000, create=True), \
             patch.object(bridge.os, 'WEXITED', 4, create=True), patch.object(bridge.os, 'getpgid', return_value=4242), \
             patch.object(bridge.os, 'getsid', return_value=4242), patch.object(bridge.os, 'killpg') as kill, \
             patch.object(bridge.os, 'waitpid', return_value=(0, 0)), \
             patch.object(owned_session, 'controller_children', return_value=[4242]), \
             patch.object(owned_session, 'clock_ns', side_effect=[0, 0, 3_000_000_000]):
            with self.assertRaisesRegex(ValueError, 'controller_children_unresolved'):
                bridge.retire_controller(child, grace=0)
        kill.assert_called_once_with(4242, owned_session.signal.SIGKILL)
        self.assertIsNone(child.returncode)


class ObserverRecoveryTests(unittest.TestCase):
    """Real retained journal; kernel and capability RPCs remain simulated."""
    def setUp(self):
        self.base = BridgeTests()
        self.base.setUp()
        self.case, self.action, self.db = self.base.case, self.base.action, self.base.db
        self.action.restore = types.MethodType(metadata_host.HostAction.restore, self.action)
        self.action.open, self.action.close = Mock(), Mock()
        self.descriptor = {'schema_version': 1, 'mode': 'linux_metadata_fixture_db', 'instance': '123456789abc',
            'capability': 'observer', 'port': 54321, 'database': 'science_reader_linux_123456789abc',
            'login': 'ts_observer_123456789abc', 'psql_sha256': 'a' * 64, 'ca_sha256': 'b' * 64}
        self.config = {'job_id': self.case.kernel.job, 'claim_id': self.case.kernel.claim, 'observer': self.descriptor}
        self.guards = ExitStack()
        self.addCleanup(self.guards.close)
        self.guards.enter_context(patch.object(bridge.lifecycle, 'preflight'))
        self.constructor = self.guards.enter_context(patch.object(bridge, 'RestrictedRPC', return_value=self.db.rpc('observer')))
        self.host = self.guards.enter_context(patch.object(bridge, 'HostAction', return_value=self.action))
        self.guards.enter_context(patch.object(bridge.frozen_context, 'root', '/captured/fixture', create=True))
        self.guards.enter_context(patch.object(bridge.frozen_context, 'manifest', self.case.kernel.manifest, create=True))
        for name in ('subreaper', 'controller_children', 'retire_controller', 'executor', 'parse',
                     'parser_context', 'result_record', 'repair_controls'):
            self.guards.enter_context(patch.object(bridge, name, side_effect=AssertionError('forbidden observer path: ' + name)))
        self.guards.enter_context(patch.object(bridge.subprocess, 'Popen', side_effect=AssertionError('controller startup')))
        self.guards.enter_context(patch.object(self.action, 'prepare', side_effect=AssertionError('source prepare')))
        self.guards.enter_context(patch.object(self.action, 'release', side_effect=AssertionError('source GO')))

    def tearDown(self):
        self.guards.close()
        self.base.tearDown()

    def seed(self, *, granted=True, checkpoint=True, decline=None):
        intent = bridge.intent_value(copy.deepcopy(self.db.job), self.case.kernel.request, self.action.binding, clock_ns())
        self.action.journal.put('intent.json', intent)
        if granted:
            self.db.commit_grant()
        if checkpoint:
            answer = {'granted': granted, 'action': 'perform_stage' if granted else decline,
                      'job': copy.deepcopy(self.db.job)}
            if granted:
                answer['execution'] = copy.deepcopy(self.case.observer.execution)
            elif decline == 'wait':
                answer.update(reason='unsettled_execution', next_allowed_at=None)
            self.action.journal.put('grant.json', {'response': answer, 'before_rpc_ns': intent['before_rpc_ns']})

    def recover(self):
        result = bridge.observer_run(copy.deepcopy(self.config))
        self.action.open.assert_called_with(fresh=False)
        self.constructor.assert_called_with(self.descriptor)
        self.assertEqual(set(result), {'schema_version', 'kind', 'state', 'job_id', 'claim_id', 'execution_id',
                                      'source_network_enabled', 'hosted_admitted'})
        self.assertEqual((result['schema_version'], result['kind']), (1, 'metadata_resource_closure_v1'))
        self.assertEqual((result['job_id'], result['claim_id']), (self.config['job_id'], self.config['claim_id']))
        self.assertIs(result['source_network_enabled'], False)
        self.assertIs(result['hosted_admitted'], False)
        self.assertLessEqual(len(canonical(result)), 1024)
        self.assertTrue(all(capability == 'observer' and name in (
            'worker_metadata_execution_state', 'worker_record_metadata_quiescence') for capability, name, _ in self.db.calls))
        self.assertEqual((self.base.fetches, self.base.parses), (0, 0))
        self.assertFalse(self.action.journal.exists('go.json'))
        for name in ('parser-input.json', 'parser-output.json', 'result.json', 'result-ack.json'):
            self.assertFalse(self.action.journal.exists(name))
        return result

    def test_exact_config_rejects_other_capabilities_and_extra_authority(self):
        for key in ('executor', 'fixture', 'mode'):
            with self.subTest(extra=key), self.assertRaisesRegex(ValueError, 'invalid_observer_configuration'):
                bridge.observer_run(dict(self.config, **{key: 'not admitted'}))
        for capability in ('executor', 'admitter'):
            descriptor = dict(self.descriptor, capability=capability, login='ts_' + capability + '_123456789abc')
            with self.subTest(capability=capability), self.assertRaisesRegex(ValueError, 'observer_required'):
                bridge.observer_run(dict(self.config, observer=descriptor))
        self.host.assert_not_called()
        self.constructor.assert_not_called()

    def test_known_execution_scope_only_replay_retains_original_receipt_ids(self):
        self.seed()
        retained = {name: self.action.journal.read(name) for name in ('intent.json', 'grant.json')}
        first = self.recover()
        self.assertEqual(first['state'], 'settled')
        self.assertEqual(first['execution_id'], self.case.execution['id'])
        receipts = copy.deepcopy(self.case.observer.calls)
        self.assertEqual([row['p_resource'] for row in receipts], ['executor', 'arxiv_connection'])
        self.assertTrue(all(row['p_evidence_kind'] == 'owned_scope_retired_v1' for row in receipts))
        source = receipts[1]['p_facts']
        self.assertEqual(source['framing'], 'unknown')
        self.assertIs(source['peer_eof'], False)
        self.assertIsNone(source['actual_bytes'])
        self.assertIsNone(source['body_sha256'])
        acks = {name: self.action.journal.read(name) for name in ('executor-ack.json', 'arxiv_connection-ack.json')}
        self.assertEqual(self.recover(), first)
        self.assertEqual(self.case.observer.calls, receipts + receipts)
        self.assertEqual(len(self.case.observer.execution['receipts']), 2)
        for name, value in dict(retained, **acks).items():
            self.assertEqual(self.action.journal.read(name), value)
        self.assertIsNone(self.db.finished)  # Resource success does not finalize the step.
        self.assertEqual(self.action.close.call_count, 2)

    def test_null_then_late_commit_keeps_first_status_without_grant_or_go(self):
        self.seed(granted=False, checkpoint=False)
        first = self.recover()
        self.assertEqual((first['state'], first['execution_id']), ('grant_still_unknown', None))
        status = self.action.journal.read('grant-status.json')
        self.assertIsNone(status['execution'])
        self.assertEqual(self.case.observer.calls, [])
        self.assertEqual(self.recover(), first)
        self.db.commit_grant()
        self.assertEqual(self.recover()['state'], 'settled')
        self.assertEqual(self.action.journal.read('grant-status.json'), status)
        self.assertFalse(self.action.journal.exists('grant.json'))
        self.assertEqual(len(self.case.observer.execution['receipts']), 2)

    def test_positive_saved_grant_with_null_current_state_stays_unknown(self):
        self.seed()
        grant = self.action.journal.read('grant.json')
        self.db.granted = False
        result = self.recover()
        self.assertEqual((result['state'], result['execution_id']), ('grant_still_unknown', None))
        self.assertEqual(self.action.journal.read('grant.json'), grant)
        self.assertEqual(self.case.observer.calls, [])

    def test_lost_receipt_ack_replays_original_body_and_id(self):
        self.seed()
        self.case.observer.lose_ack = 'executor'
        with self.assertRaises(Refused):
            self.recover()
        original = self.action.journal.read('executor.json')
        self.assertFalse(self.action.journal.exists('executor-ack.json'))
        self.assertEqual(self.recover()['state'], 'settled')
        self.assertEqual(self.action.journal.read('executor.json'), original)
        self.assertEqual(self.case.observer.calls[0], self.case.observer.calls[1])
        self.assertEqual(len(self.case.observer.execution['receipts']), 2)

    def test_retained_complete_body_is_validated_but_never_exposed_or_parsed(self):
        self.seed()
        report = self.case.witness()
        result = self.recover()
        self.assertEqual(result['state'], 'settled')
        self.assertNotIn(report['result']['body_base64'], canonical(result).decode())
        self.assertTrue(all(row['evidence_kind'] == 'owned_child_joined'
                            for row in self.case.observer.execution['receipts']))
        self.assertEqual(self.case.observer.execution['receipts'][1]['facts']['body_sha256'],
                         report['result']['body_sha256'])

    def test_known_non_grant_requires_retired_scope_and_issues_no_receipts(self):
        self.seed(granted=False, decline='wait')
        with patch.object(self.action, 'retire', return_value=False):
            self.assertEqual(self.recover()['state'], 'grant_still_unknown')
        self.assertEqual(self.recover()['state'], 'wait')
        self.assertEqual(self.case.observer.calls, [])

    def test_failed_stop_leaves_all_holds_without_receipts(self):
        self.seed()
        with patch.object(self.action, 'retire', return_value=False):
            self.assertEqual(self.recover()['state'], 'scope_unresolved')
        self.assertEqual(self.case.observer.execution['pending_resources'], ['arxiv_connection', 'executor'])
        self.assertEqual(self.case.observer.calls, [])

    def test_saved_execution_identity_conflict_refuses_resource_receipts(self):
        self.seed()
        saved = self.db.state()
        saved['execution']['id'] = str(uuid.uuid4())
        self.action.journal.put('grant-status.json', saved)
        with self.assertRaisesRegex(ValueError, 'execution_checkpoint_conflict'):
            self.recover()
        self.assertEqual(self.case.observer.calls, [])
        self.assertEqual(self.action.journal.read('grant-status.json'), saved)

    def test_saved_grant_generation_conflict_refuses_resource_receipts(self):
        self.seed()
        self.case.observer.execution['generation'] += 1
        with self.assertRaisesRegex(ValueError, 'execution_checkpoint_conflict'):
            self.recover()
        self.assertEqual(self.case.observer.calls, [])

    def test_malformed_current_execution_fails_before_retirement_or_receipts(self):
        self.seed()
        self.case.observer.execution['id'] = 7
        with patch.object(self.action, 'retire') as retire, self.assertRaisesRegex(ValueError, 'invalid_execution_state'):
            self.recover()
        retire.assert_not_called()
        self.assertEqual(self.case.observer.calls, [])

    def test_missing_intent_and_changed_boot_fail_before_retirement_or_rpc(self):
        with patch.object(self.action, 'retire') as retire:
            with self.assertRaisesRegex(ValueError, 'missing_grant_intent'):
                self.recover()
            self.seed()
            self.action.boot = str(uuid.uuid4())
            with self.assertRaisesRegex(ValueError, 'changed_boot_requires_review'):
                self.recover()
        retire.assert_not_called()
        self.assertEqual(self.db.calls, [])
        self.assertEqual(self.action.close.call_count, 2)

    def test_pending_go_is_never_promoted_to_make_room_for_receipts(self):
        self.seed()
        k = self.case.kernel
        go = {'schema_version': 1, 'kind': 'linux_metadata_go_v1', 'scope_id': k.claim,
              **{key: k.ready[key] for key in ('child_id', 'bundle_sha256', 'source_sha256')},
              'execution_id': self.case.execution['id'], 'deadline_ns': str(clock_ns() + 30_000_000_000)}
        def interrupt(event):
            if event == 'checkpoint_fsynced':
                raise OSError('publication interrupted')
        with self.assertRaises(OSError):
            self.base.actual_put('go.json', go, hook=interrupt)
        pending = self.case.layout['control'] / '.pending-go.json'
        raw, inode = pending.read_bytes(), pending.stat().st_ino
        with self.assertRaisesRegex(ValueError, 'unfinished_action_record'):
            self.recover()
        self.assertEqual((pending.read_bytes(), pending.stat().st_ino), (raw, inode))
        self.assertFalse((self.case.layout['control'] / 'go.json').exists())
        self.assertEqual(self.case.observer.calls, [])
        self.assertEqual([name for _, name, _ in self.db.calls], ['worker_metadata_execution_state'])

    def test_main_bounds_input_and_redacts_failures(self):
        self.seed()
        for raw in (b'x' * (bridge.OBSERVER_INPUT_LIMIT + 1), b'{"observer":"secret fixture path"}',
                    b'[]', b'[' * 1500 + b']' * 1500):
            output = io.StringIO()
            with patch.object(bridge.sys, 'argv', ['bootstrap.py', '/captured', 'metadata_observer']), \
                 patch.object(bridge.sys, 'stdin', types.SimpleNamespace(buffer=io.BytesIO(raw))), redirect_stdout(output):
                self.assertEqual(bridge.observer_main(), 2)
            self.assertEqual(decode(output.getvalue().encode()), {'schema_version': 1,
                'kind': 'metadata_resource_closure_v1', 'state': 'reconcile_required',
                'source_network_enabled': False, 'hosted_admitted': False})
        self.host.assert_not_called()
        output = io.StringIO()
        with patch.object(bridge.sys, 'argv', ['bootstrap.py', '/captured', 'metadata_observer']), \
             patch.object(bridge.sys, 'stdin', types.SimpleNamespace(buffer=io.BytesIO(canonical(self.config)))), \
             redirect_stdout(output):
            self.assertEqual(bridge.observer_main(), 0)
        self.assertEqual(decode(output.getvalue().encode())['state'], 'settled')


@unittest.skipUnless(sys.platform == 'linux' and os.environ.get('TIMESTEP_LINUX_FIXTURE_RUN') == '1',
                     'requires opt-in inside the isolated Linux guest')
class ControllerSessionTests(unittest.TestCase):
    def test_normal_or_killed_controller_cannot_leave_live_grandchild(self):
        script = '''
import os,signal,subprocess,sys,types
sys.modules['frozen_context']=types.ModuleType('frozen_context')
import metadata_bridge as bridge
bridge.subreaper(True)
program="import os,time\\npid=os.fork()\\nif pid==0: time.sleep(60); os._exit(0)\\nprint(pid,flush=True)\\n"+("time.sleep(60)" if sys.argv[1]=='kill' else "os._exit(0)")
p=subprocess.Popen([sys.executable,'-B','-c',program],stdout=subprocess.PIPE,start_new_session=True)
grand=int(p.stdout.readline(32))
if sys.argv[1]=='kill': os.kill(p.pid,signal.SIGKILL)
code=bridge.retire_controller(p)
assert code==(-9 if sys.argv[1]=='kill' else 0)
assert not bridge.controller_children()
try: os.kill(grand,0)
except ProcessLookupError: pass
else: raise AssertionError('live grandchild')
bridge.subreaper(False)
print('retired')
'''
        for mode in ('normal', 'kill'):
            with self.subTest(mode=mode):
                result = subprocess.run([sys.executable, '-B', '-c', script, mode], capture_output=True,
                        timeout=8, env={'PATH': '/usr/bin:/bin', 'PYTHONPATH': os.environ['PYTHONPATH']})
                self.assertEqual(result.returncode, 0, result.stderr[:2048])
                self.assertEqual(result.stdout, b'retired\n')


if __name__ == '__main__':
    unittest.main()
