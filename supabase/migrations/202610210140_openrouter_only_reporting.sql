-- 0140: the budget check and Health reason about OpenRouter attempts only (owner, 2026-10-21: "I want to double down
-- and exclusively use open router"; design: docs/architecture/PROVIDER_SPENDING.md "OpenRouter only (2026-10-21)").
-- Every model call has gone to OpenRouter since migration 089; admission refuses any other provider for a model route.
-- Before: the scheduled budget check failed on any `unknown` attempt over an hour old, whatever its provider; Health's
-- "retired direct providers" count also counted Tavily's prepaid searches; Health's chat-cache figure read only
-- `anthropic` usage, so it has shown nothing since 2026-10-18.
-- Now: the budget check carries the OpenRouter count it fails on; attempts of the retired direct providers (anthropic,
-- deepseek, google, mathpix) are named as legacy, by provider, with the ceilings they still hold. They are not dropped:
-- they stay in the ledger, the month's spend and its reservation until an owner reconciles each with the provider's
-- evidence (scripts/pipeline-ops.py). Tavily's search attempts are neither OpenRouter nor legacy and are counted apart.
-- Health's cache figure reads OpenRouter's usage. No table changes; historical rows are untouched.
begin;
set local lock_timeout='15s';

-- A provider kept only as history: everything but OpenRouter (all model calls) and Tavily (search).
create function app_private.legacy_provider(p_provider text) returns boolean
language sql immutable set search_path='' as $$ select p_provider not in ('openrouter','tavily') $$;
revoke all on function app_private.legacy_provider(text) from public,anon,authenticated;

-- As 0102, with the legacy count limited to retired direct providers and its breakdown named.
create or replace function app_private.openrouter_reconcile_health() returns jsonb
language sql stable security definer set search_path='' as $$
 with u as (select a.*,q.tries,q.last_outcome from app_private.provider_attempts a
  left join app_private.openrouter_reconcile_queue q on q.attempt_id=a.id
  where a.state='unknown' or (a.state='admitted' and a.created_at<now()-interval '1 hour'))
 select jsonb_build_object(
  'automatic_pending',(select count(*) from u where app_private.openrouter_reconcilable(u.provider,u.dispatched_at,u.provider_request_id,u.state,u.created_at)
   and coalesce(u.tries,0)<12),
  'gave_up',(select count(*) from u where coalesce(u.tries,0)>=12),
  'without_generation',(select count(*) from u where u.provider='openrouter' and u.provider_request_id is null and u.created_at<now()-interval '1 hour'),
  -- Retired direct providers only (anthropic, deepseek, google, mathpix): legacy history an owner settles with evidence.
  'other_providers',(select count(*) from u where app_private.legacy_provider(u.provider) and u.created_at<now()-interval '1 hour'),
  'legacy',(select jsonb_build_object('attempts',count(*),'held_microusd',coalesce(sum(u.ceiling_microusd),0),'oldest_at',min(u.created_at),
    'by_provider',coalesce((select jsonb_object_agg(x.provider,x.n order by x.provider) from (select v.provider,count(*) n from u v
     where app_private.legacy_provider(v.provider) group by v.provider) x),'{}'::jsonb))
   from u where app_private.legacy_provider(u.provider)),
  -- Tavily's prepaid searches (no dollar ceiling): neither OpenRouter nor legacy.
  'search_unresolved',(select count(*) from u where u.provider='tavily' and u.created_at<now()-interval '1 hour'),
  'manual_held_microusd',(select coalesce(sum(u.ceiling_microusd),0) from u where u.created_at<now()-interval '1 hour'
   and (coalesce(u.tries,0)>=12 or u.provider<>'openrouter' or u.provider_request_id is null)),
  'reconciled_24h',(select count(*) from app_private.provider_attempt_adjustments j where j.actor_id is null and j.created_at>now()-interval '24 hours'
   and j.evidence_reference like 'openrouter-generation:%'))
$$;

-- As 0108, with the OpenRouter attempts the scheduled check fails on. `unknown_attempts_over_1h` (every provider) stays
-- in the base for builds of the check that predate this one.
create or replace function app_private.budget_health_extra() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('attempt_capacity_eighty_percent',coalesce((app_private.provider_attempt_window()->>'eighty_percent')::boolean,false),
  'tariffs_expiring_within_42d',jsonb_array_length(app_private.openrouter_tariff_attention()->'expiring'),
  'soonest_tariff_expiry',app_private.openrouter_tariff_attention()->'soonest_valid_until',
  'reconciliation',app_private.openrouter_reconcile_health(),
  'stale_sweep_failing',(select count(*) from app_private.stale_sweep_failures f join app_private.metered_operations m
   on (m.account_id,m.id)=(f.account_id,f.operation_id) where m.state<>'settled'),
  'unknown_openrouter_attempts_over_1h',(select count(*) from app_private.provider_attempts a
   where a.state='unknown' and a.provider='openrouter' and a.created_at<now()-interval '1 hour'))
$$;

-- Health's cache figure (migration 069 read `anthropic` usage only): OpenRouter's text calls over the same window.
alter function public.v1_admin_health(integer) rename to admin_health_before_0140;
alter function public.admin_health_before_0140(integer) set schema app_private;
revoke all on function app_private.admin_health_before_0140(integer) from public,anon,authenticated;
create function public.v1_admin_health(p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb; since timestamptz;
begin
 -- The earlier function checks the owner with MFA and the window before anything is read.
 base:=app_private.admin_health_before_0140(p_days);
 since:=((base->>'since')::date)::timestamp at time zone 'UTC';
 return base||jsonb_build_object('money',(base->'money')||jsonb_build_object('chat_cache',(select jsonb_build_object(
   'read_tokens',coalesce(sum((e.units->>'cache_read_tokens')::bigint),0),
   'write_tokens',coalesce(sum(coalesce((e.units->>'cache_write_5m_tokens')::bigint,0)+coalesce((e.units->>'cache_write_1h_tokens')::bigint,0)),0),
   'input_tokens',coalesce(sum((e.units->>'input_tokens')::bigint),0))
  from app_private.provider_usage_events e where e.provider='openrouter' and e.created_at>=since and e.units ? 'cache_read_tokens')));
end $$;
revoke all on function public.v1_admin_health(integer) from public,anon;
grant execute on function public.v1_admin_health(integer) to authenticated;

notify pgrst,'reload schema';
commit;
