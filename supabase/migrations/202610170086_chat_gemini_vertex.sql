-- 086: Fixed Flash route satisfies the observed OpenRouter ZDR policy.
-- Design: docs/architecture/GEMINI_FLASH_CHAT.md, Build 68 follow-up.
-- Only the snapshot for newly admitted attempts changes; historical snapshots, admission, locks and settlement stay intact.
begin;
set local lock_timeout='15s';

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
 if not ((p_provider='anthropic' and p_route in ('chat','catalog_tags','podcast_script','podcast_review','podcast_script_repair'))
  or (p_provider='tavily' and p_route in ('chat_search','ingest_lookup','reference_lookup'))
  or (p_provider='mathpix' and p_route='paper_ocr') or (p_provider='google' and p_route='podcast_speech')
  or (p_provider='deepseek' and p_route in ('podcast_script','podcast_review','podcast_script_repair'))
  or (p_provider='deepseek' and p_route='chat' and p_model='deepseek-flash')
  or (p_provider='openrouter' and p_route='chat' and p_model='gemini-3.8-flash')) then raise exception 'invalid_provider_route'; end if;
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
 snapshot:=case when podcast_route then jsonb_build_object('version','provider-bounds-20261008-podcast-v1','credit_rate_version',op.rate_version,
   'ceiling_microusd',p_ceiling_microusd,'profile',current_setting('app_private.podcast_profile',true),
   'tariff',case p_provider when 'google' then 'vertex-gemini-3.8-flash-tts-list-20270101' when 'deepseek' then 'deepseek-token-rates-peak-20261014' else 'anthropic-token-rates-20261007' end,
   'rates_microusd',case p_provider when 'google' then jsonb_build_object('text_input',1,'audio_output',18)
    when 'deepseek' then jsonb_build_object('v4_pro',jsonb_build_object('input',1.32,'output',3.96,'cache_read',0.044))
    else jsonb_build_object('sonnet',jsonb_build_object('input',2,'output',10)) end)
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

notify pgrst, 'reload schema';
commit;
