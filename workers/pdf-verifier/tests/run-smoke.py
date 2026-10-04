#!/usr/bin/env python3
"""Hard local process wall timeout; fresh build/run evidence, no Edge CPU claim."""
import importlib.util
import json
from pathlib import Path
import resource
import subprocess
import time
import uuid

REPO = Path(__file__).resolve().parents[3]
OUT = REPO / '.artifacts/pdf-verifier'
DENO = REPO / 'node_modules/@deno/darwin-arm64/deno'
spec = importlib.util.spec_from_file_location('pdf_smoke_build_store', REPO / 'workers/pdf-verifier/build_store.py')
store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store)


def selected_build():
    pointer = store.json_value(store.read(OUT / 'current-build.json', 1024))
    store.require(isinstance(pointer, dict) and set(pointer) == {'format', 'identity_sha256'}
                  and type(pointer['format']) is int and pointer['format'] == 1, 'invalid_current_build')
    build_id = store.identifier(pointer['identity_sha256'])
    bundle = store.open_bundle(build_id)
    return build_id, store.json_value(store.read(bundle / 'identity.json', 262144))


def main():
    build_id, identity = selected_build()
    profile = identity['profile']
    fixture_bytes = store.read(OUT / 'fixtures/manifest.json', 262144)
    fixtures = store.json_value(fixture_bytes)
    run_id = str(uuid.uuid4())
    directory = OUT / 'evidence' / build_id / 'smoke' / run_id
    directory.mkdir(parents=True, exist_ok=False)
    results = []
    evidence = {'format': 1, 'run_id': run_id, 'build_identity_sha256': build_id,
                'profile_sha256': identity['profile_sha256'], 'fixture_manifest_sha256': store.digest(fixture_bytes),
                'scope': 'local child process measurements; no hosted admission', 'results': results}
    for name, mode in [(value['name'], '') for value in fixtures] + [('probe-oom', ''), ('probe-stack', ''), ('pages-50', 'warm')]:
        command = [str(DENO), 'run', '--no-config', '--no-prompt', '--allow-read=workers/pdf-verifier,.artifacts/pdf-verifier',
                   'workers/pdf-verifier/tests/smoke.ts', name, mode, build_id]
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        start = time.monotonic()
        try:
            completed = subprocess.run(command, cwd=REPO, capture_output=True, text=True,
                                       timeout=profile['local_wall_timeout_ms'] / 1000)
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            record = {'name': name, 'mode': mode, 'exit_code': completed.returncode,
                      'process_wall_ms': (time.monotonic() - start) * 1000,
                      'process_cpu_ms': ((after.ru_utime + after.ru_stime) - (before.ru_utime + before.ru_stime)) * 1000,
                      'stdout': completed.stdout, 'stderr': completed.stderr}
        except subprocess.TimeoutExpired:
            record = {'name': name, 'mode': mode, 'outcome': 'time_limit', 'exit_code': -1,
                      'process_wall_ms': (time.monotonic() - start) * 1000}
        results.append(record)
        print(json.dumps({key: value for key, value in record.items() if key not in ('stdout', 'stderr')}), flush=True)
    with (directory / 'results.json').open('x') as result_file:
        result_file.write(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps({'build_identity_sha256': build_id, 'run_id': run_id,
                      'results': str((directory / 'results.json').relative_to(REPO))}), flush=True)
    return 1 if any(value['exit_code'] != 0 for value in results) else 0


if __name__ == '__main__':
    raise SystemExit(main())
