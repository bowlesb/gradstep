begin;
create table app_private.plans (
  id text primary key,
  display_name text not null,
  active boolean not null default false
);
create table app_private.price_versions (
  id text primary key,
  plan_id text not null references app_private.plans(id),
  apple_product_id text not null unique,
  monthly_credits bigint not null check(monthly_credits>=0),
  effective_at timestamptz not null,
  rate_card jsonb not null
);
create table app_private.subscription_events (
  environment text not null check(environment in ('Sandbox','Production')),
  event_id text not null,
  original_transaction_id text not null,
  account_id uuid not null references app_private.accounts(id),
  signed_at timestamptz not null,
  received_at timestamptz not null default now(),
  payload_sha256 bytea not null check(octet_length(payload_sha256)=32),
  verified_payload jsonb not null,
  primary key(environment,event_id)
);
create table app_private.subscription_owners (
  environment text not null,
  original_transaction_id text not null,
  account_id uuid not null references app_private.accounts(id),
  primary key(environment,original_transaction_id),
  unique(environment,original_transaction_id,account_id)
);
alter table app_private.subscription_events add foreign key(environment,original_transaction_id,account_id)
 references app_private.subscription_owners(environment,original_transaction_id,account_id);
create table app_private.entitlements (
  account_id uuid not null references app_private.accounts(id),
  environment text not null,
  original_transaction_id text not null,
  product_id text not null references app_private.price_versions(apple_product_id),
  state text not null check(state in ('active','grace','expired','revoked')),
  expires_at timestamptz not null,
  verified_at timestamptz not null,
  source_signed_at timestamptz not null,
  primary key(environment,original_transaction_id),
  foreign key(environment,original_transaction_id,account_id) references app_private.subscription_owners(environment,original_transaction_id,account_id)
);
create table app_private.credit_buckets (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references app_private.accounts(id),
  source text not null check(source in ('subscription','purchased','trial','adjustment')),
  external_key text not null,
  starts_at timestamptz not null,
  expires_at timestamptz,
  revoked_at timestamptz,
  revocation_key text,
  balance bigint not null default 0 check(balance>=0),
  reserved bigint not null default 0 check(reserved>=0 and reserved<=balance),
  unique(source,external_key),
  unique(id,account_id),
  check(expires_at is null or expires_at>starts_at),
  check(source<>'purchased' or expires_at is null)
);
create index credit_account_active on app_private.credit_buckets(account_id,expires_at);
create table app_private.platform_budgets (
  period date primary key check(extract(day from period)=1),
  limit_microusd bigint not null check(limit_microusd>=0),
  spent_microusd bigint not null default 0 check(spent_microusd>=0),
  reserved_microusd bigint not null default 0 check(reserved_microusd>=0),
  work_enabled boolean not null default false,
  -- Actual bills may exceed estimates: record the truth and freeze new work.
  check(limit_microusd<=30000000)
);
create table app_private.metered_operations (
  account_id uuid not null references app_private.accounts(id),
  id uuid not null,
  kind text not null check(kind in ('chat','ocr','search','metadata','diagram')),
  request_sha256 bytea not null check(octet_length(request_sha256)=32),
  rate_version text not null,
  period date not null references app_private.platform_budgets(period),
  credit_ceiling bigint not null check(credit_ceiling>=0),
  spend_ceiling_microusd bigint not null check(spend_ceiling_microusd>=0),
  state text not null check(state in ('reserved','submitted','uncertain','settled')),
  actual_credits bigint check(actual_credits>=0 and actual_credits<=credit_ceiling),
  actual_microusd bigint check(actual_microusd>=0),
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  settled_at timestamptz,
  primary key(account_id,id),
  check((state='settled')=(settled_at is not null)),
  check(state<>'settled' or (actual_credits is not null and actual_microusd is not null))
);
create table app_private.reservation_allocations (
  account_id uuid not null,
  operation_id uuid not null,
  bucket_id uuid not null,
  credits bigint not null check(credits>0),
  primary key(account_id,operation_id,bucket_id),
  foreign key(account_id,operation_id) references app_private.metered_operations(account_id,id),
  foreign key(bucket_id,account_id) references app_private.credit_buckets(id,account_id)
);
create table app_private.credit_ledger (
  id bigint generated always as identity primary key,
  account_id uuid not null,
  bucket_id uuid not null,
  operation_id uuid,
  entry_key text not null,
  kind text not null check(kind in ('grant','hold','settle','adjustment')),
  balance_delta bigint not null,
  reserved_delta bigint not null,
  reason text not null,
  created_at timestamptz not null default now(),
  unique(bucket_id,entry_key),
  foreign key(bucket_id,account_id) references app_private.credit_buckets(id,account_id),
  foreign key(account_id,operation_id) references app_private.metered_operations(account_id,id)
);
create table app_private.provider_usage_events (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null,
  operation_id uuid not null,
  provider text not null,
  provider_event_id text not null,
  model text,
  units jsonb not null,
  estimated_microusd bigint not null check(estimated_microusd>=0),
  created_at timestamptz not null default now(),
  unique(provider,provider_event_id),
  foreign key(account_id,operation_id) references app_private.metered_operations(account_id,id)
);
create table app_private.provider_reconciliations (
  id uuid primary key default gen_random_uuid(),
  usage_event_id uuid not null references app_private.provider_usage_events(id),
  invoice_reference text not null unique,
  adjustment_microusd bigint not null,
  created_at timestamptz not null default now()
);
create function app_private.immutable_record() returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'immutable_record_requires_compensating_entry'; end $$;
create trigger credit_ledger_immutable before update or delete on app_private.credit_ledger for each row execute function app_private.immutable_record();
create trigger subscription_events_immutable before update or delete on app_private.subscription_events for each row execute function app_private.immutable_record();
create trigger provider_usage_immutable before update or delete on app_private.provider_usage_events for each row execute function app_private.immutable_record();
create trigger reconciliation_immutable before update or delete on app_private.provider_reconciliations for each row execute function app_private.immutable_record();
create trigger price_version_immutable before update or delete on app_private.price_versions for each row execute function app_private.immutable_record();

create function public.worker_grant_credits(p_account_id uuid,p_source text,p_external_key text,p_credits bigint,
 p_starts_at timestamptz,p_expires_at timestamptz,p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare b app_private.credit_buckets; granted bigint;
begin
 if p_credits is null or p_credits<0 or p_reason is null or length(p_reason)<3 then raise exception 'invalid_grant'; end if;
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null for update;
 if not found then raise exception 'account_unavailable'; end if;
 insert into app_private.credit_buckets(account_id,source,external_key,starts_at,expires_at)
 values(p_account_id,p_source,p_external_key,p_starts_at,p_expires_at) on conflict(source,external_key) do nothing;
 select * into strict b from app_private.credit_buckets where source=p_source and external_key=p_external_key for update;
 if b.account_id is distinct from p_account_id or b.starts_at is distinct from p_starts_at or b.expires_at is distinct from p_expires_at then raise exception 'grant_id_conflict'; end if;
 select balance_delta into granted from app_private.credit_ledger where bucket_id=b.id and entry_key='grant';
 if found then
   if granted<>p_credits then raise exception 'grant_id_conflict'; end if;
   return b.id;
 end if;
 update app_private.credit_buckets set balance=balance+p_credits where id=b.id;
 insert into app_private.credit_ledger(account_id,bucket_id,entry_key,kind,balance_delta,reserved_delta,reason)
 values(p_account_id,b.id,'grant','grant',p_credits,0,p_reason);
 return b.id;
end $$;

create function public.worker_reserve_operation(p_account_id uuid,p_id uuid,p_kind text,p_request_sha256 bytea,
 p_rate_version text,p_credits bigint,p_microusd bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare period_start date := date_trunc('month',now() at time zone 'UTC')::date;
 budget app_private.platform_budgets; op app_private.metered_operations; b app_private.credit_buckets; remaining bigint:=p_credits; held bigint;
begin
 if p_credits is null or p_microusd is null or p_credits<0 or p_microusd<0 then raise exception 'invalid_reservation'; end if;
 -- Uniform global->account->bucket lock order; no check-then-spend race.
 select * into strict budget from app_private.platform_budgets where period=period_start for update;
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null for update;
 if not found then raise exception 'account_unavailable'; end if;
 select * into op from app_private.metered_operations where account_id=p_account_id and id=p_id;
 if found then
  if op.kind is distinct from p_kind or op.request_sha256 is distinct from p_request_sha256 or op.rate_version is distinct from p_rate_version
    or op.credit_ceiling<>p_credits or op.spend_ceiling_microusd<>p_microusd then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('id',op.id,'state',op.state,'replayed',true);
 end if;
 if not budget.work_enabled or budget.spent_microusd+budget.reserved_microusd+p_microusd>budget.limit_microusd then raise exception 'platform_budget_exhausted'; end if;
 if (select count(*) from app_private.metered_operations where account_id=p_account_id and state<>'settled')>=3 then raise exception 'too_many_active_operations'; end if;
 insert into app_private.metered_operations(account_id,id,kind,request_sha256,rate_version,period,credit_ceiling,spend_ceiling_microusd,state)
 values(p_account_id,p_id,p_kind,p_request_sha256,p_rate_version,period_start,p_credits,p_microusd,'reserved');
 for b in select * from app_private.credit_buckets where account_id=p_account_id and revoked_at is null and starts_at<=now() and (expires_at is null or expires_at>now())
   and balance>reserved order by expires_at nulls last,id for update loop
  exit when remaining=0;
  held:=least(remaining,b.balance-b.reserved);
  update app_private.credit_buckets set reserved=reserved+held where id=b.id;
  insert into app_private.reservation_allocations values(p_account_id,p_id,b.id,held);
  insert into app_private.credit_ledger(account_id,bucket_id,operation_id,entry_key,kind,balance_delta,reserved_delta,reason)
    values(p_account_id,b.id,p_id,'hold:'||p_id,'hold',0,held,'Reserved before provider submission');
  remaining:=remaining-held;
 end loop;
 if remaining>0 then raise exception 'insufficient_credits'; end if;
 update app_private.platform_budgets set reserved_microusd=reserved_microusd+p_microusd where period=period_start;
 return jsonb_build_object('id',p_id,'state','reserved','replayed',false);
end $$;
create function public.worker_mark_submitted(p_account_id uuid,p_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
 update app_private.metered_operations set state='submitted',submitted_at=now() where account_id=p_account_id and id=p_id and state='reserved';
 return found;
end $$;
create function public.worker_settle_operation(p_account_id uuid,p_id uuid,p_actual_credits bigint,p_actual_microusd bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare op app_private.metered_operations; a record; remaining bigint:=p_actual_credits; captured bigint;
begin
 select * into strict op from app_private.metered_operations where account_id=p_account_id and id=p_id;
 perform 1 from app_private.platform_budgets where period=op.period for update;
 perform 1 from app_private.accounts where id=p_account_id for update;
 select * into strict op from app_private.metered_operations where account_id=p_account_id and id=p_id for update;
 if p_actual_credits is null or p_actual_credits<0 or p_actual_credits>op.credit_ceiling or p_actual_microusd is null or p_actual_microusd<0 then raise exception 'invalid_settlement'; end if;
 if op.state='settled' then
  if op.actual_credits<>p_actual_credits or op.actual_microusd<>p_actual_microusd then raise exception 'settlement_id_conflict'; end if;
  return;
 end if;
 for a in select ra.* from app_private.reservation_allocations ra join app_private.credit_buckets b on b.id=ra.bucket_id
  where ra.account_id=p_account_id and ra.operation_id=p_id order by b.expires_at nulls last,b.id loop
  captured:=least(remaining,a.credits);
  update app_private.credit_buckets set balance=balance-captured,reserved=reserved-a.credits where id=a.bucket_id;
  insert into app_private.credit_ledger(account_id,bucket_id,operation_id,entry_key,kind,balance_delta,reserved_delta,reason)
    values(p_account_id,a.bucket_id,p_id,'settle:'||p_id,'settle',-captured,-a.credits,'Actual consumption; unused hold released');
  remaining:=remaining-captured;
 end loop;
 update app_private.platform_budgets set spent_microusd=spent_microusd+p_actual_microusd,
  reserved_microusd=reserved_microusd-op.spend_ceiling_microusd,
  work_enabled=work_enabled and p_actual_microusd<=op.spend_ceiling_microusd where period=op.period;
 update app_private.metered_operations set state='settled',actual_credits=p_actual_credits,actual_microusd=p_actual_microusd,settled_at=now()
  where account_id=p_account_id and id=p_id;
end $$;
create function public.v1_credit_balance() returns jsonb language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('available',coalesce(sum(balance-reserved) filter(where revoked_at is null and starts_at<=now() and (expires_at is null or expires_at>now())),0),
  'reserved',coalesce(sum(reserved),0)) from app_private.credit_buckets where account_id=app_private.require_actor()
$$;

create table app_private.processing_jobs (
 id uuid primary key default gen_random_uuid(),
 ocr_run_id uuid not null unique references app_private.ocr_runs(id),
 funding_account_id uuid not null,
 operation_id uuid not null,
 state text not null default 'queued' check(state in ('queued','claimed','submitting','awaiting_provider','collecting','ready','retryable','failed','cancelled','submission_uncertain')),
 lease_generation bigint not null default 0,
 lease_until timestamptz,
 next_attempt_at timestamptz not null default now(),
 provider_job_id text,
 attempt_count integer not null default 0 check(attempt_count>=0),
 last_error_code text,
 created_at timestamptz not null default now(),
 foreign key(funding_account_id,operation_id) references app_private.metered_operations(account_id,id),
 check(state not in ('awaiting_provider','collecting','ready') or provider_job_id is not null)
);
create index processing_claim on app_private.processing_jobs(state,next_attempt_at,lease_until);
create table app_private.job_requests (
 job_id uuid not null references app_private.processing_jobs(id),
 account_id uuid not null references app_private.accounts(id),
 requested_at timestamptz not null default now(),
 primary key(job_id,account_id)
);
create table app_private.job_attempts (
 job_id uuid not null references app_private.processing_jobs(id),
 generation bigint not null,
 claimed_at timestamptz not null default now(),
 previous_state text not null,
 primary key(job_id,generation)
);
create function public.worker_claim_job() returns jsonb language plpgsql security definer set search_path = '' as $$
declare j app_private.processing_jobs;
begin
 -- An expired submit lease is ambiguous, so quarantine it instead of recharging.
 update app_private.processing_jobs set state='submission_uncertain',lease_until=null,
   last_error_code='submit_lease_expired' where state='submitting' and lease_until<now();
 select * into j from app_private.processing_jobs where state in ('queued','retryable','claimed','awaiting_provider','collecting')
  and next_attempt_at<=now() and (lease_until is null or lease_until<now()) and attempt_count<100
  order by next_attempt_at,id for update skip locked limit 1;
 if not found then return null; end if;
 insert into app_private.job_attempts(job_id,generation,previous_state) values(j.id,j.lease_generation+1,j.state);
 update app_private.processing_jobs set lease_generation=lease_generation+1,lease_until=now()+interval '60 seconds',
   state=case when state in ('queued','retryable','claimed') then 'claimed' else state end,attempt_count=attempt_count+1
   where id=j.id returning * into j;
 return to_jsonb(j);
end $$;
create function public.worker_transition_job(p_id uuid,p_generation bigint,p_expected text,p_next text,p_provider_job_id text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare j app_private.processing_jobs;
begin
 select * into strict j from app_private.processing_jobs where id=p_id for update;
 if j.lease_generation is distinct from p_generation or j.lease_until is null or j.lease_until<=now() or j.state is distinct from p_expected then raise exception 'stale_job_lease'; end if;
 if not coalesce(((p_expected='claimed' and p_next in ('submitting','failed','cancelled'))
  or (p_expected='submitting' and p_next in ('awaiting_provider','submission_uncertain'))
  or (p_expected='awaiting_provider' and p_next in ('awaiting_provider','collecting','failed'))
  or (p_expected='collecting' and p_next in ('collecting','ready'))),false) then raise exception 'invalid_job_transition'; end if;
 if j.provider_job_id is not null and p_provider_job_id is not null and j.provider_job_id<>p_provider_job_id then raise exception 'provider_job_conflict'; end if;
 if p_next='ready' and not exists(select 1 from app_private.render_artifacts where ocr_run_id=j.ocr_run_id) then raise exception 'artifact_not_ready'; end if;
 if p_next='submitting' then
  if not public.worker_mark_submitted(j.funding_account_id,j.operation_id) then raise exception 'operation_already_submitted'; end if;
 end if;
 update app_private.processing_jobs set state=p_next,provider_job_id=coalesce(provider_job_id,p_provider_job_id),
  lease_until=case when p_next in ('submitting','collecting') then lease_until else null end,
  next_attempt_at=now()+interval '10 seconds' where id=p_id;
 if p_provider_job_id is not null then
  update app_private.ocr_runs set provider_job_id=p_provider_job_id where id=j.ocr_run_id and (provider_job_id is null or provider_job_id=p_provider_job_id);
 end if;
end $$;

do $$ declare t record; f record; begin
 for t in select tablename from pg_tables where schemaname='app_private' loop
  execute format('alter table app_private.%I enable row level security',t.tablename);
 end loop;
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on p.pronamespace=n.oid
  where n.nspname='public' and p.proname like 'worker_%' loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;
revoke all on all functions in schema app_private from public,anon,authenticated;
revoke all on function public.v1_credit_balance() from public,anon;
grant execute on function public.v1_credit_balance() to authenticated;
commit;
