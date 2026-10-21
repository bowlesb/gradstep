-- 0100: Provider attempt capacity counts a rolling window of granted attempts, never every attempt ever stored (review
-- A2, 2026-10-21; design: docs/architecture/PROVIDER_SPENDING.md "Attempt capacity in a rolling window").
-- Before: worker_provider_attempt_begin refused once count(*) over every provider_attempts row (refused ones included,
-- never pruned) reached 100,000 for the platform or 20,000 for an account, permanently: about 6,600 answers into the
-- owner's testing every chat, tag and podcast would fail as service_unavailable, and each admission counted the whole
-- table under the global locks. Now granted attempts are counted per UTC hour in a small table, summed over the
-- policy's window (24 hours); refused attempts never count; rows older than 8 days are pruned as hours begin. The
-- per-operation bound (64) is unchanged. No money limit changes: the monthly budget and every hold still decide what may
-- be spent. The OpenRouter tariff date moves behind one function (0101 makes it a renewable table).
begin;
set local lock_timeout='15s';

create table app_private.provider_attempt_hours (
 -- An account, or the whole platform (the nil UUID).
 scope_id uuid not null,
 hour timestamptz not null check((extract(epoch from hour)::bigint % 3600)=0),
 attempts integer not null check(attempts>=0),
 primary key(scope_id,hour)
);
alter table app_private.provider_attempt_hours enable row level security;
revoke all on app_private.provider_attempt_hours from public,anon,authenticated;

create function app_private.attempt_hour(p_at timestamptz) returns timestamptz
language sql immutable set search_path='' as $$ select to_timestamp(floor(extract(epoch from p_at)/3600)*3600) $$;

-- The last 8 days of granted attempts (refused ones never counted).
insert into app_private.provider_attempt_hours(scope_id,hour,attempts)
select scope,hour,count(*) from (
 select a.account_id as scope,app_private.attempt_hour(a.created_at) as hour from app_private.provider_attempts a
  where a.state<>'denied' and a.created_at>now()-interval '8 days'
 union all
 select '00000000-0000-0000-0000-000000000000'::uuid,app_private.attempt_hour(a.created_at) from app_private.provider_attempts a
  where a.state<>'denied' and a.created_at>now()-interval '8 days') x
group by scope,hour;

-- The limits now apply per window: 50,000 granted attempts a day for the platform and 10,000 for one account (a chat
-- answer with a title and suggestions uses about 3). Raising them later is a policy update, not a migration.
alter table app_private.provider_spending_policy drop constraint provider_spending_policy_attempt_limit_check,
 drop constraint provider_spending_policy_account_attempt_limit_check,
 add column attempt_window_hours integer not null default 24 check(attempt_window_hours between 1 and 168);
alter table app_private.provider_spending_policy add constraint provider_attempt_window_limit check(attempt_limit between 1 and 1000000),
 add constraint provider_attempt_window_account_limit check(account_attempt_limit between 1 and 200000),
 alter column attempt_limit set default 50000, alter column account_attempt_limit set default 10000;
update app_private.provider_spending_policy set attempt_limit=50000,account_attempt_limit=10000 where singleton;

create function app_private.provider_attempt_window_used(p_scope uuid,p_hours integer) returns bigint
language sql stable security definer set search_path='' as $$
 select coalesce(sum(attempts),0)::bigint from app_private.provider_attempt_hours
 where scope_id=p_scope and hour>app_private.attempt_hour(now())-make_interval(hours=>p_hours)
$$;

-- Whether one more grant fits. Every caller holds provider_lock_operation (the policy row), so counts are taken in turn.
create function app_private.provider_attempt_capacity(p_account_id uuid,p_operation_id uuid,pol app_private.provider_spending_policy) returns boolean
language sql stable security definer set search_path='' as $$
 select app_private.provider_attempt_window_used('00000000-0000-0000-0000-000000000000',pol.attempt_window_hours)<pol.attempt_limit
  and app_private.provider_attempt_window_used(p_account_id,pol.attempt_window_hours)<pol.account_attempt_limit
  and (select count(*) from app_private.provider_attempts where account_id=p_account_id and operation_id=p_operation_id)<pol.operation_attempt_limit
$$;

-- One granted attempt; rows older than the longest window (7 days) plus a day are pruned for both scopes.
create function app_private.provider_attempt_counted(p_account_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare h timestamptz:=app_private.attempt_hour(now());
begin
 insert into app_private.provider_attempt_hours as t(scope_id,hour,attempts)
 values(p_account_id,h,1),('00000000-0000-0000-0000-000000000000',h,1)
 on conflict(scope_id,hour) do update set attempts=t.attempts+1;
 delete from app_private.provider_attempt_hours where scope_id in (p_account_id,'00000000-0000-0000-0000-000000000000') and hour<h-interval '8 days';
end $$;

-- Every reviewed OpenRouter price card's validity, in one place (until 0101: the date all of them had).
create function app_private.openrouter_tariff_expires(p_model text) returns timestamptz
language sql stable security definer set search_path='' as $$ select '2027-01-01T00:00:00Z'::timestamptz $$;
create function app_private.openrouter_tariff_expiry_text(p_model text) returns text
language sql stable security definer set search_path='' as $$
 select to_char(app_private.openrouter_tariff_expires(p_model) at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')
$$;
revoke all on function app_private.attempt_hour(timestamptz),app_private.provider_attempt_window_used(uuid,integer),
 app_private.provider_attempt_capacity(uuid,uuid,app_private.provider_spending_policy),app_private.provider_attempt_counted(uuid),
 app_private.openrouter_tariff_expires(text),app_private.openrouter_tariff_expiry_text(text) from public,anon,authenticated;

-- As migration 089, with the window above and the tariff date from one function (comments marked 0100).
create or replace function public.worker_provider_attempt_begin(p_account_id uuid,p_operation_id uuid,p_attempt_id uuid,
 p_provider text,p_route text,p_model text,p_request_sha256 bytea,p_ceiling_microusd bigint,p_reserved_units jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare op app_private.metered_operations; pol app_private.provider_spending_policy; prior app_private.provider_attempts;
 allowance app_private.provider_allowance_periods; daily app_private.provider_allowance_days;
 reason text; used bigint; units bigint; v_bucket text; day_key date:=(now() at time zone 'UTC')::date; snapshot jsonb;
 podcast_route boolean:=p_route in ('podcast_script','podcast_review','podcast_script_repair','podcast_speech');
begin
 if p_attempt_id is null or p_provider not in ('anthropic','tavily','mathpix','google','deepseek','openrouter') or p_provider is null
  or p_route is null or p_model is null or p_model !~ '^[a-zA-Z0-9./_-]{1,128}$'
  or octet_length(p_request_sha256) is distinct from 32 or p_ceiling_microusd is null or p_ceiling_microusd not between 0 and 30000000
  or not app_private.valid_provider_units(p_reserved_units) then raise exception 'invalid_provider_attempt'; end if;
 if not ((p_provider='tavily' and p_route in ('chat_search','ingest_lookup','reference_lookup'))
  or (p_provider='openrouter' and p_route='chat' and p_model in ('gemini-3.8-flash','anthropic/claude-haiku-5.5','anthropic/claude-sonnet-5.5','anthropic/claude-opus-5.5','deepseek/deepseek-v4.1-flash-1017'))
  or (p_provider='openrouter' and p_route='catalog_tags' and p_model='anthropic/claude-haiku-5.5')
  or (p_provider='openrouter' and p_route in ('podcast_script','podcast_review','podcast_script_repair') and p_model in ('anthropic/claude-sonnet-5.5','deepseek/deepseek-v4-pro-0813'))
  or (p_provider='openrouter' and p_route='podcast_speech' and p_model='google/gemini-3.8-flash-tts')) then raise exception 'invalid_provider_route'; end if;
 if podcast_route and current_setting('app_private.podcast_attempt',true) is distinct from p_attempt_id::text then
  raise exception 'podcast_admission_required';
 end if;
 op:=app_private.provider_lock_operation(p_account_id,p_operation_id);
 if podcast_route<>(op.kind='podcast') then raise exception 'invalid_provider_route'; end if;
 select * into strict pol from app_private.provider_spending_policy where singleton;
 select * into prior from app_private.provider_attempts where id=p_attempt_id;
 if found then
  if (prior.account_id,prior.operation_id,prior.provider,prior.route,prior.model,prior.request_sha256,prior.ceiling_microusd,prior.reserved_units)
   is distinct from (p_account_id,p_operation_id,p_provider,p_route,p_model,p_request_sha256,p_ceiling_microusd,p_reserved_units)
  then raise exception 'provider_attempt_id_conflict'; end if;
  return jsonb_build_object('granted',false,'state',prior.state,'reason','attempt_replayed');
 end if;
 -- (0100) Granted attempts within the rolling window, per platform and per account, and the per-operation bound.
 if not app_private.provider_attempt_capacity(p_account_id,p_operation_id,pol)
 then return jsonb_build_object('granted',false,'state','denied','reason','attempt_capacity'); end if;
 if not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended) then reason:='account_unavailable';
 elsif p_provider='openrouter' and now()>=app_private.openrouter_tariff_expires(p_model) then reason:='tariff_expired';
 elsif not pol.enabled or not exists(select 1 from app_private.platform_budgets where period=op.period and work_enabled) then reason:='platform_paused';
 elsif not op.attempt_accounting and op.created_at<(select coverage_started_at from app_private.provider_spending_policy where singleton) then reason:='legacy_operation';
 elsif p_provider in ('anthropic','deepseek','openrouter') and coalesce((p_reserved_units->>'web_searches')::bigint,0)>0 then reason:='native_search_unbounded';
 elsif op.state='settled' and not (p_provider='tavily' and p_route='ingest_lookup' and p_ceiling_microusd=0 and op.created_at>now()-interval '15 minutes')
 then reason:='operation_settled'; end if;
 select coalesce(sum(case when state in ('admitted','unknown') then ceiling_microusd else coalesce(actual_microusd,0) end),0)
  into used from app_private.provider_attempts where account_id=p_account_id and operation_id=p_operation_id;
 if reason is null and used+p_ceiling_microusd>op.spend_ceiling_microusd then reason:='operation_ceiling'; end if;
 if p_provider='tavily' then
  if p_reserved_units<>jsonb_build_object('credits',1) or p_ceiling_microusd<>0 or p_model<>'search-basic' then raise exception 'invalid_search_reservation'; end if;
  units:=1; v_bucket:=case when p_route='chat_search' then 'chat' else 'lookup' end;
  if reason is null then
   select * into allowance from app_private.provider_allowance_periods
    where provider='tavily' and starts_at<=now() and ends_at>now() and enabled for update;
   if not found then reason:='provider_allowance_unverified';
   elsif allowance.baseline_units+allowance.spent_units+allowance.reserved_units+units>allowance.limit_units then reason:='provider_allowance_exhausted'; end if;
  end if;
  if reason is null then
   insert into app_private.provider_allowance_days(account_id,day,bucket) values(p_account_id,day_key,v_bucket) on conflict do nothing;
   select * into strict daily from app_private.provider_allowance_days where account_id=p_account_id and day=day_key and provider_allowance_days.bucket=v_bucket for update;
   if daily.spent_units+daily.reserved_units+units>(case when v_bucket='chat' then pol.chat_search_daily else pol.lookup_search_daily end)
   then reason:='account_provider_allowance'; end if;
  end if;
 end if;
 snapshot:=case when p_provider='openrouter' and p_route='podcast_speech' then jsonb_build_object(
   'version','provider-bounds-router-speech-20261018','credit_rate_version',op.rate_version,'ceiling_microusd',p_ceiling_microusd,
   'profile',current_setting('app_private.podcast_profile',true),'tariff','openrouter-gemini-tts-upper-20270101',
   'routing','speech/zdr','zdr',true,'cost_source','openrouter_generation_receipt','expires_at',app_private.openrouter_tariff_expiry_text(p_model),
   'rates_microusd',jsonb_build_object('text_input',1,'audio_output',18))
  when p_provider='openrouter' and p_model like 'deepseek/%' then jsonb_build_object(
   'version','provider-bounds-router-deepseek-20261018','credit_rate_version',op.rate_version,'ceiling_microusd',p_ceiling_microusd,
   'tariff','openrouter-deepseek-deepinfra-20261018','model',p_model,'inference_provider','deepinfra/fp8','zdr',true,
   'cost_source','openrouter_final_usage','expires_at',app_private.openrouter_tariff_expiry_text(p_model),
   'rates_microusd',case when p_model='deepseek/deepseek-v4.1-flash-1017' then jsonb_build_object('input',0.2,'output',0.6,'cache_read',0.006)
    else jsonb_build_object('input',1.3,'output',2.6,'cache_read',0.1) end)
  when p_provider='openrouter' and p_model like 'anthropic/%' then jsonb_build_object(
   'version','provider-bounds-20261017-chat-claude-router-v1','credit_rate_version',op.rate_version,
   'ceiling_microusd',p_ceiling_microusd,'tariff','openrouter-claude-vertex-us-20261017',
   'model',p_model,'inference_provider','google-vertex/us','zdr',true,'cost_source','openrouter_final_usage',
   'expires_at',app_private.openrouter_tariff_expiry_text(p_model),
   'rates_microusd',case p_model
    when 'anthropic/claude-haiku-5.5' then jsonb_build_object('input',0.11,'output',0.55,'cache_write_5m',0.1375,'cache_write_1h',0.22,'cache_read',0.011,'long_prompt_threshold',100000,'long_prompt_multiplier',5)
    when 'anthropic/claude-sonnet-5.5' then jsonb_build_object('input',2.2,'output',11,'cache_write_5m',2.75,'cache_write_1h',4.4,'cache_read',0.11)
    else jsonb_build_object('input',4.4,'output',22,'cache_write_5m',5.5,'cache_write_1h',8.8,'cache_read',0.22) end)
  when p_provider='openrouter' then jsonb_build_object('version','provider-bounds-20261017-chat-gemini-vertex-v1','credit_rate_version',op.rate_version,
   'ceiling_microusd',p_ceiling_microusd,'tariff','openrouter-google-flash-vertex-us-20261017','inference_provider','google-vertex/us','zdr',true,
   'cost_source','openrouter_final_usage','expires_at',app_private.openrouter_tariff_expiry_text(p_model),
   'rates_microusd',jsonb_build_object('input',0.825,'output',4.125,'cache_read',0.0825,'cache_storage_token_hour',0.5))
  when p_provider='deepseek' then jsonb_build_object('version','provider-bounds-20261016-chat-deepseek-v1','credit_rate_version',op.rate_version,
   'ceiling_microusd',p_ceiling_microusd,'tariff','deepseek-token-rates-peak-20261016',
   'rates_microusd',jsonb_build_object('flash',jsonb_build_object('input',0.3,'output',1.2,'cache_read',0.006)))
  else jsonb_build_object('version','provider-bounds-20261007-v1','credit_rate_version',op.rate_version,
  'ceiling_microusd',p_ceiling_microusd,'tariff',case p_provider when 'tavily' then 'prepaid-basic-one-credit-no-overage'
   when 'mathpix' then 'pdf-page-cap-5000-microusd' else 'anthropic-token-rates-20261007' end,
  'rates_microusd',case p_provider when 'mathpix' then jsonb_build_object('page',5000) when 'tavily' then jsonb_build_object('prepaid_credit',0,'customer_list_credit',8000)
   else jsonb_build_object('sonnet',jsonb_build_object('input',2,'output',10,'cache_write_5m',2.5,'cache_write_1h',4,'cache_read',0.2),
    'haiku',jsonb_build_object('input',1,'output',5,'cache_write_5m',1.25,'cache_read',0.1),
    'fallback',jsonb_build_object('input',4,'output',20,'cache_write_5m',5,'cache_write_1h',8,'cache_read',0.4)) end) end;
 insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,
  state,failure_code,pricing_snapshot,allowance_period_id,allowance_day,allowance_bucket)
 values(p_attempt_id,p_account_id,p_operation_id,p_provider,p_route,p_model,p_request_sha256,p_ceiling_microusd,p_reserved_units,
  case when reason is null then 'admitted' else 'denied' end,reason,snapshot,
  case when reason is null then allowance.id end,case when reason is null and allowance.id is not null then day_key end,
  case when reason is null and allowance.id is not null then v_bucket end);
 insert into app_private.provider_attempt_events(attempt_id,state,details) values(p_attempt_id,
  case when reason is null then 'admitted' else 'denied' end,jsonb_build_object('reason',reason,'ceiling_microusd',p_ceiling_microusd,'reserved_units',p_reserved_units));
 if reason is null then
  update app_private.metered_operations set attempt_accounting=true where account_id=p_account_id and id=p_operation_id;
  perform app_private.provider_attempt_counted(p_account_id);
 end if;
 if reason is null and allowance.id is not null then
  update app_private.provider_allowance_periods set reserved_units=reserved_units+units where id=allowance.id;
  update app_private.provider_allowance_days set reserved_units=reserved_units+units where account_id=p_account_id and day=day_key and provider_allowance_days.bucket=v_bucket;
 end if;
 return jsonb_build_object('granted',reason is null,'state',case when reason is null then 'admitted' else 'denied' end,'reason',reason);
end $$;

-- The window's use: the platform's, the busiest account's, and whether either passed 80% of its limit.
create function app_private.provider_attempt_window() returns jsonb
language sql stable security definer set search_path='' as $$
 with p as (select * from app_private.provider_spending_policy where singleton),
 used as (select app_private.provider_attempt_window_used('00000000-0000-0000-0000-000000000000',p.attempt_window_hours) platform from p),
 busiest as (select h.scope_id account_id,sum(h.attempts)::bigint used from app_private.provider_attempt_hours h cross join p
  where h.scope_id<>'00000000-0000-0000-0000-000000000000' and h.hour>app_private.attempt_hour(now())-make_interval(hours=>p.attempt_window_hours)
  group by h.scope_id order by sum(h.attempts) desc,h.scope_id limit 1)
 select jsonb_build_object('window_hours',p.attempt_window_hours,'platform_used',used.platform,'platform_limit',p.attempt_limit,
  'account_limit',p.account_attempt_limit,'busiest_account_id',(select account_id from busiest),'busiest_account_used',coalesce((select used from busiest),0),
  'eighty_percent',used.platform>=p.attempt_limit*0.8 or coalesce((select used from busiest),0)>=p.account_attempt_limit*0.8)
 from p cross join used
$$;
revoke all on function app_private.provider_attempt_window() from public,anon,authenticated;

-- The owner's Spending tab (chained from migration 095's): the window's use, and its 80% warning computed from it.
alter function public.v1_admin_spending(integer,uuid) rename to admin_spending_before_0100;
alter function public.admin_spending_before_0100(integer,uuid) set schema app_private;
revoke all on function app_private.admin_spending_before_0100(integer,uuid) from public,anon,authenticated;
create function public.v1_admin_spending(p_days integer default 30,p_account_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb; capacity jsonb;
begin
 -- The earlier function checks the owner with MFA, the window and the request rate before anything is read.
 base:=app_private.admin_spending_before_0100(p_days,p_account_id);
 capacity:=app_private.provider_attempt_window();
 return jsonb_set(base,'{anomalies,attempt_capacity_eighty_percent}',to_jsonb(coalesce((capacity->>'eighty_percent')::boolean,false)))
  ||jsonb_build_object('attempt_capacity',capacity);
end $$;
revoke all on function public.v1_admin_spending(integer,uuid) from public,anon;
grant execute on function public.v1_admin_spending(integer,uuid) to authenticated;

-- The scheduled budget check (worker_budget_health, migration 079) gains fields from one replaceable function, so later
-- migrations add to it without another wrapper.
create function app_private.budget_health_extra() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('attempt_capacity_eighty_percent',coalesce((app_private.provider_attempt_window()->>'eighty_percent')::boolean,false))
$$;
revoke all on function app_private.budget_health_extra() from public,anon,authenticated;
alter function public.worker_budget_health() rename to budget_health_before_0100;
alter function public.budget_health_before_0100() set schema app_private;
revoke all on function app_private.budget_health_before_0100() from public,anon,authenticated,service_role;
create function public.worker_budget_health() returns jsonb
language sql stable security definer set search_path='' as $$
 select app_private.budget_health_before_0100()||case when app_private.budget_health_before_0100() ? 'missing' then '{}'::jsonb else app_private.budget_health_extra() end
$$;
revoke all on function public.worker_budget_health() from public,anon,authenticated;
grant execute on function public.worker_budget_health() to service_role;

notify pgrst,'reload schema';
commit;
