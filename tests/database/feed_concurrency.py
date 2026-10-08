"""Concurrent sessions against the feed (migration 044): one refresh claim at a time, one feedback
row per account and paper, and an exact per-account feedback cap."""
import concurrent.futures
import subprocess
import uuid


def verify(bin_path, db, base):
    def sql(source, required=True):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input=source, capture_output=True, text=True)
        if required and result.returncode:
            raise AssertionError(result.stderr)
        return result

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
    finally:
        sql(f"update app_private.feed_policy set feedback_rows={original}; delete from app_private.feed_feedback where account_id='{account}'; "
            "select public.worker_set_feed_policy('off',false);")
    print('PASS feed_concurrency (one refresh claim, one row per paper, exact feedback cap)', flush=True)
