-- Owner-approved policy (DECISIONS 2026-10-05): an upgrade retains the prior
-- period's credits until their ORIGINAL expiry. No carryover, new product,
-- allowance change, provider request, or retrospective grant is introduced.
-- Independently reviewed. Deployment requires the reviewed verifier
-- pause/drain procedure; table locks alone do not replace that procedure.
begin;
set local lock_timeout='15s';

-- Freeze channel enablement/admission and inventory during this transaction.
-- This deliberately does not toggle a policy. A separately completed pause and
-- drain is required before invoking the migration (see the review document).
lock table app_private.store_verifier_policy in share mode;
lock table app_private.store_transactions,app_private.credit_buckets in share row exclusive mode;
do $$ begin
 if (select count(*) from app_private.store_verifier_policy)<>2
  or exists(select 1 from app_private.store_verifier_policy where enabled) then
  raise exception 'subscription_upgrade_requires_verifier_pause';
 end if;
 -- Ten quiet minutes exceeds the current 115-second adapter budget and 400-second
 -- Edge runtime. A finished verifier start can still precede a recorder call,
 -- so count ALL recent starts, not only those whose outcome remains started.
 if exists(select 1 from app_private.store_verifier_starts where started_at>clock_timestamp()-interval '10 minutes') then
  raise exception 'subscription_upgrade_requires_verifier_drain';
 end if;
 -- Staging has never recorded a subscription. Refuse a changed inventory rather
 -- than silently leaving an old supersession/zero grant unrepaired. No financial
 -- row is rewritten here; even a valid prior subscription requires review.
 if exists(select 1 from app_private.store_transactions t join app_private.store_products p using(product_id)
    where p.kind='subscription')
  or exists(select 1 from app_private.credit_buckets where source='subscription' or revocation_key like 'store-superseded:%') then
  raise exception 'subscription_upgrade_history_requires_review';
 end if;
end $$;

-- Same admission and Sandbox accounting as036. An upgrade neither suppresses
-- a valid earlier grant first seen late nor revokes a bucket already granted.
create or replace function app_private.store_grant(p_env text,p_tid text,p_otid text,p_account uuid,p_product text,p_quantity integer,
 p_purchased timestamptz,p_expires timestamptz,p_reason text,p_app_transaction text,out granted bigint,out bucket uuid)
language plpgsql security definer set search_path = '' as $$
declare product app_private.store_products; cap bigint; used bigint;
 requested bigint; account_used bigint:=0; identity_used bigint:=0; decision text; identity text:=p_app_transaction;
 month_start timestamptz:=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC';
begin
 granted:=0; bucket:=null;
 select * into strict product from app_private.store_products where product_id=p_product;
 if product.kind='subscription' then
  -- A malformed reversal must never turn a subscription into perpetual credits.
  if p_expires is null or not isfinite(p_expires) then raise exception 'invalid_store_transaction'; end if;
  if p_expires<=now() then return; end if;
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

end $$;

create or replace function app_private.record_store_transaction_locked(p_source text,p_account_id uuid,p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare env text:=p->>'environment'; tid text:=p->>'transaction_id'; otid text:=p->>'original_transaction_id';
 token uuid; product app_private.store_products; owner app_private.store_owners; t app_private.store_transactions; seen app_private.store_seen;
 purchased timestamptz:=app_private.store_millis(p,'purchase_date'); expires timestamptz:=app_private.store_millis(p,'expires_date');
 revoked timestamptz:=app_private.store_millis(p,'revocation_date'); signed timestamptz:=app_private.store_millis(p,'signed_date');
 qty integer; candidate uuid; previous uuid; linked boolean:=false; g record; b app_private.credit_buckets; delta bigint;
 reason text:=p->>'reason'; app_transaction text:=p->>'app_transaction_id';
 locked_accounts uuid[]:='{}'; lock_account uuid;
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

 -- Validate known-product terms on every copy, before newest-state or ledger
 -- writes. A first-seen refunded period may receive its first grant on reversal;
 -- missing expiry or a changed product type must not bypass the first-sight
 -- product checks. Unknown products retain the existing unknown-product path.
 select * into product from app_private.store_products where product_id=p->>'product_id';
 if found and (
  (product.kind='subscription' and (p->>'type' is distinct from 'Auto-Renewable Subscription' or expires is null or qty<>1
    or expires>purchased+interval '400 days'))
  or (product.kind='credits' and (p->>'type' is distinct from 'Consumable' or expires is not null or qty not between 1 and 10))
  or coalesce(p->>'ownership','PURCHASED')<>'PURCHASED') then
  return jsonb_build_object('outcome','unsupported');
 end if;

 -- These two transaction-scoped advisory namespaces belong only to App Store
 -- purchase recording:741801 = transaction identity;741802 = original purchase.
 -- Every app/notification path uses them. A transaction cannot change originals
 -- and enter a different original's account snapshot before the conflict fails.
 perform pg_advisory_xact_lock(741801,hashtext(env||':'||tid));
 if exists(select 1 from app_private.store_seen where environment=env and transaction_id=tid and original_transaction_id<>otid)
  or exists(select 1 from app_private.store_transactions where environment=env and transaction_id=tid and original_transaction_id<>otid)
 then raise exception 'store_transaction_conflict'; end if;
 perform pg_advisory_xact_lock(741802,hashtext(env||':'||otid));

 -- Ownership and all historical buckets for this original are now stable.
 -- Prelock the complete account union, including closed owners and signed tokens,
 -- before implicit FK KEY SHARE locks or explicit grant/refund locks. This is the
 -- same UUID order as multi-account pipeline funding. Unknown token accounts may
 -- remain absent; discovering them later must never add an out-of-order lock.
 for lock_account in select id from (
  select p_account_id id union select token
  union select account_id from app_private.store_owners where environment=env and original_transaction_id=otid
  union select previous_account_id from app_private.store_owners where environment=env and original_transaction_id=otid
  union select account_id from app_private.store_transactions where environment=env and original_transaction_id=otid
 ) accounts where id is not null order by id loop
  perform 1 from app_private.accounts where id=lock_account for update;
  if found then locked_accounts:=array_append(locked_accounts,lock_account); end if;
 end loop;

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
    if not (p_account_id=any(locked_accounts) and owner.account_id=any(locked_accounts)) then raise exception 'store_account_changed'; end if;
    update app_private.store_owners set account_id=p_account_id,previous_account_id=owner.account_id,bound_at=now(),bound_by='app'
     where environment=env and original_transaction_id=otid;
   end if;
  end if;
  if seen.signed_at<=t.signed_at then
   return jsonb_build_object('outcome',case when linked then 'linked_to_another_account' else 'already_recorded' end,'account_id',t.account_id); end if;
  if not (t.account_id=any(locked_accounts)) then raise exception 'store_account_changed'; end if;
  perform 1 from app_private.accounts where id=t.account_id for update;
  if seen.revoked_at is not null and t.revoked_at is null and t.bucket_id is not null then
   perform app_private.store_remove_unspent(t.bucket_id,'store-revoke:'||env||':'||tid||':'||(extract(epoch from seen.signed_at)*1000)::bigint,
    'App Store refund; credits in flight preserved');
  elsif seen.revoked_at is null and t.revoked_at is not null then
   if t.bucket_id is not null then
    select * into strict b from app_private.credit_buckets where id=t.bucket_id for update;
    -- Refund reversals restore this grant only; the original bucket expiry is unchanged.
    if b.revoked_at is not null and b.revocation_key like 'store-revoke:%' then
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
  if not (candidate=any(locked_accounts)) or (previous is not null and not (previous=any(locked_accounts)))
  then raise exception 'store_account_changed'; end if;
  insert into app_private.store_owners(environment,original_transaction_id,account_id,bound_by,previous_account_id)
  values(env,otid,candidate,p_source,previous) on conflict do nothing;
  select * into strict owner from app_private.store_owners where environment=env and original_transaction_id=otid for update;
 end if;
 if p_source='app' and owner.account_id<>p_account_id then
  perform 1 from app_private.accounts where id=owner.account_id and closed_at is null;
  if found then return jsonb_build_object('outcome','linked_to_another_account'); end if;
  -- The purchase's account was deleted: it moves to the caller (future periods only).
  if not (p_account_id=any(locked_accounts) and owner.account_id=any(locked_accounts)) then raise exception 'store_account_changed'; end if;
  update app_private.store_owners set account_id=p_account_id,previous_account_id=owner.account_id,bound_at=now(),bound_by='app'
   where environment=env and original_transaction_id=otid returning * into owner;
 end if;

 if not (owner.account_id=any(locked_accounts)) then raise exception 'store_account_changed'; end if;
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

-- Preserve the Sandbox identity wrapper, including its gate, while avoiding
-- a late identity write after the core recorder refused malformed product terms.
create or replace function app_private.record_store_transaction(p_source text,p_account_id uuid,p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; prior_identity text; identity text:=p->>'app_transaction_id'; tid text:=p->>'transaction_id';
begin
 if p->>'environment' is distinct from 'Sandbox' then
  return app_private.record_store_transaction_locked(p_source,p_account_id,p);
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
 end if;
 result:=app_private.record_store_transaction_locked(p_source,p_account_id,p);
 -- An unsupported copied receipt must not fill identity on an existing row.
 if identity is not null and result->>'outcome'<>'unsupported' then
  update app_private.store_seen set app_transaction_id=identity where environment='Sandbox' and transaction_id=tid and app_transaction_id is null;
  update app_private.store_transactions set app_transaction_id=identity where environment='Sandbox' and transaction_id=tid and app_transaction_id is null;
 end if;
 return result;
end $$;

-- Existing public app/notification wrappers continue using036's Sandbox gate
-- and this recorder. Keep private financial functions inaccessible to clients.
revoke all on function app_private.store_grant(text,text,text,uuid,text,integer,timestamptz,timestamptz,text,text),
 app_private.record_store_transaction_locked(text,uuid,jsonb),app_private.record_store_transaction(text,uuid,jsonb)
 from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
