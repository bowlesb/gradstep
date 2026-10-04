"""Explicit, loopback-only UID separation tests in the existing marked guest."""
import errno
import grp
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

import common
import lifecycle
import package_prerequisite
from tls_fixture import Server, certificate
import uid_policy
import witness_slots

ENABLED = sys.platform == 'linux' and os.environ.get('TIMESTEP_LINUX_FIXTURE_RUN') == '1'
REQUEST = {'source_id': '1706.03762', 'revision': 1, 'stage': 'atom', 'byte_ceiling': 1_048_576}
ACCOUNTS = ((62401, 'timestep-supervisor'), (62402, 'timestep-source'))


def _account_command(arguments):
    require = common.require
    require(arguments[0] in ('groupadd', 'useradd', 'userdel', 'groupdel'), 'invalid_account_command')
    completed = subprocess.run(['/usr/sbin/' + arguments[0]] + arguments[1:], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
                               env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C'})
    require(completed.returncode == 0 and len(completed.stdout) + len(completed.stderr) < 4096,
            'fixture_account_operation_failed')


@unittest.skipUnless(ENABLED, 'requires opt-in inside the marked isolated Linux guest')
class PrerequisiteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.platform = lifecycle.preflight()
        cls.owned_accounts = []
        cls.roots = []
        # Never adopt/reconfigure a pre-existing name or UID, even if it looks similar.
        for number, name in ACCOUNTS:
            for lookup, key in ((pwd.getpwuid, number), (pwd.getpwnam, name),
                                (grp.getgrgid, number), (grp.getgrnam, name)):
                try:
                    lookup(key)
                except KeyError:
                    continue
                raise ValueError('fixture_account_collision')
        for number, name in ACCOUNTS:
            _account_command(['groupadd', '--gid', str(number), name])
            _account_command(['useradd', '--no-create-home', '--no-user-group', '--uid', str(number),
                              '--gid', str(number), '--home-dir', '/nonexistent', '--shell', '/usr/sbin/nologin',
                              '--password', '!', '--comment', 'Timestep isolated UID fixture', name])
            cls.owned_accounts.append((number, name))
        cls.certs = tempfile.TemporaryDirectory(prefix='timestep-uid-certificate-')
        cls.cert, cls.key = certificate(Path(cls.certs.name))
        cls.base = Path('/run/timestep-source-fixture')
        cls.base.mkdir(mode=0o755, exist_ok=True)
        bundles = Path('/run/timestep-prerequisite-bundles')
        bundles.mkdir(mode=0o755, exist_ok=True)
        for path in (cls.base, bundles):
            common.require(not path.is_symlink() and path.stat().st_uid == 0 and not path.stat().st_mode & 0o022,
                           'unowned_fixture_base')
        pending = bundles / ('capture-' + uuid.uuid4().hex)
        cls.manifest = package_prerequisite.build(pending)
        cls.bundle = bundles / lifecycle.digest(cls.manifest)
        common.require(not cls.bundle.exists(), 'bundle_collision')
        pending.rename(cls.bundle)

    @classmethod
    def tearDownClass(cls):
        # Never remove IDs or source identity while an uncertain unit is retained.
        common.require(not any(path.exists() for path in cls.roots), 'retained_fixture_requires_review')
        for number, name in reversed(cls.owned_accounts):
            account = pwd.getpwnam(name)
            common.require(account.pw_uid == number and account.pw_gid == number
                           and account.pw_shell == '/usr/sbin/nologin' and account.pw_dir == '/nonexistent',
                           'fixture_account_changed')
            _account_command(['userdel', name])
            # Ubuntu may remove this exact otherwise-unused matching group.
            try:
                group = grp.getgrnam(name)
            except KeyError:
                pass
            else:
                common.require(group.gr_gid == number and group.gr_mem == [], 'fixture_group_changed')
                _account_command(['groupdel', name])
        cls.bundle.chmod(0o755)
        shutil.rmtree(cls.bundle)
        cls.certs.cleanup()

    def setUp(self):
        self.attempt = str(uuid.uuid4())
        self.service, self.slice, root = lifecycle.names(self.attempt)
        self.root = Path(root); self.root.mkdir(mode=0o755)
        self.roots.append(self.root)
        for name, mode, owner in (('control', 0o750, 0), ('data', 0o700, 62401),
                                  ('ingress', 0o700, 62401), ('guardian', 0o700, 0), ('observer', 0o700, 0)):
            path = self.root / name; path.mkdir(mode=mode)
            os.chown(path, owner, 62401 if name == 'control' else owner)
        common.publish(self.root / 'observer', 'private.json', {'fixture': 'no credential exists'})
        self.variant = 'normal'
        self.units = []
        self.installed = False
        self.observer = lifecycle.Observer(current_process=self.process, unit_renderer=self.render,
                                             expected_uid=62402, ready_mode='linux_uid_ingress_fixture')

    def process(self, pid):
        checked = uid_policy.checked_status(pid, 62402)
        value = lifecycle.process(pid)
        value['uid'] = checked['uids'][0]
        return value

    def render(self, attempt):
        service, slice_name, root = lifecycle.names(attempt)
        result = {}
        for suffix, name in (('service', service), ('slice', slice_name)):
            raw = (self.bundle / ('prerequisite.' + suffix + '.in')).read_text()
            raw = raw.replace('@ATTEMPT@', attempt).replace('@ROOT@', root).replace('@SLICE@', slice_name)
            raw = raw.replace('@BUNDLE@', str(self.bundle))
            if self.variant == 'probe': raw = raw.replace('linux_launcher ', 'linux_probe_launcher ')
            if self.variant == 'missing_cap': raw = raw.replace('CAP_SETUID CAP_SETGID CAP_SETPCAP', 'CAP_SETUID CAP_SETGID')
            common.require('@' not in raw, 'unexpanded_template')
            result[name] = raw.encode()
        return result

    def tearDown(self):
        if not self.installed:
            shutil.rmtree(self.root)
            return
        fence = self.root / 'observer' / 'stop-fence.json'
        if not fence.exists():
            common.publish(fence.parent, fence.name, {'schema_version': 1, 'kind': 'fixture_cleanup_fence_v1',
                                                      'attempt_id': self.attempt})
        common.durable_read(fence)
        def remove():
            for path in self.units: path.unlink()
            lifecycle.run(['/usr/bin/systemctl', 'daemon-reload'])
            for name in (self.service, self.slice):
                try: lifecycle.run(['/usr/bin/systemctl', 'reset-failed', name])
                except ValueError: pass
            shutil.rmtree(self.root)
        lifecycle.stop_before_cleanup(self.attempt, remove, unit_renderer=self.render)

    def wait_file(self, directory, name, seconds=5):
        limit = time.monotonic() + seconds
        while time.monotonic() < limit:
            path = self.root / directory / name
            if path.exists():
                return common.decode(common.read(path, witness_slots.MAX_OUTPUT))
            time.sleep(.01)
        self.fail('missing ' + directory + '/' + name + '; ' +
                  json.dumps(lifecycle.show(self.service, lifecycle.SERVICE_FIELDS + ('ExecMainCode', 'ExecMainStatus'))))

    def start(self, server, *, variant='normal'):
        self.variant = variant
        common.publish(self.root / 'control', 'input.json', {'schema_version': 1, 'mode': 'linux_uid_ingress_fixture',
                        'attempt_id': self.attempt, 'request': REQUEST, 'fixture': server.fixture})
        (self.root / 'control' / 'input.json').chmod(0o440)
        os.chown(self.root / 'control' / 'input.json', 0, 62401)
        common.publish(self.root / 'observer', 'capacity.json', witness_slots.reservation(self.manifest['source_bytes']))
        for name, raw in self.render(self.attempt).items():
            path = Path('/run/systemd/system') / name
            with path.open('xb') as stream:
                stream.write(raw); stream.flush(); os.fsync(stream.fileno())
            path.chmod(0o444); self.units.append(path)
        self.installed = True
        lifecycle.run(['/usr/bin/systemctl', 'daemon-reload'])
        lifecycle.run(['/usr/bin/systemctl', 'start', self.slice, self.service])
        if variant != 'normal': return None
        ready = self.wait_file('data', 'ready.json')
        supervisor = uid_policy.checked_status(ready['controller_pid'], 62401)
        self.assertEqual(supervisor['caps'], {key: 0 for key in uid_policy.CAP_FIELDS})
        self.capture = self.observer.capture(self.attempt, ready)
        common.publish(self.root / 'observer', 'capture.json', self.capture)
        return ready

    def go(self, ready):
        common.publish(self.root / 'control', 'go.json', {'mode': 'linux_uid_ingress_fixture',
                       'attempt_id': self.attempt, 'child_id': ready['child_id'],
                       'bundle_sha256': ready['bundle_sha256']})
        path = self.root / 'control' / 'go.json'; path.chmod(0o440); os.chown(path, 0, 62401)

    def retire(self):
        value = lifecycle.stop_and_observe(self.root / 'observer', observer=self.observer)
        self.assertEqual(value['kind'], 'fixture_cgroup_empty_v1')
        self.assertFalse(value['sql_receipt_authority'])
        return value

    def test_real_split_uid_normal_join_and_large_witness(self):
        body = b'x' * 1_048_576
        with Server(self.cert, self.key, body=body) as server:
            ready = self.start(server)
            privileges = self.wait_file('data', 'privileges.json')
            self.assertEqual(privileges['cross_uid_signal_errno'], errno.EPERM)
            self.assertEqual(privileges['supervisor']['dumpable'], 0)
            self.go(ready)
            report = self.wait_file('ingress', 'witness.json')
            self.assertIs(report['owned_process_retired'], True)
            self.assertEqual(report['retirement_witness'], 'parent_waitpid')
            self.assertEqual(report['returncode'], 0)
            self.assertEqual(report['identity'], ready['identity'])
            self.assertEqual(report['source_sha256'], ready['source_sha256'])
            self.assertEqual(report['result']['body_bytes'], len(body))
            self.assertEqual(report['result']['body_sha256'], hashlib.sha256(body).hexdigest())
            expected = common.canonical(report)
            def validate(raw): common.require(raw == expected, 'fixture_witness_changed')
            retained = witness_slots.recover(self.root / 'ingress', self.root / 'guardian', validate)
            self.assertEqual(retained, expected)
            self.assertEqual(server.connections, 1)
            self.retire()

    def test_actual_kernel_denials_and_zero_capability_sets(self):
        with Server(self.cert, self.key) as server:
            self.start(server, variant='probe')
            result = self.wait_file('data', 'probe.json')
            self.assertEqual(result['supervisor']['uids'], [62401] * 4)
            self.assertEqual(result['source']['identity']['uids'], [62402] * 4)
            self.assertEqual(set(result['source']['checks']), {'setresuid_root', 'setresgid_root',
                'supplementary_groups', 'securebits_unlock', 'ambient_raise', 'guardian_path',
                'supervisor_control', 'supervisor_fd', 'cgroup_write', 'unix_socket', 'socketpair',
                'io_uring_setup', 'io_uring_enter', 'io_uring_register', 'ptrace', 'process_vm_readv',
                'process_vm_writev', 'pidfd_getfd', 'extra_task'})
            self.assertEqual(server.connections, 0)

    def test_incorrect_bootstrap_capabilities_never_read_input_or_open_socket(self):
        with Server(self.cert, self.key) as server:
            self.start(server, variant='missing_cap')
            limit = time.monotonic() + 3
            while time.monotonic() < limit:
                state = lifecycle.show(self.service, lifecycle.SERVICE_FIELDS)
                if state['ActiveState'] == 'failed': break
                time.sleep(.01)
            self.assertEqual(state['ActiveState'], 'failed')
            self.assertEqual(list((self.root / 'data').iterdir()), [])
            self.assertEqual(list((self.root / 'ingress').iterdir()), [])
            self.assertEqual(server.connections, 0)

    def test_cancellation_cannot_signal_child_guardian_retires_populated_scope(self):
        with Server(self.cert, self.key, slow=True) as server:
            ready = self.start(server); self.go(ready)
            self.assertTrue(server.requested.wait(3))
            os.kill(ready['identity']['process_id'], signal.SIGSTOP)
            common.publish(self.root / 'control', 'stop.json', {'fixture': True})
            path = self.root / 'control' / 'stop.json'; path.chmod(0o440); os.chown(path, 0, 62401)
            report = self.wait_file('ingress', 'witness.json')
            self.assertIs(report['owned_process_retired'], False)
            self.assertIsNone(report['retirement_witness'])
            self.assertIsNone(report['result'])
            self.assertEqual(lifecycle.cgroup_snapshot('/' + self.slice)['populated'], 1)
            self.retire()
            self.assertEqual(server.connections, 1)

    def test_lost_supervisor_has_only_scope_evidence_and_fence_blocks_restart(self):
        with Server(self.cert, self.key, slow=True) as server:
            ready = self.start(server); self.go(ready)
            self.assertTrue(server.requested.wait(3))
            os.kill(ready['controller_pid'], signal.SIGKILL)
            self.retire()
            self.assertFalse((self.root / 'ingress' / 'witness.json').exists())
            lifecycle.run(['/usr/bin/systemctl', 'start', self.service])
            self.assertEqual(lifecycle.show(self.service, lifecycle.SERVICE_FIELDS)['MainPID'], '0')
            self.assertEqual(server.connections, 1)


if __name__ == '__main__':
    unittest.main()
