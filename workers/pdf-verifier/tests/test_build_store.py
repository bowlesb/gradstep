"""Offline checks for preserving executable/source identity across upgrades."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('build_store', Path(__file__).resolve().parents[1] / 'build_store.py')
store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store)


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        self.dist = self.root / 'dist'
        self.bundles = self.root / 'builds'
        self.source.mkdir()
        self.dist.mkdir()
        self.library = self.root / 'libqpdf.a'
        self.library.write_bytes(b'fixed library')
        self.profile = {'id': 'fixture', 'hosted_admitted': False}
        self.identity = {'profile': self.profile, 'profile_sha256': store.digest(store.canonical(self.profile)),
                         'qpdf_library_sha256': store.digest(self.library.read_bytes())}
        for name, key in store.SOURCES.items():
            raw = ('fixed source ' + name).encode()
            (self.source / name).write_bytes(raw)
            self.identity[key] = store.digest(raw)
        for name, key in store.EXECUTABLES.items():
            raw = ('fixed binary ' + name).encode()
            (self.dist / name).write_bytes(raw)
            self.identity[key] = store.digest(raw)
        (self.source / 'profile.json').write_bytes(store.canonical(self.profile))
        self.write_identity()

    def write_identity(self):
        encoded = store.canonical(self.identity)
        self.build_id = store.digest(encoded)
        (self.dist / 'identity.json').write_bytes(encoded)
        self.provenance = {**self.identity, 'build_identity_sha256': self.build_id, 'commands_run': [['original']]}
        (self.dist / 'build.json').write_bytes(store.canonical(self.provenance))

    def freeze(self):
        return store.freeze(self.dist, self.source, self.bundles, self.build_id, self.library)

    def tearDown(self):
        # Published bundles deliberately have read-only directories.
        for entry in self.root.rglob('*'):
            if entry.is_dir() and not entry.is_symlink():
                entry.chmod(0o755)
        self.temporary.cleanup()

    def test_owned_snapshot_survives_live_source_binary_and_library_changes(self):
        bundle = self.freeze()
        before = {path.name: path.read_bytes() for path in bundle.iterdir()}
        (self.source / 'runtime.ts').write_bytes(b'new runtime')
        (self.dist / 'verifier.wasm').write_bytes(b'new binary')
        self.library.write_bytes(b'new library')
        self.assertEqual(store.open_bundle(self.build_id, self.bundles), bundle)
        self.assertEqual(before, {path.name: path.read_bytes() for path in bundle.iterdir()})
        self.assertTrue(all(path.stat().st_nlink == 1 for path in bundle.iterdir()))

    def test_wrong_source_or_library_fails_before_publication(self):
        (self.source / 'runtime.ts').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'bundle_source_mismatch'):
            self.freeze()
        self.assertFalse(self.bundles.exists())
        (self.source / 'runtime.ts').write_bytes(b'fixed source runtime.ts')
        self.library.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'bundle_source_mismatch'):
            self.freeze()
        self.assertFalse(self.bundles.exists())

    def test_changed_runtime_gets_new_identity_and_preserves_old_bundle(self):
        original = self.freeze()
        original_id = self.build_id
        original_bytes = (original / 'runtime.ts').read_bytes()
        raw = b'new reviewed runtime'
        (self.source / 'runtime.ts').write_bytes(raw)
        self.identity['runtime_sha256'] = store.digest(raw)
        self.write_identity()
        newer = self.freeze()
        self.assertNotEqual(original, newer)
        self.assertEqual((newer / 'runtime.ts').read_bytes(), raw)
        self.assertEqual((store.open_bundle(original_id, self.bundles) / 'runtime.ts').read_bytes(), original_bytes)

    def test_repeat_preserves_original_provenance_and_rejects_incomplete_existing_bundle(self):
        original = self.freeze()
        provenance = (original / 'build.json').read_bytes()
        self.provenance['commands_run'] = [['later clean build']]
        (self.dist / 'build.json').write_bytes(store.canonical(self.provenance))
        self.assertEqual(self.freeze(), original)
        self.assertEqual((original / 'build.json').read_bytes(), provenance)
        original.chmod(0o755)
        (original / 'runtime.ts').unlink()
        with self.assertRaisesRegex(ValueError, 'bundle_file_set_mismatch'):
            self.freeze()
        self.assertFalse((original / 'runtime.ts').exists())

    def test_tampering_is_rejected_even_if_editable_manifest_hash_is_updated(self):
        original = self.freeze()
        path = original / 'runtime.ts'
        path.chmod(0o644)
        path.write_bytes(b'wrong runtime')
        manifest_path = original / 'bundle.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['files']['runtime.ts'] = store.digest(path.read_bytes())
        manifest_path.chmod(0o644)
        manifest_path.write_bytes(store.canonical(manifest))
        with self.assertRaisesRegex(ValueError, 'bundle_source_mismatch'):
            store.open_bundle(self.build_id, self.bundles)

    def test_symlinks_and_extra_members_fail_without_merging(self):
        original = self.freeze()
        original.chmod(0o755)
        path = original / 'runtime.ts'
        path.unlink()
        path.symlink_to(self.source / 'runtime.ts')
        with self.assertRaisesRegex(ValueError, 'bundle_symlink_refused'):
            store.open_bundle(self.build_id, self.bundles)
        path.unlink()
        path.write_bytes((self.source / 'runtime.ts').read_bytes())
        (original / 'unexpected').write_bytes(b'extra')
        with self.assertRaisesRegex(ValueError, 'bundle_file_set_mismatch'):
            store.open_bundle(self.build_id, self.bundles)

    def test_interrupted_publish_leaves_no_partial_bundle_and_does_not_change_inputs(self):
        source_before = (self.source / 'runtime.ts').read_bytes()
        with patch.object(store.os, 'rename', side_effect=OSError('simulated disk failure')):
            with self.assertRaises(OSError):
                self.freeze()
        self.assertEqual({path.name for path in self.bundles.iterdir()}, {'.publish.lock'})
        self.assertEqual((self.source / 'runtime.ts').read_bytes(), source_before)
        self.freeze()
        store.open_bundle(self.build_id, self.bundles)

    def test_identity_path_duplicates_provenance_and_size_are_checked(self):
        for value in ('../escape', 'a' * 63, 'A' * 64):
            with self.assertRaisesRegex(ValueError, 'invalid_build_identity'):
                store.open_bundle(value, self.bundles)
        with self.assertRaisesRegex(ValueError, 'duplicate_bundle_key'):
            store.json_value(b'{"x":1,"x":2}')
        with self.assertRaisesRegex(ValueError, 'invalid_bundle_file'):
            store.read(self.library, maximum=1)
        self.provenance['runtime_sha256'] = '0' * 64
        (self.dist / 'build.json').write_bytes(store.canonical(self.provenance))
        with self.assertRaisesRegex(ValueError, 'bundle_provenance_mismatch'):
            self.freeze()


if __name__ == '__main__':
    unittest.main()
