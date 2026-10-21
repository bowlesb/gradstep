#!/usr/bin/env python3
"""Subscription-upgrade migration and regression checks in a disposable loopback database.

--baseline reproduces the approved-policy failure against the schema before044.
No provider keys, Apple APIs, hosted database, grants outside fixtures, or migration
ledger writes are used. Normal database tests include the promoted044 contract.
"""
import argparse
import contextlib
import importlib.util
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(os.environ['SCIENCE_READER_PG_BIN'])
BASE = ['-h', '127.0.0.1', '-p', '55431']
MIGRATION = ROOT / 'supabase/migrations/202610080044_subscription_upgrade_credits.sql'
ENV = {key: value for key, value in os.environ.items() if not key.startswith('PG')}


def run(binary, *params, **kw):
    return subprocess.run([str(BIN / binary), *BASE, *params], env=ENV, check=kw.pop('check', True), **kw)


@contextlib.contextmanager
def database():
    db = 'science_reader_test_subscription_' + uuid.uuid4().hex[:10]
    run('createdb', db)
    try:
        run('psql', '-X', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres', '-c', f'ALTER DATABASE "{db}" SET timezone TO \'UTC\'', capture_output=True)
        # Historical schema is explicit: rollout guards and the reproducer must
        # execute before044, even after later migrations enter the repository.
        prior = [p for p in sorted((ROOT / 'supabase/migrations').glob('*.sql')) if p.name < MIGRATION.name]
        for source in [ROOT / 'tests/database/bootstrap.sql', *prior]:
            run('psql', '-X', '-v', 'ON_ERROR_STOP=1', '-d', db, '-f', str(source), capture_output=True, text=True)
        yield db
    finally:
        run('dropdb', db)


def guards():
    """Each refused rollout leaves functions and seeded financial history intact."""
    account = '44900000-0000-0000-0000-000000000001'
    pack = f"""insert into auth.users(id) values('{account}');
      select public.worker_record_store_transaction('{account}',jsonb_build_object('environment','Production',
       'transaction_id','449001','original_transaction_id','449001','product_id','com.sciencereader.ios.credits.400',
       'type','Consumable','purchase_date',(extract(epoch from now())*1000)::bigint,
       'signed_date',(extract(epoch from now())*1000)::bigint,'app_account_token','{account}'));"""
    fingerprint = """select md5(jsonb_build_object(
      'grant',pg_get_functiondef('app_private.store_grant(text,text,text,uuid,text,integer,timestamptz,timestamptz,text,text)'::regprocedure),
      'recorder',pg_get_functiondef('app_private.record_store_transaction_locked(text,uuid,jsonb)'::regprocedure),
      'wrapper',pg_get_functiondef('app_private.record_store_transaction(text,uuid,jsonb)'::regprocedure),
      'buckets',(select jsonb_agg(to_jsonb(b) order by id) from app_private.credit_buckets b),
      'ledger',(select jsonb_agg(to_jsonb(l) order by id) from app_private.credit_ledger l),
      'transactions',(select jsonb_agg(to_jsonb(t) order by environment,transaction_id) from app_private.store_transactions t)
      )::text);"""
    scenarios = [
        ('enabled_channel', "update app_private.store_verifier_policy set enabled=true where channel='app';", 'subscription_upgrade_requires_verifier_pause'),
        ('completed_recent_verification', f"""insert into app_private.store_verifier_starts
         (id,channel,account_id,policy_id,payload_bytes,started_at,expires_at,outcome,finished_at,duration_ms)
         values('019af010-0000-7000-8000-000000000001','app','{account}','app-store-sandbox-v1',100,
         now(),now()+interval '840 hours','verified',now(),1);""", 'subscription_upgrade_requires_verifier_drain'),
    ]
    for label, expiry in [('zero_credit_subscription', "now()-interval '1 day'"), ('granted_subscription', "now()+interval '20 days'")]:
        scenarios.append((label, f"""select public.worker_record_store_transaction('{account}',jsonb_build_object(
         'environment','Production','transaction_id','449002','original_transaction_id','449002',
         'product_id','com.sciencereader.ios.standard.monthly','type','Auto-Renewable Subscription',
         'purchase_date',(extract(epoch from now()-interval '31 days')*1000)::bigint,
         'expires_date',(extract(epoch from ({expiry}))*1000)::bigint,
         'signed_date',(extract(epoch from now())*1000)::bigint,'app_account_token','{account}'));""",
         'subscription_upgrade_history_requires_review'))
    for label, setup, expected in scenarios:
        with database() as db:
            def sql(source):
                return run('psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db,
                           input=source, capture_output=True, text=True).stdout.strip().splitlines()[-1]
            sql(pack + setup + 'select 1;')
            before = sql(fingerprint)
            rejected = run('psql', '-X', '-v', 'ON_ERROR_STOP=1', '-d', db, '-f', str(MIGRATION),
                           capture_output=True, text=True, check=False)
            if rejected.returncode == 0 or expected not in rejected.stderr:
                raise AssertionError(f'{label}: expected {expected}, got {rejected.stderr}')
            if sql(fingerprint) != before:
                raise AssertionError(f'{label}: refused candidate changed financial state or function bodies')
            print(f'PASS migration refuses {label}; functions/buckets/ledger/transactions unchanged', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', action='store_true')
    args = parser.parse_args()
    try:
        if not args.baseline:
            if not MIGRATION.is_file():
                raise RuntimeError('Subscription retention migration is not present')
            guards()
        with database() as db:
            if not args.baseline:
                run('psql', '-X', '-v', 'ON_ERROR_STOP=1', '-d', db, '-f', str(MIGRATION), capture_output=True, text=True)
            print('PASS isolated schema loaded; mode=' + ('pre044-baseline' if args.baseline else 'retained044'), flush=True)
            run('psql', '-X', '-v', 'ON_ERROR_STOP=1', '-d', db,
                '-f', str(ROOT / 'tests/database/subscription_upgrade_credits.sql'), capture_output=True, text=True)
            print('PASS approved subscription upgrade credit lifecycle regression', flush=True)
            if not args.baseline:
                spec = importlib.util.spec_from_file_location('subscription_upgrade_concurrency', ROOT / 'tests/database/subscription_upgrade_concurrency.py')
                race = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(race)
                race.verify(BIN, db, BASE)
    except subprocess.CalledProcessError as error:
        print(error.stderr or '')
        raise SystemExit(1)


if __name__ == '__main__':
    main()
