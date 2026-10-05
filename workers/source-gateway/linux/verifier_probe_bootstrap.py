"""Load one explicitly pinned, finite Python graph for the Linux verifier probe."""
import hashlib
import importlib.abc
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
import types


def require(value):
    if not value:
        raise ValueError('invalid_verifier_probe_capture')


def read(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1
                and stat.S_IMODE(info.st_mode) == 0o444 and 0 < info.st_size <= limit)
        with os.fdopen(os.dup(fd), 'rb') as stream:
            raw = stream.read(limit + 1)
        require(len(raw) == info.st_size)
        return raw
    finally:
        os.close(fd)


def main():
    require(len(sys.argv) in (5, 6))
    root, expected, role = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    require(root.is_absolute() and str(root) == os.path.normpath(str(root))
            and re.fullmatch('[0-9a-f]{64}', expected) and role in ('reaper', 'supervisor'))
    for path in (root, *root.parents):
        info = path.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022)
    require(stat.S_IMODE(root.stat().st_mode) == 0o555)
    manifest_raw = read(root / 'capture.json', 16_384)
    require(hashlib.sha256(manifest_raw).hexdigest() == expected)
    manifest = json.loads(manifest_raw)
    require(set(manifest) == {'format', 'local_fixture_only', 'hosted_admitted', 'files', 'python_sha256'}
            and manifest['format'] == 'linux-verifier-probe-capture-v1'
            and manifest['local_fixture_only'] is True and manifest['hosted_admitted'] is False
            and type(manifest['files']) is dict and 1 <= len(manifest['files']) <= 16)
    require({p.name for p in root.iterdir()} == set(manifest['files']) | {'capture.json'})
    raw = {}
    for name, digest in manifest['files'].items():
        require(re.fullmatch('[a-z][a-z0-9_]{0,50}\\.py', name) and re.fullmatch('[0-9a-f]{64}', digest))
        data = read(root / name, 131_072)
        require(hashlib.sha256(data).hexdigest() == digest)
        raw[name] = data
    require('verifier_probe_bootstrap.py' in raw and 'verifier_probe_runtime.py' in raw)
    runtime = hashlib.sha256()
    count = 0
    with open(sys.executable, 'rb') as stream:
        for part in iter(lambda: stream.read(65_536), b''):
            count += len(part)
            require(count <= 268_435_456)
            runtime.update(part)
    require(runtime.hexdigest() == manifest['python_sha256'])
    context = types.ModuleType('verifier_probe_context')
    context.module_root, context.manifest_sha256, context.manifest = root, expected, manifest
    sys.modules['verifier_probe_context'] = context

    class Loader(importlib.abc.MetaPathFinder, importlib.abc.Loader):
        def find_spec(self, name, path=None, target=None):
            return importlib.util.spec_from_loader(name, self) if name + '.py' in raw else None

        def create_module(self, spec):
            return None

        def exec_module(self, module):
            name = module.__name__ + '.py'
            module.__file__ = str(root / name)
            exec(compile(raw[name], module.__file__, 'exec'), module.__dict__)

    sys.meta_path.insert(0, Loader())
    from verifier_probe_runtime import main as run
    return run(sys.argv[3:])


if __name__ == '__main__':
    raise SystemExit(main())
