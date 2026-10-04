import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import uuid

import common
import lifecycle
import package


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.attempt = str(uuid.uuid4())
        self.service, self.slice, _ = lifecycle.names(self.attempt)
        self.boot = str(uuid.uuid4())
        self.invocation = uuid.uuid4().hex
        self.group = {'path': '/' + self.slice, 'device': 4, 'inode': 99, 'populated': 1}
        self.ready = {'schema_version': 1, 'mode': 'loopback_lifecycle_fixture', 'attempt_id': self.attempt,
                      'child_id': str(uuid.uuid4()), 'identity': {'boot_id': self.boot, 'process_id': 401,
                      'process_start_id': '1234'}, 'controller_pid': 400, 'invocation_id': self.invocation,
                      'source_sha256': 'a' * 64, 'bundle_sha256': 'b' * 64,
                      'source_network_enabled': False, 'hosted_admitted': False}
        self.service_state = {'Id': self.service, 'LoadState': 'loaded', 'ActiveState': 'active', 'SubState': 'running',
                      'MainPID': '400', 'InvocationID': self.invocation,
                      'ControlGroup': '/' + self.slice + '/' + self.service, 'Slice': self.slice,
                      'KillMode': 'control-group', 'Restart': 'no', 'Delegate': 'no', 'Job': '',
                      'FragmentPath': '/run/systemd/system/' + self.service}
        self.slice_state = {'Id': self.slice, 'LoadState': 'loaded', 'ActiveState': 'active',
                            'ControlGroup': '/' + self.slice, 'StopWhenUnneeded': 'no',
                            'FragmentPath': '/run/systemd/system/' + self.slice}
        self.observer = lifecycle.Observer(unit_show=lambda name, _: dict(self.service_state if name == self.service else self.slice_state),
                    current_boot=lambda: self.boot, snapshot=lambda _: dict(self.group),
                    current_process=lambda _: {'process_start_id': '1234', 'parent_pid': 400, 'uid': 65534,
                                              'cgroup': '/' + self.slice + '/' + self.service})
        units = lifecycle.rendered_units(self.attempt)
        self.reader = patch.object(lifecycle, 'read', side_effect=lambda path, limit: units[Path(path).name])
        self.reader.start()
        self.capture = self.observer.capture(self.attempt, self.ready)
        self.fence = {'schema_version': 1, 'kind': 'fixture_stop_fence_v1',
                      'capture_sha256': lifecycle.digest(self.capture), 'attempt_id': self.attempt}

    def tearDown(self):
        self.reader.stop()
        for directory, _, _ in os.walk(self.root):
            Path(directory).chmod(0o700)
        self.temp.cleanup()

    def stopped(self):
        self.service_state.update(ActiveState='inactive', SubState='dead', MainPID='0')

    def test_stop_return_without_empty_group_is_unresolved(self):
        self.stopped()
        result = self.observer.observe(self.capture, self.fence)
        self.assertFalse(result['owned_group_empty'])
        self.assertFalse(result['sql_receipt_authority'])

    def test_empty_active_group_without_stop_completion_is_unresolved(self):
        self.group['populated'] = 0
        self.assertFalse(self.observer.observe(self.capture, self.fence)['owned_group_empty'])

    def test_exact_stopped_empty_group_is_only_fixture_evidence(self):
        self.stopped(); self.group['populated'] = 0
        result = self.observer.observe(self.capture, self.fence)
        self.assertEqual(result['kind'], 'fixture_cgroup_empty_v1')
        self.assertNotEqual(result['kind'], 'owned_child_joined')
        self.assertFalse(result['sql_receipt_authority'])

    def test_wrong_boot_or_invocation_refuses(self):
        for key in ('boot', 'invocation'):
            with self.subTest(key=key):
                original = self.boot if key == 'boot' else self.service_state['InvocationID']
                if key == 'boot': self.boot = str(uuid.uuid4())
                else: self.service_state['InvocationID'] = uuid.uuid4().hex
                with self.assertRaises(ValueError): self.observer.observe(self.capture, self.fence)
                if key == 'boot': self.boot = original
                else: self.service_state['InvocationID'] = original

    def test_cleared_invocation_requires_inactive_and_empty_retained_group(self):
        self.service_state['InvocationID'] = ''
        with self.assertRaises(ValueError): self.observer.observe(self.capture, self.fence)
        self.stopped(); self.group['populated'] = 0
        self.assertTrue(self.observer.observe(self.capture, self.fence)['owned_group_empty'])

    def test_missing_or_recreated_group_is_not_retirement(self):
        self.group['inode'] += 1
        with self.assertRaisesRegex(ValueError, 'group_identity_changed'):
            self.observer.observe(self.capture, self.fence)
        self.observer.snapshot = lambda _: (_ for _ in ()).throw(FileNotFoundError())
        with self.assertRaises(FileNotFoundError): self.observer.observe(self.capture, self.fence)

    def test_changed_source_or_fence_refuses(self):
        with patch.object(lifecycle, 'read', return_value=b'changed'):
            with self.assertRaisesRegex(ValueError, 'unit_source_changed'):
                self.observer.observe(self.capture, self.fence)
        bad = dict(self.fence, attempt_id=str(uuid.uuid4()))
        with self.assertRaisesRegex(ValueError, 'invalid_stop_fence'):
            self.observer.observe(self.capture, bad)

    def test_bool_group_identity_and_truthy_flags_refuse(self):
        for mutate in (lambda c: c.update(hosted_admitted='false'), lambda c: c['group'].update(inode=True)):
            bad = copy.deepcopy(self.capture); mutate(bad)
            fence = dict(self.fence, capture_sha256=lifecycle.digest(bad))
            with self.assertRaises(ValueError): self.observer.observe(bad, fence)

    def test_restored_nested_ready_binding_is_strict(self):
        mutations = (lambda c: c.update(ready={}),
                     lambda c: c['ready'].update(invocation_id=uuid.uuid4().hex),
                     lambda c: c['ready']['identity'].update(boot_id=str(uuid.uuid4())),
                     lambda c: c['ready']['identity'].update(process_id=True),
                     lambda c: c['ready'].update(source_sha256='not a hash'))
        self.stopped(); self.group['populated'] = 0
        for mutate in mutations:
            bad = copy.deepcopy(self.capture); mutate(bad)
            fence = dict(self.fence, capture_sha256=lifecycle.digest(bad))
            with self.assertRaises(ValueError): self.observer.observe(bad, fence)

    def test_capture_owns_ready_snapshot(self):
        self.ready['identity']['process_id'] = 999
        self.assertEqual(self.capture['ready']['identity']['process_id'], 401)

    def test_immutable_checkpoint_and_fresh_fsync_on_reopen(self):
        common.publish(self.root, 'capture.json', self.capture)
        with self.assertRaises(FileExistsError): common.publish(self.root, 'capture.json', self.capture)
        with patch.object(common.os, 'fsync', side_effect=OSError('fixture barrier failure')):
            with self.assertRaises(OSError): common.durable_read(self.root / 'capture.json')
        self.assertEqual(common.durable_read(self.root / 'capture.json'), self.capture)

    def test_symlink_and_duplicate_keys_refuse(self):
        common.publish(self.root, 'record.json', {'a': 1})
        (self.root / 'link.json').symlink_to('record.json')
        with self.assertRaises(OSError): common.read(self.root / 'link.json')
        with self.assertRaises(ValueError): common.decode(b'{"a":1,"a":2}')

    def test_bundle_binds_actual_copied_bytes_and_runtime(self):
        manifest = package.build(self.root / 'bundle')
        for name, digest in manifest['files'].items():
            self.assertEqual(hashlib.sha256((self.root / 'bundle' / name).read_bytes()).hexdigest(), digest)
        self.assertEqual(manifest['python_sha256'], package.runtime_sha())
        self.assertFalse(manifest['source_network_enabled'])
        self.assertFalse(manifest['hosted_admitted'])
        with self.assertRaises(FileExistsError): package.build(self.root / 'bundle')

    def test_cgroup_reader_observes_exact_retained_directory(self):
        parent = self.root / 'cgroups'; parent.mkdir()
        group = parent / self.slice; group.mkdir(); (group / 'cgroup.events').write_text('populated 0\nfrozen 0\n')
        snapshot = lifecycle.cgroup_snapshot('/' + self.slice, parent)
        self.assertEqual(snapshot['populated'], 0)
        self.assertEqual(snapshot['inode'], group.stat().st_ino)
        (group / 'cgroup.events').write_text('populated 0\npopulated 1\n')
        with self.assertRaises(ValueError): lifecycle.cgroup_snapshot('/' + self.slice, parent)

    def test_uncertain_cleanup_preserves_all_owned_files(self):
        from unittest.mock import Mock
        for fail_at in (1, 2):
            control = Mock(side_effect=[ValueError('stop unknown')] if fail_at == 1 else [None, ValueError('stop unknown')])
            remove = Mock()
            with self.assertRaises(ValueError):
                lifecycle.stop_before_cleanup(self.attempt, remove, control=control,
                                              snapshot=lambda _: {'populated': 0})
            remove.assert_not_called()
        remove = Mock()
        with self.assertRaisesRegex(ValueError, 'cleanup_group_unresolved'):
            lifecycle.stop_before_cleanup(self.attempt, remove, control=Mock(), snapshot=lambda _: {'populated': 1})
        remove.assert_not_called()


if __name__ == '__main__':
    unittest.main()
