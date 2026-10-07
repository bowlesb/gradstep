-- Provider allowances (owner decision 2026-10-06: Tavily Project plan, $30/month for
-- 4,000 search credits, as chat's primary web search). The chat function checks the
-- credits recorded in the last N days before offering Tavily, so prepaid allowances are
-- never silently exceeded (pay-as-you-go stays off as the provider-side limit). Additive:
-- a read-only aggregate over existing usage events and an index for it.
begin;
set local lock_timeout='15s';

create index provider_usage_events_provider_created on app_private.provider_usage_events(provider,created_at);

-- Sum of one numeric unit (e.g. Tavily `credits`) over the provider's events in the last p_days.
create function public.worker_provider_units_recent(p_provider text,p_unit text,p_days integer) returns bigint
language plpgsql stable security definer set search_path='' as $$
begin
 if p_provider !~ '^[a-z0-9_-]{1,32}$' or p_unit !~ '^[a-z0-9_]{1,32}$' or p_days is null or p_days not between 1 and 62
 then raise exception 'invalid_usage_query'; end if;
 return (select coalesce(sum(case when jsonb_typeof(e.units->p_unit)='number' then floor((e.units->>p_unit)::numeric) else 0 end),0)::bigint
  from app_private.provider_usage_events e where e.provider=p_provider and e.created_at>now()-make_interval(days=>p_days));
end $$;

revoke all on function public.worker_provider_units_recent(text,text,integer) from public,anon,authenticated,service_role;
grant execute on function public.worker_provider_units_recent(text,text,integer) to service_role;
notify pgrst,'reload schema';
commit;
