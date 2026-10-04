#!/usr/bin/env python3
"""Preserve checked verifier executables and sources by their full build identity.

Bundles are local build evidence, not permission to deploy or admit a profile.
Their provenance is informational; consumers must never execute commands from
build.json. Runtime and packaging consumers select an explicit reviewed digest.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile

SOURCE = Path(__file__).resolve().parent
ARTIFACTS = SOURCE.parents[1] / '.artifacts/pdf-verifier'
STORE = ARTIFACTS / 'builds'
SOURCES = {'runtime.ts': 'runtime_sha256', 'wasm.ts': 'memory_inspector_sha256',
           'verifier.cpp': 'wrapper_sha256', 'build.py': 'build_recipe_sha256',
           'dependencies.lock.json': 'dependencies_sha256'}
EXECUTABLES = {'verifier.wasm': 'wasm_sha256', 'verifier.mjs': 'javascript_sha256'}
LIBRARIES = {'libqpdf.a': 'qpdf_library_sha256'}
MAX_FILE_BYTES = 16 * 1024 * 1024


def require(value, code):
    if not value:
        raise ValueError(code)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def identifier(value):
    require(isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value), 'invalid_build_identity')
    return value


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def read(path, maximum=MAX_FILE_BYTES):
    require(not path.is_symlink(), 'bundle_symlink_refused')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_size <= maximum, 'invalid_bundle_file')
        raw = stream.read(maximum + 1)
        require(len(raw) <= maximum, 'bundle_file_limit')
        return raw


def json_value(raw):
    require(len(raw) <= 262144, 'bundle_json_limit')
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, 'duplicate_bundle_key')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite_bundle_number')))


def source_names(identity):
    names = dict(SOURCES)
    if 'build_store_sha256' in identity:
        names['build_store.py'] = 'build_store_sha256'
    for key in [*names.values(), *EXECUTABLES.values(), 'profile_sha256', 'qpdf_library_sha256']:
        identifier(identity.get(key))
    return names


def validate_files(files, expected):
    """Bind executable/source bytes to identity, not to an editable pointer."""
    identifier(expected)
    require(digest(files['identity.json']) == expected, 'bundle_identity_mismatch')
    identity = json_value(files['identity.json'])
    require(isinstance(identity, dict), 'invalid_bundle_identity')
    names = {**source_names(identity), **EXECUTABLES, **LIBRARIES}
    require(set(files) == {*names, 'identity.json', 'build.json', 'profile.json'}, 'bundle_file_set_mismatch')
    for name, key in names.items():
        require(digest(files[name]) == identity[key], 'bundle_source_mismatch')
    profile = json_value(files['profile.json'])
    require(profile == identity.get('profile') and digest(canonical(profile)) == identity['profile_sha256'],
            'bundle_profile_mismatch')
    provenance = json_value(files['build.json'])
    require(isinstance(provenance, dict) and provenance.get('build_identity_sha256') == expected,
            'bundle_provenance_mismatch')
    for key, value in identity.items():
        require(provenance.get(key) == value, 'bundle_provenance_mismatch')
    return identity


def verify_directory(path, expected):
    require(not path.is_symlink() and path.is_dir(), 'invalid_bundle_directory')
    manifest = json_value(read(path / 'bundle.json', 262144))
    require(isinstance(manifest, dict) and set(manifest) == {'format', 'identity_sha256', 'files'}
            and manifest['format'] == 1 and manifest['identity_sha256'] == identifier(expected)
            and isinstance(manifest['files'], dict), 'invalid_bundle_manifest')
    identity_raw = read(path / 'identity.json', 262144)
    require(digest(identity_raw) == expected, 'bundle_identity_mismatch')
    identity = json_value(identity_raw)
    require(isinstance(identity, dict), 'invalid_bundle_identity')
    names = {*source_names(identity), *EXECUTABLES, *LIBRARIES, 'identity.json', 'build.json', 'profile.json'}
    require(set(manifest['files']) == names and {entry.name for entry in path.iterdir()} == names | {'bundle.json'},
            'bundle_file_set_mismatch')
    files = {}
    for name in names:
        raw = read(path / name)
        require(digest(raw) == identifier(manifest['files'][name]), 'bundle_file_mismatch')
        files[name] = raw
    return validate_files(files, expected)


def open_bundle(expected, store=STORE):
    path = store / identifier(expected)
    verify_directory(path, expected)
    return path


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def freeze(distribution, source=SOURCE, store=STORE, expected=None, library=None):
    """Check everything before atomic publication; never overwrite a bundle."""
    raw = read(distribution / 'identity.json', 262144)
    build_id = digest(raw)
    require(expected is None or build_id == identifier(expected), 'unexpected_build_identity')
    identity = json_value(raw)
    require(isinstance(identity, dict), 'invalid_bundle_identity')
    files = {'identity.json': raw, 'build.json': read(distribution / 'build.json', 262144),
             'profile.json': read(source / 'profile.json', 262144)}
    for name in source_names(identity):
        files[name] = read(source / name)
    for name in EXECUTABLES:
        files[name] = read(distribution / name)
    files['libqpdf.a'] = read(library or ARTIFACTS / 'qpdf-build/libqpdf/libqpdf.a')
    validate_files(files, build_id)
    manifest = {'format': 1, 'identity_sha256': build_id,
                'files': {name: digest(value) for name, value in sorted(files.items())}}
    require(not store.is_symlink(), 'invalid_bundle_store')
    store.mkdir(parents=True, exist_ok=True)
    with (store / '.publish.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        destination = store / build_id
        if destination.exists() or destination.is_symlink():
            # Canonical source/profile/executable bytes must still match. A
            # repeated clean/link-only build may have different informational
            # invocation provenance; preserve the first verified bundle.
            verify_directory(destination, build_id)
            for name, value in files.items():
                if name != 'build.json':
                    require(read(destination / name) == value, 'existing_bundle_conflict')
            return destination
        temporary = Path(tempfile.mkdtemp(prefix='.' + build_id + '-', dir=store))
        try:
            for name, value in {**files, 'bundle.json': canonical(manifest)}.items():
                with (temporary / name).open('xb') as stream:
                    stream.write(value)
                    stream.flush()
                    os.fsync(stream.fileno())
            verify_directory(temporary, build_id)
            fsync_directory(temporary)
            # Read-only permissions prevent accidental build-tool overwrites;
            # they are not a security boundary against the local owner.
            for file in temporary.iterdir():
                file.chmod(0o444)
            os.rename(temporary, destination)
            destination.chmod(0o555)
            fsync_directory(store)
        finally:
            if temporary.exists():
                temporary.chmod(0o755)
                shutil.rmtree(temporary)
        return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-identity', required=True)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    path = open_bundle(args.expected_identity) if args.verify_only else freeze(
        ARTIFACTS / 'dist', expected=args.expected_identity)
    print(json.dumps({'bundle': str(path.relative_to(SOURCE.parents[1])), 'identity_sha256': args.expected_identity}))


if __name__ == '__main__':
    main()
