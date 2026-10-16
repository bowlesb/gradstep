-- 079: Contain overruns; record how each paid answer ended and what Gradstep absorbed. Owner decisions 2026-10-16
-- (docs/architecture/RESILIENCE.md "Owner decisions", fix 1; docs/architecture/CHAT.md "When an answer stops early —
-- 2026-10-16"; docs/architecture/DATA_HANDLING_AND_COSTS.md). Additive: no row is changed or deleted; the three
-- functions that paused the month on a single overrun are redefined (bodies otherwise as migrations 003 and 034).
--
-- A. Overruns are contained (owner: "Yes, I agree with your suggestions"). An operation whose actual or uncertain
--    provider cost passes its ceiling no longer sets the month's work_enabled=false (migrations 003 and 034 did: one
--    late usage report or pricing slip paused every account's AI, the "AI answers are paused" of build 38). It is a
--    budget_anomaly row, shown in the admin's Health > Attention. The month pauses only when
--      (1) spent + reserved + a new hold would pass the month's limit (worker_reserve_operation, unchanged),
--      (2) more than 5 operations overran within one rolling hour (the tripwire, app_private.paid_work_guard), or
--      (3) an operator pauses it (unchanged).
--    The hard monthly limit is unchanged and never raised here.
-- B. Early endings (owner: "If we were charged by the provider, the onus is now on us to provide the value back"). The
--    reader pays for work that finishes, or for the part of an answer they chose to stop; anything else that ends it
--    early costs them nothing, and Gradstep's provider cost stays in the month's spend. worker_settle_chat settles a
--    chat operation and records its ending (app_private.chat_endings) in one transaction. A client that declares the
--    `stop_signal` capability records the reader's Stop (v1_chat_stop) before it closes the stream, so a dropped
--    connection is not charged as a Stop. Uncharged endings over 20 per account per UTC day raise an Attention row;
--    the reader is never blocked for them.
-- C. Drills: fault modes `midstream` and `slow`; a test account's synthetic attempts (provider request id `drill-…`)
--    can be reconciled to zero, since they never reached a provider.
begin;
set local lock_timeout='15s';

-- ---------------------------------------------------------------------------
-- The guard's numbers (owner decisions 2026-10-16), one row
-- ---------------------------------------------------------------------------
create table app_private.paid_work_guard (
  singleton boolean primary key default true check (singleton),
  -- The tripwire: more than this many operations over their ceiling within the window pauses the month.
  overrun_pause_after integer not null default 5 check (overrun_pause_after between 1 and 1000),
  overrun_window_minutes integer not null default 60 check (overrun_window_minutes between 5 and 1440),
  -- An account with more uncharged early endings than this in a UTC day is shown in Attention (never blocked).
  uncharged_endings_daily_attention integer not null default 20 check (uncharged_endings_daily_attention between 1 and 10000),
  updated_at timestamptz not null default now()
);
insert into app_private.paid_work_guard(singleton) values (true);
alter table app_private.paid_work_guard enable row level security;
revoke all on app_private.paid_work_guard from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- A. Budget anomalies
-- ---------------------------------------------------------------------------
-- One row per operation (and per attempt) whose provider cost passed its ceiling: what the ceiling was, the largest cost
-- seen, and whether this row tripped the month's pause. Financial evidence: kept with the operation, like its quote.
create table app_private.budget_anomalies (
  id uuid primary key default gen_random_uuid(),
  period date not null references app_private.platform_budgets(period),
  account_id uuid not null,
  operation_id uuid not null,
  attempt_id uuid references app_private.provider_attempts(id),
  kind text not null check (kind in ('attempt_over_ceiling', 'operation_over_ceiling')),
  ceiling_microusd bigint not null check (ceiling_microusd >= 0),
  observed_microusd bigint not null check (observed_microusd >= 0),
  test_account boolean not null default false,
  paused_month boolean not null default false,
  -- The statement's own time, so anomalies within one transaction keep their order for the tripwire.
  created_at timestamptz not null default clock_timestamp(),
  foreign key (account_id, operation_id) references app_private.metered_operations(account_id, id),
  check ((kind = 'attempt_over_ceiling') = (attempt_id is not null))
);
create unique index budget_anomaly_once on app_private.budget_anomalies(account_id, operation_id, kind,
  coalesce(attempt_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index budget_anomaly_time on app_private.budget_anomalies(created_at);
alter table app_private.budget_anomalies enable row level security;
revoke all on app_private.budget_anomalies from public, anon, authenticated;

-- How many operations count toward the tripwire now: those over their ceiling within the window (operations, not rows:
-- one operation's attempt and operation rows are one anomaly), counted afresh after the tripwire's last pause, so an
-- operator who resumes the month is not paused again by the next single anomaly.
create function app_private.anomalies_toward_tripwire() returns integer
language sql stable security definer set search_path='' as $$
 select count(distinct (b.account_id, b.operation_id))::integer from app_private.budget_anomalies b
 cross join app_private.paid_work_guard g
 where g.singleton and b.created_at > greatest(now() - make_interval(mins => g.overrun_window_minutes),
  coalesce((select max(p.created_at) from app_private.budget_anomalies p where p.paused_month), '-infinity'::timestamptz))
$$;
revoke all on function app_private.anomalies_toward_tripwire() from public, anon, authenticated;

-- Records (or raises the observed cost of) one anomaly; a new one counts toward the tripwire. Every caller already holds
-- the period's budget row (provider_lock_operation or settlement's lock order), so concurrent anomalies count in turn.
create function app_private.record_budget_anomaly(p_period date, p_account_id uuid, p_operation_id uuid, p_attempt_id uuid,
  p_kind text, p_ceiling bigint, p_observed bigint) returns void
language plpgsql security definer set search_path='' as $$
declare g app_private.paid_work_guard; new_id uuid;
begin
 update app_private.budget_anomalies set observed_microusd=greatest(observed_microusd, coalesce(p_observed, 0))
  where account_id=p_account_id and operation_id=p_operation_id and kind=p_kind and attempt_id is not distinct from p_attempt_id;
 if found then return; end if;
 insert into app_private.budget_anomalies(period, account_id, operation_id, attempt_id, kind, ceiling_microusd, observed_microusd, test_account)
 values (p_period, p_account_id, p_operation_id, p_attempt_id, p_kind, greatest(coalesce(p_ceiling, 0), 0), greatest(coalesce(p_observed, 0), 0),
  app_private.is_test_account(p_account_id))
 returning id into new_id;
 select * into strict g from app_private.paid_work_guard where singleton;
 if app_private.anomalies_toward_tripwire() > g.overrun_pause_after then
  update app_private.platform_budgets set work_enabled=false where period=p_period and work_enabled;
  if found then update app_private.budget_anomalies set paused_month=true where id=new_id; end if;
 end if;
end $$;
revoke all on function app_private.record_budget_anomaly(date, uuid, uuid, uuid, text, bigint, bigint) from public, anon, authenticated;

-- As migration 034, with an overrun recorded instead of pausing the month.
create or replace function app_private.provider_attempt_apply(p_attempt_id uuid,p_state text,p_request_id text,p_actual bigint,p_units jsonb,p_failure text)
returns void language plpgsql security definer set search_path='' as $$
declare a app_private.provider_attempts; op app_private.metered_operations; old_hold bigint; new_hold bigint;
 old_units bigint; new_units bigint; unit_hold bigint; known_delta bigint; total bigint;
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
 -- (079) An attempt over its own ceiling, or an operation whose attempts (known cost plus every unresolved ceiling) pass
 -- the operation's, is recorded and alerted. It pauses nothing by itself; the tripwire may.
 if coalesce(p_actual,0)>a.ceiling_microusd then
  perform app_private.record_budget_anomaly(op.period,a.account_id,a.operation_id,a.id,'attempt_over_ceiling',a.ceiling_microusd,p_actual);
 end if;
 select coalesce(sum(case when state in ('admitted','unknown') then ceiling_microusd else coalesce(actual_microusd,0) end),0) into total
  from app_private.provider_attempts where account_id=a.account_id and operation_id=a.operation_id;
 if total>op.spend_ceiling_microusd then
  perform app_private.record_budget_anomaly(op.period,a.account_id,a.operation_id,null,'operation_over_ceiling',op.spend_ceiling_microusd,total);
 end if;
 if p_actual is not null and a.actual_microusd is null then
  insert into app_private.provider_usage_events(account_id,operation_id,provider,provider_event_id,model,units,estimated_microusd)
  values(a.account_id,a.operation_id,a.provider,'attempt:'||a.id,a.model,p_units,p_actual);
 end if;
end $$;

-- As migration 003 (renamed by 034), with an overrun recorded instead of pausing the month.
create or replace function app_private.settle_operation_before_034(p_account_id uuid,p_id uuid,p_actual_credits bigint,p_actual_microusd bigint) returns void
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
  reserved_microusd=reserved_microusd-op.spend_ceiling_microusd where period=op.period;
 if p_actual_microusd>op.spend_ceiling_microusd then
  perform app_private.record_budget_anomaly(op.period,p_account_id,p_id,null,'operation_over_ceiling',op.spend_ceiling_microusd,p_actual_microusd);
 end if;
 update app_private.metered_operations set state='settled',actual_credits=p_actual_credits,actual_microusd=p_actual_microusd,settled_at=now()
  where account_id=p_account_id and id=p_id;
end $$;

-- As migration 034, with an overrun recorded instead of pausing the month.
create or replace function public.worker_settle_operation(p_account_id uuid,p_id uuid,p_actual_credits bigint,p_actual_microusd bigint) returns void
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
 update app_private.platform_budgets set reserved_microusd=reserved_microusd+liability where period=op.period;
 if known+liability>op.spend_ceiling_microusd then
  perform app_private.record_budget_anomaly(op.period,p_account_id,p_id,null,'operation_over_ceiling',op.spend_ceiling_microusd,known+liability);
 end if;
 update app_private.metered_operations set provider_liability_microusd=liability,settlement_reported_microusd=p_actual_microusd
  where account_id=p_account_id and id=p_id;
end $$;

-- ---------------------------------------------------------------------------
-- B. How each chat operation ended
-- ---------------------------------------------------------------------------
-- One row per settled chat operation (answer, selection actions, Study turn, equation view and its background, diagram
-- repair): its ending, whether the reader paid, and the provider cost Gradstep absorbed (every uncharged ending's whole
-- cost; a completed answer's undelivered title, suggestions or map). Codes and amounts only; kept with the operation.
create table app_private.chat_endings (
  account_id uuid not null,
  operation_id uuid not null,
  action text not null check (action in ('answer','ingest','related','relevance','diagram_fix','study','equation','equation_background','unknown')),
  ending text not null check (ending in ('completed','stopped','left','provider','server','limit','connection','refusal')),
  charged boolean not null,
  credits bigint not null check (credits >= 0),
  absorbed_microusd bigint not null default 0 check (absorbed_microusd between 0 and 1000000000),
  created_at timestamptz not null default now(),
  primary key (account_id, operation_id),
  foreign key (account_id, operation_id) references app_private.metered_operations(account_id, id),
  check (charged = (ending in ('completed','stopped','left'))),
  check (charged or credits = 0)
);
create index chat_endings_uncharged on app_private.chat_endings(created_at, account_id) where not charged;
create index chat_endings_time on app_private.chat_endings(created_at);
alter table app_private.chat_endings enable row level security;
revoke all on app_private.chat_endings from public, anon, authenticated;

-- The reader pressed Stop (their app says so before it closes the stream). One row per operation at most.
create table app_private.chat_stop_requests (
  account_id uuid not null,
  operation_id uuid not null,
  requested_at timestamptz not null default now(),
  primary key (account_id, operation_id),
  foreign key (account_id, operation_id) references app_private.metered_operations(account_id, id)
);
alter table app_private.chat_stop_requests enable row level security;
revoke all on app_private.chat_stop_requests from public, anon, authenticated;

-- The chat function's settlement: worker_settle_operation (unchanged amounts rule) and the ending, in one transaction.
-- An uncharged ending must charge nothing. Replaying the identical settlement is a no-op; a different one conflicts.
create function public.worker_settle_chat(p_account_id uuid, p_id uuid, p_actual_credits bigint, p_actual_microusd bigint,
  p_action text, p_ending text, p_absorbed_microusd bigint) returns void
language plpgsql security definer set search_path='' as $$
declare e app_private.chat_endings; is_charged boolean := p_ending in ('completed','stopped','left');
begin
 if p_action is null or p_action not in ('answer','ingest','related','relevance','diagram_fix','study','equation','equation_background')
  or p_ending is null or p_ending not in ('completed','stopped','left','provider','server','limit','connection','refusal')
  or p_absorbed_microusd is null or p_absorbed_microusd not between 0 and 1000000000
  or (not is_charged and p_actual_credits is distinct from 0) then raise exception 'invalid_settlement'; end if;
 if not exists (select 1 from app_private.metered_operations where account_id=p_account_id and id=p_id and kind='chat') then
  raise exception 'invalid_settlement';
 end if;
 perform public.worker_settle_operation(p_account_id, p_id, p_actual_credits, p_actual_microusd);
 select * into e from app_private.chat_endings where account_id=p_account_id and operation_id=p_id;
 if found then
  if (e.action, e.ending, e.credits, e.absorbed_microusd) is distinct from (p_action, p_ending, p_actual_credits, p_absorbed_microusd)
  then raise exception 'settlement_id_conflict'; end if;
  return;
 end if;
 insert into app_private.chat_endings(account_id, operation_id, action, ending, charged, credits, absorbed_microusd)
 values (p_account_id, p_id, p_action, p_ending, is_charged, p_actual_credits, p_absorbed_microusd);
end $$;

-- The reader's Stop, from their own app (authenticated): recorded only for one of their own chat operations; anything
-- else is answered without a record (the app then closes the stream as it would anyway).
create function public.v1_chat_stop(p_operation_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid := app_private.require_actor(); op app_private.metered_operations;
begin
 if p_operation_id is null then raise exception 'invalid_request'; end if;
 select * into op from app_private.metered_operations where account_id=a and id=p_operation_id and kind='chat';
 if not found then return jsonb_build_object('recorded', false); end if;
 insert into app_private.chat_stop_requests(account_id, operation_id) values (a, p_operation_id) on conflict do nothing;
 return jsonb_build_object('recorded', true, 'settled', op.state='settled');
end $$;

create function public.worker_chat_stop_requested(p_account_id uuid, p_operation_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists (select 1 from app_private.chat_stop_requests where account_id=p_account_id and operation_id=p_operation_id)
$$;

-- As migration 060, and a hold whose invocation died is recorded as our server's ending: nothing charged, its provider
-- cost (known, plus every unresolved ceiling) absorbed.
create or replace function public.worker_expire_stale_chat_operations(p_older_than_minutes integer default 30) returns integer
language plpgsql security definer set search_path='' as $$
declare op record; n integer:=0; cost bigint;
begin
 if p_older_than_minutes is null or p_older_than_minutes<10 then raise exception 'invalid_age'; end if;
 for op in select account_id,id from app_private.metered_operations
  where kind='chat' and state<>'settled' and created_at<now()-make_interval(mins=>p_older_than_minutes)
  order by created_at limit 50 loop
  begin
   perform public.worker_settle_operation(op.account_id,op.id,0,0);
   select coalesce(sum(case when state in ('admitted','unknown') then ceiling_microusd else coalesce(actual_microusd,0) end),0) into cost
    from app_private.provider_attempts where account_id=op.account_id and operation_id=op.id;
   insert into app_private.chat_endings(account_id,operation_id,action,ending,charged,credits,absorbed_microusd)
    values(op.account_id,op.id,'unknown','server',false,0,least(cost,1000000000)) on conflict do nothing;
   n:=n+1;
  exception when others then null;
  end;
 end loop;
 return n;
end $$;

-- An operation's settlement and ending, for drills and checks (service role): amounts, codes and anomalies only.
create function public.worker_operation_outcome(p_account_id uuid, p_operation_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind', op.kind, 'state', op.state, 'credit_ceiling', op.credit_ceiling, 'actual_credits', op.actual_credits,
   'spend_ceiling_microusd', op.spend_ceiling_microusd, 'actual_microusd', op.actual_microusd,
   'provider_liability_microusd', op.provider_liability_microusd, 'settlement_reported_microusd', op.settlement_reported_microusd,
   'ending', e.ending, 'charged', e.charged, 'credits', e.credits, 'absorbed_microusd', e.absorbed_microusd, 'action', e.action,
   'stop_requested', exists (select 1 from app_private.chat_stop_requests s where (s.account_id, s.operation_id)=(op.account_id, op.id)),
   'attempts', (select coalesce(jsonb_agg(jsonb_build_object('state', a.state, 'provider', a.provider, 'model', a.model,
      'ceiling_microusd', a.ceiling_microusd, 'actual_microusd', a.actual_microusd, 'drill', coalesce(a.provider_request_id like 'drill-%', false))
      order by a.created_at), '[]'::jsonb) from app_private.provider_attempts a where (a.account_id, a.operation_id)=(op.account_id, op.id)),
   'anomalies', (select coalesce(jsonb_agg(jsonb_build_object('kind', b.kind, 'ceiling_microusd', b.ceiling_microusd,
      'observed_microusd', b.observed_microusd, 'paused_month', b.paused_month, 'test_account', b.test_account) order by b.created_at), '[]'::jsonb)
      from app_private.budget_anomalies b where (b.account_id, b.operation_id)=(op.account_id, op.id)))
 from app_private.metered_operations op left join app_private.chat_endings e on (e.account_id, e.operation_id)=(op.account_id, op.id)
 where op.account_id=p_account_id and op.id=p_operation_id
$$;

-- As migration 060, with the anomaly tripwire and today's uncharged endings for the scheduled budget check.
create or replace function public.worker_budget_health() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce((select jsonb_build_object('period',b.period,'limit_microusd',b.limit_microusd,'spent_microusd',b.spent_microusd,
   'reserved_microusd',b.reserved_microusd,'work_enabled',b.work_enabled,
   'next_period_exists',exists(select 1 from app_private.platform_budgets n where n.period=(b.period+interval '1 month')::date),
   'unknown_attempts_over_1h',(select count(*) from app_private.provider_attempts a where a.state='unknown' and a.created_at<now()-interval '1 hour'),
   'open_operations_over_1h',(select count(*) from app_private.metered_operations o where o.state<>'settled' and o.created_at<now()-interval '1 hour'),
   'overrun_pause_after',g.overrun_pause_after,'overrun_window_minutes',g.overrun_window_minutes,
   'anomalies_in_window',app_private.anomalies_toward_tripwire(),
   'anomalies_24h',(select count(distinct (x.account_id,x.operation_id)) from app_private.budget_anomalies x where x.created_at>now()-interval '24 hours'),
   'paused_by_tripwire',exists(select 1 from app_private.budget_anomalies x where x.period=b.period and x.paused_month) and not b.work_enabled,
   'uncharged_endings_today',(select count(*) from app_private.chat_endings c where not c.charged
     and c.created_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'),
   'absorbed_microusd_today',(select coalesce(sum(c.absorbed_microusd),0) from app_private.chat_endings c
     where c.created_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'))
  from app_private.platform_budgets b cross join app_private.paid_work_guard g where b.period=date_trunc('month',now() at time zone 'UTC')::date and g.singleton),
  jsonb_build_object('period',null,'missing',true))
$$;

-- ---------------------------------------------------------------------------
-- The owner's Health tab: anomalies and early endings
-- ---------------------------------------------------------------------------
alter function public.v1_admin_health(integer) rename to admin_health_before_079;
alter function public.admin_health_before_079(integer) set schema app_private;
revoke all on function app_private.admin_health_before_079(integer) from public, anon, authenticated;

-- `anomalies`: operations over their ceiling (the tripwire's count, the last day's, the latest few, which paused the month).
-- `early_endings`: chat answers by how they ended over the window, what Gradstep absorbed, today's uncharged ones, and the
-- accounts over the daily Attention number (real accounts only; test accounts are drills and checks).
create function public.v1_admin_health(p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb; today date := (now() at time zone 'UTC')::date; since date; g app_private.paid_work_guard;
begin
 base := app_private.admin_health_before_079(p_days);
 since := today - (p_days - 1);
 select * into strict g from app_private.paid_work_guard where singleton;
 return base || jsonb_build_object(
  'anomalies', jsonb_build_object(
   'pause_after', g.overrun_pause_after, 'window_minutes', g.overrun_window_minutes,
   'in_window', app_private.anomalies_toward_tripwire(),
   'last_24h', (select count(distinct (account_id, operation_id)) from app_private.budget_anomalies where created_at > now() - interval '24 hours'),
   'last_24h_test', (select count(distinct (account_id, operation_id)) from app_private.budget_anomalies where created_at > now() - interval '24 hours' and test_account),
   'recent', (select coalesce(jsonb_agg(r.item order by r.at desc), '[]'::jsonb) from (
     select b.created_at as at, jsonb_build_object('at', b.created_at, 'kind', b.kind, 'operation_kind', m.kind,
       'ceiling_microusd', b.ceiling_microusd, 'observed_microusd', b.observed_microusd, 'paused_month', b.paused_month,
       'test_account', b.test_account) as item
     from app_private.budget_anomalies b join app_private.metered_operations m on (m.account_id, m.id) = (b.account_id, b.operation_id)
     where b.created_at > now() - interval '24 hours' order by b.created_at desc limit 10) r)),
  'early_endings', (with e as (
     select c.*, (c.created_at at time zone 'UTC')::date as day from app_private.chat_endings c
     where c.created_at >= (since::timestamp at time zone 'UTC')),
    real as (select a.id from app_private.accounts a join auth.users u on u.id = a.auth_user_id
     where a.closed_at is null and not (lower(coalesce(u.email, '')) like '%@example.invalid' or lower(coalesce(u.email, '')) like '%@example.test'))
   select jsonb_build_object(
    'attention_daily', g.uncharged_endings_daily_attention,
    'answers', (select count(*) from e),
    'uncharged', (select count(*) from e where not charged),
    'absorbed_microusd', (select coalesce(sum(absorbed_microusd), 0) from e),
    'by_ending', (select coalesce(jsonb_object_agg(ending, n), '{}'::jsonb) from (select ending, count(*) n from e group by 1) x),
    'today', jsonb_build_object('uncharged', (select count(*) from e where day = today and not charged),
      'absorbed_microusd', (select coalesce(sum(absorbed_microusd), 0) from e where day = today)),
    'accounts_over_today', (select coalesce(jsonb_agg(jsonb_build_object('account_id', x.account_id, 'uncharged', x.n, 'absorbed_microusd', x.absorbed)
       order by x.n desc), '[]'::jsonb) from (
      select e.account_id, count(*) n, sum(e.absorbed_microusd) absorbed from e join real r on r.id = e.account_id
      where e.day = today and not e.charged group by e.account_id having count(*) > g.uncharged_endings_daily_attention
      order by count(*) desc limit 10) x))));
end $$;
revoke all on function public.v1_admin_health(integer) from public, anon;
grant execute on function public.v1_admin_health(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- C. Drills: streamed fault modes; a test account's synthetic attempts reconciled to zero
-- ---------------------------------------------------------------------------
alter table app_private.fault_injection drop constraint fault_injection_mode_check;
alter table app_private.fault_injection add constraint fault_injection_mode_check
 check (mode in ('throttle','overload','error','timeout','malformed','midstream','slow'));

-- A drill's synthetic answers never reached a provider: their attempts (provider request id `drill-…`, on a test account
-- only) are reconciled to zero with the same evidence trail as an operator's reconciliation (actor: none, the drill).
-- Releases their held ceilings and any synthetic cost from the month. A real reader's attempts are never touched.
create function public.worker_fault_drill_reconcile(p_account_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare a app_private.provider_attempts; n integer := 0; released bigint; usage_id uuid; adjustment uuid;
begin
 if not app_private.is_test_account(p_account_id) then raise exception 'fault_target_not_test_account' using errcode = '42501'; end if;
 for a in select * from app_private.provider_attempts where account_id=p_account_id and provider_request_id like 'drill-%'
   and state in ('admitted','unknown','succeeded') order by created_at loop
  released := case when a.state in ('admitted','unknown') then a.ceiling_microusd else 0 end;
  select id into usage_id from app_private.provider_usage_events where provider=a.provider and provider_event_id='attempt:'||a.id;
  perform app_private.provider_attempt_apply(a.id, 'reconciled', null, 0, '{}'::jsonb, null);
  adjustment := gen_random_uuid();
  insert into app_private.provider_attempt_adjustments(id, attempt_id, actor_id, before_microusd, after_microusd, released_liability_microusd,
   units, evidence_reference, reason)
  values (adjustment, a.id, null, coalesce(a.actual_microusd, 0), 0, released, '{}'::jsonb, 'fault-drill:synthetic',
   'Synthetic fault-drill answer; it never reached the provider');
  if usage_id is not null and coalesce(a.actual_microusd, 0) <> 0 then
   insert into app_private.provider_reconciliations(usage_event_id, invoice_reference, adjustment_microusd)
   values (usage_id, 'attempt-adjustment:'||adjustment, -coalesce(a.actual_microusd, 0));
  end if;
  insert into app_private.provider_attempt_events(attempt_id, state, details)
  values (a.id, 'reconciled', jsonb_build_object('adjustment_id', adjustment, 'actual_microusd', 0, 'evidence_reference', 'fault-drill:synthetic'));
  n := n + 1;
 end loop;
 return n;
end $$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function public.worker_settle_chat(uuid, uuid, bigint, bigint, text, text, bigint) from public, anon, authenticated;
revoke all on function public.worker_chat_stop_requested(uuid, uuid) from public, anon, authenticated;
revoke all on function public.worker_operation_outcome(uuid, uuid) from public, anon, authenticated;
revoke all on function public.worker_fault_drill_reconcile(uuid) from public, anon, authenticated;
grant execute on function public.worker_settle_chat(uuid, uuid, bigint, bigint, text, text, bigint) to service_role;
grant execute on function public.worker_chat_stop_requested(uuid, uuid) to service_role;
grant execute on function public.worker_operation_outcome(uuid, uuid) to service_role;
grant execute on function public.worker_fault_drill_reconcile(uuid) to service_role;
revoke all on function public.v1_chat_stop(uuid) from public, anon;
grant execute on function public.v1_chat_stop(uuid) to authenticated;
notify pgrst, 'reload schema';
commit;
