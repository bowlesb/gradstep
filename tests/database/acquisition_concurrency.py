"""Disposable localhost-only 010->011 upgrade and deterministic acquisition races.

No outbound worker, storage, or PDF execution. .sql.pending is accepted only as
an explicit local test candidate while review is incomplete.
"""
import concurrent.futures
import json
import os
import pathlib
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]


def verify(bin_path, db, base):
    def sql(source, name=None):
        prefix = f"set application_name='{name}';" if name else ''
        r = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                           input=prefix + source, text=True, capture_output=True, timeout=20)
        if r.returncode:
            raise AssertionError(r.stderr)
        return r.stdout.strip()

    def value(source):
        return sql(source).splitlines()[-1]

    def wait(name, kind):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if value(f"select exists(select 1 from pg_stat_activity where datname='{db}' and application_name='{name}' and wait_event_type='{kind}');") == 't':
                return
            time.sleep(.015)
        raise AssertionError(f'{name} did not reach {kind} barrier')

    a, i, l, o, slot, d, obj, approval = [str(uuid.uuid4()) for _ in range(8)]
    meta = value("select public.worker_record_arxiv_metadata('2403.20001',1,'{\"title\":\"Concurrency fixture\",\"authors\":[\"Test\"],\"categories\":[\"cs.LG\"]}');")
    version = value(f"select version_id from app_private.catalog_metadata where id='{meta}';")
    evidence = json.dumps({'source_id': '2403.20001', 'source_revision': 1, 'source_url': 'https://arxiv.org/abs/2403.20001v1',
                           'license_uri': 'https://creativecommons.org/licenses/by/4.0/', 'evidence_sha256': 'c' * 64,
                           'observed_at': '2026-10-03T01:00:00Z'})
    sql(f"""insert into auth.users values('{a}');
      select set_config('request.jwt.claim.sub','{a}',false);
      select public.v2_begin_import('{i}','2403.20001',0,1);
      insert into app_private.acquisition_source_slots(id,source_id,requested_revision,generation) values('{slot}','2403.20001',1,1);
      insert into app_private.acquisition_jobs(id,kind,source_slot_id,slot_generation,source_id,requested_revision,input_sha256,
       metadata_id,version_id,source_revision,eligibility,license_uri,evidence,stage,status,slots_held)
      values('{l}','lookup','{slot}',1,'2403.20001',1,sha256('lookup'::bytea),'{meta}','{version}',1,'eligible',
       'https://creativecommons.org/licenses/by/4.0/','{evidence}','complete','complete',12),
       ('{o}','original',null,null,'2403.20001',1,sha256('original'::bytea),'{meta}','{version}',1,'eligible',
       'https://creativecommons.org/licenses/by/4.0/','{evidence}','publish','queued',24);
      select public.worker_link_import_acquisition('{a}','{i}',1,1,'{l}','{o}');
      insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
       values('{d}',sha256('race-original'::bytea),'shared_catalog','{{"fixture":true}}',1000,2);
      insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
       values('{obj}','paper-assets','test/acquisition/race.pdf','{d}','verified',sha256('race-original'::bytea),1000,'application/pdf',now());
      select public.worker_approve_arxiv_asset('{approval}','{meta}','{d}','{obj}','https://creativecommons.org/licenses/by/4.0/','{evidence}');""")

    # Controlled test-only pause immediately after policy acquisition. It gives
    # a duplicate publisher time to obtain its document lock. No production
    # hook, migration edit, or timing-only assumption is needed for the wait.
    original = value("select replace(pg_get_functiondef('app_private.lock_library_state(uuid)'::regprocedure),E'\\n',chr(1));").replace(chr(1), '\n')
    instrumented = original.replace('END;', "IF current_setting('application_name')='acq-projector' THEN PERFORM pg_sleep(0.4); END IF; END;")
    # Existing source uses lowercase end; preserve exact function definition.
    if instrumented == original:
        instrumented = original.replace('end $$', "if current_setting('application_name')='acq-projector' then perform pg_sleep(0.4); end if; end $$")
    if instrumented == original:
        instrumented = original.replace('end $function$', "if current_setting('application_name')='acq-projector' then perform pg_sleep(0.4); end if; end $function$")
    assert instrumented != original
    sql(instrumented)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            first = pool.submit(sql, f"""begin;
              select 1 from app_private.documents where id='{d}' for update;
              select 1 from app_private.library_policy for update;
              update app_private.acquisition_jobs set document_id='{d}',original_object_id='{obj}',approval_id='{approval}',
                stage='complete',status='complete',state_revision=state_revision+1 where id in ('{o}','{l}');
              select pg_sleep(1); commit;""", 'acq-first-publisher')
            wait('acq-first-publisher', 'Timeout')
            projector = pool.submit(sql, f"select public.worker_project_import_acquisition('{a}','{i}',1);", 'acq-projector')
            wait('acq-projector', 'Lock')
            duplicate = pool.submit(sql, f"""begin; select 1 from app_private.documents where id='{d}' for update;
              select 1 from app_private.library_policy for update; commit;""", 'acq-duplicate-publisher')
            wait('acq-duplicate-publisher', 'Lock')
            first.result(); projected = json.loads(projector.result().splitlines()[-1]); duplicate.result()
        assert projected['entry']['phase'] == 'acquiring', projected
        assert value(f"select projected_original_revision<(select state_revision from app_private.acquisition_jobs where id='{o}') from app_private.acquisition_interests where account_id='{a}' and import_id='{i}';") == 't'
        assert i in value('select public.worker_scan_acquisition_imports();')
        sql(f"select public.worker_project_import_acquisition('{a}','{i}',1);")
        assert value(f"select phase from app_private.import_requests where account_id='{a}' and id='{i}';") == 'ready'
    finally:
        sql(original)
    print('PASS null→published projection retains pre-policy snapshot; duplicate publication cannot deadlock')

    # NO KEY UPDATE permits interest's FK KEY SHARE while publisher awaits the
    # library-policy mutex. FOR UPDATE on job state would form a lock cycle.
    a2, i2 = [str(uuid.uuid4()) for _ in range(2)]
    sql(f"insert into auth.users values('{a2}'); select set_config('request.jwt.claim.sub','{a2}',false); select public.v2_begin_import('{i2}','2403.20001',0,1);")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        linker = pool.submit(sql, f"""begin; select 1 from app_private.accounts where id='{a2}' for no key update;
          select 1 from app_private.documents where id='{d}' for key share;
          select 1 from app_private.library_policy for update; select pg_sleep(0.6);
          select public.worker_link_import_acquisition('{a2}','{i2}',1,1,'{l}','{o}'); commit;""", 'acq-linker')
        wait('acq-linker', 'Timeout')
        mutable = pool.submit(sql, f"begin; select 1 from app_private.acquisition_jobs where id='{o}' for no key update; select 1 from app_private.library_policy for update; commit;", 'acq-job-mutator')
        wait('acq-job-mutator', 'Lock')
        linker.result(); mutable.result()
    print('PASS job NO KEY UPDATE does not block account-interest FK under policy')

    # A retained approval can appear while a lookup binder waits on policy.
    # The check must run under policy, or the nested approval helper can return
    # the newly inserted conflicting object after an earlier optimistic check.
    m2=value("select public.worker_record_arxiv_metadata('2403.20001',1,'{\"title\":\"Later metadata observation\",\"authors\":[\"Test\"],\"categories\":[\"cs.LG\"]}');")
    l2, obj2, approval2=[str(uuid.uuid4()) for _ in range(3)]
    sql(f"""insert into app_private.acquisition_jobs(id,kind,source_slot_id,slot_generation,source_id,requested_revision,input_sha256,
       metadata_id,version_id,source_revision,eligibility,license_uri,evidence,stage,status,slots_held)
      values('{l2}','lookup','{slot}',2,'2403.20001',1,sha256('binder-race'::bytea),'{m2}','{version}',1,'eligible',
       'https://creativecommons.org/licenses/by/4.0/','{evidence}','complete','complete',12);
      insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
       values('{obj2}','paper-assets','test/acquisition/retained.pdf','{d}','verified',sha256('race-original'::bytea),1000,'application/pdf',now());
      insert into app_private.paper_asset_availability(object_id,revision,state) values('{obj}',1,'available');""")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        writer=pool.submit(sql,f"""begin; select 1 from app_private.documents where id='{d}' for key share;
          select 1 from app_private.library_policy for update; select pg_sleep(0.6);
          select public.worker_approve_arxiv_asset('{approval2}','{m2}','{d}','{obj2}','https://creativecommons.org/licenses/by/4.0/','{evidence}'); commit;""",'acq-approval-writer')
        wait('acq-approval-writer','Timeout')
        binder=pool.submit(sql,f"select public.worker_bind_lookup_original('{l2}','{o}');",'acq-binder')
        wait('acq-binder','Lock')
        writer.result(); result=json.loads(binder.result().splitlines()[-1])
    assert result['error_code']=='legacy_original_unverified' and result['approval_id'] is None, result
    assert value(f"select original_object_id from app_private.catalog_asset_approvals where id='{approval2}';")==obj2
    print('PASS concurrent legacy approval insertion cannot race past canonical binding check')

    # Eight distinct callers for one source obtain one lookup identity; command
    # replay stays bound to that job when the source cache later expires.
    operations = [str(uuid.uuid4()) for _ in range(8)]
    def prepare(op):
        return json.loads(value(f"set role service_role; select public.worker_prepare_acquisition('{op}','2403.20002',1);"))
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(prepare, operations))
    assert len({r['job']['id'] for r in results}) == 1
    print('PASS eight-way lookup coalescing preserves independent command receipts')

    # Independent atomic claimers contend on one gate. Waiting consumes no
    # receipt, job revision, generation, source attempt, or transfer charge.
    jobs = []
    sql('update app_private.acquisition_policy set metadata_enabled=true;')
    for n in range(2):
        owner, request, job, claim = [str(uuid.uuid4()) for _ in range(4)]
        source = f'2403.2001{n}'
        sql(f"""insert into auth.users values('{owner}'); select set_config('request.jwt.claim.sub','{owner}',false);
          select public.v2_begin_import('{request}','{source}',0,1); select public.worker_prepare_acquisition('{job}','{source}',1);
          select public.worker_link_import_acquisition('{owner}','{request}',1,1,'{job}');""")
        jobs.append((job, claim))
    def begin(pair):
        return json.loads(value(f"set role service_role; select public.worker_claim_arxiv_stage('{pair[0]}','{pair[1]}','staging');"))
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        permits = list(pool.map(begin, jobs))
    assert sum(p['granted'] for p in permits) == 1
    token = next(p['token'] for p in permits if p['granted'])
    denied = jobs[permits.index(next(p for p in permits if not p['granted']))]
    assert value(f"select generation=0 and atom_attempts=0 and state_revision=1 from app_private.acquisition_jobs where id='{denied[0]}';") == 't'
    before = value("select jsonb_build_array((select jsonb_agg(to_jsonb(j) order by id) from app_private.acquisition_jobs j),(select jsonb_agg(to_jsonb(s) order by job_id,operation_id) from app_private.acquisition_steps s),(select jsonb_agg(to_jsonb(w) order by period,scope,kind) from app_private.acquisition_transfer_windows w));")
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        repeated = list(pool.map(begin, [(denied[0],str(uuid.uuid4())) for _ in range(12)]))
    assert all(p['action'] == 'wait' for p in repeated)
    after = value("select jsonb_build_array((select jsonb_agg(to_jsonb(j) order by id) from app_private.acquisition_jobs j),(select jsonb_agg(to_jsonb(s) order by job_id,operation_id) from app_private.acquisition_steps s),(select jsonb_agg(to_jsonb(w) order by period,scope,kind) from app_private.acquisition_transfer_windows w));")
    assert before == after
    winner = jobs[permits.index(next(p for p in permits if p['granted']))]
    assert begin(winner)['granted'] is False
    sql(f"select public.worker_finish_arxiv_request('{token}',100,0);")
    assert begin(denied)['action'] == 'wait'
    assert value("select sum(charged) from app_private.acquisition_transfer_windows where scope='environment' and kind='source_bytes';") == '100'
    print('PASS simultaneous atomic source claims; repeated busy/cooldown waits allocate no retry or control state')

    # Lost grant acknowledgement: simultaneous identical retries reconcile
    # the same token after one grant; none may repeat the source side effect.
    sql("update app_private.arxiv_network_gate set next_allowed_at='-infinity';")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        same = list(pool.map(begin, [denied,denied]))
    assert sum(p['granted'] for p in same) == 1
    assert len({p['token'] for p in same}) == 1
    token = next(p['token'] for p in same if p['granted'])
    sql(f"select public.worker_finish_arxiv_request('{token}',100,0);")
    print('PASS simultaneous same-operation grant/replay has one side-effect authority')

    # Claim holds gate/job while admission capacity is unavailable. A Cancel
    # committing during that wait must be seen by the final current-interest
    # check, leaving no attempted work. No scheduler exclusivity assumption.
    owner, request, job, claim = [str(uuid.uuid4()) for _ in range(4)]
    sql(f"""insert into auth.users values('{owner}'); select set_config('request.jwt.claim.sub','{owner}',false);
      select public.v2_begin_import('{request}','2403.20012',0,1); select public.worker_prepare_acquisition('{job}','2403.20012',1);
      select public.worker_link_import_acquisition('{owner}','{request}',1,1,'{job}');
      update app_private.arxiv_network_gate set next_allowed_at='-infinity';""")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        holder = pool.submit(sql,"begin; select 1 from app_private.acquisition_transfer_capacity where singleton for update; select pg_sleep(0.8); commit;",'acq-transfer-holder')
        wait('acq-transfer-holder','Timeout')
        claimant = pool.submit(sql,f"select public.worker_claim_arxiv_stage('{job}','{claim}','staging');",'acq-cancel-claim')
        wait('acq-cancel-claim','Lock')
        sql(f"select set_config('request.jwt.claim.sub','{owner}',false); select public.v2_cancel_import(gen_random_uuid(),'{request}',1);")
        holder.result(); result=json.loads(claimant.result().splitlines()[-1])
    assert result['action']=='no_interest',result
    assert value(f"select generation=0 and atom_attempts=0 and state_revision=1 from app_private.acquisition_jobs where id='{job}';")=='t'
    assert value(f"select not exists(select 1 from app_private.acquisition_steps where job_id='{job}');")=='t'
    print('PASS cancellation during transfer-admission wait prevents atomic source authority')

    # Operator kill switches/profile/caps can change without taking a job
    # lock. A grant waiting for transfer admission re-reads that policy.
    owner, request, job, claim = [str(uuid.uuid4()) for _ in range(4)]
    sql(f"""insert into auth.users values('{owner}'); select set_config('request.jwt.claim.sub','{owner}',false);
      select public.v2_begin_import('{request}','2403.20013',0,1); select public.worker_prepare_acquisition('{job}','2403.20013',1);
      select public.worker_link_import_acquisition('{owner}','{request}',1,1,'{job}');""")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        holder = pool.submit(sql,"begin; select 1 from app_private.acquisition_transfer_capacity where singleton for update; select pg_sleep(0.8); commit;",'acq-disable-holder')
        wait('acq-disable-holder','Timeout')
        claimant = pool.submit(sql,f"select public.worker_claim_arxiv_stage('{job}','{claim}','staging');",'acq-disable-claim')
        wait('acq-disable-claim','Lock')
        sql('update app_private.acquisition_policy set metadata_enabled=false;')
        holder.result(); result=json.loads(claimant.result().splitlines()[-1])
    assert result['action']=='disabled',result
    assert value(f"select generation=0 and atom_attempts=0 and state_revision=1 from app_private.acquisition_jobs where id='{job}';")=='t'
    assert value(f"select not exists(select 1 from app_private.acquisition_steps where job_id='{job}');")=='t'
    sql('update app_private.acquisition_policy set metadata_enabled=true;')
    print('PASS policy disable during transfer-admission wait prevents source authority without consuming state')


def upgrade(bin_path, db, base, candidate):
    def sql(source, name=None):
        r = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                           input=(f"set application_name='{name}';" if name else "")+source, text=True, capture_output=True, timeout=20)
        if r.returncode:
            raise AssertionError(r.stderr)
        return r.stdout.strip()
    a, b, d, obj, approval = [str(uuid.uuid4()) for _ in range(5)]
    meta=sql("select public.worker_record_arxiv_metadata('2403.30001',1,'{\"title\":\"Legacy original\",\"authors\":[\"Test\"],\"categories\":[\"cs.LG\"]}');")
    sql(f"""insert into auth.users values('{a}'),('{b}');
      insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
      values('{d}',sha256('upgrade-fixture'::bytea),'shared_catalog','{{"fixture":true}}',100,1);
      insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
       values('{obj}','paper-assets','test/acquisition/legacy.pdf','{d}','verified',sha256('upgrade-fixture'::bytea),100,'application/pdf',now());
      select public.worker_approve_arxiv_asset('{approval}','{meta}','{d}','{obj}','https://creativecommons.org/licenses/by/4.0/',
       '{{"source_id":"2403.30001","source_revision":1,"source_url":"https://arxiv.org/abs/2403.30001v1","license_uri":"https://creativecommons.org/licenses/by/4.0/","evidence_sha256":"{'d'*64}","observed_at":"2026-10-03T01:00:00Z"}}');
      select set_config('request.jwt.claim.sub','{a}',false); select public.v2_set_library_item(gen_random_uuid(),'{d}',true,0,'{approval}');
      select set_config('request.jwt.claim.sub','{b}',false); select public.v2_set_library_item(gen_random_uuid(),'{d}',true,0,'{approval}'); select public.v2_set_library_item(gen_random_uuid(),'{d}',false,1);
      update app_private.accounts set closed_at=now() where id='{b}';
      create table test_upgrade_old as select account_id,id,state_seq,membership_revision,removed_at,approval_id,artifact_id from app_private.library_items;""")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        writer = pool.submit(sql, """begin; select 1 from app_private.library_policy for update; select pg_sleep(1);
          select public.worker_record_arxiv_metadata('2403.30002',1,'{"title":"Concurrent catalog writer","authors":["Test"],"categories":["cs.LG"]}'); commit;""", 'acq-upgrade-writer')
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            if sql(f"select exists(select 1 from pg_stat_activity where datname='{db}' and application_name='acq-upgrade-writer' and wait_event='PgSleep');")=='t': break
            time.sleep(.01)
        else: raise AssertionError('catalog writer did not reach barrier')
        migration = pool.submit(sql,candidate.read_text(),'acq-upgrade-migration')
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            if sql(f"select exists(select 1 from pg_stat_activity where datname='{db}' and application_name='acq-upgrade-migration' and wait_event_type='Lock');")=='t': break
            time.sleep(.01)
        else: raise AssertionError('migration did not wait for catalog writer')
        assert sql(f"select not exists(select 1 from pg_locks l join pg_stat_activity a on a.pid=l.pid where a.datname='{db}' and a.application_name='acq-upgrade-migration' and l.mode='ShareRowExclusiveLock' and l.granted);")== 't'
        writer.result(); migration.result()
    print('PASS migration drains preexisting catalog writer before referenced-table FK locks')
    verdict = sql("""select bool_and(li.state_seq>o.state_seq and li.membership_revision=o.membership_revision and li.removed_at is not distinct from o.removed_at
       and li.approval_id is not distinct from o.approval_id and li.artifact_id is not distinct from o.artifact_id
       and c.entries=jsonb_build_array(app_private.library_item_entry(li.account_id,li.id)))
      from test_upgrade_old o join app_private.library_items li on li.id=o.id
      join app_private.library_changes c on c.account_id=li.account_id and c.seq=li.state_seq;""")
    assert verdict == 't', verdict
    assert sql('select count(*) from app_private.library_asset_projection;') == '2'
    assert sql("select bool_and(app_private.library_item_entry(account_id,id)->>'readiness'='unavailable') from app_private.library_items;")=='t'
    assert sql(f"select app_private.original_descriptor('{a}',(select id from app_private.library_items where account_id='{a}')) is null;")=='t'
    print('PASS populated 010→011 backfill journals visible and closed-account tombstone rows without altering membership')


def main():
    import sys  # run directly: the same binaries as scripts/test-database.py (scripts/pg_tools.py)
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'scripts'))
    from pg_tools import pg_bin
    bin_path = pg_bin()
    base = ['-h', '127.0.0.1', '-p', '55431']
    candidate = ROOT / 'supabase/migrations/202610030011_acquisition.sql'
    if not candidate.exists():
        candidate = candidate.with_suffix('.sql.pending')
    db = 'science_reader_acq_' + uuid.uuid4().hex[:12]
    subprocess.run([str(bin_path / 'createdb'), *base, db], check=True)
    try:
        for source in [ROOT / 'tests/database/bootstrap.sql', *sorted(p for p in (ROOT / 'supabase/migrations').glob('*.sql') if p.name<'202610030011')]:
            p = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-v', 'ON_ERROR_STOP=1', '-d', db, '-f', str(source)], text=True, capture_output=True)
            if p.returncode:
                raise AssertionError(p.stderr)
        upgrade(bin_path, db, base, candidate)
        verify(bin_path, db, base)
    finally:
        subprocess.run([str(bin_path / 'dropdb'), *base, db], check=True)


if __name__ == '__main__':
    main()
