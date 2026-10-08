"""Populated038→039 compatibility, on a disposable loopback database only."""
import json
import os
from pathlib import Path
import select
import subprocess
import time
import uuid


def verify(binary, _database, base, root, migration_override=None):
    root = Path(root)
    database = 'science_reader_test_' + uuid.uuid4().hex[:12]
    if base != ['-h', '127.0.0.1', '-p', '55431']:
        raise RuntimeError('Visibility upgrade only permits the disposable loopback fixture')
    env = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
    env['PGCONNECT_TIMEOUT'] = '5'
    sessions = []

    def run(name, args, source=None):
        result = subprocess.run([str(Path(binary) / name), *base, *args], input=source,
                                env=env, text=True, capture_output=True, timeout=120)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout.strip()

    def sql(source):
        return run('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database], source)

    class Session:
        """Independent connection with bounded, observable PostgreSQL barriers."""
        def __init__(self):
            self.process = subprocess.Popen(
                [str(Path(binary) / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            self.buffer = b''
            sessions.append(self)
            self.pid = int(self.complete("set statement_timeout='20s'; select pg_backend_pid();")[-1])

        def send(self, source):
            marker = 'barrier_' + uuid.uuid4().hex
            self.process.stdin.write((source + f"\nselect '{marker}';\n").encode())
            self.process.stdin.flush()
            return marker

        def until(self, marker):
            deadline, lines = time.monotonic() + 25, []
            while time.monotonic() < deadline:
                while b'\n' in self.buffer:
                    raw, self.buffer = self.buffer.split(b'\n', 1)
                    line = raw.decode().strip()
                    if line == marker:
                        return lines
                    if line:
                        lines.append(line)
                if select.select([self.process.stdout], [], [], .05)[0]:
                    chunk = os.read(self.process.stdout.fileno(), 65536)
                    if not chunk:
                        raise AssertionError(self.process.stderr.read().decode())
                    self.buffer += chunk
            raise AssertionError('Visibility migration SQL barrier timed out')

        def complete(self, source):
            return self.until(self.send(source))

        def close(self):
            if not self.process.stdin.closed:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=3)
            self.process.stdout.close()
            self.process.stderr.close()

    def migration_waits_on_account(migration, writer):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if sql(f"""select {writer.pid}=any(pg_blocking_pids({migration.pid})) and exists(
              select 1 from pg_locks where pid={migration.pid} and locktype='relation'
                and relation='app_private.accounts'::regclass and mode='ExclusiveLock' and not granted);""") == 't':
                return
            if migration.process.poll() is not None:
                raise AssertionError(migration.process.stderr.read().decode())
            time.sleep(.02)
        raise AssertionError('Migration did not wait at its account-table admission gate')

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
        # A real import can already own its account when the migration starts.
        # Pause at that existing runtime boundary, then let 039 demonstrably
        # wait for it. The import must still reach its downstream tables and
        # commit before DDL proceeds. A late account-table gate instead holds
        # import/pipeline DDL locks and deadlocks this exact continuation.
        writer_account = '39500000-0000-0000-0000-000000000081'
        operation = '39500000-0000-0000-0000-000000000082'
        sql(f"insert into auth.users values('{writer_account}');")
        writer, upgrading = Session(), Session()
        writer.complete(f"begin; select app_private.lock_library_account('{writer_account}');")
        migration_path = str(migration.resolve()).replace("\\", "\\\\").replace("'", "\\'")
        finished = upgrading.send(f"\\i '{migration_path}'")
        migration_waits_on_account(upgrading, writer)
        receipt = json.loads(writer.complete(f"""set local role authenticated;
          select set_config('request.jwt.claim.sub','{writer_account}',true);
          select public.v2_begin_import('{operation}','2410.03981',0,1);""")[-1])['result']
        if receipt['status'] != 'applied' or receipt['id'] != operation:
            raise AssertionError('Concurrent installed-client import was not applied')
        writer.complete('commit;')
        upgrading.until(finished)
        imported = json.loads(sql(f"""select jsonb_build_object(
          'receipt',(select result from app_private.library_commands where account_id='{writer_account}' and id='{operation}'),
          'linked',exists(select 1 from app_private.pipeline_imports pi join app_private.pipeline_papers p on p.id=pi.paper_id
            where pi.account_id='{writer_account}' and pi.import_id='{operation}' and p.source_id='2410.03981'));"""))
        if imported != {'receipt': receipt, 'linked': True}:
            raise AssertionError('Concurrent import receipt or pipeline link changed during upgrade')
        print('PASS 038→039 account-table gate lets an in-flight authenticated import commit before downstream DDL', flush=True)
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
        for session in reversed(sessions):
            session.close()
        run('dropdb', [database])
