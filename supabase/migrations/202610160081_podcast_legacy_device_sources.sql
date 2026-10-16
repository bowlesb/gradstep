-- 081: Listen on an arXiv paper that joined the library before the HTML-first reader (a legacy library item) makes its
-- episode from the text prepared on the device, as chat does since migration 080 (#6). The server's paper copies were
-- deleted on 2026-10-16 (docs/architecture/DATA_HANDLING_AND_COSTS.md "Server paper copies: retired"), so such an item
-- has no server text to pin (podcast_item_pin answers nothing, the quote source_unavailable). A device source
-- (migration 066) already names its paper by a membership id; here that id may be the legacy library item's own id:
--  1. podcast_device_pin: when the id is one of the account's library items, the item must be in the library (not
--     removed) and its catalog record must be that exact arXiv source and revision (as worker_local_chat_context
--     checks for chat); otherwise nothing is pinned (source_unavailable). Any other id behaves exactly as in 076.
--  2. v1_podcast_paper on a library item also finds the account's device episodes, jobs and lengths named by that item.
--  3. A device episode named by a library item belongs to the item's document: podcast_episode_public.document_id and
--     the catalog's `mine` list (podcast_mine) give the document id, which is how both clients identify a legacy paper
--     (browser paperIdentity, native Paper.id). Episodes of source memberships keep their membership id.
-- The worker's claim keeps the membership id as the transcript's internal source name (never sent to clients).
-- Additive: functions are wrapped or replaced; no table or row changes.
begin;
set local lock_timeout='15s';

-- The paper a device episode belongs to: a legacy library item's document, else the membership id itself.
create function app_private.podcast_device_paper(p_owner uuid,p_membership uuid) returns uuid
language sql stable security definer set search_path='' as $$
 select coalesce((select li.document_id from app_private.library_items li where li.account_id=p_owner and li.id=p_membership),p_membership)
$$;

-- 1. The device pin: a library item's id pins only its own exact arXiv source and revision.
alter function app_private.podcast_device_pin(uuid,jsonb) rename to podcast_device_pin_before_081;
create function app_private.podcast_device_pin(p_account uuid,p_device jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare membership uuid; rev integer;
begin
 if p_account is null or p_device is null or jsonb_typeof(p_device)<>'object' then return null; end if;
 begin
  membership:=(p_device->>'membership_id')::uuid; rev:=(p_device->>'revision')::integer;
 exception when others then return null; end;
 if membership is not null and exists(select 1 from app_private.library_items li where li.account_id=p_account and li.id=membership) then
  if not exists(select 1 from app_private.library_items li join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
    join app_private.catalog_metadata cm on cm.id=ca.metadata_id
    where li.account_id=p_account and li.id=membership and li.removed_at is null
     and cm.source_id=p_device->>'source_id' and cm.source_revision=rev and cm.source_id !~ '^(openalex|upload):') then
   return null;
  end if;
 end if;
 return app_private.podcast_device_pin_before_081(p_account,p_device);
end $$;

-- 2. A paper's episodes: a library item's document and its device episodes, or a device-source paper by membership id.
create or replace function public.v1_podcast_paper(p_item_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); doc uuid; r app_private.podcast_releases; j app_private.podcast_jobs; req uuid; lengths jsonb; device boolean:=false;
begin
 perform public.worker_consume_request(a,'podcast-read');
 select document_id into doc from app_private.library_items where account_id=a and id=p_item_id and removed_at is null;
 if not found then
  -- Not a library item: a paper read on this device (its episodes, if any, carry its membership id). An unknown id
  -- with no episodes is still a valid answer (nothing yet; the capabilities say what can be made).
  device:=true;
 end if;
 if device then
  select x.* into r from app_private.podcast_releases x join app_private.podcast_device_sources d on d.episode_id=x.episode_id
   where d.owner_id=a and d.membership_id=p_item_id and x.scope='private' and x.owner_id=a and x.state='ready' order by x.published_seq desc limit 1;
  select x.* into j from app_private.podcast_jobs x join app_private.podcast_episode_keys k on k.id=x.episode_id and k.scope='private' and k.owner_id=a
   join app_private.podcast_device_sources d on d.episode_id=x.episode_id
   where d.owner_id=a and d.membership_id=p_item_id and x.funding_kind='customer' and x.finished_at is null order by x.created_at desc limit 1;
  if j.id is not null then select request_id into req from app_private.podcast_requests where account_id=a and job_id=j.id order by created_at limit 1; end if;
  select coalesce(jsonb_agg(app_private.podcast_episode_public(z.release) order by z.seconds),'[]'::jsonb) into lengths
   from (select distinct on (k.profile_id) x as release,(pr.spec->>'target_seconds')::integer seconds from app_private.podcast_releases x
     join app_private.podcast_episode_keys k on k.id=x.episode_id join app_private.podcast_device_sources d on d.episode_id=x.episode_id
     join app_private.podcast_profiles pr on (pr.id,pr.version)=(k.profile_id,k.profile_version)
    where d.owner_id=a and d.membership_id=p_item_id and x.state='ready' and x.scope='private' and x.owner_id=a
    order by k.profile_id,x.published_seq desc) z;
  return jsonb_build_object('episode',case when r.id is not null then app_private.podcast_episode_public(r) end,'episodes',lengths,
   'job',case when j.id is not null then app_private.podcast_job_public(j,req) end,'capabilities',app_private.podcast_capabilities(a));
 end if;
 -- A library item: its document's episodes as before, and (081) the account's own device episodes named by the item.
 select x.* into r from app_private.podcast_releases x
  where x.scope='private' and x.owner_id=a and x.state='ready'
   and (exists(select 1 from app_private.podcast_sources s where s.episode_id=x.episode_id and s.ordinal=0 and s.document_id=doc)
    or exists(select 1 from app_private.podcast_device_sources d where d.episode_id=x.episode_id and d.owner_id=a and d.membership_id=p_item_id))
  order by x.published_seq desc limit 1;
 if not found then
  select x.* into r from app_private.podcast_releases x join app_private.podcast_sources s on s.episode_id=x.episode_id and s.ordinal=0
   where s.document_id=doc and x.scope='shared' and x.state='ready' and app_private.podcast_rights_current(x.episode_id,null)
    and (select catalog_enabled from app_private.podcast_policy where singleton)
   order by x.published_seq desc limit 1;
 end if;
 select x.* into j from app_private.podcast_jobs x join app_private.podcast_episode_keys k on k.id=x.episode_id and k.scope='private' and k.owner_id=a
  where x.funding_kind='customer' and x.finished_at is null
   and (exists(select 1 from app_private.podcast_sources s where s.episode_id=x.episode_id and s.ordinal=0 and s.document_id=doc)
    or exists(select 1 from app_private.podcast_device_sources d where d.episode_id=x.episode_id and d.owner_id=a and d.membership_id=p_item_id))
  order by x.created_at desc limit 1;
 if j.id is not null then select request_id into req from app_private.podcast_requests where account_id=a and job_id=j.id order by created_at limit 1; end if;
 -- Every playable length for this paper (each length is its own work key): the
 -- account's newest private release per length, else the newest shared one.
 select coalesce(jsonb_agg(app_private.podcast_episode_public(z.release) order by z.seconds),'[]'::jsonb) into lengths
  from (select distinct on (k.profile_id) x as release,(pr.spec->>'target_seconds')::integer seconds from app_private.podcast_releases x
    join app_private.podcast_episode_keys k on k.id=x.episode_id
    join app_private.podcast_profiles pr on (pr.id,pr.version)=(k.profile_id,k.profile_version)
   where x.state='ready' and (
    (exists(select 1 from app_private.podcast_sources s where s.episode_id=x.episode_id and s.ordinal=0 and s.document_id=doc)
     and ((x.scope='private' and x.owner_id=a)
      or (x.scope='shared' and app_private.podcast_rights_current(x.episode_id,null) and (select catalog_enabled from app_private.podcast_policy where singleton))))
    or (x.scope='private' and x.owner_id=a
     and exists(select 1 from app_private.podcast_device_sources d where d.episode_id=x.episode_id and d.owner_id=a and d.membership_id=p_item_id)))
   order by k.profile_id,(x.scope='private') desc,x.published_seq desc) z;
 return jsonb_build_object('episode',case when r.id is not null then app_private.podcast_episode_public(r) end,'episodes',lengths,
  'job',case when j.id is not null then app_private.podcast_job_public(j,req) end,'capabilities',app_private.podcast_capabilities(a));
end $$;

-- 3. A device episode named by a legacy library item belongs to the item's document (as migration 066 otherwise).
create or replace function app_private.podcast_episode_public(r app_private.podcast_releases) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('release_id',r.id,'scope',r.scope,'state',r.state,'fixture',r.origin='fixture','ai_audio',true,'language','en',
  'duration_ms',r.duration_ms,'published_at',r.published_at,
  'document_id',coalesce((select s.document_id from app_private.podcast_sources s where s.episode_id=r.episode_id and s.ordinal=0),
   (select app_private.podcast_device_paper(d.owner_id,d.membership_id) from app_private.podcast_device_sources d where d.episode_id=r.episode_id)),
  'title',r.public_metadata->>'title','year',(r.public_metadata->>'year')::integer,'authors',coalesce(r.public_metadata->'authors','[]'::jsonb),
  'topic',r.public_metadata->>'topic','source',coalesce(r.public_metadata->'source',
   (select jsonb_build_object('arxiv_id',d.source_id,'version',d.revision,'url','https://arxiv.org/abs/'||d.source_id||'v'||d.revision,'license',null)
    from app_private.podcast_device_sources d where d.episode_id=r.episode_id),
   jsonb_build_object('arxiv_id',null,'version',null,'url',null,'license',null)),
  'audio',(select jsonb_build_object('bytes',o.byte_count,'sha256',encode(o.sha256,'hex'),'media_type',o.media_type)
   from app_private.podcast_release_objects ro join app_private.stored_objects o on o.id=ro.object_id where ro.release_id=r.id and ro.role='audio'),
  'replacement_id',r.replacement_id,
  'profile',(select k.profile_id from app_private.podcast_episode_keys k where k.id=r.episode_id),
  'label',(select app_private.podcast_label(pr.spec) from app_private.podcast_episode_keys k join app_private.podcast_profiles pr
    on (pr.id,pr.version)=(k.profile_id,k.profile_version) where k.id=r.episode_id),
  'target_seconds',(select (pr.spec->>'target_seconds')::integer from app_private.podcast_episode_keys k join app_private.podcast_profiles pr
    on (pr.id,pr.version)=(k.profile_id,k.profile_version) where k.id=r.episode_id))
$$;

-- The account's own episodes and requests (migration 076), each named by the same paper id as above.
create or replace function app_private.podcast_mine(a uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 with paper as (
  select k.id episode_id,coalesce(s.document_id,app_private.podcast_device_paper(d.owner_id,d.membership_id)) paper_id,
   coalesce(d.title,left(cm.metadata->>'title',300)) title
  from app_private.podcast_episode_keys k
  left join app_private.podcast_sources s on s.episode_id=k.id and s.ordinal=0
  left join app_private.catalog_metadata cm on cm.id=s.metadata_id
  left join app_private.podcast_device_sources d on d.episode_id=k.id
  where k.scope='private' and k.owner_id=a),
 asked as (
  select distinct on (j.id) j.*,q.request_id,p.paper_id,p.title,k.profile_id,pr.spec
  from app_private.podcast_requests q join app_private.podcast_jobs j on j.id=q.job_id
  join app_private.podcast_episode_keys k on k.id=j.episode_id
  join app_private.podcast_profiles pr on (pr.id,pr.version)=(k.profile_id,k.profile_version)
  join paper p on p.episode_id=j.episode_id
  where q.account_id=a and j.funding_kind='customer' and j.created_at>now()-interval '30 days'
  order by j.id,q.created_at)
 select jsonb_build_object(
  'episodes',coalesce((select jsonb_agg(e order by seq desc) from (
    select app_private.podcast_episode_public(x)||jsonb_build_object('title',coalesce(x.public_metadata->>'title',p.title),
      'request_id',(select q.request_id from app_private.podcast_requests q where q.account_id=a and q.job_id=x.job_id order by q.created_at limit 1)) e,
     x.published_seq seq
    from app_private.podcast_releases x join paper p on p.episode_id=x.episode_id
    where x.scope='private' and x.owner_id=a and x.state='ready' order by x.published_seq desc limit 50) z),'[]'::jsonb),
  'requests',coalesce((select jsonb_agg(r order by created desc) from (
    select jsonb_build_object('request_id',j.request_id,'status',case when j.finished_at is null then 'making' else 'failed' end,
      'failure',case when j.finished_at is not null then j.failure_code end,'profile',j.profile_id,'label',app_private.podcast_label(j.spec),
      'target_seconds',(j.spec->>'target_seconds')::integer,'document_id',j.paper_id,'title',j.title,'created_at',j.created_at) r,j.created_at created
    from asked j
    where j.finished_at is null
     or (j.state in ('failed','unknown_provider') and j.finished_at>now()-interval '1 day'
      and not exists(select 1 from asked later where later.paper_id=j.paper_id and later.created_at>j.created_at))
    order by j.created_at desc limit 20) z),'[]'::jsonb))
$$;

revoke all on function app_private.podcast_device_paper(uuid,uuid),app_private.podcast_device_pin(uuid,jsonb),
 app_private.podcast_device_pin_before_081(uuid,jsonb),app_private.podcast_mine(uuid) from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
