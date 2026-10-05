"""File-only package checks. No Deno, PDF parser, subprocess or network runs.

The real archived parser is verified once. Most cases then use a private copy
of its six exact assets and an injected already-verified-build lookup, plus
explicitly synthetic executable/wrapper bytes that are never executed.
"""
from dataclasses import replace
import errno
import hashlib
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

import original_verifier_bundle as package


class OriginalVerifierBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            cls.original = package._open_build_bundle(package.BUILD_ID)
        except FileNotFoundError:
            raise unittest.SkipTest('exact archived 3998 verifier build is unavailable')
        cls.assets = {name: package._read_path(cls.original / name, limit)
                      for name, limit in package.ASSET_LIMITS.items()}
        cls.original_hashes = {name: hashlib.sha256(raw).hexdigest() for name, raw in cls.assets.items()}

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='.timestep-verifier-bundle-', dir=Path.home())
        self.base = Path(self.temp.name).resolve()
        self.parent, self.source, self.receiver = (self.base / name for name in ('packages', 'build', 'receiver'))
        for path in (self.parent, self.source, self.receiver):
            path.mkdir(mode=0o700)
        for name, raw in self.assets.items():
            (self.source / name).write_bytes(raw)
        (self.source / 'bundle.json').write_bytes(package._canonical({
            'format': 1, 'identity_sha256': package.BUILD_ID, 'files': self.original_hashes}))
        self.wrapper = b'// Synthetic receiver; never executed by these file tests.\n'
        (self.receiver / package.ENTRYPOINT).write_bytes(self.wrapper)
        self.deno = self.base / 'synthetic-deno-not-executed'
        self.deno.write_bytes(b'synthetic executable identity fixture\n')
        self.deno.chmod(0o500)

    def tearDown(self):
        # All names here belong to this test. Successful captures intentionally
        # deny writes, so restore only their directory modes for fixture cleanup.
        for path in self.parent.iterdir():
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o700)
        self.temp.cleanup()

    def capture(self, *, parent=None, build_id=None, deno=None):
        with patch.object(package, '_SOURCE', self.receiver), \
                patch.object(package, '_open_build_bundle', return_value=self.source) as checked:
            result = package.capture_verifier_bundle(parent or self.parent, build_id or package.BUILD_ID,
                                                      deno or self.deno)
        checked.assert_called_once_with(package.BUILD_ID)
        return result

    def rewrite(self, bundle, name, raw):
        path = bundle.root / name
        path.chmod(0o600)
        path.write_bytes(raw)
        path.chmod(0o400)

    def test_real_build_capture_has_exact_private_graph_and_owned_manifest(self):
        with patch.object(package, '_SOURCE', self.receiver):
            bundle = package.capture_verifier_bundle(self.parent, package.BUILD_ID, self.deno)
        self.assertIsNone(bundle.verify())
        self.assertEqual(set(path.name for path in bundle.root.iterdir()), set(package.FILE_LIMITS) | {'bundle.json'})
        self.assertEqual(bundle.path, bundle.root)
        self.assertEqual(bundle.receiver_entry, bundle.root / package.ENTRYPOINT)
        self.assertEqual(bundle.build_identity_sha256, package.BUILD_ID)
        self.assertEqual(bundle.profile_id, package.PROFILE_ID)
        self.assertEqual(bundle.profile_sha256, package.PROFILE_SHA256)
        self.assertEqual(bundle.deno_path, self.deno)
        self.assertEqual(bundle.deno_sha256, hashlib.sha256(self.deno.read_bytes()).hexdigest())
        self.assertEqual(bundle.sha256, hashlib.sha256((bundle.root / 'bundle.json').read_bytes()).hexdigest())
        self.assertEqual(bundle.sha256, bundle.package_sha256)
        self.assertEqual(bundle.sha256, bundle.manifest_sha256)
        self.assertFalse(bundle.manifest_bytes.endswith(b'\n'))
        self.assertLessEqual(len(bundle.manifest_bytes), package.MAX_MANIFEST)
        self.assertEqual(stat.S_IMODE(bundle.root.stat().st_mode), 0o500)
        for path in bundle.root.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o400)
            self.assertEqual(path.stat().st_nlink, 1)
        for name, raw in self.assets.items():
            self.assertEqual((bundle.root / name).read_bytes(), raw)
            self.assertEqual(package._read_path(self.original / name, package.ASSET_LIMITS[name]), raw)
        view = bundle.manifest
        view['files']['runtime.ts']['sha256'] = '0' * 64
        self.assertNotEqual(view, bundle.manifest)
        bundle.verify()

    def test_capture_never_executes_runtime_or_build_commands(self):
        # The executable is deliberately not a runnable Deno binary. All capture
        # checks are reads, hashes and owned publication; no version is invented.
        bundle = self.capture()
        self.assertNotIn('version', bundle.manifest['deno'])
        self.assertFalse(bundle.manifest['hosted_admitted'])
        self.assertTrue(bundle.manifest['local_fixture_only'])

    def test_only_exact_explicit_build_is_allowed_before_lookup(self):
        for value in ('', '2fea' + '0' * 60, package.BUILD_ID.upper(), None, []):
            with self.subTest(value=value), patch.object(package, '_open_build_bundle') as lookup:
                with self.assertRaisesRegex(ValueError, 'verifier_build_not_allowed'):
                    package.capture_verifier_bundle(self.parent, value, self.deno)
                lookup.assert_not_called()
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_capture_is_independent_of_later_workspace_and_build_changes(self):
        bundle = self.capture()
        shutil.rmtree(self.receiver)
        shutil.rmtree(self.source)
        bundle.verify()
        self.assertEqual((bundle.root / package.ENTRYPOINT).read_bytes(), self.wrapper)

    def test_changed_asset_after_build_lookup_refuses_without_publication(self):
        path = self.source / 'runtime.ts'
        path.write_bytes(path.read_bytes() + b'\n// changed after admitted source lookup\n')
        with self.assertRaisesRegex(ValueError, 'verifier_source_changed'):
            self.capture()
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_wrapper_maximum_and_limit_plus_one(self):
        (self.receiver / package.ENTRYPOINT).write_bytes(b'x' * package.FILE_LIMITS[package.ENTRYPOINT])
        bundle = self.capture()
        self.assertEqual(bundle.manifest['files'][package.ENTRYPOINT]['bytes'], 65_536)
        (self.receiver / package.ENTRYPOINT).write_bytes(b'x' * (package.FILE_LIMITS[package.ENTRYPOINT] + 1))
        with self.assertRaisesRegex(ValueError, 'verifier_file_identity'):
            self.capture()
        self.assertEqual(len(list(self.parent.iterdir())), 1)

    def test_unsafe_parent_and_symlink_ancestor_are_refused(self):
        self.parent.chmod(0o777)
        with self.assertRaisesRegex(ValueError, 'verifier_untrusted_directory'):
            self.capture()
        self.parent.chmod(0o700)
        link = self.base / 'parent-link'
        link.symlink_to(self.parent, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            self.capture(parent=link)
        with self.assertRaisesRegex(ValueError, 'verifier_absolute_path_required'):
            self.capture(parent=Path('relative-path'))
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_symlink_and_hardlink_source_members_are_refused(self):
        path = self.source / 'runtime.ts'
        path.unlink()
        path.symlink_to(self.original / 'runtime.ts')
        with self.assertRaises(OSError):
            self.capture()
        path.unlink()
        path.write_bytes(self.assets['runtime.ts'])
        os.link(path, self.base / 'source-alias')
        with self.assertRaisesRegex(ValueError, 'verifier_file_identity'):
            self.capture()

    def test_runtime_alias_nonexecutable_privilege_bits_and_size_refuse(self):
        link = self.base / 'deno-link'
        link.symlink_to(self.deno)
        with self.assertRaises(OSError):
            self.capture(deno=link)
        os.link(self.deno, self.base / 'deno-alias')
        with self.assertRaisesRegex(ValueError, 'verifier_file_identity'):
            self.capture()
        (self.base / 'deno-alias').unlink()
        for mode in (0o400, 0o4500, 0o2500, 0o502):
            self.deno.chmod(mode)
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                self.capture()
        self.deno.chmod(0o700)
        with self.deno.open('r+b') as stream:
            stream.truncate(package.MAX_DENO + 1)
        self.deno.chmod(0o500)
        with self.assertRaisesRegex(ValueError, 'verifier_file_identity'):
            self.capture()
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_mutated_member_and_self_consistent_forged_inventory_are_refused(self):
        bundle = self.capture()
        raw = (bundle.root / 'runtime.ts').read_bytes() + b'\n'
        self.rewrite(bundle, 'runtime.ts', raw)
        with self.assertRaisesRegex(ValueError, 'verifier_member_changed'):
            bundle.verify()
        manifest = bundle.manifest
        manifest['files']['runtime.ts'] = {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
        manifest['payload_bytes'] += 1
        encoded = package._canonical(manifest)
        self.rewrite(bundle, 'bundle.json', encoded)
        with self.assertRaisesRegex(ValueError, 'verifier_asset_mismatch'):
            replace(bundle, manifest_bytes=encoded).verify()

    def test_member_permissions_aliases_and_unexpected_cache_entry_refuse(self):
        bundle = self.capture()
        member = bundle.root / package.ENTRYPOINT
        member.chmod(0o600)
        with self.assertRaisesRegex(ValueError, 'verifier_file_mode'):
            bundle.verify()
        member.chmod(0o400)
        os.link(member, self.base / 'captured-alias')
        with self.assertRaisesRegex(ValueError, 'verifier_file_identity'):
            bundle.verify()
        (self.base / 'captured-alias').unlink()
        bundle.root.chmod(0o700)
        (bundle.root / 'gen').mkdir()
        bundle.root.chmod(0o500)
        with self.assertRaisesRegex(ValueError, 'verifier_file_set'):
            bundle.verify()

    def test_member_symlink_and_missing_member_refuse(self):
        bundle = self.capture()
        member = bundle.root / package.ENTRYPOINT
        bundle.root.chmod(0o700)
        member.unlink()
        member.symlink_to(self.receiver / package.ENTRYPOINT)
        bundle.root.chmod(0o500)
        with self.assertRaises(OSError):
            bundle.verify()
        bundle.root.chmod(0o700)
        member.unlink()
        bundle.root.chmod(0o500)
        with self.assertRaisesRegex(ValueError, 'verifier_file_set'):
            bundle.verify()

    def test_runtime_mutation_and_identical_byte_inode_replacement_refuse(self):
        bundle = self.capture()
        old = self.deno.read_bytes()
        self.deno.chmod(0o700)
        self.deno.write_bytes(old + b'changed')
        self.deno.chmod(0o500)
        with self.assertRaisesRegex(ValueError, 'verifier_runtime_changed'):
            bundle.verify()
        self.deno.unlink()
        self.deno.write_bytes(old)
        self.deno.chmod(0o500)
        with self.assertRaisesRegex(ValueError, 'verifier_runtime_changed'):
            bundle.verify()

    def test_runtime_change_during_capture_read_refuses_before_publication(self):
        real_read = os.read
        identity = (self.deno.stat().st_dev, self.deno.stat().st_ino)
        changed = []
        def changing(fd, count):
            raw = real_read(fd, count)
            info = os.fstat(fd)
            if raw and (info.st_dev, info.st_ino) == identity and not changed:
                changed.append(True)
                self.deno.chmod(0o700)
                with self.deno.open('ab') as stream:
                    stream.write(b'x')
                self.deno.chmod(0o500)
            return raw
        with patch.object(package.os, 'read', side_effect=changing), self.assertRaises(ValueError):
            self.capture()
        self.assertEqual(changed, [True])
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_package_directory_replacement_with_identical_bytes_refuses(self):
        bundle = self.capture()
        saved = bundle.root.with_name(bundle.root.name + '-retained')
        bundle.root.chmod(0o700)  # The trusted owner is the simulated attacker.
        bundle.root.rename(saved)
        shutil.copytree(saved, bundle.root)
        bundle.root.chmod(0o500)
        saved.chmod(0o500)
        with self.assertRaisesRegex(ValueError, 'verifier_directory_changed'):
            bundle.verify()

    def test_closed_canonical_manifest_rejects_extra_duplicate_and_nonfinite_values(self):
        bundle = self.capture()
        for mutate in (
                lambda value: value.update(extra=True),
                lambda value: value.update(hosted_admitted=True),
                lambda value: value.update(payload_bytes=True),
                lambda value: value['files'][package.ENTRYPOINT].update(bytes=True),
                lambda value: value['deno']['identity'].update(inode='01'),
                lambda value: value['deno']['identity'].update(mode=0o4500)):
            value = bundle.manifest
            mutate(value)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                package._manifest(package._canonical(value))
        for raw in (bundle.manifest_bytes + b'\n', b'{"a":1,"a":2}', b'{"a":NaN}',
                    b'{"a":Infinity}', b'\xff', b'x' * (package.MAX_MANIFEST + 1)):
            with self.subTest(raw=raw[:20]), self.assertRaises(ValueError):
                package._manifest(raw)

    def test_short_writes_are_completed_and_successful_capture_fsyncs_parent(self):
        real_write, real_fsync = os.write, os.fsync
        synced = []
        def short(fd, raw):
            return real_write(fd, raw[:71])
        def sync(fd):
            synced.append((os.fstat(fd).st_dev, os.fstat(fd).st_ino))
            return real_fsync(fd)
        # A Mock records every 64KiB argument before the deliberate 71-byte
        # short write. Keeping thousands of those copies exhausted the1GiB
        # Linux test VM. These direct replacements test the same real short
        # writes and barriers without retaining payload copies in call history.
        with patch.object(package.os, 'write', new=short), patch.object(package.os, 'fsync', new=sync):
            bundle = self.capture()
        bundle.verify()
        info = self.parent.stat()
        self.assertIn((info.st_dev, info.st_ino), synced)

    def test_write_failure_retains_exact_private_partial_path_and_original_assets(self):
        real_write = os.write
        calls = []
        def disk_full(fd, raw):
            calls.append(1)
            if len(calls) == 1:
                return real_write(fd, raw[:7])
            raise OSError(errno.ENOSPC, 'synthetic disk full')
        with patch.object(package.os, 'write', side_effect=disk_full), self.assertRaises(package.VerifierCaptureError) as caught:
            self.capture()
        root = caught.exception.root
        self.assertEqual(root.parent, self.parent)
        self.assertEqual(list(self.parent.iterdir()), [root])
        self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
        self.assertLessEqual(sum(path.stat().st_size for path in root.iterdir()), package.MAX_PAYLOAD + package.MAX_MANIFEST)
        for name, expected in self.original_hashes.items():
            self.assertEqual(hashlib.sha256(package._read_path(self.original / name, package.ASSET_LIMITS[name])).hexdigest(), expected)

    def test_fsync_failure_retains_publication_without_claiming_success(self):
        with patch.object(package.os, 'fsync', side_effect=OSError(errno.EIO, 'synthetic fsync failure')):
            with self.assertRaises(package.VerifierCaptureError) as caught:
                self.capture()
        self.assertTrue(caught.exception.root.is_dir())
        self.assertEqual(caught.exception.root.parent, self.parent)

    def test_parent_fsync_failure_retains_complete_files_without_returning_bundle(self):
        real_fsync = os.fsync
        info = self.parent.stat()
        identity = (info.st_dev, info.st_ino)
        def fail_parent(fd):
            observed = os.fstat(fd)
            if (observed.st_dev, observed.st_ino) == identity:
                raise OSError(errno.EIO, 'synthetic parent fsync failure')
            return real_fsync(fd)
        with patch.object(package.os, 'fsync', side_effect=fail_parent):
            with self.assertRaises(package.VerifierCaptureError) as caught:
                self.capture()
        self.assertEqual(set(path.name for path in caught.exception.root.iterdir()),
                         set(package.FILE_LIMITS) | {'bundle.json'})
        self.assertEqual(stat.S_IMODE(caught.exception.root.stat().st_mode), 0o500)

    def installed_manifest(self):
        value = self.capture().manifest
        value['format'] = 'original-verifier-bundle-v2'
        value['installation'] = dict(package.INSTALLATION)
        value['deno']['identity'].update(uid=0, gid=0, mode=0o555)
        return value

    def test_v2_schema_is_closed_and_cannot_be_silently_applied_to_v1(self):
        value = self.installed_manifest()
        self.assertEqual(package._manifest(package._canonical(value)), value)
        for mutate in (
                lambda item: item.update(format='original-verifier-bundle-v1'),
                lambda item: item.pop('installation'),
                lambda item: item['installation'].update(extra=True),
                lambda item: item['installation'].update(policy='portable'),
                lambda item: item['installation'].update(uid=False),
                lambda item: item['installation'].update(uid=62402),
                lambda item: item['installation'].update(gid=62401),
                lambda item: item['installation'].update(directory_mode=0o500),
                lambda item: item['installation'].update(file_mode=0o400),
                lambda item: item['deno']['identity'].update(uid=62402),
                lambda item: item['deno']['identity'].update(mode=0o500),
                lambda item: item['deno']['identity'].update(gid=62402, mode=0o501)):
            changed = package._decode(package._canonical(value))
            mutate(changed)
            with self.subTest(value=changed), self.assertRaises(ValueError):
                package._manifest(package._canonical(changed))

    def test_installed_apis_refuse_nonroot_and_nonlinux_before_any_file_access(self):
        for platform, uid in (('darwin', 0), ('linux', 62401), ('linux', 62402)):
            with self.subTest(platform=platform, uid=uid), \
                    patch.object(package.sys, 'platform', platform), \
                    patch.object(package.os, 'geteuid', return_value=uid), \
                    patch.object(package, '_open_build_bundle') as lookup, \
                    patch.object(package, '_directory') as directory:
                with self.assertRaisesRegex(ValueError, 'verifier_linux_root_required'):
                    package.install_verifier_bundle(self.parent, package.BUILD_ID, self.deno)
                with self.assertRaisesRegex(ValueError, 'verifier_linux_root_required'):
                    package.open_installed_verifier_bundle(self.parent, '0' * 64)
                lookup.assert_not_called()
                directory.assert_not_called()

    def test_installed_manifest_properties_remain_available_after_drop(self):
        value = self.installed_manifest()
        encoded = package._canonical(value)
        bundle = package.FrozenVerifierBundle(self.parent / 'never-opened', encoded, (1, 2))
        with patch.object(package.sys, 'platform', 'linux'), \
                patch.object(package.os, 'geteuid', return_value=62401), \
                patch.object(package, '_directory', side_effect=AssertionError('unexpected file access')):
            self.assertEqual(bundle.manifest, value)
            self.assertEqual(bundle.build_identity_sha256, package.BUILD_ID)
            self.assertEqual(bundle.profile_sha256, package.PROFILE_SHA256)
            self.assertEqual(bundle.profile_id, package.PROFILE_ID)
            self.assertEqual(bundle.deno_path, self.deno)
            self.assertEqual(bundle.deno_sha256, value['deno']['sha256'])
            self.assertEqual(bundle.receiver_entry, bundle.root / package.ENTRYPOINT)
            self.assertEqual(bundle.package_sha256, hashlib.sha256(encoded).hexdigest())
            with self.assertRaisesRegex(ValueError, 'verifier_linux_root_required'):
                bundle.verify()

    def test_fixed_reader_group_and_reopen_digest_refuse_before_lookup(self):
        # Only these front-door guards are simulated. Actual ownership/mode
        # installation is exercised by the Linux-root class below.
        with patch.object(package.sys, 'platform', 'linux'), \
                patch.object(package.os, 'geteuid', return_value=0), \
                patch.object(package, '_open_build_bundle') as lookup, \
                patch.object(package, '_directory') as directory:
            for group in (0, True, 62401, '62402', [], None):
                with self.subTest(group=group), self.assertRaisesRegex(ValueError, 'verifier_reader_group'):
                    package.install_verifier_bundle(self.parent, package.BUILD_ID, self.deno, reader_gid=group)
            for digest in ('', 'A' * 64, [], None):
                with self.subTest(digest=digest), self.assertRaisesRegex(ValueError, 'verifier_manifest_digest'):
                    package.open_installed_verifier_bundle(self.parent, digest)
            lookup.assert_not_called()
            directory.assert_not_called()


@unittest.skipUnless(sys.platform == 'linux' and os.geteuid() == 0,
                     'installed package ownership requires Linux root')
class InstalledVerifierBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        OriginalVerifierBundleTests.setUpClass.__func__(cls)

    def setUp(self):
        # /tmp is deliberately inadmissible: its writable ancestor would allow
        # aliases/replacements. This finite root-owned fixture has safe ancestry.
        self.temp = tempfile.TemporaryDirectory(prefix='timestep-verifier-bundle-', dir='/var/lib')
        self.base = Path(self.temp.name)
        self.base.chmod(0o755)
        self.parent, self.source, self.receiver = (self.base / name for name in ('packages', 'build', 'receiver'))
        for path in (self.parent, self.source, self.receiver):
            path.mkdir(mode=0o755)
            path.chmod(0o755)
        for name, raw in self.assets.items():
            (self.source / name).write_bytes(raw)
        (self.source / 'bundle.json').write_bytes(package._canonical({
            'format': 1, 'identity_sha256': package.BUILD_ID, 'files': self.original_hashes}))
        self.wrapper = b'// Synthetic installed receiver; never executed.\n'
        (self.receiver / package.ENTRYPOINT).write_bytes(self.wrapper)
        self.deno = self.base / 'synthetic-deno-not-executed'
        self.deno.write_bytes(b'synthetic Linux executable identity fixture\n')
        self.deno.chmod(0o555)

    def tearDown(self):
        for path in self.parent.iterdir():
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o700)
        self.temp.cleanup()

    def install(self):
        with patch.object(package, '_SOURCE', self.receiver), \
                patch.object(package, '_open_build_bundle', return_value=self.source):
            return package.install_verifier_bundle(self.parent, package.BUILD_ID, self.deno)

    def test_install_and_reopen_exact_graph_without_changing_private_capture(self):
        with patch.object(package, '_SOURCE', self.receiver), \
                patch.object(package, '_open_build_bundle', return_value=self.source):
            private = package.capture_verifier_bundle(self.parent, package.BUILD_ID, self.deno)
        original = {path.name: (path.read_bytes(), path.stat().st_mode, path.stat().st_gid)
                    for path in private.root.iterdir()}
        bundle = self.install()
        self.assertNotEqual(private.root, bundle.root)
        self.assertEqual(bundle.manifest['format'], 'original-verifier-bundle-v2')
        self.assertEqual(bundle.manifest['installation'], package.INSTALLATION)
        self.assertEqual((bundle.root.stat().st_uid, bundle.root.stat().st_gid), (0, 62402))
        self.assertEqual(stat.S_IMODE(bundle.root.stat().st_mode), 0o550)
        self.assertEqual(set(path.name for path in bundle.root.iterdir()), set(package.FILE_LIMITS) | {'bundle.json'})
        for path in bundle.root.iterdir():
            info = path.stat()
            self.assertEqual((info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink), (0, 62402, 0o440, 1))
        for name, raw in self.assets.items():
            self.assertEqual((bundle.root / name).read_bytes(), raw)
        with patch.object(package, '_open_build_bundle', side_effect=AssertionError('mutable build lookup')):
            reopened = package.open_installed_verifier_bundle(bundle.root, bundle.sha256)
        self.assertEqual(reopened, bundle)
        self.assertEqual({path.name: (path.read_bytes(), path.stat().st_mode, path.stat().st_gid)
                          for path in private.root.iterdir()}, original)
        private.verify()
        with self.assertRaises(ValueError):
            package.open_installed_verifier_bundle(private.root, private.sha256)

    def test_root_and_member_owner_group_mode_are_exact(self):
        bundle = self.install()
        os.chown(bundle.root, 0, 0)
        with self.assertRaisesRegex(ValueError, 'verifier_directory_group'):
            bundle.verify()
        os.chown(bundle.root, 0, 62402)
        for mode in (0o500, 0o555, 0o750):
            bundle.root.chmod(mode)
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, 'verifier_directory_mode'):
                bundle.verify()
        bundle.root.chmod(0o550)
        member = bundle.root / package.ENTRYPOINT
        os.chown(member, 0, 0)
        with self.assertRaisesRegex(ValueError, 'verifier_file_group'):
            bundle.verify()
        os.chown(member, 0, 62402)
        member.chmod(0o444)
        with self.assertRaisesRegex(ValueError, 'verifier_file_mode'):
            bundle.verify()
        member.chmod(0o440)
        os.chown(member, 62402, 62402)
        with self.assertRaisesRegex(ValueError, 'verifier_file_identity'):
            bundle.verify()

    def test_reader_must_traverse_every_ancestor_and_execute_runtime(self):
        self.parent.chmod(0o700)
        with self.assertRaisesRegex(ValueError, 'verifier_reader_traversal'):
            self.install()
        self.parent.chmod(0o755)
        self.base.chmod(0o700)
        with self.assertRaisesRegex(ValueError, 'verifier_reader_traversal'):
            self.install()
        self.base.chmod(0o755)
        self.deno.chmod(0o500)
        with self.assertRaisesRegex(ValueError, 'verifier_installed_runtime'):
            self.install()
        self.deno.chmod(0o555)
        os.chown(self.deno, 62402, 62402)
        with self.assertRaisesRegex(ValueError, 'verifier_file_identity'):
            self.install()
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_reopen_rejects_manifest_member_and_runtime_tamper(self):
        bundle = self.install()
        with self.assertRaisesRegex(ValueError, 'verifier_manifest_changed'):
            package.open_installed_verifier_bundle(bundle.root, '0' * 64)
        member = bundle.root / package.ENTRYPOINT
        member.chmod(0o640)
        member.write_bytes(self.wrapper + b'changed')
        member.chmod(0o440)
        with self.assertRaisesRegex(ValueError, 'verifier_member_changed'):
            package.open_installed_verifier_bundle(bundle.root, bundle.sha256)
        member.chmod(0o640)
        member.write_bytes(self.wrapper)
        member.chmod(0o440)
        self.deno.chmod(0o755)
        self.deno.write_bytes(b'changed installed runtime\n')
        self.deno.chmod(0o555)
        with self.assertRaisesRegex(ValueError, 'verifier_runtime_changed'):
            package.open_installed_verifier_bundle(bundle.root, bundle.sha256)

    def test_reopen_rejects_aliases_extra_files_and_replaced_root_identity(self):
        bundle = self.install()
        member = bundle.root / package.ENTRYPOINT
        alias = self.base / 'alias'
        os.link(member, alias)
        with self.assertRaisesRegex(ValueError, 'verifier_file_identity'):
            package.open_installed_verifier_bundle(bundle.root, bundle.sha256)
        alias.unlink()
        bundle.root.chmod(0o750)
        (bundle.root / 'unexpected').write_bytes(b'no cache')
        bundle.root.chmod(0o550)
        with self.assertRaisesRegex(ValueError, 'verifier_file_set'):
            package.open_installed_verifier_bundle(bundle.root, bundle.sha256)
        bundle.root.chmod(0o750)
        (bundle.root / 'unexpected').unlink()
        saved = bundle.root.with_name(bundle.root.name + '-retained')
        bundle.root.rename(saved)
        shutil.copytree(saved, bundle.root)
        os.chown(bundle.root, 0, 62402)
        bundle.root.chmod(0o550)
        with self.assertRaisesRegex(ValueError, 'verifier_directory_changed'):
            bundle.verify()

    def test_install_chown_failure_retains_only_its_new_partial_capture(self):
        with patch.object(package.os, 'fchown', side_effect=OSError(errno.EPERM, 'synthetic ownership failure')):
            with self.assertRaises(package.VerifierCaptureError) as caught:
                self.install()
        self.assertEqual(caught.exception.root.parent, self.parent)
        self.assertEqual(list(self.parent.iterdir()), [caught.exception.root])
        self.assertEqual(stat.S_IMODE(caught.exception.root.stat().st_mode), 0o700)
        self.assertEqual(list(caught.exception.root.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
