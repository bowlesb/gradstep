-- Web imports (owner request 2026-10-05): Ingest may add a cited paper that has
-- no arXiv copy, from the open-access PDF OpenAlex reports for it. Additive over
-- 010/014/016; arXiv behaviour and arXiv library entries are unchanged.
--
-- Identity: a web paper's source_id is 'openalex:W<digits>', which can never equal
-- an arXiv ID, so every unique index and source_id comparison keeps working. Web
-- papers are always revision 1 and always converted privately for the requesting
-- account (eligible is never true); the PDF locations come only from OpenAlex,
-- recorded by the worker, never from a client.
--
-- Installed builds before this migration accept only arXiv library entries, and
-- one unexpected entry stops their library sync for good. v2 library reads omit
-- web entries; v3 reads (builds that understand them) return everything. An arXiv
-- import never resolves onto a web-pinned item, so v2 never references a hidden item.
--
-- Also (review, 2026-10-05): an import's `progress` is stored when the worker
-- projects it (with a new state_seq) instead of computed live from the paper's
-- stage, so an entry's JSON at a given state_seq never changes.
--
-- Apply with the pipeline disabled (worker_set_pipeline_enabled(false)); the
-- table alterations below take short exclusive locks.
begin;
set local lock_timeout='15s';

alter table app_private.publication_identifiers drop constraint publication_identifiers_namespace_check;
alter table app_private.publication_identifiers add constraint publication_identifiers_namespace_check
 check(namespace in ('doi','arxiv','semantic_scholar','openalex'));

create function app_private.validate_web_source_id(p_source_id text) returns text language plpgsql immutable set search_path='' as $$
declare s text:=btrim(p_source_id);
begin
 if s is null or s !~ '^openalex:[Ww][1-9][0-9]{0,14}$' then raise exception 'invalid_web_source_id'; end if;
 return 'openalex:W'||substr(s,11);
end $$;
-- An https URL on a named host (no IP literal, port or credentials) with a path, printable ASCII.
create function app_private.web_url_ok(p_url text) returns boolean language sql immutable set search_path='' as $$
 select p_url is not null and length(p_url)<=1000 and p_url ~ '^https://[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,63}/[!-~]*$'
$$;
create function app_private.web_urls_ok(p_urls text[]) returns boolean language sql immutable set search_path='' as $$
 select cardinality(p_urls) between 1 and 3 and array_ndims(p_urls)=1 and not exists(select 1 from unnest(p_urls) u where not app_private.web_url_ok(u))
$$;

alter table app_private.pipeline_papers
 add column pdf_urls text[] check(pdf_urls is null or app_private.web_urls_ok(pdf_urls)),
 add column landing_url text check(landing_url is null or (length(landing_url)<=512 and app_private.web_url_ok(landing_url))),
 add constraint pipeline_web_private check(source_id not like 'openalex:%' or eligible is not true),
 add constraint pipeline_web_locations check((pdf_urls is null and landing_url is null) or source_id like 'openalex:%');

-- Same rules as worker_record_arxiv_metadata (010), plus no control characters
-- (the reader's attribution refuses them; web metadata is third-party text).
create function app_private.check_catalog_metadata(p_metadata jsonb) returns void language plpgsql immutable set search_path='' as $$
begin
 if p_metadata is not null and jsonb_typeof(p_metadata)='object' and exists(select 1 from jsonb_each(p_metadata) e
  cross join lateral (select e.value#>>'{}' v where jsonb_typeof(e.value)='string' union all
   select x#>>'{}' from jsonb_array_elements(case when jsonb_typeof(e.value)='array' then e.value else '[]'::jsonb end) x where jsonb_typeof(x)='string') t
  where t.v ~ '[\u0001-\u001f\u007f-\u009f]') then raise exception 'invalid_catalog_metadata'; end if;
 if p_metadata is null or jsonb_typeof(p_metadata)<>'object' or octet_length(p_metadata::text)>32768
 or (p_metadata-'title'-'authors'-'abstract'-'published_at'-'updated_at'-'categories'-'venue')<>'{}'::jsonb
 or jsonb_typeof(p_metadata->'title') is distinct from 'string' or length(p_metadata->>'title') not between 1 and 2000
 or jsonb_typeof(p_metadata->'authors') is distinct from 'array' or jsonb_typeof(p_metadata->'categories') is distinct from 'array'
 then raise exception 'invalid_catalog_metadata'; end if;
 if jsonb_array_length(p_metadata->'authors')>512 or jsonb_array_length(p_metadata->'categories')>64
 or exists(select 1 from jsonb_array_elements(p_metadata->'authors') x where jsonb_typeof(x)<>'string' or length(x#>>'{}')>256)
 or exists(select 1 from jsonb_array_elements(p_metadata->'categories') x where jsonb_typeof(x)<>'string' or length(x#>>'{}')>64)
 or exists(select 1 from jsonb_each(p_metadata) e where e.key in ('abstract','venue','published_at','updated_at') and jsonb_typeof(e.value) not in ('string','null'))
 or length(coalesce(p_metadata->>'abstract',''))>24000 or length(coalesce(p_metadata->>'venue',''))>1024
 then raise exception 'invalid_catalog_metadata'; end if;
 if exists(select 1 from jsonb_each_text(p_metadata) e where e.key in ('published_at','updated_at') and e.value is not null and e.value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') then raise exception 'invalid_catalog_metadata'; end if;
 if p_metadata->>'published_at' is not null then perform (p_metadata->>'published_at')::date; end if;
 if p_metadata->>'updated_at' is not null then perform (p_metadata->>'updated_at')::date; end if;
end $$;

create function app_private.record_web_metadata(p_source_id text,p_metadata jsonb,p_doi text) returns uuid
language plpgsql security definer set search_path='' as $$
declare src text:=app_private.validate_web_source_id(p_source_id); work text; doi text:=lower(btrim(p_doi)); pub uuid; ver uuid; result uuid;
 p app_private.library_policy; authors text[];
begin
 perform app_private.check_catalog_metadata(p_metadata);
 work:=substr(src,10);
 if doi is not null and (length(doi)>256 or doi !~ '^10\.[0-9]{4,9}/[!-~]+$') then doi:=null; end if;
 select * into strict p from app_private.library_policy where singleton for update;
 select publication_id into pub from app_private.publication_identifiers where namespace='openalex' and identifier=work;
 if pub is null then
  select coalesce(array_agg(value),'{}') into authors from jsonb_array_elements_text(p_metadata->'authors');
  insert into app_private.publications(title,authors,abstract,venue) values(p_metadata->>'title',authors,p_metadata->>'abstract',p_metadata->>'venue') returning id into pub;
  insert into app_private.publication_identifiers values('openalex',work,pub,now(),'openalex-adapter-v1');
  if doi is not null then insert into app_private.publication_identifiers values('doi',doi,pub,now(),'openalex-adapter-v1') on conflict do nothing; end if;
 end if;
 insert into app_private.publication_versions(publication_id,source,revision,published_at) values(pub,'web','v1',nullif(p_metadata->>'published_at','')::date)
 on conflict(publication_id,source,revision) do nothing;
 select id into strict ver from app_private.publication_versions where publication_id=pub and source='web' and revision='v1';
 select id into result from app_private.catalog_metadata where version_id=ver and metadata_sha256=sha256(convert_to(p_metadata::text,'UTF8'));
 if result is not null then return result; end if;
 if (select count(*) from app_private.catalog_metadata)+1>p.metadata_rows
 or (select coalesce(sum(octet_length(metadata::text)),0) from app_private.catalog_metadata)+octet_length(p_metadata::text)>p.metadata_bytes
 then raise exception 'catalog_metadata_limit'; end if;
 insert into app_private.catalog_metadata(version_id,source_id,source_revision,metadata,metadata_sha256)
 values(ver,src,1,p_metadata,sha256(convert_to(p_metadata::text,'UTF8'))) returning id into result;
 return result;
end $$;

-- A web paper's shared coordinator records metadata and its open-access PDF
-- locations, then hands every interested import to a private paper.
create function public.worker_pipeline_web_metadata(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_metadata jsonb,
 p_doi text,p_pdf_urls text[],p_landing_url text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; meta uuid; landing text;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'metadata' then raise exception 'invalid_pipeline_stage'; end if;
 if p.owner_id is not null or p.source_id not like 'openalex:%' or p_pdf_urls is null or not app_private.web_urls_ok(p_pdf_urls)
 then raise exception 'invalid_pipeline_metadata'; end if;
 meta:=app_private.record_web_metadata(p.source_id,p_metadata,p_doi);
 landing:=case when length(p_landing_url)<=512 and app_private.web_url_ok(p_landing_url) then p_landing_url
  else 'https://openalex.org/works/'||substr(p.source_id,10) end;
 -- The landing page is the private pin's provenance (where the license is stated).
 update app_private.pipeline_papers set revision=1,metadata_id=meta,eligible=false,license_uri=landing,evidence=null,
  pdf_urls=p_pdf_urls,landing_url=landing where id=p.id;
 perform app_private.pipeline_set_stage(p.id,'private_split');
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

-- 014, plus the web PDF locations for private web papers.
create or replace function public.worker_pipeline_split_private(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns integer
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; link record; private uuid; moved integer:=0;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'private_split' or p.owner_id is not null then raise exception 'invalid_pipeline_stage'; end if;
 for link in select pi.account_id,pi.import_id from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
  where pi.paper_id=p.id and i.desired_present and i.phase in ('accepted','resolving','acquiring') order by pi.account_id,pi.import_id loop
  insert into app_private.pipeline_papers(owner_id,source_id,requested_revision,revision,metadata_id,eligible,license_uri,stage,pdf_urls,landing_url)
   values(link.account_id,p.source_id,p.requested_revision,p.revision,p.metadata_id,false,p.license_uri,'download',p.pdf_urls,p.landing_url)
   on conflict(owner_id,source_id,requested_revision) where owner_id is not null do nothing;
  select id into strict private from app_private.pipeline_papers where owner_id=link.account_id and source_id=p.source_id and requested_revision=p.requested_revision;
  update app_private.pipeline_imports set paper_id=private,synced_revision=0,next_sync_at=now(),
   retry_requested=exists(select 1 from app_private.pipeline_papers where id=private and stage in ('failed','needs_credits') and resume_stage is not null)
   where account_id=link.account_id and import_id=link.import_id;
  moved:=moved+1;
 end loop;
 return moved;
end $$;

-- 014, plus web provenance: the landing page and the PDF locations offered.
create or replace function app_private.approve_private_asset(p app_private.pipeline_papers,p_document uuid,p_object uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare m app_private.catalog_metadata; existing uuid; result uuid:=gen_random_uuid(); pol app_private.library_policy;
 v_evidence jsonb;
begin
 select * into strict m from app_private.catalog_metadata where id=p.metadata_id;
 select * into strict pol from app_private.library_policy where singleton for update;
 select id into existing from app_private.catalog_asset_approvals where metadata_id=m.id and document_id=p_document and policy_version='owner-private-v1';
 if existing is not null then return existing; end if;
 if m.source_id like 'openalex:%' then
  if p.landing_url is null or p.pdf_urls is null then raise exception 'invalid_web_provenance'; end if;
  v_evidence:=jsonb_build_object('scope','owner_private','owner_id',p.owner_id,'source_id',m.source_id,'source_revision',m.source_revision,
    'source_url',p.landing_url,'pdf_urls',to_jsonb(p.pdf_urls),'license_uri',p.license_uri);
 else
  v_evidence:=jsonb_build_object('scope','owner_private','owner_id',p.owner_id,'source_id',m.source_id,'source_revision',m.source_revision,
    'source_url','https://arxiv.org/abs/'||m.source_id||'v'||m.source_revision,'license_uri',p.license_uri);
 end if;
 if (select count(*) from app_private.catalog_asset_approvals)+1>pol.approval_rows
 or (select coalesce(sum(octet_length(a.evidence::text)),0) from app_private.catalog_asset_approvals a)+octet_length(v_evidence::text)>pol.approval_bytes
 then raise exception 'catalog_approval_limit'; end if;
 insert into app_private.version_documents values(m.version_id,p_document) on conflict do nothing;
 insert into app_private.catalog_asset_approvals values(result,m.version_id,p_document,m.id,p_object,p.license_uri,'owner-private-v1',v_evidence,now());
 return result;
end $$;

-- 014, plus the web source fields the worker needs.
create or replace function app_private.pipeline_entry(p app_private.pipeline_papers) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',p.id,'source_id',p.source_id,'requested_revision',p.requested_revision,'revision',p.revision,
  'owner_id',p.owner_id,'stage',p.stage,'error_code',p.error_code,'generation',p.generation,'claim_id',p.claim_id,'state_revision',p.state_revision,
  'metadata_id',p.metadata_id,'eligible',p.eligible,'document_id',p.document_id,'original_object_id',p.original_object_id,
  'approval_id',p.approval_id,'page_count',p.page_count,'artifact_id',p.artifact_id,'failures',p.failures,'ocr_run_id',p.ocr_run_id,
  'license_uri',p.license_uri,
  'source_kind',case when p.source_id like 'openalex:%' then 'web' else 'arxiv' end,'pdf_urls',to_jsonb(p.pdf_urls),'landing_url',p.landing_url,
  'title',(select cm.metadata->>'title' from app_private.catalog_metadata cm where cm.id=p.metadata_id),
  'authors',(select cm.metadata->'authors' from app_private.catalog_metadata cm where cm.id=p.metadata_id),
  'due',p.stage in ('metadata','private_split','download','ocr_fund','ocr_submit','ocr_wait','render') and p.next_attempt_at<=clock_timestamp(),
  'document_sha256',(select encode(d.sha256,'hex') from app_private.documents d where d.id=p.document_id),
  'original_path',(select o.path from app_private.stored_objects o where o.id=p.original_object_id),
  'original_bytes',(select o.byte_count from app_private.stored_objects o where o.id=p.original_object_id),
  'raw_manifest_path',app_private.pipeline_raw_path(p.ocr_run_id),
  'attempt',(select jsonb_build_object('id',x.id,'state',x.state,'page_limit',x.page_limit,'provider_job_id',x.provider_job_id,
    'ocr_run_id',x.ocr_run_id,'submitted_at',x.submitted_at,'raw_manifest_path',app_private.pipeline_raw_path(x.ocr_run_id))
   from app_private.ocr_attempts x where x.paper_id=p.id order by x.created_at desc limit 1))
$$;

-- A private web paper's PDF locations, re-read from OpenAlex before each download
-- (locations move; a retry must not keep failing on the first importer's list).
create function public.worker_pipeline_web_locations(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_pdf_urls text[]) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'download' or p.owner_id is null or p.source_id not like 'openalex:%' then raise exception 'invalid_pipeline_stage'; end if;
 if p_pdf_urls is null or not app_private.web_urls_ok(p_pdf_urls) then raise exception 'invalid_pipeline_metadata'; end if;
 update app_private.pipeline_papers set pdf_urls=p_pdf_urls,updated_at=now() where id=p.id returning * into p;
 return app_private.pipeline_entry(p);
end $$;

-- Stored import progress (see header). Active imports keep the value a reader saw last.
create function app_private.pipeline_progress(p_stage text) returns text language sql immutable set search_path='' as $$
 select case when p_stage='metadata' then 'finding' when p_stage in ('download','private_split') then 'downloading'
  when p_stage in ('ocr_fund','ocr_submit','ocr_wait','ocr_uncertain') then 'converting' when p_stage='render' then 'rendering'
  when p_stage='done' then 'finishing' end
$$;
alter table app_private.import_requests add column progress text default 'finding'
 check(progress in ('finding','downloading','converting','rendering','finishing'));
update app_private.import_requests i set progress=(select app_private.pipeline_progress(pp.stage) from app_private.pipeline_imports pi
 join app_private.pipeline_papers pp on pp.id=pi.paper_id where (pi.account_id,pi.import_id)=(i.account_id,i.id))
 where i.phase in ('accepted','resolving','acquiring');

-- 014, plus the stored progress.
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
      when p.stage='failed' then case when p.error_code in ('metadata_unavailable','download_failed','pdf_invalid','rate_limited','too_large','conversion_failed')
       then p.error_code when p.resume_stage='metadata' then 'metadata_unavailable' when p.resume_stage='download' then 'download_failed' else 'conversion_failed' end end;
     retry:=p.stage='needs_credits' or (p.stage='failed' and p.resume_stage is not null);
     perform app_private.lock_library_account(i.account_id); perform app_private.lock_library_state(i.account_id);
     select * into strict i from app_private.import_requests where account_id=link.account_id and id=link.import_id;
     if i.desired_present and i.phase in ('accepted','resolving','acquiring') then
      s:=app_private.library_next_seq(i.account_id);
      update app_private.import_requests set phase=target,metadata_id=coalesce(metadata_id,p.metadata_id),state_seq=s,
       error_code=err,retryable=coalesce(retry,false),progress=coalesce(app_private.pipeline_progress(p.stage),progress)
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

-- Library entries: arXiv output is byte-for-byte what 011/014 produced (progress is now stored).
create or replace function app_private.library_item_entry(a uuid,p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind','item','id',li.id,'document_id',li.document_id,'created_seq',li.created_seq,'state_seq',li.state_seq,
  'membership_revision',li.membership_revision,'visible',li.removed_at is null,'added_at',li.added_at,
  'last_remove_seq',li.last_remove_seq,'approval_id',li.approval_id,'version_id',ca.version_id,'metadata_id',cm.id,
  'source',case when cm.id is null then null when cm.source_id like 'openalex:%' then 'web' else 'arxiv' end,'source_id',cm.source_id,'source_revision',cm.source_revision,
  'metadata',cm.metadata,'metadata_recorded_at',cm.recorded_at,
  'source_url',case when cm.id is null then null when cm.source_id like 'openalex:%' then ca.evidence->>'source_url'
   else 'https://arxiv.org/abs/'||cm.source_id||'v'||cm.source_revision end,
  'scope',d.scope,'page_count',d.page_count,'original_object_id',ca.original_object_id,'artifact_id',li.artifact_id,
  'original_availability',coalesce(ap.original_availability,'unverified'),'render_availability',coalesce(ap.render_availability,'unverified'),
  'original_availability_revision',coalesce(ap.original_availability_revision,0),'render_availability_revision',coalesce(ap.render_availability_revision,0),
  'readiness',case when ap.render_availability='available' then 'converted_ready' when ap.original_availability='available' then 'pdf_ready'
   when ca.id is not null or li.artifact_id is not null then 'unavailable' else 'unverified' end)
 from app_private.library_items li join app_private.documents d on d.id=li.document_id
 left join app_private.catalog_asset_approvals ca on ca.id=li.approval_id left join app_private.catalog_metadata cm on cm.id=ca.metadata_id
 left join app_private.library_asset_projection ap on (ap.account_id,ap.item_id)=(li.account_id,li.id) where li.account_id=a and li.id=p_id
$$;
create or replace function app_private.library_import_entry(a uuid,p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind','import','id',i.id,'created_seq',i.created_seq,'state_seq',i.state_seq,'intent_revision',i.intent_revision,
  'visible',i.desired_present and i.phase<>'ready','phase',i.phase,'source',case when i.source_id like 'openalex:%' then 'web' else 'arxiv' end,'source_id',i.source_id,
  'requested_revision',i.requested_revision,'source_revision',cm.source_revision,'metadata_id',cm.id,'version_id',cm.version_id,
  'metadata',cm.metadata,'metadata_recorded_at',cm.recorded_at,
  'source_url',case when i.source_id like 'openalex:%' then 'https://openalex.org/works/'||substr(i.source_id,10)
   else 'https://arxiv.org/abs/'||i.source_id||coalesce('v'||coalesce(cm.source_revision,i.requested_revision),'') end,
  'document_id',i.document_id,'library_item_id',i.library_item_id,
  'error_code',i.error_code,'retryable',i.retryable,
  'progress',case when i.phase in ('accepted','resolving','acquiring') then i.progress end)
 from app_private.import_requests i left join app_private.catalog_metadata cm on cm.id=i.metadata_id
 where i.account_id=a and i.id=p_id
$$;

-- Mirrors v2_begin_import (010) for a web source; never a requested revision.
create function public.v2_begin_web_import(p_operation_id uuid,p_source_id text,p_observed_cursor bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); src text:=app_private.validate_web_source_id(p_source_id); digest bytea; replay jsonb; s bigint; p app_private.library_policy;
begin
 if p_observed_cursor is null or p_observed_cursor<0 then raise exception 'invalid_import_request'; end if;
 digest:=sha256(convert_to(jsonb_build_array('web-import-v1',src,p_observed_cursor)::text,'UTF8'));
 perform public.worker_consume_request(a,'library-write'); perform app_private.lock_library_account(a); perform app_private.lock_library_state(a);
 replay:=app_private.library_replay(a,p_operation_id,digest); if replay is not null then return replay; end if;
 if p_observed_cursor>(select last_seq from app_private.library_sync_state where account_id=a) then raise exception 'invalid_library_cursor'; end if;
 select * into strict p from app_private.library_policy;
 perform app_private.library_check_receipt_capacity(a,true);
 if (select count(*) from app_private.import_requests where account_id=a)+1>p.account_imports then raise exception 'library_account_import_limit'; end if;
 if (select count(*) from app_private.import_requests)+1>p.environment_imports then raise exception 'library_environment_import_limit'; end if;
 if (select count(*) from app_private.import_requests where account_id=a and desired_present and phase in ('accepted','resolving','acquiring'))+1>p.account_active_imports
 or (select count(*) from app_private.import_requests where desired_present and phase in ('accepted','resolving','acquiring'))+1>p.environment_active_imports
 then raise exception 'library_active_import_limit'; end if;
 s:=app_private.library_next_seq(a);
 insert into app_private.import_requests(account_id,id,request_sha256,source_id,requested_revision,observed_cursor,created_seq,state_seq)
 values(a,p_operation_id,digest,src,null,p_observed_cursor,s,s);
 perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,p_operation_id)));
 return app_private.library_receipt(a,p_operation_id,digest,jsonb_build_object('status','applied','kind','import','id',p_operation_id,'seq',s,'revision',1));
end $$;

-- 014, plus: an arXiv import never resolves onto an item pinned by a web source
-- (v2 readers could not see that item), and a web import never pins an unpinned
-- item (a v2 reader can see it). Either ends as a membership conflict without an
-- item, so a v2 reader's observation stays complete.
create or replace function public.worker_resolve_import(p_account_id uuid,p_import_id uuid,p_expected_state_seq bigint,p_expected_intent_revision bigint,
 p_approval_id uuid,p_artifact_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare i app_private.import_requests; ca app_private.catalog_asset_approvals; m app_private.catalog_metadata; li app_private.library_items;
 s bigint; item_id uuid; digest bytea; conflict boolean; cross_kind boolean; e jsonb; p app_private.library_policy;
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
 cross_kind:=li.id is not null and case when i.source_id like 'openalex:%' then li.approval_id is null
  else li.approval_id is not null and exists(select 1 from app_private.catalog_asset_approvals x
   join app_private.catalog_metadata xm on xm.id=x.metadata_id where x.id=li.approval_id and xm.source_id like 'openalex:%') end;
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

-- 010's baseline and delta with a reader filter. Without p_web, web entries are
-- left out; a change batch left empty is skipped (sequence gaps are allowed) and
-- the page limit counts only batches returned.
create function app_private.library_baseline_for(a uuid,p_cursor jsonb,p_limit integer,p_web boolean) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare high bigint; floor bigint; after_seq bigint:=0; after_id uuid:='00000000-0000-0000-0000-000000000000'; after_kind text:=''; result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 100 or p_web is null then raise exception 'invalid_library_page'; end if;
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
  ) projected where p_web or projected.entry->>'source' is distinct from 'web'
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
create function app_private.library_delta_for(a uuid,p_after bigint,p_through bigint,p_limit integer,p_web boolean) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare high bigint; floor bigint; result jsonb;
begin
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_after is null or p_after<0 or p_limit is null or p_limit not between 1 and 100 or p_web is null
 or p_after>high or p_through>high or p_through<p_after then raise exception 'invalid_library_cursor'; end if;
 if p_after<floor then raise exception 'library_resync_required'; end if;
 high:=coalesce(p_through,high);
 with shown as materialized (
  select c.seq,case when p_web then c.entries else (select coalesce(jsonb_agg(x.value order by x.ordinality),'[]'::jsonb)
    from jsonb_array_elements(c.entries) with ordinality x where x.value->>'source' is distinct from 'web') end entries
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
create or replace function public.v2_library_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin perform public.worker_consume_request(a,'library-read'); result:=app_private.library_baseline_for(a,p_cursor,p_limit,false);
 perform app_private.consume_library_transfer(a,result); return result; end $$;
create or replace function public.v2_library_changes(p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin perform public.worker_consume_request(a,'library-read'); result:=app_private.library_delta_for(a,p_after,p_through,p_limit,false);
 perform app_private.consume_library_transfer(a,result); return result; end $$;
create function public.v3_library_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin perform public.worker_consume_request(a,'library-read'); result:=app_private.library_baseline_for(a,p_cursor,p_limit,true);
 perform app_private.consume_library_transfer(a,result); return result; end $$;
create function public.v3_library_changes(p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin perform public.worker_consume_request(a,'library-read'); result:=app_private.library_delta_for(a,p_after,p_through,p_limit,true);
 perform app_private.consume_library_transfer(a,result); return result; end $$;

revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
do $$ declare f record; begin
 for f in select p.oid::regprocedure signature,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
 and p.proname in ('v2_begin_web_import','v3_library_page','v3_library_changes','worker_pipeline_web_metadata','worker_pipeline_web_locations') loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
  execute format('grant execute on function %s to %I',f.signature,case when f.proname like 'worker_%' then 'service_role' else 'authenticated' end);
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
