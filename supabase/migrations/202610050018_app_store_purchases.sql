-- App Store purchases (owner decision 2026-10-05): Standard $9.99 = 800 credits
-- a month, Pro $19.99 = 1,800, a $4.99 pack = 400 credits that never expire.
--
-- Every verified App Store transaction (a subscription purchase or renewal, or a
-- credit pack) grants at most one credit bucket, once. The newest signed copy of
-- a transaction decides its refund state: a refund removes that bucket's unspent
-- credits (holds in flight are kept); a reversed refund restores them, or grants
-- them if the purchase was first seen refunded. An upgrade ends the earlier
-- plan's period. Sandbox (free) purchases are capped per account per month.
-- Signature, bundle and environment checks happen in the Edge function before
-- these service-only functions are called.
--
-- Supersedes migration 007's worker_record_subscription (one mutable entitlement
-- ordered by signing time, which a re-signed older transaction could regress);
-- its tables stay, unused, like 011's.
begin;

drop function public.worker_record_subscription(uuid,text,text,text,timestamptz,text,text,timestamptz,timestamptz,timestamptz,jsonb);

create table app_private.store_products (
 product_id text primary key check(product_id ~ '^com\.sciencereader\.ios\.[a-z0-9.]{1,60}$'),
 kind text not null check(kind in ('subscription','credits')),
 plan text check((kind='subscription')=(plan is not null)),
 credits bigint not null check(credits>0 and credits<=100000),
 active boolean not null default true
);
alter table app_private.store_products enable row level security;
insert into app_private.store_products values
 ('com.sciencereader.ios.standard.monthly','subscription','standard',800,true),
 ('com.sciencereader.ios.pro.monthly','subscription','pro',1800,true),
 ('com.sciencereader.ios.credits.400','credits',null,400,true);

-- The account an App Store purchase (its original transaction) belongs to,
-- bound on first verified sight: from the app, the signed-in account; from a
-- notification, the purchase's appAccountToken.
create table app_private.store_owners (
 environment text not null check(environment in ('Sandbox','Production')),
 original_transaction_id text not null check(original_transaction_id ~ '^[0-9]{1,32}$'),
 account_id uuid not null references app_private.accounts(id),
 bound_at timestamptz not null default now(),
 bound_by text not null check(bound_by in ('app','notification')),
 -- A deleted account's purchase moves to the account that next restores it.
 previous_account_id uuid references app_private.accounts(id),
 primary key(environment,original_transaction_id)
);
alter table app_private.store_owners enable row level security;
create index store_owners_account on app_private.store_owners(account_id);

create table app_private.store_transactions (
 environment text not null,
 transaction_id text not null check(transaction_id ~ '^[0-9]{1,32}$'),
 original_transaction_id text not null,
 account_id uuid not null references app_private.accounts(id),
 product_id text not null references app_private.store_products(product_id),
 quantity integer not null check(quantity between 1 and 10),
 purchased_at timestamptz not null,
 expires_at timestamptz check(expires_at is null or expires_at>purchased_at),
 revoked_at timestamptz,
 signed_at timestamptz not null,
 credits bigint not null check(credits>=0),
 bucket_id uuid,
 granted_at timestamptz,
 -- Apple's reason (PURCHASE: bought, including an upgrade; RENEWAL) and the
 -- Apple Account's app transaction (one per Apple Account per app).
 reason text check(reason is null or reason in ('PURCHASE','RENEWAL')),
 app_transaction_id text check(app_transaction_id ~ '^[0-9]{1,32}$'),
 recorded_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 primary key(environment,transaction_id),
 foreign key(environment,original_transaction_id) references app_private.store_owners(environment,original_transaction_id),
 foreign key(bucket_id,account_id) references app_private.credit_buckets(id,account_id),
 check((bucket_id is null)=(credits=0) and (bucket_id is null)=(granted_at is null))
);
alter table app_private.store_transactions enable row level security;
create index store_transactions_account on app_private.store_transactions(account_id,expires_at);
create index store_transactions_original on app_private.store_transactions(environment,original_transaction_id);
create index store_transactions_app_transaction on app_private.store_transactions(environment,app_transaction_id) where app_transaction_id is not null;

-- The newest verified copy of every transaction seen, attributed or not, so a
-- later report of an older copy can never undo a refund.
create table app_private.store_seen (
 environment text not null check(environment in ('Sandbox','Production')),
 transaction_id text not null check(transaction_id ~ '^[0-9]{1,32}$'),
 original_transaction_id text not null check(original_transaction_id ~ '^[0-9]{1,32}$'),
 signed_at timestamptz not null,
 expires_at timestamptz,
 revoked_at timestamptz,
 primary key(environment,transaction_id)
);
alter table app_private.store_seen enable row level security;

-- Sandbox purchases (TestFlight, sandbox testers) cost nothing, so the credits
-- they grant are capped per UTC month, per account and per Apple Account.
-- Production is uncapped.
create table app_private.store_policy (
 environment text primary key check(environment in ('Sandbox','Production')),
 monthly_credit_cap bigint check(monthly_credit_cap is null or monthly_credit_cap>=0)
);
alter table app_private.store_policy enable row level security;
insert into app_private.store_policy values('Sandbox',1000),('Production',null);

create table app_private.store_notifications (
 environment text not null check(environment in ('Sandbox','Production')),
 notification_uuid uuid not null,
 notification_type text not null check(length(notification_type) between 1 and 64),
 subtype text check(length(subtype) between 1 and 64),
 signed_at timestamptz not null,
 transaction_id text,
 outcome text not null,
 received_at timestamptz not null default now(),
 primary key(environment,notification_uuid)
);
alter table app_private.store_notifications enable row level security;
create trigger store_notifications_immutable before update or delete on app_private.store_notifications
 for each row execute function app_private.immutable_record();

insert into app_private.api_rate_rules values('store-sync',600,60,10000) on conflict(route) do nothing;

create function app_private.store_millis(p jsonb,k text) returns timestamptz language sql immutable set search_path = '' as $$
 select case when p->k is null or jsonb_typeof(p->k)='null' then null
  when jsonb_typeof(p->k)='number' and (p->>k)::numeric between 1000000000000 and 9999999999999 then to_timestamp((p->>k)::numeric/1000)
  else '-infinity'::timestamptz end
$$;

-- Removes a bucket's unspent credits (holds in flight stay) under an entry key.
create function app_private.store_remove_unspent(p_bucket uuid,p_entry text,p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare b app_private.credit_buckets;
begin
 select * into strict b from app_private.credit_buckets where id=p_bucket for update;
 if b.revoked_at is not null then return; end if;
 update app_private.credit_buckets set balance=reserved,revoked_at=now(),revocation_key=p_entry where id=b.id;
 insert into app_private.credit_ledger(account_id,bucket_id,entry_key,kind,balance_delta,reserved_delta,reason)
 values(b.account_id,b.id,p_entry,'adjustment',-(b.balance-b.reserved),0,p_reason);
end $$;

-- A plan period replaced by a plan change (a different product bought, not
-- renewed, on the same subscription, starting more than a day before the
-- period ends).
create function app_private.store_replaced(p_env text,p_tid text,p_otid text,p_product text,p_purchased timestamptz,p_expires timestamptz)
returns boolean language sql stable security definer set search_path = '' as $$
 select exists(select 1 from app_private.store_transactions s where s.environment=p_env and s.original_transaction_id=p_otid
  and s.transaction_id<>p_tid and s.product_id<>p_product and s.reason is distinct from 'RENEWAL'
  and s.purchased_at>p_purchased and s.purchased_at<p_expires-interval '1 day')
$$;

-- The credits one transaction grants: once, on first sight (or when a refund it
-- was first seen with is reversed). A plan period that already ended, or one a
-- plan change replaced, grants nothing; a plan change ends the earlier period.
create function app_private.store_grant(p_env text,p_tid text,p_otid text,p_account uuid,p_product text,p_quantity integer,
 p_purchased timestamptz,p_expires timestamptz,p_reason text,p_app_transaction text,out granted bigint,out bucket uuid)
language plpgsql security definer set search_path = '' as $$
declare product app_private.store_products; cap bigint; used bigint; earlier record;
begin
 granted:=0; bucket:=null;
 select * into strict product from app_private.store_products where product_id=p_product;
 if product.kind='subscription' then
  if p_expires<=now() then return; end if;
  if app_private.store_replaced(p_env,p_tid,p_otid,p_product,p_purchased,p_expires) then return; end if;
 end if;
 granted:=product.credits*p_quantity;
 select monthly_credit_cap into cap from app_private.store_policy where environment=p_env;
 if cap is not null then
  select coalesce(sum(credits),0) into used from app_private.store_transactions
   where environment=p_env and granted_at>=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC'
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

-- Records one verified transaction. p_source 'app' (p_account_id: the signed-in
-- caller) or 'notification' (p_account_id null). Returns {outcome, account_id,
-- credits}: recorded | updated | already_recorded | linked_to_another_account |
-- unattributed | account_closed | unknown_product | unsupported.
-- Lock order: the transaction's newest copy, the purchase owner, the account, buckets.
create function app_private.record_store_transaction(p_source text,p_account_id uuid,p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare env text:=p->>'environment'; tid text:=p->>'transaction_id'; otid text:=p->>'original_transaction_id';
 token uuid; product app_private.store_products; owner app_private.store_owners; t app_private.store_transactions; seen app_private.store_seen;
 purchased timestamptz:=app_private.store_millis(p,'purchase_date'); expires timestamptz:=app_private.store_millis(p,'expires_date');
 revoked timestamptz:=app_private.store_millis(p,'revocation_date'); signed timestamptz:=app_private.store_millis(p,'signed_date');
 qty integer; candidate uuid; previous uuid; linked boolean:=false; g record; b app_private.credit_buckets; delta bigint;
 reason text:=p->>'reason'; app_transaction text:=p->>'app_transaction_id';
begin
 if p_source is null or p_source not in ('app','notification') or (p_source='app')<>(p_account_id is not null) then raise exception 'invalid_store_source'; end if;
 if p is null or jsonb_typeof(p)<>'object' or env is null or env not in ('Sandbox','Production')
  or tid is null or tid !~ '^[0-9]{1,32}$' or otid is null or otid !~ '^[0-9]{1,32}$' or p->>'product_id' is null
  or purchased is null or purchased='-infinity' or signed is null or signed='-infinity' or expires='-infinity' or revoked='-infinity'
  or (expires is not null and expires<=purchased) or purchased>now()+interval '1 hour' or signed>now()+interval '1 hour'
  or (p ? 'quantity' and (jsonb_typeof(p->'quantity')<>'number' or (p->>'quantity') !~ '^[0-9]{1,2}$'))
  or (reason is not null and reason not in ('PURCHASE','RENEWAL')) or (app_transaction is not null and app_transaction !~ '^[0-9]{1,32}$')
  then raise exception 'invalid_store_transaction'; end if;
 if p ? 'app_account_token' and jsonb_typeof(p->'app_account_token')<>'null' then
  if jsonb_typeof(p->'app_account_token')<>'string'
   or (p->>'app_account_token') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'invalid_store_transaction'; end if;
  token:=(p->>'app_account_token')::uuid;
 end if;
 qty:=coalesce((p->>'quantity')::integer,1);

 -- The newest copy wins, whoever reported it and in whatever order.
 insert into app_private.store_seen(environment,transaction_id,original_transaction_id,signed_at,expires_at,revoked_at)
 values(env,tid,otid,signed,expires,revoked)
 on conflict(environment,transaction_id) do update set signed_at=excluded.signed_at,expires_at=excluded.expires_at,revoked_at=excluded.revoked_at
  where excluded.signed_at>app_private.store_seen.signed_at;
 select * into strict seen from app_private.store_seen where environment=env and transaction_id=tid for update;
 if seen.original_transaction_id<>otid then raise exception 'store_transaction_conflict'; end if;

 select * into t from app_private.store_transactions where environment=env and transaction_id=tid;
 if found then
  select * into strict owner from app_private.store_owners where environment=env and original_transaction_id=otid for update;
  select * into strict t from app_private.store_transactions where environment=env and transaction_id=tid for update;
  if t.product_id<>p->>'product_id' or t.purchased_at<>purchased or t.quantity<>qty then raise exception 'store_transaction_conflict'; end if;
  if p_source='app' and owner.account_id<>p_account_id then
   perform 1 from app_private.accounts where id=owner.account_id and closed_at is null;
   if found then linked:=true;
   else
    -- The purchase's account was deleted: it moves to the caller (future periods only).
    update app_private.store_owners set account_id=p_account_id,previous_account_id=owner.account_id,bound_at=now(),bound_by='app'
     where environment=env and original_transaction_id=otid;
   end if;
  end if;
  if seen.signed_at<=t.signed_at then
   return jsonb_build_object('outcome',case when linked then 'linked_to_another_account' else 'already_recorded' end,'account_id',t.account_id); end if;
  perform 1 from app_private.accounts where id=t.account_id for update;
  if seen.revoked_at is not null and t.revoked_at is null and t.bucket_id is not null then
   perform app_private.store_remove_unspent(t.bucket_id,'store-revoke:'||env||':'||tid||':'||(extract(epoch from seen.signed_at)*1000)::bigint,
    'App Store refund; credits in flight preserved');
  elsif seen.revoked_at is null and t.revoked_at is not null then
   if t.bucket_id is not null then
    select * into strict b from app_private.credit_buckets where id=t.bucket_id for update;
    -- Not when a plan change has since replaced the period.
    if b.revoked_at is not null and b.revocation_key like 'store-revoke:%'
     and not app_private.store_replaced(env,tid,otid,t.product_id,t.purchased_at,coalesce(seen.expires_at,'infinity')) then
     select -balance_delta into strict delta from app_private.credit_ledger where bucket_id=b.id and entry_key=b.revocation_key;
     update app_private.credit_buckets set balance=balance+delta,revoked_at=null,revocation_key=null where id=b.id;
     insert into app_private.credit_ledger(account_id,bucket_id,entry_key,kind,balance_delta,reserved_delta,reason)
      values(t.account_id,b.id,'store-reinstate:'||env||':'||tid||':'||(extract(epoch from seen.signed_at)*1000)::bigint,'adjustment',delta,0,'App Store refund reversed');
    end if;
   else
    -- First seen already refunded, so nothing was granted: grant now.
    perform 1 from app_private.accounts where id=t.account_id and closed_at is null;
    if found then
     select * into g from app_private.store_grant(env,tid,otid,t.account_id,t.product_id,t.quantity,t.purchased_at,seen.expires_at,
      t.reason,t.app_transaction_id);
     update app_private.store_transactions set credits=g.granted,bucket_id=g.bucket,granted_at=case when g.granted>0 then now() end
      where environment=env and transaction_id=tid;
    end if;
   end if;
  end if;
  update app_private.store_transactions set revoked_at=seen.revoked_at,expires_at=seen.expires_at,signed_at=seen.signed_at,updated_at=now()
   where environment=env and transaction_id=tid;
  return jsonb_build_object('outcome',case when linked then 'linked_to_another_account' else 'updated' end,'account_id',t.account_id);
 end if;

 -- First sight: only what the store sells.
 select * into product from app_private.store_products where product_id=p->>'product_id';
 if not found then return jsonb_build_object('outcome','unknown_product'); end if;
 if (product.kind='subscription' and (p->>'type' is distinct from 'Auto-Renewable Subscription' or expires is null or qty<>1
     or seen.expires_at>purchased+interval '400 days'))
  or (product.kind='credits' and (p->>'type' is distinct from 'Consumable' or expires is not null or qty not between 1 and 10))
  or coalesce(p->>'ownership','PURCHASED')<>'PURCHASED' then return jsonb_build_object('outcome','unsupported'); end if;

 -- Ownership.
 select * into owner from app_private.store_owners where environment=env and original_transaction_id=otid for update;
 if not found then
  if p_source='app' and token is not null and token<>p_account_id then
   -- Bound to another account at purchase: only a deleted account's purchase moves to the caller.
   perform 1 from app_private.accounts where id=token and closed_at is not null;
   if not found then return jsonb_build_object('outcome','linked_to_another_account'); end if;
   candidate:=p_account_id; previous:=token;
  else candidate:=coalesce(token,p_account_id); end if;
  if candidate is null then return jsonb_build_object('outcome','unattributed'); end if;
  perform 1 from app_private.accounts where id=candidate and closed_at is null;
  if not found then return jsonb_build_object('outcome',case when p_source='app' then 'account_closed' else 'unattributed' end); end if;
  insert into app_private.store_owners(environment,original_transaction_id,account_id,bound_by,previous_account_id)
  values(env,otid,candidate,p_source,previous) on conflict do nothing;
  select * into strict owner from app_private.store_owners where environment=env and original_transaction_id=otid for update;
 end if;
 if p_source='app' and owner.account_id<>p_account_id then
  perform 1 from app_private.accounts where id=owner.account_id and closed_at is null;
  if found then return jsonb_build_object('outcome','linked_to_another_account'); end if;
  -- The purchase's account was deleted: it moves to the caller (future periods only).
  update app_private.store_owners set account_id=p_account_id,previous_account_id=owner.account_id,bound_at=now(),bound_by='app'
   where environment=env and original_transaction_id=otid returning * into owner;
 end if;

 perform 1 from app_private.accounts where id=owner.account_id and closed_at is null for update;
 if not found then return jsonb_build_object('outcome','account_closed'); end if;
 if seen.revoked_at is null then
  select * into g from app_private.store_grant(env,tid,otid,owner.account_id,product.product_id,qty,purchased,seen.expires_at,reason,app_transaction);
 else select 0::bigint granted,null::uuid bucket into g; end if;
 insert into app_private.store_transactions(environment,transaction_id,original_transaction_id,account_id,product_id,quantity,
  purchased_at,expires_at,revoked_at,signed_at,credits,bucket_id,granted_at,reason,app_transaction_id)
 values(env,tid,otid,owner.account_id,product.product_id,qty,purchased,seen.expires_at,seen.revoked_at,seen.signed_at,g.granted,g.bucket,
  case when g.granted>0 then now() end,reason,app_transaction);
 return jsonb_build_object('outcome','recorded','account_id',owner.account_id,'credits',g.granted);
end $$;

create function public.worker_record_store_transaction(p_account_id uuid,p_transaction jsonb) returns jsonb
language sql security definer set search_path = '' as $$
 select app_private.record_store_transaction('app',p_account_id,p_transaction)
$$;

-- An App Store Server Notification (V2), once per notificationUUID. The
-- transaction it carries, if any, is recorded like one from the app.
create function public.worker_record_store_notification(p_environment text,p_notification_uuid uuid,p_type text,p_subtype text,
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

-- The caller's current plan, from verified renewals (the app shows billing
-- issues from StoreKit itself).
create function public.v1_store_summary() returns jsonb language sql stable security definer set search_path = '' as $$
 select coalesce((select jsonb_build_object('plan',p.plan,'product_id',t.product_id,'expires_at',t.expires_at)
  from app_private.store_transactions t join app_private.store_products p using(product_id)
  where t.account_id=app_private.require_actor() and p.kind='subscription' and t.revoked_at is null and t.expires_at>now()
  order by t.expires_at desc limit 1),jsonb_build_object('plan',null))
$$;

-- Admin overview: subscriptions now come from verified App Store transactions
-- (migration 009's definition otherwise unchanged).
create or replace function public.v1_admin_overview() returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; month_start timestamptz:=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC';
begin
 result:=app_private.v1_admin_overview(); -- Existing owner-role and MFA gate.
 return result||jsonb_build_object(
  'sync_storage',(select to_jsonb(s)||to_jsonb(p) from app_private.sync_environment_storage s cross join app_private.sync_storage_policy p),
  'sync_transfers',jsonb_build_object('period',date_trunc('month',now() at time zone 'UTC')::date,
   'policy',(select to_jsonb(p) from app_private.sync_transfer_policy p),
   'months',coalesce((select jsonb_agg(to_jsonb(m) order by period desc) from app_private.sync_transfer_months m
    where scope_id='environment' and period>=(date_trunc('month',now() at time zone 'UTC')-interval '2 months')::date),'[]'::jsonb)),
  'subscriptions',coalesce((select jsonb_object_agg(k,n) from (
    select initcap(p.plan)||' active ('||t.environment||')' k,count(distinct t.original_transaction_id) n
     from app_private.store_transactions t join app_private.store_products p using(product_id)
     where p.kind='subscription' and t.revoked_at is null and t.expires_at>now() group by p.plan,t.environment
    union all select 'Credit packs this month ('||t.environment||')',count(*) from app_private.store_transactions t
     join app_private.store_products p using(product_id) where p.kind='credits' and t.recorded_at>=month_start group by t.environment
    union all select 'Refunded this month ('||environment||')',count(*) from app_private.store_transactions
     where revoked_at>=month_start group by environment) x),'{}'::jsonb));
end $$;

revoke all on function app_private.store_millis(jsonb,text) from public,anon,authenticated;
revoke all on function app_private.store_remove_unspent(uuid,text,text) from public,anon,authenticated;
revoke all on function app_private.store_grant(text,text,text,uuid,text,integer,timestamptz,timestamptz,text,text) from public,anon,authenticated;
revoke all on function app_private.store_replaced(text,text,text,text,timestamptz,timestamptz) from public,anon,authenticated;
revoke all on function app_private.record_store_transaction(text,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.worker_record_store_transaction(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.worker_record_store_notification(text,uuid,text,text,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function public.worker_record_store_transaction(uuid,jsonb) to service_role;
grant execute on function public.worker_record_store_notification(text,uuid,text,text,timestamptz,jsonb) to service_role;
revoke all on function public.v1_store_summary() from public,anon;
grant execute on function public.v1_store_summary() to authenticated;
commit;
