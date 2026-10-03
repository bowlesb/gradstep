"""Pre-deployment backups must accept pending source but reject schema drift."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from migration_ledger import source_ledger, verify_applied_prefix


class MigrationLedgerTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.directory = Path(self.work.name)
        for version in ['202610020001', '202610030009', '202610030010']:
            (self.directory / f'{version}_fixture.sql').write_text('begin; commit;\n')
        self.sources = source_ledger(self.directory)
        self.applied = dict(list(self.sources.items())[:2])

    def test_pending_newer_sources_are_not_part_of_checkpoint(self):
        original = self.applied.copy()
        verify_applied_prefix(self.applied, self.sources)
        self.assertEqual(self.applied, original)
        self.assertNotIn('202610030010', self.applied)

    def test_all_applied_sources_are_accepted(self):
        verify_applied_prefix(self.sources, self.sources)

    def test_edited_applied_source_is_rejected(self):
        self.sources['202610020001'] = 'f' * 64
        with self.assertRaisesRegex(RuntimeError, 'differs'):
            verify_applied_prefix(self.applied, self.sources)

    def test_missing_applied_source_is_rejected(self):
        del self.sources['202610020001']
        with self.assertRaisesRegex(RuntimeError, 'prefix'):
            verify_applied_prefix(self.applied, self.sources)

    def test_hole_in_applied_sequence_is_rejected(self):
        del self.applied['202610020001']
        with self.assertRaisesRegex(RuntimeError, 'prefix'):
            verify_applied_prefix(self.applied, self.sources)

    def test_newly_inserted_earlier_source_is_rejected(self):
        self.sources['202610020002'] = 'a' * 64
        with self.assertRaisesRegex(RuntimeError, 'prefix'):
            verify_applied_prefix(self.applied, self.sources)

    def test_duplicate_source_version_is_rejected(self):
        (self.directory / '202610030010_duplicate.sql').write_text('begin; commit;')
        with self.assertRaisesRegex(RuntimeError, 'Duplicate'):
            source_ledger(self.directory)

    def test_malformed_sources_and_ledgers_are_rejected(self):
        for ledger in [{}, [], None, {'bad': 'a' * 64}, {'202610020001': 'not a hash'}, {1: 'a' * 64}]:
            with self.subTest(ledger=ledger), self.assertRaises(RuntimeError):
                verify_applied_prefix(ledger, self.sources)
        (self.directory / 'invalid.sql').write_text('begin; commit;')
        with self.assertRaisesRegex(RuntimeError, 'filename'):
            source_ledger(self.directory)


if __name__ == '__main__':
    unittest.main()
