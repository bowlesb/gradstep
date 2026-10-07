-- Durable single-transport grants and provider liabilities. See SPENDING_CONTROLS.md.
-- Existing credit settlement remains immutable; unresolved vendor cost is separate.
begin;

alter table app_private.accounts add column spending_suspended boolean not null default false;
alter table app_private.metered_operations
 add column attempt_accounting boolean not null default false,
 add column provider_liability_microusd bigint not null default 0 check(provider_liability_microusd>=0),
 add column settlement_reported_microusd bigint check(settlement_reported_microusd>=0);

create table app_private.provider_spending_policy (
 singleton boolean primary key default true check(singleton),
 enabled boolean not null default true,
 -- Native search cannot be enabled until its internal context cost has a verified bound.
 native_search_enabled boolean not null default false check(not native_search_enabled),
 attempt_limit integer not null default 100000 check(attempt_limit between 1 and 100000),
 account_attempt_limit integer not null default 20000 check(account_attempt_limit between 1 and 20000),
 operation_attempt_limit integer not null default 64 check(operation_attempt_limit between 1 and 64),
 chat_search_daily integer not null default 30 check(chat_search_daily between 0 and 200),
 lookup_search_daily integer not null default 10 check(lookup_search_daily between 0 and 100),
 coverage_started_at timestamptz not null default now()
);
insert into app_private.provider_spending_policy(singleton) values(true);

-- No synthetic initial allowance: an operator must establish the provider's exact
-- billing period, current usage and overage setting from dated evidence first.
create table app_private.provider_allowance_periods (
 id uuid primary key default gen_random_uuid(),
 provider text not null check(provider='tavily'),
 starts_at timestamptz not null,
 ends_at timestamptz not null check(ends_at>starts_at and ends_at<=starts_at+interval '32 days'),
 limit_units bigint not null check(limit_units between 0 and 3900),
 baseline_units bigint not null check(baseline_units>=0),
 spent_units bigint not null default 0 check(spent_units>=0),
 reserved_units bigint not null default 0 check(reserved_units>=0),
 enabled boolean not null default false,
 overage_disabled boolean not null check(overage_disabled),
 evidence_reference text not null check(length(evidence_reference) between 3 and 256),
 observed_at timestamptz not null,
 created_at timestamptz not null default now(),
 unique(provider,starts_at), check(baseline_units<=limit_units)
);
create table app_private.provider_allowance_days (
 account_id uuid not null references app_private.accounts(id),
 day date not null,
 bucket text not null check(bucket in ('chat','lookup')),
 spent_units bigint not null default 0 check(spent_units>=0),
 reserved_units bigint not null default 0 check(reserved_units>=0),
 primary key(account_id,day,bucket)
);

create function app_private.valid_provider_units(p_units jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
declare item record;
begin
 if p_units is null or jsonb_typeof(p_units)<>'object' or octet_length(p_units::text)>2048 then return false; end if;
 for item in select key,value from jsonb_each(p_units) loop
  if item.key not in ('input_tokens','output_tokens','cache_write_5m_tokens','cache_write_1h_tokens','cache_read_tokens',
    'web_searches','attempts','credits','searches','pages','estimated')
   or jsonb_typeof(item.value)<>'number' or item.value::text !~ '^[0-9]{1,12}$' then return false; end if;
 end loop;
 return true;
end $$;

create table app_private.provider_attempts (
 id uuid primary key,
 account_id uuid not null,
 operation_id uuid not null,
 provider text not null check(provider in ('anthropic','tavily','mathpix')),
 route text not null check(route in ('chat','chat_search','ingest_lookup','reference_lookup','catalog_tags','paper_ocr')),
 model text not null check(model ~ '^[a-zA-Z0-9./_-]{1,128}$'),
 request_sha256 bytea not null check(octet_length(request_sha256)=32),
 ceiling_microusd bigint not null check(ceiling_microusd between 0 and 30000000),
 reserved_units jsonb not null check(app_private.valid_provider_units(reserved_units)),
 -- Projection of the append-only events below, not the accounting source of history.
 state text not null check(state in ('admitted','succeeded','rejected','unknown','denied','reconciled')),
 provider_request_id text check(length(provider_request_id) between 1 and 256 and provider_request_id ~ '^[a-zA-Z0-9._:/-]+$'),
 actual_microusd bigint check(actual_microusd between 0 and 1000000000),
 actual_units jsonb not null default '{}'::jsonb check(app_private.valid_provider_units(actual_units)),
 failure_code text check(failure_code ~ '^[a-z][a-z0-9_]{0,63}$'),
 pricing_snapshot jsonb not null,
 allowance_period_id uuid references app_private.provider_allowance_periods(id),
 allowance_day date,
 allowance_bucket text,
 created_at timestamptz not null default now(),
 finished_at timestamptz,
 foreign key(account_id,operation_id) references app_private.metered_operations(account_id,id),
 foreign key(account_id,allowance_day,allowance_bucket) references app_private.provider_allowance_days(account_id,day,bucket),
 check((allowance_period_id is null)=(allowance_day is null)),
 check((allowance_day is null)=(allowance_bucket is null)),
 check((state in ('succeeded','rejected','reconciled'))=(actual_microusd is not null)),
 check(state<>'rejected' or actual_microusd=0)
);
create index provider_attempt_operation on app_private.provider_attempts(account_id,operation_id,created_at,id);
create index provider_attempt_time on app_private.provider_attempts(created_at,id);
create index provider_attempt_unresolved on app_private.provider_attempts(created_at,id) where state in ('admitted','unknown');
create index provider_attempt_request on app_private.provider_attempts(provider,provider_request_id) where provider_request_id is not null;
create table app_private.provider_attempt_events (
 id bigint generated always as identity primary key,
 attempt_id uuid not null references app_private.provider_attempts(id),
 state text not null check(state in ('admitted','succeeded','rejected','unknown','denied','reconciled','provider_identified')),
 details jsonb not null check(jsonb_typeof(details)='object' and octet_length(details::text)<=4096),
 created_at timestamptz not null default now()
);
create index provider_attempt_event_lookup on app_private.provider_attempt_events(attempt_id,id);
create trigger provider_attempt_events_immutable before update or delete on app_private.provider_attempt_events
 for each row execute function app_private.immutable_record();
create table app_private.provider_attempt_adjustments (
 id uuid primary key,
 attempt_id uuid not null references app_private.provider_attempts(id),
 actor_id uuid references app_private.accounts(id),
 before_microusd bigint not null check(before_microusd>=0),
 after_microusd bigint not null check(after_microusd>=0),
 released_liability_microusd bigint not null check(released_liability_microusd>=0),
 units jsonb not null check(app_private.valid_provider_units(units)),
 evidence_reference text not null check(length(evidence_reference) between 3 and 256),
 reason text not null check(length(reason) between 3 and 256),
 created_at timestamptz not null default now()
);
create index provider_attempt_adjustment_lookup on app_private.provider_attempt_adjustments(attempt_id,created_at,id);
create trigger provider_attempt_adjustments_immutable before update or delete on app_private.provider_attempt_adjustments
 for each row execute function app_private.immutable_record();

-- All monetary paths lock a budget, then account, then policy, then operation.
create function app_private.provider_lock_operation(p_account_id uuid,p_operation_id uuid)
returns app_private.metered_operations language plpgsql security definer set search_path='' as $$
declare op app_private.metered_operations;
begin
 select * into strict op from app_private.metered_operations where account_id=p_account_id and id=p_operation_id;
 perform 1 from app_private.platform_budgets where period=op.period for update;
 perform 1 from app_private.accounts where id=p_account_id for update;
 perform 1 from app_private.provider_spending_policy where singleton for update;
 select * into strict op from app_private.metered_operations where account_id=p_account_id and id=p_operation_id for update;
 return op;
end $$;

alter function public.worker_reserve_operation(uuid,uuid,text,bytea,text,bigint,bigint) set schema app_private;
alter function app_private.worker_reserve_operation(uuid,uuid,text,bytea,text,bigint,bigint) rename to reserve_operation_before_034;
create function public.worker_reserve_operation(p_account_id uuid,p_id uuid,p_kind text,p_request_sha256 bytea,
 p_rate_version text,p_credits bigint,p_microusd bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=app_private.reserve_operation_before_034(p_account_id,p_id,p_kind,p_request_sha256,p_rate_version,p_credits,p_microusd);
 if exists(select 1 from app_private.accounts where id=p_account_id and spending_suspended) then raise exception 'spending_suspended'; end if;
 return result;
end $$;

create function public.worker_provider_spending_policy() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('native_search_enabled',false,'tavily_enabled',
  p.enabled and exists(select 1 from app_private.provider_allowance_periods a where a.enabled and a.overage_disabled
   and now()>=a.starts_at and now()<a.ends_at and a.baseline_units+a.spent_units+a.reserved_units<a.limit_units))
 from app_private.provider_spending_policy p where singleton
$$;

create function public.worker_provider_allowance_configure(p_id uuid,p_starts_at timestamptz,p_ends_at timestamptz,
 p_limit_units bigint,p_baseline_units bigint,p_observed_at timestamptz,p_evidence_reference text,p_overage_disabled boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a app_private.provider_allowance_periods;
begin
 if p_id is null or p_overage_disabled is distinct from true or p_observed_at is null
  or p_observed_at<now()-interval '24 hours' or p_observed_at>now()+interval '5 minutes'
  or p_starts_at>now() or p_ends_at<=now() or (length(p_evidence_reference) not between 3 and 256 or p_evidence_reference !~ '^[a-zA-Z0-9._:/ -]+$')
 then raise exception 'invalid_provider_allowance_evidence'; end if;
 perform 1 from app_private.provider_spending_policy where singleton for update;
 select * into a from app_private.provider_allowance_periods where id=p_id;
 if found then
  if (a.starts_at,a.ends_at,a.limit_units,a.baseline_units,a.observed_at,a.evidence_reference)
   is distinct from (p_starts_at,p_ends_at,p_limit_units,p_baseline_units,p_observed_at,p_evidence_reference) then raise exception 'allowance_id_conflict'; end if;
  return to_jsonb(a);
 end if;
 if exists(select 1 from app_private.provider_allowance_periods where starts_at<p_ends_at and ends_at>p_starts_at)
 then raise exception 'provider_allowance_overlap'; end if;
 insert into app_private.provider_allowance_periods(id,provider,starts_at,ends_at,limit_units,baseline_units,enabled,
  overage_disabled,observed_at,evidence_reference)
 values(p_id,'tavily',p_starts_at,p_ends_at,p_limit_units,p_baseline_units,true,true,p_observed_at,p_evidence_reference) returning * into a;
 return to_jsonb(a);
end $$;

create function public.worker_provider_attempt_begin(p_account_id uuid,p_operation_id uuid,p_attempt_id uuid,
 p_provider text,p_route text,p_model text,p_request_sha256 bytea,p_ceiling_microusd bigint,p_reserved_units jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare op app_private.metered_operations; pol app_private.provider_spending_policy; prior app_private.provider_attempts;
 allowance app_private.provider_allowance_periods; daily app_private.provider_allowance_days;
 reason text; used bigint; units bigint; v_bucket text; day_key date:=(now() at time zone 'UTC')::date; snapshot jsonb;
begin
 if p_attempt_id is null or p_provider not in ('anthropic','tavily','mathpix') or p_provider is null
  or p_route is null or p_model is null or p_model !~ '^[a-zA-Z0-9./_-]{1,128}$'
  or octet_length(p_request_sha256) is distinct from 32 or p_ceiling_microusd is null or p_ceiling_microusd not between 0 and 30000000
  or not app_private.valid_provider_units(p_reserved_units) then raise exception 'invalid_provider_attempt'; end if;
 if not ((p_provider='anthropic' and p_route in ('chat','catalog_tags')) or (p_provider='tavily' and p_route in ('chat_search','ingest_lookup','reference_lookup'))
  or (p_provider='mathpix' and p_route='paper_ocr')) then raise exception 'invalid_provider_route'; end if;
 op:=app_private.provider_lock_operation(p_account_id,p_operation_id);
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
 snapshot:=jsonb_build_object('version','provider-bounds-20261007-v1','credit_rate_version',op.rate_version,
  'ceiling_microusd',p_ceiling_microusd,'tariff',case p_provider when 'tavily' then 'prepaid-basic-one-credit-no-overage'
   when 'mathpix' then 'pdf-page-cap-5000-microusd' else 'anthropic-token-rates-20261007' end,
  'rates_microusd',case p_provider when 'mathpix' then jsonb_build_object('page',5000) when 'tavily' then jsonb_build_object('prepaid_credit',0,'customer_list_credit',8000)
   else jsonb_build_object('sonnet',jsonb_build_object('input',2,'output',10,'cache_write_5m',2.5,'cache_write_1h',4,'cache_read',0.2),
    'haiku',jsonb_build_object('input',1,'output',5,'cache_write_5m',1.25,'cache_read',0.1),
    'fallback',jsonb_build_object('input',4,'output',20,'cache_write_5m',5,'cache_write_1h',8,'cache_read',0.4)) end);
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

-- Update only projections/counters here; callers append the evidence event.
create function app_private.provider_attempt_apply(p_attempt_id uuid,p_state text,p_request_id text,p_actual bigint,p_units jsonb,p_failure text)
returns void language plpgsql security definer set search_path='' as $$
declare a app_private.provider_attempts; op app_private.metered_operations; old_hold bigint; new_hold bigint;
 old_units bigint; new_units bigint; unit_hold bigint; known_delta bigint;
begin
 select * into strict a from app_private.provider_attempts where id=p_attempt_id;
 op:=app_private.provider_lock_operation(a.account_id,a.operation_id);
 select * into strict a from app_private.provider_attempts where id=p_attempt_id for update;
 old_hold:=case when a.state in ('admitted','unknown') then a.ceiling_microusd else 0 end;
 new_hold:=case when p_state='unknown' then a.ceiling_microusd else 0 end;
 known_delta:=coalesce(p_actual,0)-coalesce(a.actual_microusd,0);
 if a.allowance_period_id is not null then
  old_units:=coalesce((a.actual_units->>'credits')::bigint,0);
  -- Unknown partial usage is evidence only; the original whole unit stays held.
  if a.state in ('admitted','unknown') then old_units:=0; end if;
  new_units:=case when p_state='unknown' then 0 else coalesce((p_units->>'credits')::bigint,0) end;
  unit_hold:=case when a.state in ('admitted','unknown') and p_state<>'unknown' then (a.reserved_units->>'credits')::bigint else 0 end;
  update app_private.provider_allowance_periods set spent_units=spent_units+new_units-old_units,
   reserved_units=reserved_units-unit_hold,
   enabled=enabled and new_units<=(a.reserved_units->>'credits')::bigint where id=a.allowance_period_id;
  update app_private.provider_allowance_days set spent_units=spent_units+new_units-old_units,reserved_units=reserved_units-unit_hold
   where account_id=a.account_id and day=a.allowance_day and bucket=a.allowance_bucket;
 end if;
 update app_private.provider_attempts set state=p_state,provider_request_id=coalesce(p_request_id,provider_request_id),actual_microusd=p_actual,
  actual_units=p_units,failure_code=p_failure,finished_at=now() where id=a.id;
 if op.state='settled' then
  update app_private.platform_budgets set spent_microusd=spent_microusd+known_delta,
   reserved_microusd=reserved_microusd-old_hold+new_hold where period=op.period;
  update app_private.metered_operations set provider_liability_microusd=provider_liability_microusd-old_hold+new_hold
   where account_id=a.account_id and id=a.operation_id;
 end if;
 if coalesce(p_actual,0)>a.ceiling_microusd or exists(select 1 from app_private.provider_attempts where account_id=a.account_id and operation_id=a.operation_id
   group by account_id,operation_id having sum(case when state in ('admitted','unknown') then ceiling_microusd else coalesce(actual_microusd,0) end)>op.spend_ceiling_microusd)
 then update app_private.platform_budgets set work_enabled=false where period=op.period; end if;
 if p_actual is not null and a.actual_microusd is null then
  insert into app_private.provider_usage_events(account_id,operation_id,provider,provider_event_id,model,units,estimated_microusd)
  values(a.account_id,a.operation_id,a.provider,'attempt:'||a.id,a.model,p_units,p_actual);
 end if;
end $$;

create function public.worker_provider_attempt_finish(p_account_id uuid,p_operation_id uuid,p_attempt_id uuid,p_state text,
 p_provider_request_id text,p_actual_microusd bigint,p_actual_units jsonb,p_failure_code text) returns void
language plpgsql security definer set search_path='' as $$
declare a app_private.provider_attempts; op app_private.metered_operations; released bigint;
begin
 if p_state is null or p_state not in ('succeeded','rejected','unknown') or not app_private.valid_provider_units(p_actual_units)
  or (p_provider_request_id is not null and (length(p_provider_request_id) not between 1 and 256 or p_provider_request_id !~ '^[a-zA-Z0-9._:/-]+$'))
  or (p_failure_code is not null and p_failure_code !~ '^[a-z][a-z0-9_]{0,63}$')
  or (p_state='unknown') is distinct from (p_actual_microusd is null)
  or p_actual_microusd not between 0 and 1000000000
  or (p_state='rejected' and (p_actual_microusd<>0 or exists(select 1 from jsonb_each_text(p_actual_units) where value::bigint<>0)))
 then raise exception 'invalid_provider_result'; end if;
 op:=app_private.provider_lock_operation(p_account_id,p_operation_id);
 select * into strict a from app_private.provider_attempts where id=p_attempt_id and account_id=p_account_id and operation_id=p_operation_id for update;
 if a.state=p_state and (a.actual_microusd,a.actual_units,a.failure_code,a.provider_request_id)
   is not distinct from (p_actual_microusd,p_actual_units,p_failure_code,coalesce(p_provider_request_id,a.provider_request_id)) then return; end if;
 if a.state not in ('admitted','unknown') then raise exception 'provider_result_conflict'; end if;
 if a.provider_request_id is not null and p_provider_request_id is not null and a.provider_request_id<>p_provider_request_id
 then raise exception 'provider_request_conflict'; end if;
 if (select count(*) from app_private.provider_attempt_events where attempt_id=a.id)>=32 then raise exception 'provider_event_capacity'; end if;
 if a.provider='tavily' and p_state='succeeded' and not (p_actual_units ? 'credits') then raise exception 'provider_units_missing'; end if;
 released:=case when p_state='unknown' then 0 else a.ceiling_microusd end;
 perform app_private.provider_attempt_apply(a.id,p_state,p_provider_request_id,p_actual_microusd,p_actual_units,p_failure_code);
 insert into app_private.provider_attempt_events(attempt_id,state,details) values(a.id,p_state,
  jsonb_build_object('provider_request_id',p_provider_request_id,'actual_microusd',p_actual_microusd,'units',p_actual_units,'failure_code',p_failure_code));
 if op.state='settled' and p_state<>'unknown' then
  insert into app_private.provider_attempt_adjustments(id,attempt_id,before_microusd,after_microusd,released_liability_microusd,units,evidence_reference,reason)
   values(gen_random_uuid(),a.id,0,p_actual_microusd,released,p_actual_units,'provider-final:'||a.id,'Late authoritative provider result');
 end if;
end $$;

alter function public.worker_settle_operation(uuid,uuid,bigint,bigint) set schema app_private;
alter function app_private.worker_settle_operation(uuid,uuid,bigint,bigint) rename to settle_operation_before_034;
create function public.worker_settle_operation(p_account_id uuid,p_id uuid,p_actual_credits bigint,p_actual_microusd bigint) returns void
language plpgsql security definer set search_path='' as $$
declare op app_private.metered_operations; known bigint; liability bigint;
begin
 op:=app_private.provider_lock_operation(p_account_id,p_id);
 if p_actual_microusd is null or p_actual_microusd<0 then raise exception 'invalid_settlement'; end if;
 if not op.attempt_accounting then
  perform app_private.settle_operation_before_034(p_account_id,p_id,p_actual_credits,p_actual_microusd); return;
 end if;
 if op.state='settled' then
  if op.actual_credits is distinct from p_actual_credits or op.settlement_reported_microusd is distinct from p_actual_microusd
  then raise exception 'settlement_id_conflict'; end if; return;
 end if;
 select coalesce(sum(actual_microusd),0),coalesce(sum(ceiling_microusd) filter(where state in ('admitted','unknown')),0)
  into known,liability from app_private.provider_attempts where account_id=p_account_id and operation_id=p_id;
 perform app_private.settle_operation_before_034(p_account_id,p_id,p_actual_credits,known);
 update app_private.platform_budgets set reserved_microusd=reserved_microusd+liability,
  work_enabled=work_enabled and known+liability<=op.spend_ceiling_microusd where period=op.period;
 update app_private.metered_operations set provider_liability_microusd=liability,settlement_reported_microusd=p_actual_microusd
  where account_id=p_account_id and id=p_id;
end $$;

-- Preserve API compatibility without duplicating new per-attempt expenses.
alter function public.worker_record_provider_usage(uuid,uuid,text,text,text,jsonb,bigint) set schema app_private;
alter function app_private.worker_record_provider_usage(uuid,uuid,text,text,text,jsonb,bigint) rename to record_provider_usage_before_034;
create function public.worker_record_provider_usage(p_account_id uuid,p_operation_id uuid,p_provider text,p_provider_event_id text,
 p_model text,p_units jsonb,p_microusd bigint) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_provider in ('anthropic','tavily','mathpix') and exists(select 1 from app_private.provider_attempts
  where account_id=p_account_id and operation_id=p_operation_id and provider=p_provider and state<>'denied') then return; end if;
 perform app_private.record_provider_usage_before_034(p_account_id,p_operation_id,p_provider,p_provider_event_id,p_model,p_units,p_microusd);
end $$;

create function public.worker_provider_attempt_reconcile(p_actor_id uuid,p_request_id uuid,p_attempt_id uuid,
 p_actual_microusd bigint,p_actual_units jsonb,p_evidence_reference text,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a app_private.provider_attempts; prior app_private.provider_attempt_adjustments; op app_private.metered_operations; released bigint; usage_id uuid;
begin
 perform app_private.require_owner_account(p_actor_id);
 if p_request_id is null or p_actual_microusd is null or p_actual_microusd not between 0 and 1000000000
  or not app_private.valid_provider_units(p_actual_units) or p_evidence_reference is null or (length(p_evidence_reference) not between 3 and 256 or p_evidence_reference !~ '^[a-zA-Z0-9._:/ -]+$')
  or p_reason is null or length(trim(p_reason)) not between 3 and 256 then raise exception 'invalid_reconciliation'; end if;
 select * into strict a from app_private.provider_attempts where id=p_attempt_id;
 op:=app_private.provider_lock_operation(a.account_id,a.operation_id);
 select * into strict a from app_private.provider_attempts where id=p_attempt_id for update;
 select * into prior from app_private.provider_attempt_adjustments where id=p_request_id;
 if found then
  if (prior.attempt_id,prior.actor_id,prior.after_microusd,prior.units,prior.evidence_reference,prior.reason)
   is distinct from (p_attempt_id,p_actor_id,p_actual_microusd,p_actual_units,p_evidence_reference,trim(p_reason)) then raise exception 'reconciliation_id_conflict'; end if;
  return jsonb_build_object('replayed',true,'attempt_id',a.id);
 end if;
 if a.state='denied' or (a.provider='tavily' and not (p_actual_units ? 'credits')) then raise exception 'invalid_reconciliation'; end if;
 if (select count(*) from app_private.provider_attempt_adjustments where attempt_id=a.id)>=16 then raise exception 'reconciliation_capacity'; end if;
 released:=case when a.state in ('admitted','unknown') then a.ceiling_microusd else 0 end;
 select id into usage_id from app_private.provider_usage_events where provider=a.provider and provider_event_id='attempt:'||a.id;
 perform app_private.provider_attempt_apply(a.id,'reconciled',null,p_actual_microusd,p_actual_units,null);
 insert into app_private.provider_attempt_adjustments(id,attempt_id,actor_id,before_microusd,after_microusd,released_liability_microusd,units,evidence_reference,reason)
 values(p_request_id,a.id,p_actor_id,coalesce(a.actual_microusd,0),p_actual_microusd,released,p_actual_units,p_evidence_reference,trim(p_reason));
 if usage_id is not null then
  insert into app_private.provider_reconciliations(usage_event_id,invoice_reference,adjustment_microusd)
   values(usage_id,'attempt-adjustment:'||p_request_id,p_actual_microusd-coalesce(a.actual_microusd,0));
 end if;
 insert into app_private.provider_attempt_events(attempt_id,state,details) values(a.id,'reconciled',jsonb_build_object('adjustment_id',p_request_id,
  'actor_id',p_actor_id,'actual_microusd',p_actual_microusd,'units',p_actual_units,'evidence_reference',p_evidence_reference));
 return jsonb_build_object('replayed',false,'attempt_id',a.id);
end $$;

-- The DB spending guard commits with the owner request, before the separate Auth
-- API. Replaying an old disable must not undo a newer enable (or vice versa).
alter function public.worker_admin_set_sign_in(uuid,uuid,uuid,boolean,text) set schema app_private;
alter function app_private.worker_admin_set_sign_in(uuid,uuid,uuid,boolean,text) rename to admin_set_sign_in_before_034;
create function public.worker_admin_set_sign_in(p_actor_id uuid,p_request_id uuid,p_account_id uuid,p_disabled boolean,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; current_disabled boolean;
begin
 result:=app_private.admin_set_sign_in_before_034(p_actor_id,p_request_id,p_account_id,p_disabled,p_reason);
 if not (result->>'replayed')::boolean then update app_private.accounts set spending_suspended=p_disabled where id=p_account_id; end if;
 select spending_suspended into strict current_disabled from app_private.accounts where id=p_account_id;
 return result||jsonb_build_object('disabled',current_disabled,'spending_suspended',current_disabled);
end $$;

-- Pipeline/tag integrations are below; financial locks must precede paper locks.
create function app_private.pipeline_money_lock(p_paper_id uuid,p_include_candidates boolean default false) returns uuid[]
language plpgsql security definer set search_path='' as $$
declare period_key date; acct_id uuid; locked_accounts uuid[];
begin
 for period_key in select distinct period from (
  select date_trunc('month',now() at time zone 'UTC')::date period
  union all select op.period from app_private.ocr_attempts x join app_private.metered_operations op
   on (op.account_id,op.id)=(x.funder_account_id,x.operation_id)
   where x.paper_id=p_paper_id and x.state in ('funded','submitting','submitted','uncertain')) b order by period loop
  perform 1 from app_private.platform_budgets where period=period_key for update;
 end loop;
 -- Capture all linked accounts when choosing a first funder, including inactive
 -- interests: a reactivated existing link must not add an unlocked account later.
 select coalesce(array_agg(id order by id),'{}'::uuid[]) into locked_accounts from (
  select owner_id id from app_private.pipeline_papers where id=p_paper_id
  union select funder_account_id from app_private.ocr_attempts where paper_id=p_paper_id and state in ('funded','submitting','submitted','uncertain')
  union select account_id from app_private.pipeline_imports where p_include_candidates and paper_id=p_paper_id
 ) a where id is not null;
 foreach acct_id in array locked_accounts loop
  perform 1 from app_private.accounts where id=acct_id for update;
 end loop;
 return locked_accounts;
end $$;

-- First funding uses the exact locked candidate snapshot. Closed/suspended first
-- importers cannot abort another eligible account's funding or invert paper locks.
create or replace function public.worker_pipeline_fund(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_page_limit integer,
 p_options_sha256 bytea,p_request_sha256 bytea) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; pol app_private.pipeline_policy; run uuid; raw_run uuid; artifact uuid; candidate record; op uuid;
 credits bigint; microusd bigint; funded boolean:=false; paused boolean:=false; locked_accounts uuid[];
begin
 locked_accounts:=app_private.pipeline_money_lock(p_paper_id,true);
 -- Stronger than the ordinary stage fence: prevent a new import FK from joining
 -- after the snapshot check. A just-committed new link is retried next claim.
 perform 1 from app_private.pipeline_papers where id=p_paper_id for update;
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if exists(select 1 from app_private.pipeline_imports where paper_id=p.id and not(account_id=any(locked_accounts))) then
  update app_private.pipeline_papers set next_attempt_at=clock_timestamp()+interval '1 second' where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('funding','waiting');
 end if;
 select * into strict pol from app_private.pipeline_policy;
 if p.stage<>'ocr_fund' then raise exception 'invalid_pipeline_stage'; end if;
 if p_page_limit is null or p_page_limit<1 or p_page_limit>least(p.page_count,pol.max_ocr_pages)
  or octet_length(p_options_sha256)<>32 or octet_length(p_request_sha256)<>32 then raise exception 'invalid_ocr_request'; end if;
 -- No document lock here (reservation takes budget -> account). The partial
 -- unique index on active attempts serializes funding of identical bytes.
 select ra.id into artifact from app_private.render_artifacts ra join app_private.ocr_runs r on r.id=ra.ocr_run_id
  join app_private.stored_objects mo on mo.id=ra.manifest_object_id
  where r.document_id=p.document_id and ra.renderer_version=pol.renderer_version and mo.state='verified' limit 1;
 if artifact is not null then
  update app_private.pipeline_papers set artifact_id=artifact where id=p.id;
  perform app_private.pipeline_set_stage(p.id,'done');
  select * into p from app_private.pipeline_papers where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('funding','reused');
 end if;
 -- Retained raw OCR (another slot, an earlier renderer) is re-rendered free.
 select r.id into raw_run from app_private.ocr_runs r join app_private.stored_objects o on o.id=r.raw_bundle_object_id
  where r.document_id=p.document_id and r.provider='mathpix' and o.state='verified' order by (r.options_sha256=p_options_sha256) desc limit 1;
 if raw_run is not null then
  update app_private.pipeline_papers set ocr_run_id=raw_run where id=p.id;
  perform app_private.pipeline_set_stage(p.id,'render');
  select * into p from app_private.pipeline_papers where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('funding','reused_raw');
 end if;
 -- Deterministic provider failures are not retried at platform cost forever.
 if (select count(*) from app_private.ocr_attempts where document_id=p.document_id and state='failed'
  and error_code in ('conversion_failed','conversion_timeout'))>=2 then
  perform app_private.pipeline_set_stage(p.id,'failed','conversion_failed');
  select * into p from app_private.pipeline_papers where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('funding','refused');
 end if;
 if exists(select 1 from app_private.ocr_attempts where document_id=p.document_id and state in ('funded','submitting','submitted','uncertain')) then
  -- Another source slot is converting identical bytes; wait for it.
  update app_private.pipeline_papers set next_attempt_at=clock_timestamp()+interval '15 seconds' where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('funding','waiting');
 end if;
 if not exists(select 1 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date and work_enabled) then
  update app_private.pipeline_papers set next_attempt_at=clock_timestamp()+interval '5 minutes',error_code='service_paused' where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('funding','paused');
 end if;
 insert into app_private.ocr_runs(document_id,provider,options_sha256) values(p.document_id,'mathpix',p_options_sha256)
  on conflict(document_id,provider,options_sha256) do nothing;
 select id into strict run from app_private.ocr_runs where document_id=p.document_id and provider='mathpix' and options_sha256=p_options_sha256;
 credits:=p_page_limit::bigint*pol.ocr_credits_per_page; microusd:=p_page_limit::bigint*pol.ocr_microusd_per_page;
 for candidate in select i.account_id from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
  where pi.paper_id=p.id and i.account_id=any(locked_accounts) and i.desired_present and i.phase in ('accepted','resolving','acquiring')
   and exists(select 1 from app_private.accounts a where a.id=i.account_id and a.closed_at is null and not a.spending_suspended)
  order by i.created_at,i.account_id loop
  op:=gen_random_uuid();
  begin
   perform public.worker_reserve_operation(candidate.account_id,op,'ocr',p_request_sha256,pol.rate_version,credits,microusd);
   insert into app_private.ocr_attempts(paper_id,document_id,ocr_run_id,funder_account_id,operation_id,page_limit,state)
    values(p.id,p.document_id,run,candidate.account_id,op,p_page_limit,'funded');
   funded:=true; exit;
  exception
   when others then
    if sqlerrm in ('platform_budget_exhausted','too_many_active_operations') then paused:=true;
    elsif sqlerrm<>'insufficient_credits' then raise; end if;
  end;
 end loop;
 if funded then
  update app_private.pipeline_papers set ocr_run_id=run where id=p.id;
  perform app_private.pipeline_set_stage(p.id,'ocr_submit');
 elsif paused then update app_private.pipeline_papers set next_attempt_at=clock_timestamp()+interval '5 minutes',error_code='service_paused' where id=p.id;
 else perform app_private.pipeline_set_stage(p.id,'needs_credits','insufficient_credits','ocr_fund'); end if;
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p)||jsonb_build_object('funding',case when funded then 'funded' when paused then 'paused' else 'needs_credits' end);
end $$;

-- Reviewed draft for insertion into provider accounting migration034.
-- Discovery is an unlocked, bounded snapshot. Lock accounts (including private
-- owners) first, then only still-due paper rows, then the short policy CAS.
-- Never discover a new account to lock after holding a paper or policy row.

create function app_private.pipeline_retry_lock_accounts(p_candidates jsonb,p_papers uuid[]) returns uuid[]
language plpgsql security definer set search_path='' as $$
declare captured uuid[]; locked uuid[];
begin
 select coalesce(array_agg(id order by id),'{}') into captured from (
  select c.account_id id from jsonb_to_recordset(p_candidates) as c(account_id uuid)
  union select owner_id from app_private.pipeline_papers where id=any(p_papers) and owner_id is not null
 ) a;
 -- Lock closed rows too: closure that won the race must finish before a
 -- private paper is touched. All individual import actions recheck open state.
 select coalesce(array_agg(id order by id),'{}') into locked from (
  select id from app_private.accounts where id=any(captured) order by id for no key update
 ) a;
 return locked;
end $$;

create function app_private.pipeline_retry_captured(p_candidates jsonb,p_locked_papers uuid[],p_heal boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare link record; outcome text; outcomes jsonb:='{}'; healed integer:=0; key text; listed boolean; paper uuid;
begin
 for link in select * from jsonb_to_recordset(p_candidates)
  as c(account_id uuid,import_id uuid,paper_id uuid,listed boolean) order by c.account_id,c.import_id loop
  listed:=link.paper_id=any(p_locked_papers);
  -- This exact account/import/paper was captured before the account locks.
  -- Links added or moved during the wait are left to a later sweep.
  if not exists(select 1 from app_private.import_requests i join app_private.pipeline_imports pi
   on (pi.account_id,pi.import_id)=(i.account_id,i.id)
   join app_private.accounts a on a.id=i.account_id and a.closed_at is null
   join app_private.pipeline_papers pp on pp.id=pi.paper_id
   where i.account_id=link.account_id and i.id=link.import_id and pi.paper_id=link.paper_id
    and i.phase='failed' and i.retryable and i.desired_present
    and (listed or (p_heal and pp.stage not in ('failed','needs_credits')))) then continue; end if;
  begin outcome:=app_private.pipeline_auto_retry_import(link.account_id,link.import_id);
  exception when others then outcome:='skipped';
  end;
  if listed then
   key:=link.paper_id::text;
   outcomes:=outcomes||jsonb_build_object(key,case when outcome='retried' or outcomes->>key='retried' then 'retried'
    when outcome='limited' or outcomes->>key='limited' then 'limited' else 'none' end);
  elsif outcome='retried' then healed:=healed+1;
  end if;
 end loop;
 -- A new/uncaptured interested account cannot be processed under held paper
 -- locks. Preserve a later retry instead of silently dropping its schedule.
 foreach paper in array p_locked_papers loop
  if coalesce(outcomes->>paper::text,'none')<>'retried' and exists(
   select 1 from app_private.pipeline_imports pi join app_private.import_requests i
    on (i.account_id,i.id)=(pi.account_id,pi.import_id)
   join app_private.accounts a on a.id=i.account_id and a.closed_at is null
   where pi.paper_id=paper and i.phase='failed' and i.retryable and i.desired_present)
  then outcomes:=outcomes||jsonb_build_object(paper::text,'limited'); end if;
 end loop;
 return jsonb_build_object('papers',outcomes,'healed',healed);
end $$;

create or replace function public.worker_pipeline_auto_retry(p_min_interval_seconds integer default 0,p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path='' as $$
declare discovered uuid[]; due uuid[]; accounts uuid[]; candidates jsonb; result jsonb; outcome text; paper uuid;
 retried integer:=0; postponed integer:=0;
begin
 if p_min_interval_seconds is null or p_min_interval_seconds not between 0 and 3600 or p_limit is null or p_limit not between 1 and 100
 then raise exception 'invalid_auto_retry_request'; end if;
 if not exists(select 1 from app_private.pipeline_policy where singleton and enabled
  and auto_retry_swept_at<=clock_timestamp()-make_interval(secs=>p_min_interval_seconds))
 then return jsonb_build_object('swept',false,'retried',0,'healed',0,'postponed',0); end if;
 select coalesce(array_agg(x.id order by x.id),'{}') into discovered from (
  select pp.id from app_private.pipeline_papers pp where pp.auto_retry_at<=clock_timestamp() and pp.stage='failed'
   and (pp.lease_until is null or pp.lease_until<=clock_timestamp()) order by pp.auto_retry_at,pp.id limit p_limit
 ) x;
 select coalesce(jsonb_agg(to_jsonb(c) order by c.account_id,c.import_id),'[]') into candidates
  from app_private.pipeline_retry_candidates(discovered,true) c;
 accounts:=app_private.pipeline_retry_lock_accounts(candidates,discovered);
 select coalesce(array_agg(x.id order by x.id),'{}') into due from (
  select pp.id from app_private.pipeline_papers pp where pp.id=any(discovered)
   and (pp.owner_id is null or pp.owner_id=any(accounts)) and pp.auto_retry_at<=clock_timestamp() and pp.stage='failed'
   and (pp.lease_until is null or pp.lease_until<=clock_timestamp()) order by pp.id for no key update skip locked
 ) x;
 -- Keep the throttling decision atomic, but take its mutex only after every
 -- account/paper needed by this finite sweep has been selected and locked.
 update app_private.pipeline_policy set auto_retry_swept_at=clock_timestamp()
  where singleton and enabled and auto_retry_swept_at<=clock_timestamp()-make_interval(secs=>p_min_interval_seconds);
 if not found then return jsonb_build_object('swept',false,'retried',0,'healed',0,'postponed',0); end if;
 result:=app_private.pipeline_retry_captured(candidates,due,true);
 foreach paper in array due loop
  outcome:=coalesce(result->'papers'->>paper::text,'none');
  update app_private.pipeline_papers set auto_retry_at=case when outcome='limited' then clock_timestamp()+interval '15 minutes' end,
   auto_retries=auto_retries+case when outcome='retried' then 1 else 0 end where id=paper;
  if outcome='retried' then retried:=retried+1; elsif outcome='limited' then postponed:=postponed+1; end if;
 end loop;
 return jsonb_build_object('swept',true,'retried',retried,'healed',(result->>'healed')::integer,'postponed',postponed);
end $$;

create or replace function public.worker_pipeline_retry_failed(p_deploy text,p_limit integer default 200) returns jsonb
language plpgsql security definer set search_path='' as $$
declare discovered uuid[]; papers uuid[]; accounts uuid[]; candidates jsonb; result jsonb;
begin
 if p_deploy is null or p_deploy !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$' or p_limit is null or p_limit not between 1 and 1000
 then raise exception 'invalid_retry_request'; end if;
 if not (select enabled from app_private.pipeline_policy) then return jsonb_build_object('enabled',false,'papers',0,'retried',0,'healed',0); end if;
 select coalesce(array_agg(x.id order by x.id),'{}') into discovered from (
  select pp.id from app_private.pipeline_papers pp where pp.stage='failed' and pp.resume_stage in ('metadata','download','render')
   and pp.error_code is distinct from 'too_large' and pp.deploy_retry is distinct from p_deploy
   and (pp.lease_until is null or pp.lease_until<=clock_timestamp()) order by pp.updated_at,pp.id limit p_limit
 ) x;
 select coalesce(jsonb_agg(to_jsonb(c) order by c.account_id,c.import_id),'[]') into candidates
  from app_private.pipeline_retry_candidates(discovered,true) c;
 accounts:=app_private.pipeline_retry_lock_accounts(candidates,discovered);
 select coalesce(array_agg(x.id order by x.id),'{}') into papers from (
  select pp.id from app_private.pipeline_papers pp where pp.id=any(discovered)
   and (pp.owner_id is null or pp.owner_id=any(accounts)) and pp.stage='failed' and pp.resume_stage in ('metadata','download','render')
   and pp.error_code is distinct from 'too_large' and pp.deploy_retry is distinct from p_deploy
   and (pp.lease_until is null or pp.lease_until<=clock_timestamp()) order by pp.id for no key update skip locked
 ) x;
 -- Match the automatic path's account -> paper -> policy order, and recheck
 -- pause after any lock wait before restarting imports.
 perform 1 from app_private.pipeline_policy where singleton and enabled for update;
 if not found then return jsonb_build_object('enabled',false,'papers',0,'retried',0,'healed',0); end if;
 result:=app_private.pipeline_retry_captured(candidates,papers,true);
 -- A bounded candidate snapshot or active-import quota can defer a paper.
 -- Do not spend its one-per-deploy opportunity when nothing restarted.
 update app_private.pipeline_papers set deploy_retry=p_deploy where id=any(papers)
  and coalesce(result->'papers'->>id::text,'none')<>'limited';
 return jsonb_build_object('enabled',true,'papers',cardinality(papers),
  'retried',(select count(*) from jsonb_each_text(result->'papers') e where e.value='retried'),
  'deferred',(select count(*) from jsonb_each_text(result->'papers') e where e.value='limited'),'healed',(result->>'healed')::integer);
end $$;

-- Retire the old rescan-after-paper-lock helper; public signatures and roles
-- stay unchanged. All new snapshot helpers are private implementation details.
drop function app_private.pipeline_retry_papers(uuid[],boolean);
revoke all on function app_private.pipeline_retry_lock_accounts(jsonb,uuid[]),
 app_private.pipeline_retry_captured(jsonb,uuid[],boolean) from public,anon,authenticated,service_role;


-- Existing paid submissions are liabilities, not fresh transport permissions.
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,
 reserved_units,state,provider_request_id,failure_code,pricing_snapshot,created_at)
select x.id,x.funder_account_id,x.operation_id,'mathpix','paper_ocr','v3/pdf',op.request_sha256,op.spend_ceiling_microusd,
 jsonb_build_object('pages',x.page_limit),'unknown',x.provider_job_id,'pre_accounting_submission',
 jsonb_build_object('version','legacy-ocr-held-20261007','credit_rate_version',op.rate_version,'page_microusd',5000),x.created_at
from app_private.ocr_attempts x join app_private.metered_operations op on (op.account_id,op.id)=(x.funder_account_id,x.operation_id)
where x.state in ('submitting','submitted','uncertain') and op.state<>'settled';
insert into app_private.provider_attempt_events(attempt_id,state,details)
select id,'unknown',jsonb_build_object('reason','pre_accounting_submission','ceiling_microusd',ceiling_microusd)
from app_private.provider_attempts where failure_code='pre_accounting_submission';
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,
 reserved_units,state,failure_code,pricing_snapshot,created_at)
select t.operation_id,t.operation_account_id,t.operation_id,'anthropic','catalog_tags','claude-haiku-4-5-20251001',op.request_sha256,
 op.spend_ceiling_microusd,'{"output_tokens":256}','unknown','pre_accounting_tag_claim',
 jsonb_build_object('version','legacy-tag-held-20261007','credit_rate_version',op.rate_version),op.created_at
from app_private.catalog_tags t join app_private.metered_operations op on (op.account_id,op.id)=(t.operation_account_id,t.operation_id)
where t.claim_id is not null and op.state<>'settled';
insert into app_private.provider_attempt_events(attempt_id,state,details)
select id,'unknown',jsonb_build_object('reason','pre_accounting_tag_claim','ceiling_microusd',ceiling_microusd)
from app_private.provider_attempts where failure_code='pre_accounting_tag_claim';
update app_private.metered_operations op set attempt_accounting=true where exists(
 select 1 from app_private.provider_attempts a where (a.account_id,a.operation_id)=(op.account_id,op.id));

-- Grant + mirror are one transaction. Never acquire operation/budget locks only
-- after the old begin function has already updated that operation.
create or replace function public.worker_pipeline_begin_submit(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; x app_private.ocr_attempts; op app_private.metered_operations; admission jsonb;
begin
 perform app_private.pipeline_money_lock(p_paper_id);
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'ocr_submit' then raise exception 'invalid_pipeline_stage'; end if;
 select * into strict x from app_private.ocr_attempts where paper_id=p.id and state in ('funded','submitting') for update;
 if x.state='submitting' then
  update app_private.ocr_attempts set state='uncertain',error_code='submission_unrecorded' where id=x.id;
  perform app_private.pipeline_set_stage(p.id,'ocr_uncertain','submission_uncertain');
  if exists(select 1 from app_private.provider_attempts where id=x.id and state='admitted') then
   perform public.worker_provider_attempt_finish(x.funder_account_id,x.operation_id,x.id,'unknown',null,null,'{}','submission_unrecorded');
  end if;
  select * into p from app_private.pipeline_papers where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('granted',false);
 end if;
 if not app_private.pipeline_interest(p.id,x.funder_account_id) then
  update app_private.ocr_attempts set state='failed',error_code='funder_withdrew',finished_at=clock_timestamp() where id=x.id;
  perform public.worker_settle_operation(x.funder_account_id,x.operation_id,0,0);
  perform app_private.pipeline_set_stage(p.id,'ocr_fund');
  select * into p from app_private.pipeline_papers where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('granted',false);
 end if;
 select * into strict op from app_private.metered_operations where account_id=x.funder_account_id and id=x.operation_id;
 -- A funded legacy attempt has no submission to repeat and may enter accounting.
 update app_private.metered_operations set attempt_accounting=true where account_id=x.funder_account_id and id=x.operation_id;
 admission:=public.worker_provider_attempt_begin(x.funder_account_id,x.operation_id,x.id,'mathpix','paper_ocr','v3/pdf',
  op.request_sha256,op.spend_ceiling_microusd,jsonb_build_object('pages',x.page_limit));
 if not (admission->>'granted')::boolean then
  update app_private.ocr_attempts set state='failed',error_code='provider_admission_refused',finished_at=clock_timestamp() where id=x.id;
  perform public.worker_settle_operation(x.funder_account_id,x.operation_id,0,0);
  perform app_private.pipeline_set_stage(p.id,'failed','service_paused','ocr_fund');
  select * into p from app_private.pipeline_papers where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('granted',false);
 end if;
 update app_private.ocr_attempts set state='submitting',submitted_at=clock_timestamp() where id=x.id;
 perform public.worker_mark_submitted(x.funder_account_id,x.operation_id);
 return app_private.pipeline_entry(p)||jsonb_build_object('granted',true,'attempt_id',x.id);
end $$;

alter function public.worker_pipeline_submitted(uuid,text,text) set schema app_private;
alter function app_private.worker_pipeline_submitted(uuid,text,text) rename to pipeline_submitted_before_034;
create function public.worker_pipeline_submitted(p_attempt_id uuid,p_provider_job_id text,p_uncertain_reason text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare x app_private.ocr_attempts; a app_private.provider_attempts; result jsonb;
begin
 select * into strict x from app_private.ocr_attempts where id=p_attempt_id;
 perform app_private.pipeline_money_lock(x.paper_id);
 result:=app_private.pipeline_submitted_before_034(p_attempt_id,p_provider_job_id,p_uncertain_reason);
 select * into a from app_private.provider_attempts where id=x.id;
 if found and p_provider_job_id is not null and a.provider_request_id is distinct from p_provider_job_id then
  if a.provider_request_id is not null then raise exception 'provider_job_conflict'; end if;
  update app_private.provider_attempts set provider_request_id=p_provider_job_id where id=x.id;
  insert into app_private.provider_attempt_events(attempt_id,state,details) values(x.id,'provider_identified',jsonb_build_object('provider_request_id',p_provider_job_id));
 elsif found and p_provider_job_id is null and a.state='admitted' then
  perform public.worker_provider_attempt_finish(x.funder_account_id,x.operation_id,x.id,'unknown',null,null,'{}','submission_unknown');
 end if;
 return result;
end $$;

create function public.worker_pipeline_ocr_uncertain(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_error_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; x app_private.ocr_attempts;
begin
 if p_error_code is null or p_error_code !~ '^[a-z_]{1,64}$' then raise exception 'invalid_uncertainty'; end if;
 perform app_private.pipeline_money_lock(p_paper_id);
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'ocr_wait' then raise exception 'invalid_pipeline_stage'; end if;
 select * into strict x from app_private.ocr_attempts where paper_id=p.id and state='submitted' for update;
 update app_private.ocr_attempts set state='uncertain',error_code=p_error_code where id=x.id;
 if exists(select 1 from app_private.provider_attempts where id=x.id and state='admitted') then
  perform public.worker_provider_attempt_finish(x.funder_account_id,x.operation_id,x.id,'unknown',x.provider_job_id,null,'{}',p_error_code);
 end if;
 update app_private.metered_operations set state='uncertain' where account_id=x.funder_account_id and id=x.operation_id and state<>'settled';
 perform app_private.pipeline_set_stage(p.id,'ocr_uncertain',p_error_code);
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

create or replace function app_private.pipeline_settle_ocr(x app_private.ocr_attempts,p_pages_billed integer,p_charge_customer boolean) returns void
language plpgsql security definer set search_path='' as $$
declare pol app_private.pipeline_policy; op app_private.metered_operations; a app_private.provider_attempts; credits bigint; microusd bigint;
begin
 select * into strict pol from app_private.pipeline_policy;
 select * into strict op from app_private.metered_operations where account_id=x.funder_account_id and id=x.operation_id;
 microusd:=p_pages_billed::bigint*pol.ocr_microusd_per_page;
 credits:=case when p_charge_customer then least(op.credit_ceiling,p_pages_billed::bigint*pol.ocr_credits_per_page) else 0 end;
 select * into a from app_private.provider_attempts where id=x.id;
 if found then
  if a.state='reconciled' then
   if a.actual_microusd<>microusd or coalesce((a.actual_units->>'pages')::bigint,-1)<>p_pages_billed then raise exception 'ocr_reconciliation_conflict'; end if;
  else
   perform public.worker_provider_attempt_finish(x.funder_account_id,x.operation_id,x.id,'succeeded',x.provider_job_id,microusd,
    jsonb_build_object('pages',p_pages_billed,'estimated',case when x.state='collected' then 0 else 1 end),null);
  end if;
 else
  perform public.worker_record_provider_usage(x.funder_account_id,x.operation_id,'mathpix',coalesce(x.provider_job_id,'legacy-attempt:'||x.id),
   'v3/pdf',jsonb_build_object('pages',p_pages_billed,'estimated',1),microusd);
 end if;
 perform public.worker_settle_operation(x.funder_account_id,x.operation_id,credits,microusd);
end $$;

alter function public.worker_pipeline_resolve_uncertain(uuid,text,integer) set schema app_private;
alter function app_private.worker_pipeline_resolve_uncertain(uuid,text,integer) rename to pipeline_resolve_before_034;
create function public.worker_pipeline_resolve_uncertain(p_attempt_id uuid,p_provider_job_id text,p_pages_billed integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare x app_private.ocr_attempts;
begin
 select * into strict x from app_private.ocr_attempts where id=p_attempt_id;
 perform app_private.pipeline_money_lock(x.paper_id);
 if p_provider_job_id is null and exists(select 1 from app_private.provider_attempts where id=x.id and state<>'reconciled')
 then raise exception 'provider_reconciliation_required'; end if;
 if p_provider_job_id is not null and x.provider_job_id is not null and x.provider_job_id<>p_provider_job_id then raise exception 'provider_job_conflict'; end if;
 return app_private.pipeline_resolve_before_034(p_attempt_id,p_provider_job_id,p_pages_billed);
end $$;

-- These existing stage implementations settle while holding paper/attempt rows.
-- Acquire their financial/account locks before entering them.
alter function public.worker_pipeline_collected(uuid,uuid,bigint,integer,bytea,bigint) set schema app_private;
alter function app_private.worker_pipeline_collected(uuid,uuid,bigint,integer,bytea,bigint) rename to pipeline_collected_before_034;
create function public.worker_pipeline_collected(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_pages_reported integer,
 p_raw_manifest_sha256 bytea,p_raw_manifest_bytes bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.pipeline_money_lock(p_paper_id);
 return app_private.pipeline_collected_before_034(p_paper_id,p_claim_id,p_generation,p_pages_reported,p_raw_manifest_sha256,p_raw_manifest_bytes);
end $$;
alter function public.worker_pipeline_ocr_failed(uuid,uuid,bigint,text,integer) set schema app_private;
alter function app_private.worker_pipeline_ocr_failed(uuid,uuid,bigint,text,integer) rename to pipeline_ocr_failed_before_034;
create function public.worker_pipeline_ocr_failed(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_error_code text,p_pages_billed integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare page_cap integer;
begin
 perform app_private.pipeline_money_lock(p_paper_id);
 select page_limit into page_cap from app_private.ocr_attempts where paper_id=p_paper_id and state='submitted';
 -- This endpoint is only for unusable output of a completed job. Its full
 -- provider-enforced page cap is expensed; partial progress never releases money.
 if p_pages_billed is distinct from page_cap then raise exception 'provider_reconciliation_required'; end if;
 return app_private.pipeline_ocr_failed_before_034(p_paper_id,p_claim_id,p_generation,p_error_code,p_pages_billed);
end $$;
alter function public.worker_pipeline_abandon_funding(uuid,uuid,bigint,text) set schema app_private;
alter function app_private.worker_pipeline_abandon_funding(uuid,uuid,bigint,text) rename to pipeline_abandon_before_034;
create function public.worker_pipeline_abandon_funding(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_error_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.pipeline_money_lock(p_paper_id);
 return app_private.pipeline_abandon_before_034(p_paper_id,p_claim_id,p_generation,p_error_code);
end $$;

-- Tag claim is already a one-shot grant, including its platform-funded hold.
update app_private.tag_policy set hold_microusd=40000;
alter function public.worker_tags_claim(uuid,integer,boolean,text) set schema app_private;
alter function app_private.worker_tags_claim(uuid,integer,boolean,text) rename to tags_claim_before_034;
create function public.worker_tags_claim(p_claim_id uuid,p_limit integer,p_model boolean,p_vocabulary text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; item jsonb; t app_private.catalog_tags; op app_private.metered_operations; admission jsonb; final_result jsonb:='[]';
begin
 result:=app_private.tags_claim_before_034(p_claim_id,p_limit,p_model,p_vocabulary);
 for item in select value from jsonb_array_elements(result) loop
  if (item->>'model')::boolean then
   select * into strict t from app_private.catalog_tags where version_id=(item->>'version_id')::uuid;
   select * into strict op from app_private.metered_operations where account_id=t.operation_account_id and id=t.operation_id;
   admission:=public.worker_provider_attempt_begin(t.operation_account_id,t.operation_id,t.operation_id,'anthropic','catalog_tags','claude-haiku-4-5-20251001',
    op.request_sha256,op.spend_ceiling_microusd,'{"output_tokens":256}');
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
alter function public.worker_tags_record(uuid,uuid,uuid,text[],text,text,text,bytea,text,jsonb,bigint,boolean) set schema app_private;
alter function app_private.worker_tags_record(uuid,uuid,uuid,text[],text,text,text,bytea,text,jsonb,bigint,boolean) rename to tags_record_before_034;
create function public.worker_tags_record(p_version_id uuid,p_claim_id uuid,p_metadata_id uuid,p_tags text[],p_method text,p_vocabulary text,
 p_model text,p_input_sha256 bytea,p_provider_event_id text,p_units jsonb,p_microusd bigint,p_model_attempted boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t app_private.catalog_tags; state text; units jsonb;
begin
 select * into t from app_private.catalog_tags where version_id=p_version_id for update;
 if not found or t.claim_id is distinct from p_claim_id then raise exception 'stale_tag_claim'; end if;
 if t.operation_id is not null and exists(select 1 from app_private.provider_attempts where id=t.operation_id) then
  state:=case when coalesce(p_units->>'estimated','false') in ('true','1') then 'unknown' when p_microusd>0 or p_provider_event_id is not null then 'succeeded' else 'rejected' end;
  units:=coalesce(p_units,'{}'::jsonb)-'estimated';
  if state='unknown' then units:=units||jsonb_build_object('estimated',1); end if;
  perform public.worker_provider_attempt_finish(t.operation_account_id,t.operation_id,t.operation_id,state,p_provider_event_id,
   case when state='unknown' then null else p_microusd end,units,case when state='unknown' then 'provider_usage_unknown' else null end);
 end if;
 return app_private.tags_record_before_034(p_version_id,p_claim_id,p_metadata_id,p_tags,p_method,p_vocabulary,p_model,p_input_sha256,
  p_provider_event_id,p_units,p_microusd,p_model_attempted);
end $$;

-- PostgREST exposes only these service functions; no table or legacy function
-- is accessible to a customer, nor is a reconciler callable with a customer JWT.
do $$
declare r record;
begin
 for r in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='app_private'
  and c.relkind='r' and c.relname in ('provider_spending_policy','provider_allowance_periods','provider_allowance_days','provider_attempts','provider_attempt_events','provider_attempt_adjustments') loop
  execute format('alter table app_private.%I enable row level security',r.relname);
  execute format('revoke all on app_private.%I from public,anon,authenticated,service_role',r.relname);
 end loop;
 for r in select p.oid::regprocedure signature,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where (n.nspname='app_private' and (p.proname like '%before_034' or p.proname in ('valid_provider_units','provider_lock_operation','provider_attempt_apply','pipeline_money_lock')))
   or (n.nspname='public' and p.proname in ('worker_reserve_operation','worker_settle_operation','worker_record_provider_usage','worker_admin_set_sign_in',
    'worker_provider_spending_policy','worker_provider_allowance_configure','worker_provider_attempt_begin','worker_provider_attempt_finish','worker_provider_attempt_reconcile',
    'worker_pipeline_begin_submit','worker_pipeline_submitted','worker_pipeline_ocr_uncertain','worker_pipeline_resolve_uncertain',
    'worker_pipeline_collected','worker_pipeline_ocr_failed','worker_pipeline_abandon_funding','worker_tags_claim','worker_tags_record')) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',r.signature);
  if r.nspname='public' then execute format('grant execute on function %s to service_role',r.signature); end if;
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
