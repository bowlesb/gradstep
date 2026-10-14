-- DeepSeek as the podcast script provider (docs/architecture/PAPER_PODCASTS.md "DeepSeek script provider", 2026-10-14).
-- Owner direction: a cheaper script writer, proven on podcasts. Additive: the provider `deepseek` in the attempt
-- constraint and route rules (script, review and repair routes only; speech stays with Google), the podcast admission
-- taking the provider from the profile spec instead of assuming Anthropic, a second consent version
-- (`podcast-private-v2`) that a quote carries and the start requires exactly, the quote's provider labels read from the
-- spec, and version-4 profiles copied from version 3 with `deepseek-v4-pro` at DeepSeek's peak list prices
-- ($1.32 per million input tokens, $3.96 output; off-peak is cheaper, so every ceiling is an upper bound). Version-3
-- rows and jobs are untouched; the policy pointer moves to version 4 through the audited worker_podcast_policy_set.
begin;
set local lock_timeout='15s';

alter table app_private.provider_attempts drop constraint provider_attempts_provider_check;
alter table app_private.provider_attempts add constraint provider_attempts_provider_check
 check(provider in ('anthropic','tavily','mathpix','google','deepseek'));

-- As migration 062, with DeepSeek admitted for the script routes and its own pricing snapshot.
create or replace function public.worker_provider_attempt_begin(p_account_id uuid,p_operation_id uuid,p_attempt_id uuid,
 p_provider text,p_route text,p_model text,p_request_sha256 bytea,p_ceiling_microusd bigint,p_reserved_units jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare op app_private.metered_operations; pol app_private.provider_spending_policy; prior app_private.provider_attempts;
 allowance app_private.provider_allowance_periods; daily app_private.provider_allowance_days;
 reason text; used bigint; units bigint; v_bucket text; day_key date:=(now() at time zone 'UTC')::date; snapshot jsonb;
 podcast_route boolean:=p_route in ('podcast_script','podcast_review','podcast_script_repair','podcast_speech');
begin
 if p_attempt_id is null or p_provider not in ('anthropic','tavily','mathpix','google','deepseek') or p_provider is null
  or p_route is null or p_model is null or p_model !~ '^[a-zA-Z0-9./_-]{1,128}$'
  or octet_length(p_request_sha256) is distinct from 32 or p_ceiling_microusd is null or p_ceiling_microusd not between 0 and 30000000
  or not app_private.valid_provider_units(p_reserved_units) then raise exception 'invalid_provider_attempt'; end if;
 if not ((p_provider='anthropic' and p_route in ('chat','catalog_tags','podcast_script','podcast_review','podcast_script_repair'))
  or (p_provider='tavily' and p_route in ('chat_search','ingest_lookup','reference_lookup'))
  or (p_provider='mathpix' and p_route='paper_ocr') or (p_provider='google' and p_route='podcast_speech')
  or (p_provider='deepseek' and p_route in ('podcast_script','podcast_review','podcast_script_repair'))) then raise exception 'invalid_provider_route'; end if;
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
 if (select count(*) from app_private.provider_attempts)>=pol.attempt_limit
  or (select count(*) from app_private.provider_attempts where account_id=p_account_id)>=pol.account_attempt_limit
  or (select count(*) from app_private.provider_attempts where account_id=p_account_id and operation_id=p_operation_id)>=pol.operation_attempt_limit
 then return jsonb_build_object('granted',false,'state','denied','reason','attempt_capacity'); end if;
 if not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended) then reason:='account_unavailable';
 elsif not pol.enabled or not exists(select 1 from app_private.platform_budgets where period=op.period and work_enabled) then reason:='platform_paused';
 elsif not op.attempt_accounting and op.created_at<(select coverage_started_at from app_private.provider_spending_policy where singleton) then reason:='legacy_operation';
 elsif p_provider='anthropic' and coalesce((p_reserved_units->>'web_searches')::bigint,0)>0 then reason:='native_search_unbounded';
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
 snapshot:=case when podcast_route then jsonb_build_object('version','provider-bounds-20261008-podcast-v1','credit_rate_version',op.rate_version,
   'ceiling_microusd',p_ceiling_microusd,'profile',current_setting('app_private.podcast_profile',true),
   'tariff',case p_provider when 'google' then 'vertex-gemini-3.8-flash-tts-list-20270101' when 'deepseek' then 'deepseek-token-rates-peak-20261014' else 'anthropic-token-rates-20261007' end,
   'rates_microusd',case p_provider when 'google' then jsonb_build_object('text_input',1,'audio_output',18)
    when 'deepseek' then jsonb_build_object('v4_pro',jsonb_build_object('input',1.32,'output',3.96,'cache_read',0.044))
    else jsonb_build_object('sonnet',jsonb_build_object('input',2,'output',10)) end)
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
 end if;
 if reason is null and allowance.id is not null then
  update app_private.provider_allowance_periods set reserved_units=reserved_units+units where id=allowance.id;
  update app_private.provider_allowance_days set reserved_units=reserved_units+units where account_id=p_account_id and day=day_key and provider_allowance_days.bucket=v_bucket;
 end if;
 return jsonb_build_object('granted',reason is null,'state',case when reason is null then 'admitted' else 'denied' end,'reason',reason);
end $$;
-- As migration 048, with the provider read from the profile (speech stays with Google).
create or replace function app_private.podcast_grant(j app_private.podcast_jobs,p_spec jsonb,p_attempt_id uuid,p_route text,p_request_sha256 bytea,
 p_ordinal integer,p_audio_tokens bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare call jsonb; provider text; model text; ceiling bigint; units jsonb; admission jsonb;
begin
 if p_route='podcast_speech' then
  provider:='google'; model:=p_spec->'speech'->>'model';
  units:=jsonb_build_object('text_input_tokens',(p_spec->'speech'->>'max_input_tokens')::bigint,'audio_output_tokens',p_audio_tokens);
  ceiling:=(p_spec->'speech'->>'max_input_tokens')::bigint*(p_spec->'speech'->'rates_microusd_per_token'->>'text_input')::bigint
   +p_audio_tokens*(p_spec->'speech'->'rates_microusd_per_token'->>'audio_output')::bigint;
 else
  select c into strict call from jsonb_array_elements(p_spec->'script'->'calls') c where c->>'route'=p_route;
  provider:=coalesce(p_spec->'script'->>'provider','anthropic'); model:=p_spec->'script'->>'model'; ceiling:=(call->>'ceiling_microusd')::bigint;
  units:=jsonb_build_object('input_tokens',(call->>'max_input_tokens')::bigint,'output_tokens',(call->>'max_output_tokens')::bigint);
 end if;
 perform set_config('app_private.podcast_attempt',p_attempt_id::text,true);
 perform set_config('app_private.podcast_profile',(p_spec->>'id')||':'||(p_spec->>'version'),true);
 admission:=public.worker_provider_attempt_begin(j.operation_account_id,j.operation_id,p_attempt_id,provider,p_route,model,p_request_sha256,ceiling,units);
 perform set_config('app_private.podcast_attempt','',true);
 if exists(select 1 from app_private.provider_attempts where id=p_attempt_id) then
  insert into app_private.podcast_job_attempts(job_id,route,ordinal,attempt_id) values(j.id,p_route,p_ordinal,p_attempt_id);
 end if;
 perform app_private.podcast_event(j.id,'attempt',jsonb_build_object('route',p_route,'ordinal',p_ordinal,'attempt_id',p_attempt_id,
  'granted',admission->'granted','reason',admission->'reason'));
 return admission||jsonb_build_object('attempt_id',p_attempt_id,'provider',provider,'model',model,'ceiling_microusd',ceiling,'units',units,
  'ordinal',p_ordinal,'account_id',j.operation_account_id,'operation_id',j.operation_id);
end $$;
-- A quote names the script provider the way the clients show it.
create or replace function app_private.podcast_script_provider_label(p_spec jsonb) returns text
language sql immutable set search_path='' as $$
 select case p_spec->'script'->>'provider' when 'deepseek' then 'DeepSeek (script)' else 'Anthropic (script)' end
$$;

alter table app_private.podcast_quotes drop constraint podcast_quotes_consent_version_check;
alter table app_private.podcast_quotes add constraint podcast_quotes_consent_version_check
 check(consent_version in ('podcast-private-v1','podcast-private-v2'));

-- As migration 057, with the provider label from the quoted profile.
create or replace function public.v1_podcast_quote(p_item_id uuid,p_request_id uuid,p_profile text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); pol app_private.podcast_policy; spec jsonb; pin jsonb; key bytea; q app_private.podcast_quotes;
 r app_private.podcast_releases; j app_private.podcast_jobs; req uuid; qspec jsonb;
begin
 perform public.worker_consume_request(a,'podcast-generate');
 if p_item_id is null or p_request_id is null then raise exception 'invalid_podcast_request'; end if;
 select * into strict pol from app_private.podcast_policy where singleton;
 if not pol.generation_enabled or not app_private.podcast_inventory_certified() then raise exception 'podcast_unavailable'; end if;
 if not exists(select 1 from app_private.accounts where id=a and closed_at is null and not spending_suspended) then raise exception 'account_unavailable'; end if;
 spec:=app_private.podcast_allowed_spec(p_profile);
 select * into q from app_private.podcast_quotes where account_id=a and request_id=p_request_id;
 if found then
  if q.item_id<>p_item_id or q.profile_id<>spec->>'id' then raise exception 'podcast_request_conflict'; end if;
  if q.expires_at<=now() then raise exception 'quote_expired'; end if;
 else
  pin:=app_private.podcast_item_pin(a,p_item_id);
  if pin is null then raise exception 'source_unavailable'; end if;
  if (pin->>'text_bytes')::bigint>(spec->>'max_source_bytes')::bigint then raise exception 'source_too_large'; end if;
  key:=app_private.podcast_work_key('private',a,spec,pin);
  select x.* into r from app_private.podcast_releases x join app_private.podcast_episode_keys k on k.id=x.episode_id
   where k.scope='private' and k.owner_id=a and k.work_sha256=key and x.state='ready' limit 1;
  if found then return jsonb_build_object('reuse',jsonb_build_object('release_id',r.id)); end if;
  select x.* into j from app_private.podcast_jobs x join app_private.podcast_episode_keys k on k.id=x.episode_id
   where k.scope='private' and k.owner_id=a and k.work_sha256=key and x.finished_at is null and x.state not in ('unknown_provider','quarantined') limit 1;
  if found then
   select request_id into req from app_private.podcast_requests where account_id=a and job_id=j.id order by created_at limit 1;
   return jsonb_build_object('join',jsonb_build_object('request_id',req));
  end if;
  if app_private.podcast_account_unresolved(a) then raise exception 'podcast_outcome_pending'; end if;
  if (select count(*) from app_private.podcast_quotes where account_id=a and created_at>now()-interval '1 day')>=50 then raise exception 'request_rate_limit'; end if;
  insert into app_private.podcast_quotes(account_id,request_id,item_id,work_sha256,pin,profile_id,profile_version,max_credits,max_microusd,epoch,consent_version,expires_at)
   values(a,p_request_id,p_item_id,key,pin,spec->>'id',(spec->>'version')::integer,(spec->>'max_credits')::bigint,(spec->>'hold_microusd')::bigint,
    pol.epoch,spec->>'consent_version',now()+interval '15 minutes') returning * into q;
 end if;
 select pr.spec into strict qspec from app_private.podcast_profiles pr where (pr.id,pr.version)=(q.profile_id,q.profile_version);
 return jsonb_build_object('quote',jsonb_build_object('id',q.id,'expires_at',q.expires_at,'max_credits',q.max_credits,
  'estimate',app_private.podcast_estimate(qspec),
  'providers',jsonb_build_array(app_private.podcast_script_provider_label(qspec),'Google Vertex AI (speech)'),'consent_version',q.consent_version,
  'target_seconds',(qspec->>'target_seconds')::integer,'profile',q.profile_id,'label',app_private.podcast_label(qspec)),
  'options',app_private.podcast_lengths());
end $$;

-- As migration 048, requiring the consent version the quote carries.
create or replace function public.v1_podcast_start(p_quote_id uuid,p_request_id uuid,p_consent_version text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); month date:=app_private.podcast_month(); pol app_private.podcast_policy; q app_private.podcast_quotes;
 prior app_private.podcast_requests; spec jsonb; pin jsonb; episode uuid; r app_private.podcast_releases; j app_private.podcast_jobs; op uuid; req uuid;
begin
 perform public.worker_consume_request(a,'podcast-generate');
 if p_quote_id is null or p_request_id is null then raise exception 'invalid_podcast_request'; end if;
 select * into prior from app_private.podcast_requests where account_id=a and request_id=p_request_id;
 if found then
  if prior.quote_id<>p_quote_id then raise exception 'podcast_request_conflict'; end if;
  if prior.outcome='reused' then return jsonb_build_object('reuse',jsonb_build_object('release_id',prior.release_id)); end if;
  select * into strict j from app_private.podcast_jobs where id=prior.job_id;
  return jsonb_build_object('job',app_private.podcast_job_public(j,p_request_id));
 end if;
 -- Budget -> account -> provider policy -> podcast policy, as every financial path.
 perform 1 from app_private.platform_budgets where period=month for update;
 perform 1 from app_private.accounts where id=a and closed_at is null and not spending_suspended for update;
 if not found then raise exception 'account_unavailable'; end if;
 perform 1 from app_private.provider_spending_policy where singleton for update;
 select * into strict pol from app_private.podcast_policy where singleton for update;
 if not pol.generation_enabled or not app_private.podcast_inventory_certified() then raise exception 'podcast_unavailable'; end if;
 select * into q from app_private.podcast_quotes where id=p_quote_id and account_id=a;
 if not found then raise exception 'quote_unavailable'; end if;
 -- The consent the quote named (its profile's providers), not a fixed version: a DeepSeek quote needs podcast-private-v2.
 if p_consent_version is distinct from q.consent_version then raise exception 'consent_required'; end if;
 if q.expires_at<=now() or q.epoch<>pol.epoch then raise exception 'quote_expired'; end if;
 -- The quoted length, still offered (an operator may have withdrawn it since).
 spec:=app_private.podcast_allowed_spec(q.profile_id);
 -- The quote never authorizes later changes to its source or options.
 pin:=app_private.podcast_item_pin(a,q.item_id);
 if pin is distinct from q.pin or app_private.podcast_work_key('private',a,spec,pin)<>q.work_sha256
  or (spec->>'id',(spec->>'version')::integer)<>(q.profile_id,q.profile_version) then raise exception 'quote_expired'; end if;
 select x.* into r from app_private.podcast_releases x join app_private.podcast_episode_keys k on k.id=x.episode_id
  where k.scope='private' and k.owner_id=a and k.work_sha256=q.work_sha256 and x.state='ready' limit 1;
 if found then
  insert into app_private.podcast_requests(account_id,request_id,quote_id,release_id,outcome) values(a,p_request_id,q.id,r.id,'reused');
  return jsonb_build_object('reuse',jsonb_build_object('release_id',r.id));
 end if;
 select x.* into j from app_private.podcast_jobs x join app_private.podcast_episode_keys k on k.id=x.episode_id
  where k.scope='private' and k.owner_id=a and k.work_sha256=q.work_sha256 and x.finished_at is null and x.state not in ('unknown_provider','quarantined') for update of x;
 if found then
  insert into app_private.podcast_requests(account_id,request_id,quote_id,job_id,outcome) values(a,p_request_id,q.id,j.id,'joined');
  return jsonb_build_object('job',app_private.podcast_job_public(j,p_request_id));
 end if;
 if (select count(*) from app_private.podcast_jobs x join app_private.podcast_episode_keys k on k.id=x.episode_id
   where k.owner_id=a and x.funding_kind='customer' and x.state in ('queued','scripting','checking','synthesizing','verifying','publishing','capacity_wait'))>=pol.max_active_private_per_account
  then raise exception 'active_generation_limit'; end if;
 if (select count(*) from app_private.podcast_jobs where state in ('queued','scripting','checking','synthesizing','verifying','publishing'))>=pol.max_active_environment
  then raise exception 'podcast_busy'; end if;
 if (select count(*) from app_private.podcast_jobs where created_at>now()-interval '1 day')>=pol.max_jobs_day_environment then raise exception 'podcast_daily_limit'; end if;
 if app_private.podcast_customer_losses(month)>=pol.quality_allocation_microusd then raise exception 'podcast_paused'; end if;
 if app_private.podcast_account_unresolved(a) then raise exception 'podcast_outcome_pending'; end if;
 op:=gen_random_uuid();
 perform public.worker_reserve_operation(a,op,'podcast',sha256(convert_to(jsonb_build_array('gradstep/podcast-private/v1',a,p_request_id,q.id,encode(q.work_sha256,'hex'))::text,'UTF8')),
  'beta-credits-v1',q.max_credits,q.max_microusd);
 episode:=app_private.podcast_insert_episode('private',a,spec,pin);
 insert into app_private.podcast_jobs(episode_id,origin,funding_kind,operation_account_id,operation_id,epoch)
  values(episode,'generated','customer',a,op,pol.epoch) returning * into j;
 update app_private.podcast_jobs set kicked_at=clock_timestamp() where id=j.id returning * into j;
 insert into app_private.podcast_asset_holds(job_id,owner_id,bytes,objects)
  values(j.id,a,(spec->'storage'->>'bytes')::bigint,(spec->'storage'->>'objects')::integer);
 begin perform app_private.paper_asset_check_capacity(a);
 exception when raise_exception then
  if sqlerrm in ('paper_storage_capacity','paper_owner_storage_capacity') then raise exception 'storage_full'; end if; raise;
 end;
 insert into app_private.podcast_requests(account_id,request_id,quote_id,job_id,outcome) values(a,p_request_id,q.id,j.id,'started');
 perform app_private.podcast_event(j.id,'admitted',jsonb_build_object('funding','customer','hold_credits',q.max_credits,'hold_microusd',q.max_microusd));
 perform app_private.podcast_kick();
 return jsonb_build_object('job',app_private.podcast_job_public(j,p_request_id));
end $$;

-- Version 4 of every profile: version 3 with DeepSeek writing, reviewing and repairing the script. Every script call's
-- ceiling is its token caps at DeepSeek's peak prices; the totals, credits and hold follow the same rules as before.
insert into app_private.podcast_profiles(id,version,spec,spec_sha256)
select id,4,spec,sha256(convert_to(spec::text,'UTF8')) from (
 select v.id,
  jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(v.spec,
   '{version}','4'::jsonb),
   '{script,provider}','"deepseek"'::jsonb),
   '{script,model}','"deepseek-v4-pro"'::jsonb),
   '{script,rates_microusd_per_token}','{"input":1.32,"output":3.96}'::jsonb),
   '{script,calls}',s.calls),
   '{ceiling_microusd}',to_jsonb(c.total)),
   '{max_credits}',to_jsonb(c.credits)),
   '{hold_microusd}',to_jsonb(c.credits*5000)),
   '{consent_version}','"podcast-private-v2"'::jsonb) as spec
 from app_private.podcast_profiles v
 cross join lateral (
  select jsonb_agg(t.c||jsonb_build_object('ceiling_microusd',ceil((t.c->>'max_input_tokens')::numeric*1.32+(t.c->>'max_output_tokens')::numeric*3.96)::bigint) order by t.o) as calls,
   sum(ceil((t.c->>'max_input_tokens')::numeric*1.32+(t.c->>'max_output_tokens')::numeric*3.96)::bigint) as script_total
  from jsonb_array_elements(v.spec->'script'->'calls') with ordinality as t(c,o)) s
 cross join lateral (
  select s.script_total+(v.spec->'speech'->>'ceiling_microusd')::bigint as total,
   ceil((s.script_total+(v.spec->'speech'->>'ceiling_microusd')::bigint)::numeric/50000)*10 as credits) c
 where v.version=3 and v.id in ('podcast-short-v1','podcast-5min-v1','podcast-10min-v1','podcast-20min-v1')
  and not exists(select 1 from app_private.podcast_profiles x where x.id=v.id and x.version=4)
) x;

-- The stated totals are the sums of their parts, and the provider, model, rates and consent are the DeepSeek ones.
do $$
begin
 if (select count(*) from app_private.podcast_profiles where version=4)<>4 then raise exception 'podcast_profile_v4_missing'; end if;
 if exists(select 1 from app_private.podcast_profiles p where p.version=4 and (
   p.spec->'script'->>'provider'<>'deepseek' or p.spec->'script'->>'model'<>'deepseek-v4-pro'
   or p.spec->'script'->'rates_microusd_per_token'<>'{"input":1.32,"output":3.96}'::jsonb
   or p.spec->>'consent_version'<>'podcast-private-v2'
   or (select count(*) from jsonb_array_elements(p.spec->'script'->'calls') c)<>3
   or exists(select 1 from jsonb_array_elements(p.spec->'script'->'calls') c
     where (c->>'ceiling_microusd')::bigint<>ceil((c->>'max_input_tokens')::numeric*1.32+(c->>'max_output_tokens')::numeric*3.96)::bigint)
   or (p.spec->>'ceiling_microusd')::bigint<>(select sum((c->>'ceiling_microusd')::bigint) from jsonb_array_elements(p.spec->'script'->'calls') c)
     +(p.spec->'speech'->>'ceiling_microusd')::bigint
   or (p.spec->>'max_credits')::bigint<>ceil((p.spec->>'ceiling_microusd')::numeric/50000)*10
   or (p.spec->>'hold_microusd')::bigint<>(p.spec->>'max_credits')::bigint*5000
   or (p.spec->>'version')::integer<>4)) then raise exception 'podcast_profile_v4_arithmetic'; end if;
end $$;

revoke all on function public.worker_provider_attempt_begin(uuid,uuid,uuid,text,text,text,bytea,bigint,jsonb) from public,anon,authenticated;
revoke all on function app_private.podcast_grant(app_private.podcast_jobs,jsonb,uuid,text,bytea,integer,bigint) from public,anon,authenticated,service_role;
revoke all on function app_private.podcast_script_provider_label(jsonb) from public,anon,authenticated,service_role;
revoke all on function public.v1_podcast_quote(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.v1_podcast_quote(uuid,uuid,text) to authenticated;
revoke all on function public.v1_podcast_start(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.v1_podcast_start(uuid,uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
