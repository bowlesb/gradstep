"""Immutable prerequisite loader. It has no request or credential input."""
import hashlib
import importlib.abc
import importlib.util
import json
import os
import pathlib
import re
import stat
import sys
import types

root = pathlib.Path(sys.argv[1])
entry = sys.argv[2]
assert entry in ('linux_launcher', 'linux_probe_launcher', 'linux_source', 'linux_source_probe')
assert root.is_absolute() and not root.is_symlink()
status = root.stat()
assert status.st_uid == 0 and not status.st_mode & 0o222
manifest_raw = (root / 'bundle.json').read_bytes()
assert 0 < len(manifest_raw) <= 16_384
manifest = json.loads(manifest_raw)
assert manifest['mode'] == 'linux_uid_ingress_fixture'
assert manifest['source_network_enabled'] is False and manifest['hosted_admitted'] is False
assert manifest['supervisor_uid'] == 62401 and manifest['source_uid'] == 62402
assert 0 < len(manifest['files']) <= 24
raw = {}
for name, expected in manifest['files'].items():
    assert re.fullmatch(r'[a-z][a-z0-9_.-]{0,63}', name)
    path = root / name
    status = path.lstat()
    assert stat.S_ISREG(status.st_mode) and status.st_uid == 0 and not status.st_mode & 0o222
    data = path.read_bytes()
    assert 0 < len(data) <= 131_072 and hashlib.sha256(data).hexdigest() == expected
    raw[name] = data
assert hashlib.sha256(raw['bootstrap.py']).hexdigest() == manifest['bootstrap_sha256']
runtime = hashlib.sha256()
size = 0
with open(sys.executable, 'rb') as stream:
    for block in iter(lambda: stream.read(65_536), b''):
        size += len(block)
        assert size <= 268_435_456
        runtime.update(block)
assert runtime.hexdigest() == manifest['python_sha256']
context = types.ModuleType('frozen_context')
context.root, context.manifest, context.loaded = root, manifest, {}
sys.modules['frozen_context'] = context


class Loader(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    def find_spec(self, name, path=None, target=None):
        return importlib.util.spec_from_loader(name, self) if name + '.py' in raw else None

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        name = module.__name__ + '.py'
        module.__file__ = str(root / name)
        context.loaded[name] = hashlib.sha256(raw[name]).hexdigest()
        exec(compile(raw[name], module.__file__, 'exec'), module.__dict__)


sys.meta_path.insert(0, Loader())
module = __import__('linux_launcher' if entry == 'linux_probe_launcher' else
                    'linux_source' if entry == 'linux_source_probe' else entry)
raise SystemExit(module.probe_main() if entry == 'linux_source_probe' else module.main())
