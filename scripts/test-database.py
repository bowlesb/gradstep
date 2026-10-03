#!/usr/bin/env python3
"""Fresh disposable local DB. Refuses remote hosts; never uses TextBrain's DB."""
import os
import pathlib
import subprocess
import uuid
import importlib.util

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get('SCIENCE_READER_PG_BIN', '/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin'))
DB = 'science_reader_test_' + uuid.uuid4().hex[:12]
BASE = ['-h', '127.0.0.1', '-p', '55431']

def run(binary, args, **kwargs):
    return subprocess.run([str(BIN / binary), *BASE, *args], check=True, **kwargs)

run('createdb', [DB])
try:
    for source in [ROOT / 'tests/database/bootstrap.sql', *sorted((ROOT / 'supabase/migrations').glob('*.sql')), *sorted((ROOT / 'tests/database').glob('test_*.sql'))]:
        result = run('psql', ['-X', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-f', str(source)], capture_output=True, text=True)
        print('PASS', source.relative_to(ROOT))
    spec = importlib.util.spec_from_file_location('concurrency', ROOT / 'tests/database/concurrency.py')
    concurrency = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(concurrency)
    concurrency.verify(BIN, DB, BASE)
    spec = importlib.util.spec_from_file_location('upgrade', ROOT / 'tests/database/upgrade.py')
    upgrade = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(upgrade)
    upgrade.verify(BIN, DB, BASE, ROOT)
    print('Database:', DB)
except subprocess.CalledProcessError as error:
    print(error.stdout or '')
    print(error.stderr or '')
    raise
finally:
    run('dropdb', [DB])
