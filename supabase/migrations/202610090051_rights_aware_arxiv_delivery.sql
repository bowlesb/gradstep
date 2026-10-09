-- Rights-aware paper delivery (owner decision 2026-10-09).
--
-- A public arXiv URL is not, by itself, permission for Science Reader to
-- retain and serve the PDF or a Mathpix-derived bundle.  The pipeline keeps
-- metadata and the source link, but sends default, missing, or uncertain
-- arXiv licenses to source_only.  Shared server assets remain limited to the
-- existing CC BY 4.0 / CC0 evidence path.  Web and reader-supplied PDFs keep
-- their separate owner-private path.  An arXiv private conversion is only
-- available to a trusted worker when its evidence explicitly contains a
-- private_permission reference; the production arXiv adapter does not supply
-- one today.
--
-- Existing owner-private arXiv rows are marked legacy_private.  This is an
-- audit distinction, not a claim that their original rights basis is valid;
-- no existing stored asset is deleted or silently rewritten by this change.
begin;
set local lock_timeout = '15s';
lock table app_private.accounts in exclusive mode;

alter table app_private.pipeline_papers
  add column rights_mode text not null default 'pending';

alter table app_private.pipeline_papers
  add constraint pipeline_papers_rights_mode_check
  check (rights_mode in ('pending','shared','private','source_only','legacy_private'));

-- Classify rows already in the database before the new transition is used.
-- An old private arXiv conversion is deliberately visible as legacy_private,
-- so operators can inventory it rather than confusing it with a new grant.
update app_private.pipeline_papers
set rights_mode = case
  when stage = 'source_only' then 'source_only'
  when eligible is true then 'shared'
  when source_id like 'openalex:%' or source_id like 'upload:%' then 'private'
  when owner_id is not null or stage = 'private_split' then 'legacy_private'
  else 'pending'
end;

create index pipeline_papers_rights_mode on app_private.pipeline_papers(rights_mode,stage);
comment on column app_private.pipeline_papers.rights_mode is
  'Delivery policy: pending, shared (CC BY/CC0), private (web/upload or explicit permission), source_only (device retrieval), or legacy_private (pre-051 arXiv conversion).';

-- Uploads are explicitly supplied by the account and remain owner-private.
create or replace function app_private.pipeline_link_import() returns trigger
language plpgsql security definer set search_path='' as $$
declare paper uuid;
begin
 if tg_op='INSERT' then
  if new.source_id like 'upload:%' then
   insert into app_private.pipeline_papers(owner_id,source_id,requested_revision,revision,metadata_id,eligible,rights_mode,stage)
    values(new.account_id,new.source_id,0,1,new.metadata_id,false,'private','download')
    on conflict(owner_id,source_id,requested_revision) where owner_id is not null do nothing;
   select id into strict paper from app_private.pipeline_papers where owner_id=new.account_id and source_id=new.source_id and requested_revision=0;
  else
   insert into app_private.pipeline_papers(source_id,requested_revision) values(new.source_id,coalesce(new.requested_revision,0))
    on conflict(source_id,requested_revision) where owner_id is null do nothing;
   select id into strict paper from app_private.pipeline_papers where owner_id is null and source_id=new.source_id and requested_revision=coalesce(new.requested_revision,0);
  end if;
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

-- Keep the worker/debug entry explicit about the policy that produced it.
create or replace function app_private.pipeline_entry(p app_private.pipeline_papers) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',p.id,'source_id',p.source_id,'requested_revision',p.requested_revision,'revision',p.revision,
  'owner_id',p.owner_id,'stage',p.stage,'error_code',p.error_code,'generation',p.generation,'claim_id',p.claim_id,'state_revision',p.state_revision,
  'metadata_id',p.metadata_id,'eligible',p.eligible,'rights_mode',p.rights_mode,'document_id',p.document_id,'original_object_id',p.original_object_id,
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

-- A non-CC arXiv record is source-only unless a trusted caller presents an
-- explicit private_permission evidence reference.  The production worker
-- passes NULL for ineligible arXiv evidence, so the default path cannot enter
-- private_split or write an original PDF to Storage.
create or replace function public.worker_pipeline_metadata(
 p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_revision integer,p_metadata jsonb,
 p_eligible boolean,p_license_uri text default null,p_evidence jsonb default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; meta uuid; private_permission boolean; next_stage text; mode text;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'metadata' then raise exception 'invalid_pipeline_stage'; end if;
 if p.source_id like 'openalex:%' or p.source_id like 'upload:%' then raise exception 'invalid_arxiv_id'; end if;
 if p.owner_id is not null or p_eligible is null or p_revision is null or (p.requested_revision>0 and p_revision<>p.requested_revision)
  or (p_eligible and (p_license_uri is null or p_evidence is null)) then raise exception 'invalid_pipeline_metadata'; end if;
 private_permission:=not p_eligible and p_evidence is not null and jsonb_typeof(p_evidence)='object'
  and length(coalesce(p_evidence->>'private_permission','')) between 1 and 512;
 if not p_eligible and private_permission and p_evidence->>'private_permission' !~ '^[A-Za-z0-9._:/ -]+$' then
  raise exception 'invalid_pipeline_metadata';
 end if;
 meta:=public.worker_record_arxiv_metadata(p.source_id,p_revision,p_metadata);
 next_stage:=case when p_eligible then 'download' when private_permission then 'private_split' else 'source_only' end;
 mode:=case when p_eligible then 'shared' when private_permission then 'private' else 'source_only' end;
 update app_private.pipeline_papers set revision=p_revision,metadata_id=meta,eligible=p_eligible,rights_mode=mode,
  license_uri=case when p_eligible or (length(p_license_uri)<=512 and p_license_uri ~ '^https?://[A-Za-z0-9.-]+/[ -~]*$') then p_license_uri
   else 'https://arxiv.org/abs/'||p.source_id||'v'||p_revision end,
  evidence=case when p_eligible or private_permission then p_evidence else null end where id=p.id;
 perform app_private.pipeline_set_stage(p.id,next_stage,case when next_stage='source_only' then 'license_unverified' else null end);
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

-- Preserve the source of a private split: web/upload coordinators are private;
-- old arXiv splits remain explicitly marked legacy_private.
create or replace function public.worker_pipeline_split_private(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns integer
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; link record; private uuid; moved integer:=0; child_mode text;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'private_split' or p.owner_id is not null then raise exception 'invalid_pipeline_stage'; end if;
 child_mode:=case when p.rights_mode='private' then 'private' else 'legacy_private' end;
 for link in select pi.account_id,pi.import_id from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
  where pi.paper_id=p.id and i.desired_present and i.phase in ('accepted','resolving','acquiring') order by pi.account_id,pi.import_id loop
  insert into app_private.pipeline_papers(owner_id,source_id,requested_revision,revision,metadata_id,eligible,rights_mode,license_uri,stage,pdf_urls,landing_url)
   values(link.account_id,p.source_id,p.requested_revision,p.revision,p.metadata_id,false,child_mode,p.license_uri,'download',p.pdf_urls,p.landing_url)
   on conflict(owner_id,source_id,requested_revision) where owner_id is not null do nothing;
  select id into strict private from app_private.pipeline_papers where owner_id=link.account_id and source_id=p.source_id and requested_revision=p.requested_revision;
  update app_private.pipeline_imports set paper_id=private,synced_revision=0,next_sync_at=now(),
   retry_requested=exists(select 1 from app_private.pipeline_papers where id=private and stage in ('failed','needs_credits') and resume_stage is not null)
   where account_id=link.account_id and import_id=link.import_id;
  moved:=moved+1;
 end loop;
 return moved;
end $$;

-- Web papers are owner-private by source policy, even when their landing page
-- is publicly reachable.  The reader-supplied upload path is private too.
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
 update app_private.pipeline_papers set revision=1,metadata_id=meta,eligible=false,rights_mode='private',license_uri=landing,evidence=null,
  pdf_urls=case when cardinality(p_pdf_urls)>0 then p_pdf_urls end,landing_url=landing where id=p.id;
 perform app_private.pipeline_set_stage(p.id,'private_split');
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
revoke all on function public.worker_pipeline_metadata(uuid,uuid,bigint,integer,jsonb,boolean,text,jsonb),
 public.worker_pipeline_split_private(uuid,uuid,bigint),public.worker_pipeline_web_metadata(uuid,uuid,bigint,jsonb,text,text[],text)
 from public,anon,authenticated;
grant execute on function public.worker_pipeline_metadata(uuid,uuid,bigint,integer,jsonb,boolean,text,jsonb),
 public.worker_pipeline_split_private(uuid,uuid,bigint),public.worker_pipeline_web_metadata(uuid,uuid,bigint,jsonb,text,text[],text)
 to service_role;
notify pgrst,'reload schema';
commit;
