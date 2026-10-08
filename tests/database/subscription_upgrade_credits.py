#!/usr/bin/env python3
"""Explicit pending-migration review in a disposable loopback database.

--baseline reproduces the approved-policy failure without loading the candidate.
No provider keys, Apple APIs, hosted database, grants outside fixtures, or migration
ledger writes are used. The pending file cannot enter normal deployment by accident.
"""
import argparse
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(os.environ.get('SCIENCE_READER_PG_BIN', '/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin'))
BASE = ['-h', '127.0.0.1', '-p', '55431']
PENDING = ROOT / 'supabase/migrations/202610080044_subscription_upgrade_credits.sql.pending'
ENV = {key: value for key, value in os.environ.items() if not key.startswith('PG')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', action='store_true')
    args = parser.parse_args()
    db = 'science_reader_test_subscription_' + uuid.uuid4().hex[:10]

    def run(binary, *params, **kw):
        return subprocess.run([str(BIN / binary), *BASE, *params], env=ENV, check=True, **kw)

    run('createdb', db)
    try:
        run('psql', '-X', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres', '-c', f'ALTER DATABASE "{db}" SET timezone TO \'UTC\'', capture_output=True)
        sources = [ROOT / 'tests/database/bootstrap.sql', *sorted((ROOT / 'supabase/migrations').glob('*.sql'))]
        if not args.baseline:
            if not PENDING.is_file():
                raise RuntimeError('Candidate pending migration is not present')
            sources.append(PENDING)
        for source in sources:
            run('psql', '-X', '-v', 'ON_ERROR_STOP=1', '-d', db, '-f', str(source), capture_output=True, text=True)
        print('PASS isolated schema loaded; mode=' + ('baseline' if args.baseline else 'candidate'), flush=True)
        result = run('psql', '-X', '-v', 'ON_ERROR_STOP=1', '-d', db,
                     '-f', str(ROOT / 'tests/database/candidates/subscription_upgrade_credits.sql'), capture_output=True, text=True)
        print('PASS approved subscription upgrade credit regression', flush=True)
    except subprocess.CalledProcessError as error:
        print(error.stderr or '')
        raise SystemExit(1)
    finally:
        run('dropdb', db)


if __name__ == '__main__':
    main()
