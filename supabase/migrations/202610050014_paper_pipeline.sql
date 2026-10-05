-- Edge-driven paper pipeline: arXiv metadata/license -> original PDF in Storage
-- -> funded Mathpix OCR -> reader bundle, plus reader delivery and chat context.
-- Supersedes the unapplied Linux executor candidates (012/013, deleted). The 011
-- acquisition tables stay in place but are not used by this pipeline.
--
-- Lock order (all writers): paper row -> document -> capacity/library policy
-- -> budget -> account. Customer library paths (account -> document -> policy)
-- never lock a pipeline_papers row; import triggers only insert links/papers
-- with ON CONFLICT DO NOTHING. Import projection runs in its own transaction
-- without holding the paper row.
begin;

create table app_private.pipeline_policy (
 singleton boolean primary key default true check(singleton),
 enabled boolean not null default false,
 max_pdf_bytes bigint not null default 67108864 check(max_pdf_bytes between 1024 and 67108864),
 max_ocr_pages integer not null default 80 check(max_ocr_pages between 1 and 250),
 ocr_credits_per_page integer not null default 1 check(ocr_credits_per_page between 0 and 1000),
 ocr_microusd_per_page integer not null default 5000 check(ocr_microusd_per_page between 0 and 1000000),
 rate_version text not null default 'beta-credits-v1' check(rate_version ~ '^[a-z0-9-]{1,64}$'),
 renderer_version text not null default 'timestep-mathpix-mathml-v1' check(renderer_version ~ '^[a-z0-9-]{1,64}$'),
 lease_seconds integer not null default 180 check(lease_seconds between 30 and 900),
 arxiv_spacing_ms integer not null default 3000 check(arxiv_spacing_ms between 0 and 60000),
 arxiv_next_request_at timestamptz not null default '-infinity'
);
insert into app_private.pipeline_policy default values;
-- Image-heavy ML papers commonly exceed 32 MiB (e.g. 40.8 MB for arXiv 2112.10752v2).
alter table app_private.documents drop constraint documents_byte_count_check;
alter table app_private.documents add constraint documents_byte_count_check check(byte_count between 1 and 67108864);
update app_private.library_policy set compatible_renderers=array_append(compatible_renderers,'timestep-mathpix-mathml-v1')
 where singleton and not ('timestep-mathpix-mathml-v1'=any(compatible_renderers));

-- One unit of work per arXiv source slot (0 = latest revision): shared for
-- reusable (CC BY/CC0) papers, otherwise one private paper per owner.
create table app_private.pipeline_papers (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid references app_private.accounts(id),
 source_id text not null check(length(source_id) between 1 and 128),
 requested_revision integer not null default 0 check(requested_revision>=0),
 revision integer check(revision>0),
 metadata_id uuid references app_private.catalog_metadata(id),
 eligible boolean,
 license_uri text,
 evidence jsonb check(evidence is null or (jsonb_typeof(evidence)='object' and octet_length(evidence::text)<=8192)),
 document_id uuid references app_private.documents(id),
 original_object_id uuid references app_private.stored_objects(id),
 approval_id uuid references app_private.catalog_asset_approvals(id),
 page_count integer check(page_count between 1 and 250),
 artifact_id uuid references app_private.render_artifacts(id),
 ocr_run_id uuid references app_private.ocr_runs(id),
 stage text not null default 'metadata' check(stage in ('metadata','private_split','download','ocr_fund','ocr_submit','ocr_wait','render','done',
  'source_only','failed','needs_credits','ocr_uncertain')),
 resume_stage text check(resume_stage in ('metadata','download','ocr_fund','render')),
 error_code text check(error_code ~ '^[a-z_]{1,64}$'),
 state_revision bigint not null default 1 check(state_revision>0),
 generation bigint not null default 0 check(generation>=0),
 claim_id uuid, lease_until timestamptz,
 next_attempt_at timestamptz not null default now(),
 failures integer not null default 0 check(failures>=0),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check((claim_id is null)=(lease_until is null)),
 check(owner_id is null or eligible is false),
 check(stage<>'done' or (artifact_id is not null and approval_id is not null)),
 check(resume_stage is null or stage in ('failed','needs_credits'))
);
create unique index pipeline_shared_slot on app_private.pipeline_papers(source_id,requested_revision) where owner_id is null;
create unique index pipeline_private_slot on app_private.pipeline_papers(owner_id,source_id,requested_revision) where owner_id is not null;
create index pipeline_papers_due on app_private.pipeline_papers(next_attempt_at)
 where stage in ('metadata','private_split','download','ocr_fund','ocr_submit','ocr_wait','render');

create table app_private.pipeline_imports (
 account_id uuid not null,
 import_id uuid not null,
 paper_id uuid not null references app_private.pipeline_papers(id),
 synced_revision bigint not null default 0,
 retry_requested boolean not null default false,
 next_sync_at timestamptz not null default now(),
 sync_failures integer not null default 0 check(sync_failures>=0),
 created_at timestamptz not null default now(),
 primary key(account_id,import_id),
 foreign key(account_id,import_id) references app_private.import_requests(account_id,id)
);
create index pipeline_imports_paper on app_private.pipeline_imports(paper_id);

-- Paid OCR attempts are financial records, separate from worker leases.
create table app_private.ocr_attempts (
 id uuid primary key default gen_random_uuid(),
 paper_id uuid not null references app_private.pipeline_papers(id),
 document_id uuid not null references app_private.documents(id),
 ocr_run_id uuid not null references app_private.ocr_runs(id),
 funder_account_id uuid not null,
 operation_id uuid not null,
 page_limit integer not null check(page_limit between 1 and 250),
 state text not null check(state in ('funded','submitting','submitted','uncertain','collected','failed')),
 provider_job_id text unique check(provider_job_id ~ '^[A-Za-z0-9_-]{1,128}$'),
 pages_reported integer check(pages_reported between 0 and 250),
 raw_manifest_object_id uuid references app_private.stored_objects(id),
 error_code text check(error_code ~ '^[a-z_]{1,64}$'),
 created_at timestamptz not null default now(),
 submitted_at timestamptz,
 finished_at timestamptz,
 foreign key(funder_account_id,operation_id) references app_private.metered_operations(account_id,id)
);
create unique index ocr_attempt_active_document on app_private.ocr_attempts(document_id)
 where state in ('funded','submitting','submitted','uncertain');

-- Private (non-reusable) papers are pinned by an owner-private approval that
-- records the arXiv license observed; it never makes the document shareable.
alter table app_private.catalog_asset_approvals drop constraint catalog_asset_approvals_license_uri_check,
 drop constraint catalog_asset_approvals_policy_version_check;
alter table app_private.catalog_asset_approvals add constraint catalog_asset_approval_policy check(
 (policy_version='arxiv-reuse-v1' and license_uri in ('https://creativecommons.org/licenses/by/4.0/','https://creativecommons.org/publicdomain/zero/1.0/'))
 or (policy_version='owner-private-v1' and length(license_uri)<=512 and license_uri ~ '^https?://[A-Za-z0-9.-]+/[ -~]*$'));

alter table app_private.import_requests drop constraint import_requests_error_code_check;
alter table app_private.import_requests add constraint import_requests_error_code_check check(error_code in
 ('metadata_unavailable','download_failed','pdf_invalid','rate_limited','license_unverified','membership_conflict',
  'insufficient_credits','conversion_failed','too_large'));

insert into app_private.api_rate_rules values('chat',3600,120,2000),('reader-download',3600,300,3000),('pipeline-kick',60,30,600)
 on conflict(route) do nothing;

-- Optional immediate wake-up. pg_net and the Vault secret exist only in hosted
-- environments; locally (and before configuration) this is a no-op. Runs as
-- the trigger's definer; failures never block the customer's import.
create function app_private.pipeline_kick() returns void language plpgsql security definer set search_path='' as $$
declare url text; secret text;
begin
 if to_regnamespace('net') is null or to_regnamespace('vault') is null then return; end if;
 begin
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into url using 'science_reader_pipeline_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into secret using 'science_reader_pipeline_secret';
  if url is null or secret is null then return; end if;
  execute 'select net.http_post(url:=$1,body:=$2,headers:=$3,timeout_milliseconds:=1000)'
   using url,'{"reason":"import"}'::jsonb,jsonb_build_object('content-type','application/json','x-pipeline-secret',secret);
 exception when others then null;
 end;
end $$;

create function app_private.pipeline_link_import() returns trigger language plpgsql security definer set search_path='' as $$
declare paper uuid;
begin
 if tg_op='INSERT' then
  insert into app_private.pipeline_papers(source_id,requested_revision) values(new.source_id,coalesce(new.requested_revision,0))
   on conflict(source_id,requested_revision) where owner_id is null do nothing;
  select id into strict paper from app_private.pipeline_papers where owner_id is null and source_id=new.source_id and requested_revision=coalesce(new.requested_revision,0);
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
create trigger pipeline_link_import after insert or update of phase on app_private.import_requests
 for each row execute function app_private.pipeline_link_import();

-- Reader availability no longer requires a 011 verifier record: the approval's
-- original object and the artifact manifest carry their own availability rows.
create or replace function app_private.current_library_assets(p_account_id uuid,p_item_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('original_object_id',ca.original_object_id,'artifact_id',li.artifact_id,
  'original_availability',case when ca.id is null then 'unverified' when so.state<>'verified' then 'unavailable' else coalesce(a.state,'unverified') end,
  'original_availability_revision',coalesce(a.revision,0),
  'render_availability',case when li.artifact_id is null then 'not_converted' when not (ra.renderer_version=any(lp.compatible_renderers)) then 'incompatible'
   when ro.state<>'verified' then 'unavailable' else coalesce(ma.state,'unverified') end,
  'render_availability_revision',coalesce(ma.revision,0))
 from app_private.library_items li left join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
 left join app_private.stored_objects so on so.id=ca.original_object_id
 left join app_private.paper_asset_availability a on a.object_id=so.id
 left join app_private.render_artifacts ra on ra.id=li.artifact_id left join app_private.stored_objects ro on ro.id=ra.manifest_object_id
 left join app_private.paper_asset_availability ma on ma.object_id=ro.id cross join app_private.library_policy lp
 where li.account_id=p_account_id and li.id=p_item_id and lp.singleton
$$;

create or replace function app_private.library_import_entry(a uuid,p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind','import','id',i.id,'created_seq',i.created_seq,'state_seq',i.state_seq,'intent_revision',i.intent_revision,
  'visible',i.desired_present and i.phase<>'ready','phase',i.phase,'source','arxiv','source_id',i.source_id,
  'requested_revision',i.requested_revision,'source_revision',cm.source_revision,'metadata_id',cm.id,'version_id',cm.version_id,
  'metadata',cm.metadata,'metadata_recorded_at',cm.recorded_at,'source_url','https://arxiv.org/abs/'||i.source_id||coalesce('v'||coalesce(cm.source_revision,i.requested_revision),''),
  'document_id',i.document_id,'library_item_id',i.library_item_id,
  'error_code',i.error_code,'retryable',i.retryable,
  'progress',case when i.phase not in ('accepted','resolving','acquiring') then null
   when pp.stage='metadata' then 'finding' when pp.stage in ('download','private_split') then 'downloading'
   when pp.stage in ('ocr_fund','ocr_submit','ocr_wait','ocr_uncertain') then 'converting' when pp.stage='render' then 'rendering'
   when pp.stage='done' then 'finishing' end)
 from app_private.import_requests i left join app_private.catalog_metadata cm on cm.id=i.metadata_id
 left join app_private.pipeline_imports pi on (pi.account_id,pi.import_id)=(i.account_id,i.id)
 left join app_private.pipeline_papers pp on pp.id=pi.paper_id
 where i.account_id=a and i.id=p_id
$$;

create function app_private.pipeline_raw_path(p_run uuid) returns text language sql stable security definer set search_path='' as $$
 select o.path from app_private.ocr_runs r join app_private.stored_objects o on o.id=r.raw_bundle_object_id where r.id=p_run
$$;
create function app_private.pipeline_entry(p app_private.pipeline_papers) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',p.id,'source_id',p.source_id,'requested_revision',p.requested_revision,'revision',p.revision,
  'owner_id',p.owner_id,'stage',p.stage,'error_code',p.error_code,'generation',p.generation,'claim_id',p.claim_id,'state_revision',p.state_revision,
  'metadata_id',p.metadata_id,'eligible',p.eligible,'document_id',p.document_id,'original_object_id',p.original_object_id,
  'approval_id',p.approval_id,'page_count',p.page_count,'artifact_id',p.artifact_id,'failures',p.failures,'ocr_run_id',p.ocr_run_id,
  'due',p.stage in ('metadata','private_split','download','ocr_fund','ocr_submit','ocr_wait','render') and p.next_attempt_at<=clock_timestamp(),
  'document_sha256',(select encode(d.sha256,'hex') from app_private.documents d where d.id=p.document_id),
  'original_path',(select o.path from app_private.stored_objects o where o.id=p.original_object_id),
  'original_bytes',(select o.byte_count from app_private.stored_objects o where o.id=p.original_object_id),
  'raw_manifest_path',app_private.pipeline_raw_path(p.ocr_run_id),
  'attempt',(select jsonb_build_object('id',x.id,'state',x.state,'page_limit',x.page_limit,'provider_job_id',x.provider_job_id,
    'ocr_run_id',x.ocr_run_id,'submitted_at',x.submitted_at,'raw_manifest_path',app_private.pipeline_raw_path(x.ocr_run_id))
   from app_private.ocr_attempts x where x.paper_id=p.id order by x.created_at desc limit 1))
$$;

-- Fence: the caller must hold the current, unexpired claim of this paper.
-- Each fenced call renews the lease. NO KEY UPDATE keeps the customer's
-- import trigger (FK KEY SHARE on the paper) from ever waiting on a worker.
-- Stage functions keep the claim; the worker projects imports with
-- worker_pipeline_sync_imports and ends with release or defer.
create function app_private.pipeline_fenced(p_paper uuid,p_claim uuid,p_generation bigint) returns app_private.pipeline_papers
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers;
begin
 select * into p from app_private.pipeline_papers where id=p_paper for no key update;
 if not found or p.claim_id is distinct from p_claim or p.generation is distinct from p_generation or p.lease_until<=clock_timestamp()
 then raise exception 'stale_pipeline_claim'; end if;
 update app_private.pipeline_papers set lease_until=clock_timestamp()+make_interval(secs=>(select lease_seconds from app_private.pipeline_policy))
  where id=p.id returning * into p;
 return p;
end $$;
create function app_private.pipeline_set_stage(p_paper uuid,p_stage text,p_error text default null,p_resume text default null,p_delay interval default '0') returns void
language sql security definer set search_path='' as $$
 update app_private.pipeline_papers set stage=p_stage,error_code=p_error,resume_stage=p_resume,
  state_revision=state_revision+1,next_attempt_at=clock_timestamp()+p_delay,updated_at=now(),
  failures=case when p_error is null then 0 else failures end
 where id=p_paper
$$;
-- Any interested, active import of this paper (optionally for one account).
create function app_private.pipeline_interest(p_paper uuid,p_account uuid default null) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
  where pi.paper_id=p_paper and (p_account is null or pi.account_id=p_account) and i.desired_present and i.phase in ('accepted','resolving','acquiring'))
$$;

create function public.worker_pipeline_claim(p_claim_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare pol app_private.pipeline_policy; p app_private.pipeline_papers; retries integer;
begin
 if p_claim_id is null then raise exception 'invalid_claim'; end if;
 select * into strict pol from app_private.pipeline_policy;
 if not pol.enabled then return null; end if;
 select pp.* into p from app_private.pipeline_papers pp
 where (pp.lease_until is null or pp.lease_until<=clock_timestamp()) and (
  -- Paid/provider stages continue regardless of interest.
  (pp.stage in ('ocr_submit','ocr_wait','render') and pp.next_attempt_at<=clock_timestamp())
  or (pp.stage in ('metadata','private_split','download','ocr_fund') and pp.next_attempt_at<=clock_timestamp() and app_private.pipeline_interest(pp.id))
  or exists(select 1 from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
   where pi.paper_id=pp.id and i.desired_present and i.phase in ('accepted','resolving','acquiring')
   and (pi.retry_requested or (pi.synced_revision<pp.state_revision and pi.next_sync_at<=clock_timestamp()))))
 order by pp.next_attempt_at,pp.id limit 1 for no key update skip locked;
 if not found then return null; end if;
 update app_private.pipeline_imports set retry_requested=false where paper_id=p.id and retry_requested;
 get diagnostics retries=row_count;
 if retries>0 and p.stage in ('failed','needs_credits') and p.resume_stage is not null then
  perform app_private.pipeline_set_stage(p.id,p.resume_stage);
 end if;
 update app_private.pipeline_papers set generation=generation+1,claim_id=p_claim_id,
  lease_until=clock_timestamp()+make_interval(secs=>pol.lease_seconds),updated_at=now() where id=p.id returning * into p;
 return app_private.pipeline_entry(p);
end $$;

-- Global arXiv politeness: returns how many milliseconds this caller must wait
-- before its single request. Each call reserves the next slot.
create function public.worker_pipeline_arxiv_slot() returns integer language plpgsql security definer set search_path='' as $$
declare slot timestamptz; spacing integer;
begin
 update app_private.pipeline_policy set arxiv_next_request_at=greatest(arxiv_next_request_at,clock_timestamp())+make_interval(secs=>arxiv_spacing_ms/1000.0)
  where singleton returning arxiv_next_request_at,arxiv_spacing_ms into slot,spacing;
 return greatest(0,ceil(extract(epoch from (slot-make_interval(secs=>spacing/1000.0)-clock_timestamp()))*1000))::integer;
end $$;

-- Releases the claim with a delay. Failing is allowed only in stages that hold
-- no provider work (paid stages have their own explicit exits).
create function public.worker_pipeline_defer(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_seconds integer,
 p_error_code text default null,p_fail boolean default false,p_resume_stage text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p_seconds is null or p_seconds not between 0 and 86400 then raise exception 'invalid_delay'; end if;
 if p_fail then
  if p_error_code is null then raise exception 'error_required'; end if;
  if p.stage not in ('metadata','private_split','download','ocr_fund','render') then raise exception 'invalid_failure_stage'; end if;
  perform app_private.pipeline_set_stage(p.id,'failed',p_error_code,p_resume_stage);
 else
  update app_private.pipeline_papers set next_attempt_at=clock_timestamp()+make_interval(secs=>p_seconds),error_code=p_error_code,
   failures=failures+case when p_error_code is null then 0 else 1 end,updated_at=now() where id=p.id;
 end if;
 update app_private.pipeline_papers set claim_id=null,lease_until=null where id=p.id returning * into p;
 return app_private.pipeline_entry(p);
end $$;

create function public.worker_pipeline_release(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns void
language sql security definer set search_path='' as $$
 update app_private.pipeline_papers set claim_id=null,lease_until=null,updated_at=now()
 where id=p_paper_id and claim_id=p_claim_id and generation=p_generation
$$;

create function public.worker_pipeline_metadata(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_revision integer,p_metadata jsonb,
 p_eligible boolean,p_license_uri text default null,p_evidence jsonb default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; meta uuid;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'metadata' then raise exception 'invalid_pipeline_stage'; end if;
 if p.owner_id is not null or p_eligible is null or p_revision is null or (p.requested_revision>0 and p_revision<>p.requested_revision)
  or (p_eligible and (p_license_uri is null or p_evidence is null)) then raise exception 'invalid_pipeline_metadata'; end if;
 meta:=public.worker_record_arxiv_metadata(p.source_id,p_revision,p_metadata);
 -- Ineligible papers are converted privately per interested account.
 update app_private.pipeline_papers set revision=p_revision,metadata_id=meta,eligible=p_eligible,
  license_uri=case when p_eligible or (length(p_license_uri)<=512 and p_license_uri ~ '^https?://[A-Za-z0-9.-]+/[ -~]*$') then p_license_uri
   else 'https://arxiv.org/abs/'||p.source_id||'v'||p_revision end,
  evidence=case when p_eligible then p_evidence end where id=p.id;
 perform app_private.pipeline_set_stage(p.id,case when p_eligible then 'download' else 'private_split' end);
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

create function app_private.approve_private_asset(p app_private.pipeline_papers,p_document uuid,p_object uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare m app_private.catalog_metadata; existing uuid; result uuid:=gen_random_uuid(); pol app_private.library_policy;
 v_evidence jsonb;
begin
 select * into strict m from app_private.catalog_metadata where id=p.metadata_id;
 select * into strict pol from app_private.library_policy where singleton for update;
 select id into existing from app_private.catalog_asset_approvals where metadata_id=m.id and document_id=p_document and policy_version='owner-private-v1';
 if existing is not null then return existing; end if;
 v_evidence:=jsonb_build_object('scope','owner_private','owner_id',p.owner_id,'source_id',m.source_id,'source_revision',m.source_revision,
   'source_url','https://arxiv.org/abs/'||m.source_id||'v'||m.source_revision,'license_uri',p.license_uri);
 if (select count(*) from app_private.catalog_asset_approvals)+1>pol.approval_rows
 or (select coalesce(sum(octet_length(a.evidence::text)),0) from app_private.catalog_asset_approvals a)+octet_length(v_evidence::text)>pol.approval_bytes
 then raise exception 'catalog_approval_limit'; end if;
 insert into app_private.version_documents values(m.version_id,p_document) on conflict do nothing;
 insert into app_private.catalog_asset_approvals values(result,m.version_id,p_document,m.id,p_object,p.license_uri,'owner-private-v1',v_evidence,now());
 return result;
end $$;

-- An ineligible shared paper hands each interested import to that account's
-- private paper (created with the already-recorded metadata).
create function public.worker_pipeline_split_private(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns integer
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; link record; private uuid; moved integer:=0;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'private_split' or p.owner_id is not null then raise exception 'invalid_pipeline_stage'; end if;
 for link in select pi.account_id,pi.import_id from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
  where pi.paper_id=p.id and i.desired_present and i.phase in ('accepted','resolving','acquiring') order by pi.account_id,pi.import_id loop
  insert into app_private.pipeline_papers(owner_id,source_id,requested_revision,revision,metadata_id,eligible,license_uri,stage)
   values(link.account_id,p.source_id,p.requested_revision,p.revision,p.metadata_id,false,p.license_uri,'download')
   on conflict(owner_id,source_id,requested_revision) where owner_id is not null do nothing;
  select id into strict private from app_private.pipeline_papers where owner_id=link.account_id and source_id=p.source_id and requested_revision=p.requested_revision;
  update app_private.pipeline_imports set paper_id=private,synced_revision=0,next_sync_at=now() where account_id=link.account_id and import_id=link.import_id;
  moved:=moved+1;
 end loop;
 return moved;
end $$;

-- Records verified original bytes already written to Storage at the
-- content-addressed path. Reuses an existing render for identical bytes.
create function public.worker_pipeline_original(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_sha256 bytea,p_bytes bigint,
 p_pages integer,p_path text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; pol app_private.pipeline_policy; d app_private.documents; o app_private.stored_objects; approval uuid; artifact uuid;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 select * into strict pol from app_private.pipeline_policy;
 if p.stage<>'download' or (p.owner_id is null and not coalesce(p.eligible,false)) then raise exception 'invalid_pipeline_stage'; end if;
 if octet_length(p_sha256)<>32 or p_bytes not between 1 and pol.max_pdf_bytes or p_pages not between 1 and 250
  or p_path is distinct from (case when p.owner_id is null then '' else 'private/'||p.owner_id::text||'/' end)||'originals/'||encode(p_sha256,'hex')||'.pdf'
 then raise exception 'invalid_original'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if p.owner_id is null then
  select * into d from app_private.documents where scope='shared_catalog' and sha256=p_sha256 for update;
 else
  select * into d from app_private.documents where scope='owner_private' and owner_id=p.owner_id and sha256=p_sha256 for update;
 end if;
 if not found then
  if p.owner_id is null then
   insert into app_private.documents(sha256,scope,reuse_evidence,byte_count,page_count)
    values(p_sha256,'shared_catalog',p.evidence,p_bytes,p_pages) returning * into d;
  else
   insert into app_private.documents(sha256,scope,owner_id,byte_count,page_count)
    values(p_sha256,'owner_private',p.owner_id,p_bytes,p_pages) returning * into d;
  end if;
 elsif d.byte_count<>p_bytes then raise exception 'document_conflict'; end if;
 select * into o from app_private.stored_objects where path=p_path;
 if not found then
  insert into app_private.stored_objects(bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
   values('paper-assets',p_path,d.id,'verified',p_sha256,p_bytes,'application/pdf',clock_timestamp()) returning * into o;
  perform app_private.mark_paper_availability(o.id,'available');
 elsif o.document_id<>d.id or o.sha256<>p_sha256 or o.byte_count<>p_bytes or o.state<>'verified' then raise exception 'original_object_conflict'; end if;
 if p.owner_id is null then
  approval:=public.worker_approve_arxiv_asset(gen_random_uuid(),p.metadata_id,d.id,o.id,p.license_uri,p.evidence);
 else
  approval:=app_private.approve_private_asset(p,d.id,o.id);
 end if;
 select ra.id into artifact from app_private.render_artifacts ra join app_private.ocr_runs r on r.id=ra.ocr_run_id
  join app_private.stored_objects mo on mo.id=ra.manifest_object_id join app_private.paper_asset_availability av on av.object_id=mo.id
  where r.document_id=d.id and ra.renderer_version=pol.renderer_version and mo.state='verified' and av.state='available'
  order by ra.ready_at desc,ra.id limit 1;
 update app_private.pipeline_papers set document_id=d.id,original_object_id=o.id,approval_id=approval,page_count=d.page_count,artifact_id=artifact where id=p.id;
 perform app_private.pipeline_set_stage(p.id,case when artifact is null then 'ocr_fund' else 'done' end);
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

-- Reuses a finished render or retained raw OCR for identical bytes; otherwise
-- chooses a funder among interested accounts and reserves the OCR ceiling.
create function public.worker_pipeline_fund(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_page_limit integer,
 p_options_sha256 bytea,p_request_sha256 bytea) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; pol app_private.pipeline_policy; run uuid; raw_run uuid; artifact uuid; candidate record; op uuid;
 credits bigint; microusd bigint; funded boolean:=false; paused boolean:=false;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 select * into strict pol from app_private.pipeline_policy;
 if p.stage<>'ocr_fund' then raise exception 'invalid_pipeline_stage'; end if;
 if p_page_limit is null or p_page_limit<1 or p_page_limit>least(p.page_count,pol.max_ocr_pages)
  or octet_length(p_options_sha256)<>32 or octet_length(p_request_sha256)<>32 then raise exception 'invalid_ocr_request'; end if;
 -- No document lock here (reservation takes budget -> account). The partial
 -- unique index on active attempts serializes funding of identical bytes.
 select ra.id into artifact from app_private.render_artifacts ra join app_private.ocr_runs r on r.id=ra.ocr_run_id
  join app_private.stored_objects mo on mo.id=ra.manifest_object_id
  where r.document_id=p.document_id and ra.renderer_version=pol.renderer_version and mo.state='verified' limit 1;
 if artifact is not null then
  update app_private.pipeline_papers set artifact_id=artifact where id=p.id;
  perform app_private.pipeline_set_stage(p.id,'done');
  select * into p from app_private.pipeline_papers where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('funding','reused');
 end if;
 -- Retained raw OCR (another slot, an earlier renderer) is re-rendered free.
 select r.id into raw_run from app_private.ocr_runs r join app_private.stored_objects o on o.id=r.raw_bundle_object_id
  where r.document_id=p.document_id and r.provider='mathpix' and o.state='verified' order by (r.options_sha256=p_options_sha256) desc limit 1;
 if raw_run is not null then
  update app_private.pipeline_papers set ocr_run_id=raw_run where id=p.id;
  perform app_private.pipeline_set_stage(p.id,'render');
  select * into p from app_private.pipeline_papers where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('funding','reused_raw');
 end if;
 if exists(select 1 from app_private.ocr_attempts where document_id=p.document_id and state in ('funded','submitting','submitted','uncertain')) then
  -- Another source slot is converting identical bytes; wait for it.
  update app_private.pipeline_papers set next_attempt_at=clock_timestamp()+interval '15 seconds' where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('funding','waiting');
 end if;
 if not exists(select 1 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date and work_enabled) then
  update app_private.pipeline_papers set next_attempt_at=clock_timestamp()+interval '5 minutes',error_code='service_paused' where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('funding','paused');
 end if;
 insert into app_private.ocr_runs(document_id,provider,options_sha256) values(p.document_id,'mathpix',p_options_sha256)
  on conflict(document_id,provider,options_sha256) do nothing;
 select id into strict run from app_private.ocr_runs where document_id=p.document_id and provider='mathpix' and options_sha256=p_options_sha256;
 credits:=p_page_limit::bigint*pol.ocr_credits_per_page; microusd:=p_page_limit::bigint*pol.ocr_microusd_per_page;
 for candidate in select i.account_id from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
  where pi.paper_id=p.id and i.desired_present and i.phase in ('accepted','resolving','acquiring') order by i.created_at,i.account_id loop
  op:=gen_random_uuid();
  begin
   perform public.worker_reserve_operation(candidate.account_id,op,'ocr',p_request_sha256,pol.rate_version,credits,microusd);
   insert into app_private.ocr_attempts(paper_id,document_id,ocr_run_id,funder_account_id,operation_id,page_limit,state)
    values(p.id,p.document_id,run,candidate.account_id,op,p_page_limit,'funded');
   funded:=true; exit;
  exception
   when others then
    if sqlerrm in ('platform_budget_exhausted','too_many_active_operations') then paused:=true;
    elsif sqlerrm<>'insufficient_credits' then raise; end if;
  end;
 end loop;
 if funded then
  update app_private.pipeline_papers set ocr_run_id=run where id=p.id;
  perform app_private.pipeline_set_stage(p.id,'ocr_submit');
 elsif paused then update app_private.pipeline_papers set next_attempt_at=clock_timestamp()+interval '5 minutes',error_code='service_paused' where id=p.id;
 else perform app_private.pipeline_set_stage(p.id,'needs_credits','insufficient_credits','ocr_fund'); end if;
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p)||jsonb_build_object('funding',case when funded then 'funded' when paused then 'paused' else 'needs_credits' end);
end $$;

create function app_private.pipeline_settle_ocr(x app_private.ocr_attempts,p_pages_billed integer,p_charge_customer boolean) returns void
language plpgsql security definer set search_path='' as $$
declare pol app_private.pipeline_policy; op app_private.metered_operations; credits bigint; microusd bigint;
begin
 select * into strict pol from app_private.pipeline_policy;
 select * into strict op from app_private.metered_operations where account_id=x.funder_account_id and id=x.operation_id;
 microusd:=p_pages_billed::bigint*pol.ocr_microusd_per_page;
 credits:=case when p_charge_customer then least(op.credit_ceiling,p_pages_billed::bigint*pol.ocr_credits_per_page) else 0 end;
 perform public.worker_settle_operation(x.funder_account_id,x.operation_id,credits,microusd);
 if x.provider_job_id is not null then
  insert into app_private.provider_usage_events(account_id,operation_id,provider,provider_event_id,model,units,estimated_microusd)
   values(x.funder_account_id,x.operation_id,'mathpix',x.provider_job_id,'v3/pdf',jsonb_build_object('pages',p_pages_billed),microusd)
   on conflict(provider,provider_event_id) do nothing;
 end if;
end $$;

-- The only path to a paid POST. Grants once; a repeated begin means an earlier
-- holder may have posted, so the attempt becomes uncertain instead. A funder
-- who withdrew before the grant is released and another funder is sought.
create function public.worker_pipeline_begin_submit(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; x app_private.ocr_attempts;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'ocr_submit' then raise exception 'invalid_pipeline_stage'; end if;
 select * into strict x from app_private.ocr_attempts where paper_id=p.id and state in ('funded','submitting') for update;
 if x.state='submitting' then
  update app_private.ocr_attempts set state='uncertain',error_code='submission_unrecorded' where id=x.id;
  perform app_private.pipeline_set_stage(p.id,'ocr_uncertain','submission_uncertain');
  select * into p from app_private.pipeline_papers where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('granted',false);
 end if;
 if not app_private.pipeline_interest(p.id,x.funder_account_id) then
  update app_private.ocr_attempts set state='failed',error_code='funder_withdrew',finished_at=clock_timestamp() where id=x.id;
  perform public.worker_settle_operation(x.funder_account_id,x.operation_id,0,0);
  perform app_private.pipeline_set_stage(p.id,'ocr_fund');
  select * into p from app_private.pipeline_papers where id=p.id;
  return app_private.pipeline_entry(p)||jsonb_build_object('granted',false);
 end if;
 update app_private.ocr_attempts set state='submitting',submitted_at=clock_timestamp() where id=x.id;
 perform public.worker_mark_submitted(x.funder_account_id,x.operation_id);
 return app_private.pipeline_entry(p)||jsonb_build_object('granted',true,'attempt_id',x.id);
end $$;

-- Before any grant, a funded attempt that cannot be prepared (e.g. its original
-- is missing) releases its hold; the paper can be refunded on retry.
create function public.worker_pipeline_abandon_funding(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_error_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; x app_private.ocr_attempts;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'ocr_submit' or p_error_code !~ '^[a-z_]{1,64}$' then raise exception 'invalid_pipeline_stage'; end if;
 select * into strict x from app_private.ocr_attempts where paper_id=p.id and state='funded' for update;
 update app_private.ocr_attempts set state='failed',error_code=p_error_code,finished_at=clock_timestamp() where id=x.id;
 perform public.worker_settle_operation(x.funder_account_id,x.operation_id,0,0);
 perform app_private.pipeline_set_stage(p.id,'failed',p_error_code,'download');
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

-- Records the POST outcome by attempt, not by lease: a POST that outlived its
-- worker lease still records the billed provider job. Accepts a late result
-- for an attempt already marked uncertain because its acknowledgement was lost.
create function public.worker_pipeline_submitted(p_attempt_id uuid,p_provider_job_id text,p_uncertain_reason text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; x app_private.ocr_attempts; paper uuid;
begin
 if (p_provider_job_id is null)=(p_uncertain_reason is null) then raise exception 'invalid_submission_result'; end if;
 select paper_id into paper from app_private.ocr_attempts where id=p_attempt_id;
 if paper is null then raise exception 'attempt_unavailable'; end if;
 select * into strict p from app_private.pipeline_papers where id=paper for no key update;
 select * into strict x from app_private.ocr_attempts where id=p_attempt_id for update;
 if p_provider_job_id is not null then
  if x.state='submitted' and x.provider_job_id=p_provider_job_id then return app_private.pipeline_entry(p); end if;
  if not (x.state='submitting' or (x.state='uncertain' and x.provider_job_id is null)) then raise exception 'invalid_submission_result'; end if;
  update app_private.ocr_attempts set state='submitted',provider_job_id=p_provider_job_id,error_code=null where id=x.id;
  if p.stage in ('ocr_submit','ocr_uncertain') then perform app_private.pipeline_set_stage(p.id,'ocr_wait',null,null,'5 seconds'); end if;
 elsif x.state='submitting' then
  update app_private.ocr_attempts set state='uncertain',error_code=left(regexp_replace(lower(p_uncertain_reason),'[^a-z_]','_','g'),64) where id=x.id;
  if p.stage='ocr_submit' then perform app_private.pipeline_set_stage(p.id,'ocr_uncertain','submission_uncertain'); end if;
 end if;
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

-- Operator reconciliation of an uncertain submission: a found provider job
-- resumes polling; otherwise the hold settles (no customer charge; the
-- operator's estimate of billed pages is recorded) and the paper can be refunded.
create function public.worker_pipeline_resolve_uncertain(p_attempt_id uuid,p_provider_job_id text,p_pages_billed integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; x app_private.ocr_attempts; paper uuid;
begin
 select paper_id into paper from app_private.ocr_attempts where id=p_attempt_id;
 if paper is null then raise exception 'attempt_unavailable'; end if;
 select * into strict p from app_private.pipeline_papers where id=paper for no key update;
 select * into strict x from app_private.ocr_attempts where id=p_attempt_id for update;
 if x.state<>'uncertain' or (p_provider_job_id is null and (p_pages_billed is null or p_pages_billed not between 0 and 250)) then raise exception 'invalid_resolution'; end if;
 if p_provider_job_id is not null then
  update app_private.ocr_attempts set state='submitted',provider_job_id=p_provider_job_id,error_code=null where id=x.id;
  perform app_private.pipeline_set_stage(p.id,'ocr_wait');
 else
  update app_private.ocr_attempts set state='failed',error_code='submission_unaccepted',finished_at=clock_timestamp() where id=x.id returning * into x;
  perform app_private.pipeline_settle_ocr(x,p_pages_billed,false);
  perform app_private.pipeline_set_stage(p.id,'failed','conversion_failed','ocr_fund');
 end if;
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

-- Raw provider output has been written to Storage under raw/<manifest sha>/.
create function public.worker_pipeline_collected(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_pages_reported integer,
 p_raw_manifest_sha256 bytea,p_raw_manifest_bytes bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; x app_private.ocr_attempts; o uuid; v_path text;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'ocr_wait' then raise exception 'invalid_pipeline_stage'; end if;
 select * into strict x from app_private.ocr_attempts where paper_id=p.id and state='submitted' for update;
 if p_pages_reported is null or p_pages_reported not between 1 and 250 or octet_length(p_raw_manifest_sha256)<>32
  or p_raw_manifest_bytes not between 1 and 262144 then raise exception 'invalid_collection'; end if;
 -- No document lock: settlement below takes budget -> account, and customer
 -- paths take account -> document. The FK's KEY SHARE is compatible with them.
 v_path:='raw/'||encode(p_raw_manifest_sha256,'hex')||'/manifest.json';
 select id into o from app_private.stored_objects where path=v_path;
 if o is null then
  insert into app_private.stored_objects(bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
   values('paper-assets',v_path,p.document_id,'verified',p_raw_manifest_sha256,p_raw_manifest_bytes,'application/json',clock_timestamp()) returning id into o;
 end if;
 update app_private.ocr_attempts set state='collected',pages_reported=p_pages_reported,raw_manifest_object_id=o,finished_at=clock_timestamp()
  where id=x.id returning * into x;
 -- The first retained raw output stays the run's durable OCR identity.
 update app_private.ocr_runs set provider_job_id=coalesce(provider_job_id,x.provider_job_id),raw_bundle_object_id=coalesce(raw_bundle_object_id,o)
  where id=x.ocr_run_id;
 update app_private.pipeline_papers set ocr_run_id=x.ocr_run_id where id=p.id;
 perform app_private.pipeline_settle_ocr(x,least(p_pages_reported,x.page_limit),true);
 perform app_private.pipeline_set_stage(p.id,'render');
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

-- Provider reported a failed (or unusable) job. The customer is not charged;
-- the estimated provider cost is still recorded against the platform budget.
create function public.worker_pipeline_ocr_failed(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_error_code text,p_pages_billed integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; x app_private.ocr_attempts;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'ocr_wait' or p_error_code !~ '^[a-z_]{1,64}$' or p_pages_billed not between 0 and 250 then raise exception 'invalid_pipeline_stage'; end if;
 select * into strict x from app_private.ocr_attempts where paper_id=p.id and state='submitted' for update;
 update app_private.ocr_attempts set state='failed',error_code=p_error_code,finished_at=clock_timestamp() where id=x.id returning * into x;
 perform app_private.pipeline_settle_ocr(x,p_pages_billed,false);
 perform app_private.pipeline_set_stage(p.id,'failed','conversion_failed','ocr_fund');
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

-- Reader bundle members are already in Storage under reader/<manifest sha>/.
-- An existing artifact for the same run and renderer is adopted.
create function public.worker_pipeline_published(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_manifest_sha256 bytea,
 p_manifest_bytes bigint,p_renderer_version text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; pol app_private.pipeline_policy; o uuid; artifact uuid; v_path text;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 select * into strict pol from app_private.pipeline_policy;
 if p.stage<>'render' or p.ocr_run_id is null or p_renderer_version is distinct from pol.renderer_version or octet_length(p_manifest_sha256)<>32
  or p_manifest_bytes not between 1 and 262144 then raise exception 'invalid_publication'; end if;
 select id into artifact from app_private.render_artifacts where ocr_run_id=p.ocr_run_id and renderer_version=p_renderer_version;
 if artifact is null then
  v_path:='reader/'||encode(p_manifest_sha256,'hex')||'/manifest.json';
  perform 1 from app_private.paper_storage_capacity where singleton for update;
  select id into o from app_private.stored_objects where path=v_path and document_id=p.document_id;
  if o is null then
   insert into app_private.stored_objects(bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
    values('paper-assets',v_path,p.document_id,'verified',p_manifest_sha256,p_manifest_bytes,'application/json',clock_timestamp()) returning id into o;
   perform app_private.mark_paper_availability(o,'available');
  end if;
  insert into app_private.render_artifacts(ocr_run_id,renderer_version,manifest_object_id) values(p.ocr_run_id,p_renderer_version,o)
   on conflict(ocr_run_id,renderer_version) do nothing;
  select id into strict artifact from app_private.render_artifacts where ocr_run_id=p.ocr_run_id and renderer_version=p_renderer_version;
 end if;
 update app_private.pipeline_papers set artifact_id=artifact where id=p.id;
 perform app_private.pipeline_set_stage(p.id,'done');
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

-- Projects paper state onto each interested import. Never holds the paper row.
-- All link accounts are locked first in id order, so the library policy lock
-- taken per link can never invert against a customer's account -> policy order.
-- A failing link backs off alone; it never fails the paper or other links.
create function public.worker_pipeline_sync_imports(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns integer
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; link record; i app_private.import_requests; s bigint; changed integer:=0; target text; err text; retry boolean;
begin
 select * into p from app_private.pipeline_papers where id=p_paper_id;
 if not found or p.claim_id is distinct from p_claim_id or p.generation is distinct from p_generation or p.lease_until<=clock_timestamp()
 then raise exception 'stale_pipeline_claim'; end if;
 perform 1 from app_private.accounts where id in (select account_id from app_private.pipeline_imports where paper_id=p.id and synced_revision<p.state_revision)
  and closed_at is null order by id for no key update;
 for link in select pi.* from app_private.pipeline_imports pi where pi.paper_id=p.id and pi.synced_revision<p.state_revision
  and pi.next_sync_at<=clock_timestamp() order by pi.account_id,pi.import_id loop
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
       error_code=err,retryable=coalesce(retry,false) where account_id=i.account_id and id=i.id;
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

-- Delivery: the Edge function signs member URLs after this authorization.
create function public.worker_reader_descriptor(p_account_id uuid,p_item_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r record;
begin
 perform public.worker_consume_request(p_account_id,'reader-download');
 select li.id as item_id,li.document_id,ra.id as artifact_id,ra.renderer_version,mo.path,encode(mo.sha256,'hex') as manifest_sha256,mo.byte_count
 into r from app_private.library_items li join app_private.render_artifacts ra on ra.id=li.artifact_id
 join app_private.stored_objects mo on mo.id=ra.manifest_object_id
 join app_private.library_asset_projection ap on (ap.account_id,ap.item_id)=(li.account_id,li.id)
 where li.account_id=p_account_id and li.id=p_item_id and li.removed_at is null and mo.state='verified' and ap.render_availability='available';
 if not found then raise exception 'reader_unavailable' using errcode='42501'; end if;
 return jsonb_build_object('item_id',r.item_id,'document_id',r.document_id,'artifact_id',r.artifact_id,'renderer_version',r.renderer_version,
  'bucket','paper-assets','manifest_path',r.path,'manifest_sha256',r.manifest_sha256,'manifest_bytes',r.byte_count);
end $$;

create function public.worker_chat_context(p_account_id uuid,p_document_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r record;
begin
 select ro.path,cm.metadata->>'title' as title into r from app_private.library_items li
 join app_private.render_artifacts ra on ra.id=li.artifact_id join app_private.ocr_runs o on o.id=ra.ocr_run_id
 join app_private.stored_objects ro on ro.id=o.raw_bundle_object_id
 left join app_private.catalog_asset_approvals ca on ca.id=li.approval_id left join app_private.catalog_metadata cm on cm.id=ca.metadata_id
 where li.account_id=p_account_id and li.document_id=p_document_id and li.removed_at is null limit 1;
 if not found then raise exception 'document_unavailable' using errcode='42501'; end if;
 return jsonb_build_object('bucket','paper-assets','path',regexp_replace(r.path,'manifest\.json$','standalone.mmd'),'title',r.title);
end $$;

create function public.worker_record_provider_usage(p_account_id uuid,p_operation_id uuid,p_provider text,p_provider_event_id text,
 p_model text,p_units jsonb,p_microusd bigint) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_provider !~ '^[a-z0-9_-]{1,32}$' or p_provider_event_id is null or length(p_provider_event_id) not between 1 and 256
  or p_units is null or jsonb_typeof(p_units)<>'object' or octet_length(p_units::text)>4096 or p_microusd is null or p_microusd<0
 then raise exception 'invalid_usage'; end if;
 insert into app_private.provider_usage_events(account_id,operation_id,provider,provider_event_id,model,units,estimated_microusd)
  values(p_account_id,p_operation_id,p_provider,p_provider_event_id,left(p_model,128),p_units,p_microusd)
  on conflict(provider,provider_event_id) do nothing;
end $$;

-- Operator controls (service role only; used by scripts/ops tooling).
create function public.worker_set_platform_budget(p_period date,p_limit_microusd bigint,p_enabled boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b app_private.platform_budgets;
begin
 if p_period is null or extract(day from p_period)<>1 or p_limit_microusd is null or p_enabled is null then raise exception 'invalid_budget'; end if;
 insert into app_private.platform_budgets(period,limit_microusd,work_enabled) values(p_period,p_limit_microusd,p_enabled)
  on conflict(period) do update set limit_microusd=excluded.limit_microusd,work_enabled=excluded.work_enabled returning * into b;
 return to_jsonb(b);
end $$;
create function public.worker_set_pipeline_enabled(p_enabled boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_policy;
begin
 if p_enabled is null then raise exception 'invalid_policy'; end if;
 update app_private.pipeline_policy set enabled=p_enabled where singleton returning * into p;
 return to_jsonb(p)-'arxiv_next_request_at';
end $$;
create function public.worker_pipeline_policy() returns jsonb language sql stable security definer set search_path='' as $$
 select to_jsonb(p)-'arxiv_next_request_at' from app_private.pipeline_policy p
$$;

-- Owner dashboard (MFA): pipeline papers and paid attempts. Metadata only.
create function public.v1_admin_pipeline() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 return jsonb_build_object(
  'policy',(select to_jsonb(p)-'arxiv_next_request_at' from app_private.pipeline_policy p),
  'stages',coalesce((select jsonb_object_agg(stage,n) from (select stage,count(*) n from app_private.pipeline_papers group by stage) s),'{}'::jsonb),
  'papers',coalesce((select jsonb_agg(x order by x->>'updated_at' desc) from (select jsonb_build_object('id',pp.id,'source',pp.source_id||coalesce('v'||pp.revision,''),
    'title',cm.metadata->>'title','private',pp.owner_id is not null,'stage',pp.stage,'error_code',pp.error_code,'failures',pp.failures,
    'interested',(select count(*) from app_private.pipeline_imports pi where pi.paper_id=pp.id),'updated_at',pp.updated_at) x
    from app_private.pipeline_papers pp left join app_private.catalog_metadata cm on cm.id=pp.metadata_id order by pp.updated_at desc limit 100) papers),'[]'::jsonb),
  'attempts',coalesce((select jsonb_agg(x) from (select jsonb_build_object('id',a.id,'paper_id',a.paper_id,'state',a.state,'page_limit',a.page_limit,
    'pages_reported',a.pages_reported,'provider_job_id',a.provider_job_id,'error_code',a.error_code,'created_at',a.created_at,'finished_at',a.finished_at) x
    from app_private.ocr_attempts a order by a.created_at desc limit 50) attempts),'[]'::jsonb));
end $$;
revoke all on function public.v1_admin_pipeline() from public,anon;
grant execute on function public.v1_admin_pipeline() to authenticated;

-- Import resolution also accepts the caller's own private documents.
create or replace function public.worker_resolve_import(p_account_id uuid,p_import_id uuid,p_expected_state_seq bigint,p_expected_intent_revision bigint,
 p_approval_id uuid,p_artifact_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare i app_private.import_requests; ca app_private.catalog_asset_approvals; m app_private.catalog_metadata; li app_private.library_items;
 s bigint; item_id uuid; digest bytea; conflict boolean; e jsonb; p app_private.library_policy;
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
 conflict:=li.id is not null and li.removed_at is not null and (li.last_remove_seq>i.observed_cursor or li.last_remove_seq>i.created_seq);
 s:=app_private.library_next_seq(p_account_id);
 item_id:=li.id;
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

do $$ declare t text; begin
 for t in select tablename from pg_tables where schemaname='app_private' loop
  execute format('alter table app_private.%I enable row level security',t);
 end loop;
end $$;
revoke all on all tables in schema app_private from public,anon,authenticated,service_role;
revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
do $$ declare f text; begin
 for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname in ('worker_pipeline_claim','worker_pipeline_arxiv_slot','worker_pipeline_defer','worker_pipeline_release',
   'worker_pipeline_metadata','worker_pipeline_split_private','worker_pipeline_original','worker_pipeline_fund','worker_pipeline_begin_submit','worker_pipeline_abandon_funding','worker_pipeline_submitted','worker_pipeline_resolve_uncertain',
   'worker_pipeline_collected','worker_pipeline_ocr_failed','worker_pipeline_published','worker_pipeline_sync_imports','worker_reader_descriptor',
   'worker_chat_context','worker_record_provider_usage','worker_set_platform_budget','worker_set_pipeline_enabled','worker_pipeline_policy') loop
  execute format('revoke all on function %s from public,anon,authenticated',f);
  execute format('grant execute on function %s to service_role',f);
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
