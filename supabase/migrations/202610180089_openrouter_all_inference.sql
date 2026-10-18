-- 089: Every new paid model request uses OpenRouter; account-scoped one-shot dispatch and receipts.
-- Design: PROVIDER_SPENDING.md and PAPER_PODCASTS.md, owner 2026-10-18. Historical bills stay unchanged.
begin;
set local lock_timeout='15s';
alter table app_private.provider_attempts add column dispatched_at timestamptz;
alter table app_private.provider_attempts add column transport_metadata jsonb not null default '{}'
 check(jsonb_typeof(transport_metadata)='object' and octet_length(transport_metadata::text)<=2048);
alter table app_private.provider_attempts add column receipt_metadata jsonb not null default '{}'
 check(jsonb_typeof(receipt_metadata)='object' and octet_length(receipt_metadata::text)<=2048);
create index provider_attempt_account_time on app_private.provider_attempts(account_id,created_at desc,id desc);
alter table app_private.provider_attempt_events drop constraint provider_attempt_events_state_check;
alter table app_private.provider_attempt_events add constraint provider_attempt_events_state_check
 check(state in ('admitted','succeeded','rejected','unknown','denied','reconciled','provider_identified','dispatched','receipt'));

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
 if (select count(*) from app_private.provider_attempts)>=pol.attempt_limit
  or (select count(*) from app_private.provider_attempts where account_id=p_account_id)>=pol.account_attempt_limit
  or (select count(*) from app_private.provider_attempts where account_id=p_account_id and operation_id=p_operation_id)>=pol.operation_attempt_limit
 then return jsonb_build_object('granted',false,'state','denied','reason','attempt_capacity'); end if;
 if not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended) then reason:='account_unavailable';
 elsif p_provider='openrouter' and now()>='2027-01-01T00:00:00Z'::timestamptz then reason:='tariff_expired';
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
   'routing','speech/zdr','zdr',true,'cost_source','openrouter_generation_receipt','expires_at','2027-01-01T00:00:00Z',
   'rates_microusd',jsonb_build_object('text_input',1,'audio_output',18))
  when p_provider='openrouter' and p_model like 'deepseek/%' then jsonb_build_object(
   'version','provider-bounds-router-deepseek-20261018','credit_rate_version',op.rate_version,'ceiling_microusd',p_ceiling_microusd,
   'tariff','openrouter-deepseek-deepinfra-20261018','model',p_model,'inference_provider','deepinfra/fp8','zdr',true,
   'cost_source','openrouter_final_usage','expires_at','2027-01-01T00:00:00Z',
   'rates_microusd',case when p_model='deepseek/deepseek-v4.1-flash-1017' then jsonb_build_object('input',0.2,'output',0.6,'cache_read',0.006)
    else jsonb_build_object('input',1.3,'output',2.6,'cache_read',0.1) end)
  when p_provider='openrouter' and p_model like 'anthropic/%' then jsonb_build_object(
   'version','provider-bounds-20261017-chat-claude-router-v1','credit_rate_version',op.rate_version,
   'ceiling_microusd',p_ceiling_microusd,'tariff','openrouter-claude-vertex-us-20261017',
   'model',p_model,'inference_provider','google-vertex/us','zdr',true,'cost_source','openrouter_final_usage',
   'expires_at','2027-01-01T00:00:00Z',
   'rates_microusd',case p_model
    when 'anthropic/claude-haiku-5.5' then jsonb_build_object('input',0.11,'output',0.55,'cache_write_5m',0.1375,'cache_write_1h',0.22,'cache_read',0.011,'long_prompt_threshold',100000,'long_prompt_multiplier',5)
    when 'anthropic/claude-sonnet-5.5' then jsonb_build_object('input',2.2,'output',11,'cache_write_5m',2.75,'cache_write_1h',4.4,'cache_read',0.11)
    else jsonb_build_object('input',4.4,'output',22,'cache_write_5m',5.5,'cache_write_1h',8.8,'cache_read',0.22) end)
  when p_provider='openrouter' then jsonb_build_object('version','provider-bounds-20261017-chat-gemini-vertex-v1','credit_rate_version',op.rate_version,
   'ceiling_microusd',p_ceiling_microusd,'tariff','openrouter-google-flash-vertex-us-20261017','inference_provider','google-vertex/us','zdr',true,
   'cost_source','openrouter_final_usage','expires_at','2027-01-01T00:00:00Z',
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
 end if;
 if reason is null and allowance.id is not null then
  update app_private.provider_allowance_periods set reserved_units=reserved_units+units where id=allowance.id;
  update app_private.provider_allowance_days set reserved_units=reserved_units+units where account_id=p_account_id and day=day_key and provider_allowance_days.bucket=v_bucket;
 end if;
 return jsonb_build_object('granted',reason is null,'state',case when reason is null then 'admitted' else 'denied' end,'reason',reason);
end $$;


-- A lost grant acknowledgement cannot authorize a replay. Account and operation identity come from admission,
-- never caller-provided prompt content; this metadata has a closed shape and no free-text fields.
create function public.worker_openrouter_dispatch(p_account_id uuid,p_operation_id uuid,p_attempt_id uuid,p_metadata jsonb)
returns boolean language plpgsql security definer set search_path='' as $$
declare a app_private.provider_attempts; expected text; endpoint text;
begin
 if p_metadata is null or jsonb_typeof(p_metadata)<>'object' or octet_length(p_metadata::text)>1024
  or (select count(*) from jsonb_object_keys(p_metadata))<>4
  or not p_metadata ?& array['transport_model','endpoint','feature','caller']
  or exists(select 1 from jsonb_each(p_metadata) e where jsonb_typeof(e.value)<>'string')
  or p_metadata->>'feature' !~ '^[a-z][a-z0-9_/-]{0,63}$' or p_metadata->>'caller' !~ '^[a-z][a-z0-9_/-]{0,63}$'
 then raise exception 'invalid_transport_metadata'; end if;
 select * into a from app_private.provider_attempts where id=p_attempt_id and account_id=p_account_id and operation_id=p_operation_id for update;
 if not found or a.provider<>'openrouter' or a.state<>'admitted' or a.dispatched_at is not null then return false; end if;
 if not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended) then return false; end if;
 expected:=case when a.model='gemini-3.8-flash' then 'google/'||a.model else a.model end;
 endpoint:=case when a.route='podcast_speech' then 'speech/zdr' when a.model like 'deepseek/%' then 'deepinfra/fp8' else 'google-vertex/us' end;
 if p_metadata->>'transport_model'<>expected or p_metadata->>'endpoint'<>endpoint then raise exception 'transport_route_mismatch'; end if;
 update app_private.provider_attempts set dispatched_at=clock_timestamp(),transport_metadata=p_metadata where id=a.id;
 insert into app_private.provider_attempt_events(attempt_id,state,details) values(a.id,'dispatched',p_metadata);
 return true;
end $$;

create function public.worker_openrouter_receipt(p_account_id uuid,p_operation_id uuid,p_attempt_id uuid,p_metadata jsonb)
returns boolean language plpgsql security definer set search_path='' as $$
declare a app_private.provider_attempts;
begin
 if p_metadata is null or jsonb_typeof(p_metadata)<>'object' or octet_length(p_metadata::text)>1024
  or not p_metadata ?& array['generation_id','provider','model']
  or exists(select 1 from jsonb_object_keys(p_metadata) k where k not in ('generation_id','provider','model','resolved_model','total_cost_microusd'))
  or length(p_metadata->>'generation_id') not between 1 and 256 or p_metadata->>'generation_id' !~ '^[a-zA-Z0-9._:/-]+$'
  or exists(select 1 from jsonb_each(p_metadata) e where e.key<>'total_cost_microusd' and jsonb_typeof(e.value)<>'string')
  or p_metadata->>'provider' !~ '^[a-zA-Z0-9 ./_-]{1,80}$' or p_metadata->>'model' !~ '^[a-zA-Z0-9./_-]{1,128}$'
  or (p_metadata ? 'resolved_model' and p_metadata->>'resolved_model' !~ '^[a-zA-Z0-9./_-]{1,128}$')
  or (p_metadata ? 'total_cost_microusd' and (jsonb_typeof(p_metadata->'total_cost_microusd')<>'number'
   or p_metadata->>'total_cost_microusd' !~ '^[0-9]+$' or (p_metadata->>'total_cost_microusd')::numeric>1000000000))
 then raise exception 'invalid_transport_receipt'; end if;
 select * into a from app_private.provider_attempts where id=p_attempt_id and account_id=p_account_id and operation_id=p_operation_id for update;
 if not found or a.provider<>'openrouter' or a.dispatched_at is null then return false; end if;
 if a.receipt_metadata<>'{}' then
  if a.receipt_metadata<>p_metadata then raise exception 'receipt_conflict'; end if;
  return true;
 end if;
 if p_metadata->>'model'<>a.transport_metadata->>'transport_model' then raise exception 'receipt_model_mismatch'; end if;
 update app_private.provider_attempts set receipt_metadata=p_metadata where id=a.id;
 insert into app_private.provider_attempt_events(attempt_id,state,details) values(a.id,'receipt',p_metadata);
 return true;
end $$;
revoke all on function public.worker_openrouter_dispatch(uuid,uuid,uuid,jsonb),public.worker_openrouter_receipt(uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.worker_openrouter_dispatch(uuid,uuid,uuid,jsonb),public.worker_openrouter_receipt(uuid,uuid,uuid,jsonb) to service_role;

create or replace function public.worker_tags_claim(p_claim_id uuid,p_limit integer,p_model boolean,p_vocabulary text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; item jsonb; t app_private.catalog_tags; op app_private.metered_operations; admission jsonb; final_result jsonb:='[]';
begin
 result:=app_private.tags_claim_before_034(p_claim_id,p_limit,p_model,p_vocabulary);
 for item in select value from jsonb_array_elements(result) loop
  if (item->>'model')::boolean then
   select * into strict t from app_private.catalog_tags where version_id=(item->>'version_id')::uuid;
   select * into strict op from app_private.metered_operations where account_id=t.operation_account_id and id=t.operation_id;
   admission:=public.worker_provider_attempt_begin(t.operation_account_id,t.operation_id,t.operation_id,'openrouter','catalog_tags','anthropic/claude-haiku-5.5',
    op.request_sha256,op.spend_ceiling_microusd,'{"output_tokens":256}');
   item:=item||jsonb_build_object('account_id',t.operation_account_id,'operation_id',t.operation_id,'attempt_id',t.operation_id);
   if not (admission->>'granted')::boolean then
    perform public.worker_settle_operation(t.operation_account_id,t.operation_id,0,0);
    update app_private.catalog_tags set operation_account_id=null,operation_id=null where version_id=t.version_id;
    item:=item||jsonb_build_object('model',false,'hold_microusd',0,'model_refused',admission->>'reason');
   end if;
  end if;
  final_result:=final_result||jsonb_build_array(item);
 end loop;
 return final_result;
end $$;

create or replace function app_private.podcast_grant(j app_private.podcast_jobs,p_spec jsonb,p_attempt_id uuid,p_route text,p_request_sha256 bytea,
 p_ordinal integer,p_audio_tokens bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare call jsonb; provider text; model text; ceiling bigint; units jsonb; admission jsonb;
begin
 if p_spec->>'consent_version' is distinct from 'podcast-private-v3' then raise exception 'podcast_profile_unavailable'; end if;
 if p_route='podcast_speech' then
  provider:='openrouter'; model:='google/'||(p_spec->'speech'->>'model');
  units:=jsonb_build_object('text_input_tokens',(p_spec->'speech'->>'max_input_tokens')::bigint,'audio_output_tokens',p_audio_tokens);
  ceiling:=(p_spec->'speech'->>'max_input_tokens')::bigint*(p_spec->'speech'->'rates_microusd_per_token'->>'text_input')::bigint
   +p_audio_tokens*(p_spec->'speech'->'rates_microusd_per_token'->>'audio_output')::bigint;
 else
  select c into strict call from jsonb_array_elements(p_spec->'script'->'calls') c where c->>'route'=p_route;
  provider:='openrouter'; model:=p_spec->'script'->>'transport_model'; ceiling:=(call->>'ceiling_microusd')::bigint;
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

alter table app_private.podcast_quotes drop constraint podcast_quotes_consent_version_check;
alter table app_private.podcast_quotes add constraint podcast_quotes_consent_version_check check(consent_version in ('podcast-private-v1','podcast-private-v2','podcast-private-v3'));
-- Successor profiles keep writer identities and output limits. No policy pointer changes during migration.
insert into app_private.podcast_profiles(id,version,spec,spec_sha256)
select id,version,spec,sha256(convert_to(spec::text,'UTF8')) from (
 select p.id,n.version,
  p.spec||jsonb_build_object('version',n.version,'consent_version','podcast-private-v3',
   'script',p.spec->'script'||jsonb_build_object('transport_model',n.model,'calls',c.calls,
    'rates_microusd_per_token',jsonb_build_object('input',n.ri,'output',n.ro)),
   'ceiling_microusd',c.total+(p.spec->'speech'->>'ceiling_microusd')::bigint,
   'max_credits',ceil((c.total+(p.spec->'speech'->>'ceiling_microusd')::bigint)::numeric/50000)*10,
   'hold_microusd',ceil((c.total+(p.spec->'speech'->>'ceiling_microusd')::bigint)::numeric/50000)*50000) as spec
 from app_private.podcast_profiles p
 join (values (3,6,'anthropic/claude-sonnet-5.5',2.2,11),(5,7,'deepseek/deepseek-v4-pro-0813',1.3,2.6)) n(old,version,model,ri,ro) on n.old=p.version
 cross join lateral (
  select jsonb_agg(x.c||jsonb_build_object('max_input_tokens',(x.c->>'max_input_tokens')::bigint+120000,
   'ceiling_microusd',ceil(((x.c->>'max_input_tokens')::bigint+120000)*n.ri+(x.c->>'max_output_tokens')::bigint*n.ro)::bigint) order by x.ord) as calls,
   sum(ceil(((x.c->>'max_input_tokens')::bigint+120000)*n.ri+(x.c->>'max_output_tokens')::bigint*n.ro)::bigint) as total
  from jsonb_array_elements(p.spec->'script'->'calls') with ordinality x(c,ord)
 ) c
) q;
create or replace function app_private.podcast_script_provider_label(p_spec jsonb) returns text
language sql immutable set search_path='' as $$
 select case when p_spec->>'consent_version'='podcast-private-v3' then
  case p_spec->'script'->>'provider' when 'deepseek' then 'OpenRouter → DeepInfra (DeepSeek script)' else 'OpenRouter → Google Vertex (Claude script)' end
 else case p_spec->'script'->>'provider' when 'deepseek' then 'DeepSeek (script)' else 'Anthropic (script)' end end
$$;

create or replace function public.v1_podcast_quote(p_item_id uuid,p_request_id uuid,p_profile text default null,p_writer text default null,p_device jsonb default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); pol app_private.podcast_policy; spec jsonb; pin jsonb; key bytea; q app_private.podcast_quotes;
 r app_private.podcast_releases; j app_private.podcast_jobs; req uuid; qspec jsonb;
begin
 perform public.worker_consume_request(a,'podcast-generate');
 if p_item_id is null or p_request_id is null then raise exception 'invalid_podcast_request'; end if;
 select * into strict pol from app_private.podcast_policy where singleton;
 if not pol.generation_enabled or not app_private.podcast_inventory_certified() then raise exception 'podcast_unavailable'; end if;
 if not exists(select 1 from app_private.accounts where id=a and closed_at is null and not spending_suspended) then raise exception 'account_unavailable'; end if;
 spec:=app_private.podcast_allowed_spec(p_profile,p_writer);
 select * into q from app_private.podcast_quotes where account_id=a and request_id=p_request_id;
 if found then
  -- The same request id names the same paper, length and writer, or it is a different request.
  if q.item_id<>p_item_id or (q.profile_id,q.profile_version)<>(spec->>'id',(spec->>'version')::integer) then raise exception 'podcast_request_conflict'; end if;
  if q.expires_at<=now() then raise exception 'quote_expired'; end if;
 else
  if p_device is not null then pin:=app_private.podcast_device_pin(a,p_device||jsonb_build_object('membership_id',p_item_id));
  else pin:=app_private.podcast_item_pin(a,p_item_id); end if;
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
  'providers',jsonb_build_array(app_private.podcast_script_provider_label(qspec),case when qspec->>'consent_version'='podcast-private-v3' then 'OpenRouter → Google (speech)' else 'Google Vertex AI (speech)' end),'consent_version',q.consent_version,
  'target_seconds',(qspec->>'target_seconds')::integer,'profile',q.profile_id,'label',app_private.podcast_label(qspec),
  'writer',app_private.podcast_writer(qspec),'writer_label',app_private.podcast_writer_label(qspec)),
  'options',app_private.podcast_lengths());
end $$;

notify pgrst, 'reload schema';
commit;
