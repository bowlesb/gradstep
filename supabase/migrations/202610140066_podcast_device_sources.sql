-- 066: Private podcast episodes from the paper's own text on the device
-- (docs/architecture/PAPER_PODCASTS.md, "Episodes from the paper on this device"; owner, TestFlight build 35:
-- "we should have stopped storing PDFs at all on the server"). Additive: a device-source table beside
-- podcast_sources, a service RPC that registers the uploaded text, a device pin, and the quote, start, claim, paper
-- and public-episode functions resolving a source by kind. Mathpix pins, work keys and shared episodes are unchanged.
begin;

-- 1. Device sources: ids and digests of the text a device uploaded for one episode (immutable once written).
create table app_private.podcast_device_sources (
 episode_id uuid primary key references app_private.podcast_episode_keys(id),
 owner_id uuid not null references app_private.accounts(id),
 membership_id uuid not null,
 source text not null check(source='arxiv'),
 source_id text not null check(source_id ~ '^([0-9]{4}\.[0-9]{4,5}|[a-z-]+(\.[A-Z]{2})?/[0-9]{7})$'),
 revision integer not null check(revision between 1 and 999),
 manifest_sha256 bytea not null check(octet_length(manifest_sha256)=32),
 text_object_id uuid not null references app_private.stored_objects(id),
 text_sha256 bytea not null check(octet_length(text_sha256)=32),
 text_bytes bigint not null check(text_bytes between 1 and 8388608),
 normalization_version text not null check(normalization_version='gradstep-paper-context-v2'),
 title text check(title is null or length(title)<=500),
 authors jsonb not null default '[]'::jsonb check(jsonb_typeof(authors)='array' and jsonb_array_length(authors)<=20),
 created_at timestamptz not null default now()
);
create index podcast_device_sources_paper on app_private.podcast_device_sources(owner_id,membership_id);
create trigger podcast_device_sources_immutable before update or delete on app_private.podcast_device_sources
 for each row execute function app_private.immutable_record();

-- 2. The uploaded text, registered by the Edge function once the object is stored (service role only). One object
-- per account and digest at private-content/podcast-sources/<account>/<sha256>.txt; bounded per account and overall.
create function public.worker_podcast_source_register(p_account uuid,p_sha256 text,p_bytes bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o app_private.stored_objects; target text; used bigint;
begin
 if p_account is null or p_sha256 !~ '^[0-9a-f]{64}$' or p_bytes is null or p_bytes<1 or p_bytes>409600 then raise exception 'invalid_podcast_request'; end if;
 if not exists(select 1 from app_private.accounts where id=p_account and closed_at is null) then raise exception 'account_unavailable'; end if;
 target:='podcast-sources/'||p_account::text||'/'||p_sha256||'.txt';
 select * into o from app_private.stored_objects where bucket='private-content' and owner_id=p_account and path=target and state<>'deleted';
 if found then
  if o.state='pending' then
   update app_private.stored_objects set state='verified',verified_at=clock_timestamp() where id=o.id returning * into o;
  end if;
  if o.state<>'verified' or o.sha256<>decode(p_sha256,'hex') or o.byte_count<>p_bytes then raise exception 'source_unavailable'; end if;
  return jsonb_build_object('object_id',o.id,'bucket',o.bucket,'path',o.path,'bytes',o.byte_count);
 end if;
 select coalesce(sum(byte_count),0) into used from app_private.stored_objects
  where bucket='private-content' and owner_id=p_account and path like 'podcast-sources/%' and state<>'deleted';
 if used+p_bytes>67108864 then raise exception 'storage_full'; end if;
 select coalesce(sum(byte_count),0) into used from app_private.stored_objects
  where bucket='private-content' and path like 'podcast-sources/%' and state<>'deleted';
 if used+p_bytes>2147483648 then raise exception 'storage_full'; end if;
 insert into app_private.stored_objects(bucket,path,owner_id,sha256,byte_count,media_type,state,verified_at)
  values('private-content',target,p_account,decode(p_sha256,'hex'),p_bytes,'text/plain',  'verified',clock_timestamp()) returning * into o;
 return jsonb_build_object('object_id',o.id,'bucket',o.bucket,'path',o.path,'bytes',o.byte_count);
end $$;
revoke all on function public.worker_podcast_source_register(uuid,text,bigint) from public,anon,authenticated;
grant execute on function public.worker_podcast_source_register(uuid,text,bigint) to service_role;

-- 3. The device pin: ids and digests only, recomputable from its own fields (the start compares it with the quote's).
create function app_private.podcast_device_pin(p_account uuid,p_device jsonb) returns jsonb
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
 select * into o from app_private.stored_objects where bucket='private-content' and owner_id=p_account
  and path='podcast-sources/'||p_account::text||'/'||digest||'.txt' and state='verified' and sha256=decode(digest,'hex');
 if not found then return null; end if;
 title:=left(nullif(btrim(coalesce(p_device->>'title','')),''),300);
 authors:=coalesce((select jsonb_agg(left(v,120)) from (select value v from jsonb_array_elements_text(
  case when jsonb_typeof(p_device->'authors')='array' then p_device->'authors' else '[]'::jsonb end) where length(btrim(value))>0 limit 10) x),'[]'::jsonb);
 return jsonb_build_object('kind','device','membership_id',membership,'source','arxiv','source_id',sid,'revision',rev,'manifest_sha256',manifest,
  'text_object_id',o.id,'text_sha256',digest,'text_bytes',o.byte_count,'normalization_version','gradstep-paper-context-v2',
  'title',title,'authors',authors);
end $$;

-- 4. Episode insertion by pin kind (a device source is private only).
create or replace function app_private.podcast_insert_episode(p_scope text,p_owner uuid,p_spec jsonb,p_pin jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare key bytea:=app_private.podcast_work_key(p_scope,p_owner,p_spec,p_pin); episode uuid;
begin
 if p_pin->>'kind'='device' and p_scope<>'private' then raise exception 'invalid_podcast_request'; end if;
 if p_scope='shared' then
  insert into app_private.podcast_episode_keys(scope,owner_id,work_sha256,profile_id,profile_version)
   values('shared',null,key,p_spec->>'id',(p_spec->>'version')::integer) on conflict do nothing;
  select id into strict episode from app_private.podcast_episode_keys where scope='shared' and work_sha256=key;
 else
  insert into app_private.podcast_episode_keys(scope,owner_id,work_sha256,profile_id,profile_version)
   values('private',p_owner,key,p_spec->>'id',(p_spec->>'version')::integer) on conflict do nothing;
  select id into strict episode from app_private.podcast_episode_keys where scope='private' and owner_id=p_owner and work_sha256=key;
 end if;
 if p_pin->>'kind'='device' then
  insert into app_private.podcast_device_sources(episode_id,owner_id,membership_id,source,source_id,revision,manifest_sha256,
   text_object_id,text_sha256,text_bytes,normalization_version,title,authors)
  values(episode,p_owner,(p_pin->>'membership_id')::uuid,'arxiv',p_pin->>'source_id',(p_pin->>'revision')::integer,decode(p_pin->>'manifest_sha256','hex'),
   (p_pin->>'text_object_id')::uuid,decode(p_pin->>'text_sha256','hex'),(p_pin->>'text_bytes')::bigint,p_pin->>'normalization_version',
   p_pin->>'title',coalesce(p_pin->'authors','[]'::jsonb))
  on conflict do nothing;
 else
  insert into app_private.podcast_sources(episode_id,ordinal,document_id,document_sha256,approval_id,version_id,metadata_id,ocr_run_id,
   raw_manifest_object_id,raw_manifest_sha256,text_object_id,text_sha256,text_bytes,artifact_id,normalization_version)
  values(episode,0,(p_pin->>'document_id')::uuid,decode(p_pin->>'document_sha256','hex'),(p_pin->>'approval_id')::uuid,(p_pin->>'version_id')::uuid,
   (p_pin->>'metadata_id')::uuid,(p_pin->>'ocr_run_id')::uuid,(p_pin->>'raw_manifest_object_id')::uuid,decode(p_pin->>'raw_manifest_sha256','hex'),
   (p_pin->>'text_object_id')::uuid,decode(p_pin->>'text_sha256','hex'),(p_pin->>'text_bytes')::bigint,(p_pin->>'artifact_id')::uuid,p_pin->>'normalization_version')
  on conflict do nothing;
 end if;
 return episode;
end $$;

-- 5. The quote takes an optional device source (the membership id is the paper's name in `p_item_id`).
drop function public.v1_podcast_quote(uuid,uuid,text,text);
create function public.v1_podcast_quote(p_item_id uuid,p_request_id uuid,p_profile text default null,p_writer text default null,p_device jsonb default null) returns jsonb
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
  if p_device is not null then pin:=app_private.podcast_device_pin(a,p_device||jsonb_build_object('membership_id',p_item_id));
  else pin:=app_private.podcast_item_pin(a,p_item_id); end if;
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
revoke all on function public.v1_podcast_quote(uuid,uuid,text,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.v1_podcast_quote(uuid,uuid,text,text,jsonb) to authenticated;

-- 6. The start resolves the quote's pin by kind (065's text otherwise).
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
 if q.pin->>'kind'='device' then pin:=app_private.podcast_device_pin(a,q.pin); else pin:=app_private.podcast_item_pin(a,q.item_id); end if;
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

-- 7. The claim reads either source table; the worker sees the same `source` and `metadata` shapes (document_id is
-- the membership id for a device source).
create or replace function public.worker_podcast_claim(p_claim_id uuid,p_generated boolean default true) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.podcast_policy; candidate uuid; j app_private.podcast_jobs; spec jsonb; src app_private.podcast_sources;
 dev app_private.podcast_device_sources; t app_private.stored_objects; meta jsonb; resumed boolean; resume jsonb; source_doc uuid; norm text;
begin
 if p_claim_id is null then raise exception 'invalid_podcast_claim'; end if;
 select * into strict pol from app_private.podcast_policy where singleton;
 -- Queued work, or a staged job parked after a checkpoint (oldest first, so work in flight finishes first).
 select x.id into candidate from app_private.podcast_jobs x where x.claim_id is null
  and (x.state='queued' or (x.state in ('checking','synthesizing') and exists(select 1 from app_private.podcast_job_checkpoints c where c.job_id=x.id)))
  and ((x.funding_kind='customer' and pol.generation_enabled) or (x.funding_kind='platform_seed' and pol.seed_enabled) or (x.funding_kind='fixture' and pol.fixtures_enabled))
  and (x.origin='fixture' or coalesce(p_generated,false))
  order by x.created_at,x.id limit 1;
 if candidate is null then return jsonb_build_object('claimed',false); end if;
 j:=app_private.podcast_lock_job(candidate);
 if j.claim_id is not null or j.finished_at is not null or j.state not in ('queued','checking','synthesizing') then return jsonb_build_object('claimed',false,'more',true); end if;
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
  select * into t from app_private.stored_objects where id=dev.text_object_id and state='verified' and sha256=dev.text_sha256 and byte_count=dev.text_bytes;
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

-- 8. A paper's episodes: a library item as before, or a device-source paper named by its membership id.
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
 select x.* into r from app_private.podcast_releases x join app_private.podcast_sources s on s.episode_id=x.episode_id and s.ordinal=0
  where s.document_id=doc and x.scope='private' and x.owner_id=a and x.state='ready' order by x.published_seq desc limit 1;
 if not found then
  select x.* into r from app_private.podcast_releases x join app_private.podcast_sources s on s.episode_id=x.episode_id and s.ordinal=0
   where s.document_id=doc and x.scope='shared' and x.state='ready' and app_private.podcast_rights_current(x.episode_id,null)
    and (select catalog_enabled from app_private.podcast_policy where singleton)
   order by x.published_seq desc limit 1;
 end if;
 select x.* into j from app_private.podcast_jobs x join app_private.podcast_episode_keys k on k.id=x.episode_id and k.scope='private' and k.owner_id=a
  join app_private.podcast_sources s on s.episode_id=x.episode_id and s.ordinal=0
  where s.document_id=doc and x.funding_kind='customer' and x.finished_at is null order by x.created_at desc limit 1;
 if j.id is not null then select request_id into req from app_private.podcast_requests where account_id=a and job_id=j.id order by created_at limit 1; end if;
 -- Every playable length for this paper (each length is its own work key): the
 -- account's newest private release per length, else the newest shared one.
 select coalesce(jsonb_agg(app_private.podcast_episode_public(z.release) order by z.seconds),'[]'::jsonb) into lengths
  from (select distinct on (k.profile_id) x as release,(pr.spec->>'target_seconds')::integer seconds from app_private.podcast_releases x
    join app_private.podcast_episode_keys k on k.id=x.episode_id join app_private.podcast_sources s on s.episode_id=x.episode_id and s.ordinal=0
    join app_private.podcast_profiles pr on (pr.id,pr.version)=(k.profile_id,k.profile_version)
   where s.document_id=doc and x.state='ready' and ((x.scope='private' and x.owner_id=a)
    or (x.scope='shared' and app_private.podcast_rights_current(x.episode_id,null) and (select catalog_enabled from app_private.podcast_policy where singleton)))
   order by k.profile_id,(x.scope='private') desc,x.published_seq desc) z;
 return jsonb_build_object('episode',case when r.id is not null then app_private.podcast_episode_public(r) end,'episodes',lengths,
  'job',case when j.id is not null then app_private.podcast_job_public(j,req) end,'capabilities',app_private.podcast_capabilities(a));
end $$;

-- 9. A device episode's document_id is its membership id, so clients find the paper as they do for a library item.
create or replace function app_private.podcast_episode_public(r app_private.podcast_releases) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('release_id',r.id,'scope',r.scope,'state',r.state,'fixture',r.origin='fixture','ai_audio',true,'language','en',
  'duration_ms',r.duration_ms,'published_at',r.published_at,
  'document_id',coalesce((select s.document_id from app_private.podcast_sources s where s.episode_id=r.episode_id and s.ordinal=0),
   (select d.membership_id from app_private.podcast_device_sources d where d.episode_id=r.episode_id)),
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

notify pgrst,'reload schema';
commit;
