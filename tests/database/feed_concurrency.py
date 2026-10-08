"""Concurrent sessions against the feed (migration 043): one refresh claim at a time, one feedback
row per account and paper, an exact per-account feedback cap, and account-closure fencing."""
import concurrent.futures
import os
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing a non-disposable/non-loopback feed test target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    def sql(source, required=True):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input=source, capture_output=True, text=True, timeout=15, env=env)
        if required and result.returncode:
            raise AssertionError(result.stderr)
        return result

    class Session:
        """A transaction held at an observed SQL barrier, not an estimated sleep."""
        def __init__(self):
            self.process = subprocess.Popen(
                [str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            self.buffer = b''
            self.pid = int(self.complete("set statement_timeout='10s'; set lock_timeout='5s'; select pg_backend_pid();")[-1])

        def send(self, source):
            self.process.stdin.write((source + '\n').encode())
            self.process.stdin.flush()

        def complete(self, source):
            marker = 'barrier_' + uuid.uuid4().hex
            self.send(source + f" select '{marker}';")
            deadline = time.monotonic() + 12
            lines = []
            while time.monotonic() < deadline:
                while b'\n' in self.buffer:
                    line, self.buffer = self.buffer.split(b'\n', 1)
                    value = line.decode().strip()
                    if value == marker:
                        return lines
                    if value:
                        lines.append(value)
                if select.select([self.process.stdout], [], [], .1)[0]:
                    chunk = os.read(self.process.stdout.fileno(), 65536)
                    if not chunk:
                        raise AssertionError(self.process.stderr.read().decode())
                    self.buffer += chunk
            raise AssertionError('Feed SQL barrier timed out')

        def error(self, expected):
            code = self.process.wait(timeout=12)
            detail = self.process.stderr.read().decode()
            assert code != 0 and expected in detail, detail

        def close(self):
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
            if sql(f"select {holder.pid}=any(pg_blocking_pids({waiter.pid}));").stdout.strip() == 't':
                return
            if waiter.process.poll() is not None:
                raise AssertionError(waiter.process.stderr.read().decode())
            time.sleep(.02)
        raise AssertionError('Expected account-closure lock wait was not observed')

    sql("select public.worker_set_feed_policy('all',true); update app_private.feed_sources set next_check_at=now()-interval '1 minute', "
        "claim_id=null, lease_until=null;")

    # Eight workers woken at once: exactly one claims the source.
    def claim(_):
        return sql("begin; set role service_role; select coalesce(public.worker_feed_refresh_claim()->>'claim_id','none'); "
                   "select pg_sleep(0.05); commit;").stdout.strip().splitlines()
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        outcomes = [next(line for line in lines if line == 'none' or len(line) == 36) for lines in pool.map(claim, range(8))]
    claimed = [value for value in outcomes if value != 'none']
    assert len(claimed) == 1, outcomes
    sql(f"set role service_role; select public.worker_feed_refresh_finish('{claimed[0]}','not_modified',null,null,null);")

    # Each batch commits. A worker that never finishes, then loses its lease, still cannot
    # grow storage beyond the cap. The next worker must obey the same bound immediately.
    original_cap = sql('select max_rows from app_private.feed_policy;').stdout.strip()
    sql("update app_private.feed_policy set max_rows=1000; update app_private.feed_sources set next_check_at=now()-interval '1 minute';")
    try:
        claim_id = sql("select public.worker_feed_refresh_claim()->>'claim_id';").stdout.strip()
        for batch in range(4):
            if batch == 3:
                sql("update app_private.feed_sources set lease_until=now()-interval '1 second';")
                replacement = sql("select public.worker_feed_refresh_claim()->>'claim_id';").stdout.strip()
                assert replacement and replacement != claim_id
                claim_id = replacement
            # Simulate an aged retained row; pruning cannot depend on finish being called.
            sql("insert into app_private.feed_papers(source_id,revision,title,authors,author_keys,categories,announced_on,announce_type) "
                "values('2608.00001',1,'Old pool item','{}','{}','{cs.LG}',current_date-45,'new') on conflict do nothing;")
            sql(f"select public.worker_feed_upsert('{claim_id}',(select jsonb_agg(jsonb_build_object("
                f"'source_id','2610.'||({80000+batch*400}+n)::text,'revision',1,'title','Capacity fixture',"
                "'authors','[]'::jsonb,'categories','[\"cs.LG\"]'::jsonb,'topics','[]'::jsonb,"
                "'announced_on',current_date::text,'announce_type','new')) from generate_series(1,400) n),'feed-topics-v1');")
            rows = int(sql('select count(*) from app_private.feed_papers;').stdout.strip())
            assert rows == min((batch+1)*400,1000), rows
            assert sql("select count(*) from app_private.feed_papers where source_id='2608.00001';").stdout.strip() == '0'
    finally:
        sql(f"update app_private.feed_policy set max_rows={original_cap}; delete from app_private.feed_papers "
            "where source_id between '2610.80001' and '2610.81600' or source_id='2608.00001';")
    print('PASS feed capacity and retention hold across committed batches, missing finish and a replacement claim', flush=True)

    account = str(uuid.uuid4())
    sql(f"insert into auth.users values('{account}');")
    reader = f"set role authenticated; select set_config('request.jwt.claim.sub','{account}',false);"

    # The same paper from many requests at once: one row, the last kind wins, nothing fails.
    def same(index):
        kind = 'not_interested' if index % 2 else 'more_like_this'
        return sql(f"{reader} select public.v1_feed_feedback('2610.07001','{kind}');", required=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(same, range(8)))
    assert all(result.returncode == 0 for result in results), [result.stderr for result in results]
    rows = sql(f"select count(*) from app_private.feed_feedback where account_id='{account}';").stdout.strip()
    assert rows == '1', rows

    # The cap holds exactly while writers race.
    original = sql('select feedback_rows from app_private.feed_policy;').stdout.strip()
    sql('update app_private.feed_policy set feedback_rows=10;')
    try:
        def distinct(index):
            # Hold each transaction open after its write so unserialized writers would overlap.
            return sql(f"begin; {reader} select public.v1_feed_feedback('2610.{17000 + index}','not_interested'); "
                       "select pg_sleep(0.02); commit;", required=False)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(distinct, range(24)))
        assert all(result.returncode == 0 for result in results), [result.stderr for result in results]
        rows = sql(f"select count(*) from app_private.feed_feedback where account_id='{account}';").stdout.strip()
        assert rows == '10', rows

        # A successful feedback write must commit before closure, so the closure's cleanup sees it.
        closer, writer = Session(), Session()
        try:
            writer.complete(f"begin; {reader} select public.v1_feed_feedback('2610.08001','not_interested');")
            closer.send(f"begin; update app_private.accounts set closed_at=now() where id='{account}';")
            blocked_by(closer, writer)
            writer.complete('commit;')
            closer.complete('commit;')
            assert sql(f"select count(*) from app_private.feed_feedback where account_id='{account}';").stdout.strip() == '0'
        finally:
            writer.close()
            closer.close()

        # Opposite ordering: the writer waits, then rechecks the now-closed account and rolls back.
        late_account = str(uuid.uuid4())
        sql(f"insert into auth.users values('{late_account}');")
        closer, writer = Session(), Session()
        try:
            closer.complete(f"begin; update app_private.accounts set closed_at=now() where id='{late_account}';")
            writer.send(f"set role authenticated; select set_config('request.jwt.claim.sub','{late_account}',false); "
                        "select public.v1_feed_feedback('2610.08002','not_interested');")
            blocked_by(writer, closer)
            closer.complete('commit;')
            writer.error('account_unavailable')
            assert sql(f"select count(*) from app_private.feed_feedback where account_id='{late_account}';").stdout.strip() == '0'
        finally:
            writer.close()
            closer.close()
    finally:
        sql(f"update app_private.feed_policy set feedback_rows={original}; delete from app_private.feed_feedback where account_id='{account}'; "
            "select public.worker_set_feed_policy('off',false);")
    print('PASS feed_concurrency (one refresh claim, one row per paper, exact feedback cap, both closure orders)', flush=True)
