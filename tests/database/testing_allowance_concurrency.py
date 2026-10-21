"""Independent database connections exercise refill/replay serialization. No model calls."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
import subprocess
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing a non-disposable/non-loopback test target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}

    def sql(source):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input="set statement_timeout='15s'; " + source, capture_output=True,
                                text=True, env=env, timeout=20)
        if result.returncode:
            raise AssertionError(result.stderr)
        return [line for line in result.stdout.splitlines() if line.strip()]

    account, request, op, owner = (str(uuid.uuid4()) for _ in range(4))
    # Migration 0105 (review A9): an owner acts, and the target is a tester.
    sql(f"insert into auth.users(id) values('{account}'),('{owner}'); "
        f"insert into app_private.app_roles(account_id,role) values('{owner}','owner'),('{account}','tester'); set role service_role; "
        "select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,1000000,true); "
        f"select public.worker_set_testing_allowance('{owner}','{request}','{account}',true,'Owner-authorized concurrency fixture');")

    def reserve(operation, credits):
        # Hold the transaction briefly so separately connected contenders overlap.
        rows = sql(f"begin; set local role service_role; select public.worker_reserve_operation('{account}',"
                   f"'{operation}','chat',sha256('{operation}'),'beta-credits-v1',{credits},1000); "
                   "select pg_sleep(.1); commit;")
        return json.loads(rows[0])

    with ThreadPoolExecutor(max_workers=8) as pool:
        outcomes = list(pool.map(lambda _: reserve(op, 100001), range(8)))
    assert sum(not result['replayed'] for result in outcomes) == 1, 'only one initial reservation'
    assert sql(f"select count(*) from app_private.credit_ledger where account_id='{account}' and entry_key='testing-refill:{op}';")[-1] == '1'
    sql(f"set role service_role; select public.worker_settle_operation('{account}','{op}',100001,10);")
    operations = [str(uuid.uuid4()) for _ in range(3)]
    with ThreadPoolExecutor(max_workers=3) as pool:
        outcomes = list(pool.map(lambda operation: reserve(operation, 50), operations))
    assert all(not result['replayed'] for result in outcomes)
    state = json.loads(sql(f"select json_build_object('balance',b.balance,'reserved',b.reserved,"
                          "'ledger_balance',(select sum(l.balance_delta) from app_private.credit_ledger l where l.bucket_id=b.id),"
                          "'ledger_reserved',(select sum(l.reserved_delta) from app_private.credit_ledger l where l.bucket_id=b.id)) "
                          "from app_private.credit_buckets b join app_private.testing_allowances t on t.bucket_id=b.id "
                          f"where t.account_id='{account}';")[-1])
    assert state == {'balance': 100100, 'reserved': 150, 'ledger_balance': 100100, 'ledger_reserved': 150}, state
    for operation in operations:
        sql(f"set role service_role; select public.worker_settle_operation('{account}','{operation}',20,10);")
    print('PASS testing allowance: concurrent replay and independent refills reconcile to ledger', flush=True)
