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
            if name in ('upgrade', 'original_execution_upgrade'):
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
parser.add_argument('--candidate', type=pathlib.Path, help='Explicit local 012 .sql.pending candidate; never deployed.')
parser.add_argument('--original-candidate', type=pathlib.Path, help='Explicit local 013 original-execution candidate; never deployed.')
selection = parser.add_mutually_exclusive_group()
selection.add_argument('--metadata-only', action='store_true', help='Run only the isolated 012 schema and executor regressions.')
selection.add_argument('--original-only', action='store_true', help='Run original execution, post-013 metadata compatibility and 012-to-013 upgrade checks.')
args = parser.parse_args()
migrations = sorted((ROOT / 'supabase/migrations').glob('*.sql'))
if any(p.name > '202610030012_metadata_execution.sql' for p in migrations):
    parser.error('a later migration needs an explicit test phase; refusing to silently skip it')
if args.candidate and any(p.name.startswith('202610030012_') for p in migrations):
    parser.error('012 already has an immutable .sql source; do not substitute a pending candidate')
prefix = [p for p in migrations if p.name < '202610030012']
candidate = args.candidate.resolve() if args.candidate else next((p for p in migrations if p.name.startswith('202610030012_')), None)
if candidate is not None and (candidate.parent != ROOT / 'supabase/migrations' or
        candidate.name not in ('202610030012_metadata_execution.sql.pending', '202610030012_metadata_execution.sql') or not candidate.is_file()):
    parser.error('candidate must be the local 012 metadata execution migration')
if args.metadata_only and candidate is None:
    parser.error('--metadata-only requires the explicit 012 candidate or applied local source')
original = args.original_candidate.resolve() if args.original_candidate else None
if original is not None and (original.parent != ROOT / 'supabase/migrations' or
        original.name != '202610040013_original_execution.sql.pending' or not original.is_file()):
    parser.error('original candidate must be the explicit local 013 original execution migration')
if original is not None and candidate is None:
    parser.error('--original-candidate requires the explicit 012 candidate or applied local source')
if args.metadata_only and original is not None:
    parser.error('--metadata-only cannot include an original candidate')
if args.original_only and original is None:
    parser.error('--original-only requires --original-candidate')
if not args.metadata_only and not args.original_only:
    # 011's positive legacy execution tests remain real tests of the immutable
    # 001--011 prefix. They cannot run after 012 deliberately revokes those APIs.
    legacy_tests = [p for p in sorted((ROOT / 'tests/database').glob('test_*.sql'))
                    if p.name not in ('test_metadata_execution.sql', 'test_original_execution.sql')]
    phase([*prefix, *legacy_tests], ['concurrency', 'upgrade'])
if candidate is not None and not args.original_only:
    phase([*prefix, candidate, ROOT / 'tests/database/test_metadata_execution.sql'], ['metadata_execution_concurrency'])
if original is not None:
    # The unchanged metadata suite must still pass on the widened shared tables.
    phase([*prefix, candidate, original, ROOT / 'tests/database/test_metadata_execution.sql'], ['metadata_execution_concurrency'])
    phase([*prefix, candidate, original, ROOT / 'tests/database/test_original_execution.sql'], ['original_execution_concurrency'])
    # The upgrade verifier seeds 012 history, checks disabled-state preflight,
    # applies this same fixed local candidate, then checks byte preservation.
    phase([*prefix, candidate], ['original_execution_upgrade'])
