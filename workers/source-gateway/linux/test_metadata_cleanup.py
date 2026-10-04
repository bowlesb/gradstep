"""Portable test-only cleanup checks. No PG, systemd, TLS or VM is invoked."""
from contextlib import ExitStack
import copy
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch
import uuid

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent)]
import test_metadata_integration as fixture
import test_metadata_settlement as settlement_fixture


def state(unit, *, service, loaded=None):
    value = {'Id': unit, 'LoadState': loaded or ('not-found' if service else 'loaded'),
        'ActiveState': 'inactive', 'SubState': 'dead', 'FragmentPath': '', 'SourcePath': '',
        'DropInPaths': '', 'Job': '', 'ControlGroup': ''}
    if service:
        value['MainPID'] = '0'
    return value


def reply(value, code=0):
    return code, ''.join(key + '=' + value + '\n' for key, value in value.items()).encode(), b''


class RemovedRuntimeTests(unittest.TestCase):
    def test_generated_inactive_slice_is_allowed_but_loaded_service_is_not(self):
        for service, loaded in ((True, 'not-found'), (False, 'not-found'), (False, 'loaded')):
            with self.subTest(service=service, loaded=loaded), patch.object(fixture.database, 'run',
                    return_value=reply(state('unit', service=service, loaded=loaded))):
                self.assertEqual(fixture.removed_unit_state('unit', service=service)['LoadState'], loaded)
        with patch.object(fixture.database, 'run', return_value=reply(state('unit', service=True, loaded='loaded'))):
            with self.assertRaisesRegex(ValueError, 'unit_unload_unresolved'):
                fixture.removed_unit_state('unit', service=True)

    def test_runtime_state_rejects_jobs_paths_pid_and_invalid_output(self):
        for key, value in (('Id', 'another'), ('ActiveState', 'active'), ('SubState', 'running'),
                           ('MainPID', '7'), ('Job', '3'), ('FragmentPath', '/file'), ('SourcePath', '/file'),
                           ('DropInPaths', '/dropin'), ('ControlGroup', '/group')):
            bad = dict(state('unit', service=True), **{key: value})
            with self.subTest(key=key), patch.object(fixture.database, 'run', return_value=reply(bad)):
                with self.assertRaises(ValueError): fixture.removed_unit_state('unit', service=True)
        valid = reply(state('unit', service=True))
        for output in ((1, valid[1], b''), (0, valid[1] + b'Job=\n', b''),
                       (0, valid[1].replace(b'SubState=dead\n', b''), b'')):
            with patch.object(fixture.database, 'run', return_value=output):
                with self.assertRaises(ValueError): fixture.removed_unit_state('unit', service=True)

    def test_absent_or_same_empty_group_is_current_absence_not_new_retirement(self):
        action = types.SimpleNamespace(service='service', slice='slice', units=[])
        observation = {'boot_id': 'boot', 'group': {'device': '3', 'inode': '4'}}
        with patch.object(fixture.lifecycle, 'boot_id', return_value='boot'), \
             patch.object(fixture, 'removed_unit_state', return_value={}), \
             patch.object(fixture, 'require_no_fixture_runtime') as processes, \
             patch.object(fixture.os.path, 'lexists', return_value=False), \
             patch.object(fixture.lifecycle, 'cgroup_snapshot', side_effect=FileNotFoundError):
            value = fixture.removed_runtime(action, observation)
            self.assertIsNone(value['group'])
            self.assertIs(value['new_retirement_receipt'], False)
            processes.assert_called_once()
        for inode, populated in ((4, 0), (5, 0), (4, 1)):
            with patch.object(fixture.lifecycle, 'boot_id', return_value='boot'), \
                 patch.object(fixture, 'removed_unit_state', return_value={}), \
                 patch.object(fixture, 'require_no_fixture_runtime'), \
                 patch.object(fixture.lifecycle, 'cgroup_snapshot',
                              return_value={'device': 3, 'inode': inode, 'populated': populated}):
                if (inode, populated) == (4, 0):
                    self.assertEqual(fixture.removed_runtime(action, observation)['group']['inode'], 4)
                else:
                    with self.assertRaisesRegex(ValueError, 'scope_identity_changed'):
                        fixture.removed_runtime(action, observation)
        with patch.object(fixture.lifecycle, 'boot_id', return_value='changed'):
            with self.assertRaisesRegex(ValueError, 'changed_boot_requires_review'):
                fixture.removed_runtime(action, observation)


class RetainedFilesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.root = base / 'transport'; self.root.mkdir()
        self.layout = {leaf: (self.root if leaf in ('control', 'data', 'ingress') else base) / leaf
                       for leaf in ('records', 'witness', 'control', 'data', 'ingress')}
        for leaf, path in self.layout.items():
            path.mkdir(mode=0o750 if leaf == 'control' else 0o700)
        self.action = types.SimpleNamespace(root=self.root, layout=self.layout)
        self.claim = str(uuid.uuid4())
        self.saved = {'claim_id': self.claim, 'execution_id': str(uuid.uuid4()), 'pending_resources': [],
            'result_ack_sha256': 'a' * 64, 'observation': {}, 'files': {}}
        names = ['records/' + name for name in ('capacity.json', 'capture.json', 'stop-fence.json',
            'result.json', 'result-ack.json', 'executor.json', 'executor-ack.json',
            'arxiv_connection.json', 'arxiv_connection-ack.json')]
        names += ['data/ready.json', 'data/privileges.json', 'witness/publication.lock', 'witness/witness.json']
        for key in names:
            leaf, name, _ = fixture.cleanup_spec(key)
            raw = b'' if name == 'publication.lock' else b'{}'
            path = self.layout[leaf] / name
            path.write_bytes(raw); path.chmod(0o600)
            self.saved['files'][key] = {'bytes': len(raw), 'sha256': fixture.database.sha(raw)}
        self.source_bytes = 300_000
        self.saved['inventory'] = {'names': len(names) + 2,
            'bytes': self.source_bytes + sum(value['bytes'] for value in self.saved['files'].values()),
            'ordinary_pending': []}
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(fixture, 'trusted_directory'))
        self.stack.enter_context(patch.object(fixture, 'cleanup_identity', side_effect=lambda leaf:
            (os.getuid(), os.getgid(), 0o750 if leaf == 'control' else 0o700)))

    def test_checkpoint_bounds_fixed_paths_and_required_records(self):
        self.assertIs(fixture.checked_cleanup_checkpoint(self.saved, self.claim, self.source_bytes), self.saved)
        for edit in ('path', 'size', 'missing', 'inventory', 'alias'):
            bad = copy.deepcopy(self.saved)
            if edit == 'path': bad['files']['records/../../escape'] = bad['files']['records/result.json']
            elif edit == 'size': bad['files']['records/result.json']['bytes'] = True
            elif edit == 'missing': del bad['files']['records/result-ack.json']
            elif edit == 'inventory': bad['inventory']['bytes'] += 1
            else: bad['files']['records/.pending-result.json'] = bad['files']['records/result.json']
            with self.subTest(edit=edit), self.assertRaises(ValueError):
                fixture.checked_cleanup_checkpoint(bad, self.claim, self.source_bytes)

    def test_exact_existing_lock_files_and_durability_are_reused_without_publication(self):
        before = {p: (p.stat().st_ino, p.read_bytes()) for leaf in self.layout.values() for p in leaf.iterdir()}
        with fixture.retained_cleanup_records(self.action, self.saved) as (read, remove):
            self.assertEqual(read('capture.json'), {})
            self.assertEqual(set(remove), set(before))
            with self.assertRaises(BlockingIOError):
                with fixture.retained_cleanup_records(self.action, self.saved): self.fail('second lock')
        self.assertEqual(before, {p: (p.stat().st_ino, p.read_bytes()) for leaf in self.layout.values() for p in leaf.iterdir()})

    def test_changed_missing_extra_alias_and_permissions_are_retained(self):
        path = self.layout['records'] / 'capture.json'
        for edit in ('changed', 'missing', 'extra', 'alias', 'permissions', 'lock'):
            extra = self.layout['records'] / 'unknown.json'
            removed_lock = self.layout['witness'] / 'publication.lock'
            if edit == 'changed': path.write_bytes(b'{ }')
            elif edit == 'missing': path.unlink()
            elif edit == 'extra': extra.write_bytes(b'{}'); extra.chmod(0o600)
            elif edit == 'alias': os.link(path, extra)
            elif edit == 'permissions': path.chmod(0o644)
            else: removed_lock.unlink()
            with self.subTest(edit=edit), self.assertRaises((ValueError, FileNotFoundError)):
                with fixture.retained_cleanup_records(self.action, self.saved): self.fail('accepted changed files')
            if extra.exists(): extra.unlink()
            path.write_bytes(b'{}'); path.chmod(0o600)
            if not removed_lock.exists(): removed_lock.write_bytes(b''); removed_lock.chmod(0o600)

    def test_failed_fsync_never_exposes_deletion_authority(self):
        with patch.object(fixture.os, 'fsync', side_effect=OSError('fixture barrier failed')):
            with self.assertRaises(OSError):
                with fixture.retained_cleanup_records(self.action, self.saved): self.fail('yielded before durability')
        self.assertEqual(sum(len(list(leaf.iterdir())) for leaf in self.layout.values()), len(self.saved['files']))

    def test_recovery_unproven_database_settlement_never_unlinks_or_publishes(self):
        # Exercise the real recovery method and actual retained-file verifier.
        # Only the unrelated valid capture shape/runtime context is simulated;
        # the observer's unsettled result must stop before destructive work.
        job = str(uuid.uuid4())
        service = 'tsmetadata' + uuid.UUID(self.claim).hex + '.service'
        slice_name = service.removesuffix('.service') + '.slice'
        self.action.service, self.action.slice = service, slice_name
        self.action.units = {Path('/run/systemd/system') / service: b'service',
                             Path('/run/systemd/system') / slice_name: b'slice'}
        self.action.source_bytes, self.action.capacity = self.source_bytes, {}
        self.action.render = lambda _: {}
        capture = {'claim_id': self.claim, 'job_id': job, 'binding_without_capture_sha256': {'scope': {}},
                   'unit_sha256': fixture.database.sha(b'service'), 'slice_sha256': fixture.database.sha(b'slice')}
        raw = fixture.database.canonical(capture)
        (self.layout['records'] / 'capture.json').write_bytes(raw)
        self.saved['files']['records/capture.json'] = {'bytes': len(raw), 'sha256': fixture.database.sha(raw)}
        self.saved['inventory']['bytes'] = self.source_bytes + sum(row['bytes'] for row in self.saved['files'].values())
        evidence = Path(self.temp.name).resolve() / 'evidence'; evidence.mkdir(mode=0o700)
        cleanup = evidence / ('cleanup-' + uuid.UUID(self.claim).hex + '.json')
        raw = fixture.database.canonical(self.saved)
        cleanup.write_bytes(raw); cleanup.chmod(0o600)
        digest = fixture.database.sha(raw)
        class Restored(fixture.MetadataIntegrationTests):
            pass
        Restored.claims, Restored.job, Restored.evidence = [self.claim], job, evidence
        Restored.bundle, Restored.manifest, Restored.record = Path('/owned/bundle'), {}, Mock()
        original_read = fixture.database.read_file
        before = {path: path.read_bytes() for leaf in self.layout.values() for path in leaf.iterdir()}
        for execution, step in ((None, {'job_id': job}),
                                ({'pending_resources': ['executor']}, {'job_id': job}),
                                ({'pending_resources': []}, None)):
            Restored.state = Mock(return_value={'execution': execution, 'step_result': step})
            with patch.object(fixture, 'owned_directory'), \
                 patch.object(fixture, 'HostAction', return_value=self.action), \
                 patch.object(fixture.bootstrap, 'load_bundle', return_value=({}, None)), \
                 patch.object(fixture.MetadataScope, 'checked_capture'), \
                 patch.object(fixture.database, 'read_file', side_effect=lambda path, maximum, **kwargs:
                              original_read(path, maximum, uid=os.getuid(), **kwargs)), \
                 patch.object(fixture, 'removed_runtime') as runtime, \
                 patch.object(Path, 'unlink') as unlink:
                with self.assertRaisesRegex(ValueError, 'unsettled_action_retained'):
                    Restored.recover_cleanup_action(self.claim, digest)
                unlink.assert_not_called(); runtime.assert_not_called()
            Restored.record.assert_not_called()
            self.assertEqual(before, {path: path.read_bytes() for leaf in self.layout.values() for path in leaf.iterdir()})


class ExpectedFailureTests(unittest.TestCase):
    def setUp(self):
        self.case = settlement_fixture.SettlementTests()
        self.case.setUp()
        self.addCleanup(self.case.tearDown)
        case, kernel = self.case, self.case.kernel
        case.settle()  # Actual private journal, explicitly simulated SQL/kernel.
        self.execution = copy.deepcopy(case.observer.execution)
        self.ack = {'id': kernel.job, 'source_id': fixture.SOURCE, 'requested_revision': 1,
            'generation': 1, 'stage': 'atom', 'status': 'retry_wait', 'error_code': 'metadata_unavailable',
            'retryable': True, 'claim_id': None}
        result = {'name': 'worker_fail_metadata_stage_v2', 'parameters': {'p_job_id': kernel.job,
            'p_claim_id': kernel.claim, 'p_generation': 1, 'p_attempt_id': self.execution['id'],
            'p_error_code': 'metadata_unavailable', 'p_retryable': True}}
        case.action.put('result.json', result)
        case.action.put('result-ack.json', self.ack)
        self.current = {'job': self.ack, 'execution': self.execution, 'step_result': {
            'attempt_id': self.execution['id'], 'error_code': 'metadata_unavailable', 'retryable': True}}
        self.action = types.SimpleNamespace(journal=case.action, binding=kernel.binding, capture=kernel.capture,
            ready=kernel.ready, service=kernel.service, slice=kernel.slice, claim=kernel.claim,
            scope=kernel.scope, fence_value=lambda: kernel.fence)

    def settled(self, current=None, read=None, **kwargs):
        k = self.case.kernel
        return fixture.settled_cleanup_records(read or self.case.action.read,
            self.current if current is None else current, k.binding, k.job, k.claim, **kwargs)

    def test_failure_is_explicit_exact_and_scope_only(self):
        self.assertEqual(self.settled(expected_failure=True), (self.execution, self.ack))
        with self.assertRaisesRegex(ValueError, 'missing_result_ack_retained'):
            self.settled()
        for edit in ('pending', 'attempt', 'error', 'retry', 'generation', 'ack', 'joined', 'status', 'body'):
            current = copy.deepcopy(self.current)
            saved = {name: self.case.action.read(name) for name in ('result.json', 'result-ack.json',
                'executor.json', 'executor-ack.json', 'arxiv_connection.json', 'arxiv_connection-ack.json')}
            if edit == 'pending': current['execution']['pending_resources'] = ['executor']
            elif edit == 'attempt': current['step_result']['attempt_id'] = str(uuid.uuid4())
            elif edit == 'error': current['step_result']['error_code'] = 'source_not_found'
            elif edit == 'retry': current['step_result']['retryable'] = 1
            elif edit == 'generation': saved['result.json']['parameters']['p_generation'] = 2
            elif edit == 'ack': saved['result-ack.json']['status'] = 'complete'
            elif edit == 'joined': saved['executor.json']['parameters']['p_evidence_kind'] = 'owned_child_joined'
            else:
                facts = saved['arxiv_connection.json']['parameters']['p_facts']
                facts['status_code' if edit == 'status' else 'actual_bytes'] = 200 if edit == 'status' else 0
            with self.subTest(edit=edit), self.assertRaises(ValueError):
                self.settled(current, saved.__getitem__, expected_failure=True)

    def test_reset_accepts_only_exact_killed_failed_service_and_original_paths(self):
        action = self.action
        value = dict(state(action.service, service=True, loaded='loaded'), ActiveState='failed', SubState='failed',
            FragmentPath='/run/systemd/system/' + action.service, InvocationID=action.ready['invocation_id'],
            Result='signal', ExecMainCode='2', ExecMainStatus='9')
        with patch.object(fixture.lifecycle, 'show', return_value=value):
            self.assertEqual(fixture.fault_service_state(action), value)
        for key, changed in (('ActiveState', 'active'), ('Result', 'exit-code'), ('ExecMainStatus', '15'),
                             ('ExecMainCode', '1'), ('Job', '3'), ('MainPID', '42'),
                             ('InvocationID', 'another'), ('SourcePath', '/source'), ('DropInPaths', '/dropin'),
                             ('ControlGroup', '/different'), ('FragmentPath', '/another')):
            with self.subTest(key=key), patch.object(fixture.lifecycle, 'show', return_value=dict(value, **{key: changed})):
                with self.assertRaisesRegex(ValueError, 'unexpected_fault_service_state'):
                    fixture.fault_service_state(action)
        reset = dict(value, ActiveState='inactive', SubState='dead', Result='success')
        with patch.object(fixture.lifecycle, 'show', return_value=reset):
            self.assertEqual(fixture.fault_service_state(action, reset=True), reset)
            with self.assertRaises(ValueError): fixture.fault_service_state(action)

    def test_one_reset_only_after_durable_proof_and_recheck_with_fence_retained(self):
        k = self.case.kernel
        k.service_state.update(ActiveState='failed', SubState='failed')
        observation = k.scope.observe(k.capture, k.ready, k.binding, self.execution['binding_sha256'], k.fence)
        class Context(fixture.MetadataIntegrationTests):
            pass
        Context.job, Context.scenario, Context.claims = k.job, fixture.FAULT, [k.claim]
        Context.state = Mock(return_value=self.current)
        Context.fault_proof = Mock(return_value={'exact_fixture_proof': True})
        events = []
        Context.record = Mock(side_effect=lambda name, value: events.append(name))
        def reset(argv):
            self.assertEqual(argv, ['/usr/bin/systemctl', 'reset-failed', k.service])
            self.assertEqual(events, ['fault-reset-intent.json'])
            self.assertEqual(self.case.action.read('stop-fence.json'), k.fence)
            events.append('reset')
            k.service_state.update(ActiveState='inactive', SubState='dead')
        with patch.object(fixture, 'require_no_fixture_runtime'), \
             patch.object(fixture, 'fault_service_state', side_effect=lambda action, **kw: {'reset': kw.get('reset', False)}), \
             patch.object(fixture.lifecycle, 'run', side_effect=reset) as run:
            Context.reset_fault_service(self.action, self.execution, observation)
        self.assertEqual(events, ['fault-reset-intent.json', 'reset', 'fault-reset-ack.json'])
        self.assertEqual(run.call_count, 1)
        self.assertEqual(self.case.action.read('stop-fence.json'), k.fence)

    def test_failed_proof_publication_unsettled_or_changed_fence_never_resets(self):
        k = self.case.kernel
        observation = k.scope.observe(k.capture, k.ready, k.binding, self.execution['binding_sha256'], k.fence)
        for failure in ('unsettled', 'proof', 'publication', 'changed_fence', 'nonempty'):
            class Context(fixture.MetadataIntegrationTests): pass
            Context.job = k.job
            current = copy.deepcopy(self.current)
            if failure == 'unsettled': current['execution']['pending_resources'] = ['executor']
            Context.state = Mock(return_value=current)
            Context.fault_proof = Mock(side_effect=ValueError('proof') if failure == 'proof' else None, return_value={})
            reads = self.case.action.read
            changed = False
            def record(name, value):
                nonlocal changed
                if failure == 'publication': raise OSError('directory fsync')
                changed = True
            def read(name):
                if failure == 'changed_fence' and changed and name == 'stop-fence.json':
                    return dict(k.fence, capture_sha256='0' * 64)
                return reads(name)
            Context.record = Mock(side_effect=record)
            with self.subTest(failure=failure), patch.object(fixture, 'require_no_fixture_runtime'), \
                 patch.object(fixture, 'fault_service_state', return_value={}), \
                 patch.object(self.case.action, 'read', side_effect=read), \
                 patch.object(fixture.lifecycle, 'run') as run:
                if failure == 'nonempty': self.case.kernel.group['populated'] = 1
                with self.assertRaises((ValueError, OSError)):
                    Context.reset_fault_service(self.action, self.execution, observation)
                run.assert_not_called()
            self.case.kernel.group['populated'] = 0


if __name__ == '__main__':
    unittest.main(verbosity=2)
