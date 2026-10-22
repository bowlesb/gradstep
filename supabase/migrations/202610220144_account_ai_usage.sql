-- 0144: Your AI usage (owner, 2026-10-22: "a table of my recent AI token spend for all the different activities … rows
-- ordered by time, each row being an activity, and the exact cost, so that a user can figure out where their credits are
-- going"; design: docs/architecture/OPERATIONS_AND_BILLING.md "Your AI usage").
-- A signed-in reader's own metered operations, newest first, one row per operation: when, the activity it served, how it
-- ended, the credits charged (or held while it runs), the models that answered and the tokens, searches and audio the
-- provider reported for it, with each part (answer, title, suggestions, study map, web search, podcast script, review,
-- audio, tags) beside it. Built only from the existing ledger: metered_operations (credits), provider_attempts (model,
-- route, the feature recorded at dispatch, units) and chat_endings (the chat action and how it ended).
-- The caller's own account only: the account is the authenticated actor, never a parameter. No prompt, answer, title,
-- paper, provider request id or cost in dollars leaves the database: credits are the product's unit (DECISIONS.md "In-app
-- credits do not equal dollars"); the device adds paper titles from its own library. Read only: no table changes, one
-- new rate rule. Keyset paging on (created_at, id) with totals for the whole selected window on the first page.
begin;
set local lock_timeout='15s';

insert into app_private.api_rate_rules values('account-usage',3600,600,6000) on conflict(route) do nothing;

-- The part of an operation a provider attempt served. Chat's title, follow-up suggestions and study map are separate
-- model calls inside the answer's operation (one charge); web searches are prepaid Tavily calls.
create function app_private.usage_part(p_route text,p_feature text) returns text
language sql immutable set search_path='' as $$
 select case
  when p_route in ('chat_search','ingest_lookup','reference_lookup') then 'web_search'
  when p_route='catalog_tags' then 'tags'
  when p_route='podcast_script' then 'podcast_script'
  when p_route in ('podcast_review','podcast_script_repair') then 'podcast_review'
  when p_route='podcast_speech' then 'podcast_audio'
  when p_route='paper_ocr' then 'ocr'
  when p_feature='topic_title' then 'title'
  when p_feature='suggest_follow_ups' then 'suggestions'
  when p_feature='update_study_map' then 'study_map'
  else 'answer' end
$$;

-- The activity an operation served. A settled chat operation names its action (chat_endings, 079/082/083); one still
-- running is known by the feature its attempts were dispatched with (the request's action, 089).
create function app_private.usage_activity(p_kind text,p_action text,p_features text[],p_routes text[]) returns text
language sql immutable set search_path='' as $$
 select case
  when p_kind='chat' then case
   when p_action in ('figure','figure_simpler','figure_detail')
    or (p_action is null and p_features && array['figure','figure_simpler','figure_detail']) then 'figure_explainer'
   when p_action in ('equation','equation_background')
    or (p_action is null and p_features && array['equation','equation_background']) then 'equation_explainer'
   when p_action='study' or (p_action is null and p_features && array['study','update_study_map']) then 'study'
   when p_action='related' or (p_action is null and p_features && array['related']) then 'related_papers'
   when p_action='relevance' or (p_action is null and p_features && array['relevance']) then 'why_it_matters'
   when p_action='ingest' or (p_action is null and p_features && array['ingest']) then 'add_paper'
   when p_action='diagram_fix' or (p_action is null and p_features && array['diagram_fix']) then 'diagram_repair'
   else 'chat' end
  when p_kind='podcast' then 'podcast'
  when p_kind='recommend' then 'recommendations'
  when p_kind='metadata' and p_routes && array['catalog_tags'] then 'tags'
  when p_kind='metadata' then 'paper_lookup'
  when p_kind='search' then 'web_search'
  when p_kind='ocr' then 'paper_ocr'
  when p_kind='diagram' then 'diagram'
  else 'other' end
$$;

-- Every operation of one account in the window, one row each, with its activity, outcome, charge and summed usage.
-- Settled operations that were free and reached no provider (a reference lookup that found its answer in the catalog)
-- are left out: nothing happened that a reader could pay for or learn from.
create function app_private.usage_operations(p_account_id uuid,p_since timestamptz)
returns table(id uuid,created_at timestamptz,settled_at timestamptz,kind text,activity text,action text,ending text,outcome text,
 paid_by text,credits bigint,credits_held bigint,model text,calls bigint,input_tokens bigint,cached_tokens bigint,
 cache_write_tokens bigint,output_tokens bigint,searches bigint,audio_ms bigint,estimated boolean,pending boolean)
language sql stable security definer set search_path='' as $$
 with ops as (
  select o.* from app_private.metered_operations o where o.account_id=p_account_id and o.created_at>=p_since),
 att as (
  select p.operation_id,p.created_at,p.id,p.model,p.route,p.provider,p.state,p.transport_metadata->>'feature' feature,
   app_private.usage_part(p.route,p.transport_metadata->>'feature') part,
   coalesce((p.actual_units->>'input_tokens')::bigint,0)+coalesce((p.actual_units->>'text_input_tokens')::bigint,0) input,
   coalesce((p.actual_units->>'cache_read_tokens')::bigint,0) cached,
   coalesce((p.actual_units->>'cache_write_5m_tokens')::bigint,0)+coalesce((p.actual_units->>'cache_write_1h_tokens')::bigint,0) cache_write,
   coalesce((p.actual_units->>'output_tokens')::bigint,0)+coalesce((p.actual_units->>'audio_output_tokens')::bigint,0) output,
   case when p.provider='tavily' then coalesce((p.actual_units->>'searches')::bigint,0) else 0 end searches,
   coalesce((p.actual_units->>'audio_ms')::bigint,0) audio,
   coalesce((p.actual_units->>'estimated')::bigint,0)>0 estimated
  from app_private.provider_attempts p join ops o on o.id=p.operation_id
  where p.account_id=p_account_id and p.state<>'denied'),
 per_op as (
  select a.operation_id,count(*) calls,sum(a.input) input,sum(a.cached) cached,sum(a.cache_write) cache_write,sum(a.output) output,
   sum(a.searches) searches,sum(a.audio) audio,bool_or(a.estimated) estimated,bool_or(a.state in ('admitted','unknown')) pending,
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
  coalesce(s.searches,0),coalesce(s.audio,0),coalesce(s.estimated,false),coalesce(s.pending,false)
 from ops o left join per_op s on s.operation_id=o.id
 left join app_private.chat_endings e on e.account_id=o.account_id and e.operation_id=o.id
 where not (o.state='settled' and o.credit_ceiling=0 and coalesce(o.actual_credits,0)=0 and coalesce(s.calls,0)=0)
$$;

-- One operation's parts, for its row: grouped by part and model, in the order they ran.
create function app_private.usage_parts(p_account_id uuid,p_operation_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('part',x.part,'model',x.model,'calls',x.calls,'input_tokens',x.input,'cached_tokens',x.cached,
   'cache_write_tokens',x.cache_write,'output_tokens',x.output,'searches',x.searches,'audio_ms',x.audio,'estimated',x.estimated,
   'pending',x.pending) order by x.first_at,x.part,x.model),'[]'::jsonb)
 from (
  select app_private.usage_part(p.route,p.transport_metadata->>'feature') part,p.model,count(*) calls,min(p.created_at) first_at,
   sum(coalesce((p.actual_units->>'input_tokens')::bigint,0)+coalesce((p.actual_units->>'text_input_tokens')::bigint,0)) input,
   sum(coalesce((p.actual_units->>'cache_read_tokens')::bigint,0)) cached,
   sum(coalesce((p.actual_units->>'cache_write_5m_tokens')::bigint,0)+coalesce((p.actual_units->>'cache_write_1h_tokens')::bigint,0)) cache_write,
   sum(coalesce((p.actual_units->>'output_tokens')::bigint,0)+coalesce((p.actual_units->>'audio_output_tokens')::bigint,0)) output,
   sum(case when p.provider='tavily' then coalesce((p.actual_units->>'searches')::bigint,0) else 0 end) searches,
   sum(coalesce((p.actual_units->>'audio_ms')::bigint,0)) audio,
   bool_or(coalesce((p.actual_units->>'estimated')::bigint,0)>0) estimated,bool_or(p.state in ('admitted','unknown')) pending
  from app_private.provider_attempts p
  where p.account_id=p_account_id and p.operation_id=p_operation_id and p.state<>'denied'
  group by 1,2) x
$$;

-- The reader's own usage. p_days: the last 1–366 UTC days (today included). p_activity: one activity, or all.
-- Paging: pass the previous page's `next` back as p_before_created_at/p_before_id. Totals (whole window, the activity
-- filter applied) and the activities present (whole window, no filter: the filter chips) come with the first page.
create function public.v1_ai_usage(p_days integer default 30,p_activity text default null,
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
    'estimated',p.estimated,'pending',p.pending,'parts',app_private.usage_parts(a,p.id))
   order by p.created_at desc,p.id desc) filter(where p.n<=p_limit),'[]'::jsonb) from page p),
  (select coalesce(bool_or(p.n>p_limit),false) from page p),
  case when p_before_created_at is null then
   (select jsonb_build_object('operations',count(*),'credits',coalesce(sum(u.credits),0),'credits_held',coalesce(sum(u.credits_held),0),
     'input_tokens',coalesce(sum(u.input_tokens),0),'cached_tokens',coalesce(sum(u.cached_tokens),0),
     'cache_write_tokens',coalesce(sum(u.cache_write_tokens),0),'output_tokens',coalesce(sum(u.output_tokens),0),
     'searches',coalesce(sum(u.searches),0),'audio_ms',coalesce(sum(u.audio_ms),0))
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

revoke all on function app_private.usage_part(text,text) from public,anon,authenticated;
revoke all on function app_private.usage_activity(text,text,text[],text[]) from public,anon,authenticated;
revoke all on function app_private.usage_operations(uuid,timestamptz) from public,anon,authenticated;
revoke all on function app_private.usage_parts(uuid,uuid) from public,anon,authenticated;
revoke all on function public.v1_ai_usage(integer,text,timestamptz,uuid,integer) from public,anon;
grant execute on function public.v1_ai_usage(integer,text,timestamptz,uuid,integer) to authenticated;

notify pgrst,'reload schema';
commit;
