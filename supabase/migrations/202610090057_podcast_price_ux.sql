-- Podcast price UX: distinguish the observed beta usage from the hard provider hold.
-- This changes display text only. The profile ceilings, reservations and settlement rules stay immutable.
begin;

create or replace function app_private.podcast_estimate(p_spec jsonb) returns text
language sql immutable set search_path='' as $$
 select case
   when p_spec->>'id'='podcast-5min-v1' and coalesce((p_spec->>'version')::integer,0)=2
   then 'Estimate — recent beta examples used about 55–60 credits; actual usage varies, maximum '||(p_spec->>'max_credits')||' credits'
   else 'Estimate — you''re charged actual usage, maximum '||(p_spec->>'max_credits')||' credits'
 end
$$;

create or replace function app_private.podcast_lengths() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('profile',pr.id,'label',app_private.podcast_label(pr.spec),
   'target_seconds',(pr.spec->>'target_seconds')::integer,'max_credits',(pr.spec->>'max_credits')::integer,
   'estimate',app_private.podcast_estimate(pr.spec))
  order by (pr.spec->>'target_seconds')::integer),'[]'::jsonb)
 from app_private.podcast_policy p cross join unnest(p.allowed_profiles) e
  join app_private.podcast_profiles pr on pr.id=split_part(e,':',1) and pr.version=split_part(e,':',2)::integer
 where p.singleton
$$;

create or replace function public.v1_podcast_quote(p_item_id uuid,p_request_id uuid,p_profile text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); pol app_private.podcast_policy; spec jsonb; pin jsonb; key bytea; q app_private.podcast_quotes;
 r app_private.podcast_releases; j app_private.podcast_jobs; req uuid; qspec jsonb;
begin
 perform public.worker_consume_request(a,'podcast-generate');
 if p_item_id is null or p_request_id is null then raise exception 'invalid_podcast_request'; end if;
 select * into strict pol from app_private.podcast_policy where singleton;
 if not pol.generation_enabled or not app_private.podcast_inventory_certified() then raise exception 'podcast_unavailable'; end if;
 if not exists(select 1 from app_private.accounts where id=a and closed_at is null and not spending_suspended) then raise exception 'account_unavailable'; end if;
 spec:=app_private.podcast_allowed_spec(p_profile);
 select * into q from app_private.podcast_quotes where account_id=a and request_id=p_request_id;
 if found then
  if q.item_id<>p_item_id or q.profile_id<>spec->>'id' then raise exception 'podcast_request_conflict'; end if;
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
  'providers',jsonb_build_array('Anthropic (script)','Google Vertex AI (speech)'),'consent_version',q.consent_version,
  'target_seconds',(qspec->>'target_seconds')::integer,'profile',q.profile_id,'label',app_private.podcast_label(qspec)),
  'options',app_private.podcast_lengths());
end $$;

revoke all on function app_private.podcast_estimate(jsonb) from public,anon,authenticated;
revoke all on function public.v1_podcast_quote(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.v1_podcast_quote(uuid,uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
