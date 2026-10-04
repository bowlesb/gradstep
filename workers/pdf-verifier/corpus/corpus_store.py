"""Immutable diagnostic bundles and exclusive corpus run outputs.

The main build-store helper owns verifier bundles. This module owns only corpus
artifacts and never executes commands from archived provenance.
"""
from datetime import datetime, timezone
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parents[2]
OUT = ROOT/'.artifacts/pdf-verifier/corpus'
RESEARCH_STORE = OUT/'research-builds'
RUNS = OUT/'runs'
spec = importlib.util.spec_from_file_location('verifier_build_store', SOURCE.parent/'build_store.py')
build_store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_store)
RESEARCH_FILES = {'research_build.py':'instrumentation_recipe_sha256',
    'verifier-research.cpp':'wrapper_sha256', 'verifier-research.wasm':'wasm_sha256',
    'verifier-research.mjs':'javascript_sha256'}


def require(condition, code):
    if not condition: raise ValueError(code)


def identifier(value):
    require(isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value), 'invalid_build_identity')
    return value


def canonical(value): return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()
def read(path, maximum=16*1024*1024): return build_store.read(path, maximum)
def digest(raw): return build_store.digest(raw)


def json_value(raw):
    require(len(raw)<=262144, 'corpus_json_limit')
    def pairs(values):
        result={}
        for key,value in values:
            require(key not in result,'duplicate_corpus_key')
            result[key]=value
        return result
    return json.loads(raw,object_pairs_hook=pairs,
        parse_constant=lambda _:(_ for _ in ()).throw(ValueError('nonfinite_corpus_number')))


def verify_research_files(files, expected):
    require(digest(files['identity.json'])==identifier(expected),'research_identity_mismatch')
    identity=json_value(files['identity.json'])
    require(identity.get('research_only') is True and identity.get('limits_changed') is False
        and identity.get('hosted_admitted') is False,'invalid_research_identity')
    base=build_store.open_bundle(identifier(identity.get('original_build_identity_sha256')))
    original=json_value(read(base/'identity.json',262144))
    for research_key,original_key in [('original_wrapper_sha256','wrapper_sha256'),
        ('profile_sha256','profile_sha256'),('qpdf_library_sha256','qpdf_library_sha256')]:
        require(identity.get(research_key)==original[original_key],'research_base_mismatch')
    require(set(files)=={*RESEARCH_FILES,'identity.json','provenance.json'},'research_file_set_mismatch')
    for name,key in RESEARCH_FILES.items():
        require(digest(files[name])==identifier(identity.get(key)),'research_source_mismatch')
    require(json_value(files['provenance.json']).get('identity')==identity,'research_provenance_mismatch')
    return identity


def verify_research_directory(path, expected):
    require(not path.is_symlink() and path.is_dir(),'invalid_research_directory')
    manifest=json_value(read(path/'bundle.json',262144))
    require(set(manifest)=={'format','identity_sha256','files'} and manifest['format']==1
        and manifest['identity_sha256']==identifier(expected),'invalid_research_manifest')
    names={*RESEARCH_FILES,'identity.json','provenance.json'}
    require(set(manifest['files'])==names and {p.name for p in path.iterdir()}==names|{'bundle.json'},
        'research_file_set_mismatch')
    files={name:read(path/name) for name in names}
    for name,raw in files.items():
        require(digest(raw)==identifier(manifest['files'][name]),'research_bundle_file_mismatch')
    return verify_research_files(files,expected)


def open_research(expected, store=RESEARCH_STORE):
    require(not store.is_symlink(),'invalid_research_store')
    path=store/identifier(expected)
    verify_research_directory(path,expected)
    return path


def freeze_research(source, recipe, expected, store=RESEARCH_STORE):
    files={name:read(recipe if name=='research_build.py' else source/name)
        for name in {*RESEARCH_FILES,'identity.json','provenance.json'}}
    verify_research_files(files,expected)
    require(not store.is_symlink(),'invalid_research_store')
    store.mkdir(parents=True,exist_ok=True)
    with (store/'.publish.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        destination=store/identifier(expected)
        if destination.exists() or destination.is_symlink():
            verify_research_directory(destination,expected)
            for name,raw in files.items():
                if name!='provenance.json': require(read(destination/name)==raw,'existing_research_bundle_conflict')
            return destination
        temporary=Path(tempfile.mkdtemp(prefix='.'+expected+'-',dir=store))
        try:
            manifest={'format':1,'identity_sha256':expected,
                'files':{name:digest(raw) for name,raw in sorted(files.items())}}
            for name,raw in {**files,'bundle.json':canonical(manifest)}.items():
                with (temporary/name).open('xb') as stream:
                    stream.write(raw);stream.flush();os.fsync(stream.fileno())
            verify_research_directory(temporary,expected)
            for path in temporary.iterdir(): path.chmod(0o444)
            os.rename(temporary,destination);destination.chmod(0o555)
            return destination
        finally:
            if temporary.exists():
                temporary.chmod(0o755);shutil.rmtree(temporary)


def claim_run(kind, identity, run_id=None, root=RUNS):
    require(kind in ('benchmark','research','research-build','validation'),'invalid_run_kind')
    identifier(identity)
    if run_id is None: run_id=datetime.now(timezone.utc).strftime('%Y%m%dt%H%M%Sz').lower()+'-'+uuid.uuid4().hex[:12]
    require(isinstance(run_id,str) and re.fullmatch('[a-z0-9][a-z0-9_-]{0,79}',run_id),'invalid_run_id')
    require(not root.is_symlink(),'invalid_run_root')
    parent=root/kind/identity
    for path in (root/kind,parent): require(not path.is_symlink(),'invalid_run_parent')
    parent.mkdir(parents=True,exist_ok=True)
    run=parent/run_id
    try: run.mkdir()
    except FileExistsError: raise ValueError('run_already_exists') from None
    return run


def write_progress(run, report):
    require(not (run/'report.json').exists(),'run_already_finalized')
    temporary=run/'progress.json.tmp'
    with temporary.open('xb') as stream:
        stream.write(canonical(report));stream.flush();os.fsync(stream.fileno())
    os.replace(temporary,run/'progress.json')


def finalize(run, report):
    temporary=run/'report.json.tmp'
    with temporary.open('xb') as stream:
        stream.write(canonical(report));stream.flush();os.fsync(stream.fileno())
    try:
        # link is atomic and refuses an existing destination, unlike replace.
        os.link(temporary,run/'report.json')
        (run/'report.json').chmod(0o444)
    finally: temporary.unlink()
    return run/'report.json'
