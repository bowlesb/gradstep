#!/usr/bin/env python3
"""Capture immutable local sources and fixed assets. No authentication/deployment."""
import argparse
import base64
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
ARTIFACTS = ROOT / '.artifacts/pdf-verifier'
BUILD_SHA256 = '39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610'
FIXTURE_MANIFEST_SHA256 = '8c76c68f86b16a71b9ef0f85d044e69923866ba69f9d0f91cb9672ae3134be43'
CASES = ('deny_missing_auth', 'deny_wrong_run', 'deny_invalid_case', 'control',
         'cpu-wasm', 'memory-wasm', 'background', 'recovery')
INPUTS = ('package.py', 'wasm_recipe.py', 'handler.ts', 'workloads.ts', 'auth.ts', 'index.ts.in')
spec = importlib.util.spec_from_file_location('limits_build_store', HERE.parent / 'build_store.py')
STORE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(STORE)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode('utf-8')


def require(ok, code):
    if not ok:
        raise ValueError(code)


def identifier(value):
    require(type(value) is str, 'invalid_probe_id')
    try:
        parsed = str(uuid.UUID(value))
    except ValueError:
        raise ValueError('invalid_probe_id') from None
    require(parsed == value, 'invalid_probe_id')
    return value


def checked(path, expected, maximum=16 * 1024 * 1024):
    raw = STORE.read(path, maximum)
    require(digest(raw) == expected, 'probe_artifact_mismatch')
    return raw


def capture_inputs():
    return {name: STORE.read(HERE / name, 262144) for name in INPUTS}


def assemble(run_id, user_id, created_at, attempt_ids):
    """All generated/copied executable bytes derive from this captured snapshot."""
    identifier(run_id); identifier(user_id)
    require(run_id != user_id and type(created_at) is int and created_at > 0, 'invalid_probe_config')
    require(type(attempt_ids) in (list, tuple) and len(attempt_ids) == 8, 'invalid_probe_attempts')
    attempts = [identifier(value) for value in attempt_ids]
    require(len(set(attempts + [run_id, user_id])) == 10, 'invalid_probe_attempts')
    captured = capture_inputs()
    # Execute this exact trusted local recipe snapshot, not a mutable imported
    # module that might differ from the recipe hash recorded in the manifest.
    recipe = {'__name__': 'captured_synthetic_recipe'}
    exec(compile(captured['wasm_recipe.py'], '<captured-synthetic-recipe>', 'exec'), recipe)
    synthetic = recipe['module_bytes']()
    checksum = recipe['expected_checksum']()
    require(type(synthetic) is bytes and len(synthetic) <= 1024 and type(checksum) is int, 'invalid_synthetic_recipe')
    bundle = STORE.open_bundle(BUILD_SHA256)
    identity_raw = checked(bundle / 'identity.json', BUILD_SHA256, 262144)
    identity = STORE.json_value(identity_raw)
    glue = checked(bundle / 'verifier.mjs', identity['javascript_sha256'])
    wasm = checked(bundle / 'verifier.wasm', identity['wasm_sha256'])
    runtime = checked(bundle / 'runtime.ts', identity['runtime_sha256'])
    inspector = checked(bundle / 'wasm.ts', identity['memory_inspector_sha256'])
    fixtures_raw = checked(ARTIFACTS / 'fixtures/manifest.json', FIXTURE_MANIFEST_SHA256, 262144)
    fixtures = STORE.json_value(fixtures_raw)
    choices = [entry for entry in fixtures if entry['name'] == 'pages-1']
    require(len(choices) == 1, 'invalid_recovery_fixture')
    entry = choices[0]
    require(entry['file'] == 'pages-1.pdf' and entry['expected'] == 'verified' and entry['pages'] == 1
            and type(entry['bytes']) is int and 0 < entry['bytes'] <= 5242880, 'invalid_recovery_fixture')
    pdf = checked(ARTIFACTS / 'fixtures/pages-1.pdf', entry['sha256'], 5242880)
    require(len(pdf) == entry['bytes'], 'invalid_recovery_fixture')
    fixture = {'base64': base64.b64encode(pdf).decode('ascii'), 'bytes': len(pdf), 'sha256': entry['sha256']}
    requests = [{'case': name, 'attempt_id': attempt} for name, attempt in zip(CASES, attempts)]
    slug = 'pdf-verifier-probe-' + run_id[:8]
    config = {'project': 'coxhjvqpflgxkleydati', 'runID': run_id, 'userID': user_id,
              'createdAt': created_at, 'expiresAt': created_at + 1200000, 'buildSHA256': BUILD_SHA256,
              'path': '/' + slug, 'requests': [{'case': item['case'], 'attemptID': item['attempt_id']} for item in requests]}
    assets = {'config': config, 'profile': identity['profile'], 'profileSHA256': identity['profile_sha256'],
              'wasmSHA256': identity['wasm_sha256'], 'wasmBase64': base64.b64encode(wasm).decode('ascii'),
              'fixture': fixture, 'syntheticBase64': base64.b64encode(synthetic).decode('ascii'),
              'syntheticSHA256': digest(synthetic)}
    files = {'index.ts': captured['index.ts.in'], 'handler.ts': captured['handler.ts'],
             'workloads.ts': captured['workloads.ts'], 'auth.ts': captured['auth.ts'],
             'runtime.ts': runtime, 'wasm.ts': inspector, 'verifier.mjs': glue,
             'assets.ts': b''.join(b'export const ' + key.encode('ascii') + b' = ' + canonical(value) + b' as const;\n'
                                  for key, value in assets.items())}
    total = sum(len(raw) for raw in files.values())
    require(total <= 3000000, 'probe_source_limit')
    cli_config = ('project_id = "science-reader-limits"\n\n[functions.' + slug + ']\nverify_jwt = false\n').encode()
    preserved = {**captured, 'synthetic.wasm': synthetic, 'verifier-identity.json': identity_raw,
                 'fixture-manifest.json': fixtures_raw, 'recovery.pdf': pdf}
    manifest = {'format': 1, 'scope': 'fixed host limits experiment only; no hosted admission',
                'config': config, 'requests': requests, 'build_sha256': BUILD_SHA256,
                'fixture_manifest_sha256': FIXTURE_MANIFEST_SHA256,
                'recovery_fixture_sha256': entry['sha256'], 'synthetic_sha256': digest(synthetic),
                'synthetic_chunk_iterations': recipe['ITERATIONS'], 'synthetic_seed': recipe['SEED'],
                'synthetic_first_checksum': checksum, 'source_bytes': total,
                'supabase_config_sha256': digest(cli_config),
                'source_files': {name: digest(raw) for name, raw in sorted(files.items())},
                'producer_files': {name: digest(raw) for name, raw in sorted(captured.items())},
                'captured_files': {name: digest(raw) for name, raw in sorted(preserved.items())}}
    return slug, config, requests, files, manifest, preserved, cli_config


def build(run_id, user_id, created_at, attempt_ids, *, output_root=None):
    slug, config, requests, files, manifest, captured, cli_config = assemble(run_id, user_id, created_at, attempt_ids)
    root = output_root or ARTIFACTS / 'hosted-limits'
    require(type(root) is type(Path()) and not root.is_symlink(), 'invalid_package_directory')
    root.mkdir(parents=True, exist_ok=True)
    work = root / run_id
    encoded = canonical(manifest)
    with (root / '.package.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        require(not work.exists() and not work.is_symlink(), 'package_exists')
        temporary = Path(tempfile.mkdtemp(prefix='.' + run_id + '-', dir=root))
        try:
            output = {str(Path('supabase/functions') / slug / name): raw for name, raw in files.items()}
            output.update({str(Path('captured') / name): raw for name, raw in captured.items()})
            output['source-manifest.json'] = encoded
            output['supabase/config.toml'] = cli_config
            for name, raw in output.items():
                destination = temporary / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                with destination.open('xb') as stream:
                    stream.write(raw); stream.flush(); os.fsync(stream.fileno())
                destination.chmod(0o444)
            # Sources are immutable; the run root remains writable for the
            # separately owned operator's evidence and cleanup journal.
            (temporary / 'supabase/.temp').mkdir()
            for folder in sorted((x for x in temporary.rglob('*') if x.is_dir()), reverse=True):
                STORE.fsync_directory(folder)
                folder.chmod(0o755 if folder in {temporary / 'supabase', temporary / 'supabase/.temp'} else 0o555)
            STORE.fsync_directory(temporary)
            os.rename(temporary, work)
            STORE.fsync_directory(root)
        finally:
            if temporary.exists():
                for folder in temporary.rglob('*'):
                    if folder.is_dir(): folder.chmod(0o755)
                shutil.rmtree(temporary)
    try:
        directory = str(work.relative_to(ROOT))
    except ValueError:
        directory = str(work)  # Local test stores only; operator refuses them.
    return {'directory': directory, 'function': slug, 'source_manifest_sha256': digest(encoded),
            'source_bytes': manifest['source_bytes'], 'config': config, 'requests': requests}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--user-id', required=True)
    parser.add_argument('--attempt-id', action='append', required=True)
    args = parser.parse_args()
    print(json.dumps(build(args.run_id, args.user_id, int(time.time() * 1000), args.attempt_id)))
