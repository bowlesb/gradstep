import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('limits_package_test', HERE / 'package.py')
P = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(P)
RUN = '10000000-0000-4000-8000-000000000001'
USER = '20000000-0000-4000-8000-000000000001'
ATTEMPTS = [f'30000000-0000-4000-8000-{n:012d}' for n in range(8)]
CREATED = 1790000000000


def writable(root):
    for folder in [root, *root.rglob('*')]:
        if folder.is_dir(): folder.chmod(0o755)


class PackagerTests(unittest.TestCase):
    def test_exact_verifier_synthetic_fixture_and_cli_configuration_are_bound(self):
        slug, config, requests, files, manifest, captured, cli = P.assemble(RUN, USER, CREATED, ATTEMPTS)
        self.assertEqual(requests, [{'case': name, 'attempt_id': attempt} for name, attempt in zip(P.CASES, ATTEMPTS)])
        self.assertEqual(config['expiresAt'] - config['createdAt'], 1200000)
        identity = json.loads(captured['verifier-identity.json'])
        self.assertEqual(P.digest(captured['verifier-identity.json']), P.BUILD_SHA256)
        for name, field in [('runtime.ts', 'runtime_sha256'), ('wasm.ts', 'memory_inspector_sha256'), ('verifier.mjs', 'javascript_sha256')]:
            self.assertEqual(P.digest(files[name]), identity[field])
        self.assertEqual(P.digest(captured['recovery.pdf']), manifest['recovery_fixture_sha256'])
        self.assertEqual(P.digest(captured['synthetic.wasm']), manifest['synthetic_sha256'])
        self.assertEqual(P.digest(cli), manifest['supabase_config_sha256'])
        self.assertEqual(cli, ('project_id = "science-reader-limits"\n\n[functions.' + slug + ']\nverify_jwt = false\n').encode())
        self.assertEqual(manifest['source_files'], {name: P.digest(raw) for name, raw in sorted(files.items())})
        self.assertEqual(manifest['captured_files'], {name: P.digest(raw) for name, raw in sorted(captured.items())})
        self.assertLessEqual(manifest['source_bytes'], 3000000)
        self.assertEqual(len(files), 8)

    def test_package_is_exclusive_sources_readonly_and_cli_cache_writable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            try:
                built = P.build(RUN, USER, CREATED, ATTEMPTS, output_root=root)
                work = Path(built['directory'])
                raw = (work / 'source-manifest.json').read_bytes()
                self.assertEqual(P.digest(raw), built['source_manifest_sha256'])
                manifest = json.loads(raw)
                source = work / 'supabase/functions' / built['function']
                self.assertEqual(set(x.name for x in source.iterdir()), set(manifest['source_files']))
                for name, expected in manifest['source_files'].items():
                    self.assertEqual(P.digest((source / name).read_bytes()), expected)
                    self.assertEqual(stat.S_IMODE((source / name).stat().st_mode), 0o444)
                self.assertEqual(stat.S_IMODE(source.stat().st_mode), 0o555)
                self.assertEqual(stat.S_IMODE((work / 'supabase/.temp').stat().st_mode), 0o755)
                (work / 'supabase/.temp/cli-latest').write_text('test-local-only')
                with self.assertRaisesRegex(ValueError, '^package_exists$'):
                    P.build(RUN, USER, CREATED, ATTEMPTS, output_root=root)
                self.assertEqual((work / 'source-manifest.json').read_bytes(), raw)
            finally:
                writable(root)

    def test_exact_captured_recipe_is_executed_and_recorded(self):
        inputs = P.capture_inputs()
        inputs['wasm_recipe.py'] = inputs['wasm_recipe.py'].replace(b'SEED = 0x12345678', b'SEED = 0x87654321')
        with patch.object(P, 'capture_inputs', return_value=inputs):
            *_, manifest, captured, _ = P.assemble(RUN, USER, CREATED, ATTEMPTS)
        self.assertEqual(manifest['synthetic_seed'], 0x87654321)
        self.assertEqual(captured['wasm_recipe.py'], inputs['wasm_recipe.py'])
        self.assertEqual(manifest['producer_files']['wasm_recipe.py'], P.digest(inputs['wasm_recipe.py']))

    def test_attempts_and_expiry_reject_ambiguous_inputs_before_capture(self):
        with patch.object(P, 'capture_inputs', side_effect=AssertionError('should not read')):
            for args in [(RUN, USER, True, ATTEMPTS), (RUN, USER, CREATED, ATTEMPTS[:7]),
                         (RUN, USER, CREATED, [ATTEMPTS[0]] * 8), (RUN, USER, CREATED, [RUN] + ATTEMPTS[1:]),
                         ('invalid', USER, CREATED, ATTEMPTS)]:
                with self.assertRaises(ValueError): P.assemble(*args)

    def test_symlink_destination_refused_without_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / 'target'; target.mkdir()
            (root / RUN).symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, '^package_exists$'):
                P.build(RUN, USER, CREATED, ATTEMPTS, output_root=root)
            self.assertEqual(list(target.iterdir()), [])

    def test_pinned_fixture_corruption_is_refused(self):
        original = P.checked
        def altered(path, expected, maximum=16 * 1024 * 1024):
            raw = original(path, expected, maximum)
            if path.name == 'pages-1.pdf': return raw + b'\n'
            return raw
        with patch.object(P, 'checked', side_effect=altered):
            with self.assertRaisesRegex(ValueError, '^invalid_recovery_fixture$'):
                P.assemble(RUN, USER, CREATED, ATTEMPTS)


if __name__ == '__main__':
    unittest.main()
