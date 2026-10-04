"""Real journal/receipt replay with simulated database and kernel observations."""
import base64
import copy
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

from common import canonical
from protocol import Refused, digest, target
from action_journal import ActionJournal, PENDING
import metadata_settlement as settlement
import witness_slots
import test_metadata_scope as scope_fixture


class SimulatedObserver:
    capability = 'observer'

    def __init__(self, execution):
        self.execution = copy.deepcopy(execution)
        self.calls = []
        self.lose_ack = None

    def call(self, name, args):
        if name != 'worker_record_metadata_quiescence':
            raise ValueError('unexpected_observer_rpc')
        self.calls.append(copy.deepcopy(args))
        resource = args['p_resource']
        prior = settlement.accepted(self.execution, resource)
        if prior is None:
            if resource == 'arxiv_connection' and settlement.accepted(self.execution, 'executor') is None:
                raise ValueError('connection_before_executor')
            prior = {'resource': resource, 'receipt_id': args['p_receipt_id'], 'evidence_kind': args['p_evidence_kind'],
                     'facts': copy.deepcopy(args['p_facts']), 'accepted_at': '2026-10-04T12:00:00Z'}
            self.execution['receipts'].append(prior)
            self.execution['pending_resources'].remove(resource)
            replayed = False
        else:
            if prior['evidence_kind'] != args['p_evidence_kind'] or prior['facts'] != args['p_facts']:
                raise ValueError('simulated_receipt_conflict')
            replayed = True
        if self.lose_ack == resource:
            self.lose_ack = None
            raise Refused('rpc_ack_unknown')
        return {'replayed': replayed, 'receipt_id': prior['receipt_id'], 'execution': copy.deepcopy(self.execution)}


class SettlementTests(unittest.TestCase):
    def setUp(self):
        # Reuse the explicit lifecycle observation simulation, not a SQL owner
        # connection. The real restricted PG17 sessions remain a separate gate.
        self.kernel = scope_fixture.MetadataScopeTests()
        self.kernel.setUp()
        k = self.kernel
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name).resolve()
        self.layout = {leaf: root / leaf for leaf in ('records', 'control', 'data', 'witness', 'ingress')}
        for leaf, path in self.layout.items():
            path.mkdir(mode=0o750 if leaf == 'control' else 0o700)
        unit_root = root / 'units'
        unit_root.mkdir(mode=0o755)
        self.units = {unit_root / name: raw for name, raw in k.render(k.claim).items()}
        for path, raw in self.units.items():
            path.write_bytes(raw)
            path.chmod(0o644)
        for name, value in (('ready.json', k.ready), ('privileges.json', {'checked': True})):
            path = self.layout['data'] / name
            path.write_bytes(canonical(value))
            path.chmod(0o600)
        self.execution = {'id': str(uuid.uuid4()), 'job_id': k.job, 'claim_id': k.claim,
            'generation': 1, 'kind': 'atom', 'epoch': k.binding['epoch'], 'policy_id': k.binding['policy_id'],
            'binding': copy.deepcopy(k.binding), 'binding_sha256': 'a' * 64, 'byte_ceiling': 1_048_576,
            'created_at': '2026-10-04T12:00:00Z', 'useful_deadline': '2026-10-04T12:00:30Z',
            'report_deadline': '2026-10-04T12:00:30Z', 'pending_resources': ['arxiv_connection', 'executor'], 'receipts': []}
        self.observer = SimulatedObserver(self.execution)
        k.stop()
        self.action = ActionJournal(self.layout, 262_144, self.units, owner_uid=os.getuid(), producer_uid=os.getuid(),
                                    owner_gid=os.getgid(), producer_gid=os.getgid())
        self.action.__enter__()
        self.action.put('capture.json', k.capture)
        self.action.put('stop-fence.json', k.fence)
        # The fixed production path is simulated; actual reads go through the
        # held ActionJournal's ownership, inventory and durability barriers.
        self.action.layout['records'] = k.scope.journal.layout['records']
        k.scope.journal = self.action

    def tearDown(self):
        self.action.__exit__(None, None, None)
        self.temp.cleanup()
        self.kernel.tearDown()

    def witness(self, *, retry_kind='absent', status=200):
        k = self.kernel
        body = b'<feed>fixture</feed>'
        result = {'schema_version': 1, 'mode': 'loopback_fixture_v1', 'attempt_id': k.binding['child_id'],
            'request_sha256': digest(canonical(k.request)), 'target': target(k.request), 'kind': 'complete', 'reason': None,
            'status': status, 'framing': 'content_length', 'framing_complete': True, 'tls_peer_close': 'not_observed',
            'body_base64': base64.b64encode(body).decode(), 'body_sha256': digest(body), 'body_bytes': len(body),
            'protocol_bytes_received': len(body) + 64, 'retry_after_seconds': 0, 'retry_after_kind': retry_kind,
            'local_cleanup': {'http_file_closed': True, 'socket_closed': True}, 'elapsed_ms': 5,
            'source_network_enabled': False}
        report = {'schema_version': 1, 'outcome': 'completed', 'identity': k.ready['identity'],
            'child_id': k.binding['child_id'], 'source_sha256': digest(canonical(k.request)), 'execution_id': self.execution['id'],
            'sent_go': True, 'returncode': 0, 'owned_process_retired': True, 'retirement_witness': 'parent_waitpid',
            'disposition': 'exited', 'result': result}
        witness_slots.publish_ingress(self.layout['ingress'], canonical(report))
        return report

    def settle(self):
        k = self.kernel
        return settlement.settle(self.action, self.observer, k.scope, copy.deepcopy(self.observer.execution),
                                 k.binding, k.capture, k.ready)

    def test_joined_body_receipts_are_ordered_and_allow_retained_body(self):
        report = self.witness()
        reply = self.settle()
        self.assertEqual(reply['state'], 'settled')
        self.assertEqual(reply['witness'], report)
        self.assertEqual([call['p_resource'] for call in self.observer.calls], ['executor', 'arxiv_connection'])
        self.assertTrue(all(call['p_evidence_kind'] == 'owned_child_joined' for call in self.observer.calls))
        self.assertEqual(self.observer.calls[1]['p_facts']['actual_bytes'], report['result']['body_bytes'])

    def test_missing_or_partial_body_uses_only_scope_evidence(self):
        pending = self.layout['ingress'] / witness_slots.PENDING
        pending.write_bytes(b'{partial')
        pending.chmod(0o600)
        reply = self.settle()
        self.assertEqual(reply['state'], 'settled')
        self.assertIsNone(reply['witness'])
        self.assertTrue(all(call['p_evidence_kind'] == 'owned_scope_retired_v1' for call in self.observer.calls))
        facts = self.observer.calls[1]['p_facts']
        self.assertEqual(facts['framing'], 'unknown')
        self.assertIs(facts['peer_eof'], False)
        self.assertIsNone(facts['actual_bytes'])
        self.assertIsNone(facts['body_sha256'])
        self.assertNotIn('disposition', facts)
        self.assertEqual(pending.read_bytes(), b'{partial')

    def test_first_ack_is_preserved_when_replay_snapshot_changes(self):
        self.witness()
        self.settle()
        old = self.action.read('executor-ack.json')
        self.assertFalse(old['replayed'])
        self.assertEqual(old['execution']['pending_resources'], ['arxiv_connection'])
        self.assertEqual(self.settle()['state'], 'settled')
        self.assertEqual(self.action.read('executor-ack.json'), old)
        self.assertEqual(self.observer.calls[0], self.observer.calls[2])
        self.assertEqual(self.observer.calls[1], self.observer.calls[3])

    def test_interrupted_publications_replay_original_content_and_inode(self):
        for name in ('observation.json', 'executor.json', 'executor-ack.json',
                     'arxiv_connection.json', 'arxiv_connection-ack.json'):
            for boundary in ('checkpoint_fsynced', 'checkpoint_linked', 'checkpoint_directory_fsynced'):
                with self.subTest(name=name, boundary=boundary):
                    case = SettlementTests()
                    case.setUp()
                    try:
                        case.witness()
                        original = case.action.put
                        def interrupt(event):
                            if event == boundary:
                                raise OSError('publication interrupted')
                        def put(record, value, **options):
                            return original(record, value, hook=interrupt if record == name else None)
                        with patch.object(case.action, 'put', side_effect=put), self.assertRaises(OSError):
                            case.settle()
                        pending = case.layout['records'] / (PENDING + name)
                        saved, inode = pending.read_bytes(), pending.stat().st_ino
                        fixed_path = case.action.layout['records']
                        case.action.__exit__(None, None, None)
                        case.action = ActionJournal(case.layout, 262_144, case.units,
                                owner_uid=os.getuid(), producer_uid=os.getuid(),
                                owner_gid=os.getgid(), producer_gid=os.getgid())
                        case.action.__enter__()
                        case.action.layout['records'] = fixed_path
                        case.kernel.scope.journal = case.action
                        self.assertEqual(case.settle()['state'], 'settled')
                        final = case.layout['records'] / name
                        self.assertEqual((final.read_bytes(), final.stat().st_ino), (saved, inode))
                        self.assertFalse(pending.exists())
                        for resource in ('executor', 'arxiv_connection'):
                            calls = [call for call in case.observer.calls if call['p_resource'] == resource]
                            self.assertTrue(all(call == calls[0] for call in calls))
                    finally:
                        case.tearDown()

    def test_scope_must_observe_the_same_held_journal(self):
        self.kernel.scope.journal = None
        with self.assertRaisesRegex(ValueError, 'scope_journal_mismatch'):
            self.settle()
        self.assertEqual(self.observer.calls, [])

    def test_matching_body_hash_does_not_replace_other_accepted_source_facts(self):
        for changed, value in (('status_code', 404), ('framing', 'chunked'), ('actual_bytes', 1),
                               ('retry_after_seconds', 42), ('peer_eof', True), ('disposition', 'killed'),
                               ('unsupported_retry_after', None)):
            with self.subTest(changed=changed):
                case = SettlementTests()
                case.setUp()
                try:
                    report = case.witness(retry_kind='unsupported' if changed == 'unsupported_retry_after' else 'absent')
                    facts = {'binding_sha256': case.execution['binding_sha256'], 'disposition': 'exited'}
                    case.observer.call('worker_record_metadata_quiescence',
                            settlement.receipt_arguments(case.execution, 'executor', 'owned_child_joined', facts))
                    source = dict(facts, framing='content_length', peer_eof=False,
                            actual_bytes=report['result']['body_bytes'], body_sha256=report['result']['body_sha256'],
                            status_code=200, retry_after_seconds=0)
                    if changed != 'unsupported_retry_after':
                        source[changed] = value
                    case.observer.call('worker_record_metadata_quiescence',
                            settlement.receipt_arguments(case.execution, 'arxiv_connection', 'owned_child_joined', source))
                    reply = case.settle()
                    self.assertEqual(reply['state'], 'settled')
                    self.assertIsNone(reply['witness'])
                    self.assertEqual(settlement.accepted(reply['execution'], 'arxiv_connection')['facts'], source)
                finally:
                    case.tearDown()

    def test_lost_ack_replays_exact_checkpoint_without_new_receipt_id(self):
        self.witness()
        self.observer.lose_ack = 'executor'
        with self.assertRaises(Refused):
            self.settle()
        original = self.action.read('executor.json')['parameters']
        self.assertFalse(self.action.exists('executor-ack.json'))
        self.assertEqual(self.settle()['state'], 'settled')
        self.assertEqual(self.observer.calls[0], self.observer.calls[1])
        self.assertEqual(self.action.read('executor.json')['parameters'], original)

    def test_accepted_joined_executor_survives_scope_only_source_recovery(self):
        args = settlement.receipt_arguments(self.execution, 'executor', 'owned_child_joined',
                                            {'binding_sha256': self.execution['binding_sha256'], 'disposition': 'exited'})
        self.observer.call('worker_record_metadata_quiescence', args)
        reply = self.settle()
        self.assertEqual(reply['state'], 'settled')
        self.assertIsNone(reply['witness'])
        self.assertEqual(self.observer.calls[1], args)
        self.assertEqual(self.observer.calls[2]['p_evidence_kind'], 'owned_scope_retired_v1')

    def test_unknown_joined_receipt_cannot_be_replaced_by_scope_receipt(self):
        args = settlement.receipt_arguments(self.execution, 'executor', 'owned_child_joined',
                                            {'binding_sha256': self.execution['binding_sha256'], 'disposition': 'exited'})
        self.action.put('executor.json', {'name': 'worker_record_metadata_quiescence', 'parameters': args})
        self.assertEqual(self.settle()['state'], 'receipt_evidence_unresolved')
        self.assertEqual(self.observer.calls, [])
        self.assertEqual(self.action.read('executor.json')['parameters'], args)

    def test_unsupported_retry_after_keeps_source_hold(self):
        self.witness(retry_kind='unsupported', status=429)
        reply = self.settle()
        self.assertEqual(reply['state'], 'retry_after_unresolved')
        self.assertEqual([call['p_resource'] for call in self.observer.calls], ['executor'])
        self.assertEqual(reply['execution']['pending_resources'], ['arxiv_connection'])

    def test_failed_checkpoint_barrier_issues_no_receipt(self):
        self.witness()
        original = self.action.put
        def fail(name, value, **options):
            if name == 'executor.json':
                raise OSError('failed receipt barrier')
            return original(name, value, **options)
        with patch.object(self.action, 'put', side_effect=fail), self.assertRaises(OSError):
            self.settle()
        self.assertEqual(self.observer.calls, [])

    def test_wrong_ack_proof_is_not_checkpointed(self):
        self.witness()
        original = self.observer.call
        def changed(name, args):
            reply = original(name, args)
            reply['execution']['receipts'][0]['facts']['binding_sha256'] = 'b' * 64
            return reply
        with patch.object(self.observer, 'call', side_effect=changed), self.assertRaises(ValueError):
            self.settle()
        self.assertFalse(self.action.exists('executor-ack.json'))


if __name__ == '__main__':
    unittest.main()
