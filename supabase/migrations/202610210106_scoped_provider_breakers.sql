-- 0106: A provider's breaker can be scoped to one route and upstream (review A13, 2026-10-21; design:
-- docs/architecture/RESILIENCE.md "Scoped breakers").
-- Before: one breaker per provider host. Every model goes through openrouter.ai, so five failures in a minute from any
-- route (a DeepInfra outage for DeepSeek, speech errors in a podcast, a tag job's 429s) failed every Claude and Gemini
-- chat with synthetic 429s for 30 s to 5 min. Now the caller may name a scope (for OpenRouter: the calling route and the
-- upstream endpoint, e.g. `chat_vertex`, `chat_deepinfra`, `podcast_speech`, `run_vertex`); the breaker row is per
-- provider and scope, and a scope's failures open only its own breaker. Health hours are unchanged (per provider and
-- route). Callers that send no scope keep one breaker per provider, as before.
begin;
set local lock_timeout='15s';

alter table app_private.provider_breakers add column scope text not null default '' check (scope ~ '^[a-z0-9_]{0,32}$');
alter table app_private.provider_breakers drop constraint provider_breakers_pkey;
alter table app_private.provider_breakers add primary key (provider, scope);

create or replace function app_private.provider_breaker_view(b app_private.provider_breakers) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object('provider', b.provider, 'scope', coalesce(b.scope, ''),
  'state', case when b.state = 'open' and b.reopen_at <= now() then 'half_open' else coalesce(b.state, 'closed') end,
  'reopen_at', b.reopen_at)
$$;

-- As migration 073, with the scope (named arguments of the earlier signature still resolve here).
drop function public.worker_provider_health(text, text, text, integer, integer, boolean);
create function public.worker_provider_health(p_provider text, p_route text, p_outcome text, p_latency_ms integer default 0,
  p_retry_after_s integer default null, p_drill boolean default false, p_scope text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare h timestamptz := date_trunc('hour', now()); b app_private.provider_breakers; cool integer; latency integer; kept_route text;
 v_scope text := coalesce(p_scope, '');
begin
 begin
  if p_provider is null or p_provider !~ '^[a-z][a-z0-9_]{0,31}$' or p_route is null or p_route !~ '^[a-z][a-z0-9_]{0,31}$'
   or p_outcome is null or p_outcome not in ('ok','throttled','overloaded','server_error','timeout','transport','rejected','breaker_open')
   or v_scope !~ '^[a-z0-9_]{0,32}$'
  then return null; end if;
  kept_route := case when coalesce(p_drill, false) then 'drill' else p_route end;
  latency := least(greatest(coalesce(p_latency_ms, 0), 0), 86400000);
  insert into app_private.provider_health_hours as t (hour, provider, route, outcome, calls, latency_ms_total, latency_ms_max, retry_after_max_s)
  values (h, p_provider, kept_route, p_outcome, 1, latency, latency, case when p_retry_after_s between 0 and 86400 then p_retry_after_s end)
  on conflict (hour, provider, route, outcome) do update set calls = t.calls + 1,
   latency_ms_total = t.latency_ms_total + excluded.latency_ms_total,
   latency_ms_max = greatest(t.latency_ms_max, excluded.latency_ms_max),
   retry_after_max_s = greatest(t.retry_after_max_s, excluded.retry_after_max_s);
  -- 90 days kept: the first call recorded in a new hour clears what is older.
  if (select count(*) from app_private.provider_health_hours where hour = h) = 1 then
   delete from app_private.provider_health_hours where hour < h - interval '90 days';
  end if;

  -- A client error (rejected) says nothing about the provider's health; a failed-fast call is the breaker's own doing;
  -- a drill is ours.
  if p_outcome in ('rejected', 'breaker_open') or coalesce(p_drill, false) then
   select * into b from app_private.provider_breakers where provider = p_provider and scope = v_scope;
   return case when found then app_private.provider_breaker_view(b) else jsonb_build_object('provider', p_provider, 'scope', v_scope, 'state', 'closed', 'reopen_at', null) end;
  end if;
  if p_outcome = 'ok' then
   select * into b from app_private.provider_breakers where provider = p_provider and scope = v_scope;
   if not found then return jsonb_build_object('provider', p_provider, 'scope', v_scope, 'state', 'closed', 'reopen_at', null); end if;
   if b.state = 'closed' and b.consecutive_failures = 0 then return app_private.provider_breaker_view(b); end if;
   update app_private.provider_breakers set state = 'closed', consecutive_failures = 0, open_count = 0, reopen_at = null, updated_at = now()
    where provider = p_provider and scope = v_scope returning * into b;
   return app_private.provider_breaker_view(b);
  end if;

  insert into app_private.provider_breakers(provider, scope) values (p_provider, v_scope) on conflict do nothing;
  select * into b from app_private.provider_breakers where provider = p_provider and scope = v_scope for update;
  if b.state = 'closed' then
   b.consecutive_failures := case when b.last_failure_at > now() - interval '60 seconds' then b.consecutive_failures + 1 else 1 end;
   if b.consecutive_failures >= 5 then
    cool := least(300, 30 * power(2, least(b.open_count, 4))::integer);
    b.state := 'open'; b.opened_at := now(); b.reopen_at := now() + make_interval(secs => cool); b.open_count := b.open_count + 1;
   end if;
  elsif b.reopen_at <= now() then
   -- The half-open probe failed: open again, for longer.
   cool := least(300, 30 * power(2, least(b.open_count, 4))::integer);
   b.opened_at := now(); b.reopen_at := now() + make_interval(secs => cool); b.open_count := b.open_count + 1;
  end if;  -- Open and still cooling off: a call already in flight failing changes nothing.
  update app_private.provider_breakers set state = b.state, consecutive_failures = b.consecutive_failures, last_failure_at = now(),
   opened_at = b.opened_at, reopen_at = b.reopen_at, open_count = b.open_count, updated_at = now()
   where provider = p_provider and scope = v_scope returning * into b;
  return app_private.provider_breaker_view(b);
 exception when others then return null;
 end;
end $$;
revoke all on function public.worker_provider_health(text, text, text, integer, integer, boolean, text) from public, anon, authenticated;
grant execute on function public.worker_provider_health(text, text, text, integer, integer, boolean, text) to service_role;

create or replace function public.worker_provider_breakers() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(app_private.provider_breaker_view(b) order by b.provider, b.scope), '[]'::jsonb) from app_private.provider_breakers b
 where b.state <> 'closed'
$$;

notify pgrst, 'reload schema';
commit;
