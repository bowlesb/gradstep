"""Exact local child accounting only; no Deno, network, cgroup or SQL claims.

The parent operator runs these tests. This file does not make a verifier host
profile admissible. Test-owned IPC is closed here, never by Wait4Child.
"""
from contextlib import ExitStack
import gc
import math
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import weakref

import wait4_child as subject


PAUSED = "import os; os.write(1,b'R'); os.read(0,1)"


def read_exact(pipe, count, timeout=5):
    output = bytearray()
    deadline = time.monotonic() + timeout
    while len(output) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([pipe], [], [], remaining)[0]:
            raise AssertionError('fixture output deadline')
        chunk = os.read(pipe.fileno(), count - len(output))
        if not chunk:
            raise AssertionError('fixture output truncated')
        output.extend(chunk)
    return bytes(output)


def joined(owner, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = owner.observe()
        if result is not None:
            return result
        if owner.lost_authority:
            raise AssertionError('unexpected lost fixture wait authority')
        time.sleep(.005)
    raise AssertionError('fixture child retained after join deadline')


def usage_fixture(**changes):
    values = {name: 0 for name in subject._COUNTERS}
    values.update(ru_utime=.0011, ru_stime=.0022, ru_maxrss=4096)
    values.update(changes)
    return SimpleNamespace(**values)


@unittest.skipUnless(sys.platform in ('darwin', 'linux') and hasattr(os, 'wait4'),
                     'requires supported POSIX wait4')
class Wait4ChildTests(unittest.TestCase):
    def setUp(self):
        self.owners = []

    def tearDown(self):
        failures = []
        for owner in self.owners:
            try:
                if owner.retirement is None:
                    owner.signal(signal.SIGKILL)
                joined(owner)
            except Exception as error:
                failures.append(error)
            finally:
                for pipe in (owner.stdin, owner.stdout, owner.stderr):
                    if pipe is not None:
                        try:
                            pipe.close()
                        except OSError as error:
                            failures.append(error)
        if failures:
            # No unproven raw-PID or destructor cleanup on a failing fixture.
            raise AssertionError('fixture child/IPC unresolved; owner retained') from failures[0]

    def start(self, source=PAUSED, **kwargs):
        options = dict(stdin=subprocess.PIPE, env={'LC_ALL': 'C'})
        options.update(kwargs)
        try:
            owner = subject.Wait4Child.spawn([sys.executable, '-I', '-S', '-B', '-c', source], **options)
        except subject.SpawnError as error:
            self.owners.append(error.owner)
            raise
        self.owners.append(owner)
        return owner

    def test_real_wait4_rusage_is_exact_and_cached_copies_cannot_change_it(self):
        source = ("import os\npayload=bytearray(8*1024*1024)\n"
                  "total=sum(range(250000))\nos.write(1,b'OK')\n")
        actual_wait = os.wait4
        collected = []

        def record(pid, options):
            result = actual_wait(pid, options)
            if result[0]:
                collected.append(result)
            return result

        owner = self.start(source)
        with patch.object(subject.os, 'wait4', side_effect=record):
            result = joined(owner)
        self.assertEqual(read_exact(owner.stdout, 2), b'OK')
        self.assertEqual(len(collected), 1)
        pid, status, usage = collected[0]
        self.assertEqual((result['pid'], result['wait_status'], result['returncode']), (pid, status, 0))
        self.assertIsNone(result['metrics_error'])
        for name, number in result['rusage'].items():
            self.assertEqual(number, getattr(usage, name))
        scale = 1 if sys.platform == 'darwin' else 1024
        self.assertEqual(result['metrics']['peak_process_bytes'], usage.ru_maxrss * scale)
        self.assertEqual(result['metrics']['cpu_ms'],
                         math.ceil(usage.ru_utime * 1000) + math.ceil(usage.ru_stime * 1000))
        self.assertEqual(result['maxrss_unit'], 'bytes' if scale == 1 else 'KiB')
        self.assertFalse(owner.stdout.closed)  # IPC ownership remains with session.
        original = owner.retirement
        result['rusage']['ru_maxrss'] = 0
        result['metrics']['cpu_ms'] = -1
        with patch.object(subject.os, 'wait4', side_effect=AssertionError('second wait forbidden')):
            self.assertEqual(owner.observe(), original)
            self.assertEqual(owner.retirement, original)
            self.assertFalse(owner.signal(signal.SIGKILL))
        self.assertEqual(owner.evidence['retirement'], original)
        self.assertNotIn(id(owner), subject._RETAINED)

    def test_popen_reaping_and_signaling_methods_are_never_used(self):
        owner = self.start()
        self.assertEqual(read_exact(owner.stdout, 1), b'R')
        with ExitStack() as stack:
            for name in ('poll', 'wait', 'communicate', 'kill', 'terminate', 'send_signal',
                         '__enter__', '__exit__', '_internal_poll', '_wait'):
                stack.enter_context(patch.object(owner._popen, name,
                                    side_effect=AssertionError('Popen lifecycle forbidden')))
            self.assertIsNone(owner.observe())
            self.assertTrue(owner.signal(signal.SIGKILL))
            result = joined(owner)
            self.assertTrue(os.WIFSIGNALED(result['wait_status']))
            self.assertEqual(result['returncode'], -signal.SIGKILL)
            self.assertFalse(owner.signal(signal.SIGKILL))

    def test_output_eof_does_not_reap_or_claim_retirement(self):
        owner = self.start("import os; os.write(1,b'R'); os.close(1); os.read(0,1)")
        self.assertEqual(read_exact(owner.stdout, 1), b'R')
        self.assertTrue(select.select([owner.stdout], [], [], 5)[0])
        self.assertEqual(os.read(owner.stdout.fileno(), 1), b'')
        self.assertIsNone(owner.observe())
        self.assertIsNone(owner.retirement)
        self.assertTrue(owner.signal(signal.SIGKILL))
        self.assertEqual(joined(owner)['returncode'], -signal.SIGKILL)

    def test_readonly_stdin_and_one_inherited_control_pipe(self):
        with tempfile.TemporaryDirectory(prefix='wait4-child-') as root:
            path = Path(root) / 'readback.pdf'
            path.write_bytes(b'PDF')
            input_fd = os.open(path, os.O_RDONLY)
            control_read, control_write = os.pipe()
            try:
                source = ("import os; os.write(1,b'R'); "
                          f"assert os.read({control_read},1)==b'G'; "
                          "os.write(1,os.read(0,4))")
                owner = self.start(source, stdin=input_fd, pass_fds=(control_read,))
                self.assertIsNone(owner.stdin)
                self.assertEqual(read_exact(owner.stdout, 1), b'R')
                self.assertEqual(os.lseek(input_fd, 0, os.SEEK_CUR), 0)
                os.write(control_write, b'G')
                self.assertEqual(read_exact(owner.stdout, 3), b'PDF')
                self.assertEqual(joined(owner)['returncode'], 0)
                self.assertEqual(os.fstat(input_fd).st_size, 3)  # Borrowed FD not closed.
            finally:
                for fd in (input_fd, control_read, control_write):
                    os.close(fd)

    def test_invalid_rusage_keeps_real_terminal_status_and_never_waits_again(self):
        owner = self.start('raise SystemExit(7)')
        actual_wait = os.wait4

        def missing_usage(pid, options):
            waited, status, usage = actual_wait(pid, options)
            return waited, status, object() if waited else usage

        with patch.object(subject.os, 'wait4', side_effect=missing_usage):
            result = joined(owner)
        self.assertEqual(result['returncode'], 7)
        self.assertEqual(os.WEXITSTATUS(result['wait_status']), 7)
        self.assertEqual(result['metrics_error'], 'invalid_rusage')
        self.assertIsNone(result['metrics'])
        self.assertIsNone(result['rusage'])
        self.assertFalse(owner.lost_authority)
        with patch.object(subject.os, 'wait4', side_effect=AssertionError('already reaped')):
            self.assertEqual(owner.observe(), result)
            self.assertFalse(owner.signal(signal.SIGKILL))

    def test_resource_units_rounding_and_invalid_numbers(self):
        raw, mac = subject._usage(usage_fixture(), 'darwin')
        _, linux = subject._usage(usage_fixture(), 'linux')
        self.assertEqual(mac, {'cpu_ms': 5, 'peak_process_bytes': 4096})
        self.assertEqual(linux, {'cpu_ms': 5, 'peak_process_bytes': 4096 * 1024})
        self.assertEqual(raw['ru_utime'], .0011)
        for values in ({'ru_utime': float('nan')}, {'ru_stime': float('inf')},
                       {'ru_utime': True}, {'ru_stime': -1}, {'ru_maxrss': 0},
                       {'ru_maxrss': -1}, {'ru_maxrss': 10 ** 400}, {'ru_minflt': False}):
            with self.subTest(values=values), self.assertRaises(subject.Wait4Error):
                subject._usage(usage_fixture(**values), 'linux')

    def test_echild_forbids_signal_and_dropped_owner_cannot_destructor_poll(self):
        owner = self.start('raise SystemExit(0)')
        child = owner._popen
        # Deliberate ownership violation only in this fixture: another reaper
        # consumes the actual status, leaving Wait4Child unable to prove it.
        deadline = time.monotonic() + 5
        foreign_status = None
        while time.monotonic() < deadline:
            pid, status, _usage = os.wait4(owner.pid, os.WNOHANG)
            if pid:
                foreign_status = status
                break
            time.sleep(.005)
        self.assertIsNotNone(foreign_status)
        owner_id = id(owner)
        reference = weakref.ref(owner)
        try:
            self.assertIsNone(owner.observe())
            self.assertTrue(owner.lost_authority)
            self.assertEqual(owner.evidence['authority_error'], 'wait_authority_lost')
            with patch.object(subject.os, 'kill') as kill, patch.object(subject.os, 'wait4') as wait:
                self.assertFalse(owner.signal(signal.SIGKILL))
                self.assertIsNone(owner.observe())
                kill.assert_not_called()
                wait.assert_not_called()
            self.owners.remove(owner)
            with patch.object(child, '_internal_poll', side_effect=AssertionError('destructor poll')) as poll:
                del owner
                gc.collect()
                self.assertIsNotNone(reference())
                self.assertIs(subject._RETAINED[id(reference())], reference())
                poll.assert_not_called()
            owner = reference()
        finally:
            # Test-only disposal after the above independent real wait. This
            # is NOT an authority-recovery API and provides no owner evidence.
            child.returncode = os.waitstatus_to_exitcode(foreign_status)
            with subject._REGISTRY_LOCK:
                subject._RETAINED.pop(owner_id, None)
            retained = reference()
            if retained in self.owners:
                self.owners.remove(retained)
            for pipe in (child.stdin, child.stdout, child.stderr):
                if pipe is not None:
                    pipe.close()

    def test_dropped_live_owner_is_retained_until_its_actual_wait(self):
        owner = self.start()
        self.assertEqual(read_exact(owner.stdout, 1), b'R')
        reference = weakref.ref(owner)
        self.owners.remove(owner)
        with patch.object(owner._popen, '_internal_poll', side_effect=AssertionError('destructor poll')) as poll:
            del owner
            gc.collect()
            owner = reference()
            self.assertIsNotNone(owner)
            self.owners.append(owner)
            poll.assert_not_called()
            self.assertTrue(owner.signal(signal.SIGKILL))
            self.assertEqual(joined(owner)['returncode'], -signal.SIGKILL)

    def test_capacity_refuses_before_constructing_another_child(self):
        owner = self.start()
        self.assertEqual(read_exact(owner.stdout, 1), b'R')
        with patch.object(subject, 'MAX_RETAINED_CHILDREN', len(subject._RETAINED)), \
             patch.object(subject.subprocess.Popen, '__init__', side_effect=AssertionError('must not spawn')):
            with self.assertRaises(subject.Wait4Error) as raised:
                subject.Wait4Child.spawn([sys.executable, '-c', 'pass'], env={})
            self.assertEqual(raised.exception.code, 'owner_capacity')

    def test_postspawn_pipe_setup_failure_keeps_exact_accessible_owner(self):
        with patch.object(subject.os, 'set_blocking', side_effect=[None, OSError('private fixture text')]):
            with self.assertRaises(subject.SpawnError) as raised:
                self.start()
        owner = raised.exception.owner
        self.assertEqual(str(raised.exception), 'child_setup_failed')
        self.assertEqual(owner.pid, owner._popen.pid)
        self.assertIs(subject._RETAINED[id(owner)], owner)
        self.assertFalse(owner.lost_authority)
        self.assertEqual(read_exact(owner.stdout, 1), b'R')
        self.assertTrue(owner.signal(signal.SIGKILL))
        self.assertEqual(joined(owner)['returncode'], -signal.SIGKILL)

    def test_popen_initializer_failure_after_spawn_preserves_the_same_instance(self):
        initialize = subprocess.Popen.__init__
        captured = []

        def fail_after_spawn(child, *args, **kwargs):
            initialize(child, *args, **kwargs)
            captured.append(child)
            raise OSError('private constructor details')

        with patch.object(subject.subprocess.Popen, '__init__', fail_after_spawn):
            with self.assertRaises(subject.SpawnError) as raised:
                self.start()
        owner = raised.exception.owner
        self.assertIs(owner._popen, captured[0])
        self.assertEqual(owner.pid, captured[0].pid)
        self.assertEqual(str(raised.exception), 'child_setup_failed')
        self.assertEqual(read_exact(owner.stdout, 1), b'R')
        self.assertTrue(owner.signal(signal.SIGKILL))
        self.assertEqual(joined(owner)['returncode'], -signal.SIGKILL)

    def test_constructor_failure_before_any_child_does_not_consume_capacity(self):
        count = len(subject._RETAINED)
        with patch.object(subject.subprocess.Popen, '__init__', side_effect=OSError('private startup text')):
            with self.assertRaises(subject.SpawnError) as raised:
                subject.Wait4Child.spawn([sys.executable, '-c', 'pass'], env={})
        owner = raised.exception.owner
        self.assertIsNone(owner.pid)
        self.assertEqual(owner.evidence['authority_error'], 'not_started')
        self.assertIsNone(owner.observe())
        self.assertFalse(owner.signal(signal.SIGKILL))
        self.assertEqual(len(subject._RETAINED), count)
        self.assertEqual(str(raised.exception), 'child_setup_failed')

    def test_interrupted_wait_and_failed_signal_do_not_fabricate_retirement(self):
        owner = self.start()
        self.assertEqual(read_exact(owner.stdout, 1), b'R')
        with patch.object(subject.os, 'wait4', side_effect=InterruptedError):
            self.assertIsNone(owner.observe())
        self.assertFalse(owner.lost_authority)
        with patch.object(subject.os, 'kill', side_effect=PermissionError('private OS detail')):
            self.assertFalse(owner.signal(signal.SIGKILL))
        self.assertIsNone(owner.retirement)
        self.assertEqual(owner.evidence['signal_error'], 'signal_failed')
        self.assertTrue(owner.signal(signal.SIGKILL))
        self.assertEqual(joined(owner)['returncode'], -signal.SIGKILL)

    def test_explicit_environment_and_default_sigchld_are_required_before_spawn(self):
        with patch.object(subject.subprocess.Popen, '__init__', side_effect=AssertionError('must not spawn')):
            with self.assertRaises(subject.Wait4Error):
                subject.Wait4Child.spawn([sys.executable, '-c', 'pass'], env=None)
            with patch.object(subject.signals, 'getsignal', return_value=signal.SIG_IGN):
                with self.assertRaises(subject.Wait4Error) as raised:
                    subject.Wait4Child.spawn([sys.executable, '-c', 'pass'], env={})
                self.assertEqual(raised.exception.code, 'sigchld_owner_required')


if __name__ == '__main__':
    unittest.main()
