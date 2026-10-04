"""Portable capture/GO/retirement contract checks; real kernel checks are separate."""
import copy
from pathlib import Path
import types
import unittest
from unittest.mock import patch
import uuid

from common import canonical
from protocol import digest
import lifecycle
import metadata_scope as metadata


class MetadataScopeTests(unittest.TestCase):
    def setUp(self):
        self.claim, self.job, self.boot = (str(uuid.uuid4()) for _ in range(3))
        self.service, self.slice, _ = lifecycle.names(self.claim, 'tsmetadata')
        self.manifest = {'schema_version': 1, 'mode': metadata.MODE, 'fixture': True}
        self.request = {'source_id': '1706.03762', 'revision': 1, 'stage': 'atom', 'byte_ceiling': 1_048_576}
        self.ready = {'schema_version': 1, 'mode': metadata.MODE, 'attempt_id': self.claim,
            'child_id': str(uuid.uuid4()), 'identity': {'boot_id': self.boot, 'process_id': 401,
            'process_start_id': '12345'}, 'controller_pid': 400, 'invocation_id': uuid.uuid4().hex,
            'source_sha256': digest(canonical(self.request)), 'bundle_sha256': digest(canonical(self.manifest)),
            'source_network_enabled': False, 'hosted_admitted': False}
        self.group = {'path': '/' + self.slice, 'device': 4, 'inode': 99, 'populated': 1}
        self.service_state = {'Id': self.service, 'LoadState': 'loaded', 'ActiveState': 'active', 'SubState': 'running',
            'MainPID': '400', 'InvocationID': self.ready['invocation_id'], 'ControlGroup': '/' + self.slice + '/' + self.service,
            'Slice': self.slice, 'KillMode': 'control-group', 'Restart': 'no', 'Delegate': 'no', 'Job': '',
            'FragmentPath': '/run/systemd/system/' + self.service, 'DropInPaths': ''}
        self.slice_state = {'Id': self.slice, 'LoadState': 'loaded', 'ActiveState': 'active', 'ControlGroup': '/' + self.slice,
            'StopWhenUnneeded': 'no', 'FragmentPath': '/run/systemd/system/' + self.slice, 'DropInPaths': ''}
        self.authority = {'project_ref': 'abcdefghijklmnopqrst', 'environment': 'staging', 'enabled': True,
            'recovery_required': False, 'epoch': str(uuid.uuid4()), 'policy_id': str(uuid.uuid4()),
            'admitted_host_id': str(uuid.uuid4()), 'admitted_boot_id': self.boot, 'admitted_deployment_id': 'local-linux-fixture'}
        self.processes = {
            400: {'process_start_id': '12000', 'parent_pid': 1, 'uid': 62401, 'cgroup': '/' + self.slice + '/' + self.service},
            401: {'process_start_id': '12345', 'parent_pid': 400, 'uid': 62402, 'cgroup': '/' + self.slice + '/' + self.service}}
        self.checked_ids = []

        def status(pid, uid, *, parent=None):
            self.checked_ids.append((pid, uid, parent))
            if self.processes[pid]['uid'] != uid or parent is not None and self.processes[pid]['parent_pid'] != parent:
                raise ValueError('fixture_bad_identity')
            return {'uids': [uid] * 4}

        self.render = lambda attempt: metadata.units(attempt, Path(metadata.__file__).parent)
        self.observer = lifecycle.Observer(
            unit_show=lambda name, fields: dict(self.service_state if name == self.service else self.slice_state),
            current_boot=lambda: self.boot, snapshot=lambda path: dict(self.group),
            current_process=lambda pid: dict(self.processes[pid]), unit_renderer=self.render,
            expected_uid=62402, ready_mode=metadata.MODE, family='tsmetadata')
        self.scope = metadata.MetadataScope(self.manifest, self.render, observer=self.observer,
                                            status=status, process=lambda pid: dict(self.processes[pid]))
        self.reader = patch.object(lifecycle, 'read', side_effect=lambda path, limit: self.render(self.claim)[Path(path).name])
        self.reader.start()
        self.capture, self.binding = self.scope.capture(self.job, self.claim, self.request, self.ready, self.authority)
        self.fence = {'schema_version': 1, 'kind': 'linux_metadata_stop_fence_v1', 'scope_id': self.claim,
                      'capture_sha256': digest(canonical(self.capture))}
        # Kernel/unit state and this journal boundary are simulated here;
        # test_action_journal independently exercises its actual durability.
        self.records = {'capture.json': self.capture, 'stop-fence.json': self.fence}
        self.scope.journal = types.SimpleNamespace(
            layout={'records': Path('/var/lib/timestep-source/attempts') / uuid.UUID(self.claim).hex},
            read=lambda name: self.records[name])

    def tearDown(self):
        self.reader.stop()

    def stop(self):
        self.service_state.update(ActiveState='inactive', SubState='dead', MainPID='0', InvocationID='')
        self.group['populated'] = 0

    def test_capture_binds_both_real_processes_and_exact_source(self):
        self.assertIn((400, 62401, None), self.checked_ids)
        self.assertIn((401, 62402, 400), self.checked_ids)
        self.assertEqual(self.capture['supervisor'], {'process_id': 400, 'process_start_id': '12000'})
        self.assertNotIn('capture_sha256', self.capture['binding_without_capture_sha256']['scope'])
        self.assertEqual(self.binding['scope']['capture_sha256'], digest(canonical(self.capture)))
        self.assertEqual(self.binding['scope']['scope_id'], self.claim)
        self.assertNotIn('execution_id', self.capture)
        self.scope.recheck(self.capture, self.ready, self.binding, self.authority)

    def test_source_supervisor_and_authority_drift_cannot_recheck_for_go(self):
        for change in ('source', 'supervisor_start', 'supervisor_uid', 'boot', 'disabled'):
            with self.subTest(change=change):
                ready, authority, processes = copy.deepcopy(self.ready), dict(self.authority), copy.deepcopy(self.processes)
                if change == 'source':
                    ready['source_sha256'] = '0' * 64
                elif change == 'supervisor_start':
                    self.processes[400]['process_start_id'] = '12001'
                elif change == 'supervisor_uid':
                    self.processes[400]['uid'] = 0
                elif change == 'boot':
                    authority['admitted_boot_id'] = str(uuid.uuid4())
                else:
                    authority['enabled'] = False
                with self.assertRaises(ValueError):
                    self.scope.recheck(self.capture, ready, self.binding, authority)
                self.processes = processes

    def test_scope_empty_proof_has_exact_012_fields_without_body_or_exit_claim(self):
        self.stop()
        proof = self.scope.observe(self.capture, self.ready, self.binding, 'a' * 64, self.fence)
        self.assertEqual(set(proof), {'schema_version', 'kind', 'binding_sha256', 'capture_sha256', 'fence_sha256',
            'boot_id', 'scope_id', 'captured_invocation_id', 'observed_invocation_id', 'service', 'group'})
        self.assertEqual(proof['kind'], 'linux_metadata_scope_empty_v1')
        self.assertEqual(proof['group'], {'path': '/' + self.slice, 'device': '4', 'inode': '99', 'populated': 0})
        self.assertEqual(proof['service'], {'active_state': 'inactive', 'main_pid': 0, 'pending_job': False})
        self.assertEqual(proof['observed_invocation_id'], '')

    def test_stop_without_empty_group_is_not_positive_evidence(self):
        self.service_state.update(ActiveState='inactive', MainPID='0')
        self.assertIsNone(self.scope.observe(self.capture, self.ready, self.binding, 'a' * 64, self.fence))

    def test_absent_changed_or_failed_fence_read_cannot_produce_positive_evidence(self):
        self.stop()
        for change in ('missing', 'changed', 'fsync_failure'):
            with self.subTest(change=change):
                def read(name):
                    if name == 'capture.json':
                        return self.capture
                    if change == 'missing':
                        raise FileNotFoundError('missing fence')
                    if change == 'fsync_failure':
                        raise OSError('failed durability barrier')
                    return dict(self.fence, capture_sha256='0' * 64)
                self.scope.journal.read = read
                with self.assertRaises((ValueError, OSError)):
                    self.scope.observe(self.capture, self.ready, self.binding, 'a' * 64, self.fence)

    def test_effective_unit_dropins_block_capture_and_retirement(self):
        for state in (self.service_state, self.slice_state):
            state['DropInPaths'] = '/run/systemd/system/service.d/override.conf'
            with self.assertRaisesRegex(ValueError, 'unexpected_unit_dropin'):
                self.scope.recheck(self.capture, self.ready, self.binding, self.authority)
            self.stop()
            with self.assertRaisesRegex(ValueError, 'unexpected_unit_dropin'):
                self.scope.observe(self.capture, self.ready, self.binding, 'a' * 64, self.fence)
            state['DropInPaths'] = ''
            self.service_state.update(ActiveState='active', MainPID='400', InvocationID=self.ready['invocation_id'])
            self.group['populated'] = 1

    def test_restored_capture_types_and_fence_cannot_change_proof(self):
        self.stop()
        for change in ('bool_version', 'group', 'extra', 'supervisor', 'fence', 'binding'):
            with self.subTest(change=change):
                capture, fence, binding = copy.deepcopy(self.capture), dict(self.fence), copy.deepcopy(self.binding)
                if change == 'bool_version':
                    capture['schema_version'] = True
                elif change == 'group':
                    capture['binding_without_capture_sha256']['scope']['cgroup_inode'] = '099'
                elif change == 'extra':
                    capture['unreviewed'] = True
                elif change == 'supervisor':
                    capture['supervisor']['process_id'] = True
                elif change == 'fence':
                    fence['capture_sha256'] = '0' * 64
                else:
                    binding['scope']['capture_sha256'] = '0' * 64
                with self.assertRaises(ValueError):
                    self.scope.observe(capture, self.ready, binding, 'a' * 64, fence)

    def test_go_retains_granted_execution_id_and_absolute_deadline(self):
        command = {'schema_version': 1, 'kind': 'linux_metadata_go_v1', 'scope_id': self.claim,
            **{key: self.ready[key] for key in ('child_id', 'bundle_sha256', 'source_sha256')},
            'execution_id': str(uuid.uuid4()), 'deadline_ns': '20000'}
        self.assertEqual(metadata.checked_go(command, self.claim, self.ready, now=10000), (command['execution_id'], 20000))
        for field, value in (('execution_id', 'bad'), ('scope_id', str(uuid.uuid4())), ('child_id', str(uuid.uuid4())),
                             ('schema_version', True), ('deadline_ns', 20000), ('deadline_ns', '10000'),
                             ('deadline_ns', '30000010001'), ('source_sha256', '0' * 64)):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                metadata.checked_go(dict(command, **{field: value}), self.claim, self.ready, now=10000)

    def test_metadata_templates_retain_loopback_and_exact_durable_stop_condition(self):
        units = self.render(self.claim)
        service = units[self.service].decode()
        self.assertIn('ConditionPathExists=!/var/lib/timestep-source/attempts/' + uuid.UUID(self.claim).hex + '/stop-fence.json', service)
        self.assertIn('metadata_launcher', service)
        self.assertIn('IPAddressDeny=any\nIPAddressAllow=localhost', service)
        self.assertIn('/var/lib/timestep-metadata-fixture-db', service)
        self.assertNotIn('@', service)

    def test_fixture_helpers_still_reject_metadata_names_without_explicit_family(self):
        with self.assertRaisesRegex(ValueError, 'invalid_unit'):
            lifecycle.show(self.service, lifecycle.SERVICE_FIELDS)
        with self.assertRaisesRegex(ValueError, 'invalid_cgroup'):
            lifecycle.cgroup_snapshot('/' + self.slice)


if __name__ == '__main__':
    unittest.main()
