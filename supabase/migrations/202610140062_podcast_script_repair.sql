-- Podcast script repair (docs/architecture/PAPER_PODCASTS.md, 2026-10-14). Every recent generation on staging failed
-- script_evidence_rejected the same way: the review accepted the draft, the checker removed the turns whose numbers
-- were not in their evidence, and the remaining script fell under the length's word floor (jobs 17cc7dbd, da14208a on
-- 2026-10-09). A third script call, `podcast_script_repair`, lets the worker ask the writer once for replacement turns
-- (every number only where its own evidence quotes it) and run the deterministic checker again. Additive: a new route
-- in the route lists and constraints, the grant gate (repair runs in `checking` after a succeeded review; speech still
-- needs the review only), one attempt per route per job as before, and version-3 profiles that carry the call and its
-- ceiling. Version-2 rows and jobs are untouched: a repair grant on a profile without the call is refused with
-- `route_unavailable`, and the policy pointer moves to version 3 through the audited worker_podcast_policy_set, not here.
begin;
set local lock_timeout='15s';

alter table app_private.provider_attempts drop constraint provider_attempts_route_check;
alter table app_private.provider_attempts add constraint provider_attempts_route_check
 check(route in ('chat','chat_search','ingest_lookup','reference_lookup','catalog_tags','paper_ocr',
  'podcast_script','podcast_review','podcast_script_repair','podcast_speech'));
alter table app_private.podcast_job_attempts drop constraint podcast_job_attempts_route_check;
alter table app_private.podcast_job_attempts add constraint podcast_job_attempts_route_check
 check(route in ('podcast_script','podcast_review','podcast_script_repair','podcast_speech'));

-- As migration 048, with the repair route in the provider's route lists.
create or replace function public.worker_provider_attempt_begin(p_account_id uuid,p_operation_id uuid,p_attempt_id uuid,
 p_provider text,p_route text,p_model text,p_request_sha256 bytea,p_ceiling_microusd bigint,p_reserved_units jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare op app_private.metered_operations; pol app_private.provider_spending_policy; prior app_private.provider_attempts;
 allowance app_private.provider_allowance_periods; daily app_private.provider_allowance_days;
 reason text; used bigint; units bigint; v_bucket text; day_key date:=(now() at time zone 'UTC')::date; snapshot jsonb;
 podcast_route boolean:=p_route in ('podcast_script','podcast_review','podcast_script_repair','podcast_speech');
begin
 if p_attempt_id is null or p_provider not in ('anthropic','tavily','mathpix','google') or p_provider is null
  or p_route is null or p_model is null or p_model !~ '^[a-zA-Z0-9./_-]{1,128}$'
  or octet_length(p_request_sha256) is distinct from 32 or p_ceiling_microusd is null or p_ceiling_microusd not between 0 and 30000000
  or not app_private.valid_provider_units(p_reserved_units) then raise exception 'invalid_provider_attempt'; end if;
 if not ((p_provider='anthropic' and p_route in ('chat','catalog_tags','podcast_script','podcast_review','podcast_script_repair'))
  or (p_provider='tavily' and p_route in ('chat_search','ingest_lookup','reference_lookup'))
  or (p_provider='mathpix' and p_route='paper_ocr') or (p_provider='google' and p_route='podcast_speech')) then raise exception 'invalid_provider_route'; end if;
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
   'tariff',case p_provider when 'google' then 'vertex-gemini-3.8-flash-tts-list-20270101' else 'anthropic-token-rates-20261007' end,
   'rates_microusd',case p_provider when 'google' then jsonb_build_object('text_input',1,'audio_output',18)
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

-- As migration 048, with the repair's stage and prerequisite.
create or replace function app_private.podcast_grant_gate(j app_private.podcast_jobs,p_route text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare need text; previous text;
begin
 if j.cancel_requested then
  j:=app_private.podcast_settle(j,'canceled','canceled_by_owner'); return jsonb_build_object('granted',false,'reason','canceled');
 end if;
 need:=case p_route when 'podcast_script' then 'scripting' when 'podcast_review' then 'checking' when 'podcast_script_repair' then 'checking' else 'synthesizing' end;
 previous:=case p_route when 'podcast_review' then 'podcast_script' when 'podcast_script_repair' then 'podcast_review' when 'podcast_speech' then 'podcast_review' end;
 if j.state<>need or (previous is not null and not app_private.podcast_route_succeeded(j.id,previous)) then raise exception 'invalid_podcast_stage'; end if;
 if exists(select 1 from app_private.podcast_episode_keys k where k.id=j.episode_id and k.scope='shared')
  and not app_private.podcast_rights_current(j.episode_id,j.rights_revision) then
  j:=app_private.podcast_settle(j,'failed','rights_changed'); return jsonb_build_object('granted',false,'reason','rights_changed');
 end if;
 return null;
end $$;

-- As migration 048, accepting the repair route and refusing it on profiles without the call.
create or replace function public.worker_podcast_attempt_begin(p_job uuid,p_claim uuid,p_generation bigint,p_attempt_id uuid,p_route text,p_request_sha256 bytea) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; spec jsonb; admission jsonb; prior app_private.podcast_job_attempts; refused jsonb;
begin
 if p_attempt_id is null or p_route is null or p_route not in ('podcast_script','podcast_review','podcast_script_repair','podcast_speech')
  or octet_length(p_request_sha256) is distinct from 32 then raise exception 'invalid_provider_attempt'; end if;
 j:=app_private.podcast_fenced(p_job,p_claim,p_generation);
 if j.origin<>'generated' then raise exception 'invalid_provider_route'; end if;
 select * into prior from app_private.podcast_job_attempts where job_id=j.id and route=p_route order by ordinal limit 1;
 if found then
  -- A lost acknowledgement never becomes permission for another POST.
  return jsonb_build_object('granted',false,'reason',case when prior.attempt_id=p_attempt_id then 'attempt_replayed' else 'route_used' end);
 end if;
 refused:=app_private.podcast_grant_gate(j,p_route);
 if refused is not null then return refused; end if;
 spec:=app_private.podcast_job_spec(j);
 -- A profile without the repair call (every version-2 job) has no such grant: refused, not an error, and the job goes on.
 if p_route='podcast_script_repair' and not exists(select 1 from jsonb_array_elements(spec->'script'->'calls') c where c->>'route'=p_route) then
  perform app_private.podcast_event(j.id,'attempt',jsonb_build_object('route',p_route,'ordinal',0,'attempt_id',p_attempt_id,'granted',false,'reason','route_unavailable'));
  return jsonb_build_object('granted',false,'reason','route_unavailable');
 end if;
 if p_route='podcast_speech' then update app_private.podcast_jobs set speech_calls=1 where id=j.id returning * into j; end if;
 admission:=app_private.podcast_grant(j,spec,p_attempt_id,p_route,p_request_sha256,0,
  case when p_route='podcast_speech' then least((spec->'speech'->>'max_output_tokens')::bigint,
   coalesce((spec->'speech'->>'max_audio_tokens')::bigint,(spec->'speech'->>'max_output_tokens')::bigint)) end);
 update app_private.podcast_jobs set lease_until=clock_timestamp()+interval '15 minutes' where id=j.id;
 if not (admission->>'granted')::boolean then
  j:=app_private.podcast_settle(j,'failed','provider_admission_refused');
 end if;
 return admission;
end $$;

-- Version 3 of every profile: version 2 plus the repair call (the paper, the kept turns and the removals in; a whole
-- script out, at the draft's output cap), the ceiling raised by that call, the maximum credits by the same rule as before.
insert into app_private.podcast_profiles(id,version,spec,spec_sha256)
select id,3,spec,sha256(convert_to(spec::text,'UTF8')) from (
 select v.id,
  jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(v.spec,'{version}','3'::jsonb),
   '{script,calls}',(v.spec->'script'->'calls')||jsonb_build_array(c.call)),
   '{ceiling_microusd}',to_jsonb(c.total)),'{max_credits}',to_jsonb(c.credits)),'{hold_microusd}',to_jsonb(c.credits*5000)) as spec
 from app_private.podcast_profiles v
 cross join lateral (
  select (v.spec->'script'->'calls'->0->>'max_output_tokens')::bigint as draft_out) d
 cross join lateral (
  select jsonb_build_object('route','podcast_script_repair','max_input_tokens',80000+d.draft_out+2000,'max_output_tokens',d.draft_out,
    'ceiling_microusd',(80000+d.draft_out+2000)*2+d.draft_out*10)
   ||case when (v.spec->>'staged')::boolean then jsonb_build_object('window_seconds',(v.spec->'script'->'calls'->0->>'window_seconds')::integer) else '{}'::jsonb end as call,
   (v.spec->>'ceiling_microusd')::bigint+(80000+d.draft_out+2000)*2+d.draft_out*10 as total,
   ceil(((v.spec->>'ceiling_microusd')::bigint+(80000+d.draft_out+2000)*2+d.draft_out*10)::numeric/50000)*10 as credits) c
 where v.version=2 and v.id in ('podcast-short-v1','podcast-5min-v1','podcast-10min-v1','podcast-20min-v1')
  and not exists(select 1 from app_private.podcast_profiles x where x.id=v.id and x.version=3)
) s;

-- The stated totals are the sums of their parts (as 048 and 052 check theirs).
do $$
begin
 if (select count(*) from app_private.podcast_profiles where version=3)<>4 then raise exception 'podcast_profile_v3_missing'; end if;
 if exists(select 1 from app_private.podcast_profiles p where p.version=3 and (
   (select count(*) from jsonb_array_elements(p.spec->'script'->'calls') c where c->>'route'='podcast_script_repair')<>1
   or (p.spec->>'ceiling_microusd')::bigint<>(select sum((c->>'ceiling_microusd')::bigint) from jsonb_array_elements(p.spec->'script'->'calls') c)
     +(p.spec->'speech'->>'ceiling_microusd')::bigint
   or (p.spec->>'max_credits')::bigint<>ceil((p.spec->>'ceiling_microusd')::numeric/50000)*10
   or (p.spec->>'hold_microusd')::bigint<>(p.spec->>'max_credits')::bigint*5000
   or (p.spec->>'version')::integer<>3)) then raise exception 'podcast_profile_v3_arithmetic'; end if;
end $$;

-- The five-minute estimate text (057) still reflects the measured beta usage on version 3.
create or replace function app_private.podcast_estimate(p_spec jsonb) returns text
language sql immutable set search_path='' as $$
 select case
   when p_spec->>'id'='podcast-5min-v1' and coalesce((p_spec->>'version')::integer,0) in (2,3)
   then 'Estimate — recent beta examples used about 55–60 credits; actual usage varies, maximum '||(p_spec->>'max_credits')||' credits'
   else 'Estimate — you''re charged actual usage, maximum '||(p_spec->>'max_credits')||' credits'
 end
$$;

revoke all on function public.worker_provider_attempt_begin(uuid,uuid,uuid,text,text,text,bytea,bigint,jsonb) from public,anon,authenticated;
revoke all on function public.worker_podcast_attempt_begin(uuid,uuid,bigint,uuid,text,bytea) from public,anon,authenticated;
revoke all on function app_private.podcast_grant_gate(app_private.podcast_jobs,text) from public,anon,authenticated;
revoke all on function app_private.podcast_estimate(jsonb) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
