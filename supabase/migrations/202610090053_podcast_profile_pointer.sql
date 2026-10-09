-- Allow an audited rollout to move the default/seed profile pointer together
-- with its allowlist. Migration 052 staged serving-limit profile rows; this
-- keeps a policy from offering v2 privately while seeds or capabilities still
-- resolve the v1 default.
begin;

create or replace function public.worker_podcast_policy_set(p_actor uuid,p_request_id uuid,p_changes jsonb,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 pol app_private.podcast_policy;
 prior app_private.podcast_policy_events;
 item record;
 enabling boolean:=false;
 next_profile_id text;
 next_profile_version integer;
 next_allowed text[];
begin
 perform app_private.require_owner_account(p_actor);
 if p_request_id is null or p_changes is null or jsonb_typeof(p_changes)<>'object' or p_changes='{}'::jsonb or octet_length(p_changes::text)>2048
  or p_reason is null or length(trim(p_reason)) not between 3 and 500 then raise exception 'invalid_podcast_policy'; end if;
 select * into strict pol from app_private.podcast_policy where singleton for update;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select * into prior from app_private.podcast_policy_events where id=p_request_id;
 if found then
  if prior.changes<>p_changes or prior.actor_id<>p_actor then raise exception 'podcast_policy_id_conflict'; end if;
  return to_jsonb(pol)||jsonb_build_object('replayed',true);
 end if;
 for item in select key,value from jsonb_each(p_changes) loop
  if item.key in ('catalog_enabled','delivery_enabled','generation_enabled','seed_enabled','fixtures_enabled') then
   if jsonb_typeof(item.value)<>'boolean' then raise exception 'invalid_podcast_policy'; end if;
   enabling:=enabling or (item.value::text='true' and item.key<>'catalog_enabled');
  elsif item.key in ('max_active_private_per_account','max_active_environment','max_jobs_day_environment','quality_allocation_microusd',
   'account_transfer_bytes_month','paid_account_transfer_bytes_month','environment_transfer_bytes_month') then
   if jsonb_typeof(item.value)<>'number' or item.value::text !~ '^[0-9]{1,12}$' then raise exception 'invalid_podcast_policy'; end if;
  elsif item.key='profile_version' then
   if jsonb_typeof(item.value)<>'number' or item.value::text !~ '^[1-9][0-9]{0,3}$' then raise exception 'invalid_podcast_policy'; end if;
  elsif item.key='profile_id' then
   if jsonb_typeof(item.value)<>'string' or item.value::text !~ '^"[a-z][a-z0-9-]{2,47}"$' then raise exception 'invalid_podcast_policy'; end if;
  elsif item.key='allowed_profiles' then
   if jsonb_typeof(item.value)<>'array' or jsonb_array_length(item.value) not between 1 and 8
    or exists(select 1 from jsonb_array_elements(item.value) e where jsonb_typeof(e)<>'string') then raise exception 'invalid_podcast_policy'; end if;
  else raise exception 'invalid_podcast_policy'; end if;
 end loop;
 if enabling and not app_private.podcast_inventory_certified() then raise exception 'asset_inventory_incomplete'; end if;
 next_profile_id:=coalesce(p_changes->>'profile_id',pol.profile_id);
 next_profile_version:=coalesce((p_changes->>'profile_version')::integer,pol.profile_version);
 next_allowed:=coalesce((select array_agg(e order by n) from jsonb_array_elements_text(p_changes->'allowed_profiles') with ordinality x(e,n)),pol.allowed_profiles);
 if not exists(select 1 from app_private.podcast_profiles where id=next_profile_id and version=next_profile_version)
  or not exists(select 1 from unnest(next_allowed) e where e=next_profile_id||':'||next_profile_version::text)
 then raise exception 'invalid_podcast_policy'; end if;
 update app_private.podcast_policy set
  catalog_enabled=coalesce((p_changes->>'catalog_enabled')::boolean,catalog_enabled),
  delivery_enabled=coalesce((p_changes->>'delivery_enabled')::boolean,delivery_enabled),
  generation_enabled=coalesce((p_changes->>'generation_enabled')::boolean,generation_enabled),
  seed_enabled=coalesce((p_changes->>'seed_enabled')::boolean,seed_enabled),
  fixtures_enabled=coalesce((p_changes->>'fixtures_enabled')::boolean,fixtures_enabled),
  profile_id=next_profile_id, profile_version=next_profile_version,
  max_active_private_per_account=coalesce((p_changes->>'max_active_private_per_account')::integer,max_active_private_per_account),
  max_active_environment=coalesce((p_changes->>'max_active_environment')::integer,max_active_environment),
  max_jobs_day_environment=coalesce((p_changes->>'max_jobs_day_environment')::integer,max_jobs_day_environment),
  quality_allocation_microusd=coalesce((p_changes->>'quality_allocation_microusd')::bigint,quality_allocation_microusd),
  account_transfer_bytes_month=coalesce((p_changes->>'account_transfer_bytes_month')::bigint,account_transfer_bytes_month),
  paid_account_transfer_bytes_month=coalesce((p_changes->>'paid_account_transfer_bytes_month')::bigint,paid_account_transfer_bytes_month),
  environment_transfer_bytes_month=coalesce((p_changes->>'environment_transfer_bytes_month')::bigint,environment_transfer_bytes_month),
  allowed_profiles=next_allowed,
  revision=revision+1,updated_at=now()
 where singleton returning * into pol;
 insert into app_private.podcast_policy_events(id,actor_id,changes,reason,revision) values(p_request_id,p_actor,p_changes,trim(p_reason),pol.revision);
 return to_jsonb(pol)||jsonb_build_object('replayed',false);
end $$;

revoke all on function public.worker_podcast_policy_set(uuid,uuid,jsonb,text) from public,anon,authenticated,service_role;
grant execute on function public.worker_podcast_policy_set(uuid,uuid,jsonb,text) to service_role;

notify pgrst,'reload schema';
commit;
