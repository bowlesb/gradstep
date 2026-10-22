-- 0151: Spend vs income tells Sandbox (TestFlight) purchases apart from real ones (docs/RUNBOOK_SPENDING.md). Staging's
-- only purchases are Sandbox: their credits cost testers nothing, so the spend they fund is the owner's money, not
-- prepaid income. An operation is `paid` only when Production plan or pack credits paid for it; Sandbox ones are
-- `sandbox`. Read only: one function replaced, no table changes.
begin;
set local lock_timeout='15s';

create or replace function app_private.operation_funding(p_account uuid,p_operation uuid) returns text
language sql stable security definer set search_path='' as $$
 select case when bool_or(o.free_funded) then 'free'
  when bool_or(t.account_id is not null) then 'testing'
  when bool_or(b.source in ('subscription','purchased') and b.external_key like 'Production:%') then 'paid'
  when bool_or(b.source in ('subscription','purchased')) then 'sandbox'
  when bool_or(b.source in ('adjustment','trial')) then 'granted'
  else 'platform' end
 from app_private.metered_operations o
 left join app_private.reservation_allocations ra on ra.account_id=o.account_id and ra.operation_id=o.id
 left join app_private.credit_buckets b on b.id=ra.bucket_id
 left join app_private.testing_allowances t on t.bucket_id=b.id
 where o.account_id=p_account and o.id=p_operation
$$;
revoke all on function app_private.operation_funding(uuid,uuid) from public,anon,authenticated;

notify pgrst,'reload schema';
commit;
