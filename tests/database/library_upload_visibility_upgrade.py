"""Populated038→039 compatibility, on a disposable loopback database only."""
import json
import os
from pathlib import Path
import subprocess
import uuid


def verify(binary, _database, base, root, migration_override=None):
    root = Path(root)
    database = 'science_reader_test_' + uuid.uuid4().hex[:12]
    if base != ['-h', '127.0.0.1', '-p', '55431']:
        raise RuntimeError('Visibility upgrade only permits the disposable loopback fixture')
    env = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
    env['PGCONNECT_TIMEOUT'] = '5'

    def run(name, args, source=None):
        result = subprocess.run([str(Path(binary) / name), *base, *args], input=source,
                                env=env, text=True, capture_output=True, timeout=120)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout.strip()

    def sql(source):
        return run('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database], source)

    def state():
        return json.loads(sql("""select set_config('request.jwt.claim.sub','39500000-0000-0000-0000-000000000091',false);
          select jsonb_build_object('full2',public.v2_library_page(),'full3',public.v3_library_page(),
            'delta2',public.v2_library_changes(0),'delta3',public.v3_library_changes(0),
            'journal',(select jsonb_agg(jsonb_build_object('seq',seq,'entries',entries,'bytes',encoded_bytes) order by seq)
              from app_private.library_changes where account_id='39500000-0000-0000-0000-000000000091'),
            'commands',(select jsonb_agg(to_jsonb(c) order by id) from app_private.library_commands c
              where account_id='39500000-0000-0000-0000-000000000091'));
        """).splitlines()[-1])

    run('createdb', [database])
    try:
        run('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres', '-c',
                     f'ALTER DATABASE "{database}" SET timezone TO \'UTC\''])
        migrations = sorted((root / 'supabase/migrations').glob('*.sql'))
        prefix = [path for path in migrations if path.name < '202610070039']
        for path in [root / 'tests/database/bootstrap.sql', *prefix]:
            run('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', database, '-f', str(path)])
        sql("""insert into auth.users values('39500000-0000-0000-0000-000000000091');
          select set_config('request.jwt.claim.sub','39500000-0000-0000-0000-000000000091',false);
          select public.v2_begin_import('39500000-0000-0000-0000-000000000092','2410.03991',0,1);
          select public.v2_begin_web_import('39500000-0000-0000-0000-000000000093','openalex:W395091',1);
        """)
        before = state()
        epoch = sql('select dataset_epoch from app_private.library_v4_config;')
        migration = Path(migration_override) if migration_override else root / 'supabase/migrations/202610070039_pdf_uploads.sql'
        run('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', database, '-f', str(migration)])
        after = state()
        if after != before:
            raise AssertionError('Populated upgrade changed legacy wire, immutable journal or command receipts: '
                                 + ','.join(key for key in before if before[key] != after[key]))
        if sql('select dataset_epoch from app_private.library_v4_config;') == epoch:
            raise AssertionError('Changed compact projection retained its old dataset identity')
        projected = json.loads(sql("""select jsonb_agg(jsonb_build_object('level',minimum_source_level,
            'source',entry->>'source','stored',entry->'minimum_source_level') order by created_seq)
          from app_private.library_v4_entries where account_id='39500000-0000-0000-0000-000000000091';"""))
        if projected != [{'level': 2, 'source': 'arxiv', 'stored': 2}, {'level': 3, 'source': 'web', 'stored': 3}]:
            raise AssertionError('Populated projection visibility was not rebuilt coherently')
        levels = sql("""select array_agg(minimum_source_level order by seq) from app_private.library_changes
          where account_id='39500000-0000-0000-0000-000000000091';""")
        if levels != '{2,3}':
            raise AssertionError('Historical unstamped journal generated visibility is incorrect')
        print('PASS populated038→039 visibility upgrade: old full wire/journal/receipts unchanged; projection epochs rotated', flush=True)
    finally:
        run('dropdb', [database])
