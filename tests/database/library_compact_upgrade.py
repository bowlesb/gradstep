"""Populated 030 -> 031 -> 032 backfill/read races, disposable loopback only.

The database runner may call verify(bin_path, db, base, root). Running this file
directly uses the same dedicated local test PostgreSQL port; no hosted requests.
"""
import json
import os
import pathlib
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base, root):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing a non-disposable/non-loopback compact upgrade target')
    target = db + '_compact_upgrade'
    if len(target) > 63 or not all(c.isalnum() or c == '_' for c in target):
        raise ValueError('Invalid disposable database name')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    sessions = []

    def run(binary, args, **kwargs):
        return subprocess.run([str(bin_path / binary), *base, *args], env=env, check=True, **kwargs)

    def sql(source):
        result = run('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', target],
                     input=source, text=True, capture_output=True, timeout=30)
        return result.stdout.strip()

    def value(source):
        return sql(source).splitlines()[-1]

    def claims(account):
        return f"set role authenticated; select set_config('request.jwt.claim.sub','{account}',false);"

    class Session:
        """Independent psql connection with explicit, observable SQL barriers."""
        def __init__(self):
            self.process = subprocess.Popen(
                [str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', target],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            self.buffer = b''
            sessions.append(self)
            lines = self.complete("set statement_timeout='10s'; set lock_timeout='5s'; select pg_backend_pid();")
            self.pid = int(lines[-1])

        def send(self, source):
            self.process.stdin.write((source + '\n').encode())
            self.process.stdin.flush()

        def until(self, marker):
            deadline = time.monotonic() + 12
            lines = []
            while time.monotonic() < deadline:
                while b'\n' in self.buffer:
                    line, self.buffer = self.buffer.split(b'\n', 1)
                    text = line.decode().strip()
                    if text == marker:
                        return lines
                    if text:
                        lines.append(text)
                if select.select([self.process.stdout], [], [], .1)[0]:
                    chunk = os.read(self.process.stdout.fileno(), 65536)
                    if not chunk:
                        raise AssertionError(self.process.stderr.read().decode())
                    self.buffer += chunk
            raise AssertionError('SQL barrier timed out')

        def complete(self, source):
            marker = 'barrier_' + uuid.uuid4().hex
            self.send(source + f" select '{marker}';")
            return self.until(marker)

        def error(self, expected):
            code = self.process.wait(timeout=12)
            detail = self.process.stderr.read().decode()
            assert code != 0 and expected in detail, detail

        def close(self):
            if self.process.stdin and not self.process.stdin.closed:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=3)
            self.process.stdout.close()
            self.process.stderr.close()

    def blocked_by(waiter, holder):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if value(f"select {holder.pid}=any(pg_blocking_pids({waiter.pid}));") == 't':
                return
            if waiter.process.poll() is not None:
                raise AssertionError(waiter.process.stderr.read().decode())
            time.sleep(.02)
        raise AssertionError('Expected account-lock wait was not observed')

    def assert_deleted(account):
        assert value(f"select closed_at is not null from app_private.accounts where id='{account}';") == 't'
        for table, column in [('library_v4_entries', 'account_id'), ('library_query_entries', 'account_id'), ('library_sync_state', 'account_id'),
                              ('library_transfer_months', 'scope_id'), ('api_rate_windows', 'scope_id')]:
            assert value(f"select count(*) from app_private.{table} where {column}='{account}';") == '0', table

    run('createdb', [target])
    try:
        sql((root / 'tests/database/bootstrap.sql').read_text())
        for migration in sorted((root / 'supabase/migrations').glob('*.sql')):
            if migration.name >= '202610070031':
                break
            sql(migration.read_text())
        account, second, document, original, approval, import_id, cancelled = [str(uuid.uuid4()) for _ in range(7)]
        sql(f"insert into auth.users values('{account}'),('{second}');")
        metadata = value("set role service_role; select public.worker_record_arxiv_metadata('2409.03100',1,"
                         "'{\"title\":\"Backfill paper\",\"authors\":[\"Fixture\"],\"categories\":[\"cs.LG\"],\"abstract\":\"Pinned metadata\"}');")
        sql(f"""insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
          values('{document}',decode(repeat('31',32),'hex'),'shared_catalog','{{"fixture":true}}',1000,2);
          insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
          values('{original}','paper-assets','test/compact-upgrade/original.pdf','{document}','verified',decode(repeat('31',32),'hex'),1000,'application/pdf',now());
          set role service_role;
          select public.worker_approve_arxiv_asset('{approval}','{metadata}','{document}','{original}','https://creativecommons.org/licenses/by/4.0/',
           jsonb_build_object('source_id','2409.03100','source_revision',1,'source_url','https://arxiv.org/abs/2409.03100v1',
           'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('3',64),'observed_at','2026-10-07T00:00:00Z'));
          {claims(account)}
          select public.v1_set_library_item('{document}',true);
          select public.v2_begin_import('{import_id}','2409.03100',1,1);
          reset role; set role service_role;
          select public.worker_checkpoint_import('{account}','{import_id}',2,1,'acquiring','{metadata}');
          select public.worker_resolve_import('{account}','{import_id}',3,1,'{approval}');
          {claims(account)}
          select public.v2_set_item_archived(gen_random_uuid(),'{document}',true,2);
          select public.v2_set_item_tags(gen_random_uuid(),'{document}',array['Backfill'],array[]::text[],3);
          select public.v2_set_library_item(gen_random_uuid(),'{document}',false,4);
          select public.v2_begin_import('{cancelled}','2409.03100',7,1);
          reset role; set role service_role;
          select public.worker_checkpoint_import('{account}','{cancelled}',8,1,'acquiring','{metadata}');
          {claims(account)}
          select public.v2_cancel_import(gen_random_uuid(),'{cancelled}',1);
          {claims(second)}
          select public.v1_set_library_item('{document}',true);
          reset role;
          update app_private.library_policy set account_journal_events=1;
          {claims(account)}
          select public.v2_begin_import(gen_random_uuid(),'2409.03101',10,1);""")

        assert value("select to_regclass('app_private.library_v4_entries') is null;") == 't'
        assert value(f"select retained_after>0 from app_private.library_sync_state where account_id='{account}';") == 't'

        def canonical():
            tables = ['library_items', 'import_requests', 'library_commands', 'library_changes', 'library_sync_state']
            result = {}
            for table in tables:
                # 032's generation is new derived bookkeeping, not a change to
                # the pre-existing sync cursor/retention/replay fields.
                payload = "(to_jsonb(t)-'query_revision')" if table == 'library_sync_state' else 'to_jsonb(t)'
                result[table] = value(f"select coalesce(jsonb_agg({payload} order by {payload}::text),'[]'::jsonb) "
                                      f"from app_private.{table} t where account_id in ('{account}','{second}');")
            return result

        before = canonical()
        v2 = value(f"{claims(account)} select public.v2_library_page();")
        v3 = value(f"{claims(account)} select public.v3_library_page();")
        definitions = value("select jsonb_agg(pg_get_functiondef(p.oid) order by p.oid::regprocedure::text) "
                            "from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' "
                            "and p.proname in ('v2_library_page','v2_library_changes','v3_library_page','v3_library_changes',"
                            "'v2_begin_import','v2_set_library_item','v2_cancel_import');")
        sql((root / 'supabase/migrations/202610070031_library_compact.sql').read_text())
        assert canonical() == before, 'Backfill changed canonical state, receipts or the original journal'
        assert value(f"{claims(account)} select public.v2_library_page();") == v2
        assert value(f"{claims(account)} select public.v3_library_page();") == v3
        assert value("select jsonb_agg(pg_get_functiondef(p.oid) order by p.oid::regprocedure::text) "
                     "from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' "
                     "and p.proname in ('v2_library_page','v2_library_changes','v3_library_page','v3_library_changes',"
                     "'v2_begin_import','v2_set_library_item','v2_cancel_import');") == definitions
        expected = value("select jsonb_agg(entry order by account_id,kind,id) from ("
                         "select account_id,'item' kind,id,app_private.library_item_entry(account_id,id)-'metadata' entry from app_private.library_items "
                         "union all select account_id,'import',id,app_private.library_import_entry(account_id,id)-'metadata' from app_private.import_requests) e;")
        assert value("select jsonb_agg(entry order by account_id,kind,id) from app_private.library_v4_entries;") == expected
        replay = json.loads(value(f"{claims(account)} select public.v2_begin_import('{import_id}','2409.03100',1,1);"))
        assert replay['replayed'] is True
        assert canonical() == before, 'Old receipt replay changed canonical state after upgrade'
        epoch = value('select dataset_epoch from app_private.library_v4_config;')
        metadata_result = json.loads(value(f"{claims(account)} select public.v4_library_metadata('{epoch}',array['{metadata}'::uuid]);"))
        assert metadata_result['records'][0]['metadata_id'] == metadata
        assert len(json.loads(value(f"{claims(second)} select public.v4_library_page();"))['entries']) == 1
        print('PASS compact backfill: pruned journal, tombstone, hidden mapping, cancelled import, legacy unverified item; canonical bytes/RPCs/replay unchanged', flush=True)

        sql((root / 'supabase/migrations/202610070032_library_query.sql').read_text())
        assert canonical() == before, 'Query backfill changed canonical rows, receipts, journal, last_seq or retained_after'
        assert value(f"{claims(account)} select public.v2_library_page();") == v2
        assert value(f"{claims(account)} select public.v3_library_page();") == v3
        assert value("select jsonb_agg(pg_get_functiondef(p.oid) order by p.oid::regprocedure::text) "
                     "from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' "
                     "and p.proname in ('v2_library_page','v2_library_changes','v3_library_page','v3_library_changes',"
                     "'v2_begin_import','v2_set_library_item','v2_cancel_import');") == definitions
        assert value("select jsonb_agg(entry order by account_id,kind,id) from app_private.library_v4_entries;") == expected
        assert value("select (select count(*) from app_private.library_query_entries)=(select count(*) from app_private.library_v4_entries);") == 't'
        assert value("select not exists(select 1 from app_private.library_v4_entries e "
                     "full join app_private.library_query_entries q using(account_id,kind,id) where "
                     "e.id is null or q.id is null or q.metadata_id is distinct from e.metadata_id "
                     "or q.created_seq<>e.created_seq or q.visible is distinct from (e.entry->>'visible')::boolean "
                     "or q.archived is distinct from coalesce((e.entry->>'archived')::boolean,false));") == 't'
        summary = json.loads(value(f"select summary from app_private.library_query_metadata where metadata_id='{metadata}';"))
        assert summary == {'title': 'Backfill paper', 'authors': ['Fixture'], 'author_count': 1, 'year': None, 'venue': None}, summary
        query = json.loads(value(f"{claims(account)} select public.v4_library_query();"))
        assert len(query['rows']) == 1 and query['rows'][0]['state']['source_id'] == '2409.03101'
        second_query = json.loads(value(f"{claims(second)} select public.v4_library_query();"))
        assert len(second_query['rows']) == 1 and second_query['rows'][0]['summary']['title'] is None
        print('PASS query backfill: complete compact-row coverage, static summary parity, exact old sync/legacy/canonical bytes', flush=True)

        # Reader owns KEY SHARE before deletion starts. Deletion waits, then
        # removes both counters; no stale completion can recreate either row.
        read_first = str(uuid.uuid4())
        sql(f"insert into auth.users values('{read_first}');")
        reader, deleter = Session(), Session()
        reader.complete(f"begin; {claims(read_first)} select public.v4_library_page(); select public.v4_library_query();")
        deleter.send(f"set role service_role; select public.worker_delete_account_begin('{read_first}'); select 'deleted';")
        blocked_by(deleter, reader)
        reader.complete('commit;')
        deleter.until('deleted')
        assert_deleted(read_first)
        reader.close(); deleter.close()
        print('PASS compact read/deletion race: reader first, deletion waits and removes counters', flush=True)

        # Deletion owns FOR UPDATE while uncommitted. require_actor initially
        # sees the old open row, but KEY SHARE must wait and recheck closed_at
        # before the metadata read can touch the old/deleted rate windows.
        delete_first = str(uuid.uuid4())
        sql(f"insert into auth.users values('{delete_first}'); {claims(delete_first)} select public.v4_library_page();")
        deleter, reader = Session(), Session()
        deleter.complete(f"begin; set role service_role; select public.worker_delete_account_begin('{delete_first}');")
        reader.send(f"{claims(delete_first)} select public.v4_library_metadata('{epoch}',array[]::uuid[]);")
        blocked_by(reader, deleter)
        deleter.complete('commit;')
        reader.error('account_unavailable')
        assert_deleted(delete_first)
        reader.close(); deleter.close()
        print('PASS compact metadata/deletion race: deletion first, reader rejects after closure with no recreated counters', flush=True)

        # A customer holding a v4 delta read remains compatible with the legacy
        # mutation's NO KEY UPDATE account lock. A stronger read lock deadlocks
        # or times out here, before the reader is allowed to commit.
        concurrent = str(uuid.uuid4())
        sql(f"insert into auth.users values('{concurrent}');")
        reader, writer = Session(), Session()
        reader.complete(f"begin; {claims(concurrent)} select public.v4_library_changes('{epoch}',0); select public.v4_library_query();")
        lines = writer.complete(f"{claims(concurrent)} select public.v2_begin_import(gen_random_uuid(),'2409.03102',0,1);")
        assert json.loads(lines[-1])['result']['status'] == 'applied'
        visible = json.loads(reader.complete('select public.v4_library_query();')[-1])
        assert len(visible['rows']) == 1 and visible['rows'][0]['state']['source_id'] == '2409.03102'
        reader.complete('commit;')
        assert value(f"select count(*) from app_private.library_v4_entries where account_id='{concurrent}';") == '1'
        reader.close(); writer.close()
        print('PASS compact delta read remains compatible with a concurrent legacy library writer', flush=True)
    except subprocess.CalledProcessError as error:
        raise AssertionError(error.stderr or error.stdout or str(error)) from error
    finally:
        for session in sessions:
            if not session.process.stdout.closed:
                session.close()
        run('dropdb', ['--force', target])


if __name__ == '__main__':
    repository = pathlib.Path(__file__).resolve().parents[2]
    binaries = pathlib.Path(os.environ.get('SCIENCE_READER_PG_BIN',
        '/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin'))
    verify(binaries, 'science_reader_test_' + uuid.uuid4().hex[:12], ['-h', '127.0.0.1', '-p', '55431'], repository)
