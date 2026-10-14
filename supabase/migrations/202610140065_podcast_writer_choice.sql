-- Writer choice at podcast creation (owner 2026-10-14: "expose an option when creating a podcast to use anthropic or
-- sonnet"; docs/architecture/PAPER_PODCASTS.md "Writer choice"). The policy may now allow two versions of the same
-- length, one per writer (version 3: Claude Sonnet 5.5; version 5: DeepSeek V4 Pro); the lengths list carries the
-- writers of each length; the quote takes a writer and names it; a quote's start resolves the quote's own version.
-- Additive: without a writer the quote resolves the policy's default as before; version 4 is never offered.
begin;
set local lock_timeout='15s';

-- 1. The writer a profile spec names, and how the clients label it.
create function app_private.podcast_writer(spec jsonb) returns text language sql immutable set search_path='' as $$
 select coalesce(spec->'script'->>'provider','anthropic')
$$;
create function app_private.podcast_writer_label(spec jsonb) returns text language sql immutable set search_path='' as $$
 select case
  when coalesce(spec->'script'->>'provider','anthropic')='anthropic' and coalesce(spec->'script'->>'model','') like 'claude-sonnet-5-5%' then 'Claude Sonnet 5.5'
  when spec->'script'->>'model'='deepseek-v4-pro' then 'DeepSeek V4 Pro'
  when spec->'script'->>'model'='deepseek-flash' then 'DeepSeek Flash'
  else coalesce(spec->'script'->>'model','unknown') end
$$;
revoke all on function app_private.podcast_writer(jsonb),app_private.podcast_writer_label(jsonb) from public,anon,authenticated;

-- 2. The policy may list one version per writer for each length: distinct entries, distinct writers per id, up to 16.
alter table app_private.podcast_policy drop constraint podcast_policy_allowed_profiles_check;
alter table app_private.podcast_policy add constraint podcast_policy_allowed_profiles_check check(cardinality(allowed_profiles) between 1 and 16);
create or replace function app_private.podcast_policy_profiles_valid() returns trigger language plpgsql set search_path='' as $$
begin
 if exists(select 1 from unnest(new.allowed_profiles) e where e is null or e !~ '^[a-z][a-z0-9-]{2,47}:[1-9][0-9]{0,3}$'
   or not exists(select 1 from app_private.podcast_profiles p where p.id=split_part(e,':',1) and p.version=split_part(e,':',2)::integer))
  or (select count(distinct e) from unnest(new.allowed_profiles) e)<>cardinality(new.allowed_profiles)
  -- One version per writer for each length, or the choice would be ambiguous.
  or exists(select 1 from unnest(new.allowed_profiles) e join app_private.podcast_profiles p on p.id=split_part(e,':',1) and p.version=split_part(e,':',2)::integer
     group by p.id having count(*)<>count(distinct app_private.podcast_writer(p.spec)))
 then raise exception 'invalid_podcast_policy'; end if;
 return new;
end $$;

-- 3. The audited policy change accepts the longer list (053's text otherwise).
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
   if jsonb_typeof(item.value)<>'array' or jsonb_array_length(item.value) not between 1 and 16
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

-- 4. Resolution: a length and a writer (the default writer is the policy's default profile's).
drop function app_private.podcast_allowed_spec(text);
create function app_private.podcast_allowed_spec(p_profile text,p_writer text default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare pol app_private.podcast_policy; fallback jsonb; writer text; spec jsonb; found_id boolean;
begin
 select * into strict pol from app_private.podcast_policy where singleton;
 if p_profile is not null and p_profile !~ '^[a-z][a-z0-9-]{2,47}$' then raise exception 'podcast_profile_unavailable'; end if;
 if p_writer is not null and p_writer !~ '^[a-z][a-z0-9_-]{1,31}$' then raise exception 'podcast_writer_unavailable'; end if;
 select pr.spec into fallback from app_private.podcast_profiles pr where pr.id=pol.profile_id and pr.version=pol.profile_version;
 writer:=coalesce(p_writer,app_private.podcast_writer(fallback));
 select exists(select 1 from unnest(pol.allowed_profiles) e where split_part(e,':',1)=coalesce(p_profile,pol.profile_id)) into found_id;
 if not found_id then raise exception 'podcast_profile_unavailable'; end if;
 select pr.spec into spec from unnest(pol.allowed_profiles) e
  join app_private.podcast_profiles pr on pr.id=split_part(e,':',1) and pr.version=split_part(e,':',2)::integer
  where pr.id=coalesce(p_profile,pol.profile_id) and app_private.podcast_writer(pr.spec)=writer;
 if spec is null then
  -- No writer asked for: the default writer may not be offered for this length; take the length's first entry.
  if p_writer is null then
   select pr.spec into spec from unnest(pol.allowed_profiles) with ordinality as e(v,n)
    join app_private.podcast_profiles pr on pr.id=split_part(e.v,':',1) and pr.version=split_part(e.v,':',2)::integer
    where pr.id=coalesce(p_profile,pol.profile_id) order by e.n limit 1;
  end if;
  if spec is null then raise exception 'podcast_writer_unavailable'; end if;
 end if;
 return spec;
end $$;
revoke all on function app_private.podcast_allowed_spec(text,text) from public,anon,authenticated;

-- A quote's own version, as long as the policy still offers it.
create function app_private.podcast_allowed_version(p_profile text,p_version integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare pol app_private.podcast_policy; spec jsonb;
begin
 select * into strict pol from app_private.podcast_policy where singleton;
 if not (p_profile||':'||p_version::text)=any(pol.allowed_profiles) then raise exception 'podcast_profile_unavailable'; end if;
 select pr.spec into spec from app_private.podcast_profiles pr where pr.id=p_profile and pr.version=p_version;
 if spec is null then raise exception 'podcast_profile_unavailable'; end if;
 return spec;
end $$;
revoke all on function app_private.podcast_allowed_version(text,integer) from public,anon,authenticated;

-- 5. One row per length; the top-level figures are the default writer's (older clients read them as before), and
--    `writers` lists every offered writer of that length, the default first.
create or replace function app_private.podcast_lengths() returns jsonb
language sql stable security definer set search_path='' as $$
 with pol as (select p.*,app_private.podcast_writer((select d.spec from app_private.podcast_profiles d where d.id=p.profile_id and d.version=p.profile_version)) as default_writer
   from app_private.podcast_policy p where p.singleton),
 entries as (
  select pr.id,pr.spec,e.n,app_private.podcast_writer(pr.spec) as writer,
   (app_private.podcast_writer(pr.spec)=pol.default_writer) as is_default
  from pol cross join unnest(pol.allowed_profiles) with ordinality as e(v,n)
  join app_private.podcast_profiles pr on pr.id=split_part(e.v,':',1) and pr.version=split_part(e.v,':',2)::integer),
 heads as (
  select distinct on (id) id,spec from entries order by id,is_default desc,n)
 select coalesce(jsonb_agg(jsonb_build_object('profile',h.id,'label',app_private.podcast_label(h.spec),
   'target_seconds',(h.spec->>'target_seconds')::integer,'max_credits',(h.spec->>'max_credits')::integer,
   'estimate',app_private.podcast_estimate(h.spec),
   'writers',(select jsonb_agg(jsonb_build_object('writer',x.writer,'label',app_private.podcast_writer_label(x.spec),
      'max_credits',(x.spec->>'max_credits')::integer,'estimate',app_private.podcast_estimate(x.spec),'consent_version',x.spec->>'consent_version')
      order by x.is_default desc,x.n) from entries x where x.id=h.id))
  order by (h.spec->>'target_seconds')::integer),'[]'::jsonb)
 from heads h
$$;

-- 6. The quote takes a writer and names it (063's text otherwise); the old signature goes, the new one defaults it.
drop function public.v1_podcast_quote(uuid,uuid,text);
create function public.v1_podcast_quote(p_item_id uuid,p_request_id uuid,p_profile text default null,p_writer text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); pol app_private.podcast_policy; spec jsonb; pin jsonb; key bytea; q app_private.podcast_quotes;
 r app_private.podcast_releases; j app_private.podcast_jobs; req uuid; qspec jsonb;
begin
 perform public.worker_consume_request(a,'podcast-generate');
 if p_item_id is null or p_request_id is null then raise exception 'invalid_podcast_request'; end if;
 select * into strict pol from app_private.podcast_policy where singleton;
 if not pol.generation_enabled or not app_private.podcast_inventory_certified() then raise exception 'podcast_unavailable'; end if;
 if not exists(select 1 from app_private.accounts where id=a and closed_at is null and not spending_suspended) then raise exception 'account_unavailable'; end if;
 spec:=app_private.podcast_allowed_spec(p_profile,p_writer);
 select * into q from app_private.podcast_quotes where account_id=a and request_id=p_request_id;
 if found then
  -- The same request id names the same paper, length and writer, or it is a different request.
  if q.item_id<>p_item_id or (q.profile_id,q.profile_version)<>(spec->>'id',(spec->>'version')::integer) then raise exception 'podcast_request_conflict'; end if;
  if q.expires_at<=now() then raise exception 'quote_expired'; end if;
 else
  pin:=app_private.podcast_item_pin(a,p_item_id);
  if pin is null then raise exception 'source_unavailable'; end if;
  if (pin->>'text_bytes')::bigint>(spec->>'max_source_bytes')::bigint then raise exception 'source_too_large'; end if;
  key:=app_private.podcast_work_key('private',a,spec,pin);
  select x.* into r from app_private.podcast_releases x join app_private.podcast_episode_keys k on k.id=x.episode_id
   where k.scope='private' and k.owner_id=a and k.work_sha256=key and x.state='ready' limit 1;
  if found then return jsonb_build_object('reuse',jsonb_build_object('release_id',r.id)); end if;
  select x.* into j from app_private.podcast_jobs x join app_private.podcast_episode_keys k on k.id=x.episode_id
   where k.scope='private' and k.owner_id=a and k.work_sha256=key and x.finished_at is null and x.state not in ('unknown_provider','quarantined') limit 1;
  if found then
   select request_id into req from app_private.podcast_requests where account_id=a and job_id=j.id order by created_at limit 1;
   return jsonb_build_object('join',jsonb_build_object('request_id',req));
  end if;
  if app_private.podcast_account_unresolved(a) then raise exception 'podcast_outcome_pending'; end if;
  if (select count(*) from app_private.podcast_quotes where account_id=a and created_at>now()-interval '1 day')>=50 then raise exception 'request_rate_limit'; end if;
  insert into app_private.podcast_quotes(account_id,request_id,item_id,work_sha256,pin,profile_id,profile_version,max_credits,max_microusd,epoch,consent_version,expires_at)
   values(a,p_request_id,p_item_id,key,pin,spec->>'id',(spec->>'version')::integer,(spec->>'max_credits')::bigint,(spec->>'hold_microusd')::bigint,
    pol.epoch,spec->>'consent_version',now()+interval '15 minutes') returning * into q;
 end if;
 select pr.spec into strict qspec from app_private.podcast_profiles pr where (pr.id,pr.version)=(q.profile_id,q.profile_version);
 return jsonb_build_object('quote',jsonb_build_object('id',q.id,'expires_at',q.expires_at,'max_credits',q.max_credits,
  'estimate',app_private.podcast_estimate(qspec),
  'providers',jsonb_build_array(app_private.podcast_script_provider_label(qspec),'Google Vertex AI (speech)'),'consent_version',q.consent_version,
  'target_seconds',(qspec->>'target_seconds')::integer,'profile',q.profile_id,'label',app_private.podcast_label(qspec),
  'writer',app_private.podcast_writer(qspec),'writer_label',app_private.podcast_writer_label(qspec)),
  'options',app_private.podcast_lengths());
end $$;
revoke all on function public.v1_podcast_quote(uuid,uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function public.v1_podcast_quote(uuid,uuid,text,text) to authenticated;

-- 7. The start resolves the quote's own version (063's text otherwise).
create or replace function public.v1_podcast_start(p_quote_id uuid,p_request_id uuid,p_consent_version text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); month date:=app_private.podcast_month(); pol app_private.podcast_policy; q app_private.podcast_quotes;
 prior app_private.podcast_requests; spec jsonb; pin jsonb; episode uuid; r app_private.podcast_releases; j app_private.podcast_jobs; op uuid; req uuid;
begin
 perform public.worker_consume_request(a,'podcast-generate');
 if p_quote_id is null or p_request_id is null then raise exception 'invalid_podcast_request'; end if;
 select * into prior from app_private.podcast_requests where account_id=a and request_id=p_request_id;
 if found then
  if prior.quote_id<>p_quote_id then raise exception 'podcast_request_conflict'; end if;
  if prior.outcome='reused' then return jsonb_build_object('reuse',jsonb_build_object('release_id',prior.release_id)); end if;
  select * into strict j from app_private.podcast_jobs where id=prior.job_id;
  return jsonb_build_object('job',app_private.podcast_job_public(j,p_request_id));
 end if;
 -- Budget -> account -> provider policy -> podcast policy, as every financial path.
 perform 1 from app_private.platform_budgets where period=month for update;
 perform 1 from app_private.accounts where id=a and closed_at is null and not spending_suspended for update;
 if not found then raise exception 'account_unavailable'; end if;
 perform 1 from app_private.provider_spending_policy where singleton for update;
 select * into strict pol from app_private.podcast_policy where singleton for update;
 if not pol.generation_enabled or not app_private.podcast_inventory_certified() then raise exception 'podcast_unavailable'; end if;
 select * into q from app_private.podcast_quotes where id=p_quote_id and account_id=a;
 if not found then raise exception 'quote_unavailable'; end if;
 -- The consent the quote named (its profile's providers), not a fixed version: a DeepSeek quote needs podcast-private-v2.
 if p_consent_version is distinct from q.consent_version then raise exception 'consent_required'; end if;
 if q.expires_at<=now() or q.epoch<>pol.epoch then raise exception 'quote_expired'; end if;
 -- The quoted length and writer, still offered (an operator may have withdrawn that version since).
 spec:=app_private.podcast_allowed_version(q.profile_id,q.profile_version);
 -- The quote never authorizes later changes to its source or options.
 pin:=app_private.podcast_item_pin(a,q.item_id);
 if pin is distinct from q.pin or app_private.podcast_work_key('private',a,spec,pin)<>q.work_sha256
  or (spec->>'id',(spec->>'version')::integer)<>(q.profile_id,q.profile_version) then raise exception 'quote_expired'; end if;
 select x.* into r from app_private.podcast_releases x join app_private.podcast_episode_keys k on k.id=x.episode_id
  where k.scope='private' and k.owner_id=a and k.work_sha256=q.work_sha256 and x.state='ready' limit 1;
 if found then
  insert into app_private.podcast_requests(account_id,request_id,quote_id,release_id,outcome) values(a,p_request_id,q.id,r.id,'reused');
  return jsonb_build_object('reuse',jsonb_build_object('release_id',r.id));
 end if;
 select x.* into j from app_private.podcast_jobs x join app_private.podcast_episode_keys k on k.id=x.episode_id
  where k.scope='private' and k.owner_id=a and k.work_sha256=q.work_sha256 and x.finished_at is null and x.state not in ('unknown_provider','quarantined') for update of x;
 if found then
  insert into app_private.podcast_requests(account_id,request_id,quote_id,job_id,outcome) values(a,p_request_id,q.id,j.id,'joined');
  return jsonb_build_object('job',app_private.podcast_job_public(j,p_request_id));
 end if;
 if (select count(*) from app_private.podcast_jobs x join app_private.podcast_episode_keys k on k.id=x.episode_id
   where k.owner_id=a and x.funding_kind='customer' and x.state in ('queued','scripting','checking','synthesizing','verifying','publishing','capacity_wait'))>=pol.max_active_private_per_account
  then raise exception 'active_generation_limit'; end if;
 if (select count(*) from app_private.podcast_jobs where state in ('queued','scripting','checking','synthesizing','verifying','publishing'))>=pol.max_active_environment
  then raise exception 'podcast_busy'; end if;
 if (select count(*) from app_private.podcast_jobs where created_at>now()-interval '1 day')>=pol.max_jobs_day_environment then raise exception 'podcast_daily_limit'; end if;
 if app_private.podcast_customer_losses(month)>=pol.quality_allocation_microusd then raise exception 'podcast_paused'; end if;
 if app_private.podcast_account_unresolved(a) then raise exception 'podcast_outcome_pending'; end if;
 op:=gen_random_uuid();
 perform public.worker_reserve_operation(a,op,'podcast',sha256(convert_to(jsonb_build_array('gradstep/podcast-private/v1',a,p_request_id,q.id,encode(q.work_sha256,'hex'))::text,'UTF8')),
  'beta-credits-v1',q.max_credits,q.max_microusd);
 episode:=app_private.podcast_insert_episode('private',a,spec,pin);
 insert into app_private.podcast_jobs(episode_id,origin,funding_kind,operation_account_id,operation_id,epoch)
  values(episode,'generated','customer',a,op,pol.epoch) returning * into j;
 update app_private.podcast_jobs set kicked_at=clock_timestamp() where id=j.id returning * into j;
 insert into app_private.podcast_asset_holds(job_id,owner_id,bytes,objects)
  values(j.id,a,(spec->'storage'->>'bytes')::bigint,(spec->'storage'->>'objects')::integer);
 begin perform app_private.paper_asset_check_capacity(a);
 exception when raise_exception then
  if sqlerrm in ('paper_storage_capacity','paper_owner_storage_capacity') then raise exception 'storage_full'; end if; raise;
 end;
 insert into app_private.podcast_requests(account_id,request_id,quote_id,job_id,outcome) values(a,p_request_id,q.id,j.id,'started');
 perform app_private.podcast_event(j.id,'admitted',jsonb_build_object('funding','customer','hold_credits',q.max_credits,'hold_microusd',q.max_microusd));
 perform app_private.podcast_kick();
 return jsonb_build_object('job',app_private.podcast_job_public(j,p_request_id));
end $$;
revoke all on function public.v1_podcast_start(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.v1_podcast_start(uuid,uuid,text) to authenticated;

notify pgrst,'reload schema';
commit;
