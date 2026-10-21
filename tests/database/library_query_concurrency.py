"""True-session query generation/deletion races, synthetic disposable DB only."""
import json
import os
import pathlib
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing a non-disposable/non-loopback query test target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    sessions = []

    def sql(source):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input=source, text=True, capture_output=True, timeout=15, env=env)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip().splitlines()[-1]

    def literal(value):
        return "'" + (value if isinstance(value, str) else json.dumps(value, separators=(',', ':'))).replace("'", "''") + "'"

    def claims(account):
        return f"set role authenticated; select set_config('request.jwt.claim.sub','{account}',false);"

    def query(spec=None, cursor=None, limit=50):
        return f"select public.v4_library_query({literal(spec or {})},{literal(cursor) if cursor is not None else 'null'},{limit});"

    class Session:
        # Barriers are SQL results, not guessed sleeps. A transaction remains
        # open until the test explicitly commits/releases its independent peer.
        def __init__(self):
            self.process = subprocess.Popen(
                [str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            self.buffer = b''
            sessions.append(self)
            self.pid = int(self.complete("set statement_timeout='10s'; set lock_timeout='5s'; select pg_backend_pid();")[-1])

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
            if sql(f"select {holder.pid}=any(pg_blocking_pids({waiter.pid}));") == 't':
                return
            if waiter.process.poll() is not None:
                raise AssertionError(waiter.process.stderr.read().decode())
            time.sleep(.02)
        raise AssertionError('Expected query account-lock wait was not observed')

    account = str(uuid.uuid4())
    sql(f"insert into auth.users values('{account}'); select 'created';")

    def paper(source, title, attach=True):
        document, original, approval = [str(uuid.uuid4()) for _ in range(3)]
        metadata = sql(f"set role service_role; select public.worker_record_arxiv_metadata('{source}',1,"
                       f"{literal({'title': title, 'authors': ['Synthetic Author'], 'categories': ['cs.LG']})});")
        sql(f"""insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
          values('{document}',sha256(convert_to('{document}','UTF8')),'shared_catalog','{{"fixture":true}}',1000,2);
          insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
          values('{original}','paper-assets','test/query-races/{document}.pdf','{document}','verified',sha256(convert_to('{document}','UTF8')),1000,'application/pdf',now());
          set role service_role;
          select public.worker_approve_arxiv_asset('{approval}','{metadata}','{document}','{original}','https://creativecommons.org/licenses/by/4.0/',
           jsonb_build_object('source_id','{source}','source_revision',1,'source_url','https://arxiv.org/abs/{source}v1',
           'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('3',64),'observed_at','2026-10-07T00:00:00Z'));""")
        result = {'document': document, 'approval': approval, 'metadata': metadata}
        if attach:
            receipt = json.loads(sql(f"{claims(account)} select public.v2_set_library_item(gen_random_uuid(),'{document}',true,0,'{approval}');"))
            result['item'] = receipt['entry']['id']
        return result

    try:
        papers = [paper('2411.' + str(3291 + n).zfill(5), title) for n, title in enumerate(['Alpha', 'Beta', 'Gamma', 'Delta'])]
        writer = Session()
        writer.complete(claims(account))
        title_order = {'sort': 'title'}
        mutations = [
            ('tags', f"select public.v2_set_item_tags(gen_random_uuid(),'{papers[1]['document']}',array['Race Tag'],array[]::text[],1);"),
            ('archive', f"select public.v2_set_item_archived(gen_random_uuid(),'{papers[1]['document']}',true,2);"),
            ('visibility', f"select public.v2_set_library_item(gen_random_uuid(),'{papers[2]['document']}',false,1);"),
        ]
        for label, mutation in mutations:
            reader = Session()
            reader.complete(claims(account))
            page = json.loads(reader.complete(query(title_order, limit=1))[-1])
            assert page['has_more'] and page['next_cursor'] is not None
            writer.complete(mutation)
            reader.send(query(title_order, page['next_cursor'], 1))
            reader.error('library_query_restart_required')
            reader.close()
            current = json.loads(writer.complete(query(title_order))[-1])
            assert current['query_revision'] > page['query_revision']
            if label == 'tags':
                changed = [r for r in current['rows'] if r['state']['id'] == papers[1]['item']]
                assert len(changed) == 1 and changed[0]['summary']['tags'] == ['Race Tag']
            elif label == 'archive':
                assert all(r['state']['id'] != papers[1]['item'] for r in current['rows'])
            else:
                assert all(r['state']['id'] != papers[2]['item'] for r in current['rows'])
        print('PASS query continuations restart after independently committed tags, archive and removal', flush=True)

        pending = str(uuid.uuid4())
        response = json.loads(writer.complete(
            f"select public.v2_begin_import('{pending}','2411.03295',(public.v4_library_page()->>'baseline_cursor')::bigint,1);")[-1])
        prior_state = response['entry']['state_seq']
        reader = Session()
        reader.complete(claims(account))
        page = json.loads(reader.complete(query(title_order, limit=1))[-1])
        writer.complete(f"""reset role; do $$ declare a uuid:='{account}'; s bigint; begin
          perform app_private.lock_library_account(a); perform app_private.lock_library_state(a);
          s:=app_private.library_next_seq(a);
          update app_private.import_requests set state_seq=s,progress='downloading' where account_id=a and id='{pending}';
          perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,'{pending}')));
          end $$;""")
        continuation = json.loads(reader.complete(query(title_order, page['next_cursor']))[-1])
        assert continuation['query_revision'] == page['query_revision']
        progress = [r for r in continuation['rows'] if r['state']['id'] == pending]
        assert len(progress) == 1 and progress[0]['state']['progress'] == 'downloading'
        assert progress[0]['state']['state_seq'] > prior_state
        reader.close()
        print('PASS progress-only committed update preserves query cursor and supplies fresh state decoration', flush=True)

        # Checkpoint and grouped resolution complete inside a held transaction.
        # A simultaneous query must return the old complete generation, then the
        # next committed query sees exactly the replacement membership.
        resolving = paper('2411.03296', 'Resolved', attach=False)
        intent = str(uuid.uuid4())
        writer.complete(claims(account))
        response = json.loads(writer.complete(
            f"select public.v2_begin_import('{intent}','2411.03296',(public.v4_library_page()->>'baseline_cursor')::bigint,1);")[-1])
        state_seq = response['entry']['state_seq']
        reader = Session()
        reader.complete(claims(account))
        before = json.loads(reader.complete(query())[-1])
        old_first_page = json.loads(reader.complete(query(limit=1))[-1])
        writer.complete(f"""begin; reset role; set role service_role;
          select public.worker_checkpoint_import('{account}','{intent}',{state_seq},1,'acquiring','{resolving['metadata']}');
          select public.worker_resolve_import('{account}','{intent}',{state_seq + 1},1,'{resolving['approval']}');""")
        during = json.loads(reader.complete(query())[-1])
        assert during == before, 'Uncommitted grouped transition leaked a row or query generation'
        writer.complete('commit;')
        after = json.loads(reader.complete(query())[-1])
        assert after['query_revision'] > before['query_revision']
        assert all(r['state']['id'] != intent for r in after['rows'])
        resolved = [r for r in after['rows'] if r['state'].get('document_id') == resolving['document']]
        assert len(resolved) == 1 and resolved[0]['state']['kind'] == 'item' and resolved[0]['summary']['title'] == 'Resolved'
        reader.send(query(cursor=old_first_page['next_cursor'], limit=1))
        reader.error('library_query_restart_required')
        reader.close()
        assert sql(f"select jsonb_array_length(entries)=2 from app_private.library_changes where account_id='{account}' and seq={state_seq + 2};") == 't'
        print('PASS held grouped resolution exposes one consistent old generation, then one complete committed replacement', flush=True)

        doomed = str(uuid.uuid4())
        sql(f"insert into auth.users values('{doomed}'); {claims(doomed)} select public.v4_library_query();")
        deleter, reader = Session(), Session()
        deleter.complete(f"begin; set role service_role; select public.worker_delete_account_begin('{doomed}');")
        reader.send(claims(doomed) + query())
        blocked_by(reader, deleter)
        deleter.complete('commit;')
        reader.error('account_unavailable')
        for table, column in [('library_query_entries', 'account_id'), ('library_v4_entries', 'account_id'),
                              ('library_sync_state', 'account_id'), ('library_transfer_months', 'scope_id'), ('api_rate_windows', 'scope_id')]:
            assert sql(f"select count(*) from app_private.{table} where {column}='{doomed}';") == '0', table
        reader.close(); deleter.close(); writer.close()
        print('PASS deletion-before-query blocks then rejects without recreating projection or counters', flush=True)
    finally:
        for session in sessions:
            if not session.process.stdout.closed:
                session.close()


if __name__ == '__main__':
    repository = pathlib.Path(__file__).resolve().parents[2]
    import sys  # run directly: the same binaries as scripts/test-database.py (scripts/pg_tools.py)
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'scripts'))
    from pg_tools import pg_bin
    binaries = pg_bin()
    base = ['-h', '127.0.0.1', '-p', '55431']
    database = 'science_reader_test_' + uuid.uuid4().hex[:12]
    environment = {k: v for k, v in os.environ.items() if not k.startswith('PG')}

    def run(binary, args, **kwargs):
        return subprocess.run([str(binaries / binary), *base, *args], env=environment, check=True, **kwargs)

    run('createdb', [database])
    try:
        sources = [repository / 'tests/database/bootstrap.sql',
                   *[p for p in sorted((repository / 'supabase/migrations').glob('*.sql')) if p.name <= '202610070032_library_query.sql']]
        for source in sources:
            run('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database, '-f', str(source)], capture_output=True, text=True)
        verify(binaries, database, base)
    except subprocess.CalledProcessError as error:
        raise AssertionError(error.stderr or error.stdout or str(error)) from error
    finally:
        run('dropdb', ['--force', database])
