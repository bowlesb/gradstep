-- 0105: The owner testing allowance has an owner actor, a role check, a monthly spending cap, and ends with a suspension
-- (review A9, 2026-10-21; design: docs/architecture/SPENDING_CONTROLS.md "Unlimited owner testing", safeguards).
-- Before (migration 094): any service-role caller could give any account self-refilling credits; the audit row named the
-- target as its own actor with a hard-coded authority; disabling was refused for a suspended account, and re-enabling
-- sign-in silently restored unlimited credits; nothing capped one account's monthly spend inside the shared budget; Admin
-- showed ~100,000 credits with no marker.
-- Now: worker_set_testing_allowance takes the owner's account as actor (require_owner_account) and a reason; the target
-- must be an owner, a tester (app_roles) or a synthetic test account; disabling works whatever the account's state;
-- disabling sign-in also ends the allowance (audited to the same owner); each allowance carries a monthly provider-cost cap
-- (default $25, at most $50, the schema ceiling of a whole month) enforced at reservation; Admin › Accounts lists them.
-- The platform budget, holds and every other limit are unchanged.
begin;
set local lock_timeout='15s';

alter table app_private.testing_allowances add column monthly_cap_microusd bigint not null default 25000000
 check(monthly_cap_microusd between 0 and 50000000);

drop function public.worker_set_testing_allowance(uuid,uuid,boolean,text);

-- The core change (094's logic), audited to the acting owner. Enabling needs an open, unsuspended account; disabling
-- works in any state (it only removes unused testing credits; held work still settles).
create function app_private.testing_allowance_apply(p_actor_id uuid,p_request_id uuid,p_account_id uuid,p_enabled boolean,
 p_reason text,p_monthly_cap_microusd bigint,p_source text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare prior app_private.admin_audit_events; policy app_private.testing_allowances; b app_private.credit_buckets; bucket uuid; removed bigint;
 cap bigint;
begin
 perform app_private.require_owner_account(p_actor_id);
 if p_account_id is null or p_request_id is null or p_enabled is null or p_reason is null or length(btrim(p_reason)) not between 3 and 200
  or (p_monthly_cap_microusd is not null and p_monthly_cap_microusd not between 0 and 50000000) then raise exception 'invalid_testing_allowance'; end if;
 select * into prior from app_private.admin_audit_events where id=p_request_id;
 if found then
  if prior.action<>'testing_allowance' or prior.target_id<>p_account_id::text or prior.actor_id<>p_actor_id or prior.reason<>btrim(p_reason)
   or (prior.details->>'enabled')::boolean is distinct from p_enabled then raise exception 'request_id_conflict'; end if;
  return jsonb_build_object('replayed',true,'enabled',coalesce((select enabled from app_private.testing_allowances where account_id=p_account_id),false));
 end if;
 select * into policy from app_private.testing_allowances where account_id=p_account_id;
 if p_enabled then
  perform 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended for update;
  if not found then raise exception 'account_unavailable'; end if;
  if not exists(select 1 from app_private.app_roles where account_id=p_account_id and role in ('owner','tester'))
   and not app_private.is_test_account(p_account_id) then raise exception 'testing_allowance_role_required'; end if;
 else
  perform 1 from app_private.accounts where id=p_account_id for update;
  if not found then raise exception 'account_unavailable'; end if;
 end if;
 bucket:=policy.bucket_id;
 cap:=coalesce(p_monthly_cap_microusd,policy.monthly_cap_microusd,25000000);
 if p_enabled and not coalesce(policy.enabled,false) then
  bucket:=public.worker_grant_credits(p_account_id,'adjustment','unlimited-testing:'||p_request_id,
   100000,now(),null,'Owner-authorized unlimited testing: '||btrim(p_reason));
 elsif not p_enabled and coalesce(policy.enabled,false) then
  select * into strict b from app_private.credit_buckets where id=bucket for update;
  removed:=greatest(0,b.balance-b.reserved);
  update app_private.credit_buckets set balance=reserved,revoked_at=coalesce(revoked_at,now()),revocation_key=coalesce(revocation_key,'testing-disabled:'||p_request_id) where id=bucket;
  insert into app_private.credit_ledger(account_id,bucket_id,entry_key,kind,balance_delta,reserved_delta,reason)
   values(p_account_id,bucket,'testing-disabled:'||p_request_id,'adjustment',-removed,0,'Testing allowance disabled; in-flight holds retained');
 end if;
 if bucket is not null then
  insert into app_private.testing_allowances(account_id,enabled,bucket_id,monthly_cap_microusd) values(p_account_id,p_enabled,bucket,cap)
   on conflict(account_id) do update set enabled=excluded.enabled,bucket_id=excluded.bucket_id,monthly_cap_microusd=excluded.monthly_cap_microusd,updated_at=now();
 end if;
 insert into app_private.admin_audit_events(id,actor_id,action,target_id,reason,details)
 values(p_request_id,p_actor_id,'testing_allowance',p_account_id::text,btrim(p_reason),
  jsonb_build_object('enabled',p_enabled,'bucket_id',bucket,'monthly_cap_microusd',cap,'source',p_source));
 return jsonb_build_object('replayed',false,'enabled',p_enabled,'bucket_id',bucket,'monthly_cap_microusd',cap);
end $$;
revoke all on function app_private.testing_allowance_apply(uuid,uuid,uuid,boolean,text,bigint,text) from public,anon,authenticated,service_role;

create function public.worker_set_testing_allowance(p_actor_id uuid,p_request_id uuid,p_account_id uuid,p_enabled boolean,p_reason text,
 p_monthly_cap_microusd bigint default null) returns jsonb
language sql security definer set search_path='' as $$
 select app_private.testing_allowance_apply(p_actor_id,p_request_id,p_account_id,p_enabled,p_reason,p_monthly_cap_microusd,'admin-accounts')
$$;
revoke all on function public.worker_set_testing_allowance(uuid,uuid,uuid,boolean,text,bigint) from public,anon,authenticated;
grant execute on function public.worker_set_testing_allowance(uuid,uuid,uuid,boolean,text,bigint) to service_role;

-- Disabling sign-in ends the allowance too (re-enabling sign-in does not bring it back), audited to the same owner.
alter function public.worker_admin_set_sign_in(uuid,uuid,uuid,boolean,text) rename to admin_set_sign_in_before_0105;
alter function public.admin_set_sign_in_before_0105(uuid,uuid,uuid,boolean,text) set schema app_private;
revoke all on function app_private.admin_set_sign_in_before_0105(uuid,uuid,uuid,boolean,text) from public,anon,authenticated,service_role;
create function public.worker_admin_set_sign_in(p_actor_id uuid,p_request_id uuid,p_account_id uuid,p_disabled boolean,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=app_private.admin_set_sign_in_before_0105(p_actor_id,p_request_id,p_account_id,p_disabled,p_reason);
 if (result->>'disabled')::boolean and exists(select 1 from app_private.testing_allowances where account_id=p_account_id and enabled) then
  perform app_private.testing_allowance_apply(p_actor_id,gen_random_uuid(),p_account_id,false,
   left('Sign-in disabled: '||btrim(coalesce(p_reason,'')),200),null,'sign-in-disabled');
 end if;
 return result;
end $$;
revoke all on function public.worker_admin_set_sign_in(uuid,uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.worker_admin_set_sign_in(uuid,uuid,uuid,boolean,text) to service_role;

-- This month's provider cost of one account: what settled, what is still held, and unresolved liability.
create function app_private.account_month_spend(p_account_id uuid) returns bigint
language sql stable security definer set search_path='' as $$
 select coalesce(sum(case when state='settled' then coalesce(actual_microusd,0)+provider_liability_microusd else spend_ceiling_microusd end),0)::bigint
 from app_private.metered_operations where account_id=p_account_id and period=date_trunc('month',now() at time zone 'UTC')::date
$$;
revoke all on function app_private.account_month_spend(uuid) from public,anon,authenticated;

-- The cap: a new paid operation of an account with testing credits must fit the allowance's monthly provider cost.
-- Same lock order as the reservation (budget, then account), so concurrent reservations are counted in turn.
alter function public.worker_reserve_operation(uuid,uuid,text,bytea,text,bigint,bigint) rename to reserve_operation_before_0105;
alter function public.reserve_operation_before_0105(uuid,uuid,text,bytea,text,bigint,bigint) set schema app_private;
revoke all on function app_private.reserve_operation_before_0105(uuid,uuid,text,bytea,text,bigint,bigint) from public,anon,authenticated,service_role;
create function public.worker_reserve_operation(p_account_id uuid,p_id uuid,p_kind text,p_request_sha256 bytea,
 p_rate_version text,p_credits bigint,p_microusd bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t app_private.testing_allowances;
begin
 perform 1 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date for update;
 perform 1 from app_private.accounts where id=p_account_id for update;
 select * into t from app_private.testing_allowances where account_id=p_account_id and enabled;
 if found and coalesce(p_microusd,0)>0 and not exists(select 1 from app_private.metered_operations where account_id=p_account_id and id=p_id)
  and app_private.account_month_spend(p_account_id)+p_microusd>t.monthly_cap_microusd then
  raise exception 'testing_cap_reached';
 end if;
 return app_private.reserve_operation_before_0105(p_account_id,p_id,p_kind,p_request_sha256,p_rate_version,p_credits,p_microusd);
end $$;
revoke all on function public.worker_reserve_operation(uuid,uuid,text,bytea,text,bigint,bigint) from public,anon,authenticated;
grant execute on function public.worker_reserve_operation(uuid,uuid,text,bytea,text,bigint,bigint) to service_role;

-- Admin › Accounts: which accounts have the allowance, its cap and this month's spend (chained from 028's list).
alter function public.v1_admin_accounts(text,text,boolean,integer) rename to admin_accounts_before_0105;
alter function public.admin_accounts_before_0105(text,text,boolean,integer) set schema app_private;
revoke all on function app_private.admin_accounts_before_0105(text,text,boolean,integer) from public,anon,authenticated;
create function public.v1_admin_accounts(p_search text default null,p_sort text default 'created',p_ascending boolean default false,
 p_limit integer default 200) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb;
begin
 base:=app_private.admin_accounts_before_0105(p_search,p_sort,p_ascending,p_limit); -- owner + MFA checked there
 return base||jsonb_build_object('testing_allowances',coalesce((select jsonb_agg(jsonb_build_object('account_id',t.account_id,'enabled',t.enabled,
   'monthly_cap_microusd',t.monthly_cap_microusd,'month_spend_microusd',app_private.account_month_spend(t.account_id),'updated_at',t.updated_at)
   order by t.updated_at desc) from app_private.testing_allowances t),'[]'::jsonb));
end $$;
revoke all on function public.v1_admin_accounts(text,text,boolean,integer) from public,anon;
grant execute on function public.v1_admin_accounts(text,text,boolean,integer) to authenticated;

notify pgrst,'reload schema';
commit;
