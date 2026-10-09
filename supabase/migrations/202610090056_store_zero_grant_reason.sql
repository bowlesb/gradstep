-- Explain a final App Store record that granted zero credits without exposing
-- any receipt or account data. This is diagnostic/read-only; it never changes
-- the purchase ledger or the Sandbox allowance.
begin;

create or replace function public.worker_store_zero_grant_reason(
 p_account_id uuid,
 p_environment text,
 p_transaction_id text
) returns text
language plpgsql stable security definer set search_path=''
as $$
declare
 t app_private.store_transactions;
 product app_private.store_products;
 decision text;
 cap bigint;
begin
 if p_account_id is null or p_environment not in ('Sandbox','Production')
    or p_transaction_id is null or p_transaction_id !~ '^[0-9]{1,32}$' then
  return null;
 end if;
 select * into t
   from app_private.store_transactions
  where account_id=p_account_id and environment=p_environment and transaction_id=p_transaction_id;
 if not found or t.credits<>0 then return null; end if;
 select * into product from app_private.store_products where product_id=t.product_id;
 if not found then return null; end if;
 select d.reason into decision
   from app_private.store_sandbox_decisions d
  where p_environment='Sandbox' and d.transaction_id=p_transaction_id
  order by d.created_at desc
  limit 1;
 if decision in ('account_allowance_exhausted','apple_allowance_exhausted','both_allowances_exhausted') then
  return 'sandbox_monthly_cap';
 end if;
 if p_environment='Sandbox' then
  select monthly_credit_cap into cap from app_private.store_policy where environment='Sandbox';
  if decision='identity_missing' then return 'sandbox_identity_missing'; end if;
  if cap is not null then return 'sandbox_monthly_cap'; end if;
 end if;
 if product.kind='subscription' then return 'subscription_not_eligible'; end if;
 return 'no_credit_grant';
end $$;

revoke all on function public.worker_store_zero_grant_reason(uuid,text,text) from public,anon,authenticated;
grant execute on function public.worker_store_zero_grant_reason(uuid,text,text) to service_role;
commit;
