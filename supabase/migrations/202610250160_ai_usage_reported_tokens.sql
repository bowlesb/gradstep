-- 0160: Your AI usage counts only the tokens a provider reported (coordinator, 2026-10-25, from the TestFlight 92 latency
-- investigation: a failed Explain in Chat question read "132k in · 10k out", and the Week and Month token totals added
-- such rows in). Design: docs/architecture/OPERATIONS_AND_BILLING.md "Your AI usage".
-- 0144 summed every attempt's `actual_units`. An attempt the provider never reported on keeps there what was set aside for
-- it, not what it used: chat's `unknown` attempts (stream lost or stalled, no generation record, migration 089) carry their
-- hold estimate — every input byte as a token and the whole output allowance — without the `estimated` mark; `admitted`
-- attempts are still running; and units marked `estimated` are Gradstep's estimate. Now an attempt's units count only when
-- they are the provider's own: `succeeded`, `rejected` before processing (exactly zero) or `reconciled` from the provider's
-- record, and not marked estimated. Everything else adds nothing to a row's, a part's or the window's tokens, searches or
-- audio, and is flagged: `estimated` is true when any of the row's (or part's) calls has no provider count, and the new
-- `unreported_calls` says how many; the totals gain `unreported_operations`. Same signature, same keys with the same
-- types (TestFlight 92 and the browser require every token field as a number), two fields added. Credits, holds, outcomes,
-- activities, charging and the ledger are unchanged. Read only, as 0144.
begin;
set local lock_timeout='15s';

-- Whether an attempt's units are the provider's own count.
create function app_private.usage_reported(p_state text,p_units jsonb) returns boolean
language sql immutable set search_path='' as $$
 select coalesce(p_state in ('succeeded','rejected','reconciled') and coalesce((p_units->>'estimated')::bigint,0)=0,false)
$$;

-- As 0144, with units counted only when reported, and the row's unreported calls (a new last column).
drop function app_private.usage_operations(uuid,timestamptz);
create function app_private.usage_operations(p_account_id uuid,p_since timestamptz)
returns table(id uuid,created_at timestamptz,settled_at timestamptz,kind text,activity text,action text,ending text,outcome text,
 paid_by text,credits bigint,credits_held bigint,model text,calls bigint,input_tokens bigint,cached_tokens bigint,
 cache_write_tokens bigint,output_tokens bigint,searches bigint,audio_ms bigint,estimated boolean,pending boolean,unreported_calls bigint)
language sql stable security definer set search_path='' as $$
 with ops as (
  select o.* from app_private.metered_operations o where o.account_id=p_account_id and o.created_at>=p_since),
 att as (
  select p.operation_id,p.created_at,p.id,p.model,p.route,p.provider,p.state,p.transport_metadata->>'feature' feature,
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
   -- The model that did the work: the first answer call, else the first call that is not a search, else the first.
   (array_agg(a.model order by a.part<>'answer',a.part='web_search',a.created_at,a.id))[1] model
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

-- As 0144, with units counted only when reported, and each part's unreported calls.
create or replace function app_private.usage_parts(p_account_id uuid,p_operation_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('part',x.part,'model',x.model,'calls',x.calls,'input_tokens',x.input,'cached_tokens',x.cached,
   'cache_write_tokens',x.cache_write,'output_tokens',x.output,'searches',x.searches,'audio_ms',x.audio,'estimated',x.unreported>0,
   'pending',x.pending,'unreported_calls',x.unreported) order by x.first_at,x.part,x.model),'[]'::jsonb)
 from (
  select a.part,a.model,count(*) calls,min(a.created_at) first_at,
   sum(coalesce((a.u->>'input_tokens')::bigint,0)+coalesce((a.u->>'text_input_tokens')::bigint,0)) input,
   sum(coalesce((a.u->>'cache_read_tokens')::bigint,0)) cached,
   sum(coalesce((a.u->>'cache_write_5m_tokens')::bigint,0)+coalesce((a.u->>'cache_write_1h_tokens')::bigint,0)) cache_write,
   sum(coalesce((a.u->>'output_tokens')::bigint,0)+coalesce((a.u->>'audio_output_tokens')::bigint,0)) output,
   sum(case when a.provider='tavily' then coalesce((a.u->>'searches')::bigint,0) else 0 end) searches,
   sum(coalesce((a.u->>'audio_ms')::bigint,0)) audio,
   count(*) filter(where not a.reported) unreported,bool_or(a.state in ('admitted','unknown')) pending
  from (
   select app_private.usage_part(p.route,p.transport_metadata->>'feature') part,p.model,p.created_at,p.provider,p.state,r.reported,
    case when r.reported then p.actual_units else '{}'::jsonb end u
   from app_private.provider_attempts p
   cross join lateral (select app_private.usage_reported(p.state,p.actual_units) reported) r
   where p.account_id=p_account_id and p.operation_id=p_operation_id and p.state<>'denied') a
  group by 1,2) x
$$;

-- As 0144, with each row's `unreported_calls` and the totals' `unreported_operations`.
create or replace function public.v1_ai_usage(p_days integer default 30,p_activity text default null,
 p_before_created_at timestamptz default null,p_before_id uuid default null,p_limit integer default 25) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); since timestamptz; rows jsonb; more boolean; last_row jsonb; totals jsonb:=null; activities jsonb:=null;
begin
 if p_days is null or p_days not between 1 and 366 or p_limit is null or p_limit not between 1 and 50
  or (p_before_created_at is null) is distinct from (p_before_id is null)
  or (p_activity is not null and p_activity not in ('chat','figure_explainer','equation_explainer','study','related_papers','why_it_matters',
   'add_paper','diagram_repair','podcast','recommendations','tags','paper_lookup','web_search','paper_ocr','diagram','other'))
 then raise exception 'invalid_usage_query'; end if;
 perform public.worker_consume_request(a,'account-usage');
 since:=(date_trunc('day',now() at time zone 'UTC') at time zone 'UTC')-make_interval(days=>p_days-1);
 with w as materialized (select * from app_private.usage_operations(a,since)),
 page as (
  select u.*,row_number() over(order by u.created_at desc,u.id desc) n from w u
  where (p_activity is null or u.activity=p_activity)
   and (p_before_created_at is null or (u.created_at,u.id)<(p_before_created_at,p_before_id))
  order by u.created_at desc,u.id desc limit p_limit+1)
 select
  (select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'created_at',p.created_at,'settled_at',p.settled_at,'kind',p.kind,
    'activity',p.activity,'action',p.action,'ending',p.ending,'outcome',p.outcome,'paid_by',p.paid_by,'credits',p.credits,
    'credits_held',p.credits_held,'model',p.model,'calls',p.calls,'input_tokens',p.input_tokens,'cached_tokens',p.cached_tokens,
    'cache_write_tokens',p.cache_write_tokens,'output_tokens',p.output_tokens,'searches',p.searches,'audio_ms',p.audio_ms,
    'estimated',p.estimated,'pending',p.pending,'unreported_calls',p.unreported_calls,'parts',app_private.usage_parts(a,p.id))
   order by p.created_at desc,p.id desc) filter(where p.n<=p_limit),'[]'::jsonb) from page p),
  (select coalesce(bool_or(p.n>p_limit),false) from page p),
  case when p_before_created_at is null then
   (select jsonb_build_object('operations',count(*),'credits',coalesce(sum(u.credits),0),'credits_held',coalesce(sum(u.credits_held),0),
     'input_tokens',coalesce(sum(u.input_tokens),0),'cached_tokens',coalesce(sum(u.cached_tokens),0),
     'cache_write_tokens',coalesce(sum(u.cache_write_tokens),0),'output_tokens',coalesce(sum(u.output_tokens),0),
     'searches',coalesce(sum(u.searches),0),'audio_ms',coalesce(sum(u.audio_ms),0),
     'unreported_operations',count(*) filter(where u.unreported_calls>0))
    from w u where p_activity is null or u.activity=p_activity) end,
  case when p_before_created_at is null then
   (select coalesce(jsonb_agg(jsonb_build_object('activity',x.activity,'operations',x.n,'credits',x.credits)
     order by x.credits desc,x.n desc,x.activity),'[]'::jsonb)
    from (select u.activity,count(*) n,coalesce(sum(u.credits),0) credits from w u group by u.activity) x) end
 into rows,more,totals,activities;
 if more then last_row:=rows->(jsonb_array_length(rows)-1); end if;
 return jsonb_build_object('generated_at',now(),'since',since,'days',p_days,'activity',p_activity,'limit',p_limit,
  'operations',rows,'totals',totals,'activities',activities,
  'next',case when more then jsonb_build_object('created_at',last_row->>'created_at','id',last_row->>'id') else null end);
end $$;

revoke all on function app_private.usage_reported(text,jsonb) from public,anon,authenticated;
revoke all on function app_private.usage_operations(uuid,timestamptz) from public,anon,authenticated;
revoke all on function app_private.usage_parts(uuid,uuid) from public,anon,authenticated;
revoke all on function public.v1_ai_usage(integer,text,timestamptz,uuid,integer) from public,anon;
grant execute on function public.v1_ai_usage(integer,text,timestamptz,uuid,integer) to authenticated;

notify pgrst,'reload schema';
commit;
