-- 0108: Indexes for the hot counts and a stale-hold sweep that cannot be blocked by operations it cannot settle (review
-- C7, 2026-10-21; design: docs/architecture/SPENDING_CONTROLS.md "Hot paths").
-- Before: every reservation counted an account's unsettled operations by scanning all of them under the budget lock;
-- every import began by counting active imports across the environment without an index; and
-- worker_expire_stale_chat_operations (every pipeline run) scanned all operations, always retried the same oldest 50
-- and swallowed every error, so 50 permanently failing operations blocked it and kept reserved_microusd inflated.
-- Now: partial indexes serve those counts and the sweep; the sweep records each failure (its SQLSTATE only), backs the
-- operation off (10 minutes doubling to a day) and moves on to the next; failing operations are counted for the budget
-- check. (Lifetime import counters are the retention policy of review E2, not changed here.)
begin;
set local lock_timeout='15s';

create index if not exists metered_operations_open_by_account on app_private.metered_operations(account_id) where state<>'settled';
create index if not exists metered_operations_open_chat on app_private.metered_operations(created_at) where kind='chat' and state<>'settled';
create index if not exists import_requests_active on app_private.import_requests(account_id)
 where desired_present and phase in ('accepted','resolving','acquiring');

create table app_private.stale_sweep_failures (
 account_id uuid not null,
 operation_id uuid not null,
 failures integer not null check(failures>=1),
 last_code text not null check(last_code ~ '^[A-Z0-9]{5}$'),
 next_at timestamptz not null,
 updated_at timestamptz not null default now(),
 primary key(account_id,operation_id),
 foreign key(account_id,operation_id) references app_private.metered_operations(account_id,id)
);
alter table app_private.stale_sweep_failures enable row level security;
revoke all on app_private.stale_sweep_failures from public,anon,authenticated;

-- As migration 079, skipping operations that failed recently and recording each failure instead of swallowing it.
create or replace function public.worker_expire_stale_chat_operations(p_older_than_minutes integer default 30) returns integer
language plpgsql security definer set search_path='' as $$
declare op record; n integer:=0; cost bigint;
begin
 if p_older_than_minutes is null or p_older_than_minutes<10 then raise exception 'invalid_age'; end if;
 for op in select m.account_id,m.id from app_private.metered_operations m
  where m.kind='chat' and m.state<>'settled' and m.created_at<now()-make_interval(mins=>p_older_than_minutes)
   and not exists(select 1 from app_private.stale_sweep_failures f where (f.account_id,f.operation_id)=(m.account_id,m.id) and f.next_at>now())
  order by m.created_at limit 50 loop
  begin
   perform public.worker_settle_operation(op.account_id,op.id,0,0);
   select coalesce(sum(case when state in ('admitted','unknown') then ceiling_microusd else coalesce(actual_microusd,0) end),0) into cost
    from app_private.provider_attempts where account_id=op.account_id and operation_id=op.id;
   insert into app_private.chat_endings(account_id,operation_id,action,ending,charged,credits,absorbed_microusd)
    values(op.account_id,op.id,'unknown','server',false,0,least(cost,1000000000)) on conflict do nothing;
   delete from app_private.stale_sweep_failures where (account_id,operation_id)=(op.account_id,op.id);
   n:=n+1;
  exception when others then
   insert into app_private.stale_sweep_failures as f(account_id,operation_id,failures,last_code,next_at)
   values(op.account_id,op.id,1,sqlstate,now()+interval '10 minutes')
   on conflict(account_id,operation_id) do update set failures=f.failures+1,last_code=excluded.last_code,
    next_at=now()+least(interval '1 day',interval '10 minutes'*power(2,least(f.failures,8))),updated_at=now();
  end;
 end loop;
 return n;
end $$;

create or replace function app_private.budget_health_extra() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('attempt_capacity_eighty_percent',coalesce((app_private.provider_attempt_window()->>'eighty_percent')::boolean,false),
  'tariffs_expiring_within_42d',jsonb_array_length(app_private.openrouter_tariff_attention()->'expiring'),
  'soonest_tariff_expiry',app_private.openrouter_tariff_attention()->'soonest_valid_until',
  'reconciliation',app_private.openrouter_reconcile_health(),
  'stale_sweep_failing',(select count(*) from app_private.stale_sweep_failures f join app_private.metered_operations m
   on (m.account_id,m.id)=(f.account_id,f.operation_id) where m.state<>'settled'))
$$;

notify pgrst,'reload schema';
commit;
