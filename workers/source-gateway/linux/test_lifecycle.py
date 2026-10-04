"""Explicitly opted-in real Linux systemd/cgroup tests; never starts a VM."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

import common
import lifecycle
import package
from tls_fixture import Server, certificate

ENABLED = sys.platform == 'linux' and os.environ.get('TIMESTEP_LINUX_FIXTURE_RUN') == '1'
REQUEST = {'source_id': '1706.03762', 'revision': 1, 'stage': 'atom', 'byte_ceiling': 1024}


@unittest.skipUnless(ENABLED, 'requires explicit opt-in inside the marked isolated Linux guest')
class LifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.platform = lifecycle.preflight()
        cls.certs = tempfile.TemporaryDirectory(prefix='timestep-loopback-certificate-')
        cls.cert, cls.key = certificate(Path(cls.certs.name))
        cls.base = Path('/run/timestep-source-fixture')
        cls.base.mkdir(mode=0o755, exist_ok=True)
        if cls.base.is_symlink() or cls.base.stat().st_uid != 0 or cls.base.stat().st_mode & 0o022:
            raise ValueError('unowned_fixture_base')

    @classmethod
    def tearDownClass(cls):
        cls.certs.cleanup()

    def setUp(self):
        self.attempt = str(uuid.uuid4())
        self.service, self.slice, root = lifecycle.names(self.attempt)
        self.root = Path(root)
        self.root.mkdir(mode=0o755)
        (self.root / 'data').mkdir(mode=0o700)
        os.chown(self.root / 'data', 65534, 65534)
        self.checkpoints = self.root / 'observer'
        self.checkpoints.mkdir(mode=0o700)
        self.manifest = package.build(self.root / 'bundle')
        self.unit_paths = []
        self.started = False
        for suffix, target in [('service', self.service), ('slice', self.slice)]:
            template = (self.root / 'bundle' / ('attempt.' + suffix + '.in')).read_text()
            text = template.replace('@ATTEMPT@', self.attempt).replace('@ROOT@', str(self.root)).replace('@SLICE@', self.slice)
            if '@' in text:
                raise ValueError('unexpanded_template')
            path = Path('/run/systemd/system') / target
            with path.open('x') as stream:
                stream.write(text); stream.flush(); os.fsync(stream.fileno())
            path.chmod(0o444)
            self.unit_paths.append(path)
        lifecycle.run(['/usr/bin/systemctl', 'daemon-reload'])

    def tearDown(self):
        # Exact fixture identities only. Cleanup never claims SQL retirement.
        if not (self.checkpoints / 'stop-fence.json').exists():
            common.publish(self.checkpoints, 'stop-fence.json', {'schema_version': 1,
                           'kind': 'fixture_cleanup_fence_v1', 'attempt_id': self.attempt})
        common.durable_read(self.checkpoints / 'stop-fence.json')
        def remove_artifacts():
            for path in self.unit_paths:
                path.unlink()
            lifecycle.run(['/usr/bin/systemctl', 'daemon-reload'])
            for unit in (self.service, self.slice):
                try:
                    lifecycle.run(['/usr/bin/systemctl', 'reset-failed', unit])
                except ValueError:
                    pass  # An already unloaded exact unit needs no reset.
            shutil.rmtree(self.root)
        lifecycle.stop_before_cleanup(self.attempt, remove_artifacts)

    def wait_file(self, name, seconds=5):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            path = self.root / 'data' / name
            if path.exists():
                return common.decode(common.read(path))
            time.sleep(.01)
        state = lifecycle.show(self.service, lifecycle.SERVICE_FIELDS)
        self.fail('missing ' + name + '; unit=' + json.dumps(state, sort_keys=True))

    def start(self, server):
        self.assertFalse(self.started)
        value = {'schema_version': 1, 'mode': 'loopback_lifecycle_fixture', 'attempt_id': self.attempt,
                 'request': REQUEST, 'fixture': server.fixture}
        common.publish(self.root, 'input.json', value)
        (self.root / 'input.json').chmod(0o444)
        # The root fixture harness consumes launch authority once, before start.
        common.publish(self.checkpoints, 'launch.json', {'attempt_id': self.attempt,
                       'bundle_sha256': lifecycle.digest(self.manifest), 'source_network_enabled': False})
        self.started = True
        lifecycle.run(['/usr/bin/systemctl', 'start', self.slice, self.service])
        ready = self.wait_file('ready.json')
        self.assertEqual(ready['bundle_sha256'], lifecycle.digest(self.manifest))
        self.assertEqual(ready['source_sha256'], lifecycle.digest(REQUEST))
        self.capture = lifecycle.Observer().capture(self.attempt, ready)
        common.publish(self.checkpoints, 'capture.json', self.capture)
        return ready

    def go(self, ready):
        common.publish(self.root, 'go.json', {'mode': 'loopback_lifecycle_fixture', 'attempt_id': self.attempt,
                       'child_id': ready['child_id'], 'bundle_sha256': ready['bundle_sha256']})
        (self.root / 'go.json').chmod(0o444)

    def fresh_observer(self):
        command = [sys.executable, '-I', '-S', '-B', str(self.root / 'bundle' / 'bootstrap.py'),
                   str(self.root / 'bundle'), 'linux_lifecycle', str(self.checkpoints)]
        result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                                env={'LC_ALL': 'C'}, timeout=8)
        self.assertLessEqual(len(result.stdout) + len(result.stderr), 4096)
        self.assertEqual(result.returncode, 0, result.stdout.decode())
        value = common.decode(result.stdout)
        self.assertEqual(value['kind'], 'fixture_cgroup_empty_v1')
        self.assertFalse(value['sql_receipt_authority'])
        return value

    def test_normal_transport_has_real_parent_join_and_separate_empty_group(self):
        with Server(self.cert, self.key) as server:
            ready = self.start(server); self.go(ready)
            witness = self.wait_file('witness.json')
            self.assertTrue(witness['owned_process_retired'])
            self.assertEqual(witness['retirement_witness'], 'parent_waitpid')
            self.assertEqual(witness['result']['body_bytes'], 2)
            self.assertEqual(server.connections, 1)
            self.fresh_observer()

    def test_controller_killed_before_go_opens_no_source_connection(self):
        with Server(self.cert, self.key) as server:
            ready = self.start(server)
            os.kill(ready['controller_pid'], signal.SIGKILL)
            value = self.fresh_observer()
            self.assertTrue(value['owned_group_empty'])
            self.assertEqual(server.connections, 0)
            self.assertFalse((self.root / 'data' / 'witness.json').exists())

    def test_controller_death_during_tls_has_no_fabricated_wait_witness(self):
        with Server(self.cert, self.key, slow=True) as server:
            ready = self.start(server); self.go(ready)
            self.assertTrue(server.requested.wait(3))
            os.kill(ready['controller_pid'], signal.SIGKILL)
            self.fresh_observer()
            self.assertTrue(server.ended.wait(2))
            self.assertEqual(server.connections, 1)
            self.assertFalse((self.root / 'data' / 'witness.json').exists())

    def test_stopped_child_stays_populated_until_exact_group_stop(self):
        with Server(self.cert, self.key, slow=True) as server:
            ready = self.start(server); self.go(ready)
            self.assertTrue(server.requested.wait(3))
            os.kill(ready['identity']['process_id'], signal.SIGSTOP)
            fence = {'schema_version': 1, 'kind': 'fixture_stop_fence_v1',
                     'capture_sha256': lifecycle.digest(self.capture), 'attempt_id': self.attempt}
            common.publish(self.checkpoints, 'stop-fence.json', fence)
            self.assertFalse(lifecycle.Observer().observe(self.capture, fence)['owned_group_empty'])
            self.fresh_observer()

    def test_observer_restart_replays_capture_without_restarting_action(self):
        with Server(self.cert, self.key, slow=True) as server:
            ready = self.start(server); self.go(ready)
            self.assertTrue(server.requested.wait(3))
            first = self.fresh_observer()
            # A second independently launched observer reopens the same capture.
            second = self.fresh_observer()
            self.assertEqual(first, second)
            # The root-owned durable marker is also a PID1 start condition.
            # An explicit restart request cannot mint another activation.
            lifecycle.run(['/usr/bin/systemctl', 'start', self.service])
            state = lifecycle.show(self.service, lifecycle.SERVICE_FIELDS)
            self.assertEqual(state['MainPID'], '0')
            self.assertEqual(state['InvocationID'], '')
            self.assertEqual(state['ActiveState'], 'inactive')
            self.assertEqual(self.fresh_observer(), first)
            self.assertEqual(server.connections, 1)

    def test_failed_fence_barrier_sends_no_stop_or_go(self):
        with Server(self.cert, self.key) as server:
            self.start(server)
            with patch.object(lifecycle, 'publish', side_effect=OSError('fixture fsync failure')):
                with patch.object(lifecycle, 'run') as control:
                    with self.assertRaises(OSError): lifecycle.stop_and_observe(self.checkpoints)
                    control.assert_not_called()
            self.assertEqual(server.connections, 0)
            self.fresh_observer()

    def test_wrong_boot_and_changed_unit_source_cannot_stop_a_replacement(self):
        with Server(self.cert, self.key) as server:
            self.start(server)
            with patch.object(lifecycle, 'boot_id', return_value=str(uuid.uuid4())):
                observer = lifecycle.Observer(current_boot=lifecycle.boot_id)
                with patch.object(lifecycle, 'run') as control:
                    with self.assertRaises(ValueError): lifecycle.stop_and_observe(self.checkpoints, observer=observer)
                    control.assert_not_called()
            original = self.unit_paths[0].read_bytes()
            self.unit_paths[0].write_bytes(original + b'\n# changed fixture\n')
            try:
                with patch.object(lifecycle, 'run', wraps=lifecycle.run) as control:
                    with self.assertRaisesRegex(ValueError, 'unit_source_changed'):
                        lifecycle.stop_and_observe(self.checkpoints)
                    self.assertFalse(any(call.args[0][1] == 'stop' for call in control.call_args_list))
            finally:
                self.unit_paths[0].write_bytes(original)
            self.fresh_observer()

    def test_capture_checkpoint_failure_leaves_no_go(self):
        with Server(self.cert, self.key) as server:
            publish = common.publish
            def fail_capture(parent, name, value):
                if name == 'capture.json': raise OSError('fixture capacity failure')
                return publish(parent, name, value)
            with patch.object(common, 'publish', side_effect=fail_capture):
                with self.assertRaises(OSError): self.start(server)
            self.assertEqual(server.connections, 0)
            self.assertFalse((self.root / 'go.json').exists())
            self.assertFalse((self.checkpoints / 'capture.json').exists())


if __name__ == '__main__':
    unittest.main()
