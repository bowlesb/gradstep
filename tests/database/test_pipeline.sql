-- Edge paper pipeline (migration 014): deterministic local fixtures only.
begin;
insert into auth.users values('14000000-0000-0000-0000-00000000000a'),('14000000-0000-0000-0000-00000000000b'),
 ('14000000-0000-0000-0000-00000000000c'),('14000000-0000-0000-0000-00000000000d');
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits('14000000-0000-0000-0000-00000000000a','adjustment','pipeline-test-a',100,now()-interval '1 day',null,'Pipeline test grant');
select public.worker_grant_credits('14000000-0000-0000-0000-00000000000c','adjustment','pipeline-test-c',100,now()-interval '1 day',null,'Pipeline test grant');
select test.assert(public.worker_pipeline_claim(gen_random_uuid()) is null,'disabled pipeline claims nothing');
select public.worker_set_pipeline_enabled(true);
reset role;

-- Customers cannot drive the pipeline.
set role authenticated;
select set_config('request.jwt.claim.sub','14000000-0000-0000-0000-00000000000a',false);
select test.reject('select public.worker_pipeline_claim(gen_random_uuid())','permission denied');
select test.reject($q$select public.worker_reader_descriptor('14000000-0000-0000-0000-00000000000a',gen_random_uuid())$q$,'permission denied');
select public.v2_begin_import('14000000-0000-0000-0000-0000000000a1','2305.18290',0)->'entry'->>'phase' as phase \gset
select test.assert(:'phase'='accepted','import accepted');
reset role;
select test.assert((select count(*) from app_private.pipeline_imports where account_id='14000000-0000-0000-0000-00000000000a')=1,'import linked to pipeline paper');

-- Claim, metadata and progress projection.
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'id') as paper, (:'entry'::jsonb->>'generation')::bigint as gen \gset
select test.assert(:'entry'::jsonb->>'stage'='metadata','claimed metadata stage');
select test.assert(public.worker_pipeline_claim(gen_random_uuid()) is null,'claimed paper is not claimed twice');
select test.assert((public.worker_pipeline_arxiv_slot(2)->>'reserved')::boolean,'arxiv slots reserved');
select test.assert((public.worker_pipeline_arxiv_slot()->>'wait_ms')::integer>=5000,'next request waits for both reserved slots');
select test.assert(not (public.worker_pipeline_arxiv_slot(1,1000)->>'reserved')::boolean,'a long wait reserves nothing');
select test.assert((public.worker_pipeline_arxiv_slot(1,1000)->>'wait_ms')::integer<=9000,'unreserved waits do not push the queue');
select test.reject(format('select public.worker_pipeline_metadata(%L,gen_random_uuid(),%s,3,%L,true)',:'paper',:'gen','{"title":"x","authors":[],"categories":[]}'),'stale_pipeline_claim');
select public.worker_pipeline_metadata(:'paper',:'claim',:'gen',3,
 '{"title":"Direct Preference Optimization","authors":["Rafael Rafailov"],"abstract":"DPO","published_at":"2023-05-29","updated_at":"2024-07-29","categories":["cs.LG"],"venue":null}',
 true,'https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2305.18290','source_revision',3,'source_url','https://arxiv.org/abs/2305.18290v3','license_uri','https://creativecommons.org/licenses/by/4.0/',
  'evidence_sha256',repeat('e',64),'observed_at','2026-10-05T05:00:00Z'))->>'stage' as stage \gset
select test.assert(:'stage'='download','eligible paper proceeds to download');
select test.assert(public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen')=1,'sync projects one import');
reset role;
select test.assert(app_private.library_import_entry('14000000-0000-0000-0000-00000000000a','14000000-0000-0000-0000-0000000000a1')->>'phase'='acquiring','import acquiring after metadata');
select test.assert(app_private.library_import_entry('14000000-0000-0000-0000-00000000000a','14000000-0000-0000-0000-0000000000a1')->>'progress'='downloading','progress downloading');
select test.assert(app_private.library_import_entry('14000000-0000-0000-0000-00000000000a','14000000-0000-0000-0000-0000000000a1')->'metadata'->>'title'='Direct Preference Optimization','import shows metadata');

-- Original, funding and the single submission grant.
set role service_role;
select test.reject(format('select public.worker_pipeline_original(%L,%L,%s,%L::bytea,1299212,27,%L)',:'paper',:'claim',:'gen','\x'||repeat('92',32),'originals/wrong.pdf'),'invalid_original');
select public.worker_pipeline_original(:'paper',:'claim',:'gen',('\x'||repeat('92',32))::bytea,1299212,27,'originals/'||repeat('92',32)||'.pdf')->>'stage' as stage \gset
select test.assert(:'stage'='ocr_fund','new bytes need OCR');
select test.reject(format('select public.worker_pipeline_fund(%L,%L,%s,28,%L::bytea,%L::bytea)',:'paper',:'claim',:'gen','\x'||repeat('0a',32),'\x'||repeat('0b',32)),'invalid_ocr_request');
select public.worker_pipeline_fund(:'paper',:'claim',:'gen',27,('\x'||repeat('0a',32))::bytea,('\x'||repeat('0b',32))::bytea) as funded \gset
select test.assert(:'funded'::jsonb->>'funding'='funded' and :'funded'::jsonb->>'stage'='ocr_submit','first importer funds OCR');
reset role;
select test.assert((select reserved from app_private.credit_buckets where external_key='pipeline-test-a')=27,'27 credits held');
select test.assert((select reserved_microusd from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date)>=135000,'platform spend reserved');
set role service_role;
select public.worker_pipeline_begin_submit(:'paper',:'claim',:'gen') as granted \gset
select test.assert((:'granted'::jsonb->>'granted')::boolean,'first begin grants POST');
select (:'granted'::jsonb->>'attempt_id') as attempt \gset
select test.reject(format('select public.worker_pipeline_submitted(%L,null,null)',:'attempt'),'invalid_submission_result');
select public.worker_pipeline_submitted(:'attempt','cc092181-9d12-4eb3-b5de-d2ca288fc556')->>'stage' as stage \gset
select test.assert(public.worker_pipeline_submitted(:'attempt','cc092181-9d12-4eb3-b5de-d2ca288fc556')->>'stage'='ocr_wait','submission record is idempotent');
select test.assert(:'stage'='ocr_wait','submitted job waits');
select public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen');
select public.worker_pipeline_release(:'paper',:'claim',:'gen');
select test.assert(public.worker_pipeline_claim(gen_random_uuid()) is null,'waiting job is not due yet');
reset role;
update app_private.pipeline_papers set next_attempt_at=now() where id=:'paper';
set role service_role;
select gen_random_uuid() as claim \gset
select (public.worker_pipeline_claim(:'claim')->>'generation')::bigint as gen \gset
select public.worker_pipeline_collected(:'paper',:'claim',:'gen',27,('\x'||repeat('6a',32))::bytea,4096)->>'stage' as stage \gset
select test.assert(:'stage'='render','collection moves to render');
reset role;
select test.assert((select balance from app_private.credit_buckets where external_key='pipeline-test-a')=73
 and (select reserved from app_private.credit_buckets where external_key='pipeline-test-a')=0,'settled 27 credits, hold released');
select test.assert(exists(select 1 from app_private.provider_usage_events where provider='mathpix' and provider_event_id='cc092181-9d12-4eb3-b5de-d2ca288fc556' and estimated_microusd=135000),'provider usage recorded');
set role service_role;
select test.reject(format('select public.worker_pipeline_published(%L,%L,%s,%L::bytea,2048,%L)',:'paper',:'claim',:'gen','\x'||repeat('7b',32),'other-renderer'),'invalid_publication');
select public.worker_pipeline_published(:'paper',:'claim',:'gen',('\x'||repeat('7b',32))::bytea,2048,'timestep-mathpix-mathml-v1')->>'stage' as stage \gset
select test.assert(:'stage'='done','published');
select test.assert(public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen')=1,'resolve import');
select public.worker_pipeline_release(:'paper',:'claim',:'gen');
reset role;

-- The customer sees a converted, readable library item.
set role authenticated;
select set_config('request.jwt.claim.sub','14000000-0000-0000-0000-00000000000a',false);
select e as item from jsonb_array_elements(public.v2_library_page()->'entries') e where e->>'kind'='item' \gset
select test.assert(:'item'::jsonb->>'readiness'='converted_ready' and :'item'::jsonb->>'render_availability'='available'
 and :'item'::jsonb->>'original_availability'='available' and :'item'::jsonb->>'artifact_id' is not null,'converted ready item');
select e->>'phase' as phase from jsonb_array_elements(public.v2_library_page()->'entries') e where e->>'kind'='import' \gset
select test.assert(:'phase'='ready','import ready');
reset role;
set role service_role;
select public.worker_reader_descriptor('14000000-0000-0000-0000-00000000000a',(:'item'::jsonb->>'id')::uuid) as descriptor \gset
select test.assert(:'descriptor'::jsonb->>'manifest_path'='reader/'||repeat('7b',32)||'/manifest.json' and :'descriptor'::jsonb->>'manifest_sha256'=repeat('7b',32),'reader descriptor');
select test.assert(public.worker_chat_context('14000000-0000-0000-0000-00000000000a',(:'item'::jsonb->>'document_id')::uuid)->>'path'='raw/'||repeat('6a',32)||'/standalone.mmd','chat context path');
select test.reject(format('select public.worker_reader_descriptor(%L,%L)','14000000-0000-0000-0000-00000000000b',:'item'::jsonb->>'id'),'reader_unavailable');
select test.reject(format('select public.worker_chat_context(%L,%L)','14000000-0000-0000-0000-00000000000b',:'item'::jsonb->>'document_id'),'document_unavailable');
reset role;

-- A second account reuses the conversion without credits or a charge.
set role authenticated;
select set_config('request.jwt.claim.sub','14000000-0000-0000-0000-00000000000b',false);
select public.v2_begin_import('14000000-0000-0000-0000-0000000000b1','2305.18290',0);
reset role;
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select test.assert(:'entry'::jsonb->>'id'=:'paper' and :'entry'::jsonb->>'stage'='done','done paper claimed only to sync');
select test.assert(public.worker_pipeline_sync_imports(:'paper',:'claim',(:'entry'::jsonb->>'generation')::bigint)=1,'second account resolved');
select public.worker_pipeline_release(:'paper',:'claim',(:'entry'::jsonb->>'generation')::bigint);
reset role;
select test.assert((select phase from app_private.import_requests where id='14000000-0000-0000-0000-0000000000b1')='ready','reuse import ready');
select test.assert(not exists(select 1 from app_private.metered_operations where account_id='14000000-0000-0000-0000-00000000000b'),'reuse never charges');

-- An explicit revision slot with identical bytes reuses the render directly.
set role authenticated;
select set_config('request.jwt.claim.sub','14000000-0000-0000-0000-00000000000c',false);
select public.v2_begin_import('14000000-0000-0000-0000-0000000000c1','2305.18290',0,3);
reset role;
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'id') as paper3, (:'entry'::jsonb->>'generation')::bigint as gen \gset
select test.assert(:'paper3'<>:'paper','separate source slot');
select public.worker_pipeline_metadata(:'paper3',:'claim',:'gen',3,
 '{"title":"Direct Preference Optimization","authors":["Rafael Rafailov"],"abstract":"DPO","published_at":"2023-05-29","updated_at":"2024-07-29","categories":["cs.LG"],"venue":null}',
 true,'https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2305.18290','source_revision',3,'source_url','https://arxiv.org/abs/2305.18290v3','license_uri','https://creativecommons.org/licenses/by/4.0/',
  'evidence_sha256',repeat('e',64),'observed_at','2026-10-05T05:00:00Z'));
select test.assert(public.worker_pipeline_original(:'paper3',:'claim',:'gen',('\x'||repeat('92',32))::bytea,1299212,27,'originals/'||repeat('92',32)||'.pdf')->>'stage'='done','identical bytes reuse render');
select public.worker_pipeline_sync_imports(:'paper3',:'claim',:'gen');
reset role;
select test.assert((select phase from app_private.import_requests where id='14000000-0000-0000-0000-0000000000c1')='ready','slot reuse ready');
select test.assert((select balance from app_private.credit_buckets where external_key='pipeline-test-c')=100,'slot reuse not charged');

-- No credits: retryable failure; retry after a grant funds it. Then a lost
-- grant acknowledgement makes the attempt uncertain instead of re-posting.
set role authenticated;
select set_config('request.jwt.claim.sub','14000000-0000-0000-0000-00000000000d',false);
select public.v2_begin_import('14000000-0000-0000-0000-0000000000d1','2312.00752',0);
reset role;
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'id') as paper4, (:'entry'::jsonb->>'generation')::bigint as gen \gset
select public.worker_pipeline_metadata(:'paper4',:'claim',:'gen',2,'{"title":"Mamba","authors":[],"categories":["cs.LG"]}',
 true,'https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2312.00752','source_revision',2,'source_url','https://arxiv.org/abs/2312.00752v2','license_uri','https://creativecommons.org/licenses/by/4.0/',
  'evidence_sha256',repeat('f',64),'observed_at','2026-10-05T05:00:00Z'));
select public.worker_pipeline_original(:'paper4',:'claim',:'gen',('\x'||repeat('44',32))::bytea,2000000,36,'originals/'||repeat('44',32)||'.pdf');
select test.assert(public.worker_pipeline_fund(:'paper4',:'claim',:'gen',36,('\x'||repeat('0c',32))::bytea,('\x'||repeat('0d',32))::bytea)->>'funding'='needs_credits','no credits');
select public.worker_pipeline_sync_imports(:'paper4',:'claim',:'gen');
select public.worker_pipeline_release(:'paper4',:'claim',:'gen');
reset role;
select test.assert((select phase='failed' and retryable and error_code='insufficient_credits' from app_private.import_requests where id='14000000-0000-0000-0000-0000000000d1'),'import failed retryable for credits');
select test.assert(not exists(select 1 from app_private.metered_operations where account_id='14000000-0000-0000-0000-00000000000d'),'failed reservation leaves no operation');
set role service_role;
select test.assert(public.worker_pipeline_claim(gen_random_uuid()) is null,'failed paper waits for retry');
select public.worker_grant_credits('14000000-0000-0000-0000-00000000000d','adjustment','pipeline-test-d',50,now()-interval '1 day',null,'Pipeline test grant');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','14000000-0000-0000-0000-00000000000d',false);
select public.v2_retry_import('14000000-0000-0000-0000-0000000000d2','14000000-0000-0000-0000-0000000000d1',1);
reset role;
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'generation')::bigint as gen \gset
select test.assert(:'entry'::jsonb->>'id'=:'paper4' and :'entry'::jsonb->>'stage'='ocr_fund','retry resumes funding');
select test.assert(public.worker_pipeline_fund(:'paper4',:'claim',:'gen',36,('\x'||repeat('0c',32))::bytea,('\x'||repeat('0d',32))::bytea)->>'funding'='funded','funded after grant');
select public.worker_pipeline_begin_submit(:'paper4',:'claim',:'gen') as granted4 \gset
select test.assert((:'granted4'::jsonb->>'granted')::boolean,'grant');
select (:'granted4'::jsonb->>'attempt_id') as attempt4 \gset
reset role;
update app_private.pipeline_papers set lease_until=now()-interval '1 second' where id=:'paper4';
set role service_role;
select gen_random_uuid() as claim \gset
select (public.worker_pipeline_claim(:'claim')->>'generation')::bigint as gen \gset
select public.worker_pipeline_begin_submit(:'paper4',:'claim',:'gen') as again \gset
select test.assert(not (:'again'::jsonb->>'granted')::boolean and :'again'::jsonb->>'stage'='ocr_uncertain','lost grant becomes uncertain, never a second POST');
reset role;
select test.assert((select state from app_private.metered_operations where account_id='14000000-0000-0000-0000-00000000000d')='submitted','uncertain hold retained');
select test.assert((select reserved from app_private.credit_buckets where external_key='pipeline-test-d')=36,'uncertain credits stay held');
set role service_role;
-- The original POST's result arrives late (its worker outlived its lease).
select test.assert(public.worker_pipeline_submitted(:'attempt4','late-job-d')->>'stage'='ocr_wait','late job id recovers an unrecorded submission');
select test.reject(format('select public.worker_pipeline_resolve_uncertain(%L,%L,null)',:'attempt4','other-job'),'invalid_resolution');
reset role;
-- Operator resolution of a genuinely uncertain attempt releases the hold.
update app_private.ocr_attempts set state='uncertain',provider_job_id=null,error_code='provider_http_failure' where id=:'attempt4';
update app_private.pipeline_papers set stage='ocr_uncertain' where id=:'paper4';
set role service_role;
select test.assert(public.worker_pipeline_resolve_uncertain(:'attempt4',null,0)->>'stage'='failed','resolved uncertain fails resumably');
reset role;
select test.assert((select reserved from app_private.credit_buckets where external_key='pipeline-test-d')=0
 and (select balance from app_private.credit_buckets where external_key='pipeline-test-d')=50,'resolved hold released without charge');

-- Non-CC papers: each interested account gets its own private conversion.
reset role;
insert into auth.users values('14000000-0000-0000-0000-00000000000e'),('14000000-0000-0000-0000-00000000000f');
set role service_role;
select public.worker_grant_credits('14000000-0000-0000-0000-00000000000e','adjustment','pipeline-test-e',100,now()-interval '1 day',null,'Pipeline test grant');
select public.worker_grant_credits('14000000-0000-0000-0000-00000000000f','adjustment','pipeline-test-f',100,now()-interval '1 day',null,'Pipeline test grant');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','14000000-0000-0000-0000-00000000000e',false);
select public.v2_begin_import('14000000-0000-0000-0000-0000000000e1','2006.11239',0);
select set_config('request.jwt.claim.sub','14000000-0000-0000-0000-00000000000f',false);
select public.v2_begin_import('14000000-0000-0000-0000-0000000000f1','2006.11239',0);
reset role;
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'id') as shared, (:'entry'::jsonb->>'generation')::bigint as gen \gset
select test.assert(public.worker_pipeline_metadata(:'shared',:'claim',:'gen',2,'{"title":"Denoising Diffusion Probabilistic Models","authors":["Jonathan Ho"],"categories":["cs.LG"]}',
 false,'http://arxiv.org/licenses/nonexclusive-distrib/1.0/')->>'stage'='private_split','ineligible paper splits privately');
select test.assert(public.worker_pipeline_split_private(:'shared',:'claim',:'gen')=2,'two private papers');
select public.worker_pipeline_sync_imports(:'shared',:'claim',:'gen');
select public.worker_pipeline_release(:'shared',:'claim',:'gen');
reset role;
select test.assert((select count(*) from app_private.pipeline_papers where source_id='2006.11239' and owner_id is not null and stage='download')=2,'private papers start at download');
select id as private_e from app_private.pipeline_papers where owner_id='14000000-0000-0000-0000-00000000000e' \gset
update app_private.pipeline_papers set next_attempt_at=now()+interval '1 hour' where owner_id='14000000-0000-0000-0000-00000000000f';
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select test.assert(:'entry'::jsonb->>'id'=:'private_e' and :'entry'::jsonb->>'owner_id'='14000000-0000-0000-0000-00000000000e','claim private paper');
select (:'entry'::jsonb->>'generation')::bigint as gen \gset
select test.reject(format('select public.worker_pipeline_original(%L,%L,%s,%L::bytea,900000,25,%L)',:'private_e',:'claim',:'gen','\x'||repeat('55',32),'originals/'||repeat('55',32)||'.pdf'),'invalid_original');
select test.assert(public.worker_pipeline_original(:'private_e',:'claim',:'gen',('\x'||repeat('55',32))::bytea,900000,25,
 'private/14000000-0000-0000-0000-00000000000e/originals/'||repeat('55',32)||'.pdf')->>'stage'='ocr_fund','private original');
select test.assert(public.worker_pipeline_fund(:'private_e',:'claim',:'gen',25,('\x'||repeat('0e',32))::bytea,('\x'||repeat('0f',32))::bytea)->>'funding'='funded','owner funds private OCR');
select public.worker_pipeline_begin_submit(:'private_e',:'claim',:'gen')->>'attempt_id' as attempt_e \gset
select test.assert(:'attempt_e' is not null and :'attempt_e'<>'','private grant');
select public.worker_pipeline_submitted(:'attempt_e','private-job-e');
select public.worker_pipeline_collected(:'private_e',:'claim',:'gen',25,('\x'||repeat('5a',32))::bytea,2048);
select test.assert(public.worker_pipeline_published(:'private_e',:'claim',:'gen',('\x'||repeat('5b',32))::bytea,2048,'timestep-mathpix-mathml-v1')->>'stage'='done','private published');
select test.assert(public.worker_pipeline_sync_imports(:'private_e',:'claim',:'gen')=1,'private import resolved');
reset role;
select test.assert((select d.scope='owner_private' and d.owner_id='14000000-0000-0000-0000-00000000000e' from app_private.library_items li join app_private.documents d on d.id=li.document_id
 where li.account_id='14000000-0000-0000-0000-00000000000e'),'owner has a private document');
select test.assert(app_private.library_item_entry('14000000-0000-0000-0000-00000000000e',(select id from app_private.library_items where account_id='14000000-0000-0000-0000-00000000000e'))->>'readiness'='converted_ready','private item readable');
select test.assert((select balance from app_private.credit_buckets where external_key='pipeline-test-e')=75,'owner paid for private conversion');
select test.assert((select phase in ('accepted','resolving','acquiring') from app_private.import_requests where id='14000000-0000-0000-0000-0000000000f1')
 and (select pp.owner_id='14000000-0000-0000-0000-00000000000f' from app_private.pipeline_imports pi join app_private.pipeline_papers pp on pp.id=pi.paper_id
  where pi.import_id='14000000-0000-0000-0000-0000000000f1'),'other account converts its own private copy');
select test.reject(format('select public.worker_chat_context(%L,%L)','14000000-0000-0000-0000-00000000000f',
 (select document_id from app_private.pipeline_papers where id=:'private_e')),'document_unavailable');

-- A funder who withdraws before the grant is never charged.
reset role;
update app_private.pipeline_papers set next_attempt_at=now() where owner_id='14000000-0000-0000-0000-00000000000f';
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'id') as private_f, (:'entry'::jsonb->>'generation')::bigint as gen \gset
select public.worker_pipeline_original(:'private_f',:'claim',:'gen',('\x'||repeat('66',32))::bytea,900000,25,
 'private/14000000-0000-0000-0000-00000000000f/originals/'||repeat('66',32)||'.pdf');
select test.assert(public.worker_pipeline_fund(:'private_f',:'claim',:'gen',25,('\x'||repeat('1e',32))::bytea,('\x'||repeat('1f',32))::bytea)->>'funding'='funded','F funds');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','14000000-0000-0000-0000-00000000000f',false);
select public.v2_cancel_import('14000000-0000-0000-0000-0000000000f2','14000000-0000-0000-0000-0000000000f1',1);
reset role;
set role service_role;
select test.assert(not (public.worker_pipeline_begin_submit(:'private_f',:'claim',:'gen')->>'granted')::boolean,'withdrawn funder gets no grant');
reset role;
select test.assert((select reserved from app_private.credit_buckets where external_key='pipeline-test-f')=0
 and (select balance from app_private.credit_buckets where external_key='pipeline-test-f')=100,'withdrawn funder hold released, no charge');
select test.assert((select stage from app_private.pipeline_papers where id=:'private_f')='ocr_fund','paper returns to funding');
rollback;
