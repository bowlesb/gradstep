import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import sys

import witness_slots as slots


class WitnessSlotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.ingress = self.root / 'ingress'; self.ingress.mkdir(mode=0o700)
        self.guardian = self.root / 'guardian'; self.guardian.mkdir(mode=0o700)
        self.body = b'x' * slots.MAX_OUTPUT
        self.expected = hashlib.sha256(self.body).digest()

    def tearDown(self):
        self.temp.cleanup()

    def validate(self, raw):
        if hashlib.sha256(raw).digest() != self.expected:
            raise ValueError('invalid_fixture_body')

    def recover(self, **kwargs):
        return slots.recover(self.ingress, self.guardian, self.validate,
                             producer_uid=os.getuid(), guardian_uid=os.getuid(), **kwargs)

    def test_large_witness_moves_once_and_replay_reuses_final_inode(self):
        slots.publish_ingress(self.ingress, self.body)
        self.assertEqual(self.recover(), self.body)
        inode = (self.guardian / slots.FINAL).stat().st_ino
        self.assertEqual(self.recover(), self.body)
        self.assertEqual((self.guardian / slots.FINAL).stat().st_ino, inode)
        self.assertEqual(list(self.ingress.iterdir()), [])

    def test_each_interrupted_publication_reuses_two_slots_and_same_pending_inode(self):
        for event in ('copy_chunk', 'file_fsynced', 'final_linked', 'directory_fsynced', 'before_ingress_unlink'):
            with self.subTest(event=event):
                for folder in (self.ingress, self.guardian):
                    for path in folder.iterdir(): path.unlink()
                slots.publish_ingress(self.ingress, self.body)
                observed = []
                def fail(step):
                    observed.append(slots.usage((self.ingress, self.guardian)))
                    if step == event: raise OSError('fixture interrupted')
                with self.assertRaises(OSError): self.recover(hook=fail)
                pending = self.guardian / slots.PENDING
                original_inode = pending.stat().st_ino if pending.exists() else (self.guardian / slots.FINAL).stat().st_ino
                self.assertEqual(self.recover(), self.body)
                self.assertEqual((self.guardian / slots.FINAL).stat().st_ino, original_inode)
                self.assertLessEqual(max(x['bytes'] for x in observed), 2 * slots.MAX_OUTPUT)
                # The zero-byte lock is another inode, not a body slot.
                self.assertLessEqual(max(x['inodes'] for x in observed), 3)

    def test_reopen_fsync_failure_never_returns_a_durable_witness(self):
        slots.publish_ingress(self.ingress, self.body)
        def fail(step):
            if step == 'final_linked': raise OSError('link visible, barrier failed')
        with self.assertRaises(OSError): self.recover(hook=fail)
        with patch.object(slots.os, 'fsync', side_effect=OSError('still not durable')):
            with self.assertRaises(OSError): self.recover()
        self.assertTrue((self.ingress / slots.FINAL).exists())
        self.assertEqual(self.recover(), self.body)

    def test_actual_writer_exit_and_fresh_process_recovery_do_not_allocate_a_third_body(self):
        # Terminate without finally/close to test kernel lock release and a new
        # process reopening exact retained slots, separately from fsync faults.
        script = '''import hashlib,os,pathlib,sys
sys.path.insert(0,sys.argv[1]);import witness_slots as slots
def validate(raw):
 if hashlib.sha256(raw).hexdigest()!=sys.argv[4]:raise ValueError('fixture digest')
def stop(step):
 if step==sys.argv[5]:os._exit(71)
raw=slots.recover(sys.argv[2],sys.argv[3],validate,producer_uid=os.getuid(),guardian_uid=os.getuid(),hook=stop)
print(hashlib.sha256(raw).hexdigest())
'''
        for event in ('copy_chunk', 'final_linked', 'directory_fsynced', 'before_ingress_unlink'):
            with self.subTest(event=event):
                for folder in (self.ingress, self.guardian):
                    for path in folder.iterdir(): path.unlink()
                slots.publish_ingress(self.ingress, self.body)
                command = [sys.executable, '-I', '-S', '-B', '-c', script,
                           str(Path(slots.__file__).parent), str(self.ingress), str(self.guardian),
                           self.expected.hex(), event]
                stopped = subprocess.run(command, capture_output=True, env={'LC_ALL': 'C'}, timeout=3)
                self.assertEqual(stopped.returncode, 71, stopped.stderr)
                self.assertEqual(stopped.stdout, b'')
                candidate = self.guardian / slots.FINAL
                if not candidate.exists(): candidate = self.guardian / slots.PENDING
                inode = candidate.stat().st_ino
                self.assertLessEqual(slots.usage((self.ingress, self.guardian))['bytes'], 2 * slots.MAX_OUTPUT)
                command[-1] = 'no_interruption'
                recovered = subprocess.run(command, capture_output=True, env={'LC_ALL': 'C'}, timeout=3)
                self.assertEqual(recovered.returncode, 0, recovered.stderr)
                self.assertEqual(recovered.stdout.strip(), self.expected.hex().encode())
                self.assertEqual((self.guardian / slots.FINAL).stat().st_ino, inode)

    def test_maximum_reserved_overlap_counts_all_alias_names(self):
        records = self.root / 'records'; records.mkdir(mode=0o700)
        for index, size in enumerate([65_536] * 8 + [16_384] * 8 + [4096] * 6 + [1024] * 2 + [65_536]):
            (records / ('slot' + str(index))).write_bytes(b'0' * size)
        slots.publish_ingress(self.ingress, self.body)
        os.link(self.ingress / slots.FINAL, self.ingress / slots.PENDING)
        peak = []
        def sample(step):
            peak.append(slots.usage((self.ingress, self.guardian, records), captured_source_bytes=slots.LEGACY_MAX_SOURCE_BYTES - 2048))
        self.recover(hook=sample)
        self.assertEqual(max(x['bytes'] for x in peak), slots.RESERVED_BYTES)
        self.assertEqual(max(x['names'] for x in peak), slots.RESERVED_NAMES)
        self.assertEqual(slots.reservation(slots.LEGACY_MAX_SOURCE_BYTES)['reserved_bytes'], 4_153_344)

    def test_partial_ingress_is_not_promoted_or_replaced(self):
        def fail(step):
            if step == 'copy_chunk': raise OSError('producer crashed')
        with self.assertRaises(OSError): slots.publish_ingress(self.ingress, self.body, hook=fail)
        with self.assertRaisesRegex(ValueError, 'incomplete_ingress'): self.recover()
        self.assertFalse((self.guardian / slots.PENDING).exists())
        with self.assertRaises(ValueError): slots.publish_ingress(self.ingress, self.body)

    def test_conflicting_final_pending_retains_both_and_allocates_nothing(self):
        slots.publish_ingress(self.ingress, self.body)
        (self.guardian / slots.FINAL).write_bytes(self.body)
        (self.guardian / slots.PENDING).write_bytes(b'other')
        for path in self.guardian.iterdir(): path.chmod(0o600)
        before = {x.name: x.stat().st_ino for x in self.guardian.iterdir()}
        with self.assertRaisesRegex(ValueError, 'conflicting_witness_inodes'): self.recover()
        self.assertTrue((self.ingress / slots.FINAL).exists())
        self.assertEqual({k: (self.guardian / k).stat().st_ino for k in before}, before)

    def test_changed_ingress_after_interruption_does_not_replace_durable_final(self):
        slots.publish_ingress(self.ingress, self.body)
        def fail(step):
            if step == 'directory_fsynced': raise OSError('fixture stop')
        with self.assertRaises(OSError): self.recover(hook=fail)
        (self.ingress / slots.FINAL).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'witness_replay_conflict'): self.recover()
        self.assertEqual((self.guardian / slots.FINAL).read_bytes(), self.body)

    def test_symlink_extra_name_or_unexplained_alias_is_rejected(self):
        for mutation in ('symlink', 'extra_name', 'alias'):
            with self.subTest(mutation=mutation):
                for folder in (self.ingress, self.guardian):
                    for path in folder.iterdir(): path.unlink()
                slots.publish_ingress(self.ingress, self.body)
                if mutation == 'symlink':
                    (self.guardian / slots.PENDING).symlink_to(self.ingress / slots.FINAL)
                elif mutation == 'extra_name':
                    (self.guardian / 'unexpected').write_bytes(b'')
                else:
                    os.link(self.ingress / slots.FINAL, self.root / 'outside-alias')
                with self.assertRaises((ValueError, OSError)): self.recover()
                if (self.root / 'outside-alias').exists(): (self.root / 'outside-alias').unlink()

    def test_busy_exclusive_lock_does_not_touch_body_slots(self):
        slots.publish_ingress(self.ingress, self.body)
        directory = slots._directory(self.guardian, os.getuid())
        try:
            with slots._exclusive(directory, os.getuid()):
                with self.assertRaises(BlockingIOError): self.recover()
                self.assertFalse((self.guardian / slots.PENDING).exists())
        finally:
            os.close(directory)

    def test_known_source_and_name_bounds_refuse_before_publication(self):
        with self.assertRaises(ValueError): slots.reservation(slots.LEGACY_MAX_SOURCE_BYTES + 1)
        with self.assertRaises(ValueError): slots.reservation(slots.MAX_SOURCE_BYTES + 1, fixed_records=True)
        self.assertEqual(slots.reservation(slots.MAX_SOURCE_BYTES, fixed_records=True)['schema_version'], 2)
        for number in range(33): (self.guardian / str(number)).write_bytes(b'')
        with self.assertRaisesRegex(ValueError, 'action_name_limit'): slots.usage((self.guardian,))


if __name__ == '__main__':
    unittest.main()
