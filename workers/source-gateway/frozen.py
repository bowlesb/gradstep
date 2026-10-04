"""Capture a complete local coordinator recipe before any execution."""
import hashlib
import os
from pathlib import Path
import ssl
import sys

from protocol import canonical, decode, digest, require, clock_name

from runtime_identity import executable_sha, command

FILES = ('protocol.py', 'transport.py', 'supervisor.py', 'identity.py', 'journal.py',
         'frozen.py', 'child.py', 'paused_child.py', 'local_postgres.py', 'integrate.py',
         'rpc_support.py', 'execution_contract.py', 'child_contract.py', 'runtime_identity.py')
# This exact string is itself included in the recipe identity, then passed as
# Python's -c program. Project modules execute only bytes read into this loader.
BOOTSTRAP = '''import hashlib,importlib.abc,importlib.util,json,os,pathlib,sys,types
root=pathlib.Path(sys.argv[1]); entry=sys.argv[2]
manifest=json.loads((root/'bundle.json').read_bytes())
raw={name:(root/name).read_bytes() for name in manifest['files']}
assert all(hashlib.sha256(v).hexdigest()==manifest['files'][k] for k,v in raw.items())
context=types.ModuleType('frozen_context');context.root=root;context.manifest=manifest;context.loaded={}
sys.modules['frozen_context']=context
class Loader(importlib.abc.MetaPathFinder,importlib.abc.Loader):
 def find_spec(self,name,path=None,target=None):
  return importlib.util.spec_from_loader(name,self) if name+'.py' in raw else None
 def create_module(self,spec): return None
 def exec_module(self,module):
  name=module.__name__+'.py'; data=raw[name]; module.__file__=str(root/name)
  context.loaded[name]=hashlib.sha256(data).hexdigest()
  exec(compile(data,str(root/name),'exec'),module.__dict__)
sys.meta_path.insert(0,Loader())
module=__import__(entry);raise SystemExit(module.main())
'''


def capture(parent, parser_bundle):
    root = Path(parent) / 'bundle'
    root.mkdir(mode=0o700)
    source = Path(__file__).resolve().parent
    captured = {name: (source / name).read_bytes() for name in FILES}
    project = source.parents[1]
    parser = Path(parser_bundle)
    captured.update({'parser/' + name: (parser / name).read_bytes() for name in ('parser.mjs', 'manifest.json')})
    require(all(0 < len(raw) <= 131_072 for raw in captured.values()), 'invalid_bundle')
    parser_manifest = decode(captured['parser/manifest.json'])
    require(parser_manifest['schema_version'] == 1 and parser_manifest['hosted_admitted'] is False
            and parser_manifest['source_network_enabled'] is False
            and parser_manifest['output']['file'] == 'parser.mjs'
            and parser_manifest['output']['bytes'] == len(captured['parser/parser.mjs'])
            and parser_manifest['output']['sha256'] == digest(captured['parser/parser.mjs']), 'parser_bundle_mismatch')
    deno = (project / 'node_modules/.bin/deno').resolve()
    deno_sha = executable_sha(deno)
    require(deno_sha == parser_manifest['runtime_sha256'], 'parser_runtime_changed')
    manifest = {'schema_version': 1, 'mode': 'local_fixture_only',
                'files': {name: digest(raw) for name, raw in captured.items()},
                'bootstrap_sha256': digest(BOOTSTRAP.encode()),
                'python_sha256': executable_sha(sys.executable), 'python_version': sys.version,
                'deno_path': str(deno), 'deno_sha256': deno_sha,
                'deno_version': parser_manifest['runtime_version'],
                'tls_version': ssl.OPENSSL_VERSION, 'hosted_admitted': False,
                'shared_deadline_clock': 'clock_gettime(' + clock_name() + ')',
                'source_bytes': sum(len(value) for value in captured.values()) + len(BOOTSTRAP.encode())}
    for name, raw in {**captured, 'bootstrap.py': BOOTSTRAP.encode(), 'bundle.json': canonical(manifest)}.items():
        path = root / name
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with path.open('xb') as file:
            file.write(raw)
            file.flush()
            os.fsync(file.fileno())
        path.chmod(0o400)
    # Persist and freeze every generated directory, including the parser's
    # nested name entries, before the coordinator can reference this bundle.
    for directory in [root / 'parser', root]:
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        directory.chmod(0o500)
    return root, manifest
