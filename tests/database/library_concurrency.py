"""Disposable localhost-only library contract, concurrency and 009->010 upgrade.

Run directly with python3 tests/database/library_concurrency.py. Uses the same
local PostgreSQL binaries/port as scripts/test-database.py; no hosted operation.
"""
import concurrent.futures
import json
import os
import pathlib
import subprocess
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]


def verify(bin_path, db, base):
    def sql(source, required=True):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db], input=source, text=True, capture_output=True, timeout=15)
        if required and result.returncode:
            raise AssertionError(result.stderr)
        return result

    def value(source):
        return sql(source).stdout.strip().splitlines()[-1]

    def claims(account):
        return f"set role authenticated; select set_config('request.jwt.claim.sub','{account}',false);"

    def sleep_barrier():
        for _ in range(150):
            if value(f"select count(*) from pg_stat_activity where datname='{db}' and pid<>pg_backend_pid() and wait_event='PgSleep';") == '1':
                return
        raise AssertionError('Transaction did not reach the sleep barrier')

    a, b, doc, obj, approval = [str(uuid.uuid4()) for _ in range(5)]
    sql(f"insert into auth.users values('{a}'),('{b}');")
    body = '{"title":"Concurrent metadata","authors":["Synthetic"],"categories":["cs.LG"]}'

    def metadata(_):
        return value(f"set role service_role; select public.worker_record_arxiv_metadata('2403.01234',1,'{body}');")

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        metas = list(pool.map(metadata, range(8)))
    assert len(set(metas)) == 1, metas
    meta = metas[0]
    assert value("select count(*) from app_private.publication_identifiers where namespace='arxiv' and identifier='2403.01234';") == '1'
    sql(f"""insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
      values('{doc}',decode(repeat('a1',32),'hex'),'shared_catalog','{{"fixture":true}}',1000,2);
      insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
      values('{obj}','paper-assets','test/concurrency/original.pdf','{doc}','verified',decode(repeat('a1',32),'hex'),1000,'application/pdf',now());
      set role service_role;
      select public.worker_approve_arxiv_asset('{approval}','{meta}','{doc}','{obj}','https://creativecommons.org/licenses/by/4.0/',
       jsonb_build_object('source_id','2403.01234','source_revision',1,'source_url','https://arxiv.org/abs/2403.01234v1',
       'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('a',64),'observed_at','2026-10-03T01:00:00Z'));""")
    op = str(uuid.uuid4())

    def begin_same(_):
        return json.loads(value(f"{claims(a)} select public.v2_begin_import('{op}','2403.01234',0,1);"))

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(begin_same, range(8)))
    assert sum(not r['replayed'] for r in results) == 1
    assert value(f"select last_seq||','||(select count(*) from app_private.library_commands where account_id='{a}') from app_private.library_sync_state where account_id='{a}';") == '1,1'
    print('PASS eight-way metadata identity and same-operation import replay')

    # Hold the first change transaction until a second mutation is waiting.
    # No committed highwater may overtake the invisible first change.
    op2, op3 = str(uuid.uuid4()), str(uuid.uuid4())
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(sql, f"begin; {claims(a)} select public.v2_begin_import('{op2}','2403.01234',1,1); select pg_sleep(1); commit;")
        sleep_barrier()
        second = pool.submit(sql, f"{claims(a)} select public.v2_begin_import('{op3}','2403.01234',1,1);")
        assert value(f"select last_seq from app_private.library_sync_state where account_id='{a}';") == '1'
        first.result(); second.result()
    assert value(f"select string_agg(seq::text,',' order by seq) from app_private.library_changes where account_id='{a}';") == '1,2,3'
    print('PASS committed library cursor cannot overtake an uncommitted change')

    # Two separate imports/accounts resolving identical eligible bytes share a
    # document while preserving independent membership and per-account cursors.
    bop = str(uuid.uuid4())
    sql(f"{claims(b)} select public.v2_begin_import('{bop}','2403.01234',0,1);")

    def resolve(pair):
        owner, request = pair
        return sql(f"set role service_role; select public.worker_resolve_import('{owner}','{request}',1,1,'{approval}');")

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(resolve, [(a, op), (b, bop)]))
    assert value(f"select count(*) from app_private.library_items where document_id='{doc}';") == '2'
    assert value(f"select count(*) from app_private.metered_operations where account_id in ('{a}','{b}');") == '0'

    # Independent device Adds in one account also converge. Cancelling all
    # resolved interests concurrently withdraws the import-created membership.
    shared_account = str(uuid.uuid4())
    sql(f"insert into auth.users values('{shared_account}');")
    interests = []
    for _ in range(8):
        request = str(uuid.uuid4())
        response = json.loads(value(f"{claims(shared_account)} select public.v2_begin_import('{request}','2403.01234',0,1);"))
        interests.append((request, response['entry']['state_seq']))

    def resolve_interest(interest):
        request, seq = interest
        return sql(f"set role service_role; select public.worker_resolve_import('{shared_account}','{request}',{seq},1,'{approval}');")

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(resolve_interest, interests))
    assert value(f"select count(*) from app_private.library_items where account_id='{shared_account}' and document_id='{doc}' and removed_at is null;") == '1'

    def cancel_interest(interest):
        return sql(f"{claims(shared_account)} select public.v2_cancel_import('{uuid.uuid4()}','{interest[0]}',1);")

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(cancel_interest, interests))
    assert value(f"select (removed_at is not null)::text||','||last_remove_seq from app_private.library_items where account_id='{shared_account}' and document_id='{doc}';") == 'true,0'
    print('PASS eight independent Adds converge; concurrent interest cancellation withdraws once')

    # Removal holds the account while the already accepted alias resolution
    # waits. The callback must observe the committed removal fence.
    remove = str(uuid.uuid4())
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(sql, f"begin; {claims(a)} select public.v2_set_library_item('{remove}','{doc}',false,1); select pg_sleep(1); commit;")
        sleep_barrier()
        second = pool.submit(sql, f"set role service_role; select public.worker_resolve_import('{a}','{op2}',2,1,'{approval}');")
        first.result(); second.result()
    assert value(f"select phase from app_private.import_requests where account_id='{a}' and id='{op2}';") == 'membership_conflict'
    assert value(f"select removed_at is not null from app_private.library_items where account_id='{a}' and document_id='{doc}';") == 't'
    print('PASS concurrent exact-byte reuse and remove-before-resolution fence')

    # In the opposite commit order, resolution succeeds, then a Cancel retires
    # the import-created membership. A replayed completion cannot recreate it.
    c, cop = str(uuid.uuid4()), str(uuid.uuid4())
    sql(f"insert into auth.users values('{c}'); {claims(c)} select public.v2_begin_import('{cop}','2403.01234',0,1);")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(sql, f"begin; set role service_role; select public.worker_resolve_import('{c}','{cop}',1,1,'{approval}'); select pg_sleep(1); commit;")
        sleep_barrier()
        second = pool.submit(sql, f"{claims(c)} select public.v2_cancel_import('{uuid.uuid4()}','{cop}',1);")
        first.result(); second.result()
    sql(f"set role service_role; select public.worker_resolve_import('{c}','{cop}',1,1,'{approval}');")
    assert value(f"select removed_at is not null from app_private.library_items where account_id='{c}' and document_id='{doc}';") == 't'
    assert value(f"select last_remove_seq from app_private.library_items where account_id='{c}' and document_id='{doc}';") == '0'
    print('PASS resolution-before-cancel and lost-ack callback replay')

    # A global cap is shared by accounts; eight users cannot multiply it.
    identities = [str(uuid.uuid4()) for _ in range(8)]
    sql('insert into auth.users values ' + ','.join(f"('{owner}')" for owner in identities) + ';')
    sql("update app_private.library_policy set account_active_imports=1,environment_active_imports=(select count(*)+1 from app_private.import_requests where desired_present and phase in ('accepted','resolving','acquiring'));")

    def capped(owner):
        return sql(f"{claims(owner)} select public.v2_begin_import('{uuid.uuid4()}','2403.01234',0,1);", required=False)

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        limited = list(pool.map(capped, identities))
    assert sum(r.returncode == 0 for r in limited) == 1, [r.stderr for r in limited]
    assert all(r.returncode == 0 or 'library_active_import_limit' in r.stderr for r in limited)
    ids = ','.join(f"'{owner}'" for owner in identities)
    assert value(f"select sum(last_seq) from app_private.library_sync_state where account_id in ({ids});") == '1'
    print('PASS global eight-account import cap; losing transactions leak no cursor/receipt')

    # Explicit budget/account/FK concurrency: the legacy route cannot create
    # paid work, and waiting behind a budget/account lock cannot deadlock it.
    sql("insert into app_private.platform_budgets(period,limit_microusd,work_enabled) values(date_trunc('month',now() at time zone 'UTC')::date,1000,false) on conflict do nothing;")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(sql, f"begin; select 1 from app_private.platform_budgets for update; select 1 from app_private.accounts where id='{b}' for update; select pg_sleep(1); commit;")
        sleep_barrier()
        second = pool.submit(sql, f"set role service_role; select public.worker_request_ocr('{b}','{doc}','fixture',decode(repeat('f1',32),'hex'),'{uuid.uuid4()}',decode(repeat('f2',32),'hex'),'none',0,0);", False)
        first.result(); outcome = second.result()
    assert outcome.returncode != 0 and 'ocr_authorization_required' in outcome.stderr, outcome.stderr
    assert value(f"select count(*) from app_private.metered_operations where account_id='{b}';") == '0'
    print('PASS legacy OCR account/FK lock ordering and explicit new-work denial')


def upgrade(bin_path, db, base):
    def sql(source):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db], input=source, text=True, capture_output=True, timeout=15)
        if result.returncode:
            raise AssertionError(result.stderr)
        lines = result.stdout.strip().splitlines()
        return lines[-1] if lines else ''

    a, doc = str(uuid.uuid4()), str(uuid.uuid4())
    sql(f"insert into auth.users values('{a}'); insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values('{doc}',decode(repeat('cf',32),'hex'),'shared_catalog','{{\"legacy\":true}}',10,1); set role authenticated; select set_config('request.jwt.claim.sub','{a}',false); select public.v1_set_library_item('{doc}',true); select public.v1_set_library_item('{doc}',false);")
    before = sql(f"select id::text||','||document_id::text||','||added_at::text||','||removed_at::text from app_private.library_items where account_id='{a}';")
    sql((ROOT / 'supabase/migrations/202610030010_library_import_contract.sql').read_text())
    after = sql(f"select id::text||','||document_id::text||','||added_at::text||','||removed_at::text from app_private.library_items where account_id='{a}';")
    assert before == after
    assert sql(f"select created_seq||','||state_seq||','||last_remove_seq||','||(approval_id is null)::text from app_private.library_items where account_id='{a}';") == '1,1,1,true'
    assert sql(f"select last_seq||','||retained_after||','||v2_writes_started::text from app_private.library_sync_state where account_id='{a}';") == '1,1,false'
    page = json.loads(sql(f"set role authenticated; select set_config('request.jwt.claim.sub','{a}',false); select public.v2_library_page();"))
    assert len(page['entries']) == 1 and not page['entries'][0]['visible'] and page['entries'][0]['readiness'] == 'unverified'
    print('PASS 009->010 backfill preserves identity/removal; never invents reuse approval')


if __name__ == '__main__':
    binaries = pathlib.Path(os.environ.get('SCIENCE_READER_PG_BIN', '/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin'))
    local = ['-h', '127.0.0.1', '-p', '55431']
    for mode in ('concurrency', 'upgrade'):
        database = 'science_reader_library_' + uuid.uuid4().hex[:12]
        subprocess.run([str(binaries / 'createdb'), *local, database], check=True)
        try:
            sources = [ROOT / 'tests/database/bootstrap.sql', *sorted((ROOT / 'supabase/migrations').glob('*.sql'))]
            if mode == 'upgrade':
                sources = [s for s in sources if s.name != '202610030010_library_import_contract.sql']
            for source in sources:
                result = subprocess.run([str(binaries / 'psql'), *local, '-X', '-v', 'ON_ERROR_STOP=1', '-d', database, '-f', str(source)], capture_output=True, text=True)
                if result.returncode:
                    raise AssertionError(result.stderr)
            (verify if mode == 'concurrency' else upgrade)(binaries, database, local)
        finally:
            subprocess.run([str(binaries / 'dropdb'), *local, database], check=True)
