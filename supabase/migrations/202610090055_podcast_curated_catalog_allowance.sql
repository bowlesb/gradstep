-- Owner decision 2026-10-09: keep a small weekly curated catalog allowance,
-- roughly ten candidates per month but always bound by the $3 period cap and
-- the $25 platform budget. A count ceiling of ten prevents an accidental
-- unbounded scheduler; the dollar cap remains the binding admission check.
begin;

alter table app_private.podcast_seed_periods drop constraint podcast_seed_periods_max_episodes_check;
alter table app_private.podcast_seed_periods add constraint podcast_seed_periods_max_episodes_check
 check(max_episodes between 0 and 10);

create or replace function public.worker_podcast_seed_period(p_actor uuid,p_request_id uuid,p_period date,p_limit_microusd bigint,p_enabled boolean,p_evidence text,
 p_max_episodes integer default 2) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s app_private.podcast_seed_periods; changes jsonb; prior app_private.podcast_policy_events;
begin
 perform app_private.require_owner_account(p_actor);
 if p_request_id is null or p_period is null or extract(day from p_period)<>1 or p_limit_microusd is null or p_limit_microusd not between 0 and 5000000
  or p_enabled is null or p_evidence is null or length(p_evidence) not between 3 and 256 or p_evidence !~ '^[a-zA-Z0-9._:/ -]+$'
  or p_max_episodes is null or p_max_episodes not between 0 and 10
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

revoke all on function public.worker_podcast_seed_period(uuid,uuid,date,bigint,boolean,text,integer) from public,anon,authenticated,service_role;
grant execute on function public.worker_podcast_seed_period(uuid,uuid,date,bigint,boolean,text,integer) to service_role;

notify pgrst,'reload schema';
commit;
