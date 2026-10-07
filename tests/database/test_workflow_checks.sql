-- Workflow checks (migration 024): runs are recorded atomically and idempotently by the service
-- role only, validated and bounded; owners with MFA read the latest result per check; the
-- snapshot reports stuck imports but not resting shared private_split rows.
begin;
insert into auth.users values('24000000-0000-0000-0000-00000000000a'),('24000000-0000-0000-0000-00000000000b');

-- Recording: service role only.
set role service_role;
select public.worker_record_workflow_check_run(jsonb_build_object('id','24000000-0000-0000-0000-0000000000d1','suite','daily','trigger','schedule',
 'git_commit','b5fb04050083','started_at',now()-interval '10 minutes','finished_at',now()-interval '2 minutes','cost_microusd',120000,
 'results',jsonb_build_array(
  jsonb_build_object('check_id','config.pipeline-url','status','pass','reason','Vault → worker','duration_ms',800),
  jsonb_build_object('check_id','ingest.not-found','status','fail','reason','the find step ran out of its 45 s budget','duration_ms',49000,
   'cost_microusd',5000,'metrics',jsonb_build_object('find_s',45.0,'credits',1)),
  jsonb_build_object('check_id','import.arxiv','status','pass','reason','ready in 7 s','duration_ms',15000,'metrics',jsonb_build_object('time_to_ready_s',15)))))
 as first \gset
reset role;
select test.assert((:'first'::jsonb->>'replayed')='false','a run is recorded');
select test.assert((select passed=2 and failed=1 and warned=0 and skipped=0 and cost_microusd=120000 from app_private.workflow_check_runs
 where id='24000000-0000-0000-0000-0000000000d1'),'counts are derived from the results');
-- The same body again is a replay; a different body under the same ID is refused.
select started_at as run_started,finished_at as run_finished from app_private.workflow_check_runs where id='24000000-0000-0000-0000-0000000000d1' \gset
set role service_role;
select public.worker_record_workflow_check_run(r) ->> 'replayed' as replayed from (select jsonb_build_object('id','24000000-0000-0000-0000-0000000000d1',
 'suite','daily','trigger','schedule','git_commit','b5fb04050083','started_at',:'run_started'::timestamptz,'finished_at',:'run_finished'::timestamptz,'cost_microusd',120000,
 'results',jsonb_build_array(
  jsonb_build_object('check_id','config.pipeline-url','status','pass','reason','Vault → worker','duration_ms',800),
  jsonb_build_object('check_id','ingest.not-found','status','fail','reason','the find step ran out of its 45 s budget','duration_ms',49000,
   'cost_microusd',5000,'metrics',jsonb_build_object('find_s',45.0,'credits',1)),
  jsonb_build_object('check_id','import.arxiv','status','pass','reason','ready in 7 s','duration_ms',15000,'metrics',jsonb_build_object('time_to_ready_s',15)))) r) x \gset
select test.assert(:'replayed'='true','an identical run is a replay');
select test.reject($$select public.worker_record_workflow_check_run('{"id":"24000000-0000-0000-0000-0000000000d1","suite":"daily","trigger":"schedule",
 "started_at":"2026-10-07T00:00:00Z","finished_at":"2026-10-07T00:01:00Z","results":[{"check_id":"import.arxiv","status":"pass","reason":"","duration_ms":1}]}')$$,
 'workflow_run_conflict');
reset role;
select test.assert((select count(*) from app_private.workflow_check_results where run_id='24000000-0000-0000-0000-0000000000d1')=3,'a conflict changes nothing');

-- Validation: bad status, duplicate check, non-numeric metric, long reason, bad suite, no results, bad ID, finish before start.
create temporary table bad_runs(body jsonb) on commit drop;
grant all on bad_runs to service_role;
insert into bad_runs values
 ('{"id":"24000000-0000-0000-0000-0000000000e1","suite":"daily","trigger":"schedule","started_at":"2026-10-07T00:00:00Z","finished_at":"2026-10-07T00:01:00Z","results":[{"check_id":"a.b","status":"broken","reason":"","duration_ms":1}]}'),
 ('{"id":"24000000-0000-0000-0000-0000000000e2","suite":"daily","trigger":"schedule","started_at":"2026-10-07T00:00:00Z","finished_at":"2026-10-07T00:01:00Z","results":[{"check_id":"a.b","status":"pass","reason":"","duration_ms":1},{"check_id":"a.b","status":"fail","reason":"","duration_ms":1}]}'),
 ('{"id":"24000000-0000-0000-0000-0000000000e3","suite":"daily","trigger":"schedule","started_at":"2026-10-07T00:00:00Z","finished_at":"2026-10-07T00:01:00Z","results":[{"check_id":"a.b","status":"pass","reason":"","duration_ms":1,"metrics":{"account":"someone"}}]}'),
 (('{"id":"24000000-0000-0000-0000-0000000000e4","suite":"daily","trigger":"schedule","started_at":"2026-10-07T00:00:00Z","finished_at":"2026-10-07T00:01:00Z","results":[{"check_id":"a.b","status":"pass","duration_ms":1,"reason":"'||repeat('x',501)||'"}]}')::jsonb),
 ('{"id":"24000000-0000-0000-0000-0000000000e5","suite":"hourly","trigger":"schedule","started_at":"2026-10-07T00:00:00Z","finished_at":"2026-10-07T00:01:00Z","results":[{"check_id":"a.b","status":"pass","reason":"","duration_ms":1}]}'),
 ('{"id":"24000000-0000-0000-0000-0000000000e6","suite":"daily","trigger":"schedule","started_at":"2026-10-07T00:00:00Z","finished_at":"2026-10-07T00:01:00Z","results":[]}'),
 ('{"id":"not-a-uuid","suite":"daily","trigger":"schedule","started_at":"2026-10-07T00:00:00Z","finished_at":"2026-10-07T00:01:00Z","results":[{"check_id":"a.b","status":"pass","reason":"","duration_ms":1}]}'),
 ('{"id":"24000000-0000-0000-0000-0000000000e8","suite":"daily","trigger":"schedule","started_at":"2026-10-07T00:01:00Z","finished_at":"2026-10-07T00:00:00Z","results":[{"check_id":"a.b","status":"pass","reason":"","duration_ms":1}]}'),
 ('{"id":"24000000-0000-0000-0000-0000000000e9","suite":"daily","trigger":"Bad Trigger","started_at":"2026-10-07T00:00:00Z","finished_at":"2026-10-07T00:01:00Z","results":[{"check_id":"a.b","status":"pass","reason":"","duration_ms":1}]}'),
 ('{"id":"24000000-0000-0000-0000-0000000000ea","suite":"daily","trigger":"schedule","started_at":"yesterday-ish","finished_at":"2026-10-07T00:01:00Z","results":[{"check_id":"a.b","status":"pass","reason":"","duration_ms":1}]}');
set role service_role;
do $$ declare b jsonb; begin
 for b in select body from bad_runs loop
  begin
   perform public.worker_record_workflow_check_run(b);
   raise exception 'accepted an invalid run: %',left(b::text,120);
  exception when raise_exception then
   if sqlerrm<>'invalid_workflow_run' then raise; end if;
  end;
 end loop;
end $$;
reset role;
select test.assert((select count(*) from app_private.workflow_check_runs)=1,'invalid runs leave nothing behind');

-- Customers and anonymous callers cannot record or read the snapshot.
set role authenticated;
select set_config('request.jwt.claim.sub','24000000-0000-0000-0000-00000000000a',false);
select test.reject($$select public.worker_record_workflow_check_run('{}')$$,'permission denied');
select test.reject('select public.worker_workflow_snapshot()','permission denied');
reset role;
set role anon;
select test.reject($$select public.worker_record_workflow_check_run('{}')$$,'permission denied');
select test.reject('select public.v1_admin_workflow_checks(14)','permission denied');
reset role;

-- Retention: runs older than 180 days go when a new run is recorded.
set role service_role;
select public.worker_record_workflow_check_run(jsonb_build_object('id','24000000-0000-0000-0000-0000000000d0','suite','weekly','trigger','schedule',
 'started_at',now()-interval '200 days','finished_at',now()-interval '200 days'+interval '20 minutes',
 'results',jsonb_build_array(jsonb_build_object('check_id','import.large-pdf','status','pass','reason','ready','duration_ms',60000))));
select public.worker_record_workflow_check_run(jsonb_build_object('id','24000000-0000-0000-0000-0000000000d2','suite','deploy','trigger','deploy-staging',
 'started_at',now()-interval '1 minute','finished_at',now(),
 'results',jsonb_build_array(jsonb_build_object('check_id','config.pipeline-url','status','fail','reason','Vault points at the retired Edge paper-worker','duration_ms',900))));
reset role;
select test.assert(not exists(select 1 from app_private.workflow_check_runs where id='24000000-0000-0000-0000-0000000000d0'),'old runs are pruned');
select test.assert(not exists(select 1 from app_private.workflow_check_results where run_id='24000000-0000-0000-0000-0000000000d0'),'with their results');

-- Owner read: MFA required; latest result per check and the last run per suite.
set role authenticated;
select set_config('request.jwt.claim.sub','24000000-0000-0000-0000-00000000000b',false);
select test.reject('select public.v1_admin_workflow_checks(14)','owner_mfa_required');
reset role;
insert into app_private.app_roles values('24000000-0000-0000-0000-00000000000b','owner',now());
set role authenticated;
select set_config('request.jwt.claim.aal','aal2',false);
select public.v1_admin_workflow_checks(14) as w \gset
select test.assert(:'w'::jsonb->'last_runs'->'daily'->>'failed'='1' and :'w'::jsonb->'last_runs'->'deploy'->>'trigger'='deploy-staging','last run per suite');
select test.assert(not (:'w'::jsonb->'last_runs' ? 'weekly'),'pruned runs are gone from the read');
select test.assert(jsonb_array_length(:'w'::jsonb->'runs')=2,'recent runs');
select test.assert((select c->'latest'->>'status' from jsonb_array_elements(:'w'::jsonb->'checks') c where c->>'check_id'='config.pipeline-url')='fail',
 'the latest result wins');
select test.assert((select c->'counts'->>'pass' from jsonb_array_elements(:'w'::jsonb->'checks') c where c->>'check_id'='config.pipeline-url')='1'
 and (select jsonb_array_length(c->'history') from jsonb_array_elements(:'w'::jsonb->'checks') c where c->>'check_id'='config.pipeline-url')=2,'history and counts');
select test.assert((select (c->'latest'->'metrics'->>'find_s')::numeric from jsonb_array_elements(:'w'::jsonb->'checks') c where c->>'check_id'='ingest.not-found')=45,
 'numeric metrics are kept');
select test.reject('select public.v1_admin_workflow_checks(0)','invalid_checks_window');
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject('select public.v1_admin_workflow_checks(14)','owner_mfa_required');
reset role;

-- Snapshot: a paper in a working stage for over 15 minutes is stuck; a shared private_split row
-- with no active import is resting, not stuck. Hosted-only parts are null locally.
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_set_pipeline_enabled(true);
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','24000000-0000-0000-0000-00000000000a',false);
select (public.v2_begin_import('24000000-0000-0000-0000-0000000000a1','2305.18290',0))->'entry'->>'id' as import_id \gset
reset role;
update app_private.pipeline_papers set stage_entered_at=now()-interval '20 minutes' where source_id='2305.18290';
set role service_role;
select public.worker_workflow_snapshot() as s \gset
reset role;
select test.assert(:'s'::jsonb->'pipeline_url'='null'::jsonb and :'s'::jsonb->'worker_calls'='null'::jsonb,'hosted-only parts are null without Vault and pg_net');
select test.assert((:'s'::jsonb->>'pipeline_enabled')::boolean and (:'s'::jsonb->'budget'->>'limit_microusd')::bigint=10000000,'policy and budget');
select test.assert(exists(select 1 from jsonb_array_elements(:'s'::jsonb->'stuck') p where p->>'source'='2305.18290' and p->>'stage'='metadata'
 and (p->>'minutes')::int>=19),'a paper in metadata for 20 minutes is stuck');
select test.assert(:'s'::jsonb->>'stale_imports'='0','a 20-minute import is not stale yet');
-- The import goes away; its shared row rests in private_split.
set role authenticated;
select set_config('request.jwt.claim.sub','24000000-0000-0000-0000-00000000000a',false);
select public.v2_cancel_import('24000000-0000-0000-0000-0000000000a2',:'import_id',1);
reset role;
update app_private.pipeline_papers set stage='private_split',eligible=false where source_id='2305.18290';
update app_private.pipeline_papers set stage_entered_at=now()-interval '2 hours' where source_id='2305.18290';
set role service_role;
select public.worker_workflow_snapshot() as s \gset
reset role;
select test.assert(jsonb_array_length(:'s'::jsonb->'stuck')=0 and (:'s'::jsonb->>'resting_split')::int=1,'a resting shared private_split row is not stuck');
-- Crash-looping is reported even before the 15 minutes pass.
update app_private.pipeline_papers set stage='download',owner_id='24000000-0000-0000-0000-00000000000a' where source_id='2305.18290';
update app_private.pipeline_papers set stage_crashes=2 where source_id='2305.18290';
set role service_role;
select public.worker_workflow_snapshot() as s \gset
reset role;
select test.assert(exists(select 1 from jsonb_array_elements(:'s'::jsonb->'looping') p where p->>'stage'='download' and (p->>'crashes')::int=2),'crash loops are reported');
rollback;
