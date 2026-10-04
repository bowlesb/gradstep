"""Complete fixed-journal publication and interruption tests, with no SQL."""
import hashlib
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

from common import canonical
import action_journal as journal
import witness_slots as slots


class JournalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.layout = {leaf: self.root / leaf for leaf in ('records', 'control', 'data', 'witness', 'ingress')}
        for leaf, path in self.layout.items():
            path.mkdir(mode=0o750 if leaf == 'control' else 0o700)
        unit_root = self.root / 'units'
        unit_root.mkdir(mode=0o755)
        self.units = {unit_root / ('tsmetadata' + 'a' * 32 + suffix): ('unit' + suffix).encode()
                      for suffix in ('.service', '.slice')}
        for path, raw in self.units.items():
            path.write_bytes(raw)
            path.chmod(0o644)
        self.body = b'x' * slots.MAX_OUTPUT
        self.digest = hashlib.sha256(self.body).digest()

    def tearDown(self):
        self.temp.cleanup()

    def open(self, source_bytes=slots.MAX_SOURCE_BYTES):
        return journal.ActionJournal(self.layout, source_bytes, self.units, owner_uid=os.getuid(),
                                      producer_uid=os.getuid(), owner_gid=os.getgid(), producer_gid=os.getgid())

    def validate(self, raw):
        if hashlib.sha256(raw).digest() != self.digest:
            raise ValueError('unexpected_body')

    def producer(self):
        journal.publish_producer(self.layout['data'], 'privileges.json', {'checked': True})
        journal.publish_producer(self.layout['data'], 'ready.json', {'ready': True})

    def test_one_lock_covers_small_checkpoints_and_body_recovery(self):
        self.producer()
        slots.publish_ingress(self.layout['ingress'], self.body)
        with self.open() as action:
            action.put('input.json', {'request': 'fixture'})
            action.put('capture.json', {'captured': True})
            self.assertEqual(action.producer_ready(), {'ready': True})
            self.assertEqual(action.witness(self.validate), self.body)
            self.assertEqual(action.read('capture.json'), {'captured': True})
            with self.assertRaises(BlockingIOError):
                with self.open():
                    self.fail('second guardian acquired action')
            self.assertEqual(action.witness(self.validate), self.body)

    def test_control_permissions_are_correct_at_first_final_visibility(self):
        with self.open() as action:
            observed = []
            def observe(event):
                if event == 'checkpoint_linked':
                    info = (self.layout['control'] / 'go.json').stat()
                    observed.append((info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)))
            action.put('go.json', {'execution': 'fixture'}, hook=observe)
            self.assertEqual(observed, [(os.getuid(), os.getgid(), 0o640)])

    def test_visible_ready_with_temporary_cannot_start_guardian_publication(self):
        journal.publish_producer(self.layout['data'], 'privileges.json', {'checked': True})
        def stop(event):
            if event == 'checkpoint_linked':
                raise OSError('producer interrupted')
        with self.assertRaises(OSError):
            journal.publish_producer(self.layout['data'], 'ready.json', {'ready': True}, hook=stop)
        with self.open() as action:
            with self.assertRaisesRegex(ValueError, 'producer_publication_uncertain'):
                action.producer_ready()
            with self.assertRaisesRegex(ValueError, 'unfinished_action_record'):
                action.put('capture.json', {'captured': True})
        self.assertFalse((self.layout['records'] / 'capture.json').exists())

    def test_producer_cannot_write_after_ready_or_reverse_order(self):
        with self.assertRaisesRegex(ValueError, 'producer_order'):
            journal.publish_producer(self.layout['data'], 'ready.json', {})
        self.producer()
        for name in ('privileges.json', 'ready.json', 'capture.json'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                journal.publish_producer(self.layout['data'], name, {})

    def test_checkpoint_replay_resyncs_and_reuses_pending_or_final_inode(self):
        for event in ('checkpoint_fsynced', 'checkpoint_linked', 'checkpoint_directory_fsynced'):
            with self.subTest(event=event):
                for path in self.layout['records'].iterdir():
                    path.unlink()
                def stop(step):
                    if step == event:
                        raise OSError('checkpoint interrupted')
                with self.open() as action, self.assertRaises(OSError):
                    action.put('executor.json', {'receipt': 'fixed'}, hook=stop)
                pending = self.layout['records'] / (journal.PENDING + 'executor.json')
                inode = pending.stat().st_ino
                with self.open() as action:
                    action.put('executor.json', {'receipt': 'fixed'})
                    self.assertEqual(action.read('executor.json'), {'receipt': 'fixed'})
                self.assertFalse(pending.exists())
                self.assertEqual((self.layout['records'] / 'executor.json').stat().st_ino, inode)

    def test_partial_small_checkpoint_is_retained_without_another_temporary(self):
        value = {'large': 'x' * 8000}
        def stop(event):
            if event == 'checkpoint_chunk':
                raise OSError('interrupted in partial write')
        with self.open() as action, self.assertRaises(OSError):
            action.put('intent.json', value, hook=stop)
        pending = self.layout['records'] / (journal.PENDING + 'intent.json')
        before = (pending.stat().st_ino, pending.read_bytes())
        with self.open() as action:
            with self.assertRaises(ValueError):
                action.recover('intent.json', lambda value: self.fail('validated incomplete JSON'))
            with self.assertRaisesRegex(ValueError, 'unfinished_action_record'):
                action.put('intent.json', value)
            with self.assertRaisesRegex(ValueError, 'unfinished_action_record'):
                action.put('grant.json', {})
        self.assertEqual((pending.stat().st_ino, pending.read_bytes()), before)

    def test_pending_checkpoint_must_validate_before_final_publication(self):
        def stop(event):
            if event == 'checkpoint_fsynced':
                raise OSError('interrupted before link')
        with self.open() as action, self.assertRaises(OSError):
            action.put('executor.json', {'receipt': 'original'}, hook=stop)
        pending = self.layout['records'] / (journal.PENDING + 'executor.json')
        before = (pending.stat().st_ino, pending.read_bytes())
        def reject(value):
            raise ValueError('wrong receipt identity')
        with self.open() as action:
            with self.assertRaisesRegex(ValueError, 'wrong receipt identity'):
                action.recover('executor.json', reject)
            self.assertFalse(action.exists('executor.json'))
            self.assertEqual((pending.stat().st_ino, pending.read_bytes()), before)
            value = action.recover('executor.json', lambda value: self.assertEqual(value, {'receipt': 'original'}))
            self.assertEqual(value, {'receipt': 'original'})
            self.assertIsNone(action.recover('executor-ack.json', reject))
        self.assertEqual((self.layout['records'] / 'executor.json').stat().st_ino, before[0])
        self.assertFalse(pending.exists())

    def test_final_record_is_immutable_and_barrier_failure_blocks_return(self):
        with self.open() as action:
            action.put('capture.json', {'value': 1})
            with self.assertRaisesRegex(ValueError, 'immutable_action_record'):
                action.put('capture.json', {'value': 2})
            with patch.object(journal.os, 'fsync', side_effect=OSError('unavailable durability')):
                with self.assertRaises(OSError):
                    action.read('capture.json')
                with self.assertRaises(OSError):
                    action.put('capture.json', {'value': 1})

    def test_all_slots_and_maximum_bodies_fit_with_every_alias(self):
        for name, (leaf, maximum) in journal.RECORDS.items():
            raw = canonical({'v': 'x' * (maximum - len(canonical({'v': ''})))})
            self.assertEqual(len(raw), maximum)
            path = self.layout[leaf] / name
            path.write_bytes(raw)
            path.chmod(0o640 if leaf == 'control' else 0o600)
        os.link(self.layout['records'] / 'intent.json', self.layout['records'] / (journal.PENDING + 'intent.json'))
        slots.publish_ingress(self.layout['ingress'], self.body)
        os.link(self.layout['ingress'] / slots.FINAL, self.layout['ingress'] / slots.PENDING)
        observed = []
        with self.open() as action:
            action.witness(self.validate, hook=lambda event: observed.append(action.inventory()))
        self.assertEqual(max(value['names'] for value in observed), 30)
        self.assertEqual(max(value['bytes'] for value in observed), slots.RESERVED_BYTES)

    def test_witness_crash_recovery_does_not_allocate_a_third_body(self):
        slots.publish_ingress(self.layout['ingress'], self.body)
        def stop(event):
            if event == 'final_linked':
                raise OSError('guardian interrupted')
        with self.open() as action, self.assertRaises(OSError):
            action.witness(self.validate, hook=stop)
        path = self.layout['witness'] / slots.FINAL
        inode = path.stat().st_ino
        with self.open() as action:
            self.assertEqual(action.witness(self.validate), self.body)
        self.assertEqual(path.stat().st_ino, inode)

    def test_wrong_slot_mode_size_alias_and_unknown_name_refuse(self):
        changes = ('oversize', 'unknown', 'wrong_mode', 'symlink', 'outside_alias', 'two_temporaries')
        for change in changes:
            with self.subTest(change=change):
                for leaf in ('records', 'control', 'data'):
                    for path in self.layout[leaf].iterdir():
                        path.unlink()
                path = self.layout['records'] / 'capture.json'
                path.write_bytes(b'{}')
                path.chmod(0o600)
                if change == 'oversize':
                    path.write_bytes(b'x' * 16_385)
                elif change == 'unknown':
                    path.rename(path.with_name('other.json'))
                elif change == 'wrong_mode':
                    path.chmod(0o644)
                elif change == 'symlink':
                    path.unlink()
                    path.symlink_to(self.root / 'absent')
                elif change == 'outside_alias':
                    os.link(path, self.root / 'alias')
                else:
                    for leaf, name in (('records', 'grant.json'), ('control', 'go.json')):
                        pending = self.layout[leaf] / (journal.PENDING + name)
                        pending.write_bytes(b'{}')
                        pending.chmod(0o640 if leaf == 'control' else 0o600)
                with self.assertRaises(ValueError):
                    with self.open():
                        self.fail('accepted invalid inventory')
                if (self.root / 'alias').exists():
                    (self.root / 'alias').unlink()

    def test_wrong_unit_or_redirected_directory_refuses_without_mutation(self):
        unit = next(iter(self.units))
        unit.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'unit_source_changed'):
            with self.open():
                self.fail('accepted changed unit')
        unit.write_bytes(self.units[unit])
        original = self.layout['records']
        alternate = self.root / 'record-alias'
        alternate.symlink_to(original, target_is_directory=True)
        self.layout['records'] = alternate
        with self.assertRaisesRegex(ValueError, 'redirected_action_directory'):
            with self.open():
                self.fail('accepted redirected directory')


if __name__ == '__main__':
    unittest.main()
