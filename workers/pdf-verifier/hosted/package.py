#!/usr/bin/env python3
"""Build a closed, expiring probe package. Does not authenticate or deploy."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'workers/pdf-verifier'
ARTIFACTS = ROOT / '.artifacts/pdf-verifier'
BUILD_SHA256 = '2fea7b1c8f842c4c9402720a2f5c4ad8e9b7c343bcea5c6ee29210f1606028b0'
FIXTURE_MANIFEST_SHA256 = '8c76c68f86b16a71b9ef0f85d044e69923866ba69f9d0f91cb9672ae3134be43'
CASES = ['pages-1', 'pages-25', 'pages-50', 'pages-51', 'not-pdf', 'corrupt-flate',
         'unsupported-filter', 'stream-budget', 'object-stream-small', 'object-stream-oom', 'job-json-encrypt-40']


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def checked(path, expected):
    raw = path.read_bytes()
    if digest(raw) != expected:
        raise RuntimeError('Probe packaging refused an artifact hash mismatch: ' + path.name)
    return raw


def build(run_id, user_id, created_at):
    run_id, user_id = str(uuid.UUID(run_id)), str(uuid.UUID(user_id))
    if not isinstance(created_at, int) or created_at <= 0:
        raise RuntimeError('Invalid probe creation time')
    identity = json.loads(checked(ARTIFACTS / 'dist/identity.json', BUILD_SHA256))
    glue = checked(ARTIFACTS / 'dist/verifier.mjs', identity['javascript_sha256'])
    wasm = checked(ARTIFACTS / 'dist/verifier.wasm', identity['wasm_sha256'])
    runtime = checked(SOURCE / 'runtime.ts', identity['runtime_sha256'])
    inspector = checked(SOURCE / 'wasm.ts', identity['memory_inspector_sha256'])
    manifest = json.loads(checked(ARTIFACTS / 'fixtures/manifest.json', FIXTURE_MANIFEST_SHA256))
    fixtures = {}
    for name in CASES:
        matches = [entry for entry in manifest if entry['name'] == name]
        if len(matches) != 1:
            raise RuntimeError('Invalid probe fixture manifest')
        entry = matches[0]
        if entry['file'] != name + '.pdf' or entry['bytes'] > 5242880:
            raise RuntimeError('Invalid probe fixture identity')
        raw = checked(ARTIFACTS / 'fixtures' / entry['file'], entry['sha256'])
        if len(raw) != entry['bytes']:
            raise RuntimeError('Invalid probe fixture length')
        fixtures[name] = {'base64': base64.b64encode(raw).decode('ascii'), 'bytes': len(raw),
                          'sha256': entry['sha256'], 'expected': entry['expected'],
                          'pages': entry.get('pages') if entry['expected'] == 'verified' else None}
    slug = 'pdf-verifier-probe-' + run_id[:8]
    config = {'project': 'coxhjvqpflgxkleydati', 'runID': run_id, 'userID': user_id,
              'createdAt': created_at, 'expiresAt': created_at + 1200000,
              'buildSHA256': BUILD_SHA256, 'path': '/' + slug}
    assets = {
        'config': config, 'profile': identity['profile'], 'profileSHA256': identity['profile_sha256'],
        'wasmSHA256': identity['wasm_sha256'], 'wasmBase64': base64.b64encode(wasm).decode('ascii'),
        'fixtures': fixtures,
    }
    files = {
        'index.ts': (SOURCE / 'hosted/index.ts.in').read_bytes(),
        'hosted/handler.ts': (SOURCE / 'hosted/handler.ts').read_bytes(),
        'runtime.ts': runtime, 'wasm.ts': inspector, 'verifier.mjs': glue,
        'assets.ts': ''.join('export const ' + key + ' = ' + json.dumps(value, separators=(',', ':')) + ' as const;\n'
                             for key, value in assets.items()).encode('utf-8'),
    }
    total = sum(len(raw) for raw in files.values())
    if total > 3000000:
        raise RuntimeError('Probe source exceeds the reviewed package bound')
    work = ARTIFACTS / 'hosted' / run_id
    if work.exists():
        raise RuntimeError('Refusing to overwrite an existing probe run')
    function = work / 'supabase/functions' / slug
    function.mkdir(parents=True)
    for name, raw in files.items():
        destination = function / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
    (work / 'supabase/config.toml').write_text('project_id = "science-reader-probe"\n\n[functions.' + slug + ']\nverify_jwt = false\n')
    evidence = {'scope': 'compatibility probe only; no hosted admission', 'config': config,
                'build_sha256': BUILD_SHA256, 'fixture_manifest_sha256': FIXTURE_MANIFEST_SHA256,
                'source_bytes': total, 'source_files': {name: digest(raw) for name, raw in sorted(files.items())}}
    encoded = json.dumps(evidence, sort_keys=True, separators=(',', ':')).encode('utf-8')
    (work / 'source-manifest.json').write_bytes(encoded)
    return {'directory': str(work.relative_to(ROOT)), 'function': slug,
            'source_manifest_sha256': digest(encoded), 'source_bytes': total, 'config': config}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--user-id', required=True)
    args = parser.parse_args()
    print(json.dumps(build(args.run_id, args.user_id, int(time.time() * 1000))))
