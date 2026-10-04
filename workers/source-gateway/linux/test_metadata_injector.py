"""Portable fault-injector checks: mocked pidfds/systemd; no signal, SQL or TLS."""
from contextlib import ExitStack
import copy
import os
from pathlib import Path
import signal
import stat
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import Mock, patch

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent)]
import test_metadata_integration as fixture
import test_metadata_scope as scope_fixture


class FaultTargetTests(unittest.TestCase):
    def setUp(self):
        self.kernel = scope_fixture.MetadataScopeTests()
        self.kernel.setUp(); self.addCleanup(self.kernel.tearDown)
        k = self.kernel
        k.request['source_id'] = fixture.SOURCE
        k.ready['source_sha256'] = fixture.database.sha(fixture.database.canonical(k.request))
        k.capture, k.binding = k.scope.capture(k.job, k.claim, k.request, k.ready, k.authority)
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name).resolve()
        layout = {leaf: root / leaf for leaf in ('records', 'control', 'data')}
        for leaf, path in layout.items(): path.mkdir(mode=0o750 if leaf == 'control' else 0o700)
        self.units = {Path('/run/systemd/system') / name: raw for name, raw in k.render(k.claim).items()}
        self.action = types.SimpleNamespace(claim=k.claim, layout=layout, manifest=k.manifest,
                                           render=k.render, units=self.units, service=k.service, slice=k.slice)
        self.execution = {'id': str(fixture.uuid.uuid4()), 'job_id': k.job, 'claim_id': k.claim, 'generation': 1,
            'kind': 'atom', 'epoch': k.binding['epoch'], 'policy_id': k.binding['policy_id'],
            'binding': k.binding, 'binding_sha256': 'a' * 64, 'byte_ceiling': 1_048_576}
        go = {'schema_version': 1, 'kind': 'linux_metadata_go_v1', 'scope_id': k.claim,
            **{key: k.ready[key] for key in ('child_id', 'bundle_sha256', 'source_sha256')},
            'execution_id': self.execution['id'], 'deadline_ns': str(fixture.clock_ns() + 25_000_000_000)}
        self.records = {'capture.json': k.capture, 'ready.json': k.ready,
            'stop-fence.json': {'schema_version': 1, 'kind': 'linux_metadata_stop_fence_v1', 'scope_id': k.claim,
                                'capture_sha256': fixture.database.sha(fixture.database.canonical(k.capture))},
            'go.json': go, 'go-intent.json': go, 'grant.json': {'response': {'granted': True,
                'action': 'perform_stage', 'execution': self.execution, 'job': dict(k.request, kind='lookup',
                    requested_revision=1)}}}
        for name in self.records: self.write(name)
        self.stack = ExitStack(); self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(fixture, 'trusted_directory'))
        self.stack.enter_context(patch.object(fixture, 'cleanup_identity', side_effect=lambda leaf:
            (os.getuid(), os.getgid(), 0o750 if leaf == 'control' else 0o700)))
        self.stack.enter_context(patch.object(fixture.lifecycle, 'boot_id', return_value=k.boot))
        self.status = self.stack.enter_context(patch.object(fixture.uid_policy, 'checked_status'))
        self.process = self.stack.enter_context(patch.object(fixture.lifecycle, 'process', return_value=k.processes[400]))
        self.unit = self.stack.enter_context(patch.object(fixture.lifecycle, 'show', return_value=dict(k.service_state, SourcePath='')))
        original = Path.lstat
        self.stack.enter_context(patch.object(Path, 'lstat', autospec=True, side_effect=lambda path:
            types.SimpleNamespace(st_gid=0, st_mode=stat.S_IFREG | 0o644) if path in self.units else original(path)))
        self.unit_read = self.stack.enter_context(patch.object(fixture.database, 'read_file',
            side_effect=lambda path, maximum: self.units[path]))

    def write(self, name):
        leaf = fixture.RECORDS[name][0]
        path = self.action.layout[leaf] / name
        path.write_bytes(fixture.database.canonical(self.records[name]))
        path.chmod(0o640 if leaf == 'control' else 0o600)

    def test_exact_capture_go_grant_and_live_identity_are_bound(self):
        target = fixture.fault_target(self.action, self.kernel.job)
        self.assertEqual(target['supervisor'], self.kernel.capture['supervisor'])
        self.assertEqual(target['execution_id'], self.execution['id'])
        self.assertEqual(self.status.call_args_list, [unittest.mock.call(400, 62401)] * 2)
        self.assertEqual(target['capture_sha256'], self.kernel.binding['scope']['capture_sha256'])

    def test_changed_process_unit_go_and_source_binding_refuse(self):
        for change in ('start', 'group', 'uid', 'pid', 'invocation', 'dropin', 'unit', 'expired', 'go', 'source', 'boot'):
            with self.subTest(change=change), ExitStack() as context:
                if change in ('start', 'group'):
                    context.enter_context(patch.object(fixture.lifecycle, 'process', return_value=dict(
                        self.kernel.processes[400], **({'process_start_id': 'other'} if change == 'start' else {'cgroup': '/other'}))))
                elif change == 'uid': context.enter_context(patch.object(fixture.uid_policy, 'checked_status', side_effect=ValueError('uid')))
                elif change in ('pid', 'invocation', 'dropin'):
                    key = {'pid': 'MainPID', 'invocation': 'InvocationID', 'dropin': 'DropInPaths'}[change]
                    context.enter_context(patch.object(fixture.lifecycle, 'show', return_value=dict(self.unit.return_value, **{key: 'other'})))
                elif change == 'unit': context.enter_context(patch.object(fixture.database, 'read_file', return_value=b'changed'))
                elif change == 'boot': context.enter_context(patch.object(fixture.lifecycle, 'boot_id', return_value='other'))
                else:
                    records = copy.deepcopy(self.records)
                    if change == 'expired':
                        records['go.json']['deadline_ns'] = '1'
                        records['go-intent.json']['deadline_ns'] = '1'
                    elif change == 'go': records['go.json']['execution_id'] = str(fixture.uuid.uuid4())
                    else: records['grant.json']['response']['job']['source_id'] = '1706.03762'
                    prior, self.records = self.records, records
                    for name in records: self.write(name)
                with self.assertRaises(ValueError): fixture.fault_target(self.action, self.kernel.job)
                if change in ('expired', 'go', 'source'):
                    self.records = prior
                    for name in prior: self.write(name)


class InjectorTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.target = {'supervisor': {'process_id': 123, 'process_start_id': '9001'},
                       'execution_id': 'execution', 'scope_id': 'scope'}
        self.server = types.SimpleNamespace(headers_sent=threading.Event(), requested=threading.Event(),
                                            slow=True, connections=1)
        self.server.headers_sent.set(); self.server.requested.set()
        self.capture = self.stack.enter_context(patch.object(fixture, 'fault_target', return_value=self.target))
        self.open = self.stack.enter_context(patch.object(os, 'pidfd_open', create=True, return_value=91))
        self.signal = self.stack.enter_context(patch.object(signal, 'pidfd_send_signal', create=True))
        self.close = self.stack.enter_context(patch.object(os, 'close'))
        self.poll = self.stack.enter_context(patch.object(fixture.select, 'select',
            side_effect=[([], [], []), ([], [], []), ([91], [], [])]))
        self.record = Mock()
        self.action = types.SimpleNamespace(claim='claim')
        self.injector = fixture.SupervisorDeath(self.server, self.action, 'job', self.record)

    def test_one_pidfd_signal_follows_three_checks_and_durable_intent(self):
        def signal_once(fd, sig, info, flags):
            self.assertEqual(self.capture.call_count, 3)
            self.assertEqual(self.record.call_args_list[0].args, ('fault-intent.json', self.target))
            self.assertEqual((fd, sig, info, flags), (91, signal.SIGKILL, None, 0))
        self.signal.side_effect = signal_once
        self.injector.inject()
        self.assertIsNone(self.injector.error)
        self.open.assert_called_once_with(123, 0)
        self.signal.assert_called_once()
        self.close.assert_called_once_with(91)
        outcome = self.record.call_args_list[1].args
        self.assertEqual(outcome[0], 'fault-outcome.json')
        self.assertIs(outcome[1]['pidfd_exit_observed'], True)
        self.assertIs(outcome[1]['new_retirement_receipt'], False)

    def test_target_drift_after_open_or_after_intent_never_signals(self):
        for sequence in ([self.target, dict(self.target, scope_id='changed')],
                         [self.target, self.target, dict(self.target, scope_id='changed')]):
            self.capture.side_effect = sequence
            self.poll.side_effect = [([], [], []), ([], [], []), ([91], [], [])]
            self.record.reset_mock(); self.close.reset_mock(); self.signal.reset_mock()
            injector = fixture.SupervisorDeath(self.server, self.action, 'job', self.record)
            injector.inject()
            self.assertIsInstance(injector.error, ValueError)
            self.signal.assert_not_called(); self.close.assert_called_once_with(91)
            self.assertIsNone(injector.outcome)

    def test_durability_error_and_cancellation_after_intent_do_not_signal(self):
        for failure in ('fsync', 'cancel'):
            injector = fixture.SupervisorDeath(self.server, self.action, 'job', self.record)
            def record(*args):
                if failure == 'fsync': raise OSError('durability')
                injector.cancel.set()
            self.record.side_effect = record
            self.poll.side_effect = [([], [], []), ([], [], []), ([91], [], [])]
            self.close.reset_mock(); self.signal.reset_mock()
            injector.inject()
            self.assertIsInstance(injector.error, (OSError, ValueError))
            self.signal.assert_not_called(); self.close.assert_called_once_with(91)

    def test_missing_pidfd_and_exited_target_have_no_numeric_pid_fallback(self):
        with patch.object(os, 'pidfd_open', None):
            with self.assertRaisesRegex(ValueError, 'pidfd_required'):
                fixture.SupervisorDeath(self.server, self.action, 'job', self.record)
        self.poll.side_effect = [([91], [], [])]
        self.injector.inject()
        self.assertIsInstance(self.injector.error, ValueError)
        self.signal.assert_not_called(); self.record.assert_not_called()
        self.close.assert_called_once_with(91)
        self.open.side_effect = ProcessLookupError('already gone')
        self.close.reset_mock()
        injector = fixture.SupervisorDeath(self.server, self.action, 'job', self.record)
        injector.inject()
        self.assertIsInstance(injector.error, ProcessLookupError)
        self.signal.assert_not_called(); self.close.assert_not_called()

    def test_headers_barrier_and_signal_error_are_not_reported_as_success(self):
        self.server.headers_sent.clear()
        self.injector.cancel.set()
        self.injector.inject()
        self.assertIsInstance(self.injector.error, ValueError)
        self.open.assert_not_called()
        self.server.headers_sent.set()
        injector = fixture.SupervisorDeath(self.server, self.action, 'job', self.record)
        self.signal.side_effect = ProcessLookupError('exited before signal')
        injector.inject()
        self.assertIsInstance(injector.error, ProcessLookupError)
        self.assertIsNone(injector.outcome)
        self.assertEqual(self.record.call_count, 1)  # Intent only, never a completion.

    def test_error_is_propagated_after_join(self):
        self.capture.side_effect = ValueError('wrong invocation')
        with self.assertRaisesRegex(ValueError, 'wrong invocation'):
            with self.injector:
                self.injector.thread.join(1)
        self.assertFalse(self.injector.thread.is_alive())
        self.signal.assert_not_called()

    def test_cancel_and_signal_share_the_final_decision_lock(self):
        entered, release, exited = threading.Event(), threading.Event(), threading.Event()
        calls, errors = [], []
        def capture(*_):
            calls.append('check')
            if len(calls) == 3:
                entered.set()
                if not release.wait(1): raise ValueError('test release timeout')
            return self.target
        self.capture.side_effect = capture
        self.injector.__enter__()
        self.assertTrue(entered.wait(1))
        def close():
            try: self.injector.__exit__(None, None, None)
            except BaseException as error: errors.append(error)
            finally: exited.set()
        closer = threading.Thread(target=close)
        closer.start()
        try:
            self.assertFalse(exited.wait(.03))
            self.assertFalse(self.injector.cancel.is_set())
        finally:
            release.set(); closer.join(2); self.injector.thread.join(2)
        self.assertFalse(closer.is_alive()); self.assertFalse(self.injector.thread.is_alive())
        self.assertEqual(errors, [])
        self.signal.assert_called_once_with(91, signal.SIGKILL, None, 0)
        self.assertTrue(self.injector.cancel.is_set())


class HeadersSentTests(unittest.TestCase):
    def server(self, *, fail=False):
        server = fixture.Server.__new__(fixture.Server)
        server.requested, server.headers_sent, server.ended, server.stop = (threading.Event() for _ in range(4))
        server.connections, server.error, server.body, server.slow = 0, None, b'body', True
        tls, connection = Mock(), Mock()
        source = list(bytes([x]) for x in b'GET / HTTP/1.1\r\nHost: fixture\r\n\r\n') + [b'']
        tls.recv.side_effect = source
        def sent(raw):
            self.assertTrue(server.requested.is_set())
            self.assertFalse(server.headers_sent.is_set())
            self.assertTrue(raw.endswith(b'\r\n\r\n'))  # Body withheld.
            if fail: raise OSError('send failed')
        tls.sendall.side_effect = sent
        server.listener = Mock(); server.listener.accept.return_value = (connection, None)
        server.context = Mock(); server.context.wrap_socket.return_value = tls
        return server

    def test_barrier_means_headers_send_returned_not_only_get_received(self):
        for fail in (False, True):
            with self.subTest(fail=fail):
                server = self.server(fail=fail)
                server.serve()
                self.assertTrue(server.requested.is_set())
                self.assertEqual(server.headers_sent.is_set(), not fail)
                self.assertEqual(server.connections, 1)

    def test_scenario_is_exact_and_normal_remains_default(self):
        with patch.dict(os.environ, {}, clear=True): self.assertEqual(fixture.selected_scenario(), 'normal')
        with patch.dict(os.environ, {'TIMESTEP_METADATA_SCENARIO': 'supervisor_death'}, clear=True):
            self.assertEqual(fixture.selected_scenario(), 'supervisor_death')
        for bad in ('', 'all', 'normal,supervisor_death', 'SUPERVISOR_DEATH'):
            with patch.dict(os.environ, {'TIMESTEP_METADATA_SCENARIO': bad}, clear=True):
                with self.assertRaises(ValueError): fixture.selected_scenario()


if __name__ == '__main__':
    unittest.main(verbosity=2)
