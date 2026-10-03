begin;
create table app_private.allowance_periods (
 environment text not null,
 original_transaction_id text not null,
 starts_at timestamptz not null,
 ends_at timestamptz not null check(ends_at>starts_at),
 price_version_id text not null references app_private.price_versions(id),
 account_id uuid not null,
 bucket_id uuid not null unique,
 primary key(environment,original_transaction_id,starts_at),
 foreign key(environment,original_transaction_id,account_id) references app_private.subscription_owners(environment,original_transaction_id,account_id),
 foreign key(bucket_id,account_id) references app_private.credit_buckets(id,account_id)
);
alter table app_private.allowance_periods enable row level security;
-- Service-only: the Apple adapter must verify JWS signatures, app/environment,
-- transaction ownership and effective state before entering this transaction.
create function public.worker_record_subscription(p_account_id uuid,p_environment text,p_event_id text,p_original_transaction_id text,
 p_signed_at timestamptz,p_product_id text,p_state text,p_expires_at timestamptz,p_period_start timestamptz,p_period_end timestamptz,p_verified_payload jsonb)
returns boolean language plpgsql security definer set search_path = '' as $$
declare owner uuid; existing app_private.subscription_events; current_ent app_private.entitlements;
 price app_private.price_versions; b app_private.credit_buckets; allowance app_private.allowance_periods;
 payload_digest bytea; bucket uuid; entry text; delta bigint;
begin
 if p_environment is null or p_environment not in ('Sandbox','Production') or p_state is null or p_state not in ('active','grace','expired','revoked')
  or p_signed_at is null or p_signed_at>now()+interval '5 minutes' or p_verified_payload is null or pg_column_size(p_verified_payload)>65536 then raise exception 'invalid_verified_subscription'; end if;
 payload_digest:=sha256(convert_to(p_verified_payload::text,'UTF8'));
 insert into app_private.subscription_owners(environment,original_transaction_id,account_id)
 values(p_environment,p_original_transaction_id,p_account_id) on conflict do nothing;
 select account_id into strict owner from app_private.subscription_owners where environment=p_environment and original_transaction_id=p_original_transaction_id for update;
 if owner<>p_account_id then raise exception 'subscription_owned_by_another_account' using errcode='42501'; end if;
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null for update;
 if not found then raise exception 'account_unavailable'; end if;
 select * into existing from app_private.subscription_events where environment=p_environment and event_id=p_event_id;
 if found then
  if existing.account_id is distinct from p_account_id or existing.original_transaction_id is distinct from p_original_transaction_id
   or existing.payload_sha256 is distinct from payload_digest then raise exception 'subscription_event_conflict'; end if;
  return false;
 end if;
 select * into strict price from app_private.price_versions where apple_product_id=p_product_id;
 insert into app_private.subscription_events(environment,event_id,original_transaction_id,account_id,signed_at,payload_sha256,verified_payload)
 values(p_environment,p_event_id,p_original_transaction_id,p_account_id,p_signed_at,payload_digest,p_verified_payload);
 select * into current_ent from app_private.entitlements where environment=p_environment and original_transaction_id=p_original_transaction_id for update;
 if found and current_ent.source_signed_at>p_signed_at then return false; end if;
 if found and current_ent.source_signed_at=p_signed_at and (current_ent.state is distinct from p_state or current_ent.expires_at is distinct from p_expires_at or current_ent.product_id is distinct from p_product_id) then
  raise exception 'subscription_state_requires_reconciliation';
 end if;
 insert into app_private.entitlements(account_id,environment,original_transaction_id,product_id,state,expires_at,verified_at,source_signed_at)
 values(p_account_id,p_environment,p_original_transaction_id,p_product_id,p_state,p_expires_at,now(),p_signed_at)
 on conflict(environment,original_transaction_id) do update set product_id=excluded.product_id,state=excluded.state,
  expires_at=excluded.expires_at,verified_at=now(),source_signed_at=excluded.source_signed_at;
 if p_state='revoked' then
  for b in select cb.* from app_private.credit_buckets cb join app_private.allowance_periods ap on ap.bucket_id=cb.id
   where ap.environment=p_environment and ap.original_transaction_id=p_original_transaction_id and cb.revoked_at is null for update of cb loop
   delta:=b.balance-b.reserved; entry:='revoke:'||p_environment||':'||p_event_id;
   update app_private.credit_buckets set balance=reserved,revoked_at=now(),revocation_key=entry where id=b.id;
   insert into app_private.credit_ledger(account_id,bucket_id,entry_key,kind,balance_delta,reserved_delta,reason)
   values(p_account_id,b.id,entry,'adjustment',-delta,0,'Verified subscription revocation; in-flight holds preserved');
  end loop;
 elsif p_state in ('active','grace') and p_expires_at>now() then
  if p_period_start is null or p_period_end is null or p_period_start>now() or p_period_end<=p_period_start
    or p_period_end>p_expires_at or p_period_end>p_period_start+interval '1 month'+interval '1 day' then raise exception 'invalid_allowance_period'; end if;
  select * into allowance from app_private.allowance_periods where environment=p_environment and original_transaction_id=p_original_transaction_id and starts_at=p_period_start;
  if not found then
   bucket:=public.worker_grant_credits(p_account_id,'subscription',p_environment||':'||p_original_transaction_id||':'||extract(epoch from p_period_start)::text,
    price.monthly_credits,p_period_start,p_period_end,'Verified monthly subscription allowance');
   insert into app_private.allowance_periods values(p_environment,p_original_transaction_id,p_period_start,p_period_end,price.id,p_account_id,bucket);
  elsif allowance.ends_at is distinct from p_period_end or allowance.price_version_id is distinct from price.id then
   raise exception 'allowance_period_requires_reconciliation';
  end if;
  for b in select cb.* from app_private.credit_buckets cb join app_private.allowance_periods ap on ap.bucket_id=cb.id
   where ap.environment=p_environment and ap.original_transaction_id=p_original_transaction_id and cb.revoked_at is not null for update of cb loop
   select -balance_delta into strict delta from app_private.credit_ledger where bucket_id=b.id and entry_key=b.revocation_key;
   update app_private.credit_buckets set balance=balance+delta,revoked_at=null,revocation_key=null where id=b.id;
   insert into app_private.credit_ledger(account_id,bucket_id,entry_key,kind,balance_delta,reserved_delta,reason)
   values(p_account_id,b.id,'reinstate:'||p_environment||':'||p_event_id,'adjustment',delta,0,'Verified subscription reinstatement');
  end loop;
 end if;
 return true;
end $$;
revoke all on function public.worker_record_subscription(uuid,text,text,text,timestamptz,text,text,timestamptz,timestamptz,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function public.worker_record_subscription(uuid,text,text,text,timestamptz,text,text,timestamptz,timestamptz,timestamptz,jsonb) to service_role;
commit;
