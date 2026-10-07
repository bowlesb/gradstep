-- Serialize free Sandbox allowances before ownership resolution. Production
-- purchasing is unchanged. No provider call or receipt verification is added.
begin;

alter table app_private.store_policy add constraint store_sandbox_finite_cap
 check(environment<>'Sandbox' or (monthly_credit_cap is not null and monthly_credit_cap between 0 and 1000));
alter table app_private.store_seen add column app_transaction_id text check(app_transaction_id ~ '^[0-9]{1,32}$');
update app_private.store_seen s set app_transaction_id=t.app_transaction_id
 from app_private.store_transactions t where s.environment='Sandbox' and t.environment=s.environment
 and t.transaction_id=s.transaction_id and t.app_transaction_id is not null;

create index store_sandbox_account_allowance on app_private.store_transactions(account_id,granted_at) include(credits)
 where environment='Sandbox' and credits>0;
create index store_sandbox_apple_allowance on app_private.store_transactions(app_transaction_id,granted_at) include(credits)
 where environment='Sandbox' and credits>0 and app_transaction_id is not null;

create table app_private.store_sandbox_decisions (
 transaction_id text not null check(transaction_id ~ '^[0-9]{1,32}$'),
 period date not null check(extract(day from period)=1),
 account_id uuid not null references app_private.accounts(id),
 app_transaction_id text check(app_transaction_id ~ '^[0-9]{1,32}$'),
 reason text not null check(reason in ('granted','partial_allowance','identity_missing','account_allowance_exhausted',
  'apple_allowance_exhausted','both_allowances_exhausted')),
 requested_credits bigint not null check(requested_credits>0),
 granted_credits bigint not null check(granted_credits between 0 and 1000),
 account_used_before bigint not null check(account_used_before>=0),
 identity_used_before bigint not null check(identity_used_before>=0),
 credit_cap bigint not null check(credit_cap between 0 and 1000),
 created_at timestamptz not null default clock_timestamp(),
 primary key(transaction_id,period,reason)
);
alter table app_private.store_sandbox_decisions enable row level security;
revoke all on app_private.store_sandbox_decisions from public,anon,authenticated,service_role;
create trigger store_sandbox_decision_immutable before update or delete on app_private.store_sandbox_decisions
 for each row execute function app_private.immutable_record();

-- The first known verified identity remains attached even to an unattributed
-- transaction. Missing fields cannot erase it; a later verified copy may fill NULL.
create function app_private.store_sandbox_identity_immutable() returns trigger language plpgsql set search_path='' as $$
begin
 if old.environment='Sandbox' and old.app_transaction_id is not null and new.app_transaction_id is distinct from old.app_transaction_id
 then raise exception 'store_transaction_conflict'; end if;
 return new;
end $$;
create trigger store_seen_sandbox_identity before update on app_private.store_seen
 for each row execute function app_private.store_sandbox_identity_immutable();
create trigger store_transaction_sandbox_identity before update on app_private.store_transactions
 for each row execute function app_private.store_sandbox_identity_immutable();

create or replace function app_private.store_grant(p_env text,p_tid text,p_otid text,p_account uuid,p_product text,p_quantity integer,
 p_purchased timestamptz,p_expires timestamptz,p_reason text,p_app_transaction text,out granted bigint,out bucket uuid)
language plpgsql security definer set search_path = '' as $$
declare product app_private.store_products; cap bigint; used bigint; earlier record;
 requested bigint; account_used bigint:=0; identity_used bigint:=0; decision text; identity text:=p_app_transaction;
 month_start timestamptz:=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC';
begin
 granted:=0; bucket:=null;
 select * into strict product from app_private.store_products where product_id=p_product;
 if product.kind='subscription' then
  if p_expires<=now() then return; end if;
  if app_private.store_replaced(p_env,p_tid,p_otid,p_product,p_purchased,p_expires) then return; end if;
 end if;
 granted:=product.credits*p_quantity; requested:=granted;
 select monthly_credit_cap into cap from app_private.store_policy where environment=p_env;
 if p_env='Sandbox' then
  -- The recording entry point already holds the Sandbox gate before ownership
  -- resolution. Previously verified identity may fill an omitted payload field.
  if identity is null then
   select app_transaction_id into identity from app_private.store_seen where environment=p_env and transaction_id=p_tid;
  end if;
  select coalesce(sum(credits),0) into account_used from app_private.store_transactions
   where environment='Sandbox' and account_id=p_account and granted_at>=month_start and credits>0;
  if identity is null then granted:=0; decision:='identity_missing';
  else
   select coalesce(sum(credits),0) into identity_used from app_private.store_transactions
    where environment='Sandbox' and app_transaction_id=identity and granted_at>=month_start and credits>0;
   granted:=least(granted,greatest(cap-account_used,0),greatest(cap-identity_used,0));
   decision:=case when granted=requested then 'granted' when granted>0 then 'partial_allowance'
    when account_used>=cap and identity_used>=cap then 'both_allowances_exhausted'
    when account_used>=cap then 'account_allowance_exhausted' else 'apple_allowance_exhausted' end;
  end if;
  insert into app_private.store_sandbox_decisions(transaction_id,period,account_id,app_transaction_id,reason,
   requested_credits,granted_credits,account_used_before,identity_used_before,credit_cap)
   values(p_tid,(month_start at time zone 'UTC')::date,p_account,identity,decision,requested,granted,account_used,identity_used,cap)
   on conflict(transaction_id,period,reason) do nothing;
 elsif cap is not null then
  -- Preserve the existing Production policy behavior; no Sandbox gate here.
  select coalesce(sum(credits),0) into used from app_private.store_transactions
   where environment=p_env and granted_at>=month_start
    and (account_id=p_account or (p_app_transaction is not null and app_transaction_id=p_app_transaction));
  granted:=least(granted,greatest(cap-used,0));
 end if;
 if granted=0 then return; end if;
 bucket:=public.worker_grant_credits(p_account,case when product.kind='credits' then 'purchased' else 'subscription' end,
  p_env||':'||p_tid,granted,least(p_purchased,now()),case when product.kind='subscription' then p_expires end,
  case when product.kind='credits' then 'App Store credit purchase' else 'App Store subscription allowance' end);
 if product.kind='subscription' and p_reason is distinct from 'RENEWAL' then
  for earlier in select s.bucket_id from app_private.store_transactions s where s.environment=p_env and s.original_transaction_id=p_otid
    and s.transaction_id<>p_tid and s.product_id<>p_product and s.bucket_id is not null and s.purchased_at<p_purchased
    and s.expires_at>p_purchased+interval '1 day' loop
   perform app_private.store_remove_unspent(earlier.bucket_id,'store-superseded:'||p_env||':'||p_tid,'App Store plan change; the earlier plan period ended');
  end loop;
 end if;
end $$;

-- One policy row is a deliberate low-volume Sandbox admission gate. Acquire it
-- BEFORE the unchanged transaction -> original owner -> account -> bucket order;
-- acquiring it inside store_grant would deadlock with a concurrent account owner.
alter function app_private.record_store_transaction(text,uuid,jsonb) rename to record_store_transaction_v018;
create function app_private.record_store_transaction(p_source text,p_account_id uuid,p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; prior_identity text; identity text:=p->>'app_transaction_id'; tid text:=p->>'transaction_id';
begin
 if p->>'environment' is distinct from 'Sandbox' then
  return app_private.record_store_transaction_v018(p_source,p_account_id,p);
 end if;
 perform 1 from app_private.store_policy where environment='Sandbox' for update;
 if not found then raise exception 'sandbox_policy_unavailable'; end if;
 -- Core validation still rejects malformed IDs and payloads transactionally.
 select app_transaction_id into prior_identity from app_private.store_seen where environment='Sandbox' and transaction_id=tid;
 if prior_identity is not null and identity is not null and prior_identity<>identity then raise exception 'store_transaction_conflict'; end if;
 identity:=coalesce(prior_identity,identity);
 if identity is not null then
  if identity !~ '^[0-9]{1,32}$' then raise exception 'invalid_store_transaction'; end if;
  p:=p||jsonb_build_object('app_transaction_id',identity);
  update app_private.store_seen set app_transaction_id=identity where environment='Sandbox' and transaction_id=tid and app_transaction_id is null;
 end if;
 result:=app_private.record_store_transaction_v018(p_source,p_account_id,p);
 if identity is not null then
  update app_private.store_seen set app_transaction_id=identity where environment='Sandbox' and transaction_id=tid and app_transaction_id is null;
  update app_private.store_transactions set app_transaction_id=identity where environment='Sandbox' and transaction_id=tid and app_transaction_id is null;
 end if;
 return result;
end $$;

-- Recompile both public entry points explicitly so no cached call bypasses the gate.
create or replace function public.worker_record_store_transaction(p_account_id uuid,p_transaction jsonb) returns jsonb
language sql security definer set search_path='' as $$
 select app_private.record_store_transaction('app',p_account_id,p_transaction)
$$;
create or replace function public.worker_record_store_notification(p_environment text,p_notification_uuid uuid,p_type text,p_subtype text,
 p_signed_at timestamptz,p_transaction jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare previous app_private.store_notifications; result jsonb:=jsonb_build_object('outcome','no_transaction');
begin
 if p_environment is null or p_environment not in ('Sandbox','Production') or p_notification_uuid is null or p_type is null
  or p_signed_at is null or p_signed_at>now()+interval '1 hour' then raise exception 'invalid_store_notification'; end if;
 select * into previous from app_private.store_notifications where environment=p_environment and notification_uuid=p_notification_uuid;
 if found then return jsonb_build_object('outcome',previous.outcome,'duplicate',true); end if;
 if p_transaction is not null then
  if p_transaction->>'environment' is distinct from p_environment then raise exception 'invalid_store_notification'; end if;
  result:=app_private.record_store_transaction('notification',null,p_transaction);
 end if;
 insert into app_private.store_notifications(environment,notification_uuid,notification_type,subtype,signed_at,transaction_id,outcome)
 values(p_environment,p_notification_uuid,p_type,p_subtype,p_signed_at,p_transaction->>'transaction_id',result->>'outcome')
 on conflict do nothing;
 return result;
end $$;

revoke all on function app_private.store_sandbox_identity_immutable(),
 app_private.record_store_transaction(text,uuid,jsonb),app_private.record_store_transaction_v018(text,uuid,jsonb),
 app_private.store_grant(text,text,text,uuid,text,integer,timestamptz,timestamptz,text,text) from public,anon,authenticated,service_role;
revoke all on function public.worker_record_store_transaction(uuid,jsonb),
 public.worker_record_store_notification(text,uuid,text,text,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function public.worker_record_store_transaction(uuid,jsonb),
 public.worker_record_store_notification(text,uuid,text,text,timestamptz,jsonb) to service_role;
notify pgrst,'reload schema';
commit;
