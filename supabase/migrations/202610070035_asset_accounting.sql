-- Complete paper-object inventory, conservative upload liability and metered
-- member delivery. Hosted enforcement requires the documented worker/client
-- transition and complete legacy inventory reconciliation.
begin;

create table app_private.paper_asset_policy (
 singleton boolean primary key default true check(singleton),
 enforced boolean not null default false,
 reconciliation_id uuid,
 inventory_verified_at timestamptz,
 inventory_discrepancies bigint not null default 0 check(inventory_discrepancies>=0),
 check(not enforced or (inventory_verified_at is not null and inventory_discrepancies=0))
);
insert into app_private.paper_asset_policy default values;
create table app_private.paper_asset_inventory_scans (
 id uuid primary key, started_at timestamptz not null default clock_timestamp(), finished_at timestamptz,
 object_count bigint, byte_count bigint, discrepancies jsonb, report_sha256 bytea,
 check(object_count is null or object_count between 0 and 50000), check(byte_count is null or byte_count>=0),
 check(report_sha256 is null or octet_length(report_sha256)=32)
);
create table app_private.paper_asset_holds (
 paper_id uuid not null references app_private.pipeline_papers(id),
 kind text not null check(kind in ('original','raw','reader')),
 owner_id uuid references app_private.accounts(id),
 bytes bigint not null check(bytes>0), objects integer not null check(objects>0),
 created_at timestamptz not null default clock_timestamp(), primary key(paper_id,kind)
);
create table app_private.paper_asset_uploads (
 id uuid primary key, paper_id uuid not null references app_private.pipeline_papers(id),
 claim_id uuid not null, generation bigint not null, kind text not null check(kind in ('original','raw','reader')),
 document_id uuid not null references app_private.documents(id),
 manifest_object_id uuid references app_private.stored_objects(id),
 request_sha256 bytea not null check(octet_length(request_sha256)=32),
 created_at timestamptz not null default clock_timestamp(), completed_at timestamptz
);
create index paper_asset_uploads_paper on app_private.paper_asset_uploads(paper_id,created_at);
create table app_private.paper_asset_upload_members (
 upload_id uuid not null references app_private.paper_asset_uploads(id),
 object_id uuid not null references app_private.stored_objects(id),
 primary key(upload_id,object_id)
);
create table app_private.paper_asset_write_attempts (
 id uuid primary key, upload_id uuid not null references app_private.paper_asset_uploads(id),
 object_id uuid not null references app_private.stored_objects(id),
 started_at timestamptz not null default clock_timestamp(), finished_at timestamptz,
 outcome text check(outcome in ('verified','not_written')),
 check((finished_at is null)=(outcome is null))
);
create index paper_asset_write_unresolved on app_private.paper_asset_write_attempts(object_id,started_at) where finished_at is null;
create table app_private.paper_asset_manifest_members (
 manifest_object_id uuid not null references app_private.stored_objects(id),
 object_id uuid not null references app_private.stored_objects(id),
 relative_path text not null check(relative_path ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,239}$' and relative_path !~ '(^|/)\.\.(/|$)'),
 primary key(manifest_object_id,relative_path), unique(manifest_object_id,object_id), check(manifest_object_id<>object_id)
);
create trigger paper_manifest_member_immutable before update or delete on app_private.paper_asset_manifest_members
 for each row execute function app_private.immutable_record();

-- Private uploads take account KEY SHARE before the paper/capacity locks.
-- Deletion takes account FOR UPDATE then paper, so it either sees the entire
-- plan/write admission or prevents it; owner FK checks cannot invert order.
create function app_private.paper_asset_lock_owner(p_paper_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare owner uuid;
begin
 select owner_id into owner from app_private.pipeline_papers where id=p_paper_id;
 if not found then raise exception 'stale_pipeline_claim'; end if;
 if owner is not null then
  perform 1 from app_private.accounts where id=owner and closed_at is null and not spending_suspended for key share;
  if not found then raise exception 'account_unavailable'; end if;
 end if;
end $$;

-- Capacity serializes on paper_storage_capacity. A pending/deleting inventory
-- row is still a possible physical object and never frees space on timeout.
create function app_private.paper_asset_check_capacity(p_owner uuid) returns void
language plpgsql security definer set search_path='' as $$
declare cap app_private.paper_storage_capacity; used bigint; n bigint; owned bigint; owner_cap bigint;
begin
 select * into strict cap from app_private.paper_storage_capacity where singleton for update;
 select coalesce(sum(byte_count),0),count(*) into used,n from app_private.stored_objects where bucket='paper-assets' and state<>'deleted';
 select used+coalesce(sum(bytes),0),n+coalesce(sum(objects),0) into used,n from app_private.paper_asset_holds;
 if used>cap.max_bytes or n>cap.max_objects then raise exception 'paper_storage_capacity'; end if;
 if p_owner is not null then
  select coalesce(sum(o.byte_count),0) into owned from app_private.stored_objects o join app_private.documents d on d.id=o.document_id
   where o.bucket='paper-assets' and o.state<>'deleted' and d.owner_id=p_owner;
  select owned+coalesce(sum(bytes),0) into owned from app_private.paper_asset_holds where owner_id=p_owner;
  select private_bytes_per_owner into strict owner_cap from app_private.pipeline_policy where singleton;
  if owned>owner_cap then raise exception 'paper_owner_storage_capacity'; end if;
 end if;
end $$;
create function app_private.paper_asset_reserve(p app_private.pipeline_papers,p_original boolean) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p.owner_id is not null and not exists(select 1 from app_private.accounts where id=p.owner_id and closed_at is null and not spending_suspended)
 then raise exception 'account_unavailable'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 if p_original then
  insert into app_private.paper_asset_holds(paper_id,kind,owner_id,bytes,objects)
   select p.id,'original',p.owner_id,max_pdf_bytes,1 from app_private.pipeline_policy on conflict do nothing;
 end if;
 insert into app_private.paper_asset_holds(paper_id,kind,owner_id,bytes,objects)
  values(p.id,'raw',p.owner_id,58982400,4),(p.id,'reader',p.owner_id,33816576,513) on conflict do nothing;
 perform app_private.paper_asset_check_capacity(p.owner_id);
end $$;

alter function public.worker_pipeline_admit_download(uuid,uuid,bigint) set schema app_private;
create function public.worker_pipeline_admit_download(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; result jsonb;
begin
 perform app_private.paper_asset_lock_owner(p_paper_id);
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 result:=app_private.worker_pipeline_admit_download(p_paper_id,p_claim_id,p_generation);
 if coalesce((result->>'admitted')::boolean,false) then
  begin perform app_private.paper_asset_reserve(p,true);
  exception when raise_exception then
   if sqlerrm not in ('paper_storage_capacity','paper_owner_storage_capacity') then raise; end if;
   update app_private.pipeline_papers set next_attempt_at=clock_timestamp()+interval '1 hour',error_code='storage_full' where id=p.id;
   return jsonb_build_object('admitted',false,'reason','storage_full');
  end;
 end if;
 return result;
end $$;

alter function public.worker_pipeline_fund(uuid,uuid,bigint,integer,bytea,bytea) set schema app_private;
create function public.worker_pipeline_admit_processing(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns void
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers;
begin
 perform app_private.paper_asset_lock_owner(p_paper_id);
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'ocr_fund' then raise exception 'invalid_pipeline_stage'; end if;
 perform app_private.paper_asset_reserve(p,false);
end $$;
create function public.worker_pipeline_fund(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_page_limit integer,
 p_options_sha256 bytea,p_request_sha256 bytea) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 -- The durable reservation is a preceding transaction. The underlying 034
 -- funder owns account-snapshot locking and the paper fence; do not pre-lock the
 -- paper or capacity here. Maintenance never releases holds of an active claim.
 if (select enforced from app_private.paper_asset_policy where singleton) and
  (select count(*) from app_private.paper_asset_holds where paper_id=p_paper_id and kind in ('raw','reader'))<>2
 then raise exception 'asset_reservation_required'; end if;
 return app_private.worker_pipeline_fund(p_paper_id,p_claim_id,p_generation,p_page_limit,p_options_sha256,p_request_sha256);
end $$;

-- Exact immutable inventory precedes every physical write. Only the service
-- worker supplies this bounded content list; clients have no mutation grants.
create function public.worker_pipeline_asset_plan(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_upload_id uuid,
 p_kind text,p_objects jsonb,p_pages integer default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; d app_private.documents; u app_private.paper_asset_uploads; o app_private.stored_objects;
 row jsonb; total bigint:=0; n integer; digest bytea; object_path text; manifest_path text; manifest_id uuid; member_ids uuid[]:='{}';
 request_digest bytea; ceiling bigint; slots integer;
begin
 perform app_private.paper_asset_lock_owner(p_paper_id);
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p_upload_id is null or p_kind is null or p_kind not in ('original','raw','reader') or p_objects is null or jsonb_typeof(p_objects)<>'array'
  or octet_length(p_objects::text)>262144 then raise exception 'invalid_asset_plan'; end if;
 if (p_kind='original' and p.stage<>'download') or (p_kind='raw' and p.stage<>'ocr_wait') or (p_kind='reader' and p.stage<>'render')
 then raise exception 'invalid_pipeline_stage'; end if;
 if p.owner_id is not null and not exists(select 1 from app_private.accounts where id=p.owner_id and closed_at is null and not spending_suspended)
 then raise exception 'account_unavailable'; end if;
 request_digest:=sha256(convert_to(jsonb_build_array(p_paper_id,p_claim_id,p_generation,p_kind,p_objects,p_pages)::text,'UTF8'));
 select * into u from app_private.paper_asset_uploads where id=p_upload_id;
 if found then
  if u.request_sha256<>request_digest then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('upload_id',u.id,'objects',(select jsonb_agg(jsonb_build_object('id',s.id,'path',s.path,'verified',s.state='verified') order by s.path)
   from app_private.paper_asset_upload_members m join app_private.stored_objects s on s.id=m.object_id where m.upload_id=u.id));
 end if;
 n:=jsonb_array_length(p_objects);
 ceiling:=case p_kind when 'original' then 67108864 when 'raw' then 58982400 else 33816576 end;
 slots:=case p_kind when 'original' then 1 when 'raw' then 4 else 513 end;
 if n not between 1 and slots or (p_kind='raw' and n<>4) or (p_kind='reader' and n<2)
  or (select count(distinct value->>'path') from jsonb_array_elements(p_objects))<>n then raise exception 'invalid_asset_plan'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 if p_kind='original' then
  row:=p_objects->0;
  if n<>1 or p_pages is null or p_pages not between 1 and 250 or (row->>'sha256') !~ '^[0-9a-f]{64}$'
   or row->>'media_type'<>'application/pdf' or coalesce(p.eligible,false)=(p.owner_id is not null) then raise exception 'invalid_asset_plan'; end if;
  digest:=decode(row->>'sha256','hex');
  if p.owner_id is null then select * into d from app_private.documents where scope='shared_catalog' and sha256=digest;
  else select * into d from app_private.documents where owner_id=p.owner_id and sha256=digest; end if;
  if not found then
   insert into app_private.documents(sha256,scope,owner_id,reuse_evidence,byte_count,page_count)
    values(digest,case when p.owner_id is null then 'shared_catalog' else 'owner_private' end,p.owner_id,
     case when p.owner_id is null then p.evidence else null end,(row->>'bytes')::bigint,p_pages) returning * into d;
  end if;
  if d.byte_count<>(row->>'bytes')::bigint then raise exception 'asset_identity_conflict'; end if;
  manifest_path:=case when p.owner_id is null then '' else 'private/'||p.owner_id::text||'/' end||'originals/'||encode(digest,'hex')||'.pdf';
 else
  select * into strict d from app_private.documents where id=p.document_id;
  select value->>'path' into manifest_path from jsonb_array_elements(p_objects)
   where value->>'path' ~ ('^'||p_kind||'/[0-9a-f]{64}/manifest\.json$');
  if manifest_path is null or (select count(*) from jsonb_array_elements(p_objects) where value->>'path'=manifest_path)<>1 then raise exception 'invalid_asset_plan'; end if;
 end if;
 insert into app_private.paper_asset_uploads(id,paper_id,claim_id,generation,kind,document_id,request_sha256)
 values(p_upload_id,p.id,p_claim_id,p_generation,p_kind,d.id,request_digest);
 for row in select value from jsonb_array_elements(p_objects) loop
  object_path:=row->>'path';
  if object_path is null or length(object_path)>400 or object_path !~ '^[A-Za-z0-9][A-Za-z0-9._/-]*$' or object_path ~ '(^|/)\.\.(/|$)'
   or (row->>'sha256') !~ '^[0-9a-f]{64}$' or coalesce((row->>'bytes')::bigint,0) not between 1 and 67108864
   or row->>'media_type' is null or length(row->>'media_type')>120 then raise exception 'invalid_asset_plan'; end if;
  if (p_kind='original' and object_path<>manifest_path) or (p_kind<>'original' and not starts_with(object_path,regexp_replace(manifest_path,'manifest\.json$','')))
   or (object_path=manifest_path and p_kind<>'original' and ((row->>'bytes')::bigint>262144 or row->>'sha256'<>split_part(object_path,'/',2)))
  then raise exception 'invalid_asset_plan'; end if;
  if p_kind='reader' and object_path<>manifest_path and (row->>'bytes')::bigint>16777216 then raise exception 'invalid_asset_plan'; end if;
  if p_kind='raw' and object_path<>manifest_path and
   (case regexp_replace(object_path,'^raw/[0-9a-f]{64}/','') when 'standalone.mmd' then (row->>'bytes')::bigint>8388608
    when 'output.mmd.zip' then (row->>'bytes')::bigint>33554432 when 'lines.json' then (row->>'bytes')::bigint>16777216 else true end)
  then raise exception 'invalid_asset_plan'; end if;
  total:=total+(row->>'bytes')::bigint;
  select * into o from app_private.stored_objects where bucket='paper-assets' and stored_objects.path=object_path for update;
  if not found then
   insert into app_private.stored_objects(bucket,path,document_id,sha256,byte_count,media_type)
    values('paper-assets',object_path,d.id,decode(row->>'sha256','hex'),(row->>'bytes')::bigint,lower(btrim(split_part(row->>'media_type',';',1)))) returning * into o;
  elsif o.document_id<>d.id or o.sha256<>decode(row->>'sha256','hex') or o.byte_count<>(row->>'bytes')::bigint
   or o.media_type<>lower(btrim(split_part(row->>'media_type',';',1))) or o.state not in ('pending','verified') then raise exception 'asset_identity_conflict'; end if;
  member_ids:=array_append(member_ids,o.id);
  insert into app_private.paper_asset_upload_members(upload_id,object_id) values(p_upload_id,o.id);
  if object_path=manifest_path then manifest_id:=o.id; end if;
 end loop;
 if total>ceiling or manifest_id is null then raise exception 'invalid_asset_plan'; end if;
 delete from app_private.paper_asset_holds where paper_id=p.id and kind=p_kind;
 perform app_private.paper_asset_check_capacity(p.owner_id);
 update app_private.paper_asset_uploads set manifest_object_id=manifest_id where id=p_upload_id;
 if p_kind<>'original' then
  insert into app_private.paper_asset_manifest_members(manifest_object_id,object_id,relative_path)
   select manifest_id,id,substr(stored_objects.path,length(regexp_replace(manifest_path,'manifest\.json$',''))+1)
   from app_private.stored_objects where id=any(member_ids) and id<>manifest_id on conflict do nothing;
  if exists(select 1 from app_private.paper_asset_manifest_members where manifest_object_id=manifest_id and not(object_id=any(member_ids)))
  then raise exception 'asset_manifest_conflict'; end if;
 end if;
 return jsonb_build_object('upload_id',p_upload_id,'objects',(select jsonb_agg(jsonb_build_object('id',id,'path',stored_objects.path,'verified',state='verified') order by stored_objects.path)
  from app_private.stored_objects where id=any(member_ids)));
end $$;

create function public.worker_pipeline_asset_write(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_upload_id uuid,p_object_id uuid,p_attempt_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; o app_private.stored_objects; u app_private.paper_asset_uploads;
begin
 perform app_private.paper_asset_lock_owner(p_paper_id);
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.owner_id is not null and not exists(select 1 from app_private.accounts where id=p.owner_id and closed_at is null and not spending_suspended)
 then raise exception 'account_unavailable'; end if;
 select * into strict u from app_private.paper_asset_uploads where id=p_upload_id and paper_id=p.id and claim_id=p_claim_id and generation=p_generation;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 select s.* into strict o from app_private.stored_objects s join app_private.paper_asset_upload_members m on m.object_id=s.id
  where m.upload_id=u.id and s.id=p_object_id for update of s;
 if o.state='verified' then return jsonb_build_object('write',false,'verified',true); end if;
 if o.state<>'pending' then raise exception 'asset_unavailable'; end if;
 if exists(select 1 from app_private.paper_asset_write_attempts where object_id=o.id and finished_at is null)
 then return jsonb_build_object('write',false,'verified',false,'reason','asset_write_uncertain'); end if;
 insert into app_private.paper_asset_write_attempts(id,upload_id,object_id) values(p_attempt_id,u.id,o.id);
 return jsonb_build_object('write',true,'verified',false);
end $$;

-- A late response can reconcile the exact issued write, but cannot publish a
-- stale paper. Unknown/lost responses remain inventoried and block deletion.
create function public.worker_pipeline_asset_written(p_attempt_id uuid,p_verified boolean) returns void
language plpgsql security definer set search_path='' as $$
declare w app_private.paper_asset_write_attempts; o app_private.stored_objects;
begin
 if p_verified is distinct from true then raise exception 'asset_write_proof_required'; end if;
 select * into strict w from app_private.paper_asset_write_attempts where id=p_attempt_id for update;
 if w.finished_at is not null then
  if (w.outcome='verified') is distinct from p_verified then raise exception 'asset_write_conflict'; end if;
  return;
 end if;
 select * into strict o from app_private.stored_objects where id=w.object_id for update;
 if p_verified and o.state='pending' then update app_private.stored_objects set state='verified',verified_at=clock_timestamp() where id=o.id;
 elsif p_verified and o.state not in ('verified','deleting') then raise exception 'asset_unavailable'; end if;
 update app_private.paper_asset_write_attempts set finished_at=clock_timestamp(),outcome=case when p_verified then 'verified' else 'not_written' end where id=w.id;
end $$;

create function app_private.paper_asset_require_complete(p_paper uuid,p_claim uuid,p_generation bigint,p_kind text,p_path text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not (select enforced from app_private.paper_asset_policy where singleton) then return; end if;
 if not exists(select 1 from app_private.paper_asset_uploads u join app_private.stored_objects o on o.id=u.manifest_object_id
   where u.paper_id=p_paper and u.claim_id=p_claim and u.generation=p_generation and u.kind=p_kind and o.path=p_path and o.state='verified'
    and not exists(select 1 from app_private.paper_asset_upload_members m join app_private.stored_objects s on s.id=m.object_id
     where m.upload_id=u.id and s.state<>'verified')
    and not exists(select 1 from app_private.paper_asset_write_attempts w where w.upload_id=u.id and w.finished_at is null))
 then raise exception 'asset_inventory_incomplete'; end if;
end $$;

alter function public.worker_pipeline_original(uuid,uuid,bigint,bytea,bigint,integer,text) set schema app_private;
create function public.worker_pipeline_original(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_sha256 bytea,p_bytes bigint,p_pages integer,p_path text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform app_private.paper_asset_lock_owner(p_paper_id);
 perform app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 perform 1 from app_private.documents d join app_private.stored_objects o on o.document_id=d.id
  where o.bucket='paper-assets' and o.path=p_path for update of d;
 perform app_private.paper_asset_require_complete(p_paper_id,p_claim_id,p_generation,'original',p_path);
 perform app_private.mark_paper_availability(id,'available') from app_private.stored_objects where path=p_path and state='verified';
 result:=app_private.worker_pipeline_original(p_paper_id,p_claim_id,p_generation,p_sha256,p_bytes,p_pages,p_path);
 update app_private.paper_asset_uploads set completed_at=coalesce(completed_at,clock_timestamp()) where paper_id=p_paper_id and claim_id=p_claim_id and generation=p_generation and kind='original';
 if result->>'stage'='done' then delete from app_private.paper_asset_holds where paper_id=p_paper_id; end if;
 return result;
end $$;
alter function public.worker_pipeline_collected(uuid,uuid,bigint,integer,bytea,bigint) set schema app_private;
create function public.worker_pipeline_collected(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_pages_reported integer,p_raw_manifest_sha256 bytea,p_raw_manifest_bytes bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform app_private.pipeline_money_lock(p_paper_id);
 perform app_private.paper_asset_require_complete(p_paper_id,p_claim_id,p_generation,'raw','raw/'||encode(p_raw_manifest_sha256,'hex')||'/manifest.json');
 result:=app_private.worker_pipeline_collected(p_paper_id,p_claim_id,p_generation,p_pages_reported,p_raw_manifest_sha256,p_raw_manifest_bytes);
 update app_private.paper_asset_uploads set completed_at=coalesce(completed_at,clock_timestamp()) where paper_id=p_paper_id and claim_id=p_claim_id and generation=p_generation and kind='raw';
 return result;
end $$;
alter function public.worker_pipeline_published(uuid,uuid,bigint,bytea,bigint,text) set schema app_private;
create function public.worker_pipeline_published(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_manifest_sha256 bytea,p_manifest_bytes bigint,p_renderer_version text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform app_private.paper_asset_lock_owner(p_paper_id);
 perform app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 perform 1 from app_private.documents d join app_private.stored_objects o on o.document_id=d.id
  where o.bucket='paper-assets' and o.path='reader/'||encode(p_manifest_sha256,'hex')||'/manifest.json' for update of d;
 perform app_private.paper_asset_require_complete(p_paper_id,p_claim_id,p_generation,'reader','reader/'||encode(p_manifest_sha256,'hex')||'/manifest.json');
 perform app_private.mark_paper_availability(id,'available') from app_private.stored_objects
  where path='reader/'||encode(p_manifest_sha256,'hex')||'/manifest.json' and state='verified';
 result:=app_private.worker_pipeline_published(p_paper_id,p_claim_id,p_generation,p_manifest_sha256,p_manifest_bytes,p_renderer_version);
 update app_private.paper_asset_uploads set completed_at=coalesce(completed_at,clock_timestamp()) where paper_id=p_paper_id and claim_id=p_claim_id and generation=p_generation and kind='reader';
 delete from app_private.paper_asset_holds where paper_id=p_paper_id;
 return result;
end $$;

-- Finish cannot certify private erasure while an issued upload is unresolved.
alter function public.worker_delete_account_finish(uuid) set schema app_private;
create function public.worker_delete_account_finish(p_account_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from app_private.paper_asset_write_attempts w join app_private.stored_objects o on o.id=w.object_id
  join app_private.documents d on d.id=o.document_id where d.owner_id=p_account_id and w.finished_at is null)
 then raise exception 'asset_write_uncertain'; end if;
 delete from app_private.paper_asset_holds where owner_id=p_account_id;
 return app_private.worker_delete_account_finish(p_account_id);
end $$;

create table app_private.reader_delivery_policy (
 singleton boolean primary key default true check(singleton),
 mode text not null default 'legacy' check(mode in ('legacy','dual','bounded')),
 account_bytes_month bigint not null default 268435456 check(account_bytes_month>0),
 environment_bytes_month bigint not null default 2147483648 check(environment_bytes_month>0),
 backend_account_bytes_month bigint not null default 268435456 check(backend_account_bytes_month>0),
 backend_environment_bytes_month bigint not null default 2147483648 check(backend_environment_bytes_month>0),
 legacy_last_issued_at timestamptz, legacy_descriptors bigint not null default 0 check(legacy_descriptors>=0)
);
insert into app_private.reader_delivery_policy default values;
create table app_private.reader_transfer_months (
 period date not null, scope_id text not null, kind text not null check(kind in ('reader','backend')),
 reserved_bytes bigint not null default 0 check(reserved_bytes>=0),
 authorized_bytes bigint not null default 0 check(authorized_bytes>=0),
 upstream_bytes bigint not null default 0 check(upstream_bytes>=0),
 response_bytes bigint not null default 0 check(response_bytes>=0),
 primary key(period,scope_id,kind)
);
create table app_private.reader_delivery_grants (
 id uuid primary key default gen_random_uuid(), token_sha256 bytea not null unique check(octet_length(token_sha256)=32),
 account_id uuid not null references app_private.accounts(id), item_id uuid not null,
 artifact_id uuid not null references app_private.render_artifacts(id), manifest_object_id uuid not null references app_private.stored_objects(id),
 period date not null, byte_ceiling bigint not null check(byte_ceiling between 1 and 33554432),
 remaining_bytes bigint not null check(remaining_bytes>=0),
 created_at timestamptz not null default clock_timestamp(), expires_at timestamptz not null, expired_at timestamptz,
 check(remaining_bytes<=byte_ceiling)
);
create index reader_delivery_expiry on app_private.reader_delivery_grants(expires_at) where expired_at is null;
create table app_private.reader_delivery_redemptions (
 grant_id uuid not null references app_private.reader_delivery_grants(id), object_id uuid not null references app_private.stored_objects(id),
 byte_ceiling bigint not null check(byte_ceiling>0), created_at timestamptz not null default clock_timestamp(),
 upstream_bytes bigint check(upstream_bytes>=0), response_bytes bigint check(response_bytes>=0),
 observation text check(observation in ('response_created','upstream_failed','integrity_failed','cancelled')),
 observed_at timestamptz, primary key(grant_id,object_id),
 check(upstream_bytes is null or upstream_bytes<=byte_ceiling), check(response_bytes is null or response_bytes<=byte_ceiling)
);

create function app_private.reader_transfer_adjust(p_account uuid,p_period date,p_kind text,p_reserved bigint,p_authorized bigint,
 p_upstream bigint default 0,p_response bigint default 0) returns void
language plpgsql security definer set search_path='' as $$
declare pol app_private.reader_delivery_policy; r app_private.reader_transfer_months; s text; maximum bigint;
begin
 select * into strict pol from app_private.reader_delivery_policy where singleton for update;
 foreach s in array array['environment',p_account::text] loop
  maximum:=case when p_kind='backend' then case when s='environment' then pol.backend_environment_bytes_month else pol.backend_account_bytes_month end
   else case when s='environment' then pol.environment_bytes_month else pol.account_bytes_month end end;
  insert into app_private.reader_transfer_months(period,scope_id,kind) values(p_period,s,p_kind) on conflict do nothing;
  update app_private.reader_transfer_months set reserved_bytes=reserved_bytes+p_reserved,authorized_bytes=authorized_bytes+p_authorized,
   upstream_bytes=upstream_bytes+p_upstream,response_bytes=response_bytes+p_response where (period,scope_id,kind)=(p_period,s,p_kind) returning * into r;
  -- Reducing a policy must not make expiry, observation or account erasure
  -- fail because already-admitted traffic exceeds the new allowance.
  if p_reserved+p_authorized>0 and r.reserved_bytes+r.authorized_bytes>maximum then raise exception 'reader_transfer_limit'; end if;
 end loop;
end $$;

-- Bounded maintenance: return unused issuance reservations, but never refund
-- an actual redemption whose network outcome can be unknown.
create function public.worker_reader_delivery_expire(p_limit integer default 100) returns integer
language plpgsql security definer set search_path='' as $$
declare g app_private.reader_delivery_grants; n integer:=0;
begin
 if p_limit is null or p_limit not between 1 and 1000 then raise exception 'invalid_limit'; end if;
 perform 1 from app_private.reader_delivery_policy where singleton for update;
 for g in select * from app_private.reader_delivery_grants where expires_at<=clock_timestamp() and expired_at is null
  order by expires_at,id limit p_limit for update skip locked loop
  perform app_private.reader_transfer_adjust(g.account_id,g.period,'reader',-g.remaining_bytes,0);
  update app_private.reader_delivery_grants set remaining_bytes=0,expired_at=clock_timestamp() where id=g.id;
  n:=n+1;
 end loop;
 return n;
end $$;

-- Remove only future phase reservations of stopped, unclaimed jobs. Planned
-- pending/verified/deleting objects and unresolved writes remain inventoried.
-- A retry must pass admission/its exact upload plan again before any write.
create function public.worker_asset_maintenance(p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; released integer:=0; n integer; expired integer;
begin
 if p_limit is null or p_limit not between 1 and 1000 then raise exception 'invalid_limit'; end if;
 -- Match deletion's paper -> capacity -> reader-policy ordering. SKIP LOCKED
 -- avoids holding capacity while waiting on the next actively claimed paper.
 for p in select pp.* from app_private.pipeline_papers pp
  where pp.claim_id is null and pp.stage in ('failed','source_only','done')
   and exists(select 1 from app_private.paper_asset_holds h where h.paper_id=pp.id)
  order by pp.id limit p_limit for update of pp skip locked loop
  perform 1 from app_private.paper_storage_capacity where singleton for update;
  if not (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then
   delete from app_private.paper_asset_holds where paper_id=p.id;
   get diagnostics n=row_count; released:=released+n;
  end if;
 end loop;
 expired:=public.worker_reader_delivery_expire(p_limit);
 return jsonb_build_object('future_holds_released',released,'delivery_grants_expired',expired);
end $$;

create function public.worker_reader_delivery_create(p_account_id uuid,p_item_id uuid,p_token_sha256 bytea,p_transport text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.reader_delivery_policy; descriptor jsonb; manifest_id uuid; total bigint; g app_private.reader_delivery_grants;
 month date:=date_trunc('month',clock_timestamp() at time zone 'UTC')::date; expiry timestamptz;
begin
 -- Account before policy, matching deletion. No pipeline/document write lock.
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended for key share;
 if not found then raise exception 'account_unavailable'; end if;
 if p_transport is null or p_transport not in ('legacy','bounded-v1') or p_token_sha256 is null or octet_length(p_token_sha256)<>32 then raise exception 'invalid_reader_transport'; end if;
 select * into strict pol from app_private.reader_delivery_policy where singleton for update;
 if pol.mode='bounded' and p_transport='legacy' then raise exception 'reader_upgrade_required'; end if;
 if pol.mode='legacy' and p_transport='bounded-v1' then p_transport:='legacy'; end if;
 descriptor:=public.worker_reader_descriptor(p_account_id,p_item_id);
 if p_transport='legacy' then
  update app_private.reader_delivery_policy set legacy_last_issued_at=clock_timestamp(),legacy_descriptors=legacy_descriptors+1 where singleton;
  return descriptor||jsonb_build_object('transport','legacy');
 end if;
 -- A descriptor-only request still causes a manifest Storage GET and a JSON
 -- response. Charge both ceilings even if none of its members is redeemed.
 perform app_private.reader_transfer_adjust(p_account_id,month,'backend',0,(descriptor->>'manifest_bytes')::bigint);
 perform app_private.reader_transfer_adjust(p_account_id,month,'reader',0,1048576);
 select id into strict manifest_id from app_private.stored_objects where path=descriptor->>'manifest_path' and state='verified';
 select sum(o.byte_count) into total from app_private.paper_asset_manifest_members m join app_private.stored_objects o on o.id=m.object_id
  where m.manifest_object_id=manifest_id and o.state='verified';
 if total is null or total not between 1 and 33554432 or
  exists(select 1 from app_private.paper_asset_manifest_members m join app_private.stored_objects o on o.id=m.object_id
   where m.manifest_object_id=manifest_id and o.state<>'verified') then raise exception 'asset_inventory_incomplete'; end if;
 perform public.worker_reader_delivery_expire(100);
 perform app_private.reader_transfer_adjust(p_account_id,month,'reader',total,0);
 expiry:=least(clock_timestamp()+interval '15 minutes',((month+interval '1 month')::timestamp at time zone 'UTC'));
 insert into app_private.reader_delivery_grants(token_sha256,account_id,item_id,artifact_id,manifest_object_id,period,byte_ceiling,remaining_bytes,expires_at)
 values(p_token_sha256,p_account_id,p_item_id,(descriptor->>'artifact_id')::uuid,manifest_id,month,total,total,expiry) returning * into g;
 return descriptor||jsonb_build_object('transport','bounded-v1','grant_id',g.id,'expires_at',g.expires_at,
  'members',(select jsonb_agg(jsonb_build_object('id',o.id,'path',m.relative_path,'sha256',encode(o.sha256,'hex'),'bytes',o.byte_count) order by m.relative_path)
   from app_private.paper_asset_manifest_members m join app_private.stored_objects o on o.id=m.object_id where m.manifest_object_id=manifest_id));
end $$;

create function public.worker_reader_delivery_redeem(p_account_id uuid,p_token_sha256 bytea,p_object_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare g app_private.reader_delivery_grants; o app_private.stored_objects;
begin
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended for key share;
 if not found then raise exception 'account_unavailable'; end if;
 perform 1 from app_private.reader_delivery_policy where singleton for update;
 select * into g from app_private.reader_delivery_grants where token_sha256=p_token_sha256 and account_id=p_account_id for update;
 if not found or g.expired_at is not null or g.expires_at<=clock_timestamp() then raise exception 'reader_grant_unavailable'; end if;
 if not exists(select 1 from app_private.library_items li join app_private.library_asset_projection ap on (ap.account_id,ap.item_id)=(li.account_id,li.id)
  join app_private.stored_objects mo on mo.id=g.manifest_object_id
  where li.account_id=p_account_id and li.id=g.item_id and li.artifact_id=g.artifact_id and li.removed_at is null
   and ap.render_availability='available' and mo.state='verified')
 then raise exception 'reader_grant_unavailable'; end if;
 select s.* into o from app_private.paper_asset_manifest_members m join app_private.stored_objects s on s.id=m.object_id
  where m.manifest_object_id=g.manifest_object_id and m.object_id=p_object_id and s.state='verified';
 if not found then raise exception 'reader_grant_unavailable'; end if;
 if exists(select 1 from app_private.reader_delivery_redemptions where grant_id=g.id and object_id=o.id) then raise exception 'reader_grant_consumed'; end if;
 perform app_private.reader_transfer_adjust(p_account_id,g.period,'reader',-o.byte_count,o.byte_count);
 insert into app_private.reader_delivery_redemptions(grant_id,object_id,byte_ceiling) values(g.id,o.id,o.byte_count);
 update app_private.reader_delivery_grants set remaining_bytes=remaining_bytes-o.byte_count where id=g.id;
 return jsonb_build_object('grant_id',g.id,'bucket',o.bucket,'path',o.path,'bytes',o.byte_count,'sha256',encode(o.sha256,'hex'),'media_type',o.media_type);
end $$;

create function public.worker_reader_delivery_observed(p_grant_id uuid,p_object_id uuid,p_upstream_bytes bigint,p_response_bytes bigint,p_observation text) returns void
language plpgsql security definer set search_path='' as $$
declare r app_private.reader_delivery_redemptions; g app_private.reader_delivery_grants;
begin
 perform 1 from app_private.reader_delivery_policy where singleton for update;
 select * into strict r from app_private.reader_delivery_redemptions where (grant_id,object_id)=(p_grant_id,p_object_id) for update;
 if p_upstream_bytes is null or p_response_bytes is null or p_upstream_bytes not between 0 and r.byte_ceiling
  or p_response_bytes not between 0 and r.byte_ceiling or p_observation is null or p_observation not in ('response_created','upstream_failed','integrity_failed','cancelled') then raise exception 'invalid_delivery_observation'; end if;
 if r.observed_at is not null then
  if (r.upstream_bytes,r.response_bytes,r.observation) is distinct from (p_upstream_bytes,p_response_bytes,p_observation) then raise exception 'delivery_observation_conflict'; end if;
  return;
 end if;
 select * into strict g from app_private.reader_delivery_grants where id=p_grant_id;
 perform app_private.reader_transfer_adjust(g.account_id,g.period,'reader',0,0,p_upstream_bytes,p_response_bytes);
 update app_private.reader_delivery_redemptions set upstream_bytes=p_upstream_bytes,response_bytes=p_response_bytes,
  observation=p_observation,observed_at=clock_timestamp() where (grant_id,object_id)=(p_grant_id,p_object_id);
end $$;

alter function public.worker_delete_account_begin(uuid) set schema app_private;
create function public.worker_delete_account_begin(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; g app_private.reader_delivery_grants;
begin
 result:=app_private.worker_delete_account_begin(p_account_id);
 -- Closure/fencing must commit even when an upload's outcome remains unknown.
 -- Do not authorize physical removal until every issued write has finished:
 -- a late successful upload after removal could otherwise recreate a file.
 if exists(select 1 from app_private.paper_asset_write_attempts w join app_private.stored_objects o on o.id=w.object_id
  join app_private.documents d on d.id=o.document_id where d.owner_id=p_account_id and w.finished_at is null)
 then result:=jsonb_build_object('account_id',p_account_id,'blocked','asset_write_uncertain','objects','[]'::jsonb,'prefixes','[]'::jsonb); end if;
 perform 1 from app_private.reader_delivery_policy where singleton for update;
 for g in select * from app_private.reader_delivery_grants where account_id=p_account_id for update loop
  if g.remaining_bytes>0 then perform app_private.reader_transfer_adjust(p_account_id,g.period,'reader',-g.remaining_bytes,0); end if;
  delete from app_private.reader_delivery_redemptions where grant_id=g.id;
 end loop;
 delete from app_private.reader_delivery_grants where account_id=p_account_id;
 delete from app_private.reader_transfer_months where scope_id=p_account_id::text;
 return result;
end $$;

alter function public.worker_chat_context(uuid,uuid) set schema app_private;
create function public.worker_chat_context(p_account_id uuid,p_document_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare descriptor jsonb; size bigint;
begin
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended for key share;
 if not found then raise exception 'account_unavailable'; end if;
 descriptor:=app_private.worker_chat_context(p_account_id,p_document_id);
 select byte_count into size from app_private.stored_objects where bucket=descriptor->>'bucket' and path=descriptor->>'path'
  and document_id=p_document_id and state='verified';
 if size is null then
  if (select enforced from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_incomplete'; end if;
  -- Explicitly conservative legacy admission until inventory reconciliation.
  size:=8388608;
 end if;
 perform app_private.reader_transfer_adjust(p_account_id,date_trunc('month',clock_timestamp() at time zone 'UTC')::date,'backend',0,size);
 return descriptor||jsonb_build_object('byte_count',size);
end $$;

create function public.worker_asset_spending_status() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'storage_policy',(select to_jsonb(p) from app_private.paper_asset_policy p where singleton),
  'delivery_policy',(select to_jsonb(p) from app_private.reader_delivery_policy p where singleton),
  'objects',coalesce((select jsonb_agg(r) from (select state,count(*) objects,sum(byte_count) bytes from app_private.stored_objects where bucket='paper-assets' group by state) r),'[]'),
  'reservations',coalesce((select jsonb_agg(r) from (select kind,count(*) holds,sum(bytes) bytes,sum(objects) objects from app_private.paper_asset_holds group by kind) r),'[]'),
  'unresolved_uploads',(select jsonb_build_object('count',count(*),'oldest',min(started_at)) from app_private.paper_asset_write_attempts where finished_at is null),
  'transfers',coalesce((select jsonb_agg(r) from (select * from app_private.reader_transfer_months where scope_id='environment' order by period desc,kind limit 24) r),'[]'),
  'unobserved_redemptions',(select count(*) from app_private.reader_delivery_redemptions where observed_at is null))
$$;

-- A whole-bucket reconciliation is an explicit, quiesced operator operation.
-- It does not make a speculative assertion about unowned or missing bytes.
create function public.worker_asset_inventory_begin(p_scan_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare active uuid;
begin
 if p_scan_id is null then raise exception 'invalid_inventory_scan'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select reconciliation_id into active from app_private.paper_asset_policy where singleton for update;
 if active=p_scan_id then return jsonb_build_object('scan_id',p_scan_id); end if;
 if active is not null then raise exception 'asset_inventory_reconciling'; end if;
 if (select enabled from app_private.pipeline_policy where singleton)
  or exists(select 1 from app_private.pipeline_papers where claim_id is not null)
  or exists(select 1 from app_private.paper_asset_write_attempts where finished_at is null)
 then raise exception 'asset_workers_not_drained'; end if;
 insert into app_private.paper_asset_inventory_scans(id) values(p_scan_id);
 update app_private.paper_asset_policy set reconciliation_id=p_scan_id,inventory_verified_at=case when enforced then inventory_verified_at else null end where singleton;
 return jsonb_build_object('scan_id',p_scan_id,'maximum_objects',50000,'maximum_bytes',(select max_bytes from app_private.paper_storage_capacity where singleton));
end $$;

create function public.worker_asset_inventory_page(p_scan_id uuid,p_after uuid default null,p_limit integer default 500) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if p_scan_id is null or p_limit is null or p_limit not between 1 and 500 or not exists(select 1 from app_private.paper_asset_policy where reconciliation_id=p_scan_id)
 then raise exception 'invalid_inventory_scan'; end if;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.id),'[]') into rows from
  (select o.id,o.path,o.document_id,encode(d.sha256,'hex') document_sha256,d.scope,d.owner_id,o.state,encode(o.sha256,'hex') sha256,o.byte_count bytes,o.media_type
   from app_private.stored_objects o join app_private.documents d on d.id=o.document_id
   where o.bucket='paper-assets' and o.state<>'deleted' and (p_after is null or o.id>p_after) order by o.id limit p_limit) r;
 return jsonb_build_object('objects',rows,'next_after',case when jsonb_array_length(rows)>0 then rows->-1->>'id' else null end,
  'has_more',jsonb_array_length(rows)=p_limit);
end $$;

create function public.worker_asset_inventory_manifest(p_scan_id uuid,p_manifest_id uuid,p_members jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare manifest app_private.stored_objects; d app_private.documents; o app_private.stored_objects; member jsonb; object_path text; total bigint:=0; ids uuid[]:='{}'; owner uuid;
begin
 if p_members is null or jsonb_typeof(p_members)<>'array' or jsonb_array_length(p_members) not between 1 and 512 or octet_length(p_members::text)>262144 then raise exception 'invalid_manifest_inventory'; end if;
 select d0.owner_id into owner from app_private.stored_objects o0 join app_private.documents d0 on d0.id=o0.document_id where o0.id=p_manifest_id;
 if owner is not null then
  perform 1 from app_private.accounts where id=owner and closed_at is null for key share;
  if not found then raise exception 'inventory_owner_closed'; end if;
 end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if not exists(select 1 from app_private.paper_asset_policy where reconciliation_id=p_scan_id) then raise exception 'invalid_inventory_scan'; end if;
 select * into strict manifest from app_private.stored_objects where id=p_manifest_id and bucket='paper-assets' and state='verified'
  and path ~ '^(raw|reader)/[0-9a-f]{64}/manifest\.json$';
 select * into strict d from app_private.documents where id=manifest.document_id;
 if d.owner_id is not null and not exists(select 1 from app_private.accounts where id=d.owner_id and closed_at is null) then raise exception 'inventory_owner_closed'; end if;
 for member in select value from jsonb_array_elements(p_members) loop
  if member->>'relative_path' is null or member->>'relative_path' !~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,239}$'
   or member->>'relative_path' ~ '(^|/)\.\.?(/|$)' or member->>'relative_path' like '%//%'
   or member->>'relative_path'='manifest.json' or member->>'sha256' is null or member->>'sha256' !~ '^[0-9a-f]{64}$'
   or coalesce((member->>'bytes')::bigint,0) not between 1 and 33554432 or member->>'media_type' is null or length(member->>'media_type')>120
  then raise exception 'invalid_manifest_inventory'; end if;
  object_path:=regexp_replace(manifest.path,'manifest\.json$','')||(member->>'relative_path');
  select * into o from app_private.stored_objects where path=object_path for update;
  if not found then
   insert into app_private.stored_objects(bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
    values('paper-assets',object_path,d.id,'verified',decode(member->>'sha256','hex'),(member->>'bytes')::bigint,lower(btrim(split_part(member->>'media_type',';',1))),clock_timestamp()) returning * into o;
  elsif o.document_id<>d.id or o.state<>'verified' or o.sha256<>decode(member->>'sha256','hex')
   or o.byte_count<>(member->>'bytes')::bigint or o.media_type<>lower(btrim(split_part(member->>'media_type',';',1))) then raise exception 'asset_identity_conflict'; end if;
  ids:=array_append(ids,o.id); total:=total+o.byte_count;
  insert into app_private.paper_asset_manifest_members(manifest_object_id,object_id,relative_path)
   values(manifest.id,o.id,member->>'relative_path') on conflict do nothing;
 end loop;
 if cardinality(ids)<>(select count(distinct x) from unnest(ids) x)
  or total>(case when starts_with(manifest.path,'reader/') then 33554432 else 58720256 end)
  or exists(select 1 from app_private.paper_asset_manifest_members where manifest_object_id=manifest.id and not(object_id=any(ids)))
 then raise exception 'invalid_manifest_inventory'; end if;
 -- Backfill records physical truth even if the old incomplete accounting hid
 -- over-capacity storage. Enforcement cannot be enabled until it fits.
end $$;

create function public.worker_asset_inventory_finish(p_scan_id uuid,p_object_count bigint,p_byte_count bigint,p_discrepancies jsonb,p_report_sha256 bytea) returns jsonb
language plpgsql security definer set search_path='' as $$
declare discrepancies bigint; row jsonb; scan app_private.paper_asset_inventory_scans;
begin
 if p_object_count is null or p_object_count not between 0 and 50000 or p_byte_count is null or p_byte_count<0
  or p_report_sha256 is null or octet_length(p_report_sha256)<>32 or jsonb_typeof(p_discrepancies)<>'object'
  or (select array_agg(key order by key) from jsonb_object_keys(p_discrepancies) key) is distinct from array['incomplete','mismatched','missing_verified','unowned','untracked']::text[]
 then raise exception 'invalid_inventory_scan'; end if;
 discrepancies:=0;
 for row in select value from jsonb_each(p_discrepancies) loop
  if jsonb_typeof(row)<>'number' or row::text !~ '^[0-9]+$' or row::text::numeric>50000 then raise exception 'invalid_inventory_scan'; end if;
  discrepancies:=discrepancies+row::text::bigint;
 end loop;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select * into strict scan from app_private.paper_asset_inventory_scans where id=p_scan_id for update;
 if scan.finished_at is not null then
  if (scan.object_count,scan.byte_count,scan.discrepancies,scan.report_sha256) is distinct from (p_object_count,p_byte_count,p_discrepancies,p_report_sha256)
  then raise exception 'inventory_result_conflict'; end if;
  return jsonb_build_object('scan_id',scan.id,'complete',discrepancies=0);
 end if;
 if not exists(select 1 from app_private.paper_asset_policy where reconciliation_id=p_scan_id) then raise exception 'invalid_inventory_scan'; end if;
 if (select enabled from app_private.pipeline_policy where singleton) or exists(select 1 from app_private.pipeline_papers where claim_id is not null)
  or exists(select 1 from app_private.paper_asset_write_attempts where finished_at is null) then raise exception 'asset_workers_not_drained'; end if;
 update app_private.paper_asset_inventory_scans set finished_at=clock_timestamp(),object_count=p_object_count,byte_count=p_byte_count,
  discrepancies=p_discrepancies,report_sha256=p_report_sha256 where id=p_scan_id;
 update app_private.paper_asset_policy set reconciliation_id=null,inventory_discrepancies=discrepancies,enforced=enforced and discrepancies=0,
  inventory_verified_at=case when discrepancies=0 then clock_timestamp() else null end where singleton;
 return jsonb_build_object('scan_id',p_scan_id,'complete',discrepancies=0);
end $$;

create function public.worker_asset_enforcement(p_enabled boolean,p_delivery_mode text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if p_enabled is null or p_delivery_mode is null or p_delivery_mode not in ('legacy','dual','bounded') then raise exception 'invalid_asset_policy'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if p_enabled then
  if not exists(select 1 from app_private.paper_asset_policy where reconciliation_id is null and inventory_verified_at is not null and inventory_discrepancies=0)
  then raise exception 'asset_inventory_incomplete'; end if;
  perform app_private.paper_asset_check_capacity(null);
  perform app_private.paper_asset_check_capacity(owner_id) from app_private.documents where owner_id is not null group by owner_id;
 end if;
 update app_private.paper_asset_policy set enforced=p_enabled where singleton;
 update app_private.reader_delivery_policy set mode=p_delivery_mode where singleton;
 return public.worker_asset_spending_status();
end $$;

do $$ declare name text; f regprocedure; begin
 foreach name in array array['paper_asset_policy','paper_asset_inventory_scans','paper_asset_holds','paper_asset_uploads','paper_asset_upload_members','paper_asset_write_attempts',
  'paper_asset_manifest_members','reader_delivery_policy','reader_transfer_months','reader_delivery_grants','reader_delivery_redemptions'] loop
  execute format('alter table app_private.%I enable row level security',name);
  execute format('revoke all on app_private.%I from public,anon,authenticated',name);
 end loop;
 for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  and p.proname in ('worker_pipeline_admit_download','worker_pipeline_admit_processing','worker_pipeline_fund','worker_pipeline_asset_plan','worker_pipeline_asset_write',
   'worker_pipeline_asset_written','worker_pipeline_original','worker_pipeline_collected','worker_pipeline_published','worker_delete_account_begin','worker_delete_account_finish',
   'worker_reader_delivery_create','worker_reader_delivery_redeem','worker_reader_delivery_observed','worker_reader_delivery_expire','worker_asset_maintenance','worker_chat_context','worker_asset_spending_status',
   'worker_asset_inventory_begin','worker_asset_inventory_page','worker_asset_inventory_manifest','worker_asset_inventory_finish','worker_asset_enforcement') loop
  execute format('revoke all on function %s from public,anon,authenticated',f);
  execute format('grant execute on function %s to service_role',f);
 end loop;
 for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private'
  and (p.proname like 'paper_asset_%' or p.proname='reader_transfer_adjust' or p.proname in ('worker_pipeline_admit_download','worker_pipeline_fund',
   'worker_pipeline_original','worker_pipeline_collected','worker_pipeline_published','worker_delete_account_begin','worker_delete_account_finish','worker_chat_context')) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f);
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
