"""Portable byte/filesystem checks. Never executes a role, parser or runtime."""
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import types
import unittest
from unittest import mock

import metadata_bootstrap as boot
import package_metadata as package

PARENT = Path('/var/lib/timestep-source/bundles')
CODEC = vars(boot)


def material():
    # Deliberately nonexecutable members prove byte verification is independent
    # of importing the supplied graph. Python members are inspected only as AST.
    raw = {name: b'raise AssertionError("must never execute fixture member")\n' for name in boot.MEMBERS}
    raw['witness_slots.py'] = (b'LEGACY_MAX_SOURCE_BYTES=262144\nMAX_SOURCE_BYTES=327680\n'
        b'MAX_BYTES=4194304\nMAX_NAMES=32\nRESERVED_BYTES=4153344\nRESERVED_NAMES=30\n')
    local = Path(__file__).parent
    for name in ('metadata.service.in', 'metadata.slice.in'):
        raw[name] = (local / name).read_bytes()
    raw['parser.mjs'] = b'throw Error("fixture parser must never run");\n'
    version = 'deno 2.9.6 (stable, release, aarch64-unknown-linux-gnu)\nv8 14.9\ntypescript 6.0'
    observed = {'schema_version': 1, 'kind': 'linux_metadata_runtime_inventory', 'platform': 'linux',
                'architecture': 'aarch64', 'kernel_release': '6.8.0-fixture', 'systemd_version': '255.4',
                'python_version': '3.12.3 fixture', 'deno_version': version, 'psql_version': 'psql 17.9',
                'tls_version': 'OpenSSL 3.0.13 fixture',
                'packages': [{'name': 'libc6', 'version': '2.39-fixture', 'architecture': 'arm64'}]}
    runtimes = {name: {'path': '/usr/bin/' + name, 'sha256': str(i) * 64, 'bytes': 1024}
                for i, name in enumerate(boot.RUNTIME_NAMES, 1)}
    runtimes['python']['path'] = '/usr/bin/python3.12'
    runtimes['psql']['path'] = '/usr/lib/postgresql/17/bin/psql'
    parser = {'schema_version': 1, 'kind': 'local_metadata_parser_bundle',
              'sources': {name: {'bytes': 100, 'sha256': 'a' * 64} for name in
                          ('workers/source-gateway/parse-metadata.ts', 'supabase/functions/_shared/arxiv.ts',
                           'supabase/functions/_shared/http.ts', 'supabase/functions/_shared/source-xml.ts')},
              'builder_sha256': 'b' * 64, 'compiler_version': '0.28.2', 'compiler_sha256': 'c' * 64,
              'runtime_version': version, 'runtime_sha256': runtimes['deno']['sha256'],
              'output': {'file': 'parser.mjs', 'bytes': len(raw['parser.mjs']), 'sha256': boot.sha(raw['parser.mjs'])},
              'hosted_admitted': False, 'source_network_enabled': False,
              'build_options': ['workers/source-gateway/parse-metadata.ts', '--bundle', '--platform=neutral',
                                '--format=esm', '--target=es2022', '--main-fields=main', '--conditions=default',
                                '--charset=utf8', '--legal-comments=inline', '--outfile=parser.mjs', '--metafile=graph.json']}
    raw['parser-manifest.json'] = json.dumps(parser, indent=2).encode() + b'\n'
    return raw, observed, runtimes


def assemble(raw=None, observed=None, runtimes=None):
    defaults = material()
    return package.assemble(CODEC, raw or defaults[0], observed or defaults[1], runtimes or defaults[2],
                            PARENT, b'# captured build-only recipe\n')


class MaterialTests(unittest.TestCase):
    def test_exact_graph_charge_and_original_parser_bytes(self):
        raw, observed, runtimes = material()
        result, encoded, root = assemble(raw, observed, runtimes)
        self.assertEqual(boot.validate_material(raw, encoded, root), result)
        self.assertEqual(root.name, hashlib.sha256(encoded).hexdigest())
        self.assertEqual(result['source_bytes'], sum(map(len, raw.values())) + len(encoded) +
                         boot.unit_size(raw, root))
        self.assertEqual(result['runtime_inventory_sha256'], boot.sha(boot.canonical(observed)))
        self.assertEqual(result['journal_allocation'], 'fixed-record-inodes-v2')
        self.assertEqual(result['source_limit'], 327_680)
        self.assertEqual(result['files']['parser-manifest.json'], boot.sha(raw['parser-manifest.json']))
        self.assertNotIn('package_metadata.py', result['files'])
        self.assertNotIn('supervisor.py', result['files'])
        self.assertNotIn('frozen.py', result['files'])
        self.assertIn('child_contract.py', result['files'])
        self.assertIn('runtime_identity.py', result['files'])
        self.assertIn('owned_session.py', result['files'])

    def test_member_set_digest_and_address_are_not_substitutable(self):
        raw, _, _ = material()
        _, encoded, root = assemble(raw)
        changes = [dict(raw, extra=b'x'), {k: v for k, v in raw.items() if k != 'child.py'},
                   dict(raw, **{'child.py': b'changed'})]
        for changed in changes:
            with self.subTest(keys=set(changed) ^ set(raw)), self.assertRaises(ValueError):
                boot.validate_material(changed, encoded, root)
        with self.assertRaisesRegex(ValueError, 'identity'):
            boot.validate_material(raw, encoded, root.parent / ('f' * 64))

    def test_parser_output_and_real_linux_runtime_bindings(self):
        for change in ('output', 'runtime', 'mac', 'options', 'extra_source'):
            with self.subTest(change=change):
                raw, observed, runtimes = material()
                parser = json.loads(raw['parser-manifest.json'])
                if change == 'output':
                    parser['output']['sha256'] = 'd' * 64
                elif change == 'runtime':
                    parser['runtime_sha256'] = 'd' * 64
                elif change == 'mac':
                    parser['runtime_version'] = observed['deno_version'] = 'deno 2.9.6 aarch64-apple-darwin'
                elif change == 'options':
                    parser['build_options'].append('--external:*')
                else:
                    parser['sources']['../unreviewed.js'] = {'bytes': 1, 'sha256': 'a' * 64}
                raw['parser-manifest.json'] = boot.canonical(parser)
                with self.assertRaises(ValueError):
                    assemble(raw, observed, runtimes)

    def test_inventory_is_finite_canonical_and_strict(self):
        _, original, _ = material()
        for changed in (dict(original, token='not permitted'), dict(original, platform='darwin'),
                        dict(original, packages=original['packages'] * 2),
                        dict(original, kernel_release='x' * 513)):
            with self.assertRaises(ValueError):
                boot.inventory(changed)
        with self.assertRaises(ValueError):
            boot.decode(b'{"schema_version":1,"schema_version":1}', 1024)
        with self.assertRaises(ValueError):
            boot.decode(b'{"n":NaN}', 1024)

    def test_full_serialized_charge_refuses_one_byte_over(self):
        raw, _, _ = material()
        for name in ('transport.py', 'metadata_bridge.py'):
            raw[name] = b'#' * 131_072
        lower, upper = 1, boot.MAX_MEMBER
        while lower < upper:
            size = (lower + upper + 1) // 2
            raw['metadata_host.py'] = b'#' * size
            try:
                assemble(raw)
                lower = size
            except ValueError as error:
                self.assertEqual(str(error), 'bundle_source_capacity')
                upper = size - 1
        raw['metadata_host.py'] = b'#' * lower
        result, encoded, root = assemble(raw)
        self.assertEqual(result['source_bytes'], boot.MAX_SOURCE_BYTES)
        self.assertEqual(boot.validate_material(raw, encoded, root), result)
        raw['metadata_host.py'] += b'#'
        with self.assertRaisesRegex(ValueError, 'capacity'):
            assemble(raw)

    def test_allocation_and_manifest_counter_changes_refuse(self):
        raw, _, _ = material()
        changed = dict(raw, **{'witness_slots.py': raw['witness_slots.py'].replace(b'327680', b'327681')})
        with self.assertRaisesRegex(ValueError, 'allocation'):
            assemble(changed)
        result, _, _ = assemble(raw)
        result['source_bytes'] -= 1
        encoded = boot.canonical(result)
        with self.assertRaisesRegex(ValueError, 'capacity'):
            boot.validate_material(raw, encoded, PARENT / boot.sha(encoded))
        result, _, _ = assemble(raw)
        result['journal_allocation'] = 'legacy'
        encoded = boot.canonical(result)
        with self.assertRaisesRegex(ValueError, 'profile'):
            boot.validate_material(raw, encoded, PARENT / boot.sha(encoded))
        # A matching member hash cannot silently select a different allocation.
        result, _, _ = assemble(raw)
        result['files']['witness_slots.py'] = boot.sha(changed['witness_slots.py'])
        encoded = boot.canonical(result)
        with self.assertRaisesRegex(ValueError, 'allocation'):
            boot.validate_material(changed, encoded, PARENT / boot.sha(encoded))
        for parent in ('/tmp/../aliases', '//var/lib/timestep-source/bundles'):
            with self.assertRaises(ValueError):
                package.assemble(CODEC, raw, material()[1], material()[2], Path(parent), b'build')

    def test_entrypoint_dispatch_is_finite(self):
        self.assertEqual(boot.ENTRIES, {'metadata_launcher': ['linux_launcher', 'main'],
            'linux_source': ['linux_source', 'main'], 'metadata_executor': ['metadata_bridge', 'executor_main'],
            'metadata_guardian': ['metadata_bridge', 'main']})
        with mock.patch.object(boot.sys, 'argv', ['bootstrap.py', str(PARENT), 'unknown']), \
                mock.patch.object(boot, 'load_bundle', side_effect=AssertionError('must not load')):
            with self.assertRaisesRegex(ValueError, 'entrypoint'):
                boot.main()

    def test_missing_python_dependency_is_refused_without_import(self):
        raw, _, _ = material()
        for source in (b'import missing_bundle_dependency\n', b'from . import transport\n', b'import bootstrap\n'):
            raw['metadata_bridge.py'] = source
            with self.assertRaisesRegex(ValueError, 'import|graph'):
                assemble(raw)

    def test_current_source_graph_is_closed_without_importing_it(self):
        source = Path(__file__).parent
        raw = {name: (source.parent / name).read_bytes() for name in package.GATEWAY_FILES}
        raw.update({target: (source / name).read_bytes() for name, target in package.LOCAL_FILES.items()})
        fixture = material()[0]
        raw.update({name: fixture[name] for name in ('parser.mjs', 'parser-manifest.json')})
        self.assertEqual(set(raw), boot.MEMBERS)
        package.validate_python_graph(CODEC, raw)
        self.assertEqual(package.source_limit(CODEC, raw['witness_slots.py']), boot.MAX_SOURCE_BYTES)


class FileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='metadata-package-test-')
        self.root = Path(self.temporary.name)

    def tearDown(self):
        for current, directories, _ in os.walk(self.root):
            os.chmod(current, 0o700)
            for name in directories:
                path = Path(current) / name
                if not path.is_symlink():
                    path.chmod(0o700)
        self.temporary.cleanup()

    def test_file_preallocation_no_symlinks_aliases_or_special_nodes(self):
        path = self.root / 'member'
        path.write_bytes(b'abcd')
        path.chmod(0o444)
        self.assertEqual(boot.read_regular(path, 4, owner=os.getuid(), readonly=True), b'abcd')
        with self.assertRaises(ValueError):
            boot.read_regular(path, 3)
        link = self.root / 'link'
        link.symlink_to(path)
        with self.assertRaises(OSError):
            boot.read_regular(link, 4)
        alias = self.root / 'alias'
        os.link(path, alias)
        with self.assertRaises(ValueError):
            boot.read_regular(path, 4)
        fifo = self.root / 'fifo'
        os.mkfifo(fifo)
        with self.assertRaises(ValueError):
            boot.read_regular(fifo, 4)

    def test_change_during_capture_is_refused(self):
        path = self.root / 'member'
        path.write_bytes(b'abcd')
        original = os.read
        altered = False

        def read(fd, size):
            nonlocal altered
            result = original(fd, size)
            if not altered:
                altered = True
                path.write_bytes(b'changed')
            return result

        with mock.patch.object(boot.os, 'read', side_effect=read):
            with self.assertRaisesRegex(ValueError, 'changed'):
                boot.read_regular(path, 64)

    def test_elf_identity_is_hashed_without_execution(self):
        path = self.root / 'fake-runtime'
        header = bytearray(64)
        header[:7] = b'\x7fELF\x02\x01\x01'
        header[16:18] = (3).to_bytes(2, 'little')
        header[18:20] = (183).to_bytes(2, 'little')
        data = bytes(header) + b'not executable code'
        path.write_bytes(data)
        path.chmod(0o555)
        actual_stat = os.fstat

        def root_stat(fd):
            value = actual_stat(fd)
            return types.SimpleNamespace(st_mode=value.st_mode, st_uid=0, st_size=value.st_size,
                                         st_mtime_ns=value.st_mtime_ns, st_ctime_ns=value.st_ctime_ns)

        # Only the root ownership/ancestor precondition is simulated on Mac.
        # The real FD read, ELF inspection and SHA remain exercised.
        with mock.patch.object(boot, 'trusted_directory', return_value=self.root), \
                mock.patch.object(boot.os, 'fstat', side_effect=root_stat):
            self.assertEqual(boot.executable(path, 'aarch64'),
                             {'path': str(path), 'bytes': len(data), 'sha256': boot.sha(data)})
            with self.assertRaisesRegex(ValueError, 'non_linux'):
                boot.executable(path, 'x86_64')
            path.chmod(0o755)
            path.write_bytes(b'not ELF' + b'0' * 80)
            with self.assertRaisesRegex(ValueError, 'non_linux'):
                boot.executable(path, 'aarch64')
        fifo = self.root / 'runtime-fifo'
        os.mkfifo(fifo)
        with mock.patch.object(boot, 'trusted_directory', return_value=self.root), \
                mock.patch.object(boot.os, 'fstat', side_effect=root_stat):
            with self.assertRaisesRegex(ValueError, 'invalid_runtime'):
                boot.executable(fifo, 'aarch64')

    def test_readonly_publication_and_no_overwrite(self):
        raw, _, _ = material()
        _, encoded, identity = assemble(raw)
        target = self.root / identity.name
        codec = dict(CODEC, trusted_directory=lambda path: path)
        package.publish(codec, self.root, target, raw, encoded)
        self.assertEqual(set(p.name for p in target.iterdir()), boot.MEMBERS | {'bundle.json'})
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o555)
        self.assertTrue(all(stat.S_IMODE(p.stat().st_mode) == 0o444 for p in target.iterdir()))
        with self.assertRaises(FileExistsError):
            package.publish(codec, self.root, target, raw, encoded)
        self.assertEqual((target / 'bundle.json').read_bytes(), encoded)

    def test_failed_publication_retains_unusable_partial_directory(self):
        raw, _, _ = material()
        _, encoded, identity = assemble(raw)
        target = self.root / identity.name
        codec = dict(CODEC, trusted_directory=lambda path: path)
        with mock.patch.object(package.os, 'write', return_value=0):
            with self.assertRaisesRegex(ValueError, 'write_failed'):
                package.publish(codec, self.root, target, raw, encoded)
        self.assertTrue(target.is_dir())
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o700)
        self.assertFalse((target / 'bundle.json').exists())

    def test_saved_bundle_reload_checks_bytes_without_executing_members(self):
        raw, observed, runtimes = material()
        result, encoded, target = package.assemble(CODEC, raw, observed, runtimes, self.root, b'build')
        codec = dict(CODEC, trusted_directory=lambda path: path)
        package.publish(codec, self.root, target, raw, encoded)
        read = boot.read_regular

        def local_read(path, maximum, *, owner=None, readonly=False):
            return read(path, maximum, owner=os.getuid(), readonly=readonly)

        # Simulate only root ownership/runtime admission on Mac. The persisted
        # finite tree, modes, bounds, exact hashes and canonical identity are real.
        with mock.patch.object(boot, 'trusted_directory', return_value=target), \
                mock.patch.object(boot, 'read_regular', side_effect=local_read), \
                mock.patch.object(boot, 'check_runtime') as runtime:
            saved, captured = boot.load_bundle(target)
            self.assertEqual(saved, result)
            self.assertEqual(captured, raw)
            runtime.assert_called_once_with(result)
            member = target / 'child.py'
            member.chmod(0o644)
            member.write_bytes(b'changed source')
            member.chmod(0o444)
            with self.assertRaisesRegex(ValueError, 'member_mismatch'):
                boot.load_bundle(target)
            runtime.assert_called_once()


if __name__ == '__main__':
    unittest.main()
