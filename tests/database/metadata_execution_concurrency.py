"""Real local PostgreSQL executor races; no external I/O or real attestations.

Every wait is observed in pg_stat_activity before the competing mutation. The
short pg_sleep is a transaction barrier, not evidence of executor shutdown.
"""
import concurrent.futures
import json
import pathlib
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
EXECUTOR = 'science_reader_metadata_executor'
OBSERVER = 'science_reader_execution_observer'
ADMITTER = 'science_reader_executor_admitter'


def quoted(value):
    return "'" + str(value).replace("'", "''") + "'"


def verify(bin_path, db, base):
    def sql(source, name=None, required=True):
        prefix = f"set application_name={quoted(name)};" if name else ''
        r = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                           input=prefix + source, text=True, capture_output=True, timeout=20)
        if required and r.returncode:
            raise AssertionError(r.stderr)
        return r.stdout.strip() if required else r

    def value(source):
        return sql(source).splitlines()[-1]

    def call(actor, expression, name=None):
        return json.loads(sql(f'set role {actor}; select {expression};', name).splitlines()[-1])

    def wait(name, event):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if value(f"select exists(select 1 from pg_stat_activity where datname={quoted(db)} and application_name={quoted(name)} and wait_event_type={quoted(event)});") == 't':
                return
            time.sleep(.015)
        raise AssertionError(f'{name} did not reach {event} barrier')

    def job(source):
        return value(f'select test.executor_job({quoted(source)});')

    def grant_args(j, claim=None, binding=None):
        c = claim or str(uuid.uuid4())
        b = binding or json.loads(value('select test.executor_binding();'))
        return f'public.worker_claim_metadata_stage_v2({quoted(j)},{quoted(c)},\'staging\',{quoted(json.dumps(b))})'

    def close(e, resource, known=False):
        return json.loads(value(f"select test.executor_close({quoted(json.dumps(e))},{quoted(resource)},{str(known).lower()});"))

    def settled(e, known=False):
        close(e, 'arxiv_connection', known)
        close(e, 'executor', known)
        sql("update app_private.arxiv_network_gate set next_allowed_at='-infinity';")

    sql('select test.executor_enable();')
    # Eight independently registered SQL commands converge on one new v2 job.
    operations = [str(uuid.uuid4()) for _ in range(8)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        prepared = list(pool.map(lambda op: call(EXECUTOR,
            f"public.worker_prepare_acquisition({quoted(op)},'2403.60001',1)"), operations))
    assert len({r['job']['id'] for r in prepared}) == 1
    assert all(r['job']['execution_contract'] == 'metadata-v2' for r in prepared)
    print('PASS 012 eight-way prepare coalesces new24-slot model without rewriting commands', flush=True)

    # Two simultaneous requests with identical arguments have exactly one fresh
    # permit. Both returned records bind the same execution identity.
    first = job('2403.60002')
    expression = grant_args(first)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: call(EXECUTOR, expression), range(2)))
    assert sum(r['granted'] for r in results) == 1
    assert len({r['execution']['id'] for r in results}) == 1
    e = results[0]['execution']
    # Equivalent proofs with different IDs never allocate receipt aliases.
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        proofs = list(pool.map(lambda _: close(e, 'arxiv_connection'), range(8)))
    assert len({r['receipt_id'] for r in proofs}) == 1
    assert sum(not r['replayed'] for r in proofs) == 1
    assert value(f"select count(*) from app_private.execution_quiescence where attempt_id={quoted(e['id'])};") == '1'
    close(e, 'executor')
    sql("update app_private.arxiv_network_gate set next_allowed_at='-infinity';")
    print('PASS 012 concurrent grant replay executes once; equivalent closure proofs occupy one row', flush=True)

    jobs = [job('2403.60003'), job('2403.60004')]
    expressions = [grant_args(j) for j in jobs]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda expr: call(EXECUTOR, expr), expressions))
    assert sum(r['granted'] for r in results) == 1
    denied = next(j for j, r in zip(jobs, results) if not r['granted'])
    assert value(f"select atom_attempts=0 and generation=0 and state_revision=1 from app_private.acquisition_jobs where id={quoted(denied)};") == 't'
    settled(next(r['execution'] for r in results if r['granted']))
    print('PASS 012 independent schedulers share one executor/source gate without charging a loser', flush=True)

    # Preparer holds policy while awaiting a job. Grant holds that job while
    # awaiting transfer admission. Grant must never acquire the policy lock.
    j = job('2403.60005')
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        holder = pool.submit(sql, "begin; select 1 from app_private.acquisition_transfer_capacity where singleton for update; select pg_sleep(0.8); commit;", 'meta-transfer-lock')
        wait('meta-transfer-lock', 'Timeout')
        claimant = pool.submit(call, EXECUTOR, grant_args(j), 'meta-claim-policy')
        wait('meta-claim-policy', 'Lock')
        preparer = pool.submit(sql, f"begin; select 1 from app_private.acquisition_policy for update; set local role {EXECUTOR}; select public.worker_prepare_acquisition(gen_random_uuid(),'2403.60005',1); commit;", 'meta-preparer')
        wait('meta-preparer', 'Lock')
        holder.result(); result = claimant.result(); preparer.result()
    assert result['granted']
    settled(result['execution'])
    print('PASS 012 policy→job preparation cannot deadlock grant→transfer admission', flush=True)

    # An account linker holds library_policy and then acquires a job FK KEY
    # SHARE. A metadata result may hold only NO KEY UPDATE on the same job.
    j = job('2403.60006')
    c = str(uuid.uuid4())
    result = call(EXECUTOR, grant_args(j, c)); e = result['execution']
    close(e, 'arxiv_connection', True)
    a, imp = str(uuid.uuid4()), str(uuid.uuid4())
    sql(f"insert into auth.users values({quoted(a)}); select set_config('request.jwt.claim.sub',{quoted(a)},false); select public.v2_begin_import({quoted(imp)},'2403.60006',0,1);")
    body = {'revision': 1, 'metadata': {'title': 'Concurrent metadata result', 'authors': ['Author'], 'categories': ['cs.LG']}}
    finish = f"public.worker_finish_metadata_stage_v2({quoted(j)},{quoted(c)},1,{quoted(e['id'])},decode(repeat('f',64),'hex'),{quoted(json.dumps(body))})"
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        linker = pool.submit(sql, f"begin; select 1 from app_private.accounts where id={quoted(a)} for no key update; select 1 from app_private.library_policy for update; select pg_sleep(0.8); set local role {EXECUTOR}; select public.worker_link_import_acquisition({quoted(a)},{quoted(imp)},1,1,{quoted(j)}); commit;", 'meta-linker')
        wait('meta-linker', 'Timeout')
        writer = pool.submit(call, EXECUTOR, finish, 'meta-finish')
        wait('meta-finish', 'Lock')
        linker.result(); finished = writer.result()
    assert finished['stage'] == 'license' and finished['metadata_id'] is not None
    close(e, 'executor', True)
    sql("update app_private.arxiv_network_gate set next_allowed_at='-infinity';")
    print('PASS 012 metadata publication and account-interest FK lock order converge', flush=True)

    # Last-interest cancellation is re-read after a contended admission lock.
    j = job('2403.60007')
    owner, imp = value(f"select account_id||','||import_id from app_private.acquisition_interests where lookup_job_id={quoted(j)};").split(',')
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        holder = pool.submit(sql, "begin; select 1 from app_private.acquisition_transfer_capacity where singleton for update; select pg_sleep(0.8); commit;", 'meta-cancel-lock')
        wait('meta-cancel-lock', 'Timeout')
        claimant = pool.submit(call, EXECUTOR, grant_args(j), 'meta-cancel-claim')
        wait('meta-cancel-claim', 'Lock')
        sql(f"select set_config('request.jwt.claim.sub',{quoted(owner)},false); select public.v2_cancel_import(gen_random_uuid(),{quoted(imp)},1);")
        holder.result(); result = claimant.result()
    assert result['action'] == 'no_interest'
    assert value(f"select generation=0 and atom_attempts=0 from app_private.acquisition_jobs where id={quoted(j)};") == 't'
    print('PASS 012 last-interest cancel during wait consumes no attempt or receipt', flush=True)

    # Cancelling one of two imports cannot revoke the other user's shared work.
    j = job('2403.60008')
    first_owner, first_imp = value(f"select account_id||','||import_id from app_private.acquisition_interests where lookup_job_id={quoted(j)};").split(',')
    a, imp = str(uuid.uuid4()), str(uuid.uuid4())
    sql(f"insert into auth.users values({quoted(a)}); select set_config('request.jwt.claim.sub',{quoted(a)},false); select public.v2_begin_import({quoted(imp)},'2403.60008',0,1);")
    call(EXECUTOR, f"public.worker_link_import_acquisition({quoted(a)},{quoted(imp)},1,1,{quoted(j)})")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        holder = pool.submit(sql, "begin; select 1 from app_private.acquisition_transfer_capacity where singleton for update; select pg_sleep(0.8); commit;", 'meta-shared-lock')
        wait('meta-shared-lock', 'Timeout')
        claimant = pool.submit(call, EXECUTOR, grant_args(j), 'meta-shared-claim')
        wait('meta-shared-claim', 'Lock')
        sql(f"select set_config('request.jwt.claim.sub',{quoted(first_owner)},false); select public.v2_cancel_import(gen_random_uuid(),{quoted(first_imp)},1);")
        holder.result(); result = claimant.result()
    assert result['granted']
    settled(result['execution'])
    print('PASS 012 one cancelled import preserves surviving shared interest', flush=True)

    # Legacy kill switch remains an independently checked deny condition, even
    # though the new authority row cannot change during its admission mutex.
    j = job('2403.60009')
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        holder = pool.submit(sql, "begin; select 1 from app_private.acquisition_transfer_capacity where singleton for update; select pg_sleep(0.8); commit;", 'meta-disable-lock')
        wait('meta-disable-lock', 'Timeout')
        claimant = pool.submit(call, EXECUTOR, grant_args(j), 'meta-disable-claim')
        wait('meta-disable-claim', 'Lock')
        sql('update app_private.acquisition_policy set metadata_enabled=false;')
        holder.result(); result = claimant.result()
    assert result['action'] == 'disabled'
    assert value(f"select generation=0 and atom_attempts=0 from app_private.acquisition_jobs where id={quoted(j)};") == 't'
    sql('update app_private.acquisition_policy set metadata_enabled=true;')
    print('PASS 012 policy disable committed during admission wait blocks source work', flush=True)

    # Closure commits and epoch retirement contend on the same authority mutex;
    # neither can discard the other fact or accept a stale admission CAS.
    j = job('2403.60010'); result = call(EXECUTOR, grant_args(j)); e = result['execution']
    revision = int(value('select revision from app_private.executor_authority;'))
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        tasks = [pool.submit(close, e, resource) for resource in ('executor', 'arxiv_connection')]
        tasks.append(pool.submit(call, ADMITTER, f'public.worker_retire_metadata_executor({revision})'))
        for task in tasks:
            task.result()
    assert value('select not enabled and recovery_required from app_private.executor_authority;') == 't'
    assert value(f"select count(*) from app_private.execution_quiescence where attempt_id={quoted(e['id'])};") == '2'
    assert not any(x['id'] == e['id'] for x in call(OBSERVER, 'public.worker_scan_unsettled_metadata_executions()'))
    print('PASS 012 concurrent retirement and independent closure receipts preserve both facts', flush=True)

    upgrade(bin_path, base)


def upgrade(bin_path, base):
    """Populated legacy job history stays immutable and cannot masquerade as v2."""
    db = 'science_reader_meta_upgrade_' + uuid.uuid4().hex[:12]
    candidate = ROOT / 'supabase/migrations/202610030012_metadata_execution.sql.pending'
    if not candidate.exists():
        candidate = candidate.with_suffix('')
    def sql(text):
        r = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db], input=text, text=True, capture_output=True, timeout=20)
        if r.returncode:
            raise AssertionError(r.stderr)
        return r.stdout.strip()
    subprocess.run([str(bin_path / 'createdb'), *base, db], check=True)
    try:
        sql(f'ALTER DATABASE "{db}" SET timezone TO \'UTC\';')
        for path in [ROOT / 'tests/database/bootstrap.sql', *sorted(p for p in (ROOT / 'supabase/migrations').glob('*.sql') if p.name < '202610030012')]:
            sql(path.read_text())
        old, claim, new = (str(uuid.uuid4()) for _ in range(3))
        sql(f"select public.worker_prepare_acquisition({quoted(old)},'2403.60101',1);")
        before = json.loads(sql(f"select to_jsonb(j) from app_private.acquisition_jobs j where id={quoted(old)};"))
        sql(f"insert into app_private.acquisition_steps(job_id,operation_id,request_sha256,kind,generation,stage,network_token,network_closed_at) values({quoted(old)},{quoted(claim)},sha256('legacy-fixture'::bytea),'arxiv_stage',1,'atom',gen_random_uuid(),clock_timestamp());")
        sql(candidate.read_text())
        after = json.loads(sql(f"select to_jsonb(j) from app_private.acquisition_jobs j where id={quoted(old)};"))
        assert after.pop('execution_contract') == 'legacy-011' and after == before
        replay = json.loads(sql(f"select public.worker_prepare_acquisition({quoted(old)},'2403.60101',1);"))
        assert replay['replayed'] and replay['job']['execution_contract'] == 'legacy-011'
        fresh = json.loads(sql(f"select public.worker_prepare_acquisition({quoted(new)},'2403.60101',1);"))
        assert fresh['job']['id'] == new and fresh['job']['execution_contract'] == 'metadata-v2'
        assert sql(f"select slots_held from app_private.acquisition_jobs where id={quoted(old)};") == '12'
        assert sql('select app_private.legacy_execution_unsettled();') == 't'
        assert sql('select not enabled and recovery_required from app_private.executor_authority;') == 't'
        print('PASS populated 011→012 preserves old12-slot histories/receipts and requires new-model generation', flush=True)
    finally:
        subprocess.run([str(bin_path / 'dropdb'), *base, db], check=True)
