#!/usr/bin/env python3
"""Hard process wall timeout for local fixtures; not an Edge CPU-limit claim."""
import json
from pathlib import Path
import resource
import subprocess
import time

REPO = Path(__file__).resolve().parents[3]
OUT = REPO / '.artifacts/pdf-verifier'
DENO = REPO / 'node_modules/@deno/darwin-arm64/deno'
fixtures = json.loads((OUT / 'fixtures/manifest.json').read_text())
profile = json.loads((REPO / 'workers/pdf-verifier/profile.json').read_text())
results = []
for name, mode in [(value['name'], '') for value in fixtures] + [('probe-oom', ''), ('probe-stack', ''), ('pages-50', 'warm')]:
    command = [str(DENO), 'run', '--no-config', '--no-prompt', '--allow-read=workers/pdf-verifier,.artifacts/pdf-verifier',
               'workers/pdf-verifier/tests/smoke.ts', name] + ([mode] if mode else [])
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
(OUT / 'smoke-results.json').write_text(json.dumps(results, indent=2) + '\n')
raise SystemExit(1 if any(value['exit_code'] != 0 for value in results) else 0)
