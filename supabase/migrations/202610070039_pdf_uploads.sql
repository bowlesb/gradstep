-- Bounded authenticated PDF chunk ingress and exact supplied-source identity.
-- Design and rollout gates: docs/architecture/ASSET_SPENDING.md.
-- No reusable Storage upload token; no plaintext personal titles.
-- Feature defaults disabled pending client/crypto, two-bucket inventory and load validation.
-- Lifecycle: receiving -> frozen -> checking -> consumed; cancellation/expiry -> abandoned.
-- Frozen selection -> library attachment is a durable two-transaction saga; holds never disappear between them.
-- Worker admission transfers future holds and pins the exact session before any physical read/write.

-- Apply with the pipeline disabled (worker_set_pipeline_enabled(false)). Client
-- imports may still be running: gate their account lock before taking any of
-- their downstream DDL locks, so an in-flight account -> import/paper mutation
-- can commit while this transaction waits. The gate lasts through COMMIT.
begin;
set local lock_timeout='15s';
lock table app_private.accounts in exclusive mode;

insert into app_private.api_rate_rules values('add-paper',3600,120,2000),('pdf-upload',3600,40,400),
 ('pdf-upload-part',3600,768,8192),('pdf-upload-status',3600,600,6000),('pdf-upload-finish',3600,120,1200) on conflict(route) do nothing;

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

-- Ingress stays disabled until client/encryption and two-bucket inventory gates pass.
create table app_private.pdf_upload_policy (
 singleton boolean primary key default true check(singleton),
 enabled boolean not null default false,
 account_sessions integer not null default 2000 check(account_sessions between 1 and 10000),
 environment_sessions integer not null default 20000 check(environment_sessions between 1 and 100000),
 session_reads integer not null default 128 check(session_reads between 1 and 1024),
 account_active integer not null default 10 check(account_active between 1 and 100),
 environment_active integer not null default 200 check(environment_active between 1 and 10000),
 chunk_bytes integer not null default 4194304 check(chunk_bytes=4194304),
 part_attempts integer not null default 3 check(part_attempts between 1 and 8),
 pending_hours integer not null default 24 check(pending_hours between 1 and 168),
 unused_days integer not null default 7 check(unused_days between 1 and 90),
 required_inventory_scope integer not null default 2 check(required_inventory_scope=2)
);
insert into app_private.pdf_upload_policy default values;
alter table app_private.pdf_upload_policy enable row level security;

create table app_private.pdf_uploads (
 id uuid primary key,
 account_id uuid not null references app_private.accounts(id),
 target text not null check(target in ('paper','import','source')),
 source_id text not null check(length(source_id) between 1 and 128 and (source_id like 'openalex:%' or source_id like 'upload:%')),
 import_id uuid, expected_revision bigint check(expected_revision>0),
 bound_import_id uuid, bound_intent_revision bigint,
 paper_id uuid references app_private.pipeline_papers(id),
 sha256 bytea not null check(octet_length(sha256)=32),
 byte_count bigint not null check(byte_count between 1 and 67108864),
 chunk_bytes integer not null check(chunk_bytes=4194304),
 part_count integer not null check(part_count between 1 and 16),
 request_sha256 bytea not null check(octet_length(request_sha256)=32),
 state text not null default 'receiving' check(state in ('receiving','frozen','checking','consumed','abandoned')),
 revision bigint not null default 1 check(revision>0),
 generation bigint not null default 1 check(generation>0),
 finalize_result jsonb, observed_cursor bigint check(observed_cursor>=0),
 selection_sha256 bytea check(octet_length(selection_sha256)=32),
 expires_at timestamptz not null,
 created_at timestamptz not null default now(),
 finalized_at timestamptz, consumed_at timestamptz,
 check((target='import')=(import_id is not null and expected_revision is not null)),
 check(target<>'paper' or source_id='upload:'||id::text),
 check(target<>'source' or source_id like 'openalex:%'),
 check(state<>'receiving' or finalized_at is null),
 check(state not in ('frozen','checking','consumed') or (finalized_at is not null and selection_sha256 is not null and observed_cursor is not null)),
 check((state='consumed')=(consumed_at is not null))
);
-- Only one concrete supply may be selected for an account/source. There is no newest-wins lookup.
create unique index pdf_uploads_selected_source on app_private.pdf_uploads(account_id,source_id) where state='checking';
create index pdf_uploads_pending on app_private.pdf_uploads(expires_at) where state='receiving';
alter table app_private.pdf_uploads enable row level security;
alter table app_private.pipeline_papers add column upload_id uuid references app_private.pdf_uploads(id) on delete set null,
 add column upload_generation bigint check(upload_generation>0),
 add column download_admitted_claim_id uuid,
 add column download_admitted_generation bigint check(download_admitted_generation>0);

create table app_private.pdf_upload_parts (
 upload_id uuid not null references app_private.pdf_uploads(id),
 part_index integer not null check(part_index between 0 and 15),
 sha256 bytea not null check(octet_length(sha256)=32),
 byte_count integer not null check(byte_count between 1 and 4194304),
 selected_object_id uuid references app_private.stored_objects(id),
 primary key(upload_id,part_index)
);
create table app_private.pdf_upload_holds (
 upload_id uuid not null references app_private.pdf_uploads(id),
 owner_id uuid not null references app_private.accounts(id),
 kind text not null check(kind in ('staging','original','raw','reader')),
 bytes bigint not null check(bytes>0), objects integer not null check(objects>0),
 primary key(upload_id,kind)
);
create table app_private.pdf_upload_write_attempts (
 id uuid primary key,
 upload_id uuid not null,
 part_index integer not null,
 object_id uuid not null unique references app_private.stored_objects(id),
 started_at timestamptz not null default clock_timestamp(),
 reconciliation_after timestamptz not null default clock_timestamp(),
 finished_at timestamptz,
 evidence text check(evidence in ('upload_response','matching_object')),
 foreign key(upload_id,part_index) references app_private.pdf_upload_parts(upload_id,part_index),
 check((finished_at is null)=(evidence is null))
);
create index pdf_upload_write_unknown on app_private.pdf_upload_write_attempts(upload_id,started_at) where finished_at is null;
create table app_private.pdf_upload_delete_batches (
 id uuid primary key default gen_random_uuid(),
 upload_id uuid not null references app_private.pdf_uploads(id),
 created_at timestamptz not null default clock_timestamp(), completed_at timestamptz,
 next_attempt_at timestamptz not null default clock_timestamp()
);
create table app_private.pdf_upload_delete_members (
 batch_id uuid not null references app_private.pdf_upload_delete_batches(id),
 object_id uuid not null references app_private.stored_objects(id),
 primary key(batch_id,object_id)
);
create table app_private.pdf_upload_reads (
 id uuid primary key,
 upload_id uuid not null references app_private.pdf_uploads(id),
 purpose text not null check(purpose in ('assembly','reconciliation')),
 attempt_id uuid references app_private.pdf_upload_write_attempts(id),
 period date not null,
 bytes bigint not null check(bytes between 1 and 67108864),
 created_at timestamptz not null default clock_timestamp(),
 observed_bytes bigint check(observed_bytes>=0 and observed_bytes<=bytes), observed_at timestamptz,
 check((purpose='reconciliation')=(attempt_id is not null)),
 check((observed_bytes is null)=(observed_at is null))
);

-- The same physical-capacity mutex serializes existing paper work and ingress.
create or replace function app_private.paper_asset_check_capacity(p_owner uuid) returns void
language plpgsql security definer set search_path='' as $$
declare cap app_private.paper_storage_capacity; used bigint; n bigint; owned bigint; owner_cap bigint;
begin
 select * into strict cap from app_private.paper_storage_capacity where singleton for update;
 select coalesce(sum(byte_count),0),count(*) into used,n from app_private.stored_objects
  where bucket in ('paper-assets','paper-uploads') and state<>'deleted';
 select used+coalesce(sum(bytes),0),n+coalesce(sum(objects),0) into used,n from app_private.paper_asset_holds;
 select used+coalesce(sum(bytes),0),n+coalesce(sum(objects),0) into used,n from app_private.pdf_upload_holds;
 if used>cap.max_bytes or n>cap.max_objects then raise exception 'paper_storage_capacity'; end if;
 if p_owner is not null then
  select coalesce(sum(o.byte_count),0) into owned from app_private.stored_objects o
   left join app_private.documents d on d.id=o.document_id
   where o.state<>'deleted' and ((o.bucket='paper-assets' and d.owner_id=p_owner)
    or (o.bucket='paper-uploads' and o.owner_id=p_owner));
  select owned+coalesce(sum(bytes),0) into owned from app_private.paper_asset_holds where owner_id=p_owner;
  select owned+coalesce(sum(bytes),0) into owned from app_private.pdf_upload_holds where owner_id=p_owner;
  select private_bytes_per_owner into strict owner_cap from app_private.pipeline_policy where singleton;
  if owned>owner_cap then raise exception 'paper_owner_storage_capacity'; end if;
 end if;
end $$;

create function app_private.pdf_upload_lock_account(a uuid,p_allow_closed boolean default false) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from app_private.accounts where id=a and
  (p_allow_closed or (closed_at is null and not spending_suspended)) for no key update;
 if not found then raise exception 'account_unavailable' using errcode='42501'; end if;
end $$;

create function app_private.pdf_upload_session(u app_private.pdf_uploads) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin return (select jsonb_build_object('upload_id',u.id,'protocol','upload-chunks-v1','state',u.state,'revision',u.revision,
  'generation',u.generation,'byte_count',u.byte_count,'chunk_bytes',u.chunk_bytes,'part_count',u.part_count,
  'expires_at',u.expires_at,'result',u.finalize_result,'descriptor_required',u.target='paper',
  'descriptor_ref',app_private.library_descriptor_ref(u.account_id,u.source_id),
  'parts',coalesce((select jsonb_agg(jsonb_build_object('index',p.part_index,'bytes',p.byte_count,
   'verified',p.selected_object_id is not null,
   'attempts',(select count(*) from app_private.pdf_upload_write_attempts w where w.upload_id=u.id and w.part_index=p.part_index),
   'uncertain',(select count(*) from app_private.pdf_upload_write_attempts w where w.upload_id=u.id and w.part_index=p.part_index and w.finished_at is null))
   order by p.part_index) from app_private.pdf_upload_parts p where p.upload_id=u.id),'[]'::jsonb))); end
$$;

create function app_private.pipeline_supplied_upload(p app_private.pipeline_papers) returns app_private.pdf_uploads
language sql stable security definer set search_path='' as $$
 select u.* from app_private.pdf_uploads u where p.owner_id is not null and u.account_id=p.owner_id
  and u.source_id=p.source_id and u.state='checking'
  and ((p.upload_id is not null and u.id=p.upload_id and u.generation=p.upload_generation) or (p.upload_id is null and exists(
   select 1 from app_private.pipeline_imports pi join app_private.import_requests i
    on (i.account_id,i.id)=(pi.account_id,pi.import_id)
   where pi.paper_id=p.id and pi.account_id=p.owner_id and pi.import_id=u.bound_import_id
    and i.desired_present and i.intent_revision=u.bound_intent_revision)))
$$;

-- Read levels: v2 shows arXiv only, v3 adds web papers, v4 adds uploads.
create function app_private.source_level(p_source_id text) returns integer language sql immutable set search_path='' as $$
 select case when p_source_id like 'openalex:%' then 3 when p_source_id like 'upload:%' then 4 else 2 end
$$;

-- A neutral catalog identity; the personal title lives only in its encrypted descriptor.
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

-- Authenticated ingress service uses these RPCs; callers never receive Storage write credentials.
create function public.worker_begin_pdf_upload(p_account_id uuid,p_upload_id uuid,p_sha256 bytea,p_byte_count bigint,
 p_part_sha256 bytea[],p_target text,p_import_id uuid default null,p_expected_revision bigint default null,p_source_id text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.pdf_upload_policy; pp app_private.pipeline_policy; u app_private.pdf_uploads;
 i app_private.import_requests; src text; digest bytea; available bigint; n integer; j integer; size integer;
begin
 perform app_private.pdf_upload_lock_account(p_account_id);
 perform public.worker_consume_request(p_account_id,'pdf-upload');
 select * into strict pol from app_private.pdf_upload_policy where singleton;
 if not pol.enabled then raise exception 'upload_disabled'; end if;
 select * into strict pp from app_private.pipeline_policy;
 if p_upload_id is null or p_sha256 is null or octet_length(p_sha256)<>32 or p_byte_count is null or p_byte_count<1 then raise exception 'invalid_upload'; end if;
 if p_byte_count>pp.max_pdf_bytes or p_byte_count>67108864 then raise exception 'upload_too_large'; end if;
 n:=((p_byte_count+pol.chunk_bytes-1)/pol.chunk_bytes)::integer;
 if p_part_sha256 is null or array_ndims(p_part_sha256) is distinct from 1 or array_lower(p_part_sha256,1)<>1
  or cardinality(p_part_sha256)<>n or exists(select 1 from unnest(p_part_sha256) x where x is null or octet_length(x)<>32)
 then raise exception 'invalid_upload'; end if;
 if p_target='paper' then
  if p_import_id is not null or p_expected_revision is not null or p_source_id is not null then raise exception 'invalid_upload'; end if;
  src:='upload:'||p_upload_id::text;
 elsif p_target='import' then
  if p_import_id is null or p_expected_revision is null or p_expected_revision<1 or p_source_id is not null then raise exception 'invalid_upload'; end if;
  select * into i from app_private.import_requests where account_id=p_account_id and id=p_import_id;
  if not found or not (i.source_id like 'openalex:%' or i.source_id like 'upload:%') then raise exception 'upload_target_unavailable'; end if;
  src:=i.source_id;
 elsif p_target='source' then
  if p_import_id is not null or p_expected_revision is not null then raise exception 'invalid_upload'; end if;
  src:=app_private.validate_web_source_id(p_source_id);
 else raise exception 'invalid_upload'; end if;
 digest:=sha256(convert_to(jsonb_build_array('upload-chunks-v1',encode(p_sha256,'hex'),p_byte_count,
  to_jsonb(p_part_sha256),p_target,src,p_import_id,p_expected_revision)::text,'UTF8'));
 select * into u from app_private.pdf_uploads where id=p_upload_id for update;
 if found then
  if u.account_id<>p_account_id or u.request_sha256<>digest then raise exception 'upload_id_conflict'; end if;
  return app_private.pdf_upload_session(u);
 end if;
 if p_target='import' and (not i.desired_present or i.intent_revision<>p_expected_revision
  or i.phase not in ('accepted','resolving','acquiring','failed')) then raise exception 'upload_target_unavailable'; end if;
 -- Account lock prevents same-owner admission/closure; capacity serializes global counts and both buckets.
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if not (select enabled from app_private.pdf_upload_policy where singleton) then raise exception 'upload_disabled'; end if;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 if (select count(*) from app_private.pdf_uploads where account_id=p_account_id)>=pol.account_sessions
  or (select count(*) from app_private.pdf_uploads)>=pol.environment_sessions then raise exception 'upload_receipt_capacity'; end if;
 if (select count(*) from app_private.pdf_uploads where account_id=p_account_id and state in ('receiving','frozen','checking'))>=pol.account_active
  or (select count(*) from app_private.pdf_uploads where state in ('receiving','frozen','checking'))>=pol.environment_active then raise exception 'upload_limit'; end if;
 select coalesce(sum(balance-reserved) filter(where revoked_at is null and starts_at<=now() and (expires_at is null or expires_at>now())),0)
  into available from app_private.credit_buckets where account_id=p_account_id;
 if available<1 then raise exception 'insufficient_credits'; end if;
 insert into app_private.pdf_uploads(id,account_id,target,source_id,import_id,expected_revision,sha256,byte_count,chunk_bytes,part_count,request_sha256,expires_at)
  values(p_upload_id,p_account_id,p_target,src,p_import_id,p_expected_revision,p_sha256,p_byte_count,pol.chunk_bytes,n,digest,
   clock_timestamp()+make_interval(hours=>pol.pending_hours)) returning * into u;
 for j in 0..n-1 loop
  size:=least(pol.chunk_bytes,p_byte_count-j::bigint*pol.chunk_bytes)::integer;
  insert into app_private.pdf_upload_parts values(u.id,j,p_part_sha256[j+1],size,null);
 end loop;
 insert into app_private.pdf_upload_holds(upload_id,owner_id,kind,bytes,objects) values
  (u.id,p_account_id,'staging',p_byte_count,n),(u.id,p_account_id,'original',pp.max_pdf_bytes,1),
  (u.id,p_account_id,'raw',58982400,4),(u.id,p_account_id,'reader',33816576,513);
 perform app_private.paper_asset_check_capacity(p_account_id);
 return app_private.pdf_upload_session(u);
end $$;

create function public.worker_pdf_upload_status(p_account_id uuid,p_upload_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u app_private.pdf_uploads;
begin
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null for key share;
 if not found then raise exception 'account_unavailable'; end if;
 perform public.worker_consume_request(p_account_id,'pdf-upload-status');
 select * into u from app_private.pdf_uploads where id=p_upload_id and account_id=p_account_id;
 if not found then raise exception 'upload_unavailable'; end if;
 return app_private.pdf_upload_session(u);
end $$;

-- This reads no body and grants no physical side effect. It can skip an already completed/replayed part.
create function public.worker_pdf_upload_part(p_account_id uuid,p_upload_id uuid,p_generation bigint,p_part_index integer,p_attempt_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u app_private.pdf_uploads; part app_private.pdf_upload_parts; w app_private.pdf_upload_write_attempts;
begin
 perform app_private.pdf_upload_lock_account(p_account_id);
 perform public.worker_consume_request(p_account_id,'pdf-upload-part');
 if not (select enabled from app_private.pdf_upload_policy where singleton) then raise exception 'upload_disabled'; end if;
 select * into u from app_private.pdf_uploads where id=p_upload_id and account_id=p_account_id;
 if not found then raise exception 'upload_unavailable'; end if;
 if u.state<>'receiving' or u.generation is distinct from p_generation then raise exception 'upload_not_receiving'; end if;
 if u.expires_at<=clock_timestamp() then raise exception 'upload_expired'; end if;
 select * into part from app_private.pdf_upload_parts where upload_id=u.id and part_index=p_part_index;
 if not found or p_attempt_id is null then raise exception 'invalid_upload_part'; end if;
 select * into w from app_private.pdf_upload_write_attempts where id=p_attempt_id;
 if found and (w.upload_id,w.part_index) is distinct from (u.id,p_part_index) then raise exception 'upload_id_conflict'; end if;
 if part.selected_object_id is not null then return jsonb_build_object('receive',false,'verified',true); end if;
 if w.id is not null then return jsonb_build_object('receive',false,'verified',w.finished_at is not null,'uncertain',w.finished_at is null); end if;
 if (select count(*) from app_private.pdf_upload_write_attempts where upload_id=u.id and part_index=p_part_index)
  >=(select part_attempts from app_private.pdf_upload_policy where singleton) then raise exception 'upload_attempt_limit'; end if;
 return jsonb_build_object('receive',true,'bytes',part.byte_count,'sha256',encode(part.sha256,'hex'));
end $$;

-- Called only after the Edge handler has read/hashed the exact body. Each true grant permits one PUT.
create function public.worker_pdf_upload_write(p_account_id uuid,p_upload_id uuid,p_generation bigint,p_part_index integer,
 p_attempt_id uuid,p_sha256 bytea,p_byte_count integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u app_private.pdf_uploads; part app_private.pdf_upload_parts; w app_private.pdf_upload_write_attempts;
 o app_private.stored_objects; n integer;
begin
 perform app_private.pdf_upload_lock_account(p_account_id);
 if not (select enabled from app_private.pdf_upload_policy where singleton) then raise exception 'upload_disabled'; end if;
 select * into u from app_private.pdf_uploads where id=p_upload_id and account_id=p_account_id for update;
 if not found then raise exception 'upload_unavailable'; end if;
 if u.state<>'receiving' or u.generation is distinct from p_generation then raise exception 'upload_not_receiving'; end if;
 if u.expires_at<=clock_timestamp() then raise exception 'upload_expired'; end if;
 select * into strict part from app_private.pdf_upload_parts where upload_id=u.id and part_index=p_part_index;
 if p_attempt_id is null or (part.sha256,part.byte_count) is distinct from (p_sha256,p_byte_count) then raise exception 'upload_mismatch'; end if;
 select * into w from app_private.pdf_upload_write_attempts where id=p_attempt_id;
 if found then
  if (w.upload_id,w.part_index) is distinct from (u.id,p_part_index) then raise exception 'upload_id_conflict'; end if;
  return jsonb_build_object('write',false,'verified',w.finished_at is not null,'uncertain',w.finished_at is null);
 end if;
 if part.selected_object_id is not null then return jsonb_build_object('write',false,'verified',true); end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if not (select enabled from app_private.pdf_upload_policy where singleton) then raise exception 'upload_disabled'; end if;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 select count(*) into n from app_private.pdf_upload_write_attempts where upload_id=u.id and part_index=p_part_index;
 if n>=(select part_attempts from app_private.pdf_upload_policy where singleton) then raise exception 'upload_attempt_limit'; end if;
 insert into app_private.stored_objects(bucket,path,owner_id,sha256,byte_count,media_type)
  values('paper-uploads',p_account_id::text||'/'||u.id::text||'/'||p_part_index::text||'/'||p_attempt_id::text||'.chunk',
   p_account_id,part.sha256,part.byte_count,'application/octet-stream') returning * into o;
 insert into app_private.pdf_upload_write_attempts(id,upload_id,part_index,object_id) values(p_attempt_id,u.id,p_part_index,o.id);
 if n=0 then
  -- First attempts consume pre-reserved staging headroom. Replacements add a separate possible object.
  if (select objects from app_private.pdf_upload_holds where upload_id=u.id and kind='staging')=1 then
   delete from app_private.pdf_upload_holds where upload_id=u.id and kind='staging';
  else
   update app_private.pdf_upload_holds set bytes=bytes-part.byte_count,objects=objects-1 where upload_id=u.id and kind='staging';
  end if;
 end if;
 perform app_private.paper_asset_check_capacity(p_account_id);
 return jsonb_build_object('write',true,'verified',false,'bucket',o.bucket,'path',o.path,'object_id',o.id);
end $$;

-- Positive-only evidence; a missing object, request timeout or expired lease cannot release liability.
create function public.worker_pdf_upload_written(p_attempt_id uuid,p_sha256 bytea,p_byte_count integer,
 p_evidence text default 'upload_response',p_read_id uuid default null) returns void
language plpgsql security definer set search_path='' as $$
declare w app_private.pdf_upload_write_attempts; u app_private.pdf_uploads; o app_private.stored_objects;
begin
 select u0.* into u from app_private.pdf_upload_write_attempts w0 join app_private.pdf_uploads u0 on u0.id=w0.upload_id where w0.id=p_attempt_id;
 if not found then raise exception 'upload_unavailable'; end if;
 perform app_private.pdf_upload_lock_account(u.account_id,true);
 select * into strict u from app_private.pdf_uploads where id=u.id for update;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select * into strict w from app_private.pdf_upload_write_attempts where id=p_attempt_id for update;
 select * into strict o from app_private.stored_objects where id=w.object_id for update;
 if p_evidence is null or p_evidence not in ('upload_response','matching_object')
  or (o.sha256,o.byte_count) is distinct from (p_sha256,p_byte_count::bigint) then raise exception 'upload_write_proof_required'; end if;
 if p_evidence='matching_object' and not exists(select 1 from app_private.pdf_upload_reads r
  where r.id=p_read_id and r.attempt_id=w.id and r.purpose='reconciliation' and r.observed_at is not null and r.observed_bytes=o.byte_count)
 then raise exception 'upload_write_proof_required'; end if;
 if w.finished_at is not null then return; end if;
 if o.state not in ('pending','verified','deleting') then raise exception 'upload_unavailable'; end if;
 if o.state='pending' then update app_private.stored_objects set state='verified',verified_at=clock_timestamp() where id=o.id; end if;
 update app_private.pdf_upload_write_attempts set finished_at=clock_timestamp(),evidence=p_evidence where id=w.id;
 if u.state='receiving' and o.state in ('pending','verified') then
  update app_private.pdf_upload_parts set selected_object_id=o.id where upload_id=u.id and part_index=w.part_index and selected_object_id is null;
  update app_private.pdf_uploads set revision=revision+1 where id=u.id;
 end if;
end $$;

-- Freeze only verified selections. This transaction never locks library policy or capacity.
create function public.worker_freeze_pdf_upload(p_account_id uuid,p_upload_id uuid,p_generation bigint,p_revision bigint,p_observed_cursor bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u app_private.pdf_uploads; i app_private.import_requests; selection bytea;
begin
 perform app_private.pdf_upload_lock_account(p_account_id);
 perform public.worker_consume_request(p_account_id,'pdf-upload-finish');
 if not (select enabled from app_private.pdf_upload_policy where singleton) then raise exception 'upload_disabled'; end if;
 if p_generation is null or p_revision is null or p_observed_cursor is null or p_observed_cursor<0 then raise exception 'invalid_upload'; end if;
 select * into u from app_private.pdf_uploads where id=p_upload_id and account_id=p_account_id for update;
 if not found then raise exception 'upload_unavailable'; end if;
 if u.generation<>p_generation then raise exception 'upload_revision_conflict'; end if;
 if u.state in ('frozen','checking','consumed') then return app_private.pdf_upload_session(u); end if;
 if u.state<>'receiving' then raise exception 'upload_not_receiving'; end if;
 if u.revision<>p_revision then raise exception 'upload_revision_conflict'; end if;
 if u.expires_at<=clock_timestamp() then raise exception 'upload_expired'; end if;
 if exists(select 1 from app_private.pdf_upload_parts part left join app_private.stored_objects o on o.id=part.selected_object_id
  where part.upload_id=u.id and (o.id is null or o.state<>'verified' or (o.sha256,o.byte_count) is distinct from (part.sha256,part.byte_count::bigint)))
 then raise exception 'upload_incomplete'; end if;
 if u.target='paper' and not exists(select 1 from app_private.library_descriptors where account_id=p_account_id and source_id=u.source_id)
 then raise exception 'library_descriptor_required'; end if;
 if u.target='import' then
  select * into i from app_private.import_requests where account_id=p_account_id and id=u.import_id;
  if not found or i.source_id<>u.source_id or not i.desired_present or i.intent_revision<>u.expected_revision
   or not(i.phase in ('accepted','resolving','acquiring') or (i.phase='failed' and i.retryable)) then raise exception 'upload_target_unavailable'; end if;
 end if;
 select sha256(convert_to(jsonb_agg(jsonb_build_array(part_index,selected_object_id,encode(sha256,'hex'),byte_count) order by part_index)::text,'UTF8'))
  into selection from app_private.pdf_upload_parts where upload_id=u.id;
 update app_private.pdf_uploads set state='frozen',revision=revision+1,finalized_at=clock_timestamp(),observed_cursor=p_observed_cursor,
  selection_sha256=selection where id=u.id returning * into u;
 return app_private.pdf_upload_session(u);
end $$;

-- Durable attachment is a second transaction: account -> existing library policy/import/paper -> session.
-- It deliberately holds no capacity mutex. Frozen future holds remain fully charged throughout.
create function public.worker_finalize_pdf_upload(p_account_id uuid,p_upload_id uuid,p_generation bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=p_account_id; u app_private.pdf_uploads; i app_private.import_requests; pol app_private.library_policy; s bigint; meta uuid; paper app_private.pipeline_papers;
 digest bytea; result jsonb; bound uuid;
begin
 perform app_private.pdf_upload_lock_account(a);
 perform public.worker_consume_request(a,'pdf-upload-finish');
 select * into u from app_private.pdf_uploads where id=p_upload_id and account_id=a;
 if not found then raise exception 'upload_unavailable'; end if;
 if u.generation is distinct from p_generation then raise exception 'upload_revision_conflict'; end if;
 if u.finalize_result is not null then return app_private.library_command_response(a,u.finalize_result->'result',true); end if;
 if not (select enabled from app_private.pdf_upload_policy where singleton) then raise exception 'upload_disabled'; end if;
 if u.state<>'frozen' then raise exception 'upload_not_frozen'; end if;
 if u.expires_at<=clock_timestamp() then raise exception 'upload_expired'; end if;
 -- Serialize the source choice with admission/publication before library locks.
 -- A claim snapshot alone is not a physical-read grant, so attachment may win
 -- before admission. Once that claim was admitted, keep the frozen upload for
 -- an exact retry after it terminates; never replace its in-flight source.
 select * into paper from app_private.pipeline_papers where owner_id=a and source_id=u.source_id and requested_revision=0 for no key update;
 if found then
  if paper.stage not in ('metadata','private_split','download','failed') or (paper.stage='failed' and paper.resume_stage is distinct from 'download')
   then raise exception 'upload_target_unavailable'; end if;
  if paper.claim_id is not null and (paper.download_admitted_claim_id,paper.download_admitted_generation)=(paper.claim_id,paper.generation)
   then raise exception 'upload_target_busy'; end if;
 end if;
 if u.target='import' then
  select * into i from app_private.import_requests where account_id=a and id=u.import_id;
  if not found or i.source_id<>u.source_id or not i.desired_present or i.intent_revision<>u.expected_revision then raise exception 'upload_target_unavailable'; end if;
  if i.phase='failed' and i.retryable then
   result:=app_private.library_import_command(a,u.id,u.import_id,u.expected_revision,true);
  elsif i.phase in ('accepted','resolving','acquiring') then
   result:=app_private.library_command_response(a,jsonb_build_object('status','attached','kind','import','id',i.id,'revision',i.intent_revision),false);
  else raise exception 'upload_target_unavailable'; end if;
  bound:=u.import_id;
 else
  digest:=sha256(convert_to(jsonb_build_array('pdf-upload-import-v2',u.id,u.source_id,encode(u.selection_sha256,'hex'))::text,'UTF8'));
  perform app_private.lock_library_state(a);
  if u.observed_cursor>(select last_seq from app_private.library_sync_state where account_id=a) then raise exception 'invalid_library_cursor'; end if;
  select * into strict pol from app_private.library_policy;
  perform app_private.library_check_receipt_capacity(a,true);
  if (select count(*) from app_private.import_requests where account_id=a)+1>pol.account_imports then raise exception 'library_account_import_limit'; end if;
  if (select count(*) from app_private.import_requests)+1>pol.environment_imports then raise exception 'library_environment_import_limit'; end if;
  if (select count(*) from app_private.import_requests where account_id=a and desired_present and phase in ('accepted','resolving','acquiring'))+1>pol.account_active_imports
   or (select count(*) from app_private.import_requests where desired_present and phase in ('accepted','resolving','acquiring'))+1>pol.environment_active_imports
  then raise exception 'library_active_import_limit'; end if;
  if u.target='paper' then meta:=app_private.record_upload_metadata(u.id); end if;
  s:=app_private.library_next_seq(a);
  insert into app_private.import_requests(account_id,id,request_sha256,source_id,requested_revision,observed_cursor,created_seq,state_seq,metadata_id,progress)
   values(a,u.id,digest,u.source_id,null,u.observed_cursor,s,s,meta,case when meta is null then 'finding' else 'downloading' end);
  perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,u.id)));
  result:=app_private.library_receipt(a,u.id,digest,jsonb_build_object('status','applied','kind','import','id',u.id,'seq',s,'revision',1));
  bound:=u.id;
 end if;
 -- Same-owner commands/cleanup take account NO KEY UPDATE, so state cannot change beneath attachment.
 -- The source reference appears atomically with the import; no worker can consume the earlier frozen row.
 select * into strict i from app_private.import_requests where account_id=a and id=bound;
 if exists(select 1 from app_private.pdf_uploads old where old.account_id=a and old.source_id=u.source_id
   and old.state='abandoned' and old.bound_import_id=i.id and old.bound_intent_revision>=i.intent_revision)
  then raise exception 'upload_target_unavailable'; end if;
 update app_private.pdf_uploads set state='checking',bound_import_id=i.id,bound_intent_revision=i.intent_revision,
  finalize_result=result,revision=revision+1 where id=u.id and state='frozen';
 if not found then raise exception 'upload_not_frozen'; end if;
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
 return jsonb_build_object('import_id',i.id,'source_id',i.source_id,'title',coalesce(title,'Uploaded PDF'),
  'links',to_jsonb(links[1:5]));
end $$;

-- The exact selected session is pinned and its pre-reserved future holds move
-- to the paper in one transaction, before any assembly GET or original PUT.
alter function public.worker_pipeline_admit_download(uuid,uuid,bigint) rename to pipeline_admit_download_before_039;
alter function public.pipeline_admit_download_before_039(uuid,uuid,bigint) set schema app_private;
create function public.worker_pipeline_admit_download(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; u app_private.pdf_uploads; result jsonb;
begin
 select * into p from app_private.pipeline_papers where id=p_paper_id;
 if p.owner_id is not null then perform app_private.pdf_upload_lock_account(p.owner_id); end if;
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 u:=app_private.pipeline_supplied_upload(p);
 if u.id is null then
  result:=app_private.pipeline_admit_download_before_039(p_paper_id,p_claim_id,p_generation);
  if coalesce((result->>'admitted')::boolean,false) then
   update app_private.pipeline_papers set download_admitted_claim_id=p_claim_id,download_admitted_generation=p_generation where id=p.id;
  end if;
  return result||jsonb_build_object('upload',null);
 end if;
 select * into strict u from app_private.pdf_uploads where id=u.id for update;
 if u.state<>'checking' or (u.paper_id is not null and u.paper_id<>p.id) then raise exception 'upload_unavailable'; end if;
 if not exists(select 1 from app_private.import_requests where account_id=u.account_id and id=u.bound_import_id
  and desired_present and intent_revision=u.bound_intent_revision) then raise exception 'upload_target_unavailable'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 insert into app_private.paper_asset_holds(paper_id,kind,owner_id,bytes,objects)
  select p.id,h.kind,h.owner_id,h.bytes,h.objects from app_private.pdf_upload_holds h
   where h.upload_id=u.id and h.kind<>'staging' on conflict do nothing;
 delete from app_private.pdf_upload_holds where upload_id=u.id and kind<>'staging';
 update app_private.pipeline_papers set upload_id=u.id,upload_generation=u.generation where id=p.id;
 update app_private.pdf_uploads set paper_id=p.id where id=u.id;
 result:=app_private.pipeline_admit_download_before_039(p_paper_id,p_claim_id,p_generation);
 if coalesce((result->>'admitted')::boolean,false) then
  update app_private.pipeline_papers set download_admitted_claim_id=p_claim_id,download_admitted_generation=p_generation where id=p.id;
 end if;
 return result||jsonb_build_object('upload',jsonb_build_object('id',u.id,'generation',u.generation,'sha256',encode(u.sha256,'hex'),'bytes',u.byte_count,'parts',u.part_count));
end $$;

-- Backend transfer accounting retains ceilings for all admitted GETs, including
-- lost responses. Late observations of closed accounts update only environment totals.
create function app_private.pdf_upload_transfer(a uuid,p_period date,p_authorized bigint,p_observed bigint) returns void
language plpgsql security definer set search_path='' as $$
declare pol app_private.reader_delivery_policy; scope text; row app_private.reader_transfer_months; scopes text[]:=array['environment']; maximum bigint;
begin
 select * into strict pol from app_private.reader_delivery_policy where singleton for update;
 if exists(select 1 from app_private.accounts where id=a and closed_at is null) then scopes:=scopes||a::text; end if;
 foreach scope in array scopes loop
  maximum:=case when scope='environment' then pol.backend_environment_bytes_month else pol.backend_account_bytes_month end;
  insert into app_private.reader_transfer_months(period,scope_id,kind) values(p_period,scope,'backend') on conflict do nothing;
  update app_private.reader_transfer_months set authorized_bytes=authorized_bytes+p_authorized,upstream_bytes=upstream_bytes+p_observed
   where (period,scope_id,kind)=(p_period,scope,'backend') returning * into row;
  if p_authorized>0 and row.authorized_bytes+row.reserved_bytes>maximum then raise exception 'reader_transfer_limit'; end if;
 end loop;
end $$;

create function public.worker_pdf_upload_read(p_read_id uuid,p_upload_id uuid,p_upload_generation bigint,
 p_paper_id uuid default null,p_claim_id uuid default null,p_generation bigint default null,p_attempt_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u app_private.pdf_uploads; p app_private.pipeline_papers; o app_private.stored_objects; w app_private.pdf_upload_write_attempts;
 prior app_private.pdf_upload_reads; total bigint; period date:=date_trunc('month',clock_timestamp() at time zone 'UTC')::date; objects jsonb;
begin
 select * into u from app_private.pdf_uploads where id=p_upload_id;
 if not found or p_read_id is null then raise exception 'upload_unavailable'; end if;
 -- Reconciliation can remove uncertainty after closure; it never revives selection/ownership.
 perform app_private.pdf_upload_lock_account(u.account_id,p_attempt_id is not null);
 if p_attempt_id is null then
  p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
  if p.stage<>'download' or (p.upload_id,p.upload_generation,p.owner_id) is distinct from (u.id,p_upload_generation,u.account_id)
   or not exists(select 1 from app_private.paper_asset_holds where paper_id=p.id and kind='original') then raise exception 'upload_not_admitted'; end if;
 end if;
 select * into strict u from app_private.pdf_uploads where id=u.id for update;
 if u.generation is distinct from p_upload_generation then raise exception 'upload_revision_conflict'; end if;
 select * into prior from app_private.pdf_upload_reads where id=p_read_id;
 if found then
  if (prior.upload_id,prior.attempt_id) is distinct from (u.id,p_attempt_id) then raise exception 'upload_id_conflict'; end if;
  return jsonb_build_object('read',false); -- never reauthorize a physical GET
 end if;
 if (select count(*) from app_private.pdf_upload_reads where upload_id=u.id)>=(select session_reads from app_private.pdf_upload_policy where singleton)
 then raise exception 'upload_read_capacity'; end if;
 if p_attempt_id is null then
  if u.state<>'checking' or u.paper_id<>p.id then raise exception 'upload_unavailable'; end if;
  if not exists(select 1 from app_private.import_requests where account_id=u.account_id and id=u.bound_import_id and desired_present and intent_revision=u.bound_intent_revision)
   then raise exception 'upload_target_unavailable'; end if;
  select sum(part.byte_count),jsonb_agg(jsonb_build_object('index',part.part_index,'id',obj.id,'bucket',obj.bucket,'path',obj.path,
   'bytes',obj.byte_count,'sha256',encode(obj.sha256,'hex')) order by part.part_index) into total,objects
   from app_private.pdf_upload_parts part join app_private.stored_objects obj on obj.id=part.selected_object_id
   where part.upload_id=u.id and obj.state='verified';
  if total is distinct from u.byte_count or jsonb_array_length(objects) is distinct from u.part_count then raise exception 'upload_incomplete'; end if;
 else
  select * into w from app_private.pdf_upload_write_attempts where id=p_attempt_id and upload_id=u.id;
  if not found then raise exception 'upload_unavailable'; end if;
  if w.finished_at is not null then return jsonb_build_object('read',false); end if;
  if exists(select 1 from app_private.pdf_upload_reads where attempt_id=w.id and created_at>clock_timestamp()-interval '15 minutes')
   then return jsonb_build_object('read',false); end if;
  select * into strict o from app_private.stored_objects where id=w.object_id;
  total:=o.byte_count;
  objects:=jsonb_build_array(jsonb_build_object('index',w.part_index,'id',o.id,'bucket',o.bucket,'path',o.path,'bytes',o.byte_count,'sha256',encode(o.sha256,'hex')));
 end if;
 perform app_private.pdf_upload_transfer(u.account_id,period,total,0);
 insert into app_private.pdf_upload_reads(id,upload_id,purpose,attempt_id,period,bytes)
  values(p_read_id,u.id,case when p_attempt_id is null then 'assembly' else 'reconciliation' end,p_attempt_id,period,total);
 return jsonb_build_object('read',true,'read_id',p_read_id,'objects',objects,'bytes',total);
end $$;

-- Bounded, paced recovery candidates. Authority/actual GET cost is granted by
-- worker_pdf_upload_read, not this diagnostic discovery query.
create function public.worker_pdf_upload_reconciliation(p_limit integer default 3) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 10 then raise exception 'invalid_limit'; end if;
 -- Claim only a bounded diagnostic window and pace it even if the later GET
 -- admission fails (for example one owner's exhausted transfer allowance).
 -- This transaction takes attempt rows only, never later account/session locks.
 with candidates as materialized (
  select w.id from app_private.pdf_upload_write_attempts w
   join app_private.pdf_uploads u on u.id=w.upload_id
   where w.finished_at is null and w.started_at<clock_timestamp()-interval '2 minutes'
    and w.reconciliation_after<=clock_timestamp()
    and (select count(*) from app_private.pdf_upload_reads where upload_id=u.id)<(select session_reads from app_private.pdf_upload_policy where singleton)
    and not exists(select 1 from app_private.pdf_upload_reads r where r.attempt_id=w.id and r.created_at>clock_timestamp()-interval '15 minutes')
   order by w.reconciliation_after,w.started_at,w.id limit p_limit for update of w skip locked
 ), claimed as (
  update app_private.pdf_upload_write_attempts w set reconciliation_after=clock_timestamp()+interval '15 minutes'
   from candidates c where w.id=c.id returning w.id,w.upload_id
 ) select coalesce(jsonb_agg(jsonb_build_object('attempt_id',c.id,'upload_id',u.id,'generation',u.generation)),'[]') into result
  from claimed c join app_private.pdf_uploads u on u.id=c.upload_id;
 return result;
end $$;

create function public.worker_pdf_upload_read_observed(p_read_id uuid,p_bytes bigint) returns void
language plpgsql security definer set search_path='' as $$
declare r app_private.pdf_upload_reads; a uuid;
begin
 select u.account_id into a from app_private.pdf_upload_reads r0 join app_private.pdf_uploads u on u.id=r0.upload_id where r0.id=p_read_id;
 if not found then raise exception 'upload_unavailable'; end if;
 perform app_private.pdf_upload_lock_account(a,true);
 select * into strict r from app_private.pdf_upload_reads where id=p_read_id for update;
 if p_bytes is null or p_bytes<0 or p_bytes>r.bytes then raise exception 'invalid_upload_observation'; end if;
 if r.observed_at is not null then
  if r.observed_bytes<>p_bytes then raise exception 'upload_observation_conflict'; end if;
  return;
 end if;
 perform app_private.pdf_upload_transfer(a,r.period,0,p_bytes);
 update app_private.pdf_upload_reads set observed_bytes=p_bytes,observed_at=clock_timestamp() where id=r.id;
end $$;

-- The original publication callback locks owner -> paper -> session before
-- invoking035's capacity/document publication. No session-first paper lookup.
create function public.worker_pipeline_upload_original(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_upload_id uuid,
 p_sha256 bytea,p_bytes bigint,p_pages integer,p_path text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; u app_private.pdf_uploads; result jsonb;
begin
 select * into p from app_private.pipeline_papers where id=p_paper_id;
 perform app_private.pdf_upload_lock_account(p.owner_id);
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'download' or p.owner_id is null or p.upload_id is distinct from p_upload_id then raise exception 'invalid_pipeline_stage'; end if;
 select * into u from app_private.pdf_uploads where id=p_upload_id and account_id=p.owner_id for update;
 if not found or u.state<>'checking' or (u.paper_id,u.generation,u.source_id) is distinct from (p.id,p.upload_generation,p.source_id) then raise exception 'upload_unavailable'; end if;
 if (u.sha256,u.byte_count) is distinct from (p_sha256,p_bytes) then raise exception 'upload_mismatch'; end if;
 result:=public.worker_pipeline_original(p_paper_id,p_claim_id,p_generation,p_sha256,p_bytes,p_pages,p_path);
 update app_private.pdf_uploads set state='consumed',consumed_at=clock_timestamp(),revision=revision+1 where id=u.id;
 return result;
end $$;

create function public.worker_pipeline_upload_rejected(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_upload_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; u app_private.pdf_uploads;
begin
 select * into p from app_private.pipeline_papers where id=p_paper_id;
 perform app_private.pdf_upload_lock_account(p.owner_id);
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'download' or p.upload_id is distinct from p_upload_id then raise exception 'invalid_pipeline_stage'; end if;
 select * into strict u from app_private.pdf_uploads where id=p_upload_id for update;
 update app_private.pdf_uploads set state='abandoned',revision=revision+1 where id=p_upload_id and paper_id=p.id and generation=p.upload_generation and state='checking';
 if not found then raise exception 'upload_unavailable'; end if;
 -- The rejected selection can never become this paper's source again. Retain
 -- its session/objects/unknown writes; only the selection pin is cleared.
 update app_private.pipeline_papers set upload_id=null,upload_generation=null where id=p.id;
end $$;

-- Bounded candidate snapshot. Acquire owner and any already-known paper before
-- session/capacity; recheck the entire terminal predicate after the waits.
create function public.worker_claim_stale_pdf_uploads(p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path='' as $$
declare candidate record; u app_private.pdf_uploads; pol app_private.pdf_upload_policy; batch uuid; result jsonb:='[]'; objects jsonb; captured jsonb;
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'invalid_limit'; end if;
 select * into strict pol from app_private.pdf_upload_policy;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into captured from (select pending.id,pending.account_id,pending.paper_id from app_private.pdf_uploads pending
  where (pending.state in ('consumed','abandoned') or (pending.state in ('receiving','frozen') and pending.expires_at<=clock_timestamp())
   or (pending.state='checking' and pending.finalized_at<clock_timestamp()-make_interval(days=>pol.unused_days)
    and not exists(select 1 from app_private.pipeline_papers p where p.id=pending.paper_id and p.claim_id is not null)
    and not exists(select 1 from app_private.import_requests i where i.account_id=pending.account_id and i.id=pending.bound_import_id
     and i.desired_present and i.intent_revision=pending.bound_intent_revision)))
   -- One retirement pass may release unused future ceilings despite an unknown
   -- PUT. Thereafter unresolved writes/no-op receipts cannot monopolize LIMIT.
   and (pending.state not in ('consumed','abandoned') or exists(select 1 from app_private.pdf_upload_holds h where h.upload_id=pending.id)
    or (not exists(select 1 from app_private.pdf_upload_write_attempts w where w.upload_id=pending.id and w.finished_at is null)
     and exists(select 1 from app_private.pdf_upload_write_attempts w join app_private.stored_objects o on o.id=w.object_id where w.upload_id=pending.id and o.state<>'deleted')
     and not exists(select 1 from app_private.pdf_upload_delete_batches b where b.upload_id=pending.id and b.completed_at is null and b.next_attempt_at>clock_timestamp())))
  order by pending.id limit p_limit) x;
 perform 1 from app_private.accounts where id in(select (x->>'account_id')::uuid from jsonb_array_elements(captured) x) order by id for no key update;
 perform 1 from app_private.pipeline_papers where id in(select (x->>'paper_id')::uuid from jsonb_array_elements(captured) x) order by id for no key update;
 for candidate in select (x->>'id')::uuid id,(x->>'account_id')::uuid account_id,(x->>'paper_id')::uuid paper_id from jsonb_array_elements(captured) x loop
  perform app_private.pdf_upload_lock_account(candidate.account_id,true);
  if candidate.paper_id is not null then perform 1 from app_private.pipeline_papers where id=candidate.paper_id for no key update; end if;
  select * into strict u from app_private.pdf_uploads where id=candidate.id for update;
  if u.paper_id is distinct from candidate.paper_id then continue; end if;
  if u.state='checking' and (exists(select 1 from app_private.pipeline_papers where id=u.paper_id and claim_id is not null)
   or exists(select 1 from app_private.import_requests where account_id=u.account_id and id=u.bound_import_id and desired_present and intent_revision=u.bound_intent_revision)) then continue; end if;
  if u.state in ('receiving','frozen') and u.expires_at>clock_timestamp() then continue; end if;
  perform 1 from app_private.paper_storage_capacity where singleton for update;
  if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then continue; end if;
  if u.state not in ('consumed','abandoned') then
   update app_private.pdf_uploads set state='abandoned',revision=revision+1 where id=u.id;
   update app_private.pipeline_papers set upload_id=null,upload_generation=null
    where id=u.paper_id and upload_id=u.id and upload_generation=u.generation;
  end if;
  -- Future-unused ceilings can go away. Every issued physical write remains inventoried.
  delete from app_private.pdf_upload_holds where upload_id=u.id;
  if exists(select 1 from app_private.pdf_upload_write_attempts where upload_id=u.id and finished_at is null) then continue; end if;
  select id into batch from app_private.pdf_upload_delete_batches where upload_id=u.id and completed_at is null;
  if batch is not null and exists(select 1 from app_private.pdf_upload_delete_batches where id=batch and next_attempt_at>clock_timestamp()) then continue; end if;
  if batch is null then
   if not exists(select 1 from app_private.pdf_upload_write_attempts w join app_private.stored_objects o on o.id=w.object_id where w.upload_id=u.id and o.state<>'deleted') then continue; end if;
   insert into app_private.pdf_upload_delete_batches(upload_id) values(u.id) returning id into batch;
   insert into app_private.pdf_upload_delete_members(batch_id,object_id)
    select batch,o.id from app_private.pdf_upload_write_attempts w join app_private.stored_objects o on o.id=w.object_id
     where w.upload_id=u.id and o.state<>'deleted';
   update app_private.stored_objects set state='deleting' where id in(select object_id from app_private.pdf_upload_delete_members where batch_id=batch);
  end if;
  -- Issue is not deletion proof. Pace even a lost/failed Storage removal while
  -- retaining exact membership and every physical byte until confirmation.
  update app_private.pdf_upload_delete_batches set next_attempt_at=clock_timestamp()+interval '15 minutes' where id=batch;
  select jsonb_agg(jsonb_build_object('id',o.id,'bucket',o.bucket,'path',o.path) order by o.id) into objects
   from app_private.pdf_upload_delete_members m join app_private.stored_objects o on o.id=m.object_id where m.batch_id=batch;
  result:=result||jsonb_build_array(jsonb_build_object('batch_id',batch,'objects',objects));
 end loop;
 return result;
end $$;

create function public.worker_confirm_pdf_uploads_deleted(p_batch_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare u app_private.pdf_uploads; batch app_private.pdf_upload_delete_batches; n integer;
begin
 select u0.* into u from app_private.pdf_upload_delete_batches b join app_private.pdf_uploads u0 on u0.id=b.upload_id where b.id=p_batch_id;
 if not found then raise exception 'upload_unavailable'; end if;
 perform app_private.pdf_upload_lock_account(u.account_id,true);
 select * into strict u from app_private.pdf_uploads where id=u.id for update;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 select * into strict batch from app_private.pdf_upload_delete_batches where id=p_batch_id for update;
 if batch.completed_at is not null then return 0; end if;
 if u.state not in ('consumed','abandoned') or exists(select 1 from app_private.pdf_upload_write_attempts where upload_id=u.id and finished_at is null)
 then raise exception 'asset_write_uncertain'; end if;
 update app_private.stored_objects set state='deleted' where id in(select object_id from app_private.pdf_upload_delete_members where batch_id=batch.id) and state='deleting';
 get diagnostics n=row_count;
 update app_private.pdf_upload_delete_batches set completed_at=clock_timestamp() where id=batch.id;
 return n;
end $$;

create function public.worker_cancel_pdf_upload(p_account_id uuid,p_upload_id uuid,p_generation bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u app_private.pdf_uploads;
begin
 perform app_private.pdf_upload_lock_account(p_account_id,true);
 perform public.worker_consume_request(p_account_id,'pdf-upload-finish');
 select * into u from app_private.pdf_uploads where id=p_upload_id and account_id=p_account_id for update;
 if not found then raise exception 'upload_unavailable'; end if;
 if u.generation is distinct from p_generation then raise exception 'upload_revision_conflict'; end if;
 if u.state='abandoned' then return app_private.pdf_upload_session(u); end if;
 if u.state not in ('receiving','frozen') then raise exception 'upload_already_attached'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 update app_private.pdf_uploads set state='abandoned',revision=revision+1 where id=u.id returning * into u;
 delete from app_private.pdf_upload_holds where upload_id=u.id;
 return app_private.pdf_upload_session(u);
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
  'title',(select cm.metadata->>'title' from app_private.catalog_metadata cm where cm.id=p.metadata_id),
  'authors',(select cm.metadata->'authors' from app_private.catalog_metadata cm where cm.id=p.metadata_id),
  'due',p.stage in ('metadata','private_split','download','ocr_fund','ocr_submit','ocr_wait','render') and p.next_attempt_at<=clock_timestamp(),
  'document_sha256',(select encode(d.sha256,'hex') from app_private.documents d where d.id=p.document_id),
  'original_path',(select o.path from app_private.stored_objects o where o.id=p.original_object_id),
  'original_bytes',(select o.byte_count from app_private.stored_objects o where o.id=p.original_object_id),
  'raw_manifest_path',app_private.pipeline_raw_path(p.ocr_run_id),
  'upload',(select jsonb_build_object('id',u.id,'generation',u.generation,'sha256',encode(u.sha256,'hex'),'bytes',u.byte_count,'parts',u.part_count)
   from app_private.pipeline_supplied_upload(p) u where u.id is not null),
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
  'metadata',cm.metadata,
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
  'metadata',cm.metadata,
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

-- 019's baseline and delta by read level: 2 (arXiv), 3 (+ web), 4 (+ uploads; served as v5 because v4
-- is the compact format of migration 031). The 019 functions keep their signatures and never return uploads.
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
create function public.v5_library_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin perform public.worker_consume_request(a,'library-read'); result:=app_private.library_baseline_at(a,p_cursor,p_limit,4);
 perform app_private.consume_library_transfer(a,result); return result; end $$;
create function public.v5_library_changes(p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb language plpgsql security definer set search_path='' as $$
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

-- 031's metadata hydration, plus uploaded papers: source `upload` and the owner's own metadata.
create or replace function app_private.library_v4_metadata(a uuid,p_dataset_epoch uuid,p_metadata_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare epoch uuid; result jsonb;
begin
 select dataset_epoch into strict epoch from app_private.library_v4_config where singleton;
 if p_dataset_epoch is distinct from epoch then raise exception 'library_resync_required'; end if;
 if p_metadata_ids is null or coalesce(array_ndims(p_metadata_ids),1)<>1 or cardinality(p_metadata_ids)>24
  or exists(select 1 from unnest(p_metadata_ids) id where id is null)
  or (select count(distinct id) from unnest(p_metadata_ids) id)<>cardinality(p_metadata_ids)
 then raise exception 'invalid_library_metadata_request'; end if;
 if exists(select 1 from unnest(p_metadata_ids) requested(id)
  where not exists(select 1 from app_private.library_v4_entries e where e.account_id=a and e.metadata_id=requested.id)
   or not exists(select 1 from app_private.catalog_metadata m where m.id=requested.id))
 then raise exception 'library_metadata_unavailable' using errcode='42501'; end if;
 select jsonb_build_object('format',4,'dataset_epoch',epoch,'account_id',a,'records',coalesce(jsonb_agg(
  jsonb_build_object('metadata_id',m.id,'version_id',m.version_id,
   'source',case when m.source_id like 'openalex:%' then 'web' when m.source_id like 'upload:%' then 'upload' else 'arxiv' end,
   'source_id',m.source_id,'source_revision',m.source_revision,
   'metadata',m.metadata,
   'recorded_at',m.recorded_at)
  order by requested.ordinality),'[]'::jsonb)) into result
 from unnest(p_metadata_ids) with ordinality requested(id,ordinality) join app_private.catalog_metadata m on m.id=requested.id;
 return result;
end $$;

-- 032's query filters, plus `source: upload` (a reader's own PDFs).
create or replace function app_private.library_query_spec(p jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare q text; terms text[]; s text; d text; a text; src text; tag text;
begin
 if p is null or jsonb_typeof(p)<>'object' or octet_length(p::text)>4096
  or (p-'text'-'sort'-'direction'-'archive'-'source'-'tag')<>'{}'::jsonb
  or exists(select 1 from jsonb_each(p) where jsonb_typeof(value)<>'string') then raise exception 'invalid_library_query'; end if;
 q:=coalesce(p->>'text','');
 if octet_length(q)>512 then raise exception 'invalid_library_query'; end if;
 select coalesce(array_agg(t order by t collate "C"),'{}') into terms from (
  select distinct t from regexp_split_to_table(app_private.library_search_normalize(q) collate pg_catalog.pg_c_utf8,'[[:space:]]+') t where t<>''
 ) x;
 if cardinality(terms)>16 then raise exception 'invalid_library_query'; end if;
 s:=coalesce(p->>'sort','recent'); d:=coalesce(p->>'direction',case when s='title' then 'asc' else 'desc' end);
 a:=coalesce(p->>'archive','active'); src:=coalesce(p->>'source','all');
 if s not in ('recent','title','year') or d not in ('asc','desc') or a not in ('active','archived','all') or src not in ('all','arxiv','web','upload')
 then raise exception 'invalid_library_query'; end if;
 if p ? 'tag' then
  if octet_length(p->>'tag') not between 1 and 120 then raise exception 'invalid_library_query'; end if;
  tag:=lower((p->>'tag') collate pg_catalog.pg_c_utf8);
 end if;
 return jsonb_build_object('terms',to_jsonb(terms),'sort',s,'direction',d,'archive',a,'source',src,'tag',tag);
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

-- Preserve035's reader/grant cleanup and uncertain-write fence. Account deletion
-- takes account FOR UPDATE -> all private papers -> sessions -> capacity, then
-- the older deletion implementation; terminal write callbacks may still settle.
alter function public.worker_delete_account_begin(uuid) rename to delete_account_begin_before_039;
alter function public.delete_account_begin_before_039(uuid) set schema app_private;
create function public.worker_delete_account_begin(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform 1 from app_private.accounts where id=p_account_id for update;
 if not found then raise exception 'account_unavailable'; end if;
 perform 1 from app_private.pipeline_papers where owner_id=p_account_id order by id for no key update;
 perform 1 from app_private.pdf_uploads where account_id=p_account_id order by id for update;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 perform 1 from app_private.keyrings where account_id=p_account_id for update;
 perform set_config('app_private.deleting_account',p_account_id::text,true);
 update app_private.sync_environment_storage set descriptor_bytes=descriptor_bytes-(select coalesce(sum(octet_length(ciphertext)),0) from app_private.library_descriptors where account_id=p_account_id),
  descriptor_count=descriptor_count-(select count(*) from app_private.library_descriptors where account_id=p_account_id) where singleton;
 delete from app_private.library_descriptors where account_id=p_account_id;
 result:=app_private.delete_account_begin_before_039(p_account_id);
 update app_private.pdf_uploads set state='abandoned',revision=revision+1 where account_id=p_account_id and state not in ('consumed','abandoned');
 delete from app_private.pdf_upload_holds where owner_id=p_account_id;
 if result ? 'blocked' or exists(select 1 from app_private.pdf_upload_write_attempts w join app_private.pdf_uploads u on u.id=w.upload_id
  where u.account_id=p_account_id and w.finished_at is null) then
  return jsonb_build_object('account_id',p_account_id,'blocked','asset_write_uncertain','objects','[]'::jsonb,'prefixes','[]'::jsonb);
 end if;
 return jsonb_set(result,'{prefixes}',coalesce(result->'prefixes','[]')||jsonb_build_array(jsonb_build_object('bucket','paper-uploads','prefix',p_account_id::text||'/')));
end $$;

alter function public.worker_delete_account_finish(uuid) rename to delete_account_finish_before_039;
alter function public.delete_account_finish_before_039(uuid) set schema app_private;
create function public.worker_delete_account_finish(p_account_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare result integer;
begin
 perform 1 from app_private.accounts where id=p_account_id and closed_at is not null for update;
 if not found then raise exception 'account_not_closed'; end if;
 perform 1 from app_private.pipeline_papers where owner_id=p_account_id order by id for no key update;
 perform 1 from app_private.pdf_uploads where account_id=p_account_id order by id for update;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 if exists(select 1 from app_private.pdf_upload_write_attempts w join app_private.pdf_uploads u on u.id=w.upload_id
  where u.account_id=p_account_id and w.finished_at is null) then raise exception 'asset_write_uncertain'; end if;
 result:=app_private.delete_account_finish_before_039(p_account_id);
 delete from app_private.pdf_upload_delete_members where batch_id in(select b.id from app_private.pdf_upload_delete_batches b join app_private.pdf_uploads u on u.id=b.upload_id where u.account_id=p_account_id);
 delete from app_private.pdf_upload_delete_batches where upload_id in(select id from app_private.pdf_uploads where account_id=p_account_id);
 delete from app_private.pdf_upload_reads where upload_id in(select id from app_private.pdf_uploads where account_id=p_account_id);
 delete from app_private.pdf_upload_write_attempts where upload_id in(select id from app_private.pdf_uploads where account_id=p_account_id);
 delete from app_private.pdf_upload_parts where upload_id in(select id from app_private.pdf_uploads where account_id=p_account_id);
 delete from app_private.pdf_upload_holds where owner_id=p_account_id;
 delete from app_private.pdf_uploads where account_id=p_account_id;
 return result;
end $$;

alter table app_private.paper_asset_policy add column inventory_scope integer not null default 1 check(inventory_scope in (1,2));
alter table app_private.paper_asset_inventory_scans add column scope integer not null default 1 check(scope in (1,2));
-- New scans explicitly cover both buckets. Old one-bucket evidence cannot enable ingress.
alter function public.worker_asset_inventory_begin(uuid) rename to asset_inventory_begin_before_039;
alter function public.asset_inventory_begin_before_039(uuid) set schema app_private;
create function public.worker_asset_inventory_begin(p_scan_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select enabled from app_private.pdf_upload_policy where singleton)
  or exists(select 1 from app_private.pdf_upload_write_attempts where finished_at is null) then raise exception 'asset_workers_not_drained'; end if;
 result:=app_private.asset_inventory_begin_before_039(p_scan_id);
 update app_private.paper_asset_inventory_scans set scope=2 where id=p_scan_id and finished_at is null;
 return result||jsonb_build_object('scope',2,'buckets',jsonb_build_array('paper-assets','paper-uploads'));
end $$;
create or replace function public.worker_asset_inventory_page(p_scan_id uuid,p_after uuid default null,p_limit integer default 500) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if p_scan_id is null or p_limit is null or p_limit not between 1 and 500 or not exists(select 1 from app_private.paper_asset_policy where reconciliation_id=p_scan_id)
 then raise exception 'invalid_inventory_scan'; end if;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.id),'[]') into rows from
  (select o.id,o.bucket,o.path,o.document_id,encode(d.sha256,'hex') document_sha256,d.scope,coalesce(d.owner_id,o.owner_id) owner_id,
   o.state,encode(o.sha256,'hex') sha256,o.byte_count bytes,o.media_type
   from app_private.stored_objects o left join app_private.documents d on d.id=o.document_id
   where o.bucket in ('paper-assets','paper-uploads') and o.state<>'deleted' and (p_after is null or o.id>p_after) order by o.id limit p_limit) r;
 return jsonb_build_object('objects',rows,'next_after',case when jsonb_array_length(rows)>0 then rows->-1->>'id' else null end,'has_more',jsonb_array_length(rows)=p_limit);
end $$;
alter function public.worker_asset_inventory_finish(uuid,bigint,bigint,jsonb,bytea) rename to asset_inventory_finish_before_039;
alter function public.asset_inventory_finish_before_039(uuid,bigint,bigint,jsonb,bytea) set schema app_private;
create function public.worker_asset_inventory_finish(p_scan_id uuid,p_object_count bigint,p_byte_count bigint,p_discrepancies jsonb,p_report_sha256 bytea) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select enabled from app_private.pdf_upload_policy where singleton)
  or exists(select 1 from app_private.pdf_upload_write_attempts where finished_at is null) then raise exception 'asset_workers_not_drained'; end if;
 if not exists(select 1 from app_private.paper_asset_inventory_scans where id=p_scan_id and scope=2) then raise exception 'invalid_inventory_scan'; end if;
 result:=app_private.asset_inventory_finish_before_039(p_scan_id,p_object_count,p_byte_count,p_discrepancies,p_report_sha256);
 if (result->>'complete')::boolean then update app_private.paper_asset_policy set inventory_scope=2 where singleton; end if;
 return result||jsonb_build_object('scope',2);
end $$;
alter function public.worker_asset_spending_status() rename to asset_spending_status_before_039;
alter function public.asset_spending_status_before_039() set schema app_private;
create function public.worker_asset_spending_status() returns jsonb
language sql stable security definer set search_path='' as $$
 select app_private.asset_spending_status_before_039()||jsonb_build_object(
  'objects',coalesce((select jsonb_agg(r) from (select bucket,state,count(*) objects,sum(byte_count) bytes from app_private.stored_objects
   where bucket in ('paper-assets','paper-uploads') group by bucket,state) r),'[]'),
  'reservations',coalesce((select jsonb_agg(r) from (select 'paper' scope,kind,count(*) holds,sum(bytes) bytes,sum(objects) objects from app_private.paper_asset_holds group by kind
   union all select 'upload' scope,kind,count(*) holds,sum(bytes) bytes,sum(objects) objects from app_private.pdf_upload_holds group by kind) r),'[]'),
  'uploads',jsonb_build_object('policy',(select to_jsonb(p) from app_private.pdf_upload_policy p where singleton),
   'sessions',coalesce((select jsonb_agg(r) from (select state,count(*) sessions,min(created_at) oldest from app_private.pdf_uploads group by state) r),'[]'),
   'unresolved_writes',(select jsonb_build_object('count',count(*),'bytes',coalesce(sum(o.byte_count),0),'oldest',min(w.started_at))
    from app_private.pdf_upload_write_attempts w join app_private.stored_objects o on o.id=w.object_id where w.finished_at is null),
   'reads',(select jsonb_build_object('count',count(*),'unobserved',count(*) filter(where observed_at is null),'authorized_bytes',coalesce(sum(bytes),0),
    'observed_bytes',coalesce(sum(observed_bytes),0)) from app_private.pdf_upload_reads)))
$$;

create function public.worker_pdf_upload_policy(p_enabled boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if p_enabled is null then raise exception 'invalid_upload_policy'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if p_enabled then
  if not exists(select 1 from app_private.paper_asset_policy where enforced and inventory_scope=2 and inventory_verified_at is not null
   and inventory_discrepancies=0 and reconciliation_id is null) then raise exception 'asset_inventory_incomplete'; end if;
  perform app_private.paper_asset_check_capacity(null);
  perform app_private.paper_asset_check_capacity(owner_id) from (
   select owner_id from app_private.documents where owner_id is not null union select account_id from app_private.pdf_uploads) owners;
 end if;
 update app_private.pdf_upload_policy set enabled=p_enabled where singleton;
 return (select to_jsonb(p) from app_private.pdf_upload_policy p where singleton);
end $$;

-- Compose the existing first history append with account closure safely. The
-- original receipt/epoch implementation is unchanged behind this owner fence.
alter function public.v1_append_event(uuid,uuid,integer,integer,bytea,bytea) rename to append_event_before_039;
alter function public.append_event_before_039(uuid,uuid,integer,integer,bytea,bytea) set schema app_private;
create function public.v1_append_event(p_device_id uuid,p_id uuid,p_epoch integer,p_format integer,p_ciphertext bytea,p_management_token bytea) returns bigint
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor();
begin
 perform 1 from app_private.accounts where id=a and closed_at is null for key share;
 if not found then raise exception 'account_unavailable'; end if;
 return app_private.append_event_before_039(p_device_id,p_id,p_epoch,p_format,p_ciphertext,p_management_token);
end $$;

-- Mutable private titles are opaque, account-owned envelopes. Public metadata
-- UUIDs remain immutable. Author device IDs are historical, not revocation FKs.
create table app_private.library_descriptors (
 account_id uuid not null references app_private.accounts(id),
 source_id text not null check(octet_length(source_id) between 1 and 128 and source_id ~ '^[!-~]+$'),
 id uuid not null, revision integer not null check(revision>0), mutation_id uuid not null,
 device_id uuid not null, epoch integer not null check(epoch>0), format integer not null check(format=1),
 ciphertext bytea not null check(octet_length(ciphertext) between 28 and 4124),
 sha256 bytea not null check(octet_length(sha256)=32 and sha256=sha256(ciphertext)),
 updated_at timestamptz not null default clock_timestamp(),
 primary key(account_id,id), unique(account_id,source_id)
);
alter table app_private.library_descriptors enable row level security;
revoke all on app_private.library_descriptors from public,anon,authenticated,service_role;
alter table app_private.sync_environment_storage add column descriptor_bytes bigint not null default 0 check(descriptor_bytes>=0),
 add column descriptor_count bigint not null default 0 check(descriptor_count>=0);
alter table app_private.sync_account_storage add column descriptor_bytes bigint not null default 0 check(descriptor_bytes>=0),
 add column descriptor_count bigint not null default 0 check(descriptor_count>=0);

-- Keep the old event-only fields meaningful while exposing the actual shared
-- byte allowance. New client usage displays must use accounted_storage_bytes.
create or replace function public.v1_sync_usage() returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform 1 from app_private.accounts where id=a and closed_at is null for key share;
 if not found then raise exception 'account_unavailable'; end if;
 perform public.worker_consume_request(a,'sync-read');
 select jsonb_build_object('ciphertext_bytes',coalesce(s.ciphertext_bytes,0),'events',coalesce(s.event_count,0),
  'descriptor_bytes',coalesce(s.descriptor_bytes,0),'descriptor_count',coalesce(s.descriptor_count,0),
  'accounted_storage_bytes',coalesce(s.ciphertext_bytes,0)+coalesce(s.descriptor_bytes,0),
  'storage_limit_bytes',p.account_bytes,'event_limit',p.account_events,
  'transfer_bytes',coalesce(t.reserved_bytes,0),'transfer_limit_bytes',q.account_bytes,
  'transfer_period',date_trunc('month',now() at time zone 'UTC')::date)
 into result from app_private.sync_storage_policy p cross join app_private.sync_transfer_policy q
 left join app_private.sync_account_storage s on s.account_id=a
 left join app_private.sync_transfer_months t on t.scope_id=a::text and t.period=date_trunc('month',now() at time zone 'UTC')::date;
 return result;
end $$;
alter function public.v1_admin_overview() rename to admin_overview_before_039;
alter function public.admin_overview_before_039() set schema app_private;
create function public.v1_admin_overview() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 result:=app_private.admin_overview_before_039(); -- Preserve existing MFA/owner authorization.
 return jsonb_set(result,'{sync_storage}',coalesce(result->'sync_storage','{}')||
  (select jsonb_build_object('descriptor_bytes',descriptor_bytes,'descriptor_count',descriptor_count,
   'accounted_storage_bytes',ciphertext_bytes+descriptor_bytes) from app_private.sync_environment_storage where singleton));
end $$;

-- Both kinds share byte allowances. Event counts keep their original meaning.
create or replace function app_private.account_sync_storage() returns trigger
language plpgsql security definer set search_path='' as $$
declare a uuid; delta_bytes bigint; delta_events bigint; policy app_private.sync_storage_policy;
 environment app_private.sync_environment_storage; account app_private.sync_account_storage;
begin
 if tg_op='DELETE' and old.account_id::text=coalesce(current_setting('app_private.deleting_account',true),'') then return null; end if;
 if tg_op='INSERT' then a:=new.account_id; delta_bytes:=octet_length(new.ciphertext); delta_events:=1;
 else a:=old.account_id; delta_bytes:=-octet_length(old.ciphertext); delta_events:=-1; end if;
 select * into strict policy from app_private.sync_storage_policy where singleton;
 update app_private.sync_environment_storage set ciphertext_bytes=ciphertext_bytes+delta_bytes,event_count=event_count+delta_events
  where singleton returning * into strict environment;
 if delta_events>0 and (environment.ciphertext_bytes+environment.descriptor_bytes>policy.environment_bytes or environment.event_count>policy.environment_events)
 then raise exception 'sync_environment_storage_limit'; end if;
 if delta_events>0 then
  insert into app_private.sync_account_storage(account_id,ciphertext_bytes,event_count) values(a,delta_bytes,delta_events)
   on conflict(account_id) do update set ciphertext_bytes=app_private.sync_account_storage.ciphertext_bytes+excluded.ciphertext_bytes,
    event_count=app_private.sync_account_storage.event_count+excluded.event_count returning * into account;
 else
  update app_private.sync_account_storage set ciphertext_bytes=ciphertext_bytes+delta_bytes,event_count=event_count+delta_events
   where account_id=a returning * into strict account;
 end if;
 if delta_events>0 and (account.ciphertext_bytes+account.descriptor_bytes>policy.account_bytes or account.event_count>policy.account_events)
 then raise exception 'sync_account_storage_limit'; end if;
 return null;
end $$;
create function app_private.account_descriptor_storage() returns trigger
language plpgsql security definer set search_path='' as $$
declare a uuid; delta_bytes bigint; delta_count bigint; policy app_private.sync_storage_policy; library app_private.library_policy;
 environment app_private.sync_environment_storage; account app_private.sync_account_storage;
begin
 if tg_op='DELETE' and old.account_id::text=coalesce(current_setting('app_private.deleting_account',true),'') then return null; end if;
 a:=case when tg_op='DELETE' then old.account_id else new.account_id end;
 delta_bytes:=(case when tg_op='DELETE' then 0 else octet_length(new.ciphertext) end)-(case when tg_op='INSERT' then 0 else octet_length(old.ciphertext) end);
 delta_count:=case when tg_op='INSERT' then 1 when tg_op='DELETE' then -1 else 0 end;
 select * into strict policy from app_private.sync_storage_policy where singleton;
 select * into strict library from app_private.library_policy where singleton;
 update app_private.sync_environment_storage set descriptor_bytes=descriptor_bytes+delta_bytes,descriptor_count=descriptor_count+delta_count
  where singleton returning * into strict environment;
 if (delta_bytes>0 and environment.ciphertext_bytes+environment.descriptor_bytes>policy.environment_bytes)
  or (delta_count>0 and environment.descriptor_count>library.environment_items+library.environment_imports)
 then raise exception 'sync_environment_storage_limit'; end if;
 insert into app_private.sync_account_storage(account_id,ciphertext_bytes,event_count,descriptor_bytes,descriptor_count) values(a,0,0,greatest(delta_bytes,0),greatest(delta_count,0))
  on conflict(account_id) do update set descriptor_bytes=app_private.sync_account_storage.descriptor_bytes+delta_bytes,
   descriptor_count=app_private.sync_account_storage.descriptor_count+delta_count returning * into account;
 if (delta_bytes>0 and account.ciphertext_bytes+account.descriptor_bytes>policy.account_bytes)
  or (delta_count>0 and account.descriptor_count>library.account_items+library.account_imports)
 then raise exception 'sync_account_storage_limit'; end if;
 return null;
end $$;
create trigger library_descriptor_capacity after insert or update or delete on app_private.library_descriptors
 for each row execute function app_private.account_descriptor_storage();

create function app_private.library_descriptor_ref(a uuid,p_source_id text) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('descriptor_id',d.id,'revision',d.revision,'epoch',d.epoch,'sha256',encode(d.sha256,'hex'))
 from app_private.library_descriptors d where d.account_id=a and d.source_id=p_source_id
$$;
create function app_private.library_descriptor_envelope(d app_private.library_descriptors) returns jsonb
language sql immutable set search_path='' as $$
 select jsonb_build_object('descriptor_id',d.id,'revision',d.revision,'mutation_id',d.mutation_id,'device_id',d.device_id,
  'epoch',d.epoch,'format',d.format,'ciphertext',replace(encode(d.ciphertext,'base64'),E'\n',''),'sha256',encode(d.sha256,'hex'))
$$;

-- Update canonical state_seq without touching membership/intent. Imports and
-- their resolved item share a group; additional matching entries follow in the
-- same transaction. No private-event enum/ciphertext stream is extended.
create function app_private.library_descriptor_emit(a uuid,p_source text) returns void
language plpgsql security definer set search_path='' as $$
declare row record; s bigint; entries jsonb; emitted uuid[]:='{}'; item uuid;
begin
 for row in select id,library_item_id from app_private.import_requests where account_id=a and source_id=p_source order by id loop
  s:=app_private.library_next_seq(a);
  update app_private.import_requests set state_seq=s where account_id=a and id=row.id;
  entries:=jsonb_build_array(app_private.library_import_entry(a,row.id));
  item:=null;
  if row.library_item_id is not null and not(row.library_item_id=any(emitted)) then
   select li.id into item from app_private.library_items li join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
    join app_private.catalog_metadata m on m.id=ca.metadata_id where li.account_id=a and li.id=row.library_item_id and m.source_id=p_source;
   if item is not null then
    update app_private.library_items set state_seq=s where account_id=a and id=item;
    entries:=entries||jsonb_build_array(app_private.library_item_entry(a,item)); emitted:=emitted||item;
   end if;
  end if;
  perform app_private.library_emit(a,s,entries);
 end loop;
 for item in select li.id from app_private.library_items li join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
  join app_private.catalog_metadata m on m.id=ca.metadata_id where li.account_id=a and m.source_id=p_source and not(li.id=any(emitted)) order by li.id loop
  s:=app_private.library_next_seq(a);
  update app_private.library_items set state_seq=s where account_id=a and id=item;
  perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_item_entry(a,item)));
 end loop;
 -- A private title edit changes local title ordering/search even when both
 -- canonical entries are currently hidden or the source is not attached yet.
 update app_private.library_sync_state set query_revision=query_revision+1 where account_id=a;
end $$;

create function public.v1_put_library_descriptor(p_source_id text,p_expected_revision integer,p_caller_device_id uuid,
 p_management_token bytea,p_envelope jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); k app_private.keyrings; d app_private.library_descriptors; prior app_private.library_commands;
 descriptor uuid; mutation uuid; author uuid; rev integer; epoch integer; combined bytea; digest bytea; request_digest bytea; result jsonb;
begin
 perform app_private.lock_library_account(a);
 perform public.worker_consume_request(a,'library-write');
 select * into strict k from app_private.keyrings where account_id=a for update;
 if not coalesce(app_private.verify_management(a,p_management_token),false) or not exists(select 1 from app_private.devices
  where account_id=a and id=p_caller_device_id and revoked_at is null) then raise exception 'key_authority_required' using errcode='42501'; end if;
 if p_source_id is null or octet_length(p_source_id) not between 1 and 128 or p_source_id !~ '^[!-~]+$'
  or p_expected_revision is null or p_expected_revision<0 or p_envelope is null or jsonb_typeof(p_envelope)<>'object' or octet_length(p_envelope::text)>8192
  or (select array_agg(key order by key) from jsonb_object_keys(p_envelope) key) is distinct from
   array['ciphertext','descriptor_id','device_id','epoch','format','mutation_id','revision','sha256']::text[]
  or exists(select 1 from jsonb_each(p_envelope) x where (x.key in ('revision','epoch','format') and jsonb_typeof(x.value)<>'number')
   or (x.key not in ('revision','epoch','format') and jsonb_typeof(x.value)<>'string'))
  or not coalesce(p_envelope->>'descriptor_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
  or not coalesce(p_envelope->>'mutation_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
  or not coalesce(p_envelope->>'device_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
  or not coalesce(p_envelope->>'revision' ~ '^[1-9][0-9]{0,9}$',false) or (p_envelope->>'revision')::numeric>2147483647
  or not coalesce(p_envelope->>'epoch' ~ '^[1-9][0-9]{0,9}$',false) or (p_envelope->>'epoch')::numeric>2147483647
  or p_envelope->'format' is distinct from '1'::jsonb
  or not coalesce(p_envelope->>'sha256' ~ '^[0-9a-f]{64}$',false)
 then raise exception 'invalid_library_descriptor'; end if;
 begin combined:=decode(p_envelope->>'ciphertext','base64'); exception when others then raise exception 'invalid_library_descriptor'; end;
 if octet_length(combined) not between 28 and 4124 or replace(encode(combined,'base64'),E'\n','')<>p_envelope->>'ciphertext'
  or encode(sha256(combined),'hex')<>p_envelope->>'sha256' then raise exception 'invalid_library_descriptor'; end if;
 descriptor:=(p_envelope->>'descriptor_id')::uuid; mutation:=(p_envelope->>'mutation_id')::uuid; author:=(p_envelope->>'device_id')::uuid;
 rev:=(p_envelope->>'revision')::integer; epoch:=(p_envelope->>'epoch')::integer; digest:=sha256(combined);
 if rev::bigint<>p_expected_revision::bigint+1 then raise exception 'invalid_library_descriptor_revision'; end if;
 request_digest:=sha256(convert_to(jsonb_build_array('science-reader/library-descriptor/command/v1',a,p_source_id,p_expected_revision,p_envelope)::text,'UTF8'));
 perform app_private.lock_library_state(a);
 select * into prior from app_private.library_commands where account_id=a and id=mutation;
 if found then
  if prior.request_sha256<>request_digest then raise exception 'operation_id_conflict'; end if;
  -- Current authority was proved first. Caller/token are intentionally absent
  -- from request identity; surviving/recovered devices can resolve a lost reply.
  return jsonb_build_object('format',1,'account_id',a,'replayed',true,'result',prior.result);
 end if;
 if author<>p_caller_device_id or epoch<>k.epoch then raise exception 'stale_key_epoch'; end if;
 if not exists(select 1 from app_private.pdf_uploads where account_id=a and source_id=p_source_id)
  and not exists(select 1 from app_private.import_requests where account_id=a and source_id=p_source_id)
  and not exists(select 1 from app_private.library_items li join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
   join app_private.catalog_metadata m on m.id=ca.metadata_id where li.account_id=a and m.source_id=p_source_id)
 then raise exception 'library_descriptor_source_unavailable' using errcode='42501'; end if;
 select * into d from app_private.library_descriptors where account_id=a and source_id=p_source_id for update;
 perform app_private.library_check_receipt_capacity(a,false);
 if coalesce(d.revision,0)<>p_expected_revision or (d.id is not null and d.id<>descriptor) then
  result:=jsonb_build_object('status','revision_conflict','kind','descriptor','id',descriptor,'reference',app_private.library_descriptor_ref(a,p_source_id));
 else
  if exists(select 1 from app_private.library_descriptors where account_id=a and id=descriptor and source_id<>p_source_id) then raise exception 'descriptor_id_conflict'; end if;
  insert into app_private.library_descriptors(account_id,source_id,id,revision,mutation_id,device_id,epoch,format,ciphertext,sha256)
   values(a,p_source_id,descriptor,rev,mutation,author,epoch,1,combined,digest)
   on conflict(account_id,id) do update set revision=excluded.revision,mutation_id=excluded.mutation_id,device_id=excluded.device_id,
    epoch=excluded.epoch,ciphertext=excluded.ciphertext,sha256=excluded.sha256,updated_at=clock_timestamp();
  perform app_private.library_descriptor_emit(a,p_source_id);
  result:=jsonb_build_object('status','applied','kind','descriptor','id',descriptor,'reference',app_private.library_descriptor_ref(a,p_source_id));
 end if;
 perform app_private.library_receipt(a,mutation,request_digest,result);
 return jsonb_build_object('format',1,'account_id',a,'replayed',false,'result',result);
end $$;

create function public.v1_library_descriptors(p_requests jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); request jsonb; d app_private.library_descriptors; rows jsonb:='[]'; result jsonb; ids uuid[]:='{}'; requested uuid; revision integer;
begin
 perform 1 from app_private.accounts where id=a and closed_at is null for key share;
 if not found then raise exception 'account_unavailable'; end if;
 perform public.worker_consume_request(a,'library-read');
 if p_requests is null or jsonb_typeof(p_requests)<>'array' or jsonb_array_length(p_requests) not between 1 and 24 or octet_length(p_requests::text)>8192
 then raise exception 'invalid_library_descriptor_request'; end if;
 for request in select value from jsonb_array_elements(p_requests) loop
  if jsonb_typeof(request)<>'object' or (select array_agg(key order by key) from jsonb_object_keys(request) key) is distinct from array['descriptor_id','revision']::text[]
   or jsonb_typeof(request->'descriptor_id')<>'string' or jsonb_typeof(request->'revision')<>'number'
   or not coalesce(request->>'descriptor_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
   or not coalesce(request->>'revision' ~ '^[1-9][0-9]{0,9}$',false) or (request->>'revision')::numeric>2147483647 then raise exception 'invalid_library_descriptor_request'; end if;
  requested:=(request->>'descriptor_id')::uuid; revision:=(request->>'revision')::integer;
  if requested=any(ids) then raise exception 'invalid_library_descriptor_request'; end if; ids:=ids||requested;
  select * into d from app_private.library_descriptors where account_id=a and id=requested;
  if not found then raise exception 'library_descriptor_unavailable' using errcode='42501'; end if;
  rows:=rows||jsonb_build_array(case when d.revision=revision then jsonb_build_object('descriptor_id',d.id,'revision',d.revision,'status','available',
   'source_id',d.source_id,'envelope',app_private.library_descriptor_envelope(d))
   else jsonb_build_object('descriptor_id',requested,'revision',revision,'status','stale','reference',app_private.library_descriptor_ref(a,d.source_id)) end);
 end loop;
 result:=jsonb_build_object('format',1,'account_id',a,'records',rows);
 perform app_private.consume_library_transfer(a,result);
 return result;
end $$;

-- Upload-capable library visibility, integrated after descriptor helpers.
-- Canonical mutations keep one journal. Visibility is persisted per entry, never
-- inferred from missing source metadata after a removal, and never per whole batch.
lock table app_private.library_policy,app_private.library_sync_state,app_private.library_items,
 app_private.import_requests,app_private.library_changes,app_private.library_v4_entries,
 app_private.library_query_entries in share row exclusive mode;

alter table app_private.library_v4_config add column upload_dataset_epoch uuid not null default gen_random_uuid();
alter table app_private.library_v4_config add constraint library_visibility_epochs_distinct check(dataset_epoch<>upload_dataset_epoch);
alter table app_private.library_v4_entries add column minimum_source_level smallint not null default 2 check(minimum_source_level between 2 and 4);
alter table app_private.library_query_entries add column minimum_source_level smallint not null default 2 check(minimum_source_level between 2 and 4);

create or replace function app_private.library_entry_level(p_entry jsonb) returns integer
language sql immutable set search_path='' as $$
 select coalesce((p_entry->>'minimum_source_level')::integer,
  case p_entry->>'source' when 'web' then 3 when 'upload' then 4 else 2 end)
$$;

-- A derived minimum is only a batch SEEK hint. The actual reader always filters
-- every entry, so a grouped public/upload change cannot leak the hidden member.
-- Generated storage backfills this hint without modifying historical entries.
create function app_private.library_change_level(e jsonb) returns smallint
language sql immutable set search_path='' as $$
 select min(app_private.library_entry_level(x.value))::smallint from jsonb_array_elements(e) x
$$;
alter table app_private.library_changes add column minimum_source_level smallint
 generated always as (app_private.library_change_level(entries)) stored not null
 check(minimum_source_level between 2 and 4);
create index library_changes_visibility on app_private.library_changes(account_id,minimum_source_level,seq);

-- Equality on each bounded capability range uses the same B-tree, even in a
-- generic prepared plan. At most three * p_limit candidates are merged. This
-- preserves installed full readers' nonempty-continuation contract without
-- expanding/scanning the JSON for every hidden upload on each page.
create function app_private.library_visible_changes(a uuid,p_after bigint,p_through bigint,p_limit integer,p_level integer)
returns table(seq bigint,entries jsonb) language sql stable security definer set search_path='' as $$
 with ids as materialized (
  select c.seq from (
   (select j.seq from app_private.library_changes j
    where j.account_id=a and j.minimum_source_level=2 and j.seq>p_after and j.seq<=p_through order by j.seq limit p_limit)
   union all
   (select j.seq from app_private.library_changes j
    where p_level>=3 and j.account_id=a and j.minimum_source_level=3 and j.seq>p_after and j.seq<=p_through order by j.seq limit p_limit)
   union all
   (select j.seq from app_private.library_changes j
    where p_level>=4 and j.account_id=a and j.minimum_source_level=4 and j.seq>p_after and j.seq<=p_through order by j.seq limit p_limit)
  ) c order by c.seq limit p_limit
 ) select j.seq,j.entries from ids join app_private.library_changes j on j.account_id=a and j.seq=ids.seq order by j.seq
$$;

create function app_private.library_stamp_entry(a uuid,e jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare prior app_private.library_v4_entries; level integer; src text:=e->>'source'; ref jsonb;
begin
 if e is null or jsonb_typeof(e) is distinct from 'object' or not coalesce(e->>'kind' in ('item','import'),false) then raise exception 'invalid_library_compact_entry'; end if;
 select * into prior from app_private.library_v4_entries where account_id=a and kind=e->>'kind' and id=(e->>'id')::uuid;
 level:=case when src is null then coalesce(prior.minimum_source_level,2)
  when src='arxiv' then 2 when src='web' then 3 when src='upload' then 4 end;
 if level is null or (prior.id is not null and src is not null and prior.minimum_source_level<>level)
  or (e ? 'minimum_source_level' and e->'minimum_source_level' is distinct from to_jsonb(level))
 then raise exception 'library_source_identity_conflict'; end if;
 -- An unchanged old envelope ref in an emitted event must not replace the
 -- current CAS result. Stamp from authority at commit; tombstones retain their pin.
 ref:=case when e->>'source_id' is not null then app_private.library_descriptor_ref(a,e->>'source_id')
  else prior.entry->'descriptor_ref' end;
 return (e-'descriptor_ref')||jsonb_build_object('minimum_source_level',level)
  ||case when ref is not null and ref<>'null'::jsonb then jsonb_build_object('descriptor_ref',ref) else '{}'::jsonb end;
end $$;

create function app_private.library_read_entry(e jsonb,p_level integer,p_compact boolean default false) returns jsonb
language sql immutable set search_path='' as $$
 select (e-'minimum_source_level')-case when p_level<4 then array['descriptor_ref'] else '{}'::text[] end
  -case when p_compact then array['metadata'] else '{}'::text[] end
$$;

create function app_private.library_stamp_change() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 select jsonb_agg(app_private.library_stamp_entry(new.account_id,x.value) order by x.ordinality) into new.entries
 from jsonb_array_elements(new.entries) with ordinality x;
 return new;
end $$;
create trigger library_stamp_change before insert on app_private.library_changes
 for each row execute function app_private.library_stamp_change();

-- Stamp BEFORE admission calculates encoded bytes. The trigger also protects
-- internal direct inserts; customer roles have no table access. The generated
-- encoded_bytes column continues to measure the actual persisted JSON.
create or replace function app_private.library_emit(a uuid,s bigint,e jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare p app_private.library_policy; bytes bigint;
begin
 if e is null or jsonb_typeof(e)<>'array' or jsonb_array_length(e) not between 1 and 4 then raise exception 'library_change_too_large'; end if;
 select jsonb_agg(app_private.library_stamp_entry(a,x.value) order by x.ordinality) into e from jsonb_array_elements(e) with ordinality x;
 bytes:=octet_length(e::text)+128;
 select * into strict p from app_private.library_policy;
 if bytes>131072 then raise exception 'library_change_too_large'; end if;
 if (select last_seq from app_private.library_sync_state where account_id=a)<>s then raise exception 'library_sequence_mismatch'; end if;
 if (select coalesce(sum(encoded_bytes),0) from app_private.library_changes where account_id=a)+bytes>p.account_journal_bytes
  or (select count(*) from app_private.library_changes where account_id=a)+1>p.account_journal_events then
  delete from app_private.library_changes where account_id=a;
  update app_private.library_sync_state set retained_after=s-1 where account_id=a;
 end if;
 if (select coalesce(sum(encoded_bytes),0) from app_private.library_changes)+bytes>p.environment_journal_bytes
  or (select count(*) from app_private.library_changes)+1>p.environment_journal_events then
  delete from app_private.library_changes;
  update app_private.library_sync_state set retained_after=case when account_id=a then s-1 else last_seq end;
 end if;
 insert into app_private.library_changes(account_id,seq,entries) values(a,s,e);
end $$;

create or replace function app_private.library_v4_project_entry(a uuid,e jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare compact jsonb:=app_private.library_stamp_entry(a,e)-'metadata'; previous app_private.library_v4_entries;
 k text:=e->>'kind'; entry_id uuid:=(e->>'id')::uuid;
 created bigint:=(e->>'created_seq')::bigint; state bigint:=(e->>'state_seq')::bigint;
 level integer:=app_private.library_entry_level(compact);
begin
 insert into app_private.library_v4_entries(account_id,kind,id,created_seq,state_seq,metadata_id,entry,minimum_source_level)
 values(a,k,entry_id,created,state,(e->>'metadata_id')::uuid,compact,level)
 on conflict(account_id,kind,id) do update
 set state_seq=excluded.state_seq,metadata_id=excluded.metadata_id,entry=excluded.entry
 where app_private.library_v4_entries.state_seq<excluded.state_seq
  and app_private.library_v4_entries.created_seq=excluded.created_seq
  and app_private.library_v4_entries.minimum_source_level=excluded.minimum_source_level;
 if not found then
  select * into strict previous from app_private.library_v4_entries where account_id=a and kind=k and id=entry_id;
  if previous.created_seq<>created or previous.minimum_source_level<>level then raise exception 'library_compact_identity_conflict'; end if;
  if previous.state_seq=state and previous.entry is distinct from compact then raise exception 'library_compact_state_conflict'; end if;
 end if;
end $$;

-- Backfill existing projections only; never rewrite the immutable journal.
-- No upload existed before039. Historical rows without an explicit level retain
-- the legacy arxiv/web classification; all new removal events persist their level.
alter table app_private.library_v4_entries disable trigger library_query_project;
update app_private.library_v4_entries set minimum_source_level=app_private.library_entry_level(entry);
update app_private.library_v4_entries set entry=app_private.library_stamp_entry(account_id,entry);
alter table app_private.library_v4_entries enable trigger library_query_project;

create or replace function app_private.library_query_project(a uuid,k text,i uuid,m uuid,c bigint,e jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare tags text[]:=app_private.library_query_tags(e); keys text[]; meta app_private.library_query_metadata; changed integer; was_visible boolean; level integer:=app_private.library_entry_level(e);
begin
 select visible into was_visible from app_private.library_query_entries where account_id=a and kind=k and id=i;
 select * into meta from app_private.library_query_metadata where metadata_id=m;
 if m is not null and not found then raise exception 'library_query_metadata_missing'; end if;
 if cardinality(tags)=0 and m is not null then tags:=meta.fallback_tags; end if;
 select coalesce(array_agg(lower(t collate pg_catalog.pg_c_utf8) order by n),'{}') into keys from unnest(tags) with ordinality x(t,n);
 insert into app_private.library_query_entries(account_id,kind,id,metadata_id,created_seq,visible,archived,source,source_id,library_item_id,
  effective_tags,tag_keys,own_search,title_missing,title_prefix,year_missing,year_value,minimum_source_level) values(a,k,i,m,c,(e->>'visible')::boolean,coalesce((e->>'archived')::boolean,false),
  e->>'source',e->>'source_id',(e->>'library_item_id')::uuid,tags,keys,
  app_private.library_search_normalize(coalesce(e->>'source_id','')||chr(10)||array_to_string(tags,chr(10))),
  m is null,coalesce(left(meta.title_key,64),''),meta.year_value is null,coalesce(meta.year_value,0),level)
 on conflict(account_id,kind,id) do update set metadata_id=excluded.metadata_id,created_seq=excluded.created_seq,
  visible=excluded.visible,archived=excluded.archived,source=excluded.source,source_id=excluded.source_id,
  library_item_id=excluded.library_item_id,effective_tags=excluded.effective_tags,tag_keys=excluded.tag_keys,
  own_search=excluded.own_search,title_missing=excluded.title_missing,title_prefix=excluded.title_prefix,
  year_missing=excluded.year_missing,year_value=excluded.year_value,minimum_source_level=excluded.minimum_source_level
 where (library_query_entries.metadata_id,library_query_entries.created_seq,library_query_entries.visible,
  library_query_entries.archived,library_query_entries.source,library_query_entries.source_id,
  library_query_entries.library_item_id,library_query_entries.effective_tags,library_query_entries.minimum_source_level)
 is distinct from (excluded.metadata_id,excluded.created_seq,excluded.visible,excluded.archived,excluded.source,
  excluded.source_id,excluded.library_item_id,excluded.effective_tags,excluded.minimum_source_level);
 get diagnostics changed=row_count;
 if changed>0 and (coalesce(was_visible,false) or (e->>'visible')::boolean) then
  update app_private.library_sync_state set query_revision=query_revision+1 where account_id=a;
 end if;
end $$;

create or replace function app_private.library_query_project_trigger() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.library_query_project(new.account_id,new.kind,new.id,new.metadata_id,new.created_seq,new.entry);
 if TG_OP='UPDATE' and old.entry->'descriptor_ref' is distinct from new.entry->'descriptor_ref' then
  -- An encrypted rename changes client-side ordering, including hidden mappings.
  update app_private.library_sync_state set query_revision=query_revision+1 where account_id=new.account_id;
 end if;
 return null;
end $$;

do $$ declare e app_private.library_v4_entries; begin
 for e in select * from app_private.library_v4_entries order by account_id,created_seq,id,kind loop
  perform app_private.library_query_project(e.account_id,e.kind,e.id,e.metadata_id,e.created_seq,e.entry);
 end loop;
end $$;
-- Current derived rows changed; reject pre-upgrade compact cache/cursor generations.
update app_private.library_v4_config set dataset_epoch=gen_random_uuid(),upload_dataset_epoch=gen_random_uuid();


create function app_private.library_compact_baseline_at(a uuid,p_cursor jsonb,p_limit integer,p_level integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare wire_format integer:=case when p_level=4 then 5 else 4 end; epoch uuid; high bigint; floor bigint; cursor_epoch uuid; cursor_high bigint;
 after_seq bigint:=0; after_id uuid:='00000000-0000-0000-0000-000000000000'; after_kind text:=''; result jsonb;
begin
 if p_level is null or p_level not in (3,4) or p_limit is null or p_limit not between 1 and 100 then raise exception 'invalid_library_page'; end if;
 select case when p_level=4 then upload_dataset_epoch else dataset_epoch end into strict epoch from app_private.library_v4_config where singleton;
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_cursor is not null then
  if jsonb_typeof(p_cursor) is distinct from 'object'
   or not (p_cursor ?& array['format','dataset_epoch','account_id','through','created_seq','id','kind'])
   or (p_cursor-array['format','dataset_epoch','account_id','through','created_seq','id','kind'])<>'{}'::jsonb
   or p_cursor->'format' is distinct from to_jsonb(wire_format) or p_cursor->'account_id' is distinct from to_jsonb(a)
   or jsonb_typeof(p_cursor->'dataset_epoch') is distinct from 'string'
   or not coalesce(p_cursor->>'dataset_epoch' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
   or jsonb_typeof(p_cursor->'through') is distinct from 'number' or not coalesce(p_cursor->>'through' ~ '^[0-9]+$',false)
   or jsonb_typeof(p_cursor->'created_seq') is distinct from 'number' or not coalesce(p_cursor->>'created_seq' ~ '^[0-9]+$',false)
   or jsonb_typeof(p_cursor->'id') is distinct from 'string'
   or not coalesce(p_cursor->>'id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
   or p_cursor->>'kind' not in ('item','import') or jsonb_typeof(p_cursor->'kind') is distinct from 'string'
  then raise exception 'invalid_library_cursor'; end if;
  begin
   cursor_epoch:=(p_cursor->>'dataset_epoch')::uuid;
   after_seq:=(p_cursor->>'created_seq')::bigint; after_id:=(p_cursor->>'id')::uuid; after_kind:=p_cursor->>'kind';
   cursor_high:=(p_cursor->>'through')::bigint;
  exception when numeric_value_out_of_range or invalid_text_representation then raise exception 'invalid_library_cursor'; end;
  if after_seq<1 or after_seq>cursor_high then raise exception 'invalid_library_cursor'; end if;
  -- After a dataset replacement, a valid old cursor may be above this dataset's
  -- new highwater. Its epoch requires resync before comparing those sequences.
  if cursor_epoch<>epoch then raise exception 'library_resync_required'; end if;
  if cursor_high>high then raise exception 'invalid_library_cursor'; end if;
  high:=cursor_high;
  if not exists(select 1 from app_private.library_v4_entries
   where account_id=a and kind=after_kind and id=after_id and created_seq=after_seq and minimum_source_level<=p_level)
  then raise exception 'invalid_library_cursor'; end if;
 end if;
 if high<floor then raise exception 'library_resync_required'; end if;
 with candidates as materialized (
  select created_seq,id,kind,app_private.library_read_entry(entry,p_level,true) entry from app_private.library_v4_entries
  where account_id=a and minimum_source_level<=p_level and created_seq<=high and (created_seq,id,kind)>(after_seq,after_id,after_kind)
  order by created_seq,id,kind limit p_limit
 ), sized as (
  select *,sum(octet_length(entry::text)+2) over(order by created_seq,id,kind) bytes from candidates
 ), selected as materialized (select * from sized where bytes<=1046528), last_row as (
  select created_seq,id,kind from selected order by created_seq desc,id desc,kind desc limit 1
 ) select jsonb_build_object('format',wire_format,'dataset_epoch',epoch,'account_id',a,'baseline_cursor',high,'retained_after',floor,
  'entries',coalesce((select jsonb_agg(entry order by created_seq,id,kind) from selected),'[]'::jsonb),
  'next_cursor',(select jsonb_build_object('format',wire_format,'dataset_epoch',epoch,'account_id',a,'through',high,
   'created_seq',created_seq,'id',id,'kind',kind) from last_row),
  'has_more',exists(select 1 from app_private.library_v4_entries e where e.account_id=a and e.minimum_source_level<=p_level and e.created_seq<=high
   and (e.created_seq,e.id,e.kind)>coalesce((select row(created_seq,id,kind) from last_row),row(after_seq,after_id,after_kind)))) into result;
 if result->'entries'='[]'::jsonb and (result->>'has_more')::boolean then raise exception 'library_page_too_large'; end if;
 return result;
end $$;

create function app_private.library_compact_delta_at(a uuid,p_dataset_epoch uuid,p_after bigint,p_through bigint,p_limit integer,p_level integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare wire_format integer:=case when p_level=4 then 5 else 4 end; epoch uuid; high bigint; floor bigint; result jsonb;
begin
 select case when p_level=4 then upload_dataset_epoch else dataset_epoch end into strict epoch from app_private.library_v4_config where singleton;
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_level is null or p_level not in (3,4) or p_dataset_epoch is null or p_after is null or p_after<0 or p_limit is null or p_limit not between 1 and 100
  or p_through<p_after then raise exception 'invalid_library_cursor'; end if;
 if p_dataset_epoch<>epoch then raise exception 'library_resync_required'; end if;
 if p_after>high or p_through>high then raise exception 'invalid_library_cursor'; end if;
 if p_after<floor then raise exception 'library_resync_required'; end if;
 high:=coalesce(p_through,high);
 -- Seek eligible batches before expanding JSON. The scan is bounded even when
 -- this account has a large hidden upload history between visible entries.
 with candidates as materialized (
  select * from app_private.library_visible_changes(a,p_after,high,p_limit+1,p_level)
 ), compact as materialized (
  select c.seq,(select coalesce(jsonb_agg(app_private.library_read_entry(x.value,p_level,true) order by x.ordinality),'[]'::jsonb)
   from jsonb_array_elements(c.entries) with ordinality x where app_private.library_entry_level(x.value)<=p_level) entries from candidates c order by c.seq limit p_limit
 ), sized as (select *,sum(octet_length(entries::text)+128) over(order by seq) bytes from compact),
 selected as materialized (select seq,entries from sized where bytes<=1046528),
 page as (select coalesce(jsonb_agg(jsonb_build_object('seq',seq,'entries',entries) order by seq) filter(where jsonb_array_length(entries)>0),'[]'::jsonb) changes,coalesce(max(seq),p_after) last from selected)
 select jsonb_build_object('format',wire_format,'dataset_epoch',epoch,'account_id',a,'through',high,'retained_after',floor,'changes',changes,
  'next_cursor',case when exists(select 1 from candidates where seq>page.last) then page.last else high end,
  'has_more',exists(select 1 from candidates where seq>page.last)) into result from page;
 return result;
end $$;

create function app_private.library_compact_metadata_at(a uuid,p_dataset_epoch uuid,p_metadata_ids uuid[],p_level integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare wire_format integer:=case when p_level=4 then 5 else 4 end; epoch uuid; result jsonb;
begin
 select case when p_level=4 then upload_dataset_epoch else dataset_epoch end into strict epoch from app_private.library_v4_config where singleton;
 if p_level is null or p_level not in (3,4) then raise exception 'invalid_library_metadata_request'; end if;
 if p_dataset_epoch is distinct from epoch then raise exception 'library_resync_required'; end if;
 if p_metadata_ids is null or coalesce(array_ndims(p_metadata_ids),1)<>1 or cardinality(p_metadata_ids)>24
  or exists(select 1 from unnest(p_metadata_ids) id where id is null)
  or (select count(distinct id) from unnest(p_metadata_ids) id)<>cardinality(p_metadata_ids)
 then raise exception 'invalid_library_metadata_request'; end if;
 -- Check the entire bounded request before returning any record. Missing and
 -- unauthorized UUIDs have the same failure, regardless of catalog existence.
 -- Removed rows/hidden mappings deliberately retain authorization until their
 -- account is deleted; no new metadata authority comes from a global UUID.
 if exists(select 1 from unnest(p_metadata_ids) requested(id)
  where not exists(select 1 from app_private.library_v4_entries e where e.account_id=a and e.metadata_id=requested.id and e.minimum_source_level<=p_level)
   or not exists(select 1 from app_private.catalog_metadata m where m.id=requested.id and app_private.source_level(m.source_id)<=p_level))
 then raise exception 'library_metadata_unavailable' using errcode='42501'; end if;
 select jsonb_build_object('format',wire_format,'dataset_epoch',epoch,'account_id',a,'records',coalesce(jsonb_agg(
  jsonb_build_object('metadata_id',m.id,'version_id',m.version_id,
   'source',case when m.source_id like 'openalex:%' then 'web' when m.source_id like 'upload:%' then 'upload' else 'arxiv' end,
   'source_id',m.source_id,'source_revision',m.source_revision,'metadata',m.metadata,'recorded_at',m.recorded_at)
  order by requested.ordinality),'[]'::jsonb)) into result
 from unnest(p_metadata_ids) with ordinality requested(id,ordinality) join app_private.catalog_metadata m on m.id=requested.id;
 -- The immutable UUID/provenance identifies this record. catalog_metadata's
 -- internal jsonb hash is NOT a hash of serialized wire bytes and is not sent.
 return result;
end $$;

-- Full readers share the compact creation/visibility index, but render the
-- bounded page through the canonical builders. Old command acknowledgements
-- retain their exact pre-descriptor shape; v5 learns refs through observation.
create or replace function app_private.library_baseline_at(a uuid,p_cursor jsonb,p_limit integer,p_level integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare high bigint; floor bigint; cursor_high bigint; after_seq bigint:=0; epoch uuid; cursor_epoch uuid;
 after_id uuid:='00000000-0000-0000-0000-000000000000'; after_kind text:=''; result jsonb;
 cursor_keys text[]:=array['format','account_id','through','created_seq','id','kind'];
begin
 if p_limit is null or p_limit not between 1 and 100 or p_level is null or p_level not between 2 and 4 then raise exception 'invalid_library_page'; end if;
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_level=4 then
  cursor_keys:=cursor_keys||array['read_level','dataset_epoch'];
  select upload_dataset_epoch into strict epoch from app_private.library_v4_config;
 end if;
 if p_cursor is not null then
  if jsonb_typeof(p_cursor) is distinct from 'object' or not (p_cursor ?& cursor_keys)
   or (p_cursor-cursor_keys)<>'{}'::jsonb or p_cursor->'format' is distinct from '2'::jsonb
   or p_cursor->'account_id' is distinct from to_jsonb(a)
   or (p_level=4 and p_cursor->'read_level' is distinct from '4'::jsonb)
   or (p_level=4 and (jsonb_typeof(p_cursor->'dataset_epoch') is distinct from 'string'
    or not coalesce(p_cursor->>'dataset_epoch' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)))
   or jsonb_typeof(p_cursor->'through') is distinct from 'number' or not coalesce(p_cursor->>'through' ~ '^[0-9]{1,19}$',false)
   or jsonb_typeof(p_cursor->'created_seq') is distinct from 'number' or not coalesce(p_cursor->>'created_seq' ~ '^[0-9]{1,19}$',false)
   or jsonb_typeof(p_cursor->'id') is distinct from 'string'
   or not coalesce(p_cursor->>'id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
   or jsonb_typeof(p_cursor->'kind') is distinct from 'string' or p_cursor->>'kind' not in ('item','import')
  then raise exception 'invalid_library_cursor'; end if;
  begin
   cursor_high:=(p_cursor->>'through')::bigint; after_seq:=(p_cursor->>'created_seq')::bigint;
   after_id:=(p_cursor->>'id')::uuid; after_kind:=p_cursor->>'kind';
   if p_level=4 then cursor_epoch:=(p_cursor->>'dataset_epoch')::uuid; end if;
  exception when numeric_value_out_of_range or invalid_text_representation then raise exception 'invalid_library_cursor'; end;
  if p_level=4 and cursor_epoch<>epoch then raise exception 'library_resync_required'; end if;
  if cursor_high>high or after_seq<1 or after_seq>cursor_high then raise exception 'invalid_library_cursor'; end if;
  high:=cursor_high;
  if not exists(select 1 from app_private.library_v4_entries where account_id=a and kind=after_kind and id=after_id
   and created_seq=after_seq and minimum_source_level<=p_level) then raise exception 'invalid_library_cursor'; end if;
 end if;
 if high<floor then raise exception 'library_resync_required'; end if;
 with candidates as materialized (
  select created_seq,id,kind from app_private.library_v4_entries
  where account_id=a and minimum_source_level<=p_level and created_seq<=high
   and (created_seq,id,kind)>(after_seq,after_id,after_kind)
  order by created_seq,id,kind limit p_limit
 ), rendered as materialized (
  select created_seq,id,kind,app_private.library_read_entry(app_private.library_stamp_entry(a,
   case when kind='item' then app_private.library_item_entry(a,id) else app_private.library_import_entry(a,id) end),p_level) entry
  from candidates
 ), sized as (
  select *,sum(octet_length(entry::text)+2) over(order by created_seq,id,kind) bytes from rendered
 ), selected as materialized (select * from sized where bytes<=1046528), last_row as (
  select created_seq,id,kind from selected order by created_seq desc,id desc,kind desc limit 1
 ) select jsonb_build_object('format',2,'account_id',a,'baseline_cursor',high,'retained_after',floor,
  'entries',coalesce((select jsonb_agg(entry order by created_seq,id,kind) from selected),'[]'::jsonb),
  'next_cursor',(select jsonb_build_object('format',2,'account_id',a,'through',high,'created_seq',created_seq,'id',id,'kind',kind)
   ||case when p_level=4 then jsonb_build_object('read_level',4,'dataset_epoch',epoch) else '{}'::jsonb end from last_row),
  'has_more',exists(select 1 from app_private.library_v4_entries e where e.account_id=a and e.minimum_source_level<=p_level and e.created_seq<=high
   and (e.created_seq,e.id,e.kind)>coalesce((select row(created_seq,id,kind) from last_row),row(after_seq,after_id,after_kind)))) into result;
 if result->'entries'='[]'::jsonb and (result->>'has_more')::boolean then raise exception 'library_page_too_large'; end if;
 return result||case when p_level=4 then jsonb_build_object('dataset_epoch',epoch) else '{}'::jsonb end;
end $$;

create or replace function app_private.library_delta_at(a uuid,p_after bigint,p_through bigint,p_limit integer,p_level integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare high bigint; floor bigint; result jsonb;
begin
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_level is null or p_level not between 2 and 4 or p_after is null or p_after<0 or p_limit is null or p_limit not between 1 and 100
  or p_after>high or p_through>high or p_through<p_after then raise exception 'invalid_library_cursor'; end if;
 if p_after<floor then raise exception 'library_resync_required'; end if;
 high:=coalesce(p_through,high);
 -- Installed full decoders require a nonempty page and next_cursor equal to
 -- its last emitted batch when has_more=true. Indexed capability seeks preserve
 -- that contract without unbounded scans through hidden raw journal payloads.
 with candidates as materialized (
  select * from app_private.library_visible_changes(a,p_after,high,p_limit+1,p_level)
 ), rendered as materialized (
  select c.seq,(select coalesce(jsonb_agg(app_private.library_read_entry(x.value,p_level) order by x.ordinality),'[]'::jsonb)
   from jsonb_array_elements(c.entries) with ordinality x where app_private.library_entry_level(x.value)<=p_level) entries from candidates c order by c.seq limit p_limit
 ), sized as (select *,sum(octet_length(entries::text)+128) over(order by seq) bytes from rendered),
 selected as materialized (select seq,entries from sized where bytes<=1046528),
 page as (select coalesce(jsonb_agg(jsonb_build_object('seq',seq,'entries',entries) order by seq)
  filter(where jsonb_array_length(entries)>0),'[]'::jsonb) changes,coalesce(max(seq),p_after) last from selected)
 select jsonb_build_object('format',2,'account_id',a,'through',high,'retained_after',floor,'changes',changes,
  'next_cursor',case when exists(select 1 from candidates where seq>page.last) then page.last else high end,
  'has_more',exists(select 1 from candidates where seq>page.last)) into result from page;
 return result;
end $$;

create function app_private.library_query_page_at(a uuid,p_query jsonb,p_cursor jsonb,p_limit integer,p_level integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare wire_format integer:=case when p_level=4 then 5 else 4 end; epoch uuid; spec jsonb:=app_private.library_query_spec(p_query); cfg app_private.library_v4_config; rev bigint;
 fingerprint text:=encode(sha256(convert_to(spec::text,'UTF8')),'hex');
 predicates text:='q.account_id=$1 and q.minimum_source_level<=$9 and q.visible and not (q.kind=''import'' and q.library_item_id is not null and exists(select 1 from app_private.library_query_entries linked where linked.account_id=q.account_id and linked.kind=''item'' and linked.id=q.library_item_id and linked.minimum_source_level<=$9 and linked.visible))';
 order_by text; comparison text; key_expr text; key_arg text; missing_expr text; prefix_expr text; direction text:=spec->>'direction';
 patterns text[]; term text; j integer:=0; anchor record; result jsonb; after_kind text; after_id uuid;
 sql_text text; ordinal integer; small_library boolean:=false;
begin
 if p_level is null or p_level not in (3,4) or p_limit is null or p_limit not between 1 and 50 then raise exception 'invalid_library_page'; end if;
 if p_level<4 and spec->>'source'='upload' then raise exception 'invalid_library_query'; end if;
 select * into strict cfg from app_private.library_v4_config;
 epoch:=case when p_level=4 then cfg.upload_dataset_epoch else cfg.dataset_epoch end;
 if cfg.search_version is distinct from app_private.library_search_version() then raise exception 'library_query_rebuild_required'; end if;
 select query_revision into strict rev from app_private.library_sync_state where account_id=a;
 if p_cursor is not null then
  if jsonb_typeof(p_cursor)<>'object' or octet_length(p_cursor::text)>2048
   or (p_cursor-'format'-'dataset_epoch'-'account_id'-'search_version'-'query_revision'-'query_sha256'-'kind'-'id')<>'{}'::jsonb
   or p_cursor->'format' is distinct from to_jsonb(wire_format) or p_cursor->>'account_id' is distinct from a::text
   or p_cursor->>'query_sha256' is distinct from fingerprint
   or jsonb_typeof(p_cursor->'query_revision') is distinct from 'number'
   or not coalesce(p_cursor->>'query_revision' ~ '^[0-9]{1,19}$',false)
   or (p_cursor->>'query_revision')::numeric>9223372036854775807
   or p_cursor->>'kind' not in ('item','import')
   or jsonb_typeof(p_cursor->'kind') is distinct from 'string'
   or not coalesce(p_cursor->>'id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
   then raise exception 'invalid_library_cursor'; end if;
  if p_cursor->>'dataset_epoch' is distinct from epoch::text
   or p_cursor->>'search_version' is distinct from cfg.search_version
   or (p_cursor->>'query_revision')::bigint<>rev then raise exception 'library_query_restart_required'; end if;
  after_kind:=p_cursor->>'kind'; after_id:=(p_cursor->>'id')::uuid;
 end if;
 if spec->>'archive'<>'all' then predicates:=predicates||case when spec->>'archive'='archived' then ' and q.archived' else ' and not q.archived' end; end if;
 if spec->>'source'<>'all' then predicates:=predicates||' and q.source='||quote_literal(spec->>'source'); end if;
 if spec->>'tag' is not null then predicates:=predicates||' and q.tag_keys @> array['||quote_literal(spec->>'tag')||']::text[]'; end if;
 if jsonb_array_length(spec->'terms')>0 then
  -- A one-page account should not scan/hash the shared catalog for every term.
  -- Bound this decision itself at one more than the maximum page size. Larger
  -- libraries retain GIN metadata candidates; their selective searches benefit.
  select count(*)<=50 into small_library from (
   select 1 from app_private.library_query_entries where account_id=a and minimum_source_level<=p_level and visible limit 51
  ) bounded_account;
 end if;
 for term in select jsonb_array_elements_text(spec->'terms') loop
  j:=j+1; patterns:=array_append(patterns,app_private.library_query_pattern(term));
  if not small_library and term collate pg_catalog.pg_c_utf8 ~ '[[:alnum:]]{3}' then
   predicates:=predicates||format(' and (q.own_search like $2[%s] or q.metadata_id in (select sm.metadata_id from app_private.library_query_metadata sm where sm.search_text like $2[%s]))',j,j);
  else
   -- Small libraries and terms without useful trigrams stay on this account's
   -- joined metadata instead of scanning the shared catalog (still measured).
   predicates:=predicates||format(' and (q.own_search like $2[%s] or m.search_text like $2[%s])',j,j);
  end if;
 end loop;
 -- NULLs stay last for both directions. All ties use stable UUID + kind.
 missing_expr:=case spec->>'sort' when 'title' then 'q.title_missing' when 'year' then 'q.year_missing' else 'false' end;
 prefix_expr:=case spec->>'sort' when 'title' then 'q.title_prefix' else '''''::text collate "C"' end;
 key_expr:=case spec->>'sort' when 'title' then 'coalesce(m.title_key,'''') collate "C"' when 'year' then 'q.year_value' else 'q.created_seq' end;
 key_arg:=case when spec->>'sort'='title' then '$7::text collate "C"' else '$7::bigint' end;
 order_by:='missing asc,prefix '||direction||',value '||direction||',q.id '||direction||',q.kind '||direction;
 if after_id is not null then
  execute 'select '||missing_expr||' missing,'||prefix_expr||' prefix,('||key_expr||')::text value from app_private.library_query_entries q left join app_private.library_query_metadata m using(metadata_id) where '
   ||predicates||' and q.kind=$3 and q.id=$4' into anchor using a,patterns,after_kind,after_id,false,''::text,null::bigint,p_limit,p_level;
  get diagnostics ordinal=row_count;
  if ordinal<>1 then raise exception 'invalid_library_cursor'; end if;
  comparison:=case when direction='asc' then '>' else '<' end;
  -- missing=false always precedes missing=true, independent of direction.
  predicates:=predicates||format(' and ((%s)>$5 or ((%s)=$5 and (%s,%s,q.id,q.kind)%s($6,%s,$4,$3)))',
   missing_expr,missing_expr,prefix_expr,key_expr,comparison,key_arg);
  if spec->>'sort'='recent' then
   -- The generic tuple's constant prefix prevents a direct index seek. This
   -- equivalent typed guard lets the recent index start at the actual anchor.
   predicates:=predicates||format(' and (q.created_seq,q.id,q.kind)%s($7::bigint,$4,$3)',comparison);
  elsif spec->>'sort'='title' and direction='asc' then
   -- A coarse lower bound only; retain the strict FULL-title test above so
   -- colliding prefixes never truncate ordering or lose tied item/import IDs.
   predicates:=predicates||' and (q.title_missing,q.title_prefix)>=($5,$6)';
  end if;
 end if;
 sql_text:='with candidates as materialized (
  select q.*,m.summary,'||missing_expr||' missing,'||prefix_expr||' prefix,'||key_expr||' value
  from app_private.library_query_entries q left join app_private.library_query_metadata m using(metadata_id)
  where '||predicates||' order by '||order_by||' limit $8+1
 ), numbered as (select *,row_number() over(order by missing asc,prefix '||direction||',value '||direction||',id '||direction||',kind '||direction||') n from candidates),
 rendered as materialized (
  select n,kind,id,jsonb_build_object(''summary'',coalesce(summary,jsonb_build_object(''title'',null,''authors'',''[]''::jsonb,''author_count'',0,''year'',null,''venue'',null))
   ||jsonb_build_object(''tags'',to_jsonb(effective_tags)),''state'',app_private.library_read_entry(e.entry,$9,true)) row
  from numbered q join app_private.library_v4_entries e using(account_id,kind,id) where n<=$8
 ), sized as (select *,sum(octet_length(row::text)+2) over(order by n) bytes from rendered),
 selected as materialized (select * from sized where bytes<=1044480),
 last_row as (select * from selected order by n desc limit 1)
 select jsonb_build_object(''rows'',coalesce((select jsonb_agg(row order by n) from selected),''[]''::jsonb),
  ''has_more'',exists(select 1 from numbered where n>coalesce((select n from last_row),0)),
  ''anchor'',(select jsonb_build_object(''kind'',kind,''id'',id) from last_row))';
 if after_id is null then
  execute sql_text into result using a,patterns,after_kind,after_id,false,''::text,null,p_limit,p_level;
 else
  execute sql_text into result using a,patterns,after_kind,after_id,anchor.missing,anchor.prefix,anchor.value,p_limit,p_level;
 end if;
 if result->'rows'='[]'::jsonb and (result->>'has_more')::boolean then raise exception 'library_page_too_large'; end if;
 return (result-'anchor')||jsonb_build_object('format',wire_format,'account_id',a,'dataset_epoch',epoch,
  'search_version',cfg.search_version,'query_revision',rev,'query_sha256',fingerprint,
  'next_cursor',case when (result->>'has_more')::boolean then jsonb_build_object('format',wire_format,'account_id',a,
   'dataset_epoch',epoch,'search_version',cfg.search_version,'query_revision',rev,'query_sha256',fingerprint)||(result->'anchor') end);
end $$;

-- Existing compact/query RPC signatures stay unchanged. New v5 compact uses
-- wire format5; v5 full uses format2 plus read_level4 and the same upload epoch.
create or replace function app_private.library_v4_baseline(a uuid,p_cursor jsonb,p_limit integer) returns jsonb
language sql stable security definer set search_path='' as $$
 select app_private.library_compact_baseline_at(a,p_cursor,p_limit,3)
$$;
create or replace function app_private.library_v4_delta(a uuid,p_dataset_epoch uuid,p_after bigint,p_through bigint,p_limit integer) returns jsonb
language sql stable security definer set search_path='' as $$
 select app_private.library_compact_delta_at(a,p_dataset_epoch,p_after,p_through,p_limit,3)
$$;
create or replace function app_private.library_v4_metadata(a uuid,p_dataset_epoch uuid,p_metadata_ids uuid[]) returns jsonb
language sql stable security definer set search_path='' as $$
 select app_private.library_compact_metadata_at(a,p_dataset_epoch,p_metadata_ids,3)
$$;
create or replace function app_private.library_query_page(a uuid,p_query jsonb,p_cursor jsonb,p_limit integer) returns jsonb
language sql stable security definer set search_path='' as $$
 select app_private.library_query_page_at(a,p_query,p_cursor,p_limit,3)
$$;

create function app_private.library_upload_full_delta(a uuid,p_dataset_epoch uuid,p_after bigint,p_through bigint,p_limit integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare epoch uuid;
begin
 select upload_dataset_epoch into strict epoch from app_private.library_v4_config;
 if p_dataset_epoch is null then raise exception 'invalid_library_cursor'; end if;
 if p_dataset_epoch<>epoch then raise exception 'library_resync_required'; end if;
 return app_private.library_delta_at(a,p_after,p_through,p_limit,4)||jsonb_build_object('dataset_epoch',epoch);
end $$;

-- Never ship an epochless v5 overload: it would permit a restored highwater to
-- silently reuse stale rows. This signature existed only earlier in pending039.
drop function public.v5_library_changes(bigint,bigint,integer);

create or replace function public.v2_library_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_baseline_at(a,p_cursor,p_limit,2);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v2_library_changes(p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_delta_at(a,p_after,p_through,p_limit,2);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v3_library_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_baseline_at(a,p_cursor,p_limit,3);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v3_library_changes(p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_delta_at(a,p_after,p_through,p_limit,3);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v5_library_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_baseline_at(a,p_cursor,p_limit,4);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v5_library_changes(p_dataset_epoch uuid,p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_upload_full_delta(a,p_dataset_epoch,p_after,p_through,p_limit);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v5_library_compact_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_compact_baseline_at(a,p_cursor,p_limit,4);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v5_library_compact_changes(p_dataset_epoch uuid,p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_compact_delta_at(a,p_dataset_epoch,p_after,p_through,p_limit,4);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v5_library_metadata(p_dataset_epoch uuid,p_metadata_ids uuid[]) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_compact_metadata_at(a,p_dataset_epoch,p_metadata_ids,4);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v5_library_query(p_query jsonb default '{}'::jsonb,p_cursor jsonb default null,p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_query_page_at(a,p_query,p_cursor,p_limit,4);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

-- An account-bound protocol advertisement, never a physical-write grant.
-- Existing upload rows/descriptors remain readable while new ingress is paused.
create function public.v1_reader_capabilities() returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); suspended boolean; result jsonb;
begin
 select spending_suspended into suspended from app_private.accounts where id=a and closed_at is null for key share;
 if not found then raise exception 'account_unavailable' using errcode='42501'; end if;
 perform public.worker_consume_request(a,'library-read');
 select jsonb_build_object('format',1,'account_id',a,
  'library',jsonb_build_object('endpoint_family','full-v5','wire_format',2,'source_level',4,'dataset_epoch',v.upload_dataset_epoch),
  'descriptors',jsonb_build_object('format',1,'maximum_batch',24),
  'uploads',jsonb_build_object('protocol','upload-chunks-v1',
   'enabled',u.enabled and not suspended and p.enforced and p.inventory_scope=2 and p.inventory_verified_at is not null
    and p.inventory_discrepancies=0 and p.reconciliation_id is null,
   'chunk_bytes',u.chunk_bytes,'maximum_bytes',67108864,'maximum_parts',16,'part_attempts',u.part_attempts))
 into result from app_private.library_v4_config v cross join app_private.pdf_upload_policy u cross join app_private.paper_asset_policy p
 where v.singleton and u.singleton and p.singleton;
 if result is null then raise exception 'reader_capabilities_unavailable'; end if;
 perform app_private.consume_library_transfer(a,result);
 return result;
end $$;

revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
revoke all on function public.v2_library_page(jsonb,integer) from public,anon,authenticated,service_role;
grant execute on function public.v2_library_page(jsonb,integer) to authenticated;
revoke all on function public.v2_library_changes(bigint,bigint,integer) from public,anon,authenticated,service_role;
grant execute on function public.v2_library_changes(bigint,bigint,integer) to authenticated;
revoke all on function public.v3_library_page(jsonb,integer) from public,anon,authenticated,service_role;
grant execute on function public.v3_library_page(jsonb,integer) to authenticated;
revoke all on function public.v3_library_changes(bigint,bigint,integer) from public,anon,authenticated,service_role;
grant execute on function public.v3_library_changes(bigint,bigint,integer) to authenticated;
revoke all on function public.v5_library_page(jsonb,integer) from public,anon,authenticated,service_role;
grant execute on function public.v5_library_page(jsonb,integer) to authenticated;
revoke all on function public.v5_library_changes(uuid,bigint,bigint,integer) from public,anon,authenticated,service_role;
grant execute on function public.v5_library_changes(uuid,bigint,bigint,integer) to authenticated;
revoke all on function public.v5_library_compact_page(jsonb,integer) from public,anon,authenticated,service_role;
grant execute on function public.v5_library_compact_page(jsonb,integer) to authenticated;
revoke all on function public.v5_library_compact_changes(uuid,bigint,bigint,integer) from public,anon,authenticated,service_role;
grant execute on function public.v5_library_compact_changes(uuid,bigint,bigint,integer) to authenticated;
revoke all on function public.v5_library_metadata(uuid,uuid[]) from public,anon,authenticated,service_role;
grant execute on function public.v5_library_metadata(uuid,uuid[]) to authenticated;
revoke all on function public.v5_library_query(jsonb,jsonb,integer) from public,anon,authenticated,service_role;
grant execute on function public.v5_library_query(jsonb,jsonb,integer) to authenticated;
revoke all on function public.v1_reader_capabilities() from public,anon,authenticated,service_role;
grant execute on function public.v1_reader_capabilities() to authenticated;

do $$ declare n text; begin
 foreach n in array array['pdf_upload_parts','pdf_upload_holds','pdf_upload_write_attempts','pdf_upload_delete_batches','pdf_upload_delete_members','pdf_upload_reads'] loop
 execute format('alter table app_private.%I enable row level security',n);
 execute format('revoke all on app_private.%I from public,anon,authenticated,service_role',n);
 end loop; end $$;

revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
do $$ declare f record; begin
 for f in select p.oid::regprocedure signature,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
 and p.proname in ('v1_append_event','v1_put_library_descriptor','v1_library_descriptors','worker_begin_pdf_upload','worker_pdf_upload_status','worker_pdf_upload_part','worker_pdf_upload_write','worker_pdf_upload_written',
  'worker_pdf_upload_read','worker_pdf_upload_reconciliation','worker_pdf_upload_read_observed','worker_freeze_pdf_upload','worker_cancel_pdf_upload','worker_pdf_upload_policy','worker_finalize_pdf_upload','v1_import_pdf_sources','worker_pipeline_upload_original',
  'worker_pipeline_upload_rejected','worker_claim_stale_pdf_uploads','worker_confirm_pdf_uploads_deleted','v5_library_page','v5_library_changes',
  'worker_pipeline_web_metadata','worker_pipeline_sync_imports','worker_resolve_import','worker_delete_account_begin','worker_delete_account_finish',
  'worker_pipeline_admit_download','worker_asset_spending_status','worker_asset_inventory_begin','worker_asset_inventory_page','worker_asset_inventory_finish',
  'v1_sync_usage','v1_admin_overview') loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
  execute format('grant execute on function %s to %I',f.signature,case when f.proname like 'worker_%' then 'service_role' else 'authenticated' end);
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
