-- 084: Health names a provider refusing for the account's own balance (2026-10-16: the staging Anthropic account ran out of
-- credit about 15:00 UTC and every Claude request failed with "Your credit balance is too low"; the only sign was a
-- tester's "Broken??"). The chat and podcast adapters record such an attempt with failure_code `provider_billing`
-- (Anthropic, anthropic.ts `isBillingRejection`) or `http_402` (DeepSeek's "Insufficient Balance"); v1_admin_health gains
-- `provider_billing`: counts in the last hour and day, the latest, and the day's count by provider. Additive: the earlier
-- health function is kept (renamed, as migration 079 did) and its sections are unchanged.
begin;

alter function public.v1_admin_health(integer) rename to admin_health_before_084;
alter function public.admin_health_before_084(integer) set schema app_private;
revoke all on function app_private.admin_health_before_084(integer) from public, anon, authenticated;

create function public.v1_admin_health(p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb;
begin
 -- The earlier function checks the owner with MFA and the window before anything is read.
 base := app_private.admin_health_before_084(p_days);
 return base || jsonb_build_object('provider_billing', (
  with b as (select provider, created_at from app_private.provider_attempts
   where failure_code in ('provider_billing', 'http_402') and created_at > now() - interval '24 hours')
  select jsonb_build_object(
   'last_hour', (select count(*) from b where created_at > now() - interval '1 hour'),
   'last_24h', (select count(*) from b),
   'last_at', (select max(created_at) from b),
   'by_provider', (select coalesce(jsonb_object_agg(provider, n), '{}'::jsonb) from (select provider, count(*) n from b group by 1) x))));
end $$;
revoke all on function public.v1_admin_health(integer) from public, anon;
grant execute on function public.v1_admin_health(integer) to authenticated;

notify pgrst, 'reload schema';
commit;
