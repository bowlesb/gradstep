-- Seed pilot cap raised to $5 total (docs/DECISIONS.md, "Seed pilot cap"; docs/architecture/PAPER_PODCASTS.md,
-- "Seed pilot fix 3"). On 2026-10-08 the owner approved "Raise to $5 total" after three five-minute seed
-- attempts failed on staging with $1.00 of the $2 allowance committed. Only the dollar bound changes:
--
-- - a seed period's limit may now be at most 5,000,000 micro-USD (was 2,000,000), both in the table check and
--   in worker_podcast_seed_period's argument validation;
-- - each admission still holds the five-minute profile's $0.75 (hold_microusd, immutable profile rows);
-- - at most 2 seed episodes per period (max_episodes between 0 and 2, unchanged; 049's count of in-flight
--   and produced episodes is unchanged);
-- - seed spend stays inside the existing $25 provider cap and the platform budget (admission reserves the
--   operator's operation against them as before); nothing is added on top of them.
--
-- Existing periods keep their configured limit: the operator raises the current one explicitly with
-- `podcast-ops.py seed-period --limit-usd 5`, which is audited as a policy event. worker_podcast_seed_period is
-- recreated with the same signature, body and lock order as in 048 apart from the bound, security definer with
-- an empty search_path and the same grants. Migration 050's checker-report recorder needs no change for
-- checker v4's reason codes (codes and segment ids at the validator's depth limit), so it is not touched.
begin;

alter table app_private.podcast_seed_periods drop constraint podcast_seed_periods_limit_microusd_check;
alter table app_private.podcast_seed_periods add constraint podcast_seed_periods_limit_microusd_check
 check(limit_microusd between 0 and 5000000);

-- A dated seed allowance. The owner-approved ceiling is $5 per period at most (2026-10-08; was $2).
create or replace function public.worker_podcast_seed_period(p_actor uuid,p_request_id uuid,p_period date,p_limit_microusd bigint,p_enabled boolean,p_evidence text,
 p_max_episodes integer default 2) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s app_private.podcast_seed_periods; changes jsonb; prior app_private.podcast_policy_events;
begin
 perform app_private.require_owner_account(p_actor);
 if p_request_id is null or p_period is null or extract(day from p_period)<>1 or p_limit_microusd is null or p_limit_microusd not between 0 and 5000000
  or p_enabled is null or p_evidence is null or length(p_evidence) not between 3 and 256 or p_evidence !~ '^[a-zA-Z0-9._:/ -]+$'
  or p_max_episodes is null or p_max_episodes not between 0 and 2
 then raise exception 'invalid_seed_period'; end if;
 perform 1 from app_private.platform_budgets where period=p_period for update;
 if not found then raise exception 'platform_budget_unavailable'; end if;
 perform 1 from app_private.podcast_policy where singleton for update;
 changes:=jsonb_build_object('seed_period',p_period,'limit_microusd',p_limit_microusd,'enabled',p_enabled,'evidence',p_evidence,'max_episodes',p_max_episodes);
 select * into prior from app_private.podcast_policy_events where id=p_request_id;
 if found then
  if prior.changes<>changes or prior.actor_id<>p_actor then raise exception 'podcast_policy_id_conflict'; end if;
  select * into strict s from app_private.podcast_seed_periods where period=p_period;
  return to_jsonb(s)||jsonb_build_object('committed_microusd',app_private.podcast_seed_committed(p_period),'replayed',true);
 end if;
 if p_enabled and not app_private.podcast_inventory_certified() then raise exception 'asset_inventory_incomplete'; end if;
 insert into app_private.podcast_seed_periods(period,limit_microusd,max_episodes,enabled,evidence_reference,configured_by)
  values(p_period,p_limit_microusd,p_max_episodes,p_enabled,p_evidence,p_actor)
  on conflict(period) do update set limit_microusd=excluded.limit_microusd,max_episodes=excluded.max_episodes,enabled=excluded.enabled,
   evidence_reference=excluded.evidence_reference,configured_by=excluded.configured_by,configured_at=now()
  returning * into s;
 insert into app_private.podcast_policy_events(id,actor_id,changes,reason,revision)
  values(p_request_id,p_actor,changes,'Seed allowance '||p_evidence,(select revision from app_private.podcast_policy where singleton));
 return to_jsonb(s)||jsonb_build_object('committed_microusd',app_private.podcast_seed_committed(p_period),'replayed',false);
end $$;

-- As in 048: operator RPC for the service role only.
revoke all on function public.worker_podcast_seed_period(uuid,uuid,date,bigint,boolean,text,integer) from public,anon,authenticated,service_role;
grant execute on function public.worker_podcast_seed_period(uuid,uuid,date,bigint,boolean,text,integer) to service_role;

notify pgrst,'reload schema';
commit;
