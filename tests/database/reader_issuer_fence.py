#!/usr/bin/env python3
"""Pending reader ACL review in a disposable loopback DB; no hosted calls.

--baseline shows the old issuer still succeeds where the candidate rejects it.
Normal migration/deploy runners intentionally ignore the pending file.
"""
import argparse
import concurrent.futures
import os
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(os.environ.get('SCIENCE_READER_PG_BIN', '/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin'))
BASE = ['-h', '127.0.0.1', '-p', '55431']
ENV = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
PENDING = ROOT / 'supabase/migrations/202610080045_reader_issuer_fence.sql.pending'


def run(binary, *args, **kwargs):
    return subprocess.run([str(BIN / binary), *BASE, *args], env=ENV, check=kwargs.pop('check', True), **kwargs)


def boundaries(db):
    def sql(source):
        return run('psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db,
                   input=source, capture_output=True, text=True, timeout=15).stdout.strip()

    def await_true(source):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if sql(source) == 't':
                return
            time.sleep(.03)
        raise AssertionError('Reader fence did not reach the expected real lock barrier')

    # A current issuer admitted under dual mode holds the same policy row as the
    # switch. Prove the switch waits for that transaction, then rejects all new
    # legacy requests. Its already-returned descriptor cannot be recalled.
    sql("select public.worker_asset_enforcement(true,'dual');")
    before = int(sql('select legacy_descriptors from app_private.reader_delivery_policy;'))
    issuer_name, switch_name = 'reader-fence-issuer-' + uuid.uuid4().hex, 'reader-fence-switch-' + uuid.uuid4().hex
    issuer = f"""set application_name='{issuer_name}'; set statement_timeout='12s'; begin; set local role service_role;
      select public.worker_reader_delivery_create('45000000-0000-0000-0000-000000000001',
       '45000000-0000-0000-0000-000000000007',decode(repeat('6',64),'hex'),'legacy')->>'transport';
      select pg_sleep(4); commit;"""
    switch = f"set application_name='{switch_name}'; set statement_timeout='12s'; select public.worker_asset_enforcement(true,'bounded')->'delivery_policy'->>'mode';"
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(sql, issuer)
        await_true(f"select exists(select 1 from pg_stat_activity where datname='{db}' and application_name='{issuer_name}' and wait_event='PgSleep');")
        second = pool.submit(sql, switch)
        await_true(f"""select exists(select 1 from pg_stat_activity waiter,pg_stat_activity holder
          where waiter.datname='{db}' and holder.datname='{db}' and waiter.application_name='{switch_name}'
           and holder.application_name='{issuer_name}' and holder.pid=any(pg_blocking_pids(waiter.pid)));""")
        assert first.result().splitlines()[0] == 'legacy'
        assert second.result().splitlines()[-1] == 'bounded'
    assert int(sql('select legacy_descriptors from app_private.reader_delivery_policy;')) == before + 1
    sql("""set role service_role; select test.reject($q$select public.worker_reader_delivery_create(
      '45000000-0000-0000-0000-000000000001','45000000-0000-0000-0000-000000000007',
      decode(repeat('7',64),'hex'),'legacy')$q$,'reader_upgrade_required');""")
    assert int(sql('select legacy_descriptors from app_private.reader_delivery_policy;')) == before + 1
    print('PASS true-session strict-mode switch waits for prior legacy admission; subsequent legacy request is denied')

    # A changed definer/owner must not silently fence the current legitimate
    # route or leave an inheritable legacy bypass. A refused migration is atomic.
    fingerprint = """select md5(jsonb_build_object('state',test.unchanged_state(),
      'functions',(select jsonb_agg(jsonb_build_object('definition',pg_get_functiondef(oid),'owner',proowner,'acl',proacl)
       order by oid) from pg_proc where oid in ('public.worker_reader_descriptor(uuid,uuid)'::regprocedure,
        'public.worker_reader_delivery_create(uuid,uuid,bytea,text)'::regprocedure)))::text);"""
    target = 'public.worker_reader_delivery_create(uuid,uuid,bytea,text)'
    for setup, restore in [(f'alter function {target} security invoker;', f'alter function {target} security definer;'),
                           (f'alter function {target} owner to authenticated;', f'alter function {target} owner to current_user;')]:
        sql(setup + 'grant execute on function public.worker_reader_descriptor(uuid,uuid) to service_role;')
        before = sql(fingerprint)
        rejected = run('psql', '-X', '-v', 'ON_ERROR_STOP=1', '-d', db, '-f', str(PENDING),
                       capture_output=True, text=True, check=False)
        assert rejected.returncode and 'reader_issuer_owner_review_required' in rejected.stderr, rejected.stderr
        assert sql(fingerprint) == before, 'Failed reader fence changed state or ACLs'
        sql(restore + 'revoke all on function public.worker_reader_descriptor(uuid,uuid) from service_role;')
    print('PASS changed definer or ownership refuses the migration with state, bodies and ACLs unchanged')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', action='store_true')
    args = parser.parse_args()
    db = 'science_reader_test_reader_fence_' + uuid.uuid4().hex[:10]
    run('createdb', db)
    try:
        run('psql', '-X', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres', '-c',
            f'ALTER DATABASE "{db}" SET timezone TO \'UTC\'', capture_output=True)
        for source in [ROOT / 'tests/database/bootstrap.sql', *sorted((ROOT / 'supabase/migrations').glob('*.sql'))]:
            run('psql', '-X', '-v', 'ON_ERROR_STOP=1', '-d', db, '-f', str(source), capture_output=True, text=True)
        run('psql', '-X', '-v', 'ON_ERROR_STOP=1', '-v', f'candidate={str(not args.baseline).lower()}', '-d', db,
            '-f', str(ROOT / 'tests/database/candidates/reader_issuer_fence.sql'), capture_output=True, text=True)
        print('PASS true-role legacy denial, guarded dual/bounded delivery and exact single-use redemption')
        print('PASS unchanged objects, functions, inventory enforcement, policy, quotas and grant history')
        print('PASS dual rollback keeps old RPC fenced; explicit regrant demonstrates bounded-mode bypass')
        boundaries(db)
    except subprocess.CalledProcessError as error:
        print(error.stderr or '')
        raise SystemExit(1)
    finally:
        run('dropdb', db)


if __name__ == '__main__':
    main()
