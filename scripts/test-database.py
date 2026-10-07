#!/usr/bin/env python3
"""Fresh disposable local DB. Refuses remote hosts; never uses TextBrain's DB."""
import os
import pathlib
import subprocess
import uuid
import importlib.util
import argparse

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(os.environ.get('SCIENCE_READER_PG_BIN', '/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin'))
BASE = ['-h', '127.0.0.1', '-p', '55431']
# Every operation targets the disposable loopback fixture. Inherited libpq
# services/options/users must not redirect or alter that authority.
for key in list(os.environ):
    if key.startswith('PG'):
        del os.environ[key]

def run(binary, args, **kwargs):
    return subprocess.run([str(BIN / binary), *BASE, *args], check=True, **kwargs)

def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f'tests/database/{name}.py')
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def phase(sources, checks):
    db = 'science_reader_test_' + uuid.uuid4().hex[:12]
    run('createdb', [db])
    try:
        # Application receipts use UTC days. Persist the fixture setting so all
        # independent psql/race sessions share it, including around UTC midnight.
        run('psql', ['-X', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres', '-c', f'ALTER DATABASE "{db}" SET timezone TO \'UTC\''], capture_output=True)
        for source in [ROOT / 'tests/database/bootstrap.sql', *sources]:
            run('psql', ['-X', '-v', 'ON_ERROR_STOP=1', '-d', db, '-f', str(source)], capture_output=True, text=True)
            print('PASS', source.relative_to(ROOT), flush=True)
        for name in checks:
            if name in ('upgrade', 'library_compact_upgrade'):
                module(name).verify(BIN, db, BASE, ROOT)
            else:
                module(name).verify(BIN, db, BASE)
    except subprocess.CalledProcessError as error:
        print(error.stdout or '')
        print(error.stderr or '')
        raise
    finally:
        run('dropdb', [db])


parser = argparse.ArgumentParser(description=__doc__)
parser.parse_args()
migrations = sorted((ROOT / 'supabase/migrations').glob('*.sql'))
tests = sorted((ROOT / 'tests/database').glob('test_*.sql'))
phase([*migrations, *tests], ['concurrency', 'upgrade', 'library_compact_upgrade', 'library_query_concurrency', 'store_verification_concurrency'])
