-- PDF uploads (migration 031; docs/architecture/PDF_UPLOADS.md): owner-only sessions, size/quota/
-- credit limits, idempotent begin and finalize, an uploaded paper through the pipeline to the
-- library (v4 only), a reader's PDF supplying a failed or closed web paper, the read-level rule,
-- the janitor, and account deletion.
begin;
insert into auth.users values('31000000-0000-0000-0000-00000000000a'),('31000000-0000-0000-0000-00000000000b'),('31000000-0000-0000-0000-00000000000c');
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits('31000000-0000-0000-0000-00000000000a','adjustment','upload-test-a',200,now()-interval '1 day',null,'Upload test grant');
select public.worker_grant_credits('31000000-0000-0000-0000-00000000000b','adjustment','upload-test-b',200,now()-interval '1 day',null,'Upload test grant');
select public.worker_set_pipeline_enabled(true);
reset role;
-- Earlier suites' papers never get in the way of this suite's claims.
update app_private.pipeline_papers set next_attempt_at=now()+interval '1 day';
update app_private.pipeline_imports set next_sync_at=now()+interval '1 day',retry_requested=false;

\set A '31000000-0000-0000-0000-00000000000a'
\set B '31000000-0000-0000-0000-00000000000b'
\set C '31000000-0000-0000-0000-00000000000c'
\set U1 '31000000-0000-0000-0000-0000000000a1'
\set sha1 '\\x1111111111111111111111111111111111111111111111111111111111111111'

-- Only the Edge function (service role) begins and finalizes; readers read their own sources only.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,1000,%L,null,null,null,%L)',:'A',:'U1',:'sha1','paper','A draft'),'permission denied');
select test.reject(format('select public.worker_finalize_pdf_upload(%L,%L,0,1000)',:'A',:'U1'),'permission denied');
select test.reject($q$select public.worker_claim_stale_pdf_uploads(10)$q$,'permission denied');
reset role;
set role anon;
select test.reject('select public.v4_library_page()','permission denied');
select test.reject($q$select public.v1_import_pdf_sources(gen_random_uuid())$q$,'permission denied');
reset role;

set role service_role;
-- Validation, size and credits.
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,67108865,%L,null,null,null,%L)',:'A',:'U1',:'sha1','paper','A draft'),'upload_too_large');
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,1000,%L,null,null,null,%L)',:'A',:'U1',:'sha1','paper',''),'invalid_upload');
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,1000,%L,null,null,null,%L)',:'A',:'U1',:'sha1','paper',E'A\u0007draft'),'invalid_upload');
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,1000,%L,null,null,%L,null)',:'A',:'U1',:'sha1','source','2305.18290'),'invalid_web_source_id');
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,1000,%L,null,null,null,%L)',:'A',:'U1','\x11','paper','A draft'),'invalid_upload');
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,1000,%L,null,null,null,%L)',:'C',:'U1',:'sha1','paper','A draft'),'insufficient_credits');
-- A paper of its own: the session names the private object path.
select public.worker_begin_pdf_upload(:'A',:'U1',:'sha1',1000,'paper',null,null,null,'  A   workshop draft ') as began \gset
select test.assert(:'began'::jsonb->>'bucket'='paper-uploads' and :'began'::jsonb->>'path'=:'A'||'/'||:'U1'||'.pdf' and :'began'::jsonb->>'state'='pending',
 'session names its private object');
select test.assert(public.worker_begin_pdf_upload(:'A',:'U1',:'sha1',1000,'paper',null,null,null,'A workshop draft')->>'path'=:'began'::jsonb->>'path','begin is idempotent');
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,1001,%L,null,null,null,%L)',:'A',:'U1',:'sha1','paper','A workshop draft'),'upload_id_conflict');
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,1000,%L,null,null,null,%L)',:'B',:'U1',:'sha1','paper','A workshop draft'),'upload_id_conflict');
reset role;
select test.assert((select state='pending' and owner_id=:'A' and byte_count=1000 from app_private.stored_objects where path=:'A'||'/'||:'U1'||'.pdf'),'pending owner object');
select test.assert((select metadata->>'title'='A workshop draft' from app_private.pdf_uploads where id=:'U1'),'title tidied');

-- Quota: the owner's private originals plus unfinished uploads stay within the private quota.
update app_private.pipeline_policy set private_bytes_per_owner=1500;
set role service_role;
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,600,%L,null,null,null,%L)',:'A',gen_random_uuid(),:'sha1','paper','Another'),'upload_quota');
reset role;
update app_private.pipeline_policy set private_bytes_per_owner=1073741824;
update app_private.pdf_upload_policy set account_active=1;
set role service_role;
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,600,%L,null,null,null,%L)',:'A',gen_random_uuid(),:'sha1','paper','Another'),'upload_limit');
reset role;
update app_private.pdf_upload_policy set account_active=10;

-- Finalize: the import appears for v4 readers only, with the reader's title; finalizing again replays.
set role service_role;
select test.reject(format('select public.worker_finalize_pdf_upload(%L,%L,0,1000)',:'B',:'U1'),'upload_unavailable');
select test.reject(format('select public.worker_finalize_pdf_upload(%L,%L,0,null)',:'A',:'U1'),'upload_incomplete');
select test.reject(format('select public.worker_finalize_pdf_upload(%L,%L,0,999)',:'A',:'U1'),'upload_incomplete');
select public.worker_finalize_pdf_upload(:'A',:'U1',0,1000) as finalized \gset
select test.assert(:'finalized'::jsonb->'result'->>'status'='applied' and :'finalized'::jsonb->'entry'->>'source'='upload'
 and :'finalized'::jsonb->'entry'->>'source_id'='upload:'||:'U1' and :'finalized'::jsonb->'entry'->'metadata'->>'title'='A workshop draft'
 and :'finalized'::jsonb->'entry'->'source_url'='null'::jsonb and :'finalized'::jsonb->'entry'->>'source_revision'='1','upload import entry');
select test.assert((public.worker_finalize_pdf_upload(:'A',:'U1',0,1000)->>'replayed')::boolean,'finalize replays');
reset role;
select test.assert((select stage='download' and owner_id=:'A' and revision=1 and metadata_id is not null from app_private.pipeline_papers where source_id='upload:'||:'U1'),
 'the private paper starts at download');
select test.assert((select metadata->>'title'='Uploaded PDF' from app_private.catalog_metadata where source_id='upload:'||:'U1'),'the catalog keeps a neutral placeholder');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert(exists(select 1 from jsonb_array_elements(public.v4_library_page()->'entries') e where e->>'source'='upload' and e->'metadata'->>'title'='A workshop draft'),
 'v4 shows the upload');
select test.assert(not exists(select 1 from jsonb_array_elements(public.v3_library_page()->'entries') e where e->>'source'='upload')
 and not exists(select 1 from jsonb_array_elements(public.v2_library_page()->'entries') e where e->>'source'='upload'),'v2/v3 never see uploads');
select test.assert(not exists(select 1 from jsonb_array_elements(public.v3_library_changes(0)->'changes') c, jsonb_array_elements(c->'entries') e where e->>'source'='upload')
 and exists(select 1 from jsonb_array_elements(public.v4_library_changes(0)->'changes') c, jsonb_array_elements(c->'entries') e where e->>'source'='upload'),
 'changes by read level');
select set_config('request.jwt.claim.sub',:'B',false);
select test.assert(jsonb_array_length(public.v4_library_page()->'entries')=0,'another account sees nothing');
reset role;

-- The worker verifies the bytes before they become the private original.
select id as up_paper from app_private.pipeline_papers where source_id='upload:'||:'U1' \gset
update app_private.pipeline_papers set next_attempt_at=now() where id=:'up_paper';
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'generation')::bigint as gen \gset
select test.assert(:'entry'::jsonb->>'id'=:'up_paper' and :'entry'::jsonb->>'source_kind'='upload' and :'entry'::jsonb->>'title'='A workshop draft'
 and :'entry'::jsonb->'upload'->>'path'=:'A'||'/'||:'U1'||'.pdf' and :'entry'::jsonb->'upload'->>'sha256'=repeat('11',32)
 and (:'entry'::jsonb->'upload'->>'bytes')::int=1000,'the worker sees the upload');
select test.assert((public.worker_pipeline_admit_download(:'up_paper',:'claim',:'gen')->>'admitted')::boolean,'admitted');
select test.reject(format('select public.worker_pipeline_upload_original(%L,%L,%s,%L,%L,1000,3,%L)',:'up_paper',:'claim',:'gen',:'U1',
 '\x'||repeat('12',32),'private/'||:'A'||'/originals/'||repeat('12',32)||'.pdf'),'upload_mismatch');
select test.assert(public.worker_pipeline_upload_original(:'up_paper',:'claim',:'gen',:'U1',:'sha1',1000,3,
 'private/'||:'A'||'/originals/'||repeat('11',32)||'.pdf')->>'stage'='ocr_fund','upload became the private original');
reset role;
select test.assert((select state='consumed' from app_private.pdf_uploads where id=:'U1')
 and (select state='deleting' from app_private.stored_objects where path=:'A'||'/'||:'U1'||'.pdf'),'upload spent, its object queued for deletion');
select test.assert((select policy_version='owner-upload-v1' and license_uri='reader-upload' and evidence->>'supplied'='reader_upload' and evidence->>'upload_id'=:'U1'
 and not evidence ? 'title' from app_private.catalog_asset_approvals where id=(select approval_id from app_private.pipeline_papers where id=:'up_paper')),'upload provenance');
select test.assert((select scope='owner_private' and owner_id=:'A' from app_private.documents where id=(select document_id from app_private.pipeline_papers where id=:'up_paper')),
 'converted privately');
set role service_role;
select test.assert(public.worker_pipeline_fund(:'up_paper',:'claim',:'gen',3,('\x'||repeat('31',32))::bytea,('\x'||repeat('32',32))::bytea)->>'funding'='funded','metered like any private conversion');
select public.worker_pipeline_begin_submit(:'up_paper',:'claim',:'gen')->>'attempt_id' as attempt \gset
select public.worker_pipeline_submitted(:'attempt','upload-job-1');
select public.worker_pipeline_collected(:'up_paper',:'claim',:'gen',3,('\x'||repeat('3a',32))::bytea,2048);
select test.assert(public.worker_pipeline_published(:'up_paper',:'claim',:'gen',('\x'||repeat('3b',32))::bytea,2048,'timestep-mathpix-mathml-v1')->>'stage'='done','published');
select test.assert(public.worker_pipeline_sync_imports(:'up_paper',:'claim',:'gen')=1,'resolved');
select public.worker_pipeline_release(:'up_paper',:'claim',:'gen');
reset role;
select library_item_id as up_item from app_private.import_requests where id=:'U1' \gset
select test.assert(app_private.library_item_entry(:'A',:'up_item')->>'source'='upload' and app_private.library_item_entry(:'A',:'up_item')->'metadata'->>'title'='A workshop draft'
 and app_private.library_item_entry(:'A',:'up_item')->'source_url'='null'::jsonb and app_private.library_item_entry(:'A',:'up_item')->>'readiness'='converted_ready','upload item entry');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert(not exists(select 1 from jsonb_array_elements(public.v3_library_page()->'entries') e where e->>'library_item_id'=:'up_item' or e->>'id'=:'up_item'),
 'v3 sees no upload item and no reference to one');
reset role;

-- The same bytes through arXiv (a private, non-CC copy) never resolve onto the upload-pinned item.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_begin_import('31000000-0000-0000-0000-0000000000b1','2006.11239',(public.v4_library_page()->>'baseline_cursor')::bigint);
reset role;
select id as ax from app_private.pipeline_papers where owner_id is null and source_id='2006.11239' \gset
update app_private.pipeline_papers set next_attempt_at=now()+interval '1 day';
update app_private.pipeline_papers set next_attempt_at=now() where id=:'ax';
set role service_role;
select gen_random_uuid() as claim \gset
select (public.worker_pipeline_claim(:'claim')->>'generation')::bigint as gen \gset
select public.worker_pipeline_metadata(:'ax',:'claim',:'gen',2,'{"title":"Denoising Diffusion Probabilistic Models","authors":["Jonathan Ho"],"categories":["cs.LG"]}',
 false,'http://arxiv.org/licenses/nonexclusive-distrib/1.0/');
select public.worker_pipeline_split_private(:'ax',:'claim',:'gen');
select public.worker_pipeline_release(:'ax',:'claim',:'gen');
reset role;
select id as ax2 from app_private.pipeline_papers where owner_id=:'A' and source_id='2006.11239' \gset
update app_private.pipeline_papers set next_attempt_at=now()+interval '1 day' where id<>:'ax2';
update app_private.pipeline_papers set next_attempt_at=now() where id=:'ax2';
set role service_role;
select gen_random_uuid() as claim \gset
select (public.worker_pipeline_claim(:'claim')->>'generation')::bigint as gen \gset
select test.assert(public.worker_pipeline_original(:'ax2',:'claim',:'gen',:'sha1',1000,3,'private/'||:'A'||'/originals/'||repeat('11',32)||'.pdf')->>'stage'='done',
 'identical bytes reuse the render');
select public.worker_pipeline_sync_imports(:'ax2',:'claim',:'gen');
reset role;
select test.assert((select phase='membership_conflict' and library_item_id is null from app_private.import_requests where id='31000000-0000-0000-0000-0000000000b1'),
 'arXiv import does not adopt the upload item');

-- Device fallback: a web paper with no open copy fails at download (`not_open`); the reader's own PDF
-- supplies that same import, which is retried at once.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_begin_web_import('31000000-0000-0000-0000-0000000000c1','openalex:W3100000001',(public.v4_library_page()->>'baseline_cursor')::bigint);
reset role;
select id as w from app_private.pipeline_papers where owner_id is null and source_id='openalex:W3100000001' \gset
update app_private.pipeline_papers set next_attempt_at=now()+interval '1 day';
update app_private.pipeline_papers set next_attempt_at=now() where id=:'w';
set role service_role;
select gen_random_uuid() as claim \gset
select (public.worker_pipeline_claim(:'claim')->>'generation')::bigint as gen \gset
select test.reject(format('select public.worker_pipeline_web_metadata(%L,%L,%s,%L,null,%L,null)',:'w',:'claim',:'gen',
 '{"title":"A closed paper","authors":[],"categories":[]}','{{https://a.example.org/x.pdf},{https://b.example.org/y.pdf}}'),'invalid_pipeline_metadata');
select test.assert(public.worker_pipeline_web_metadata(:'w',:'claim',:'gen','{"title":"A closed paper","authors":["Ada Lovelace"],"categories":[]}','10.5555/closed.1',
 '{}','https://publisher.example.com/closed-1')->>'stage'='private_split','a work with no open copy keeps its metadata');
select public.worker_pipeline_split_private(:'w',:'claim',:'gen');
select public.worker_pipeline_release(:'w',:'claim',:'gen');
reset role;
select id as wp from app_private.pipeline_papers where owner_id=:'A' and source_id='openalex:W3100000001' \gset
select test.assert((select pdf_urls is null and landing_url='https://publisher.example.com/closed-1' from app_private.pipeline_papers where id=:'wp'),'no locations');
update app_private.pipeline_papers set next_attempt_at=now()+interval '1 day' where id<>:'wp';
update app_private.pipeline_papers set next_attempt_at=now() where id=:'wp';
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'generation')::bigint as gen \gset
select test.assert(:'entry'::jsonb->'upload'='null'::jsonb,'no upload yet');
select public.worker_pipeline_defer(:'wp',:'claim',:'gen',0,'not_open',true,'download');
reset role;
-- Project the failure onto the import (a fresh claim projects it).
set role service_role;
select gen_random_uuid() as claim \gset
select (public.worker_pipeline_claim(:'claim')->>'generation')::bigint as gen \gset
select public.worker_pipeline_sync_imports(:'wp',:'claim',:'gen');
select public.worker_pipeline_release(:'wp',:'claim',:'gen');
reset role;
select test.assert((select phase='failed' and error_code='not_open' and retryable from app_private.import_requests where id='31000000-0000-0000-0000-0000000000c1'),
 'failed: not openly available, retryable');
select test.assert((select auto_retry_at is null from app_private.pipeline_papers where id=:'wp'),'no automatic retry for a closed paper');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v1_import_pdf_sources('31000000-0000-0000-0000-0000000000c1') as sources \gset
select test.assert(:'sources'::jsonb->'links'='["https://publisher.example.com/closed-1","https://doi.org/10.5555/closed.1"]'::jsonb
 and :'sources'::jsonb->>'title'='A closed paper','device links: the landing page, then the DOI');
select set_config('request.jwt.claim.sub',:'B',false);
select test.reject($q$select public.v1_import_pdf_sources('31000000-0000-0000-0000-0000000000c1')$q$,'import_unavailable');
reset role;
\set U2 '31000000-0000-0000-0000-0000000000a2'
\set sha2 '\\x2222222222222222222222222222222222222222222222222222222222222222'
select intent_revision as rev from app_private.import_requests where id='31000000-0000-0000-0000-0000000000c1' \gset
set role service_role;
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,2000,%L,%L,%s,null,null)',:'B',:'U2',:'sha2','import','31000000-0000-0000-0000-0000000000c1',:'rev'),'upload_target_unavailable');
select public.worker_begin_pdf_upload(:'A',:'U2',:'sha2',2000,'import','31000000-0000-0000-0000-0000000000c1',:'rev',null,null);
select public.worker_finalize_pdf_upload(:'A',:'U2',0,2000) as attached \gset
select test.assert(:'attached'::jsonb->'result'->>'status'='applied' and :'attached'::jsonb->'entry'->>'phase'='acquiring','the failed import is retried');
select test.assert((public.worker_finalize_pdf_upload(:'A',:'U2',0,null)->>'replayed')::boolean,'finalize replays even after the object is gone');
reset role;
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'generation')::bigint as gen \gset
select test.assert(:'entry'::jsonb->>'id'=:'wp' and :'entry'::jsonb->>'stage'='download' and :'entry'::jsonb->'upload'->>'id'=:'U2','the retried paper uses the upload');
select test.assert((public.worker_pipeline_admit_download(:'wp',:'claim',:'gen')->>'admitted')::boolean,'admitted');
select test.assert(public.worker_pipeline_upload_original(:'wp',:'claim',:'gen',:'U2',:'sha2',2000,4,
 'private/'||:'A'||'/originals/'||repeat('22',32)||'.pdf')->>'stage'='ocr_fund','supplied original');
select public.worker_pipeline_release(:'wp',:'claim',:'gen');
reset role;
select test.assert((select policy_version='owner-private-v1' and evidence->>'supplied'='reader_upload' and evidence->'pdf_urls'='null'::jsonb
 and evidence->>'source_url'='https://publisher.example.com/closed-1'
 from app_private.catalog_asset_approvals where id=(select approval_id from app_private.pipeline_papers where id=:'wp')),'web provenance records the reader upload');

-- A closed paper the reader names (Add → "isn't openly available" → Upload): a new web import supplied at once.
\set U3 '31000000-0000-0000-0000-0000000000a3'
set role service_role;
select public.worker_begin_pdf_upload(:'A',:'U3',:'sha2',2000,'source',null,null,'openalex:w3100000002',null);
select public.worker_finalize_pdf_upload(:'A',:'U3',0,2000) as sourced \gset
reset role;
select test.assert(:'sourced'::jsonb->'entry'->>'source'='web' and :'sourced'::jsonb->'entry'->>'source_id'='openalex:W3100000002'
 and (select count(*)=1 from app_private.pipeline_imports pi join app_private.pipeline_papers pp on pp.id=pi.paper_id
  where pi.import_id=:'U3' and pp.owner_id is null),'a web import linked to the shared paper');

-- Rejected bytes are spent, so a retry goes back to the paper's locations.
\set U4 '31000000-0000-0000-0000-0000000000a4'
set role service_role;
select public.worker_begin_pdf_upload(:'A',:'U4',:'sha2',2000,'source',null,null,'openalex:W3100000002',null);
select public.worker_finalize_pdf_upload(:'A',:'U4',0,2000);
reset role;
select test.assert((select state='abandoned' from app_private.pdf_uploads where id=:'U3') and (select state='finalized' from app_private.pdf_uploads where id=:'U4'),
 'a newer upload for the same paper replaces the older one');

-- Janitor: expired sessions, spent uploads and uploads no import wants are deleted after confirmation.
\set U5 '31000000-0000-0000-0000-0000000000a5'
set role service_role;
select public.worker_begin_pdf_upload(:'B',:'U5',:'sha2',2000,'paper',null,null,null,'Never sent');
reset role;
update app_private.pdf_uploads set expires_at=now()-interval '1 hour' where id=:'U5';
set role service_role;
select test.reject(format('select public.worker_finalize_pdf_upload(%L,%L,0,2000)',:'B',:'U5'),'upload_expired');
select public.worker_claim_stale_pdf_uploads(100) as stale \gset
select test.assert(exists(select 1 from jsonb_array_elements(:'stale'::jsonb) x where x->>'path'=:'B'||'/'||:'U5'||'.pdf')
 and exists(select 1 from jsonb_array_elements(:'stale'::jsonb) x where x->>'path'=:'A'||'/'||:'U1'||'.pdf')
 and exists(select 1 from jsonb_array_elements(:'stale'::jsonb) x where x->>'path'=:'A'||'/'||:'U3'||'.pdf')
 and not exists(select 1 from jsonb_array_elements(:'stale'::jsonb) x where x->>'path'=:'A'||'/'||:'U4'||'.pdf'),'stale objects claimed; the wanted upload kept');
select test.assert(public.worker_confirm_pdf_uploads_deleted(array(select (x->>'id')::uuid from jsonb_array_elements(:'stale'::jsonb) x))=jsonb_array_length(:'stale'::jsonb),
 'deletions confirmed');
reset role;
select test.assert((select state='deleted' from app_private.stored_objects where path=:'B'||'/'||:'U5'||'.pdf'),'capacity released after deletion');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_cancel_import('31000000-0000-0000-0000-0000000000d1',:'U3',1);
select public.v2_cancel_import('31000000-0000-0000-0000-0000000000d2',:'U4',1);
reset role;
set role service_role;
select test.assert(exists(select 1 from jsonb_array_elements(public.worker_claim_stale_pdf_uploads(100)) x where x->>'path'=:'A'||'/'||:'U4'||'.pdf'),
 'an upload whose import was cancelled is deleted');
reset role;

-- Account deletion removes upload sessions (their titles are personal) and returns their objects.
\set U6 '31000000-0000-0000-0000-0000000000a6'
set role service_role;
select public.worker_begin_pdf_upload(:'B',:'U6',:'sha2',2000,'paper',null,null,null,'Private draft title');
select public.worker_delete_account_begin(:'B') as deleted \gset
reset role;
select test.assert(not exists(select 1 from app_private.pdf_uploads where account_id=:'B'),'upload rows deleted');
select test.assert(exists(select 1 from jsonb_array_elements(:'deleted'::jsonb->'objects') o where o->>'bucket'='paper-uploads' and o->>'path'=:'B'||'/'||:'U6'||'.pdf')
 and exists(select 1 from jsonb_array_elements(:'deleted'::jsonb->'prefixes') p where p->>'bucket'='paper-uploads' and p->>'prefix'=:'B'||'/'),
 'upload objects and folder returned for removal');
rollback;
