-- 0161: Model health, each call's time to first output, and the answering model in Your AI usage (2026-10-25; design:
-- docs/architecture/CHAT.md "A fallback when the chosen model fails before writing" and ADMIN_HEALTH.md "Model health").
-- Owner on TestFlight 92: "Speed and reliability seem to be not great for ai provider calls." In the 24 hours before,
-- Gemini 3.8 Flash on its pinned Google Vertex US endpoint answered 8 of 12 calls (three 429s, a stall, a broken stream)
-- and nothing on Health said so; OpenRouter's own inventory had the endpoint at 80 % uptime for the day.
--  1. `first_data_ms` joins the provider units a finished attempt may record (milliseconds from sending to the model's first
--     output; the chat function writes it from this migration on, so it must be applied first). Nothing else changes in
--     the validator.
--  2. `app_private.model_health(hours)`: per OpenRouter model over the window, calls, how many the model answered, failed
--     (by failure code) or were left by the reader, and the p90 time to first output and to the end; with attention items
--     when a model with at least 10 calls answered fewer than 90 % of them, or its p90 time to first output (at least 10
--     timed calls) is over 20 s. Counts, codes and times only. Health (`admin_health_extra.models`) and the workflow
--     check `models.health` (`worker_model_health`, service role) read it.
--  3. Your AI usage names the model that did the work as the first answer call that succeeded (an answer whose chosen
--     model failed before writing and was written by its fallback is the fallback's), else the first answer call, as 0160.
-- Read-only additions; no table, grant or existing row changes.
begin;
set local lock_timeout='15s';

-- 1. As 085, with `first_data_ms`.
create or replace function app_private.valid_provider_units(p_units jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
declare item record;
begin
 if p_units is null or jsonb_typeof(p_units)<>'object' or octet_length(p_units::text)>2048 then return false; end if;
 for item in select key,value from jsonb_each(p_units) loop
  if item.key not in ('input_tokens','output_tokens','cache_write_5m_tokens','cache_write_1h_tokens','cache_read_tokens',
    'web_searches','attempts','credits','searches','pages','estimated','text_input_tokens','audio_output_tokens','audio_ms',
    'cache_storage_tokens','first_data_ms')
   or jsonb_typeof(item.value)<>'number' or item.value::text !~ '^[0-9]{1,12}$' then return false; end if;
 end loop;
 return true;
end $$;

-- 2. Model health. A call the reader left (`aborted`), one refused for the account's balance (`provider_billing`, its own
-- Attention item) and one our own code lost (`transport_unknown`) are not the model's: they are counted apart. Calls not
-- sent (`denied`) or still running (`admitted`) are left out.
create function app_private.model_health(p_hours integer default 24) returns jsonb
language sql stable security definer set search_path='' as $$
 with policy as (select 10 min_calls,0.90::numeric success_rate,20000 p90_first_data_ms,greatest(1,least(coalesce(p_hours,24),720)) hours),
 a as (
  select p.model,p.failure_code,
   case when p.failure_code is null and p.state in ('succeeded','reconciled') then 'answered'
    when p.failure_code in ('aborted','provider_billing','transport_unknown') then 'other' else 'failed' end verdict,
   case when jsonb_typeof(p.actual_units->'first_data_ms')='number' then (p.actual_units->>'first_data_ms')::bigint end first_ms,
   case when p.failure_code is null and p.dispatched_at is not null and p.finished_at is not null
    then (extract(epoch from p.finished_at-p.dispatched_at)*1000)::bigint end total_ms
  from app_private.provider_attempts p cross join policy
  where p.provider='openrouter' and p.created_at>now()-make_interval(hours=>policy.hours) and p.state not in ('denied','admitted')),
 m as (
  select a.model,count(*) filter(where a.verdict<>'other') calls,count(*) filter(where a.verdict='answered') answered,
   count(*) filter(where a.verdict='failed') failed,count(*) filter(where a.verdict='other') other,
   count(a.first_ms) timed,
   percentile_disc(0.9) within group(order by a.first_ms) p90_first_data_ms,
   percentile_disc(0.5) within group(order by a.first_ms) p50_first_data_ms,
   percentile_disc(0.9) within group(order by a.total_ms) p90_ms,
   (select coalesce(jsonb_object_agg(f.code,f.n),'{}'::jsonb) from (select coalesce(b.failure_code,'none') code,count(*) n from a b
     where b.model=a.model and b.verdict<>'answered' group by 1) f) failures
  from a group by a.model),
 r as (
  select m.*,case when m.calls>0 then round(m.answered::numeric/m.calls,4) end rate from m)
 select jsonb_build_object('window_hours',(select hours from policy),
  'thresholds',(select jsonb_build_object('min_calls',min_calls,'success_rate',success_rate,'p90_first_data_ms',p90_first_data_ms) from policy),
  'models',coalesce((select jsonb_agg(jsonb_build_object('model',r.model,'calls',r.calls,'answered',r.answered,'failed',r.failed,
    'other',r.other,'success_rate',r.rate,'timed',r.timed,'p50_first_data_ms',r.p50_first_data_ms,'p90_first_data_ms',r.p90_first_data_ms,
    'p90_ms',r.p90_ms,'failures',r.failures) order by r.calls desc,r.model) from r),'[]'::jsonb),
  'attention',coalesce((select jsonb_agg(x.item order by x.model,x.kind) from (
    select r.model,'success_rate' kind,jsonb_build_object('kind','model_success_rate','model',r.model,'calls',r.calls,'answered',r.answered,
     'success_rate',r.rate,'failures',r.failures) item
    from r cross join policy where r.calls>=policy.min_calls and r.rate<policy.success_rate
    union all
    select r.model,'first_data',jsonb_build_object('kind','model_slow_start','model',r.model,'timed',r.timed,'p90_first_data_ms',r.p90_first_data_ms)
    from r cross join policy where r.timed>=policy.min_calls and r.p90_first_data_ms>policy.p90_first_data_ms) x),'[]'::jsonb))
$$;

create function public.worker_model_health(p_hours integer default 24) returns jsonb
language sql stable security definer set search_path='' as $$ select app_private.model_health(p_hours) $$;

-- Health gains `models` (the extras of 0152, unchanged otherwise).
create or replace function app_private.admin_health_extra() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('tariffs',app_private.openrouter_tariff_attention(),'reconciliation',app_private.openrouter_reconcile_health(),
  'recommendations',app_private.recommendation_health(),'interest_index',app_private.interest_health(),'models',app_private.model_health(24))
$$;

-- 3. As 0160, with the model that did the work chosen among answer calls that succeeded first.
create or replace function app_private.usage_operations(p_account_id uuid,p_since timestamptz)
returns table(id uuid,created_at timestamptz,settled_at timestamptz,kind text,activity text,action text,ending text,outcome text,
 paid_by text,credits bigint,credits_held bigint,model text,calls bigint,input_tokens bigint,cached_tokens bigint,
 cache_write_tokens bigint,output_tokens bigint,searches bigint,audio_ms bigint,estimated boolean,pending boolean,unreported_calls bigint)
language sql stable security definer set search_path='' as $$
 with ops as (
  select o.* from app_private.metered_operations o where o.account_id=p_account_id and o.created_at>=p_since),
 att as (
  select p.operation_id,p.created_at,p.id,p.model,p.route,p.provider,p.state,p.failure_code,p.transport_metadata->>'feature' feature,
   app_private.usage_part(p.route,p.transport_metadata->>'feature') part,r.reported,
   case when r.reported then p.actual_units else '{}'::jsonb end u
  from app_private.provider_attempts p join ops o on o.id=p.operation_id
  cross join lateral (select app_private.usage_reported(p.state,p.actual_units) reported) r
  where p.account_id=p_account_id and p.state<>'denied'),
 per_op as (
  select a.operation_id,count(*) calls,
   sum(coalesce((a.u->>'input_tokens')::bigint,0)+coalesce((a.u->>'text_input_tokens')::bigint,0)) input,
   sum(coalesce((a.u->>'cache_read_tokens')::bigint,0)) cached,
   sum(coalesce((a.u->>'cache_write_5m_tokens')::bigint,0)+coalesce((a.u->>'cache_write_1h_tokens')::bigint,0)) cache_write,
   sum(coalesce((a.u->>'output_tokens')::bigint,0)+coalesce((a.u->>'audio_output_tokens')::bigint,0)) output,
   sum(case when a.provider='tavily' then coalesce((a.u->>'searches')::bigint,0) else 0 end) searches,
   sum(coalesce((a.u->>'audio_ms')::bigint,0)) audio,
   count(*) filter(where not a.reported) unreported,bool_or(a.state in ('admitted','unknown')) pending,
   array_agg(distinct a.feature) filter(where a.feature is not null) features,array_agg(distinct a.route) routes,
   -- The model that did the work: the first answer call that succeeded (0161: a fallback that wrote the answer, not the
   -- chosen model that failed before it), else the first answer call, else the first call that is not a search, else the first.
   (array_agg(a.model order by a.part<>'answer',a.part='web_search',
     not (a.state in ('succeeded','reconciled') and a.failure_code is null),a.created_at,a.id))[1] model
  from att a group by a.operation_id)
 select o.id,o.created_at,o.settled_at,o.kind,
  app_private.usage_activity(o.kind,e.action,coalesce(s.features,'{}'),coalesce(s.routes,'{}')) activity,
  e.action,e.ending,
  case when o.state in ('reserved','submitted') then 'in_progress'
   when o.state='uncertain' then 'checking'
   when e.ending='completed' then 'completed'
   when e.ending in ('stopped','left') then 'stopped'
   when e.ending is not null then 'failed'
   when coalesce(o.actual_credits,0)>0 then 'completed'
   when o.credit_ceiling=0 then 'free'
   else 'not_charged' end outcome,
  case when o.credit_ceiling=0 and coalesce(o.actual_credits,0)=0 then 'gradstep' else 'you' end paid_by,
  case when o.state='settled' then o.actual_credits else null end credits,
  case when o.state<>'settled' then o.credit_ceiling else 0 end credits_held,
  s.model,coalesce(s.calls,0),coalesce(s.input,0),coalesce(s.cached,0),coalesce(s.cache_write,0),coalesce(s.output,0),
  coalesce(s.searches,0),coalesce(s.audio,0),coalesce(s.unreported,0)>0,coalesce(s.pending,false),coalesce(s.unreported,0)
 from ops o left join per_op s on s.operation_id=o.id
 left join app_private.chat_endings e on e.account_id=o.account_id and e.operation_id=o.id
 where not (o.state='settled' and o.credit_ceiling=0 and coalesce(o.actual_credits,0)=0 and coalesce(s.calls,0)=0)
$$;

revoke all on function app_private.model_health(integer) from public,anon,authenticated;
revoke all on function public.worker_model_health(integer) from public,anon,authenticated,service_role;
grant execute on function public.worker_model_health(integer) to service_role;
revoke all on function app_private.admin_health_extra() from public,anon,authenticated;
revoke all on function app_private.usage_operations(uuid,timestamptz) from public,anon,authenticated;

notify pgrst,'reload schema';
commit;
