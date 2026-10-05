"""Capture the one reviewed PDF parser and its paused receiving wrapper.

This module never runs Deno, a parser, build commands, or network operations.
The original complete build is verified before its six execution assets are
copied unchanged. Only the captured graph is a receiver import source. Portable
v1 is owner-private; installed Linux v2 is root-owned and readable by one fixed
receiver group. An installation always creates a new directory.

Read-only modes prevent accidental writes by the ordinary receiver; they do
not make files immutable against root/their owner. The selected absolute Deno
file is not copied: verify() checks its identity and full hash immediately before
launch, trusting the same owner not to replace it between that check and exec.
Its digest does not pin the operating system or shared libraries. The installed
mode policy is not Linux supervision or SQL/host admission.
"""
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import types
import uuid


BUILD_ID = '39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610'
PROFILE_ID = 'qpdf-wasm-pilot-v1'
PROFILE_SHA256 = 'c8478d6e1b1f7a8631132789a471a7f525123f40d2e893890254fb1660b54962'
ENTRYPOINT = 'original_verifier.mjs'
ASSET_LIMITS = {'runtime.ts': 65_536, 'wasm.ts': 65_536, 'verifier.mjs': 65_536,
                'verifier.wasm': 2_097_152, 'profile.json': 16_384, 'identity.json': 16_384}
FILE_LIMITS = dict(ASSET_LIMITS, **{ENTRYPOINT: 65_536})
MAX_MANIFEST = 16_384
MAX_PAYLOAD = 2_097_152
MAX_DENO = 268_435_456
CHUNK = 65_536
READER_GID = 62402
INSTALLATION = {'policy': 'linux-root-reader-v1', 'uid': 0, 'gid': READER_GID,
                'directory_mode': 0o550, 'file_mode': 0o440}
_SOURCE = Path(__file__).absolute().parent
_STORE_SOURCE = _SOURCE.parents[1] / 'pdf-verifier' / 'build_store.py'
_MANIFEST_KEYS = {'format', 'local_fixture_only', 'hosted_admitted', 'entrypoint',
                  'build_identity_sha256', 'profile_id', 'profile_sha256', 'files',
                  'payload_bytes', 'deno'}
_STAT_FIELDS = ('st_dev', 'st_ino', 'st_uid', 'st_gid', 'st_mode', 'st_nlink',
                'st_size', 'st_mtime_ns', 'st_ctime_ns')


def _require(value, code):
    if not value:
        raise ValueError(code)


def _sha(raw):
    return hashlib.sha256(raw).hexdigest()


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'),
                      ensure_ascii=False, allow_nan=False).encode('utf8')


def _decode(raw):
    _require(type(raw) is bytes and 0 < len(raw) <= MAX_MANIFEST, 'verifier_manifest_limit')
    def pairs(values):
        result = {}
        for key, value in values:
            _require(key not in result, 'verifier_duplicate_key')
            result[key] = value
        return result
    try:
        return json.loads(raw.decode('utf8'), object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError('verifier_nonfinite')))
    except (UnicodeError, RecursionError, json.JSONDecodeError) as error:
        raise ValueError('verifier_invalid_json') from error


def _hash_string(value):
    return type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None


def _integer(value, maximum):
    return type(value) is int and 0 <= value <= maximum


def _absolute(value):
    value = os.fspath(value)
    _require(type(value) is str and 0 < len(value.encode('utf8')) <= 4096
             and value.startswith('/') and not value.startswith('//') and value == os.path.normpath(value)
             and not any(ord(character) < 32 or ord(character) == 127 for character in value),
             'verifier_absolute_path_required')
    return Path(value)


def _directory(path, *, owned=False, mode=None, group=None, reader_gid=None):
    """Walk from / without following any symlink or writable foreign ancestor."""
    path = _absolute(path)
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        for part in path.parts[1:]:
            info = os.fstat(fd)
            _require(info.st_uid in (0, os.geteuid()) and not info.st_mode & 0o022,
                     'verifier_untrusted_ancestor')
            if reader_gid is not None:
                _require(info.st_mode & (0o010 if info.st_gid == reader_gid else 0o001),
                         'verifier_reader_traversal')
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                              dir_fd=fd)
            previous, fd = fd, next_fd
            os.close(previous)
        info = os.fstat(fd)
        _require(stat.S_ISDIR(info.st_mode) and info.st_uid in (0, os.geteuid())
                 and not info.st_mode & 0o022, 'verifier_untrusted_directory')
        _require(not owned or info.st_uid == os.geteuid(), 'verifier_directory_owner')
        _require(mode is None or stat.S_IMODE(info.st_mode) == mode, 'verifier_directory_mode')
        _require(group is None or info.st_gid == group, 'verifier_directory_group')
        if reader_gid is not None:
            _require(info.st_mode & (0o010 if info.st_gid == reader_gid else 0o001),
                     'verifier_reader_traversal')
        return fd
    except BaseException:
        os.close(fd)
        raise


def _stable(before, after):
    _require(all(getattr(before, key) == getattr(after, key) for key in _STAT_FIELDS),
             'verifier_file_changed')


def _read(directory, name, maximum, *, mode=None, owner=None, group=None, hashed=False, executable=False):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
    try:
        before = os.fstat(fd)
        _require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                 and before.st_uid in (0, os.geteuid()) and not before.st_mode & 0o022
                 and 0 < before.st_size <= maximum, 'verifier_file_identity')
        _require(mode is None or stat.S_IMODE(before.st_mode) == mode, 'verifier_file_mode')
        _require(owner is None or before.st_uid == owner, 'verifier_file_owner')
        _require(group is None or before.st_gid == group, 'verifier_file_group')
        _require(not executable or (before.st_mode & 0o111 and not before.st_mode & 0o7000),
                 'verifier_runtime_not_executable')
        raw, digest, count = bytearray(), hashlib.sha256(), 0
        while count <= maximum:
            part = os.read(fd, min(CHUNK, maximum + 1 - count))
            if not part:
                break
            count += len(part)
            digest.update(part)
            if not hashed:
                raw.extend(part)
        _require(count == before.st_size <= maximum, 'verifier_file_limit')
        _stable(before, os.fstat(fd))
        _stable(before, os.stat(name, dir_fd=directory, follow_symlinks=False))
        return (digest.hexdigest() if hashed else bytes(raw)), before
    finally:
        os.close(fd)


def _read_path(path, maximum):
    path = _absolute(path)
    directory = _directory(path.parent)
    try:
        return _read(directory, path.name, maximum)[0]
    finally:
        os.close(directory)


def _runtime(path, *, reader_gid=None):
    path = _absolute(path)
    directory = _directory(path.parent, reader_gid=reader_gid)
    try:
        digest, info = _read(directory, path.name, MAX_DENO, hashed=True, executable=True)
        if reader_gid is not None:
            _require(info.st_uid == 0 and info.st_mode & (0o010 if info.st_gid == reader_gid else 0o001),
                     'verifier_installed_runtime')
        return {'path': str(path), 'bytes': info.st_size, 'sha256': digest,
                'identity': {'device': str(info.st_dev), 'inode': str(info.st_ino),
                             'uid': info.st_uid, 'gid': info.st_gid, 'mode': stat.S_IMODE(info.st_mode),
                             'mtime_ns': str(info.st_mtime_ns), 'ctime_ns': str(info.st_ctime_ns)}}
    finally:
        os.close(directory)


def _open_build_bundle(build_id):
    # Capture the trusted local helper before executing it, avoiding import-cache
    # writes and executing no commands from build.json. This is a packager helper,
    # never an import made by the receiving process or a whole-toolchain attestation.
    raw = _read_path(_STORE_SOURCE, 65_536)
    module = types.ModuleType('_captured_pdf_build_store')
    module.__file__ = str(_STORE_SOURCE)
    exec(compile(raw, module.__file__, 'exec'), module.__dict__)
    return module.open_bundle(build_id)


def _assets(captured):
    identity = _decode(captured['identity.json'])
    profile = _decode(captured['profile.json'])
    _require(_sha(captured['identity.json']) == BUILD_ID and type(identity) is dict
             and type(profile) is dict and identity.get('profile') == profile
             and identity.get('profile_sha256') == PROFILE_SHA256
             and profile.get('id') == PROFILE_ID and profile.get('hosted_admitted') is False
             and _sha(_canonical(profile)) == PROFILE_SHA256, 'verifier_build_mismatch')
    for name, key in (('runtime.ts', 'runtime_sha256'), ('wasm.ts', 'memory_inspector_sha256'),
                      ('verifier.mjs', 'javascript_sha256'), ('verifier.wasm', 'wasm_sha256')):
        _require(_sha(captured[name]) == identity.get(key), 'verifier_asset_mismatch')


def _manifest(raw):
    value = _decode(raw)
    installed = type(value) is dict and value.get('format') == 'original-verifier-bundle-v2'
    keys = _MANIFEST_KEYS | {'installation'} if installed else _MANIFEST_KEYS
    _require(type(value) is dict and set(value) == keys and _canonical(value) == raw,
             'verifier_manifest_shape')
    _require(value['format'] in ('original-verifier-bundle-v1', 'original-verifier-bundle-v2')
             and value['local_fixture_only'] is True and value['hosted_admitted'] is False
             and value['entrypoint'] == ENTRYPOINT and value['build_identity_sha256'] == BUILD_ID
             and value['profile_id'] == PROFILE_ID and value['profile_sha256'] == PROFILE_SHA256,
             'verifier_manifest_binding')
    if installed:
        policy = value['installation']
        _require(type(policy) is dict and set(policy) == set(INSTALLATION)
                 and policy['policy'] == INSTALLATION['policy']
                 and all(type(policy[key]) is int and policy[key] == INSTALLATION[key]
                         for key in ('uid', 'gid', 'directory_mode', 'file_mode')),
                 'verifier_installation_policy')
    files = value['files']
    _require(type(files) is dict and set(files) == set(FILE_LIMITS), 'verifier_file_set')
    for name, entry in files.items():
        _require(type(entry) is dict and set(entry) == {'bytes', 'sha256'}
                 and _integer(entry['bytes'], FILE_LIMITS[name]) and entry['bytes'] > 0
                 and _hash_string(entry['sha256']), 'verifier_file_record')
    _require(_integer(value['payload_bytes'], MAX_PAYLOAD)
             and value['payload_bytes'] == sum(entry['bytes'] for entry in files.values()), 'verifier_payload_limit')
    deno = value['deno']
    _require(type(deno) is dict and set(deno) == {'path', 'bytes', 'sha256', 'identity'}
             and _integer(deno['bytes'], MAX_DENO) and deno['bytes'] > 0
             and _hash_string(deno['sha256']), 'verifier_runtime_record')
    _absolute(deno['path'])
    identity = deno['identity']
    _require(type(identity) is dict and set(identity) ==
             {'device', 'inode', 'uid', 'gid', 'mode', 'mtime_ns', 'ctime_ns'}, 'verifier_runtime_record')
    for name in ('device', 'inode', 'mtime_ns', 'ctime_ns'):
        item = identity[name]
        _require(type(item) is str and re.fullmatch('0|[1-9][0-9]{0,19}', item) is not None
                 and int(item) <= 2**64 - 1, 'verifier_runtime_record')
    _require(_integer(identity['uid'], 2**32 - 1) and _integer(identity['gid'], 2**32 - 1)
             and _integer(identity['mode'], 0o7777) and identity['mode'] & 0o111
             and not identity['mode'] & 0o7022, 'verifier_runtime_record')
    if installed:
        _require(identity['uid'] == 0
                 and identity['mode'] & (0o010 if identity['gid'] == READER_GID else 0o001),
                 'verifier_installed_runtime')
    return value


def _linux_root():
    _require(sys.platform == 'linux' and os.geteuid() == 0, 'verifier_linux_root_required')


@dataclass(frozen=True)
class FrozenVerifierBundle:
    root: Path
    manifest_bytes: bytes
    _root_identity: tuple = field(repr=False)

    @property
    def path(self):
        return self.root

    @property
    def receiver_entry(self):
        return self.root / ENTRYPOINT

    @property
    def manifest(self):
        return _manifest(self.manifest_bytes)  # Fresh tree; no caller-owned aliases.

    @property
    def sha256(self):
        return _sha(self.manifest_bytes)

    package_sha256 = sha256
    manifest_sha256 = sha256

    @property
    def build_identity_sha256(self):
        return self.manifest['build_identity_sha256']

    @property
    def profile_id(self):
        return self.manifest['profile_id']

    @property
    def profile_sha256(self):
        return self.manifest['profile_sha256']

    @property
    def deno_path(self):
        return Path(self.manifest['deno']['path'])

    @property
    def deno_sha256(self):
        return self.manifest['deno']['sha256']

    def verify(self):
        """Fail closed before launch; never follows mutable workspace imports."""
        manifest = self.manifest
        installed = manifest['format'] == 'original-verifier-bundle-v2'
        if installed:
            _linux_root()
        directory_mode, file_mode = (0o550, 0o440) if installed else (0o500, 0o400)
        reader_gid = READER_GID if installed else None
        directory = _directory(self.root, owned=True, mode=directory_mode,
                               group=reader_gid, reader_gid=reader_gid)
        try:
            info = os.fstat(directory)
            _require((info.st_dev, info.st_ino) == self._root_identity, 'verifier_directory_changed')
            names = set()
            with os.scandir(directory) as entries:
                for entry in entries:
                    names.add(entry.name)
                    _require(len(names) <= len(FILE_LIMITS) + 1, 'verifier_file_set')
            _require(names == set(FILE_LIMITS) | {'bundle.json'}, 'verifier_file_set')
            raw, _ = _read(directory, 'bundle.json', MAX_MANIFEST, mode=file_mode,
                           owner=os.geteuid(), group=reader_gid)
            _require(raw == self.manifest_bytes, 'verifier_manifest_changed')
            captured = {}
            for name, limit in FILE_LIMITS.items():
                raw, _ = _read(directory, name, limit, mode=file_mode, owner=os.geteuid(), group=reader_gid)
                _require({'bytes': len(raw), 'sha256': _sha(raw)} == manifest['files'][name],
                         'verifier_member_changed')
                captured[name] = raw
            _assets(captured)
        finally:
            os.close(directory)
        _require(_runtime(manifest['deno']['path'], reader_gid=reader_gid) == manifest['deno'],
                 'verifier_runtime_changed')
        # Rebind the name after the potentially larger executable hash read.
        directory = _directory(self.root, owned=True, mode=directory_mode,
                               group=reader_gid, reader_gid=reader_gid)
        try:
            info = os.fstat(directory)
            _require((info.st_dev, info.st_ino) == self._root_identity, 'verifier_directory_changed')
        finally:
            os.close(directory)


class VerifierCaptureError(ValueError):
    """A failed new publication is retained; root identifies only that owned path."""
    def __init__(self, root):
        self.root = root
        super().__init__('verifier_capture_incomplete: ' + str(root))


def capture_verifier_bundle(parent, explicit_build_id, exact_deno_path):
    """Capture eight private files, without executing the receiver or Deno.

    parent must already be owned and beneath trusted, non-writable ancestors.
    A partial destination is retained on failure; no original build is changed.
    """
    return _capture(parent, explicit_build_id, exact_deno_path, installed=False)


def install_verifier_bundle(parent, explicit_build_id, exact_deno_path, *, reader_gid=READER_GID):
    """Create a new root-owned Linux v2 graph for the fixed unprivileged reader.

    The existing parent and all ancestors must be root-owned, non-writable by
    other users, and searchable by UID/GID62402 without supplementary groups.
    Capture/verify happen before the supervisor drops. No runtime is executed.
    """
    _linux_root()
    _require(type(reader_gid) is int and reader_gid == READER_GID, 'verifier_reader_group')
    return _capture(parent, explicit_build_id, exact_deno_path, installed=True)


def open_installed_verifier_bundle(root, expected_sha256):
    """Reopen exactly one installed v2 capture before the root caller drops.

    Return an owned manifest and current root identity after full verification;
    properties remain memory-only afterward. Root is trusted against later
    replacement. This does not reopen portable v1 or inspect a mutable build.
    """
    _linux_root()
    _require(_hash_string(expected_sha256), 'verifier_manifest_digest')
    root = _absolute(root)
    directory = _directory(root, owned=True, mode=0o550, group=READER_GID, reader_gid=READER_GID)
    try:
        info = os.fstat(directory)
        raw, _ = _read(directory, 'bundle.json', MAX_MANIFEST, mode=0o440, owner=0, group=READER_GID)
        _require(_sha(raw) == expected_sha256, 'verifier_manifest_changed')
        _require(_manifest(raw)['format'] == 'original-verifier-bundle-v2', 'verifier_installed_required')
        result = FrozenVerifierBundle(root, raw, (info.st_dev, info.st_ino))
    finally:
        os.close(directory)
    result.verify()
    return result


def _capture(parent, explicit_build_id, exact_deno_path, *, installed):
    _require(type(explicit_build_id) is str and explicit_build_id == BUILD_ID, 'verifier_build_not_allowed')
    source = _absolute(_open_build_bundle(explicit_build_id))
    source_fd = _directory(source)
    try:
        source_manifest, _ = _read(source_fd, 'bundle.json', MAX_MANIFEST)
        inventory = _decode(source_manifest)
        _require(type(inventory) is dict and set(inventory) == {'format', 'identity_sha256', 'files'}
                 and type(inventory['format']) is int and inventory['format'] == 1
                 and inventory['identity_sha256'] == BUILD_ID and type(inventory['files']) is dict
                 and set(ASSET_LIMITS) <= set(inventory['files']), 'verifier_source_manifest')
        captured = {name: _read(source_fd, name, limit)[0] for name, limit in ASSET_LIMITS.items()}
        _require(all(_sha(raw) == inventory['files'][name] for name, raw in captured.items()),
                 'verifier_source_changed')
        _require(_read(source_fd, 'bundle.json', MAX_MANIFEST)[0] == source_manifest, 'verifier_source_changed')
    finally:
        os.close(source_fd)
    _assets(captured)
    captured[ENTRYPOINT] = _read_path(_SOURCE / ENTRYPOINT, FILE_LIMITS[ENTRYPOINT])
    reader_gid = READER_GID if installed else None
    runtime = _runtime(exact_deno_path, reader_gid=reader_gid)
    manifest = {'format': 'original-verifier-bundle-v2' if installed else 'original-verifier-bundle-v1',
                'local_fixture_only': True,
                'hosted_admitted': False, 'entrypoint': ENTRYPOINT, 'build_identity_sha256': BUILD_ID,
                'profile_id': PROFILE_ID, 'profile_sha256': PROFILE_SHA256,
                'files': {name: {'bytes': len(raw), 'sha256': _sha(raw)} for name, raw in captured.items()},
                'payload_bytes': sum(map(len, captured.values())), 'deno': runtime}
    if installed:
        manifest['installation'] = dict(INSTALLATION)
    encoded = _canonical(manifest)
    _manifest(encoded)
    parent = _absolute(parent)
    parent_fd = _directory(parent, owned=True, reader_gid=reader_gid)
    name = 'original-verifier-' + uuid.uuid4().hex
    root = parent / name
    directory = None
    created = False
    result, failure = None, None
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
        created = True
        directory = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                            dir_fd=parent_fd)
        if installed:
            os.fchown(directory, 0, READER_GID)
        os.fchmod(directory, 0o700)
        info = os.fstat(directory)
        for filename, raw in {**captured, 'bundle.json': encoded}.items():
            fd = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o400, dir_fd=directory)
            try:
                offset = 0
                while offset < len(raw):
                    sent = os.write(fd, raw[offset:offset + CHUNK])
                    _require(sent > 0, 'verifier_write_failed')
                    offset += sent
                if installed:
                    os.fchown(fd, 0, READER_GID)
                os.fchmod(fd, 0o440 if installed else 0o400)
                os.fsync(fd)
            finally:
                os.close(fd)
        os.fchmod(directory, 0o550 if installed else 0o500)
        os.fsync(directory)
        os.fsync(parent_fd)
        result = FrozenVerifierBundle(root, encoded, (info.st_dev, info.st_ino))
        result.verify()
    except BaseException as error:
        failure = error
    finally:
        for fd in (directory, parent_fd):
            if fd is not None:
                try:
                    os.close(fd)
                except BaseException as error:
                    if failure is None:
                        failure = error
    if failure is not None:
        if created:
            raise VerifierCaptureError(root) from failure
        raise failure
    return result
