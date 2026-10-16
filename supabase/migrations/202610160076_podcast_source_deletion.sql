-- 076: An episode's paper text is deleted once the episode is made (owner, 2026-10-16: "I dont think we should even
-- expose the podcast source text"; docs/architecture/PAPER_PODCASTS.md "The paper text is deleted once the episode is
-- made"). The text a device sends for a private episode (private-content/podcast-sources/<account>/...) was kept until
-- the account was deleted. Now:
--  * every upload has its own path (<account>/<digest>/<upload id>.txt), so deleting a finished job's copy never
--    touches text a newer request has just uploaded; the older one-path-per-digest objects still resolve;
--  * the quote, start and claim find the text by its digest (the newest verified copy), so a retry of the same episode
--    uses its fresh upload;
--  * when a job finishes (ready, failed, canceled), the copies uploaded before it started are scheduled for deletion,
--    unless another unfinished job still needs the same text (a requeued job keeps its source until it finishes);
--  * uploads no job used are scheduled a day later;
--  * the worker deletes scheduled objects from Storage at the end of each run and confirms them (a canceled job wakes
--    it, and an hourly schedule wakes it while anything is waiting).
-- The episode's transcript and audio stay private to the account; nothing else keeps the text.
-- Listen also lists the account's own episodes and the ones being made (section 8), so a request needs no screen open.
begin;

-- 1. The source paths of one account and digest: the original one-per-digest path, or one upload's own path.
create function app_private.podcast_source_path(p_owner uuid,p_digest text,p_path text) returns boolean
language sql immutable set search_path='' as $$
 select p_path='podcast-sources/'||p_owner::text||'/'||p_digest||'.txt'
  or p_path ~ ('^podcast-sources/'||p_owner::text||'/'||p_digest||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.txt$')
$$;

-- 2. Registration: the Edge function names the path it stored the text at (one upload's own path). The original
-- three-argument form keeps the one-per-digest path for the function build deployed before this migration; once that
-- path's copy is scheduled or deleted it is refused (object rows never come back), so the function ships with this.
create function public.worker_podcast_source_register(p_account uuid,p_sha256 text,p_bytes bigint,p_path text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o app_private.stored_objects; target text; used bigint;
begin
 if p_account is null or p_sha256 !~ '^[0-9a-f]{64}$' or p_bytes is null or p_bytes<1 or p_bytes>409600 then raise exception 'invalid_podcast_request'; end if;
 target:=coalesce(p_path,'podcast-sources/'||p_account::text||'/'||p_sha256||'.txt');
 if not app_private.podcast_source_path(p_account,p_sha256,target) then raise exception 'invalid_podcast_request'; end if;
 if not exists(select 1 from app_private.accounts where id=p_account and closed_at is null) then raise exception 'account_unavailable'; end if;
 select * into o from app_private.stored_objects where path=target for update;
 if found then
  if o.bucket<>'private-content' or o.owner_id is distinct from p_account or o.sha256<>decode(p_sha256,'hex') or o.byte_count<>p_bytes then raise exception 'source_unavailable'; end if;
  if o.state='pending' then
   update app_private.stored_objects set state='verified',verified_at=clock_timestamp() where id=o.id returning * into o;
  end if;
  if o.state<>'verified' then raise exception 'source_unavailable'; end if;
  return jsonb_build_object('object_id',o.id,'bucket',o.bucket,'path',o.path,'bytes',o.byte_count);
 end if;
 select coalesce(sum(byte_count),0) into used from app_private.stored_objects
  where bucket='private-content' and owner_id=p_account and path like 'podcast-sources/%' and state<>'deleted';
 if used+p_bytes>67108864 then raise exception 'storage_full'; end if;
 select coalesce(sum(byte_count),0) into used from app_private.stored_objects
  where bucket='private-content' and path like 'podcast-sources/%' and state<>'deleted';
 if used+p_bytes>2147483648 then raise exception 'storage_full'; end if;
 insert into app_private.stored_objects(bucket,path,owner_id,sha256,byte_count,media_type,state,verified_at)
  values('private-content',target,p_account,decode(p_sha256,'hex'),p_bytes,'text/plain','verified',clock_timestamp()) returning * into o;
 return jsonb_build_object('object_id',o.id,'bucket',o.bucket,'path',o.path,'bytes',o.byte_count);
end $$;
create or replace function public.worker_podcast_source_register(p_account uuid,p_sha256 text,p_bytes bigint) returns jsonb
language sql security definer set search_path='' as $$ select public.worker_podcast_source_register(p_account,p_sha256,p_bytes,null) $$;

-- 3. The pin names the newest verified copy of the digest (as migration 066 otherwise).
create or replace function app_private.podcast_device_pin(p_account uuid,p_device jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare o app_private.stored_objects; membership uuid; sid text; rev integer; manifest text; digest text; title text; authors jsonb;
begin
 if p_account is null or p_device is null or jsonb_typeof(p_device)<>'object' then return null; end if;
 begin
  membership:=(p_device->>'membership_id')::uuid; rev:=(p_device->>'revision')::integer;
 exception when others then return null; end;
 sid:=p_device->>'source_id'; manifest:=p_device->>'manifest_sha256'; digest:=p_device->>'text_sha256';
 if membership is null or coalesce(p_device->>'source','')<>'arxiv' or sid !~ '^([0-9]{4}\.[0-9]{4,5}|[a-z-]+(\.[A-Z]{2})?/[0-9]{7})$'
  or rev is null or rev<1 or rev>999 or manifest !~ '^[0-9a-f]{64}$' or digest !~ '^[0-9a-f]{64}$' then return null; end if;
 select * into o from app_private.stored_objects where bucket='private-content' and owner_id=p_account and state='verified'
  and sha256=decode(digest,'hex') and app_private.podcast_source_path(p_account,digest,path) order by created_at desc,id limit 1;
 if not found then return null; end if;
 title:=left(nullif(btrim(coalesce(p_device->>'title','')),''),300);
 authors:=coalesce((select jsonb_agg(left(v,120)) from (select value v from jsonb_array_elements_text(
  case when jsonb_typeof(p_device->'authors')='array' then p_device->'authors' else '[]'::jsonb end) where length(btrim(value))>0 limit 10) x),'[]'::jsonb);
 return jsonb_build_object('kind','device','membership_id',membership,'source','arxiv','source_id',sid,'revision',rev,'manifest_sha256',manifest,
  'text_object_id',o.id,'text_sha256',digest,'text_bytes',o.byte_count,'normalization_version','gradstep-paper-context-v2',
  'title',title,'authors',authors);
end $$;

-- 4. The claim reads the device text by digest (as migration 073 otherwise).
create or replace function public.worker_podcast_claim(p_claim_id uuid,p_generated boolean default true) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.podcast_policy; candidate uuid; j app_private.podcast_jobs; spec jsonb; src app_private.podcast_sources;
 dev app_private.podcast_device_sources; t app_private.stored_objects; meta jsonb; resumed boolean; resume jsonb; source_doc uuid; norm text;
begin
 if p_claim_id is null then raise exception 'invalid_podcast_claim'; end if;
 select * into strict pol from app_private.podcast_policy where singleton;
 -- Queued work, or a staged job parked after a checkpoint (oldest first, so work in flight finishes first); a job
 -- requeued after a transient refusal waits for its retry time (migration 073).
 select x.id into candidate from app_private.podcast_jobs x where x.claim_id is null
  and (x.state='queued' or (x.state in ('checking','synthesizing') and exists(select 1 from app_private.podcast_job_checkpoints c where c.job_id=x.id)))
  and (x.retry_at is null or x.retry_at<=clock_timestamp())
  and ((x.funding_kind='customer' and pol.generation_enabled) or (x.funding_kind='platform_seed' and pol.seed_enabled) or (x.funding_kind='fixture' and pol.fixtures_enabled))
  and (x.origin='fixture' or coalesce(p_generated,false))
  order by x.created_at,x.id limit 1;
 if candidate is null then return jsonb_build_object('claimed',false); end if;
 j:=app_private.podcast_lock_job(candidate);
 if j.claim_id is not null or j.finished_at is not null or j.state not in ('queued','checking','synthesizing')
  or (j.retry_at is not null and j.retry_at>clock_timestamp()) then return jsonb_build_object('claimed',false,'more',true); end if;
 resumed:=j.state<>'queued';
 -- A scan in progress would refuse this job's uploads after its paid calls.
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton for share) then
  return jsonb_build_object('claimed',false,'reason','asset_inventory_reconciling');
 end if;
 if j.epoch<>(select epoch from app_private.podcast_policy where singleton) then
  j:=app_private.podcast_settle(j,'failed','podcast_epoch_changed'); return jsonb_build_object('claimed',false,'more',true);
 end if;
 if j.cancel_requested then j:=app_private.podcast_settle(j,'canceled','canceled_by_owner'); return jsonb_build_object('claimed',false,'more',true); end if;
 if exists(select 1 from app_private.podcast_episode_keys k where k.id=j.episode_id and k.scope='shared')
  and not app_private.podcast_rights_current(j.episode_id,j.rights_revision) then
  j:=app_private.podcast_settle(j,'failed','rights_changed'); return jsonb_build_object('claimed',false,'more',true);
 end if;
 if j.operation_id is not null and not exists(select 1 from app_private.accounts where id=j.operation_account_id and closed_at is null and not spending_suspended) then
  j:=app_private.podcast_settle(j,'failed','account_unavailable'); return jsonb_build_object('claimed',false,'more',true);
 end if;
 select * into src from app_private.podcast_sources where episode_id=j.episode_id and ordinal=0;
 if found then
  select * into t from app_private.stored_objects where id=src.text_object_id and state='verified' and sha256=src.text_sha256 and byte_count=src.text_bytes;
  source_doc:=src.document_id; norm:=src.normalization_version;
  select jsonb_build_object('title',left(cm.metadata->>'title',500),'authors',cm.metadata->'authors') into meta
   from app_private.catalog_metadata cm where cm.id=src.metadata_id;
 else
  select * into dev from app_private.podcast_device_sources where episode_id=j.episode_id;
  if not found then j:=app_private.podcast_settle(j,'failed','source_unavailable'); return jsonb_build_object('claimed',false,'more',true); end if;
  -- The text by its digest, the newest verified copy (migration 076): a finished job's copy is deleted, and a retry of
  -- the same episode brings a fresh upload, which the episode's first row (immutable) does not name.
  select * into t from app_private.stored_objects where bucket='private-content' and owner_id=dev.owner_id and state='verified'
   and sha256=dev.text_sha256 and byte_count=dev.text_bytes and app_private.podcast_source_path(dev.owner_id,encode(dev.text_sha256,'hex'),path)
   order by created_at desc,id limit 1;
  source_doc:=dev.membership_id; norm:=dev.normalization_version;
  meta:=jsonb_build_object('title',dev.title,'authors',dev.authors);
 end if;
 if t.id is null then j:=app_private.podcast_settle(j,'failed','source_unavailable'); return jsonb_build_object('claimed',false,'more',true); end if;
 if resumed then
  -- Only the exact stage its checkpoint covers; anything else already ended the job.
  if app_private.podcast_resume_state(j) is distinct from j.state then
   j:=app_private.podcast_settle(j,'failed','checkpoint_unavailable'); return jsonb_build_object('claimed',false,'more',true);
  end if;
  select jsonb_build_object('stage',case when j.state='checking' then 'review' else 'speech' end,'document',c.document) into strict resume
   from app_private.podcast_job_checkpoints c where c.job_id=j.id and c.stage=case when j.state='checking' then 'draft' else 'script' end;
 end if;
 update app_private.podcast_jobs set claim_id=p_claim_id,claim_generation=claim_generation+1,lease_until=clock_timestamp()+interval '15 minutes',
  state=case when resumed then j.state else 'scripting' end,stage_entered_at=clock_timestamp() where id=j.id returning * into j;
 perform app_private.podcast_event(j.id,'claimed',jsonb_build_object('claim_id',p_claim_id,'generation',j.claim_generation,'resumed',resumed));
 spec:=app_private.podcast_job_spec(j);
 return jsonb_build_object('claimed',true,'job_id',j.id,'claim_id',p_claim_id,'generation',j.claim_generation,'origin',j.origin,
  'funding_kind',j.funding_kind,'scope',(select scope from app_private.podcast_episode_keys where id=j.episode_id),
  'owner_id',(select owner_id from app_private.podcast_episode_keys where id=j.episode_id),'episode_id',j.episode_id,
  'lease_until',j.lease_until,'spec',spec,'metadata',meta,'resume',resume,
  'source',jsonb_build_object('document_id',source_doc,'bucket',t.bucket,'path',t.path,'sha256',encode(t.sha256,'hex'),'bytes',t.byte_count,
   'normalization_version',norm));
end $$;

-- 5. A finished job schedules its text for deletion: the copies of its digest uploaded before it started, unless
-- another unfinished job needs the same text. A canceled job (no worker run is ending) wakes the worker to delete them.
create function app_private.podcast_source_release() returns trigger
language plpgsql security definer set search_path='' as $$
declare dev app_private.podcast_device_sources; n integer:=0;
begin
 select * into dev from app_private.podcast_device_sources where episode_id=new.episode_id;
 if not found then return new; end if;
 if exists(select 1 from app_private.podcast_jobs x join app_private.podcast_device_sources d on d.episode_id=x.episode_id
   where x.id<>new.id and x.finished_at is null and d.owner_id=dev.owner_id and d.text_sha256=dev.text_sha256) then return new; end if;
 update app_private.stored_objects set state='deleting'
  where bucket='private-content' and owner_id=dev.owner_id and sha256=dev.text_sha256 and state in ('pending','verified')
   and created_at<=new.created_at and app_private.podcast_source_path(dev.owner_id,encode(dev.text_sha256,'hex'),path);
 get diagnostics n=row_count;
 if n>0 and new.state='canceled' then perform app_private.podcast_kick(); end if;
 return new;
end $$;
create trigger podcast_source_release after update of finished_at on app_private.podcast_jobs
 for each row when (old.finished_at is null and new.finished_at is not null) execute function app_private.podcast_source_release();

-- 6. The worker's sweep: uploads no job used for a day are scheduled too; then the scheduled copies to delete from
-- Storage, and the confirmation once they are gone. Service role only.
create function public.worker_podcast_source_cleanup(p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path='' as $$
declare objects jsonb; orphaned integer;
begin
 if p_limit is null or p_limit not between 1 and 500 then raise exception 'invalid_limit'; end if;
 update app_private.stored_objects o set state='deleting'
  where o.bucket='private-content' and o.path like 'podcast-sources/%' and o.state in ('pending','verified') and o.created_at<now()-interval '1 day'
   and not exists(select 1 from app_private.podcast_jobs x join app_private.podcast_device_sources d on d.episode_id=x.episode_id
    where x.finished_at is null and d.owner_id=o.owner_id and d.text_sha256=o.sha256);
 get diagnostics orphaned=row_count;
 select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'bucket',o.bucket,'path',o.path) order by o.id),'[]'::jsonb) into objects
  from (select * from app_private.stored_objects where bucket='private-content' and path like 'podcast-sources/%' and state='deleting'
   order by id limit p_limit) o;
 return jsonb_build_object('objects',objects,'orphaned',orphaned);
end $$;
create function public.worker_podcast_source_cleanup_confirm(p_object_ids uuid[]) returns integer
language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if p_object_ids is null or cardinality(p_object_ids) not between 1 and 500 then raise exception 'invalid_limit'; end if;
 update app_private.stored_objects set state='deleted' where id=any(p_object_ids) and bucket='private-content'
  and path like 'podcast-sources/%' and state='deleting';
 get diagnostics n=row_count;
 return n;
end $$;

-- 7. An hourly wake-up when text is waiting to be deleted (a sweep that failed, or a day-old upload no job used), so a
-- quiet service still deletes it without waiting for the next episode.
create function public.worker_podcast_kick_sources() returns jsonb
language plpgsql security definer set search_path='' as $$
declare due integer;
begin
 select count(*) into due from app_private.stored_objects o where o.bucket='private-content' and o.path like 'podcast-sources/%'
  and (o.state='deleting' or (o.state in ('pending','verified') and o.created_at<now()-interval '1 day'
   and not exists(select 1 from app_private.podcast_jobs x join app_private.podcast_device_sources d on d.episode_id=x.episode_id
    where x.finished_at is null and d.owner_id=o.owner_id and d.text_sha256=o.sha256)));
 if due>0 then perform app_private.podcast_kick(); end if;
 return jsonb_build_object('due',due);
end $$;
do $do$
begin
 if to_regprocedure('cron.schedule(text,text,text)') is not null then
  perform cron.schedule('science-reader-podcast-sources', '17 * * * *', 'select public.worker_podcast_kick_sources()');
 end if;
end $do$;

-- 8. Listen lists the account's own episodes (owner, 2026-10-16: "the important thing is you ask for, it doesnt matter
-- if you leave the page or app, its there for you"). The catalog's first page adds `mine`: the account's ready private
-- episodes, newest first, each with the title of its paper and the request that made it; and its requests still being
-- made, or that could not be made in the last day (until a later request for the same paper). No text, no path.
create function app_private.podcast_mine(a uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 with paper as (
  select k.id episode_id,coalesce(s.document_id,d.membership_id) paper_id,coalesce(d.title,left(cm.metadata->>'title',300)) title
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

create or replace function public.v1_podcast_catalog(p_after text default null,p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); after_seq bigint; rows jsonb; mine jsonb;
begin
 perform public.worker_consume_request(a,'podcast-read');
 if p_limit is null or p_limit not between 1 and 50 or (p_after is not null and p_after !~ '^[1-9][0-9]{0,17}$') then raise exception 'invalid_podcast_cursor'; end if;
 after_seq:=coalesce(p_after::bigint,9223372036854775807);
 -- The account's own episodes and requests, on the first page only.
 if p_after is null then mine:=app_private.podcast_mine(a); end if;
 if not (select catalog_enabled from app_private.podcast_policy where singleton) then
  return jsonb_build_object('episodes','[]'::jsonb,'next',null,'capabilities',app_private.podcast_capabilities(a),'mine',mine);
 end if;
 select coalesce(jsonb_agg(app_private.podcast_episode_public(r) order by r.published_seq desc),'[]'::jsonb) into rows from (
  select x.* from app_private.podcast_releases x where x.scope='shared' and x.state='ready' and x.published_seq<after_seq
   and app_private.podcast_rights_current(x.episode_id,null) order by x.published_seq desc limit p_limit) r;
 return jsonb_build_object('episodes',rows,
  'next',case when jsonb_array_length(rows)=p_limit then (select min(x.published_seq)::text from app_private.podcast_releases x
   where x.id in (select (e->>'release_id')::uuid from jsonb_array_elements(rows) e)) end,
  'capabilities',app_private.podcast_capabilities(a),'mine',mine);
end $$;
revoke all on function app_private.podcast_mine(uuid) from public,anon,authenticated,service_role;

revoke all on function app_private.podcast_source_path(uuid,text,text),app_private.podcast_source_release() from public,anon,authenticated,service_role;
revoke all on function public.worker_podcast_source_register(uuid,text,bigint,text),public.worker_podcast_source_register(uuid,text,bigint),
 public.worker_podcast_source_cleanup(integer),public.worker_podcast_source_cleanup_confirm(uuid[]),public.worker_podcast_kick_sources() from public,anon,authenticated;
grant execute on function public.worker_podcast_source_register(uuid,text,bigint,text),public.worker_podcast_source_register(uuid,text,bigint),
 public.worker_podcast_source_cleanup(integer),public.worker_podcast_source_cleanup_confirm(uuid[]),public.worker_podcast_kick_sources() to service_role;
notify pgrst,'reload schema';
commit;
