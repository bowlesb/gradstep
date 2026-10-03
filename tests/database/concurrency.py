"""Exercise actual concurrent Postgres sessions, not simulated balance arithmetic."""
import concurrent.futures
import subprocess
import uuid

def verify(bin_path, db, base):
    def sql(source, required=True):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-d', db], input=source, capture_output=True, text=True)
        if required and result.returncode:
            raise AssertionError(result.stderr)
        return result

    account, device = str(uuid.uuid4()), str(uuid.uuid4())
    token = "decode(repeat('31',32),'hex')"
    claims = f"set role authenticated; select set_config('request.jwt.claim.sub','{account}',false);"
    sql(f"insert into auth.users values('{account}'); {claims} select public.v1_bootstrap_keys('{device}',decode(repeat('11',32),'hex'),decode(repeat('22',60),'hex'),{token},decode(repeat('44',92),'hex'),decode(repeat('aa',32),'hex')); reset role;")

    def append(index):
        return sql(f"begin; {claims} select public.v1_append_event('{device}','{uuid.uuid4()}',1,1,decode(repeat('55',60),'hex'),{token}); select pg_sleep(0.05); commit;")

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(append, range(8)))
    cursors = sql(f"select string_agg(cursor::text,',' order by cursor) from app_private.sync_events where account_id='{account}';").stdout.strip()
    assert cursors == '1,2,3,4,5,6,7,8', cursors

    # A deliberately held transaction must block a later event's commit. While
    # the first is invisible, no reader may observe a cursor that overtakes it.
    first_id, second_id = str(uuid.uuid4()), str(uuid.uuid4())
    first_source = f"begin; {claims} select public.v1_append_event('{device}','{first_id}',1,1,decode(repeat('66',60),'hex'),{token}); select pg_sleep(1); commit;"
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(sql, first_source)
        # Wait for the transaction to reach pg_sleep rather than rely on timing.
        for _ in range(100):
            active = sql(f"select count(*) from pg_stat_activity where datname='{db}' and pid<>pg_backend_pid() and wait_event='PgSleep';").stdout.strip()
            if active == '1':
                break
        else:
            raise AssertionError('First cursor transaction did not reach the barrier')
        second = pool.submit(sql, f"{claims} select public.v1_append_event('{device}','{second_id}',1,1,decode(repeat('77',60),'hex'),{token});")
        visible = sql(f"select max(cursor) from app_private.sync_events where account_id='{account}';").stdout.strip()
        assert visible == '8', visible
        first.result(); second.result()
    assert sql(f"select cursor from app_private.sync_events where account_id='{account}' and id='{second_id}';").stdout.strip() == '10'

    sql(f"update app_private.platform_budgets set work_enabled=true,limit_microusd=1000000; select public.worker_grant_credits('{account}','trial','concurrent-{account}',100,'2026-01-01',null,'Concurrency fixture');")
    def reserve(index):
        return sql(f"set role service_role; select public.worker_reserve_operation('{account}','{uuid.uuid4()}','chat',decode(repeat('88',32),'hex'),'test',70,1);", required=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(reserve, range(8)))
    assert sum(r.returncode == 0 for r in results) == 1, [r.stderr for r in results]
    assert all(r.returncode == 0 or 'insufficient_credits' in r.stderr for r in results)
    assert sql(f"select balance||','||reserved from app_private.credit_buckets where account_id='{account}';").stdout.strip() == '100,70'
    assert sql(f"select count(*) from app_private.metered_operations where account_id='{account}';").stdout.strip() == '1'
    print('PASS concurrent cursors, commit-order barrier, eight-way near-limit reservations')

    report = str(uuid.uuid4())
    sql(f"{claims} select public.v1_create_report('{report}','Concurrent attachments','Synthetic fixture','1','1','test','test'); reset role; update app_private.support_storage_limits set account_bytes=5242880;")
    def attachment(index):
        return sql(f"set role service_role; select public.worker_reserve_attachment('{account}','{report}','{uuid.uuid4()}',decode(repeat('99',32),'hex'),3145728,'image/png');", required=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(attachment, range(8)))
    assert sum(r.returncode == 0 for r in results) == 1, [r.stderr for r in results]
    assert all(r.returncode == 0 or 'attachment_storage_limit' in r.stderr for r in results)
    assert sql(f"select count(*)||','||sum(byte_count) from app_private.stored_objects where owner_id='{account}' and bucket='support';").stdout.strip() == '1,3145728'
    print('PASS eight-way attachment capacity reservation; no leaked losing rows')
