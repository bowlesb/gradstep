-- Import reliability (owner, 2026-10-06: adding a PDF must be bulletproof and measured).
-- Design: docs/architecture/PIPELINE_RELIABILITY.md. Additive over 014/016/019.
--
-- 1. Loop breaker: a lease that expires while still claimed means the worker died
--    (normal exits release the claim). Expired claims are swept before each claim:
--    the stage's crash count rises, the paper backs off (2, 4, 8 … ≤ 30 min), and the
--    third crash in a stage without provider work fails it with a retryable error.
-- 2. Telemetry: append-only pipeline_events (stage exits, crashes, import phases)
--    and an owner-only metrics read for the admin Reliability tab.
begin;
set local lock_timeout='15s';

alter table app_private.pipeline_papers
 add column stage_entered_at timestamptz not null default now(),
 add column stage_claims integer not null default 0 check(stage_claims>=0),
 add column stage_crashes integer not null default 0 check(stage_crashes>=0);

-- No account IDs: aggregates only; import_id/paper_id are opaque.
create table app_private.pipeline_events (
 id bigint generated always as identity primary key,
 at timestamptz not null default clock_timestamp(),
 kind text not null check(kind in ('stage','crash','import')),
 paper_id uuid,
 import_id uuid,
 source_id text check(source_id is null or length(source_id)<=200),
 private boolean,
 stage text,
 next_stage text,
 phase text,
 error_code text,
 duration_ms bigint check(duration_ms is null or duration_ms>=0),
 claims integer
);
create index pipeline_events_at on app_private.pipeline_events(at);
create index pipeline_events_kind_at on app_private.pipeline_events(kind,at);
alter table app_private.pipeline_events enable row level security;
revoke all on app_private.pipeline_events from public,anon,authenticated;

-- A paper leaving a stage: record it and reset the per-stage counters.
create function app_private.pipeline_stage_event() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into app_private.pipeline_events(kind,paper_id,source_id,private,stage,next_stage,error_code,duration_ms,claims)
 values('stage',old.id,old.source_id,old.owner_id is not null,old.stage,new.stage,new.error_code,
  greatest(0,floor(extract(epoch from (clock_timestamp()-old.stage_entered_at))*1000))::bigint,old.stage_claims);
 new.stage_entered_at:=clock_timestamp(); new.stage_claims:=0; new.stage_crashes:=0;
 return new;
end $$;
create trigger pipeline_stage_event before update on app_private.pipeline_papers
 for each row when (old.stage is distinct from new.stage) execute function app_private.pipeline_stage_event();

-- An import changing phase (including creation): time since it was requested.
create function app_private.import_phase_event() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' or old.phase is distinct from new.phase then
  insert into app_private.pipeline_events(kind,import_id,source_id,phase,error_code,duration_ms)
  values('import',new.id,left(new.source_id,200),new.phase,new.error_code,
   greatest(0,floor(extract(epoch from (clock_timestamp()-new.created_at))*1000))::bigint);
 end if;
 return null;
end $$;
create trigger import_phase_event after insert or update of phase on app_private.import_requests
 for each row execute function app_private.import_phase_event();

-- Expired claims (the worker died): record, back off, and fail after three in a
-- stage that holds no provider work. Provider stages (OCR) only back off.
create function app_private.pipeline_sweep_crashes() returns integer language plpgsql security definer set search_path='' as $$
declare r record; n integer:=0;
begin
 for r in select pp.id,pp.stage,pp.stage_crashes,pp.stage_claims,pp.source_id,pp.owner_id from app_private.pipeline_papers pp
  where pp.claim_id is not null and pp.lease_until<=clock_timestamp() order by pp.lease_until limit 20 for no key update skip locked loop
  insert into app_private.pipeline_events(kind,paper_id,source_id,private,stage,claims)
  values('crash',r.id,r.source_id,r.owner_id is not null,r.stage,r.stage_claims);
  update app_private.pipeline_papers set claim_id=null,lease_until=null,stage_crashes=stage_crashes+1,
   next_attempt_at=clock_timestamp()+make_interval(mins=>least(30,power(2,r.stage_crashes+1)::integer)),updated_at=now()
   where id=r.id;
  if r.stage in ('metadata','private_split','download','render') and r.stage_crashes+1>=3 then
   perform app_private.pipeline_set_stage(r.id,'failed',
    case r.stage when 'metadata' then 'metadata_unavailable' when 'render' then 'conversion_failed' else 'download_failed' end,r.stage);
  end if;
  n:=n+1;
 end loop;
 delete from app_private.pipeline_events where id in
  (select id from app_private.pipeline_events where at<now()-interval '180 days' order by at limit 200);
 return n;
end $$;

-- 014's claim, preceded by the crash sweep and counting claims per stage.
create or replace function public.worker_pipeline_claim(p_claim_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare pol app_private.pipeline_policy; p app_private.pipeline_papers; retries integer;
begin
 if p_claim_id is null then raise exception 'invalid_claim'; end if;
 select * into strict pol from app_private.pipeline_policy;
 if not pol.enabled then return null; end if;
 perform app_private.pipeline_sweep_crashes();
 select pp.* into p from app_private.pipeline_papers pp
 where (pp.lease_until is null or pp.lease_until<=clock_timestamp()) and (
  -- Paid/provider stages continue regardless of interest.
  (pp.stage in ('ocr_submit','ocr_wait','render') and pp.next_attempt_at<=clock_timestamp())
  or (pp.stage in ('metadata','private_split','download','ocr_fund') and pp.next_attempt_at<=clock_timestamp() and app_private.pipeline_interest(pp.id))
  or exists(select 1 from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
   where pi.paper_id=pp.id and i.desired_present and i.phase in ('accepted','resolving','acquiring')
   and (pi.retry_requested or (pi.synced_revision<pp.state_revision and pi.next_sync_at<=clock_timestamp()))))
 order by pp.next_attempt_at,pp.id limit 1 for no key update skip locked;
 if not found then return null; end if;
 update app_private.pipeline_imports set retry_requested=false where paper_id=p.id and retry_requested;
 get diagnostics retries=row_count;
 if retries>0 and p.stage in ('failed','needs_credits') and p.resume_stage is not null then
  perform app_private.pipeline_set_stage(p.id,p.resume_stage);
 end if;
 update app_private.pipeline_papers set generation=generation+1,claim_id=p_claim_id,stage_claims=stage_claims+1,
  lease_until=clock_timestamp()+make_interval(secs=>pol.lease_seconds),updated_at=now() where id=p.id returning * into p;
 return app_private.pipeline_entry(p);
end $$;

-- Owner-only reliability metrics for the admin Reliability tab.
create function public.v1_admin_pipeline_metrics(p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare since timestamptz;
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_days is null or p_days not between 1 and 180 then raise exception 'invalid_metrics_window'; end if;
 since:=date_trunc('day',now())-make_interval(days=>p_days-1);
 return jsonb_build_object('since',since,'generated_at',now(),
  'daily',(select coalesce(jsonb_agg(d order by d->>'day'),'[]'::jsonb) from (
    select jsonb_build_object('day',day::date,
     'started',count(*) filter (where phase='accepted'),
     'ready',count(*) filter (where phase='ready'),
     'failed',count(*) filter (where phase in ('failed','membership_conflict')),
     'cancelled',count(*) filter (where phase='cancelled'),
     'ready_p50_s',round((percentile_cont(0.5) within group (order by duration_ms) filter (where phase='ready'))::numeric/1000,1),
     'ready_p90_s',round((percentile_cont(0.9) within group (order by duration_ms) filter (where phase='ready'))::numeric/1000,1)) d
    from (select date_trunc('day',at) as day,phase,duration_ms from app_private.pipeline_events where kind='import' and at>=since) e group by day) x),
  'stages',(select coalesce(jsonb_agg(s order by s->>'stage'),'[]'::jsonb) from (
    select jsonb_build_object('stage',stage,'count',count(*),
     'p50_s',round((percentile_cont(0.5) within group (order by duration_ms))::numeric/1000,1),
     'p90_s',round((percentile_cont(0.9) within group (order by duration_ms))::numeric/1000,1),
     'failed',count(*) filter (where next_stage='failed')) s
    from app_private.pipeline_events where kind='stage' and at>=since group by stage) x),
  'crashes',(select coalesce(jsonb_object_agg(stage,n),'{}'::jsonb) from
    (select stage,count(*) n from app_private.pipeline_events where kind='crash' and at>=since group by stage) c),
  'failure_causes',(select coalesce(jsonb_object_agg(cause,n),'{}'::jsonb) from
    (select coalesce(error_code,'unknown') cause,count(*) n from app_private.pipeline_events
     where kind='import' and phase='failed' and at>=since group by 1) f),
  'recent_failures',(select coalesce(jsonb_agg(r order by r->>'at' desc),'[]'::jsonb) from (
    select jsonb_build_object('at',at,'kind',kind,'source',source_id,'stage',coalesce(stage,phase),'error_code',error_code,'private',private) r
    from app_private.pipeline_events where at>=since and (kind='crash' or (kind='import' and phase='failed') or (kind='stage' and next_stage='failed'))
    order by at desc limit 25) x),
  'stuck',(select coalesce(jsonb_agg(s order by s->>'since'),'[]'::jsonb) from (
    select jsonb_build_object('id',id,'source',source_id||coalesce('v'||revision,''),'private',owner_id is not null,'stage',stage,
     'since',stage_entered_at,'minutes',floor(extract(epoch from (now()-stage_entered_at))/60),'claims',stage_claims,'crashes',stage_crashes,
     'leased',lease_until>clock_timestamp()) s
    from app_private.pipeline_papers
    where stage not in ('done','failed','source_only','needs_credits') and stage_entered_at<now()-interval '15 minutes') x));
end $$;

revoke all on function app_private.pipeline_stage_event(),app_private.import_phase_event(),app_private.pipeline_sweep_crashes()
 from public,anon,authenticated,service_role;
revoke all on function public.worker_pipeline_claim(uuid) from public,anon,authenticated;
grant execute on function public.worker_pipeline_claim(uuid) to service_role;
revoke all on function public.v1_admin_pipeline_metrics(integer) from public,anon;
grant execute on function public.v1_admin_pipeline_metrics(integer) to authenticated;
notify pgrst,'reload schema';
commit;
