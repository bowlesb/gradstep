-- Adding a paper must be "absolutely bullet proof" (owner, 2026-10-07). Design:
-- docs/architecture/PDF_UPLOADS.md. Additive over 008/010/014/016/017/019/027/029/030.
--
-- 1. Add by any identifier or link: a rate rule for functions/v1/add-paper (identification
--    without a model; imports go through the existing begin RPCs).
-- 2. PDF upload sessions (the design in DATA_MODEL "Import identity and membership", built):
--    functions/v1/upload-pdf begins a session (account-bound, expiring, size-capped, counted
--    against the owner's private storage quota, credits required) and hands the client a signed
--    upload URL for `paper-uploads/<account>/<upload>.pdf`, a private bucket of its own; it
--    finalizes after checking the object's size. Finalizing is idempotent (the upload ID is the
--    operation ID) and creates or retries the import in the same transaction. The pipeline worker
--    verifies the bytes (declared sha256 and size, `%PDF-`, page count) before they become an
--    owner-private original; reader bytes are never shared or reused by another account.
-- 3. Targets: a paper of its own (source `upload:<upload id>`, a new source kind), a failed import
--    (device fallback: the reader's device fetched the PDF a website refused our servers), or a
--    known web paper that isn't openly available. A supplied PDF is keyed by (account, source): the
--    account's private paper for that source uses the newest finalized upload at download.
-- 4. Uploaded papers' titles are personal: they live on the upload row (deleted with the account)
--    and replace the catalog's neutral placeholder in the owner's library entries. Installed builds
--    read v3 and never see upload entries (they reject an unknown source); v4 reads return them.
--    An import never resolves onto an item a reader at its read version could not see.
-- 5. A web paper with no open location now records its metadata and fails at download with
--    `not_open` (resumable there), so a reader can supply the PDF to the same paper.
--
-- Apply with the pipeline disabled (worker_set_pipeline_enabled(false)); the table alterations
-- below take short exclusive locks.
begin;
set local lock_timeout='15s';

insert into app_private.api_rate_rules values('add-paper',3600,120,2000),('pdf-upload',3600,40,400) on conflict(route) do nothing;

-- Reader-supplied bytes: their own private bucket, owner-scoped objects (deleted with the account).
alter table app_private.stored_objects drop constraint stored_objects_bucket_check;
alter table app_private.stored_objects add constraint stored_objects_bucket_check check(bucket in ('paper-assets','private-content','support','paper-uploads'));
alter table app_private.stored_objects drop constraint stored_objects_check;
alter table app_private.stored_objects add constraint stored_objects_check check((bucket='paper-assets' and document_id is not null and owner_id is null)
 or (bucket in ('private-content','support','paper-uploads') and owner_id is not null and document_id is null));
create index stored_objects_uploads on app_private.stored_objects(owner_id,state) where bucket='paper-uploads';

-- Uploaded papers are pinned by an owner-upload approval (no license applies to a reader's own copy).
alter table app_private.catalog_asset_approvals drop constraint catalog_asset_approval_policy;
alter table app_private.catalog_asset_approvals add constraint catalog_asset_approval_policy check(
 (policy_version='arxiv-reuse-v1' and license_uri in ('https://creativecommons.org/licenses/by/4.0/','https://creativecommons.org/publicdomain/zero/1.0/'))
 or (policy_version='owner-private-v1' and length(license_uri)<=512 and license_uri ~ '^https?://[A-Za-z0-9.-]+/[ -~]*$')
 or (policy_version='owner-upload-v1' and license_uri='reader-upload'));

alter table app_private.import_requests drop constraint import_requests_error_code_check;
alter table app_private.import_requests add constraint import_requests_error_code_check check(error_code in
 ('metadata_unavailable','download_failed','pdf_invalid','rate_limited','license_unverified','membership_conflict',
  'insufficient_credits','conversion_failed','too_large',
  'download_retrying','source_unavailable','source_blocked','not_pdf','pdf_restricted',
  'not_open','upload_failed'));

create table app_private.pdf_upload_policy (
 singleton boolean primary key default true check(singleton),
 -- Unfinished uploads (begun or finalized, not yet used) per account and environment.
 account_active integer not null default 10 check(account_active between 1 and 100),
 environment_active integer not null default 200 check(environment_active between 1 and 10000),
 -- Upload objects not yet deleted, environment-wide (each owner's also count against their private quota).
 environment_bytes bigint not null default 4294967296 check(environment_bytes between 67108864 and 107374182400),
 pending_hours integer not null default 24 check(pending_hours between 1 and 168),
 -- A finalized upload no import used is deleted after this many days.
 unused_days integer not null default 7 check(unused_days between 1 and 90)
);
insert into app_private.pdf_upload_policy default values;
alter table app_private.pdf_upload_policy enable row level security;

create table app_private.pdf_uploads (
 id uuid primary key,
 account_id uuid not null references app_private.accounts(id),
 object_id uuid not null unique references app_private.stored_objects(id),
 target text not null check(target in ('paper','import','source')),
 -- `upload:<id>` for a paper of its own (and for a later upload supplying that paper); the web paper otherwise.
 source_id text not null check(length(source_id) between 1 and 128 and (source_id like 'openalex:%' or source_id like 'upload:%')),
 import_id uuid,
 expected_revision bigint check(expected_revision>0),
 -- A paper of its own: title (and nothing else a reader typed). Personal; deleted with the account.
 metadata jsonb check(metadata is null or (jsonb_typeof(metadata)='object' and octet_length(metadata::text)<=8192)),
 request_sha256 bytea not null check(octet_length(request_sha256)=32),
 state text not null default 'pending' check(state in ('pending','finalized','consumed','abandoned')),
 finalize_result jsonb,
 expires_at timestamptz not null,
 created_at timestamptz not null default now(),
 finalized_at timestamptz,
 consumed_at timestamptz,
 check((target='paper')=(metadata is not null)),
 check((target='import')=(import_id is not null and expected_revision is not null)),
 check(target<>'paper' or source_id='upload:'||id::text),
 check(target<>'source' or source_id like 'openalex:%'),
 check(state<>'pending' or finalized_at is null),
 check(state not in ('finalized','consumed') or finalized_at is not null),
 check((state='consumed')=(consumed_at is not null))
);
create index pdf_uploads_supply on app_private.pdf_uploads(account_id,source_id,finalized_at) where state='finalized';
create index pdf_uploads_pending on app_private.pdf_uploads(expires_at) where state='pending';
alter table app_private.pdf_uploads enable row level security;

-- Which upload a paper's original came from (provenance; set when the worker uses it).
alter table app_private.pipeline_papers add column upload_id uuid references app_private.pdf_uploads(id) on delete set null;

-- The upload a private paper uses at download: the newest finalized one for its owner and source.
create function app_private.pipeline_supplied_upload(p app_private.pipeline_papers) returns app_private.pdf_uploads
language sql stable security definer set search_path='' as $$
 select u.* from app_private.pdf_uploads u where p.owner_id is not null and u.account_id=p.owner_id and u.source_id=p.source_id
  and u.state='finalized' order by u.finalized_at desc,u.id limit 1
$$;

-- An uploaded paper's own metadata (its title), for the owner's entries and the reader's attribution.
create function app_private.upload_metadata(a uuid,p_source_id text) returns jsonb language sql stable security definer set search_path='' as $$
 select u.metadata from app_private.pdf_uploads u where u.account_id=a and u.target='paper' and p_source_id like 'upload:%'
  and u.id::text=substr(p_source_id,8)
$$;

-- Read levels: v2 shows arXiv only, v3 adds web papers, v4 adds uploads.
create function app_private.source_level(p_source_id text) returns integer language sql immutable set search_path='' as $$
 select case when p_source_id like 'openalex:%' then 3 when p_source_id like 'upload:%' then 4 else 2 end
$$;

-- A neutral catalog identity for one uploaded paper (the personal title stays on the upload row).
create function app_private.record_upload_metadata(p_upload uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare pub uuid; ver uuid; result uuid; src text:='upload:'||p_upload::text;
 placeholder jsonb:='{"title":"Uploaded PDF","authors":[],"abstract":null,"published_at":null,"updated_at":null,"categories":[],"venue":null}';
begin
 select id into result from app_private.catalog_metadata where source_id=src;
 if result is not null then return result; end if;
 insert into app_private.publications(title) values('Uploaded PDF') returning id into pub;
 insert into app_private.publication_versions(publication_id,source,revision) values(pub,'upload','v1') returning id into ver;
 insert into app_private.catalog_metadata(version_id,source_id,source_revision,metadata,metadata_sha256)
  values(ver,src,1,placeholder,sha256(convert_to(placeholder::text,'UTF8'))) returning id into result;
 return result;
end $$;

-- Begins (or resumes) an upload session. Service role: called by functions/v1/upload-pdf for the
-- authenticated account, which then signs an upload URL for the returned path.
create function public.worker_begin_pdf_upload(p_account_id uuid,p_upload_id uuid,p_sha256 bytea,p_byte_count bigint,p_target text,
 p_import_id uuid default null,p_expected_revision bigint default null,p_source_id text default null,p_title text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.pdf_upload_policy; pp app_private.pipeline_policy; u app_private.pdf_uploads; o app_private.stored_objects;
 i app_private.import_requests; src text; meta jsonb; title text; digest bytea; used bigint; available bigint;
begin
 perform public.worker_consume_request(p_account_id,'pdf-upload');
 select * into strict pol from app_private.pdf_upload_policy where singleton for update;
 select * into strict pp from app_private.pipeline_policy;
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null for no key update;
 if not found then raise exception 'account_unavailable' using errcode='42501'; end if;
 if p_upload_id is null or p_sha256 is null or octet_length(p_sha256)<>32 or p_byte_count is null or p_byte_count<1 then raise exception 'invalid_upload'; end if;
 if p_byte_count>pp.max_pdf_bytes then raise exception 'upload_too_large'; end if;
 if p_target='paper' then
  if p_import_id is not null or p_expected_revision is not null or p_source_id is not null then raise exception 'invalid_upload'; end if;
  title:=btrim(regexp_replace(coalesce(p_title,''),'\s+',' ','g'));
  if length(title) not between 1 and 500 or title ~ '[\u0001-\u001f\u007f-\u009f]' then raise exception 'invalid_upload'; end if;
  meta:=jsonb_build_object('title',title,'authors','[]'::jsonb,'abstract',null,'published_at',null,'updated_at',null,'categories','[]'::jsonb,'venue',null);
  perform app_private.check_catalog_metadata(meta);
  src:='upload:'||p_upload_id::text;
 elsif p_target='import' then
  if p_import_id is null or p_expected_revision is null or p_expected_revision<1 or p_source_id is not null or p_title is not null then raise exception 'invalid_upload'; end if;
  select * into i from app_private.import_requests where account_id=p_account_id and id=p_import_id;
  if not found or not (i.source_id like 'openalex:%' or i.source_id like 'upload:%') then raise exception 'upload_target_unavailable'; end if;
  src:=i.source_id;
 elsif p_target='source' then
  if p_import_id is not null or p_expected_revision is not null or p_title is not null then raise exception 'invalid_upload'; end if;
  src:=app_private.validate_web_source_id(p_source_id);
 else raise exception 'invalid_upload';
 end if;
 digest:=sha256(convert_to(jsonb_build_array('pdf-upload-v1',encode(p_sha256,'hex'),p_byte_count,p_target,src,p_import_id,p_expected_revision,meta)::text,'UTF8'));
 select * into u from app_private.pdf_uploads where id=p_upload_id for update;
 if found then
  if u.account_id<>p_account_id or u.request_sha256<>digest then raise exception 'upload_id_conflict'; end if;
  if u.state='pending' and u.expires_at<=now() then raise exception 'upload_expired'; end if;
  select * into strict o from app_private.stored_objects where id=u.object_id;
  return jsonb_build_object('id',u.id,'bucket',o.bucket,'path',o.path,'state',u.state,'byte_count',o.byte_count,'expires_at',u.expires_at,
   'result',u.finalize_result);
 end if;
 if (select count(*) from app_private.pdf_uploads where account_id=p_account_id and (state='finalized' or (state='pending' and expires_at>now())))>=pol.account_active
 or (select count(*) from app_private.pdf_uploads where state='finalized' or (state='pending' and expires_at>now()))>=pol.environment_active
 then raise exception 'upload_limit'; end if;
 -- The owner's private storage: verified originals of their private papers plus uploads not yet deleted.
 select coalesce(sum(o2.byte_count),0) into used from app_private.stored_objects o2
  where o2.state<>'deleted' and (o2.document_id in (select d.id from app_private.documents d where d.owner_id=p_account_id)
   or (o2.bucket='paper-uploads' and o2.owner_id=p_account_id));
 if used+p_byte_count>pp.private_bytes_per_owner then raise exception 'upload_quota'; end if;
 if (select coalesce(sum(byte_count),0) from app_private.stored_objects where bucket='paper-uploads' and state<>'deleted')+p_byte_count>pol.environment_bytes
 then raise exception 'upload_storage_full'; end if;
 -- Converting a private PDF needs credits; say so before the reader sends the bytes.
 select coalesce(sum(balance-reserved) filter(where revoked_at is null and starts_at<=now() and (expires_at is null or expires_at>now())),0)
  into available from app_private.credit_buckets where account_id=p_account_id;
 if available<1 then raise exception 'insufficient_credits'; end if;
 insert into app_private.stored_objects(bucket,path,owner_id,sha256,byte_count,media_type)
  values('paper-uploads',p_account_id::text||'/'||p_upload_id::text||'.pdf',p_account_id,p_sha256,p_byte_count,'application/pdf') returning * into o;
 insert into app_private.pdf_uploads(id,account_id,object_id,target,source_id,import_id,expected_revision,metadata,request_sha256,expires_at)
  values(p_upload_id,p_account_id,o.id,p_target,src,p_import_id,p_expected_revision,meta,digest,now()+make_interval(hours=>pol.pending_hours)) returning * into u;
 return jsonb_build_object('id',u.id,'bucket',o.bucket,'path',o.path,'state',u.state,'byte_count',o.byte_count,'expires_at',u.expires_at,'result',null);
end $$;

-- Finalizes an upload whose object the caller found in Storage (`p_stored_bytes`, its size there), and
-- creates or retries its import in the same transaction. Idempotent: the upload ID is the operation
-- ID; a repeated call returns the first result. `p_observed_cursor` is the reader's library cursor
-- (as for v2_begin_import); it is not part of the request identity.
create function public.worker_finalize_pdf_upload(p_account_id uuid,p_upload_id uuid,p_observed_cursor bigint,p_stored_bytes bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=p_account_id; u app_private.pdf_uploads; i app_private.import_requests; p app_private.library_policy; s bigint; meta uuid;
 digest bytea; result jsonb;
begin
 if p_upload_id is null or p_observed_cursor is null or p_observed_cursor<0 then raise exception 'invalid_upload'; end if;
 perform public.worker_consume_request(a,'library-write'); perform app_private.lock_library_account(a);
 select * into u from app_private.pdf_uploads where id=p_upload_id and account_id=a for update;
 if not found then raise exception 'upload_unavailable' using errcode='42501'; end if;
 if u.state<>'pending' then
  if u.finalize_result is null then raise exception 'upload_unavailable'; end if;
  return app_private.library_command_response(a,u.finalize_result->'result',true);
 end if;
 if u.expires_at<=now() then raise exception 'upload_expired'; end if;
 -- The caller found the object in Storage with this size (null: not there yet).
 if p_stored_bytes is distinct from (select byte_count from app_private.stored_objects where id=u.object_id) then raise exception 'upload_incomplete'; end if;
 if u.target='import' then
  -- Retries the import through the reader's own command (its receipt is keyed by this upload ID).
  select * into i from app_private.import_requests where account_id=a and id=u.import_id;
  if not found or i.source_id<>u.source_id then raise exception 'upload_target_unavailable'; end if;
  if i.desired_present and i.phase='failed' and i.retryable then
   result:=app_private.library_import_command(a,u.id,u.import_id,u.expected_revision,true);
  elsif i.desired_present and i.phase in ('accepted','resolving','acquiring') then
   -- Already running again: its paper uses the upload when it reaches the download.
   result:=app_private.library_command_response(a,jsonb_build_object('status','attached','kind','import','id',i.id,'revision',i.intent_revision),false);
  else raise exception 'upload_target_unavailable';
  end if;
 else
  digest:=sha256(convert_to(jsonb_build_array('pdf-upload-import-v1',u.id,u.source_id)::text,'UTF8'));
  perform app_private.lock_library_state(a);
  if p_observed_cursor>(select last_seq from app_private.library_sync_state where account_id=a) then raise exception 'invalid_library_cursor'; end if;
  select * into strict p from app_private.library_policy;
  perform app_private.library_check_receipt_capacity(a,true);
  if (select count(*) from app_private.import_requests where account_id=a)+1>p.account_imports then raise exception 'library_account_import_limit'; end if;
  if (select count(*) from app_private.import_requests)+1>p.environment_imports then raise exception 'library_environment_import_limit'; end if;
  if (select count(*) from app_private.import_requests where account_id=a and desired_present and phase in ('accepted','resolving','acquiring'))+1>p.account_active_imports
  or (select count(*) from app_private.import_requests where desired_present and phase in ('accepted','resolving','acquiring'))+1>p.environment_active_imports
  then raise exception 'library_active_import_limit'; end if;
  if u.target='paper' then meta:=app_private.record_upload_metadata(u.id); end if;
  s:=app_private.library_next_seq(a);
  -- An uploaded paper's import starts with its (neutral) catalog identity; its paper starts at download.
  insert into app_private.import_requests(account_id,id,request_sha256,source_id,requested_revision,observed_cursor,created_seq,state_seq,metadata_id,progress)
  values(a,u.id,digest,u.source_id,null,p_observed_cursor,s,s,meta,case when meta is null then 'finding' else 'downloading' end);
  perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,u.id)));
  result:=app_private.library_receipt(a,u.id,digest,jsonb_build_object('status','applied','kind','import','id',u.id,'seq',s,'revision',1));
 end if;
 -- A newer upload for the same paper replaces an unused older one.
 update app_private.pdf_uploads set state='abandoned' where account_id=a and source_id=u.source_id and state='finalized' and id<>u.id;
 update app_private.pdf_uploads set state='finalized',finalized_at=clock_timestamp(),finalize_result=result where id=u.id;
 return result;
end $$;

-- Where this device can try to fetch a web paper's PDF when our servers couldn't (device fallback):
-- the PDF locations the pipeline knows, the landing page, and the DOI link. Owner only.
create function public.v1_import_pdf_sources(p_import_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); i app_private.import_requests; pp app_private.pipeline_papers; doi text; links text[]:='{}'; title text;
begin
 perform public.worker_consume_request(a,'library-read');
 select * into i from app_private.import_requests where account_id=a and id=p_import_id;
 if not found then raise exception 'import_unavailable' using errcode='42501'; end if;
 if i.source_id like 'openalex:%' then
  select * into pp from app_private.pipeline_papers where owner_id=a and source_id=i.source_id and requested_revision=0;
  if not found then select * into pp from app_private.pipeline_papers where owner_id is null and source_id=i.source_id and requested_revision=0; end if;
  links:=coalesce(pp.pdf_urls,'{}');
  if pp.landing_url is not null and not pp.landing_url=any(links) then links:=links||pp.landing_url; end if;
  select pi.identifier into doi from app_private.catalog_metadata cm join app_private.publication_versions v on v.id=cm.version_id
   join app_private.publication_identifiers pi on pi.publication_id=v.publication_id and pi.namespace='doi' where cm.id=i.metadata_id limit 1;
  if doi is not null and not ('https://doi.org/'||doi)=any(links) then links:=links||('https://doi.org/'||doi); end if;
 end if;
 select cm.metadata->>'title' into title from app_private.catalog_metadata cm where cm.id=i.metadata_id and cm.source_id not like 'upload:%';
 return jsonb_build_object('import_id',i.id,'source_id',i.source_id,'title',coalesce(title,app_private.upload_metadata(a,i.source_id)->>'title'),
  'links',to_jsonb(links[1:5]));
end $$;

-- The worker uses a reader's upload as the paper's original: the bytes it read match the session
-- (size and sha256), so they become the owner-private original (014's worker_pipeline_original) and
-- the upload is spent; its object is deleted next (worker_confirm_pdf_uploads_deleted).
create function public.worker_pipeline_upload_original(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_upload_id uuid,
 p_sha256 bytea,p_bytes bigint,p_pages integer,p_path text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; u app_private.pdf_uploads; o app_private.stored_objects;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'download' or p.owner_id is null then raise exception 'invalid_pipeline_stage'; end if;
 select * into u from app_private.pdf_uploads where id=p_upload_id and account_id=p.owner_id and source_id=p.source_id and state='finalized' for update;
 if not found then raise exception 'upload_unavailable'; end if;
 select * into strict o from app_private.stored_objects where id=u.object_id for update;
 if o.sha256<>p_sha256 or o.byte_count<>p_bytes then raise exception 'upload_mismatch'; end if;
 update app_private.pipeline_papers set upload_id=u.id where id=p.id;
 update app_private.pdf_uploads set state='consumed',consumed_at=clock_timestamp() where id=u.id;
 update app_private.stored_objects set state='deleting' where id=o.id and state='pending';
 return public.worker_pipeline_original(p_paper_id,p_claim_id,p_generation,p_sha256,p_bytes,p_pages,p_path);
end $$;

-- An upload the worker could not use (missing, not what was declared, not a readable PDF): it is
-- spent, so a retry of a web paper goes back to its locations instead of the same bad bytes.
create function public.worker_pipeline_upload_rejected(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_upload_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 update app_private.pdf_uploads set state='abandoned' where id=p_upload_id and account_id=p.owner_id and source_id=p.source_id and state='finalized';
 update app_private.stored_objects set state='deleting' where id=(select object_id from app_private.pdf_uploads where id=p_upload_id) and state='pending';
end $$;

-- Upload objects to delete: spent or abandoned uploads, sessions that expired unfinished (after a
-- grace longer than an upload can take), and finalized uploads no import wants any more.
create function public.worker_claim_stale_pdf_uploads(p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.pdf_upload_policy; result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 500 then raise exception 'invalid_limit'; end if;
 select * into strict pol from app_private.pdf_upload_policy;
 -- Rows a finalize or the worker holds are skipped (seen again next time).
 update app_private.pdf_uploads set state='abandoned' where id in (select u.id from app_private.pdf_uploads u
  where u.state='pending' and u.expires_at<=now()-interval '10 minutes' for update skip locked);
 update app_private.pdf_uploads set state='abandoned' where id in (select u.id from app_private.pdf_uploads u
  where u.state='finalized' and (u.finalized_at<=now()-make_interval(days=>pol.unused_days)
   or not exists(select 1 from app_private.import_requests i where i.account_id=u.account_id and i.source_id=u.source_id and i.desired_present
    and i.phase in ('accepted','resolving','acquiring','failed'))) for update skip locked);
 update app_private.stored_objects o set state='deleting' from app_private.pdf_uploads u
  where u.object_id=o.id and u.state in ('consumed','abandoned') and o.state='pending';
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'bucket',x.bucket,'path',x.path) order by x.path),'[]'::jsonb) into result
  from (select o.id,o.bucket,o.path from app_private.stored_objects o where o.bucket='paper-uploads' and o.state='deleting' order by o.path limit p_limit) x;
 return result;
end $$;

create function public.worker_confirm_pdf_uploads_deleted(p_object_ids uuid[]) returns integer
language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if p_object_ids is null or cardinality(p_object_ids)>500 then raise exception 'invalid_limit'; end if;
 update app_private.stored_objects set state='deleted' where id=any(p_object_ids) and bucket='paper-uploads' and state='deleting';
 get diagnostics n=row_count;
 return n;
end $$;

-- 014's link trigger, plus: an uploaded paper's import gets the owner's private paper directly, at download.
create or replace function app_private.pipeline_link_import() returns trigger language plpgsql security definer set search_path='' as $$
declare paper uuid;
begin
 if tg_op='INSERT' then
  if new.source_id like 'upload:%' then
   insert into app_private.pipeline_papers(owner_id,source_id,requested_revision,revision,metadata_id,eligible,stage)
    values(new.account_id,new.source_id,0,1,new.metadata_id,false,'download')
    on conflict(owner_id,source_id,requested_revision) where owner_id is not null do nothing;
   select id into strict paper from app_private.pipeline_papers where owner_id=new.account_id and source_id=new.source_id and requested_revision=0;
  else
   insert into app_private.pipeline_papers(source_id,requested_revision) values(new.source_id,coalesce(new.requested_revision,0))
    on conflict(source_id,requested_revision) where owner_id is null do nothing;
   select id into strict paper from app_private.pipeline_papers where owner_id is null and source_id=new.source_id and requested_revision=coalesce(new.requested_revision,0);
  end if;
  -- A new interest restarts a paper paused for credits or a resumable failure.
  insert into app_private.pipeline_imports(account_id,import_id,paper_id,retry_requested)
   select new.account_id,new.id,paper,exists(select 1 from app_private.pipeline_papers
    where id=paper and stage in ('failed','needs_credits') and resume_stage is not null);
  perform app_private.pipeline_kick();
 elsif old.phase='failed' and new.desired_present and new.phase in ('accepted','acquiring') then
  update app_private.pipeline_imports set retry_requested=true,synced_revision=0,next_sync_at=now() where account_id=new.account_id and import_id=new.id;
  perform app_private.pipeline_kick();
 end if;
 return new;
end $$;

-- 019's worker entry, plus the upload a private paper would use, and an uploaded paper's own title.
create or replace function app_private.pipeline_entry(p app_private.pipeline_papers) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',p.id,'source_id',p.source_id,'requested_revision',p.requested_revision,'revision',p.revision,
  'owner_id',p.owner_id,'stage',p.stage,'error_code',p.error_code,'generation',p.generation,'claim_id',p.claim_id,'state_revision',p.state_revision,
  'metadata_id',p.metadata_id,'eligible',p.eligible,'document_id',p.document_id,'original_object_id',p.original_object_id,
  'approval_id',p.approval_id,'page_count',p.page_count,'artifact_id',p.artifact_id,'failures',p.failures,'ocr_run_id',p.ocr_run_id,
  'license_uri',p.license_uri,
  'source_kind',case when p.source_id like 'openalex:%' then 'web' when p.source_id like 'upload:%' then 'upload' else 'arxiv' end,
  'pdf_urls',to_jsonb(p.pdf_urls),'landing_url',p.landing_url,
  'title',coalesce(app_private.upload_metadata(p.owner_id,p.source_id)->>'title',(select cm.metadata->>'title' from app_private.catalog_metadata cm where cm.id=p.metadata_id)),
  'authors',(select cm.metadata->'authors' from app_private.catalog_metadata cm where cm.id=p.metadata_id),
  'due',p.stage in ('metadata','private_split','download','ocr_fund','ocr_submit','ocr_wait','render') and p.next_attempt_at<=clock_timestamp(),
  'document_sha256',(select encode(d.sha256,'hex') from app_private.documents d where d.id=p.document_id),
  'original_path',(select o.path from app_private.stored_objects o where o.id=p.original_object_id),
  'original_bytes',(select o.byte_count from app_private.stored_objects o where o.id=p.original_object_id),
  'raw_manifest_path',app_private.pipeline_raw_path(p.ocr_run_id),
  'upload',(select jsonb_build_object('id',u.id,'object_id',o.id,'bucket',o.bucket,'path',o.path,'sha256',encode(o.sha256,'hex'),'bytes',o.byte_count)
   from app_private.pipeline_supplied_upload(p) u join app_private.stored_objects o on o.id=u.object_id where u.id is not null),
  'attempt',(select jsonb_build_object('id',x.id,'state',x.state,'page_limit',x.page_limit,'provider_job_id',x.provider_job_id,
    'ocr_run_id',x.ocr_run_id,'submitted_at',x.submitted_at,'raw_manifest_path',app_private.pipeline_raw_path(x.ocr_run_id))
   from app_private.ocr_attempts x where x.paper_id=p.id order by x.created_at desc limit 1))
$$;

-- 019's approval, plus: an uploaded paper is pinned by an owner-upload approval; a web paper whose
-- original a reader supplied records that (its open locations may be none).
create or replace function app_private.approve_private_asset(p app_private.pipeline_papers,p_document uuid,p_object uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare m app_private.catalog_metadata; existing uuid; result uuid:=gen_random_uuid(); pol app_private.library_policy;
 v_evidence jsonb; v_policy text:='owner-private-v1'; v_license text:=p.license_uri;
begin
 select * into strict m from app_private.catalog_metadata where id=p.metadata_id;
 select * into strict pol from app_private.library_policy where singleton for update;
 if m.source_id like 'upload:%' then v_policy:='owner-upload-v1'; v_license:='reader-upload'; end if;
 select id into existing from app_private.catalog_asset_approvals where metadata_id=m.id and document_id=p_document and policy_version=v_policy;
 if existing is not null then return existing; end if;
 if m.source_id like 'upload:%' then
  if p.upload_id is null then raise exception 'invalid_upload_provenance'; end if;
  v_evidence:=jsonb_build_object('scope','owner_private','owner_id',p.owner_id,'source_id',m.source_id,'source_revision',m.source_revision,
    'supplied','reader_upload','upload_id',p.upload_id);
 elsif m.source_id like 'openalex:%' then
  if p.landing_url is null or (p.pdf_urls is null and p.upload_id is null) then raise exception 'invalid_web_provenance'; end if;
  v_evidence:=jsonb_build_object('scope','owner_private','owner_id',p.owner_id,'source_id',m.source_id,'source_revision',m.source_revision,
    'source_url',p.landing_url,'pdf_urls',to_jsonb(p.pdf_urls),'license_uri',p.license_uri)
   ||case when p.upload_id is not null then jsonb_build_object('supplied','reader_upload','upload_id',p.upload_id) else '{}'::jsonb end;
 else
  v_evidence:=jsonb_build_object('scope','owner_private','owner_id',p.owner_id,'source_id',m.source_id,'source_revision',m.source_revision,
    'source_url','https://arxiv.org/abs/'||m.source_id||'v'||m.source_revision,'license_uri',p.license_uri);
 end if;
 if (select count(*) from app_private.catalog_asset_approvals)+1>pol.approval_rows
 or (select coalesce(sum(octet_length(a.evidence::text)),0) from app_private.catalog_asset_approvals a)+octet_length(v_evidence::text)>pol.approval_bytes
 then raise exception 'catalog_approval_limit'; end if;
 insert into app_private.version_documents values(m.version_id,p_document) on conflict do nothing;
 insert into app_private.catalog_asset_approvals values(result,m.version_id,p_document,m.id,p_object,v_license,v_policy,v_evidence,now());
 return result;
end $$;

-- 019's web metadata, plus: a work with no open PDF location is recorded too (its private papers fail
-- at download as `not_open`, where a reader's upload can supply the PDF).
create or replace function public.worker_pipeline_web_metadata(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_metadata jsonb,
 p_doi text,p_pdf_urls text[],p_landing_url text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; meta uuid; landing text;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'metadata' then raise exception 'invalid_pipeline_stage'; end if;
 if p.owner_id is not null or p.source_id not like 'openalex:%' or p_pdf_urls is null
  or (cardinality(p_pdf_urls)>0 and not app_private.web_urls_ok(p_pdf_urls)) or array_ndims(p_pdf_urls)>1
 then raise exception 'invalid_pipeline_metadata'; end if;
 meta:=app_private.record_web_metadata(p.source_id,p_metadata,p_doi);
 landing:=case when length(p_landing_url)<=512 and app_private.web_url_ok(p_landing_url) then p_landing_url
  else 'https://openalex.org/works/'||substr(p.source_id,10) end;
 update app_private.pipeline_papers set revision=1,metadata_id=meta,eligible=false,license_uri=landing,evidence=null,
  pdf_urls=case when cardinality(p_pdf_urls)>0 then p_pdf_urls end,landing_url=landing where id=p.id;
 perform app_private.pipeline_set_stage(p.id,'private_split');
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

-- 027's projection, plus the upload and closed-paper causes.
create or replace function public.worker_pipeline_sync_imports(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns integer
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; link record; i app_private.import_requests; s bigint; changed integer:=0; target text; err text; retry boolean;
 acct uuid; ready uuid[]:='{}';
begin
 select * into p from app_private.pipeline_papers where id=p_paper_id;
 if not found or p.claim_id is distinct from p_claim_id or p.generation is distinct from p_generation or p.lease_until<=clock_timestamp()
 then raise exception 'stale_pipeline_claim'; end if;
 for acct in select distinct pi.account_id from app_private.pipeline_imports pi where pi.paper_id=p.id and pi.synced_revision<p.state_revision
  and pi.next_sync_at<=clock_timestamp() order by pi.account_id loop
  begin
   perform public.worker_consume_request(acct,'library-write');
   ready:=ready||acct;
  exception when others then
   update app_private.pipeline_imports set sync_failures=sync_failures+1,
    next_sync_at=clock_timestamp()+make_interval(secs=>least(3600,15*power(2,least(sync_failures,8))::integer))
    where paper_id=p.id and account_id=acct;
  end;
 end loop;
 perform 1 from app_private.accounts where id=any(ready) and closed_at is null order by id for no key update;
 for link in select pi.* from app_private.pipeline_imports pi where pi.paper_id=p.id and pi.synced_revision<p.state_revision
  and pi.account_id=any(ready) order by pi.account_id,pi.import_id loop
  begin
   select * into i from app_private.import_requests where account_id=link.account_id and id=link.import_id;
   if i.desired_present and i.phase in ('accepted','resolving','acquiring') then
    if p.stage='done' then
     perform public.worker_resolve_import(i.account_id,i.id,i.state_seq,i.intent_revision,p.approval_id,p.artifact_id);
    else
     target:=case when p.stage='metadata' then 'resolving'
      when p.stage in ('private_split','download','ocr_fund','ocr_submit','ocr_wait','ocr_uncertain','render') then 'acquiring'
      when p.stage='source_only' then 'source_only' else 'failed' end;
     err:=case when p.stage='source_only' then 'license_unverified' when p.stage='needs_credits' then 'insufficient_credits'
      when p.stage='failed' then case when p.auto_retry_at is not null then 'download_retrying'
       when p.error_code in ('metadata_unavailable','download_failed','pdf_invalid','rate_limited','too_large','conversion_failed',
        'source_unavailable','source_blocked','not_pdf','pdf_restricted','not_open','upload_failed') then p.error_code
       when p.resume_stage='metadata' then 'metadata_unavailable' when p.resume_stage='download' then 'download_failed' else 'conversion_failed' end end;
     retry:=p.stage='needs_credits' or (p.stage='failed' and p.resume_stage is not null);
     perform app_private.lock_library_account(i.account_id); perform app_private.lock_library_state(i.account_id);
     select * into strict i from app_private.import_requests where account_id=link.account_id and id=link.import_id;
     if i.desired_present and i.phase in ('accepted','resolving','acquiring') then
      s:=app_private.library_next_seq(i.account_id);
      update app_private.import_requests set phase=target,metadata_id=coalesce(metadata_id,p.metadata_id),state_seq=s,
       error_code=err,retryable=coalesce(retry,false),progress=coalesce(app_private.pipeline_progress(p.stage),progress),
       auto_retry_at=case when target='failed' then p.auto_retry_at end
       where account_id=i.account_id and id=i.id;
      perform app_private.library_emit(i.account_id,s,jsonb_build_array(app_private.library_import_entry(i.account_id,i.id)));
     end if;
    end if;
    changed:=changed+1;
   end if;
   update app_private.pipeline_imports set synced_revision=p.state_revision,sync_failures=0 where account_id=link.account_id and import_id=link.import_id;
  exception when others then
   update app_private.pipeline_imports set sync_failures=sync_failures+1,
    next_sync_at=clock_timestamp()+make_interval(secs=>least(3600,15*power(2,least(sync_failures,8))::integer))
    where account_id=link.account_id and import_id=link.import_id;
  end;
 end loop;
 return changed;
end $$;

-- 027's import entry (composed by 029), plus uploaded papers: source `upload`, no source page, and the
-- owner's own title in place of the catalog's neutral placeholder. Every other entry is unchanged.
create or replace function app_private.library_import_entry_base(a uuid,p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind','import','id',i.id,'created_seq',i.created_seq,'state_seq',i.state_seq,'intent_revision',i.intent_revision,
  'visible',i.desired_present and i.phase<>'ready','phase',i.phase,
  'source',case when i.source_id like 'openalex:%' then 'web' when i.source_id like 'upload:%' then 'upload' else 'arxiv' end,'source_id',i.source_id,
  'requested_revision',i.requested_revision,'source_revision',cm.source_revision,'metadata_id',cm.id,'version_id',cm.version_id,
  'metadata',case when cm.id is not null and i.source_id like 'upload:%' then coalesce(app_private.upload_metadata(a,i.source_id),cm.metadata) else cm.metadata end,
  'metadata_recorded_at',cm.recorded_at,
  'source_url',case when i.source_id like 'openalex:%' then 'https://openalex.org/works/'||substr(i.source_id,10)
   when i.source_id like 'upload:%' then null
   else 'https://arxiv.org/abs/'||i.source_id||coalesce('v'||coalesce(cm.source_revision,i.requested_revision),'') end,
  'document_id',i.document_id,'library_item_id',i.library_item_id,
  'error_code',i.error_code,'retryable',i.retryable,
  'progress',case when i.phase in ('accepted','resolving','acquiring') then i.progress end)
  ||case when i.phase='failed' and i.auto_retry_at is not null then jsonb_build_object('auto_retry_at',i.auto_retry_at) else '{}'::jsonb end
 from app_private.import_requests i left join app_private.catalog_metadata cm on cm.id=i.metadata_id
 where i.account_id=a and i.id=p_id
$$;

-- 030's item entry, plus uploaded papers (as for imports above).
create or replace function app_private.library_item_entry(a uuid,p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind','item','id',li.id,'document_id',li.document_id,'created_seq',li.created_seq,'state_seq',li.state_seq,
  'membership_revision',li.membership_revision,'visible',li.removed_at is null,'added_at',li.added_at,
  'last_remove_seq',li.last_remove_seq,'approval_id',li.approval_id,'version_id',ca.version_id,'metadata_id',cm.id,
  'source',case when cm.id is null then null when cm.source_id like 'openalex:%' then 'web' when cm.source_id like 'upload:%' then 'upload' else 'arxiv' end,
  'source_id',cm.source_id,'source_revision',cm.source_revision,
  'metadata',case when cm.source_id like 'upload:%' then coalesce(app_private.upload_metadata(a,cm.source_id),cm.metadata) else cm.metadata end,
  'metadata_recorded_at',cm.recorded_at,
  'source_url',case when cm.id is null then null when cm.source_id like 'openalex:%' then ca.evidence->>'source_url'
   when cm.source_id like 'upload:%' then null
   else 'https://arxiv.org/abs/'||cm.source_id||'v'||cm.source_revision end,
  'scope',d.scope,'page_count',d.page_count,'original_object_id',ca.original_object_id,'artifact_id',li.artifact_id,
  'original_availability',coalesce(ap.original_availability,'unverified'),'render_availability',coalesce(ap.render_availability,'unverified'),
  'original_availability_revision',coalesce(ap.original_availability_revision,0),'render_availability_revision',coalesce(ap.render_availability_revision,0),
  'readiness',case when ap.render_availability='available' then 'converted_ready' when ap.original_availability='available' then 'pdf_ready'
   when ca.id is not null or li.artifact_id is not null then 'unavailable' else 'unverified' end)
  ||case when li.archived_at is not null and li.removed_at is null then jsonb_build_object('archived',true) else '{}'::jsonb end
  ||case when li.removed_at is null and cardinality(li.catalog_tags)>0 then jsonb_build_object('tags',to_jsonb(li.catalog_tags)) else '{}'::jsonb end
  ||case when li.removed_at is null and cardinality(li.user_tags)>0 then jsonb_build_object('user_tags',to_jsonb(li.user_tags)) else '{}'::jsonb end
  ||case when li.removed_at is null and cardinality(li.hidden_tags)>0 then jsonb_build_object('hidden_tags',to_jsonb(li.hidden_tags)) else '{}'::jsonb end
 from app_private.library_items li join app_private.documents d on d.id=li.document_id
 left join app_private.catalog_asset_approvals ca on ca.id=li.approval_id left join app_private.catalog_metadata cm on cm.id=ca.metadata_id
 left join app_private.library_asset_projection ap on (ap.account_id,ap.item_id)=(li.account_id,li.id) where li.account_id=a and li.id=p_id
$$;

-- 019's baseline and delta by read level: 2 (arXiv), 3 (+ web), 4 (+ uploads). The 019 functions keep
-- their signatures for any caller and never return uploads.
create function app_private.library_entry_level(p_entry jsonb) returns integer language sql immutable set search_path='' as $$
 select case p_entry->>'source' when 'web' then 3 when 'upload' then 4 else 2 end
$$;
create function app_private.library_baseline_at(a uuid,p_cursor jsonb,p_limit integer,p_level integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare high bigint; floor bigint; after_seq bigint:=0; after_id uuid:='00000000-0000-0000-0000-000000000000'; after_kind text:=''; result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 100 or p_level is null or p_level not between 2 and 4 then raise exception 'invalid_library_page'; end if;
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_cursor is not null then
  if jsonb_typeof(p_cursor)<>'object' or p_cursor->>'account_id' is distinct from a::text or p_cursor->>'format' is distinct from '2'
  or jsonb_typeof(p_cursor->'through') is distinct from 'number' or not coalesce(p_cursor->>'through' ~ '^[0-9]+$',false)
  or jsonb_typeof(p_cursor->'created_seq') is distinct from 'number' or not coalesce(p_cursor->>'created_seq' ~ '^[0-9]+$',false)
  or jsonb_typeof(p_cursor->'id') is distinct from 'string' or not coalesce(p_cursor->>'id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
  or jsonb_typeof(p_cursor->'kind') is distinct from 'string' then raise exception 'invalid_library_cursor'; end if;
  if (p_cursor->>'through')::bigint>high or (p_cursor->>'through')::bigint<0 then raise exception 'invalid_library_cursor'; end if;
  high:=(p_cursor->>'through')::bigint; after_seq:=(p_cursor->>'created_seq')::bigint; after_id:=(p_cursor->>'id')::uuid; after_kind:=p_cursor->>'kind';
  if after_seq<0 or after_seq>high or after_kind not in ('item','import') then raise exception 'invalid_library_cursor'; end if;
 end if;
 if high<floor then raise exception 'library_resync_required'; end if;
 with entries as materialized (
  select * from (
   select li.created_seq,li.id,'item'::text kind,app_private.library_item_entry(a,li.id) entry from app_private.library_items li where li.account_id=a and li.created_seq<=high
   union all select i.created_seq,i.id,'import',app_private.library_import_entry(a,i.id) from app_private.import_requests i where i.account_id=a and i.created_seq<=high
  ) projected where app_private.library_entry_level(projected.entry)<=p_level
 ), candidates as materialized (
  select * from entries where (created_seq,id,kind)>(after_seq,after_id,after_kind) order by created_seq,id,kind limit p_limit
 ), sized as (
  select *,sum(octet_length(entry::text)+2) over(order by created_seq,id,kind) bytes from candidates
 ), selected as materialized (select * from sized where bytes<=1046528), last_row as (
  select created_seq,id,kind from selected order by created_seq desc,id desc,kind desc limit 1
 ) select jsonb_build_object('format',2,'account_id',a,'baseline_cursor',high,'retained_after',floor,
 'entries',coalesce((select jsonb_agg(entry order by created_seq,id,kind) from selected),'[]'::jsonb),
 'next_cursor',(select jsonb_build_object('format',2,'account_id',a,'through',high,'created_seq',created_seq,'id',id,'kind',kind) from last_row),
 'has_more',exists(select 1 from entries e where (e.created_seq,e.id,e.kind)>coalesce((select row(created_seq,id,kind) from last_row),row(after_seq,after_id,after_kind)))) into result;
 return result;
end $$;
create function app_private.library_delta_at(a uuid,p_after bigint,p_through bigint,p_limit integer,p_level integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare high bigint; floor bigint; result jsonb;
begin
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_after is null or p_after<0 or p_limit is null or p_limit not between 1 and 100 or p_level is null or p_level not between 2 and 4
 or p_after>high or p_through>high or p_through<p_after then raise exception 'invalid_library_cursor'; end if;
 if p_after<floor then raise exception 'library_resync_required'; end if;
 high:=coalesce(p_through,high);
 with shown as materialized (
  select c.seq,case when p_level>=4 then c.entries else (select coalesce(jsonb_agg(x.value order by x.ordinality),'[]'::jsonb)
    from jsonb_array_elements(c.entries) with ordinality x where app_private.library_entry_level(x.value)<=p_level) end entries
  from app_private.library_changes c where c.account_id=a and c.seq>p_after and c.seq<=high
 ), visible as materialized (select seq,entries,octet_length(entries::text)+128 encoded_bytes from shown where jsonb_array_length(entries)>0),
 candidates as materialized (select * from visible order by seq limit p_limit),
 sized as (select *,sum(encoded_bytes) over(order by seq) bytes from candidates),
 selected as materialized (select seq,entries from sized where bytes<=1046528),
 page as (select coalesce(jsonb_agg(jsonb_build_object('seq',seq,'entries',entries) order by seq),'[]'::jsonb) changes,coalesce(max(seq),p_after) last from selected)
 select jsonb_build_object('format',2,'account_id',a,'through',high,'retained_after',floor,'changes',changes,
 'next_cursor',case when exists(select 1 from visible v where v.seq>page.last) then page.last else high end,
 'has_more',exists(select 1 from visible v where v.seq>page.last)) into result from page;
 return result;
end $$;
create or replace function app_private.library_baseline_for(a uuid,p_cursor jsonb,p_limit integer,p_web boolean) returns jsonb language sql stable security definer set search_path='' as $$
 select app_private.library_baseline_at(a,p_cursor,p_limit,case when p_web then 3 when p_web is not null then 2 end)
$$;
create or replace function app_private.library_delta_for(a uuid,p_after bigint,p_through bigint,p_limit integer,p_web boolean) returns jsonb language sql stable security definer set search_path='' as $$
 select app_private.library_delta_at(a,p_after,p_through,p_limit,case when p_web then 3 when p_web is not null then 2 end)
$$;
create function public.v4_library_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin perform public.worker_consume_request(a,'library-read'); result:=app_private.library_baseline_at(a,p_cursor,p_limit,4);
 perform app_private.consume_library_transfer(a,result); return result; end $$;
create function public.v4_library_changes(p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin perform public.worker_consume_request(a,'library-read'); result:=app_private.library_delta_at(a,p_after,p_through,p_limit,4);
 perform app_private.consume_library_transfer(a,result); return result; end $$;

-- 019's resolution, generalized by read level: an import never ends up referencing an item that a
-- reader at its own read version can't see, and never re-pins an item into a level its readers
-- can't see. Either case ends as a membership conflict without an item.
create or replace function public.worker_resolve_import(p_account_id uuid,p_import_id uuid,p_expected_state_seq bigint,p_expected_intent_revision bigint,
 p_approval_id uuid,p_artifact_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare i app_private.import_requests; ca app_private.catalog_asset_approvals; m app_private.catalog_metadata; li app_private.library_items;
 s bigint; item_id uuid; digest bytea; conflict boolean; cross_kind boolean; e jsonb; p app_private.library_policy; item_level integer;
begin
 digest:=sha256(convert_to(jsonb_build_array(p_expected_state_seq,p_expected_intent_revision,p_approval_id,p_artifact_id)::text,'UTF8'));
 perform public.worker_consume_request(p_account_id,'library-write'); perform app_private.lock_library_account(p_account_id);
 select * into ca from app_private.catalog_asset_approvals where id=p_approval_id;
 if not found then raise exception 'asset_approval_required'; end if;
 perform 1 from app_private.documents where id=ca.document_id and (scope='shared_catalog' or owner_id=p_account_id) for key share;
 if not found then raise exception 'document_unavailable'; end if;
 perform app_private.lock_library_state(p_account_id);
 select * into strict p from app_private.library_policy;
 select * into i from app_private.import_requests where account_id=p_account_id and id=p_import_id;
 if not found then raise exception 'import_unavailable'; end if;
 if i.resolution_sha256=digest then return app_private.library_import_entry(p_account_id,i.id); end if;
 if i.state_seq is distinct from p_expected_state_seq or i.intent_revision is distinct from p_expected_intent_revision or not i.desired_present
 or i.phase not in ('accepted','resolving','acquiring') then raise exception 'stale_import_checkpoint'; end if;
 select * into strict m from app_private.catalog_metadata where id=ca.metadata_id;
 if m.source_id<>i.source_id or (i.requested_revision is not null and m.source_revision<>i.requested_revision)
 or (i.metadata_id is not null and i.metadata_id<>m.id) then raise exception 'import_source_mismatch'; end if;
 if not exists(select 1 from app_private.stored_objects o join app_private.documents d on d.id=o.document_id where o.id=ca.original_object_id
 and o.state='verified' and o.sha256=d.sha256 and o.byte_count=d.byte_count) then raise exception 'original_object_unavailable'; end if;
 if p_artifact_id is not null and not exists(select 1 from app_private.render_artifacts r join app_private.ocr_runs o on o.id=r.ocr_run_id
 join app_private.stored_objects so on so.id=r.manifest_object_id where r.id=p_artifact_id and o.document_id=ca.document_id
 and r.renderer_version=any(p.compatible_renderers) and so.state='verified' and so.document_id=ca.document_id)
 then raise exception 'artifact_incompatible'; end if;
 select * into li from app_private.library_items where account_id=p_account_id and document_id=ca.document_id;
 if li.id is not null and li.approval_id is not null then
  select app_private.source_level(xm.source_id) into item_level from app_private.catalog_asset_approvals x
   join app_private.catalog_metadata xm on xm.id=x.metadata_id where x.id=li.approval_id;
 end if;
 cross_kind:=li.id is not null and case when li.approval_id is null then app_private.source_level(i.source_id)>2
  else coalesce(item_level,2)>app_private.source_level(i.source_id) end;
 conflict:=cross_kind or (li.id is not null and li.removed_at is not null and (li.last_remove_seq>i.observed_cursor or li.last_remove_seq>i.created_seq));
 s:=app_private.library_next_seq(p_account_id);
 item_id:=case when cross_kind then null else li.id end;
 if not conflict and (li.id is null or li.removed_at is not null or (li.last_intent_seq<i.created_seq and li.last_remove_seq<=i.observed_cursor)) then
  item_id:=app_private.library_write_item(p_account_id,ca.document_id,true,s,ca.id,p_artifact_id,i.created_seq);
 end if;
 update app_private.import_requests set metadata_id=m.id,approval_id=case when item_id is not null then ca.id end,
 document_id=case when item_id is not null then ca.document_id end,library_item_id=item_id,artifact_id=p_artifact_id,resolution_sha256=digest,
 phase=case when conflict then 'membership_conflict' else 'ready' end,error_code=case when conflict then 'membership_conflict' end,state_seq=s,retryable=false
 where account_id=p_account_id and id=i.id;
 e:=jsonb_build_array(app_private.library_import_entry(p_account_id,i.id));
 if item_id is not null then e:=e||jsonb_build_array(app_private.library_item_entry(p_account_id,item_id)); end if;
 perform app_private.library_emit(p_account_id,s,e);
 return app_private.library_import_entry(p_account_id,i.id);
end $$;

-- 030's wanted versions, without uploaded papers (their neutral catalog identity has nothing to tag,
-- and a reader's own title is never sent for platform-paid tagging).
create or replace function app_private.tag_wanted_versions() returns table(version_id uuid,account_id uuid) language sql stable security definer set search_path='' as $$
 select distinct on (w.version_id) w.version_id,w.account_id from (
  select ca.version_id,li.account_id,li.added_at at_time from app_private.library_items li
   join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
   join app_private.catalog_metadata cm on cm.id=ca.metadata_id and cm.source_id not like 'upload:%'
   join app_private.accounts acct on acct.id=li.account_id and acct.closed_at is null where li.removed_at is null
  union all
  select cm.version_id,i.account_id,i.created_at from app_private.import_requests i join app_private.catalog_metadata cm on cm.id=i.metadata_id
   join app_private.accounts acct on acct.id=i.account_id and acct.closed_at is null
   where i.desired_present and i.phase in ('accepted','resolving','acquiring') and cm.source_id not like 'upload:%') w
 order by w.version_id,w.at_time,w.account_id
$$;

-- 017's deletion, plus the account's upload sessions (their titles are personal). Their objects are
-- owner-scoped, so account_deletion_objects already returns them for removal.
create or replace function public.worker_delete_account_begin(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare acct app_private.accounts;
begin
 select * into acct from app_private.accounts where id=p_account_id for update;
 if not found then raise exception 'account_unavailable'; end if;
 perform 1 from app_private.keyrings where account_id=p_account_id for update;
 if exists(select 1 from app_private.metered_operations where account_id=p_account_id and state<>'settled') then
  raise exception 'account_busy';
 end if;
 update app_private.accounts set closed_at=coalesce(closed_at,now()) where id=p_account_id;
 perform set_config('app_private.deleting_account',p_account_id::text,true);

 delete from app_private.pipeline_imports where account_id=p_account_id;
 delete from app_private.import_requests where account_id=p_account_id;
 delete from app_private.library_items where account_id=p_account_id;
 delete from app_private.library_commands where account_id=p_account_id;
 delete from app_private.library_changes where account_id=p_account_id;
 delete from app_private.library_sync_state where account_id=p_account_id;
 delete from app_private.library_transfer_months where scope_id=p_account_id::text;
 delete from app_private.paper_read_grants where account_id=p_account_id;

 update app_private.sync_environment_storage e set ciphertext_bytes=e.ciphertext_bytes-s.bytes, event_count=e.event_count-s.events
 from (select coalesce(sum(octet_length(ciphertext)),0) bytes, count(*) events from app_private.sync_events where account_id=p_account_id) s
 where e.singleton and s.events>0;
 delete from app_private.sync_events where account_id=p_account_id;
 delete from app_private.device_envelopes where account_id=p_account_id;
 delete from app_private.enrollment_requests where account_id=p_account_id;
 delete from app_private.key_transitions where account_id=p_account_id;
 delete from app_private.devices where account_id=p_account_id;
 delete from app_private.keyrings where account_id=p_account_id;
 delete from app_private.sync_account_storage where account_id=p_account_id;
 delete from app_private.sync_transfer_months where scope_id=p_account_id::text;

 delete from app_private.support_status_events where report_id in (select id from app_private.support_reports where account_id=p_account_id);
 delete from app_private.support_messages where report_id in (select id from app_private.support_reports where account_id=p_account_id);
 delete from app_private.support_attachments where account_id=p_account_id;
 delete from app_private.attachment_uploads where account_id=p_account_id;
 delete from app_private.support_reports where account_id=p_account_id;

 delete from app_private.api_rate_windows where scope_id=p_account_id::text;
 delete from app_private.app_roles where account_id=p_account_id;

 update app_private.pipeline_papers set stage='failed', resume_stage=null, error_code='owner_deleted',
  claim_id=null, lease_until=null, generation=generation+1, state_revision=state_revision+1, updated_at=now()
 where owner_id=p_account_id and stage not in ('done','failed','source_only');

 update app_private.stored_objects set state='deleting'
 where id in (select id from app_private.account_deletion_objects(p_account_id)) and state in ('pending','verified');

 -- Upload sessions (their objects are owner-scoped and returned below).
 delete from app_private.pdf_uploads where account_id=p_account_id;

 return jsonb_build_object('account_id',p_account_id,
  'objects',coalesce((select jsonb_agg(jsonb_build_object('bucket',o.bucket,'path',o.path) order by o.path)
   from app_private.account_deletion_objects(p_account_id) o where o.state='deleting'),'[]'::jsonb),
  'prefixes',jsonb_build_array(jsonb_build_object('bucket','paper-assets','prefix','private/'||p_account_id::text||'/'),
   jsonb_build_object('bucket','support','prefix',p_account_id::text||'/'),
   jsonb_build_object('bucket','paper-uploads','prefix',p_account_id::text||'/'))
   ||coalesce((select jsonb_agg(distinct jsonb_build_object('bucket',o.bucket,'prefix',regexp_replace(o.path,'manifest\.json$','')))
    from app_private.account_deletion_objects(p_account_id) o
    where o.bucket='paper-assets' and o.document_id is not null and o.path ~ '^(raw|reader)/[0-9a-f]{64}/manifest\.json$'),'[]'::jsonb),
  'private_prefix','private/'||p_account_id::text||'/');
end $$;

revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
do $$ declare f record; begin
 for f in select p.oid::regprocedure signature,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
 and p.proname in ('worker_begin_pdf_upload','worker_finalize_pdf_upload','v1_import_pdf_sources','worker_pipeline_upload_original',
  'worker_pipeline_upload_rejected','worker_claim_stale_pdf_uploads','worker_confirm_pdf_uploads_deleted','v4_library_page','v4_library_changes',
  'worker_pipeline_web_metadata','worker_pipeline_sync_imports','worker_resolve_import','worker_delete_account_begin') loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
  execute format('grant execute on function %s to %I',f.signature,case when f.proname like 'worker_%' then 'service_role' else 'authenticated' end);
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
