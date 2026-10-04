"""Local failure-boundary tests; no source, SQL, or provider traffic."""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

import journal
from protocol import Refused, canonical, digest, clock_ns, clock_name

# These pure validator tests need no launched/frozen coordinator.
sys.modules.setdefault('frozen_context', types.ModuleType('frozen_context'))
from integrate import checked_witness, grant_deadlines, instant


class CoordinationTests(unittest.TestCase):
    def test_published_checkpoint_requires_new_durable_barrier_on_reopen(self):
        with tempfile.TemporaryDirectory() as temporary:
            saved = journal.Journal(temporary)
            path = saved.path
            actual = os.fsync

            def failing_directory(fd):
                if stat.S_ISDIR(os.fstat(fd).st_mode):
                    raise OSError('fixture fsync failure')
                actual(fd)

            with mock.patch.object(journal.os, 'fsync', failing_directory):
                with self.assertRaises(OSError):
                    saved.put('executor.json', {'receipt': 'unchanged'})
                self.assertTrue((path / 'executor.json').exists())
                with self.assertRaises(OSError):
                    journal.Journal.existing(path)
            saved.close()
            observed = []

            def tracked(fd):
                observed.append('directory' if stat.S_ISDIR(os.fstat(fd).st_mode) else 'file')
                actual(fd)

            with mock.patch.object(journal.os, 'fsync', tracked):
                recovered = journal.Journal.existing(path)
                self.assertEqual(recovered.read('executor.json'), {'receipt': 'unchanged'})
                recovered.put('executor.json', {'receipt': 'unchanged'})
                recovered.close()
            self.assertEqual(observed, ['file', 'directory'])

    def test_reopen_refuses_unfinished_temporary_files_and_overflow(self):
        for mode in ('temporary', 'files', 'bytes'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                saved = journal.Journal(temporary)
                path = saved.path
                saved.close()
                if mode == 'temporary':
                    (path / '.pending-fixture').write_bytes(b'{}')
                elif mode == 'files':
                    for index in range(journal.MAX_FILES + 1):
                        (path / ('f' + str(index) + '.json')).write_bytes(b'{}')
                else:
                    with (path / 'large.json').open('wb') as output:
                        output.truncate(journal.MAX_FILE + 1)
                for entry in path.iterdir():
                    entry.chmod(0o600)
                with self.assertRaises(Refused):
                    journal.Journal.existing(path)

    def test_existing_checkpoint_cannot_change_after_open(self):
        with tempfile.TemporaryDirectory() as temporary:
            saved = journal.Journal(temporary)
            saved.put('receipt.json', {'one': 1})
            saved.close()
            recovered = journal.Journal.existing(saved.path)
            (saved.path / 'receipt.json').write_bytes(b'{"two":2}')
            try:
                with self.assertRaises(Refused):
                    recovered.read('receipt.json')
            finally:
                recovered.close()

    def test_witness_types_and_disposition_are_not_truthy(self):
        request = {'source_id': '2403.81001', 'revision': 1, 'stage': 'atom', 'byte_ceiling': 1048576}
        binding = {'child_id': '00000000-0000-0000-0000-000000000001', 'boot_id': 'boot',
                   'process_id': 123, 'process_start_id': '456'}
        execution = {'id': '00000000-0000-0000-0000-000000000002'}
        witness = {'schema_version': 1, 'outcome': 'stopped', 'identity': {
            key: binding[key] for key in ('boot_id', 'process_id', 'process_start_id')},
            'child_id': binding['child_id'], 'source_sha256': digest(canonical(request)),
            'execution_id': None, 'sent_go': False, 'returncode': -9, 'owned_process_retired': True,
            'retirement_witness': 'parent_waitpid', 'disposition': 'killed', 'result': None}
        self.assertIs(checked_witness(witness, binding, request, execution), witness)
        for key, value in (('owned_process_retired', 'false'), ('returncode', True), ('sent_go', 0),
                           ('retirement_witness', 'pid_absent'), ('disposition', 'exited'),
                           ('schema_version', True), ('source_sha256', '0' * 64), ('identity', {})):
            with self.subTest(key=key), self.assertRaises(Refused):
                checked_witness(dict(witness, **{key: value}), binding, request, execution)

    def test_deadlines_use_database_duration_and_pre_rpc_monotonic_origin(self):
        execution = {'created_at': '2001-01-01T00:00:00Z', 'useful_deadline': '2001-01-01T00:00:30Z',
                     'report_deadline': '2001-01-01T00:01:00Z'}
        self.assertEqual(grant_deadlines(execution, 123), (30_000_000_123, 60_000_000_123))
        with self.assertRaises(Refused):
            grant_deadlines(dict(execution, useful_deadline='2000-12-31T23:59:59Z'), 123)

    def test_postgres_fractional_seconds_work_on_python39(self):
        for digits in ('1', '12', '123', '1234', '12345', '123456'):
            with self.subTest(digits=digits):
                self.assertEqual(instant('2026-10-03T12:34:56.' + digits + '+00:00').microsecond,
                                 int(digits.ljust(6, '0')))

    def test_kernel_clock_domain_is_shared_by_an_actual_child(self):
        before = clock_ns()
        raw = subprocess.check_output([sys.executable, '-I', '-S', '-B', '-c',
                                       'import time;print(time.clock_gettime_ns(time.' + clock_name() + '))'],
                                      timeout=2, env={'LC_ALL': 'C'})
        after = clock_ns()
        self.assertLessEqual(before, int(raw))
        self.assertLessEqual(int(raw), after)

    def test_unreviewed_clock_platform_refuses(self):
        with mock.patch('protocol.sys.platform', 'unsupported-fixture'):
            with self.assertRaises(Refused):
                clock_ns()


if __name__ == '__main__':
    unittest.main()
