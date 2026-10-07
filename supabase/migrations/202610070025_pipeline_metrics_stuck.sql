-- Reliability metrics: "stuck now" excludes shared papers parked in private_split by
-- design (their private copies carry on per account). Found by the workflow checks.
begin;
set local lock_timeout='15s';

create or replace function public.v1_admin_pipeline_metrics(p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare since timestamptz;
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_days is null or p_days not between 1 and 180 then raise exception 'invalid_metrics_window'; end if;
 since:=date_trunc('day',now())-make_interval(days=>p_days-1);
 return jsonb_build_object('since',since,'generated_at',now(),
  -- Exact over the whole window (the admin headline), not combined from daily values.
  'summary',(select jsonb_build_object('started',count(*) filter (where phase='accepted'),'ready',count(*) filter (where phase='ready'),
     'failed',count(*) filter (where phase in ('failed','membership_conflict')),'cancelled',count(*) filter (where phase='cancelled'),
     'ready_p50_s',round((percentile_cont(0.5) within group (order by duration_ms) filter (where phase='ready'))::numeric/1000,1),
     'ready_p90_s',round((percentile_cont(0.9) within group (order by duration_ms) filter (where phase='ready'))::numeric/1000,1))
    from app_private.pipeline_events where kind='import' and at>=since),
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
    where stage not in ('done','failed','source_only','needs_credits') and stage_entered_at<now()-interval '15 minutes'
     -- A shared paper whose license requires private copies stays in private_split by design.
     and not (stage='private_split' and owner_id is null)) x));
end $$;

revoke all on function public.v1_admin_pipeline_metrics(integer) from public,anon;
grant execute on function public.v1_admin_pipeline_metrics(integer) to authenticated;
notify pgrst,'reload schema';
commit;
