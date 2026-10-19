-- Authorized testing adjustments, not purchases or provider funding.
-- Design: SPENDING_CONTROLS.md, Unlimited owner testing.
begin;
set local lock_timeout='15s';

create table app_private.testing_allowances (
 account_id uuid primary key references app_private.accounts(id),
 enabled boolean not null,
 bucket_id uuid not null,
 updated_at timestamptz not null default now(),
 foreign key(bucket_id,account_id) references app_private.credit_buckets(id,account_id)
);
alter table app_private.testing_allowances enable row level security;
revoke all on app_private.testing_allowances from public,anon,authenticated,service_role;

create function public.worker_set_testing_allowance(p_account_id uuid,p_request_id uuid,p_enabled boolean,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare prior app_private.admin_audit_events; policy app_private.testing_allowances;
 b app_private.credit_buckets; bucket uuid; removed bigint;
begin
 if p_account_id is null or p_request_id is null or p_enabled is null or p_reason is null
  or length(btrim(p_reason)) not between 3 and 200 then raise exception 'invalid_testing_allowance'; end if;
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended for update;
 if not found then raise exception 'account_unavailable'; end if;
 select * into prior from app_private.admin_audit_events where id=p_request_id;
 if found then
  if prior.action<>'testing_allowance' or prior.target_id<>p_account_id::text or prior.reason<>p_reason
   or (prior.details->>'enabled')::boolean is distinct from p_enabled then raise exception 'request_id_conflict'; end if;
  return jsonb_build_object('replayed',true,'enabled',coalesce((select enabled from app_private.testing_allowances where account_id=p_account_id),false));
 end if;
 select * into policy from app_private.testing_allowances where account_id=p_account_id;
 bucket:=policy.bucket_id;
 if p_enabled and not coalesce(policy.enabled,false) then
  bucket:=public.worker_grant_credits(p_account_id,'adjustment','unlimited-testing:'||p_request_id,
   100000,now(),null,'Owner-authorized unlimited testing: '||p_reason);
 elsif not p_enabled and coalesce(policy.enabled,false) then
  select * into strict b from app_private.credit_buckets where id=bucket for update;
  removed:=b.balance-b.reserved;
  update app_private.credit_buckets set balance=reserved,revoked_at=now(),revocation_key='testing-disabled:'||p_request_id where id=bucket;
  insert into app_private.credit_ledger(account_id,bucket_id,entry_key,kind,balance_delta,reserved_delta,reason)
   values(p_account_id,bucket,'testing-disabled:'||p_request_id,'adjustment',-removed,0,'Testing allowance disabled; in-flight holds retained');
 end if;
 if bucket is not null then
  insert into app_private.testing_allowances(account_id,enabled,bucket_id) values(p_account_id,p_enabled,bucket)
   on conflict(account_id) do update set enabled=excluded.enabled,bucket_id=excluded.bucket_id,updated_at=now();
 end if;
 insert into app_private.admin_audit_events(id,actor_id,action,target_id,reason,details)
 values(p_request_id,p_account_id,'testing_allowance',p_account_id::text,p_reason,
  jsonb_build_object('enabled',p_enabled,'bucket_id',bucket,'authority','explicit-owner-direction','source','service-operator'));
 return jsonb_build_object('replayed',false,'enabled',p_enabled,'bucket_id',bucket);
end $$;
revoke all on function public.worker_set_testing_allowance(uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.worker_set_testing_allowance(uuid,uuid,boolean,text) to service_role;

-- Reserve testing credits before any purchased/plan balance; otherwise preserve migration 003.
create or replace function app_private.reserve_operation_before_034(p_account_id uuid,p_id uuid,p_kind text,p_request_sha256 bytea,
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
   and balance>reserved order by (id=coalesce((select t.bucket_id from app_private.testing_allowances t where t.account_id=p_account_id and t.enabled),'00000000-0000-0000-0000-000000000000'::uuid)) desc,expires_at nulls last,id for update loop
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

-- The reserve function remains the authority for replay, balance,
-- platform budget, active-operation count, allocations and spending suspension.
create or replace function public.worker_reserve_operation(p_account_id uuid,p_id uuid,p_kind text,p_request_sha256 bytea,
 p_rate_version text,p_credits bigint,p_microusd bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; b app_private.credit_buckets; refill bigint;
begin
 perform 1 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date for update;
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null for update;
 if not found then raise exception 'account_unavailable'; end if;
 if exists(select 1 from app_private.accounts where id=p_account_id and spending_suspended) then raise exception 'spending_suspended'; end if;
 if p_credits>0 and not exists(select 1 from app_private.metered_operations where account_id=p_account_id and id=p_id) then
  select cb.* into b from app_private.testing_allowances t join app_private.credit_buckets cb on cb.id=t.bucket_id
   where t.account_id=p_account_id and t.enabled and cb.revoked_at is null for update of cb;
  if found then
   refill:=greatest(0,greatest(100000,p_credits)-(b.balance-b.reserved));
   if refill>0 then
    update app_private.credit_buckets set balance=balance+refill where id=b.id;
   end if;
  end if;
 end if;
 result:=app_private.reserve_operation_before_034(p_account_id,p_id,p_kind,p_request_sha256,p_rate_version,p_credits,p_microusd);
 if refill>0 then
  insert into app_private.credit_ledger(account_id,bucket_id,operation_id,entry_key,kind,balance_delta,reserved_delta,reason)
  values(p_account_id,b.id,p_id,'testing-refill:'||p_id,'adjustment',refill,0,'Owner-authorized automatic testing refill before operation');
 end if;
 return result;
end $$;

create or replace function public.v1_credit_balance() returns jsonb
language sql stable security definer set search_path='' as $$
 with actor as (select app_private.require_actor() id)
 select jsonb_build_object(
  'available',coalesce(sum(balance-reserved) filter(where revoked_at is null and starts_at<=now() and (expires_at is null or expires_at>now())),0),
  'reserved',coalesce(sum(reserved),0),
  'unlimited_testing',exists(select 1 from app_private.testing_allowances t
   join app_private.accounts a on a.id=t.account_id
   where t.account_id=(select id from actor) and t.enabled and a.closed_at is null and not a.spending_suspended))
 from app_private.credit_buckets where account_id=(select id from actor)
$$;

notify pgrst,'reload schema';
commit;
