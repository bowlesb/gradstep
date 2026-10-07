-- Workflow checks (owner, 2026-10-07: "we need better integration tests ... if they don't work,
-- users will abandon immediately ... it needs to be bulletproof"). Design:
-- docs/architecture/WORKFLOW_CHECKS.md. Additive.
--
-- 1. Runs of scripts/workflow-checks.mjs (after deploys and on a schedule) are recorded, one row
--    per check, for the admin Reliability tab: last run per suite, pass/fail per check, history.
--    Rows hold check IDs, statuses, short reasons, timings, costs and numeric metrics only: no
--    account IDs, user content or secrets (the runner redacts before sending). 180-day retention.
-- 2. worker_workflow_snapshot(): the single read the runner's configuration and stuck-import
--    checks need, for the service role, so a scheduled job needs no Management API token.
begin;
set local lock_timeout='15s';

create table app_private.workflow_check_runs (
 id uuid primary key,
 suite text not null check(suite in ('deploy','daily','weekly','custom')),
 trigger text not null check(trigger ~ '^[a-z][a-z0-9-]{0,39}$'),
 git_commit text check(git_commit ~ '^[0-9a-f]{7,40}$'),
 started_at timestamptz not null,
 finished_at timestamptz not null,
 passed integer not null check(passed>=0),
 failed integer not null check(failed>=0),
 warned integer not null check(warned>=0),
 skipped integer not null check(skipped>=0),
 cost_microusd bigint not null check(cost_microusd between 0 and 100000000),
 request_sha256 bytea not null check(octet_length(request_sha256)=32),
 recorded_at timestamptz not null default now(),
 check(finished_at>=started_at and finished_at<started_at+interval '1 day')
);
create index workflow_check_runs_started on app_private.workflow_check_runs(started_at);
create table app_private.workflow_check_results (
 run_id uuid not null references app_private.workflow_check_runs(id) on delete cascade,
 check_id text not null check(length(check_id)<=64 and check_id ~ '^[a-z][a-z0-9-]*(\.[a-z0-9-]+)*$'),
 status text not null check(status in ('pass','fail','warn','skip')),
 reason text not null check(length(reason)<=500),
 duration_ms integer not null check(duration_ms between 0 and 86400000),
 cost_microusd bigint not null default 0 check(cost_microusd between 0 and 100000000),
 metrics jsonb not null default '{}' check(jsonb_typeof(metrics)='object' and octet_length(metrics::text)<=2000),
 primary key(run_id,check_id)
);
create index workflow_check_results_check on app_private.workflow_check_results(check_id);
alter table app_private.workflow_check_runs enable row level security;
alter table app_private.workflow_check_results enable row level security;
revoke all on app_private.workflow_check_runs,app_private.workflow_check_results from public,anon,authenticated;

-- Records one run atomically. Replaying the same run is a no-op; a different body under the
-- same run ID is refused. Bounded: at most 200 checks and 128 KiB per run.
create function public.worker_record_workflow_check_run(p_run jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_id uuid; digest bytea; existing bytea;
begin
 if p_run is null or jsonb_typeof(p_run)<>'object' or octet_length(p_run::text)>131072
  or jsonb_typeof(p_run->'results')<>'array' or jsonb_array_length(p_run->'results') not between 1 and 200
 then raise exception 'invalid_workflow_run'; end if;
 begin v_id:=(p_run->>'id')::uuid; exception when others then raise exception 'invalid_workflow_run'; end;
 if v_id is null then raise exception 'invalid_workflow_run'; end if;
 -- jsonb text output is canonical (keys sorted), so equal bodies have equal digests.
 digest:=sha256(convert_to(p_run::text,'UTF8'));
 perform pg_advisory_xact_lock(hashtextextended('workflow_check_run:'||v_id::text,0));
 select request_sha256 into existing from app_private.workflow_check_runs where id=v_id;
 if found then
  if existing<>digest then raise exception 'workflow_run_conflict'; end if;
  return jsonb_build_object('id',v_id,'replayed',true);
 end if;
 if exists(select 1 from jsonb_array_elements(p_run->'results') r where jsonb_typeof(r)<>'object'
   or (r ? 'metrics' and (jsonb_typeof(r->'metrics')<>'object'
    or exists(select 1 from jsonb_each(r->'metrics') m where jsonb_typeof(m.value)<>'number'))))
 then raise exception 'invalid_workflow_run'; end if;
 begin
  insert into app_private.workflow_check_runs(id,suite,trigger,git_commit,started_at,finished_at,passed,failed,warned,skipped,cost_microusd,request_sha256)
  select v_id,p_run->>'suite',p_run->>'trigger',nullif(p_run->>'git_commit',''),(p_run->>'started_at')::timestamptz,(p_run->>'finished_at')::timestamptz,
   count(*) filter (where r->>'status'='pass'),count(*) filter (where r->>'status'='fail'),
   count(*) filter (where r->>'status'='warn'),count(*) filter (where r->>'status'='skip'),
   coalesce((p_run->>'cost_microusd')::bigint,0),digest
  from jsonb_array_elements(p_run->'results') r;
  insert into app_private.workflow_check_results(run_id,check_id,status,reason,duration_ms,cost_microusd,metrics)
  select v_id,r->>'check_id',r->>'status',coalesce(r->>'reason',''),coalesce((r->>'duration_ms')::integer,0),
   coalesce((r->>'cost_microusd')::bigint,0),coalesce(r->'metrics','{}')
  from jsonb_array_elements(p_run->'results') r;
 exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range
  or check_violation or not_null_violation or unique_violation or invalid_parameter_value then
  raise exception 'invalid_workflow_run';
 end;
 delete from app_private.workflow_check_runs where id in
  (select id from app_private.workflow_check_runs where started_at<now()-interval '180 days' order by started_at limit 100);
 return jsonb_build_object('id',v_id,'replayed',false);
end $$;

-- Owner-only (MFA) read for the admin Reliability tab: the last run per suite, recent runs,
-- and per check its latest result, recent history and counts in the window.
create function public.v1_admin_workflow_checks(p_days integer default 14) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare since timestamptz;
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_days is null or p_days not between 1 and 180 then raise exception 'invalid_checks_window'; end if;
 since:=now()-make_interval(days=>p_days);
 return jsonb_build_object('generated_at',now(),'since',since,
  'last_runs',(select coalesce(jsonb_object_agg(suite,r),'{}'::jsonb) from (
    select distinct on (suite) suite,jsonb_build_object('id',id,'trigger',trigger,'git_commit',git_commit,'started_at',started_at,
     'finished_at',finished_at,'passed',passed,'failed',failed,'warned',warned,'skipped',skipped,'cost_microusd',cost_microusd) r
    from app_private.workflow_check_runs order by suite,started_at desc) x),
  'runs',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'suite',suite,'trigger',trigger,'git_commit',git_commit,
     'started_at',started_at,'finished_at',finished_at,'passed',passed,'failed',failed,'warned',warned,'skipped',skipped,
     'cost_microusd',cost_microusd) order by started_at desc),'[]'::jsonb)
    from (select * from app_private.workflow_check_runs where started_at>=since order by started_at desc limit 50) x),
  'checks',(select coalesce(jsonb_agg(c order by c->>'check_id'),'[]'::jsonb) from (
    select jsonb_build_object('check_id',k.check_id,
     'latest',(select jsonb_build_object('status',res.status,'reason',res.reason,'at',run.started_at,'suite',run.suite,'run_id',run.id,
        'duration_ms',res.duration_ms,'cost_microusd',res.cost_microusd,'metrics',res.metrics)
       from app_private.workflow_check_results res join app_private.workflow_check_runs run on run.id=res.run_id
       where res.check_id=k.check_id order by run.started_at desc limit 1),
     'history',(select coalesce(jsonb_agg(jsonb_build_object('at',h.started_at,'status',h.status,'suite',h.suite) order by h.started_at),'[]'::jsonb)
       from (select run.started_at,res.status,run.suite from app_private.workflow_check_results res
        join app_private.workflow_check_runs run on run.id=res.run_id
        where res.check_id=k.check_id and run.started_at>=since order by run.started_at desc limit 30) h),
     'counts',(select jsonb_build_object('pass',count(*) filter (where res.status='pass'),'fail',count(*) filter (where res.status='fail'),
        'warn',count(*) filter (where res.status='warn'),'skip',count(*) filter (where res.status='skip'))
       from app_private.workflow_check_results res join app_private.workflow_check_runs run on run.id=res.run_id
       where res.check_id=k.check_id and run.started_at>=since)) c
    from (select distinct res.check_id from app_private.workflow_check_results res
     join app_private.workflow_check_runs run on run.id=res.run_id where run.started_at>=since) k) x));
end $$;

-- The runner's configuration and stuck-import read (scripts/workflow-checks.mjs SNAPSHOT_SQL is
-- the same query for runs before this migration). Vault, pg_cron and pg_net exist only hosted.
-- "Stuck" leaves out shared private_split rows with no active import: they only dispatch
-- private copies and rest in that stage (v1_admin_pipeline_metrics still lists them).
create function public.worker_workflow_snapshot() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare url text; secret_digest text; cron_state jsonb; calls jsonb;
begin
 if to_regnamespace('vault') is not null then
  execute $q$select (select decrypted_secret from vault.decrypted_secrets where name='science_reader_pipeline_url'),
   (select encode(sha256(convert_to(decrypted_secret,'UTF8')),'hex') from vault.decrypted_secrets where name='science_reader_pipeline_secret')$q$
   into url,secret_digest;
 end if;
 if to_regclass('cron.job') is not null then
  execute $q$select jsonb_build_object('active',active,'schedule',schedule) from cron.job where jobname='science-reader-pipeline'$q$ into cron_state;
 end if;
 if to_regclass('net._http_response') is not null then
  execute $q$select jsonb_build_object('ok',count(*) filter (where status_code between 200 and 299),
   'unauthorized',count(*) filter (where status_code in (401,403)),'missing',count(*) filter (where status_code=404),
   'server',count(*) filter (where status_code>=500),'timed_out',count(*) filter (where timed_out),
   'last_ok',max(created) filter (where status_code between 200 and 299)) from net._http_response where created>now()-interval '15 minutes'$q$ into calls;
 end if;
 return (with resting as (
   select pp.id from app_private.pipeline_papers pp where pp.owner_id is null and pp.stage='private_split'
    and not exists(select 1 from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
     where pi.paper_id=pp.id and i.desired_present and i.phase in ('accepted','resolving','acquiring'))),
  working as (select pp.* from app_private.pipeline_papers pp where pp.stage not in ('done','failed','source_only','needs_credits')
   and pp.id not in (select id from resting))
  select jsonb_build_object(
   'pipeline_url',url,'pipeline_secret_sha256',secret_digest,'cron',cron_state,'worker_calls',calls,
   'pipeline_enabled',(select enabled from app_private.pipeline_policy),
   'budget',(select jsonb_build_object('work_enabled',work_enabled,'limit_microusd',limit_microusd,'spent_microusd',spent_microusd,'reserved_microusd',reserved_microusd)
     from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),
   'stuck',(select coalesce(jsonb_agg(jsonb_build_object('source',source_id,'private',owner_id is not null,'stage',stage,
     'minutes',floor(extract(epoch from (now()-stage_entered_at))/60),'claims',stage_claims,'crashes',stage_crashes) order by stage_entered_at),'[]'::jsonb)
     from working where stage_entered_at<now()-interval '15 minutes'),
   'looping',(select coalesce(jsonb_agg(jsonb_build_object('source',source_id,'stage',stage,'claims',stage_claims,'crashes',stage_crashes)),'[]'::jsonb)
     from working where stage_crashes>=2 or (stage<>'ocr_wait' and stage_claims>=30)),
   'resting_split',(select count(*) from resting),
   'uncertain_ocr',(select count(*) from app_private.ocr_attempts where state='uncertain'),
   'stale_imports',(select count(*) from app_private.import_requests where desired_present and phase in ('accepted','resolving','acquiring')
     and created_at<now()-interval '60 minutes'),
   'crashes_24h',(select coalesce(jsonb_object_agg(stage,n),'{}'::jsonb) from (select stage,count(*) n from app_private.pipeline_events
     where kind='crash' and at>now()-interval '24 hours' group by stage) c),
   'import_failures_24h',(select coalesce(jsonb_object_agg(cause,n),'{}'::jsonb) from (select coalesce(error_code,'unknown') cause,count(*) n
     from app_private.pipeline_events where kind='import' and phase='failed' and at>now()-interval '24 hours' group by 1) f)));
end $$;

revoke all on function public.worker_record_workflow_check_run(jsonb),public.worker_workflow_snapshot() from public,anon,authenticated;
grant execute on function public.worker_record_workflow_check_run(jsonb),public.worker_workflow_snapshot() to service_role;
revoke all on function public.v1_admin_workflow_checks(integer) from public,anon;
grant execute on function public.v1_admin_workflow_checks(integer) to authenticated;
notify pgrst,'reload schema';
commit;
