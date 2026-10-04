"""Captured loader for the fixture's reviewed finite module graph."""
import hashlib
import importlib.abc
import importlib.util
import json
import pathlib
import re
import sys
import types

root = pathlib.Path(sys.argv[1])
entry = sys.argv[2]
assert entry in ('child', 'linux_controller', 'linux_lifecycle')
manifest_raw = (root / 'bundle.json').read_bytes()
assert len(manifest_raw) <= 16_384
manifest = json.loads(manifest_raw)
assert manifest['mode'] == 'linux_loopback_lifecycle_fixture'
assert manifest['source_network_enabled'] is False and manifest['hosted_admitted'] is False
assert len(manifest['files']) <= 24
raw = {}
for name, expected in manifest['files'].items():
    assert re.fullmatch(r'[a-z][a-z0-9_.-]{0,63}', name)
    data = (root / name).read_bytes()
    assert 0 < len(data) <= 131_072 and hashlib.sha256(data).hexdigest() == expected
    raw[name] = data
assert hashlib.sha256(raw['bootstrap.py']).hexdigest() == manifest['bootstrap_sha256']
runtime_hash = hashlib.sha256()
runtime_bytes = 0
with open(sys.executable, 'rb') as stream:
    for block in iter(lambda: stream.read(65536), b''):
        runtime_bytes += len(block)
        assert runtime_bytes <= 268_435_456
        runtime_hash.update(block)
assert runtime_hash.hexdigest() == manifest['python_sha256']
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
raise SystemExit(__import__(entry).main())
