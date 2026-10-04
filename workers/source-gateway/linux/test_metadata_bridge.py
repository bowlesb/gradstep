"""Actual pipes/journal with explicitly simulated database and Linux observations."""
import copy
import os
import struct
import subprocess
import sys
import threading
import types
import unittest
from unittest.mock import patch

sys.modules.setdefault('frozen_context', types.ModuleType('frozen_context'))
import metadata_bridge as bridge
import metadata_host
import owned_session
import test_metadata_settlement as fixture
from protocol import Refused, clock_ns


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
