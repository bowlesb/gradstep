-- Local synthetic Storage receipts; actual one-send network ordering is tested in Node.
begin;
create schema if not exists test;
grant usage on schema test to anon,authenticated,service_role;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin begin execute statement; exception when others then
 if position(expected in sqlerrm)=0 then raise exception 'Unexpected rejection: % (wanted %)',sqlerrm,expected; end if; rejected:=true; end;
 if not rejected then raise exception 'Expected rejection: %',expected; end if; end $$;
insert into auth.users values('39000000-0000-0000-0000-000000000001'),('39000000-0000-0000-0000-000000000002'),('39000000-0000-0000-0000-000000000003');
\set A '39000000-0000-0000-0000-000000000001'
\set B '39000000-0000-0000-0000-000000000002'
\set C '39000000-0000-0000-0000-000000000003'
\set U '39000000-0000-0000-0000-000000000011'
\set sha '\\x1111111111111111111111111111111111111111111111111111111111111111'
select public.worker_grant_credits(:'A','adjustment','chunk-fixture-a',1000,now()-interval '1 day',null,'Chunk fixture');
select public.worker_grant_credits(:'B','adjustment','chunk-fixture-b',1000,now()-interval '1 day',null,'Chunk fixture');
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,1000,array[%L::bytea],''paper'')',:'A',:'U',:'sha',:'sha'),'upload_disabled');
select test.reject('select public.worker_pdf_upload_policy(true)','asset_inventory_incomplete');
update app_private.paper_asset_policy set enforced=true,inventory_verified_at=clock_timestamp(),inventory_scope=2;
select public.worker_pdf_upload_policy(true);
select public.worker_set_pipeline_enabled(true);
set role authenticated;
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,1000,array[%L::bytea],''paper'')',:'A',:'U',:'sha',:'sha'),'permission denied');
select test.reject('select * from app_private.pdf_upload_write_attempts','permission denied');
reset role;
set role service_role;
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,1000,array[%L::bytea],''paper'')',:'C',:'U',:'sha',:'sha'),'insufficient_credits');
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,4194305,array[%L::bytea],''paper'')',:'A',:'U',:'sha',:'sha'),'invalid_upload');
select public.worker_begin_pdf_upload(:'A',:'U',:'sha',1000,array[:'sha'::bytea],'paper') as began \gset
select test.assert(:'began'::jsonb->>'protocol'='upload-chunks-v1' and :'began'::jsonb->>'state'='receiving' and not(:'began'::jsonb ? 'path'),'no Storage credential or path issued');
select test.assert(public.worker_begin_pdf_upload(:'A',:'U',:'sha',1000,array[:'sha'::bytea],'paper')=:'began'::jsonb,'same request replay');
select test.reject(format('select public.worker_begin_pdf_upload(%L,%L,%L,1001,array[%L::bytea],''paper'')',:'A',:'U',:'sha',:'sha'),'upload_id_conflict');
select test.reject(format('select public.worker_pdf_upload_status(%L,%L)',:'B',:'U'),'upload_unavailable');
reset role;
select test.assert((select sum(bytes)=159908840 and sum(objects)=519 from app_private.pdf_upload_holds where upload_id=:'U'),'staging and complete future phases reserved');
select test.assert(not exists(select 1 from app_private.stored_objects where bucket='paper-uploads'),'begin promises capacity without inventing physical objects');
update app_private.pipeline_policy set private_bytes_per_owner=159908840;
select test.reject(format('select public.worker_begin_pdf_upload(%L,gen_random_uuid(),%L,1,array[%L::bytea],''paper'')',:'A',:'sha',:'sha'),'paper_owner_storage_capacity');
update app_private.pipeline_policy set private_bytes_per_owner=1073741824;
select gen_random_uuid() as lost,gen_random_uuid() as replacement \gset
select test.assert((public.worker_pdf_upload_part(:'A',:'U',1,0,:'lost')->>'receive')::boolean,'part admission precedes body');
select test.reject(format('select public.worker_pdf_upload_write(%L,%L,1,0,%L,%L,999)',:'A',:'U',:'lost',:'sha'),'upload_mismatch');
select public.worker_pdf_upload_write(:'A',:'U',1,0,:'lost',:'sha',1000) as first_write \gset
select test.assert((:'first_write'::jsonb->>'write')::boolean,'one durable physical send');
select test.assert(not (public.worker_pdf_upload_write(:'A',:'U',1,0,:'lost',:'sha',1000)->>'write')::boolean,'exact replay cannot authorize a second send');
select test.reject(format('select public.worker_freeze_pdf_upload(%L,%L,1,1,0)',:'A',:'U'),'upload_incomplete');
select public.worker_pdf_upload_write(:'A',:'U',1,0,:'replacement',:'sha',1000) as replacement_write \gset
select test.assert((select sum(byte_count)=2000 from app_private.stored_objects where owner_id=:'A' and bucket='paper-uploads'),'replacement retains unknown old physical liability');
select test.assert(not exists(select 1 from app_private.pdf_upload_holds where upload_id=:'U' and kind='staging'),'exact first write consumed only its staging hold');
select public.worker_pdf_upload_written(:'replacement',:'sha',1000);
select test.assert((public.worker_pdf_upload_status(:'A',:'U')->'parts'->0->>'uncertain')::integer=1,'status exposes unresolved outcome without private paths');
select test.reject(format('select public.worker_freeze_pdf_upload(%L,%L,1,1,0)',:'A',:'U'),'upload_revision_conflict');
insert into app_private.library_descriptors(account_id,source_id,id,revision,mutation_id,device_id,epoch,format,ciphertext,sha256)
 values(:'A','upload:'||:'U',gen_random_uuid(),1,gen_random_uuid(),gen_random_uuid(),1,1,decode(repeat('11',28),'hex'),sha256(decode(repeat('11',28),'hex')));
select public.worker_freeze_pdf_upload(:'A',:'U',1,2,0);
select test.assert((select state='frozen' and selection_sha256 is not null from app_private.pdf_uploads where id=:'U'),'freeze records exact selection');
select test.assert(not exists(select 1 from app_private.import_requests where id=:'U'),'freeze alone creates no visible import');
select test.assert((select count(*)=3 from app_private.pdf_upload_holds where upload_id=:'U'),'all future capacity retained during saga gap');
select public.worker_finalize_pdf_upload(:'A',:'U',1) as receipt \gset
select test.assert(:'receipt'::jsonb->'result'->>'status'='applied','attached import');
select test.assert((public.worker_finalize_pdf_upload(:'A',:'U',1)->>'replayed')::boolean,'lost attach response replays same result');
select test.assert((select count(*)=1 from app_private.import_requests where account_id=:'A' and source_id='upload:'||:'U'),'no duplicate import');
select test.reject(format('select public.worker_cancel_pdf_upload(%L,%L,1)',:'A',:'U'),'upload_already_attached');
select id as paper from app_private.pipeline_papers where source_id='upload:'||:'U' \gset
select gen_random_uuid() as claim \gset
update app_private.pipeline_papers set claim_id=:'claim',generation=1,lease_until=clock_timestamp()+interval '10 minutes' where id=:'paper';
select test.reject(format('select public.worker_pdf_upload_read(gen_random_uuid(),%L,1,%L,%L,1)',:'U',:'paper',:'claim'),'upload_not_admitted');
select test.assert((public.worker_pipeline_admit_download(:'paper',:'claim',1)->>'admitted')::boolean,'worker takes exact session');
select test.assert((select upload_id=:'U' and upload_generation=1 from app_private.pipeline_papers where id=:'paper'),'session/generation pinned');
select test.assert(not exists(select 1 from app_private.pdf_upload_holds where upload_id=:'U') and (select count(*)=3 from app_private.paper_asset_holds where paper_id=:'paper'),'future holds atomically transferred');
select gen_random_uuid() as read \gset
select public.worker_pdf_upload_read(:'read',:'U',1,:'paper',:'claim',1) as read_receipt \gset
select test.assert(:'read_receipt'::jsonb->'objects'->0->>'id'=:'replacement_write'::jsonb->>'object_id','assembly uses frozen selected replacement');
select test.assert(not (public.worker_pdf_upload_read(:'read',:'U',1,:'paper',:'claim',1)->>'read')::boolean,'read grant cannot replay');
select public.worker_pdf_upload_read_observed(:'read',1000);
select test.assert((select authorized_bytes=1000 and upstream_bytes=1000 from app_private.reader_transfer_months where scope_id=:'A' and kind='backend'),'GET cost recorded separately from observation');
update app_private.reader_delivery_policy set backend_account_bytes_month=1000;
select test.reject(format('select public.worker_pdf_upload_read(gen_random_uuid(),%L,1,%L,%L,1)',:'U',:'paper',:'claim'),'reader_transfer_limit');
update app_private.reader_delivery_policy set backend_account_bytes_month=268435456;

-- Publish the fully verified original through035 inventory, never raw staging bytes.
select gen_random_uuid() as planned,gen_random_uuid() as original_write \gset
select 'private/'||:'A'||'/originals/'||repeat('1',64)||'.pdf' as original_path \gset
select public.worker_pipeline_asset_plan(:'paper',:'claim',1,:'planned','original',jsonb_build_array(jsonb_build_object('path',:'original_path','sha256',repeat('1',64),'bytes',1000,'media_type','application/pdf')),3) as plan \gset
select public.worker_pipeline_asset_write(:'paper',:'claim',1,:'planned',(:'plan'::jsonb->'objects'->0->>'id')::uuid,:'original_write');
select public.worker_pipeline_asset_written(:'original_write',true);
select test.assert(public.worker_pipeline_upload_original(:'paper',:'claim',1,:'U',:'sha',1000,3,:'original_path')->>'stage'='ocr_fund','private verified original published');
select test.assert((select state='consumed' from app_private.pdf_uploads where id=:'U'),'session consumed');
select test.assert((select policy_version='owner-upload-v1' and evidence->>'upload_id'=:'U' from app_private.catalog_asset_approvals where id=(select approval_id from app_private.pipeline_papers where id=:'paper')),'exact owner-upload provenance');
select test.assert(public.worker_claim_stale_pdf_uploads(50)='[]'::jsonb,'unknown original PUT blocks ALL physical chunk deletion');
select gen_random_uuid() as probe \gset
select public.worker_pdf_upload_read(:'probe',:'U',1,null,null,null,:'lost');
select test.reject(format('select public.worker_pdf_upload_written(%L,%L,1000,''matching_object'',%L)',:'lost',:'sha',:'probe'),'upload_write_proof_required');
select public.worker_pdf_upload_read_observed(:'probe',1000);
select public.worker_pdf_upload_written(:'lost',:'sha',1000,'matching_object',:'probe');
select public.worker_claim_stale_pdf_uploads(50) as batches \gset
select test.assert(jsonb_array_length(:'batches'::jsonb)=1 and jsonb_array_length(:'batches'::jsonb->0->'objects')=2,'terminal batch includes selected and superseded physical objects');
select test.assert((select sum(byte_count)=2000 from app_private.stored_objects where owner_id=:'A' and state='deleting'),'delete admission retains capacity');
select test.assert(public.worker_confirm_pdf_uploads_deleted((:'batches'::jsonb->0->>'batch_id')::uuid)=2,'exact batch confirmation releases capacity');
select test.assert(public.worker_confirm_pdf_uploads_deleted((:'batches'::jsonb->0->>'batch_id')::uuid)=0,'delete replay harmless');

-- Lifetime caps limit new evidence rows, never replay or terminal progress.
update app_private.pdf_upload_policy set account_sessions=1,environment_sessions=1,session_reads=1;
select test.assert(public.worker_begin_pdf_upload(:'A',:'U',:'sha',1000,array[:'sha'::bytea],'paper')->>'state'='consumed','exact begin replay bypasses exhausted lifetime capacity');
select test.reject(format('select public.worker_begin_pdf_upload(%L,gen_random_uuid(),%L,1,array[%L::bytea],''paper'')',:'A',:'sha',:'sha'),'upload_receipt_capacity');
select test.assert(not (public.worker_pdf_upload_read(:'probe',:'U',1,null,null,null,:'lost')->>'read')::boolean,'read replay does not require new receipt headroom');
select public.worker_pdf_upload_written(:'lost',:'sha',1000,'matching_object',:'probe');
select public.worker_pdf_upload_read_observed(:'probe',1000);
select test.assert(public.worker_confirm_pdf_uploads_deleted((:'batches'::jsonb->0->>'batch_id')::uuid)=0,'terminal cleanup bypasses new-receipt caps');
update app_private.pdf_upload_policy set account_sessions=2000,environment_sessions=20000,session_reads=128;

-- Closure persists but offers no erase authority while a PUT remains unknown.
select gen_random_uuid() as closed_upload,gen_random_uuid() as closed_write \gset
select public.worker_begin_pdf_upload(:'B',:'closed_upload',:'sha',1000,array[:'sha'::bytea],'paper');
select public.worker_pdf_upload_write(:'B',:'closed_upload',1,0,:'closed_write',:'sha',1000);
select public.worker_delete_account_begin(:'B') as closed \gset
select test.assert(:'closed'::jsonb->>'blocked'='asset_write_uncertain' and :'closed'::jsonb->'objects'='[]'::jsonb,'closure blocks physical deletion');
select test.assert((select closed_at is not null from app_private.accounts where id=:'B'),'closure is durable');
select test.reject(format('select public.worker_pdf_upload_write(%L,%L,1,0,gen_random_uuid(),%L,1000)',:'B',:'closed_upload',:'sha'),'account_unavailable');
select test.reject(format('select public.worker_delete_account_finish(%L)',:'B'),'asset_write_uncertain');
select public.worker_pdf_upload_written(:'closed_write',:'sha',1000);
select test.assert((select selected_object_id is null from app_private.pdf_upload_parts where upload_id=:'closed_upload'),'late terminal callback does not revive cancelled selection');
select public.worker_delete_account_begin(:'B') as closed \gset
select test.assert(jsonb_array_length(:'closed'::jsonb->'objects')=1 and exists(select 1 from jsonb_array_elements(:'closed'::jsonb->'prefixes') p where p->>'bucket'='paper-uploads'),'later complete erase includes staging bucket');
select public.worker_delete_account_finish(:'B');
select test.assert(not exists(select 1 from app_private.pdf_uploads where account_id=:'B'),'session personal references erased after terminal deletion');
select test.assert(not exists(select 1 from app_private.reader_transfer_months where scope_id=:'B'),'no personal counters recreated');
rollback;
