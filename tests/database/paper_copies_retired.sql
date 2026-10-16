-- Server paper copies retired (migration 080; owner, 2026-10-16; docs/architecture/DATA_HANDLING_AND_COSTS.md
-- "Server paper copies: retired"): before retirement a legacy item reads, chats and pins its server copy; retirement
-- refuses while a paper write is unresolved, then fences new copies, marks availability and schedules every paper
-- copy (paper-assets and paper-uploads) for deletion while podcast audio, episode text and report attachments stay;
-- the library projection says unavailable at a newer revision with its ids kept; reading answers reader_unavailable,
-- chat document_unavailable, podcasts find no pin; Storage's confirmation records completion.
-- Synthetic local SQL; nothing leaves the machine. Runs after the HTML-first cutover migrations (scripts/test-database.py).
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
grant execute on all functions in schema test to anon,authenticated,service_role;

\set A '80000000-0000-0000-0000-00000000000a'
\set B '80000000-0000-0000-0000-00000000000b'
insert into auth.users(id) values(:'A'),(:'B');
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);

-- A converted catalog paper as the old pipeline left it: original, Mathpix output with its text, reader bundle.
create or replace function test.pc_paper(tag text) returns jsonb language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid(); appr uuid:=gen_random_uuid();
 run uuid:=gen_random_uuid(); art uuid:=gen_random_uuid(); orig uuid:=gen_random_uuid(); rawm uuid:=gen_random_uuid(); txt uuid:=gen_random_uuid();
 readm uuid:=gen_random_uuid(); page uuid:=gen_random_uuid(); raw_digest text:=encode(sha256(convert_to(tag||'-raw','UTF8')),'hex');
 reader_digest text:=encode(sha256(convert_to(tag||'-reader','UTF8')),'hex');
 metadata jsonb:=jsonb_build_object('title','Retired fixture '||tag,'authors',jsonb_build_array('R. Fixture'),'published_at','2025-01-02','categories',jsonb_build_array('cs.LG'));
begin
 insert into app_private.publications(id,title) values(pub,'Retired fixture '||tag);
 insert into app_private.publication_versions(id,publication_id,source,revision) values(ver,pub,'arxiv','1');
 insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
  values(doc,sha256(convert_to(tag||'-document','UTF8')),'shared_catalog','{"license":"CC-BY-4.0"}',1000,2);
 insert into app_private.version_documents values(ver,doc);
 insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values
  (orig,'paper-assets','originals/'||encode(sha256(convert_to(tag||'-original','UTF8')),'hex')||'.pdf',doc,'verified',sha256(convert_to(tag||'-original','UTF8')),1000,'application/pdf',now()),
  (rawm,'paper-assets','raw/'||raw_digest||'/manifest.json',doc,'verified',decode(raw_digest,'hex'),100,'application/json',now()),
  (txt,'paper-assets','raw/'||raw_digest||'/standalone.mmd',doc,'verified',sha256(convert_to(tag||'-text','UTF8')),5000,'text/plain',now()),
  (readm,'paper-assets','reader/'||reader_digest||'/manifest.json',doc,'verified',decode(reader_digest,'hex'),100,'application/json',now()),
  (page,'paper-assets','reader/'||reader_digest||'/index.html',doc,'verified',sha256(convert_to(tag||'-page','UTF8')),700,'text/html',now());
 insert into app_private.paper_asset_manifest_members values(rawm,txt,'standalone.mmd'),(readm,page,'index.html');
 insert into app_private.catalog_metadata(id,version_id,source_id,source_revision,metadata,metadata_sha256)
  values(meta,ver,'2501.8'||lpad((abs(hashtext(tag))%10000)::text,4,'0'),1,metadata,sha256(convert_to(metadata::text,'UTF8')));
 insert into app_private.catalog_asset_approvals(id,version_id,document_id,metadata_id,original_object_id,license_uri,policy_version,evidence)
  values(appr,ver,doc,meta,orig,'https://creativecommons.org/licenses/by/4.0/','arxiv-reuse-v1','{}');
 insert into app_private.ocr_runs(id,document_id,provider,options_sha256,raw_bundle_object_id) values(run,doc,'mathpix',sha256(convert_to(tag||'-options','UTF8')),rawm);
 insert into app_private.render_artifacts(id,ocr_run_id,renderer_version,manifest_object_id) values(art,run,'timestep-mathpix-mathml-v1',readm);
 -- Publication marked both available (the pipeline's capacity -> document order).
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 perform 1 from app_private.documents where id=doc for update;
 perform app_private.mark_paper_availability(orig,'available');
 perform app_private.mark_paper_availability(readm,'available');
 return jsonb_build_object('approval',appr,'document',doc,'artifact',art,'original',orig,'text',txt,'reader',readm);
end $$;

select test.pc_paper('one') as fixture \gset
insert into app_private.library_items(account_id,document_id,artifact_id,approval_id)
 values(:'A',(:'fixture'::jsonb->>'document')::uuid,(:'fixture'::jsonb->>'artifact')::uuid,(:'fixture'::jsonb->>'approval')::uuid);
select id as item from app_private.library_items where account_id=:'A' \gset
select app_private.library_item_entry(:'A',:'item') as before \gset
select test.assert(:'before'::jsonb->>'render_availability'='available' and :'before'::jsonb->>'original_availability'='available'
 and :'before'::jsonb->>'readiness'='converted_ready','fixture: a legacy item reads its server copy');

-- A PDF upload chunk (paper-uploads) and the files that are not paper copies: an episode's audio, the text a device
-- sent for an episode, a report screenshot.
\set UP '80000000-0000-4000-8000-0000000000c1'
insert into app_private.stored_objects(id,bucket,path,owner_id,state,sha256,byte_count,media_type,verified_at) values
 (:'UP','paper-uploads',:'A'||'/'||repeat('c',64)||'/0',:'A','verified',sha256('chunk'),4096,'application/octet-stream',now()),
 (gen_random_uuid(),'podcast-assets','private/'||:'A'||'/'||repeat('a',64)||'/audio.m4a',:'A','verified',sha256('audio'),2048,'audio/mp4',now()),
 (gen_random_uuid(),'private-content','podcast-sources/'||:'A'||'/'||repeat('b',64)||'/'||gen_random_uuid()||'.txt',:'A','verified',sha256('text'),31,'text/plain',now()),
 (gen_random_uuid(),'support',:'A'||'/report.png',:'A','verified',sha256('png'),512,'image/png',now());
select (select count(*) from app_private.stored_objects where bucket not in ('paper-assets','paper-uploads') and state='verified') as controls \gset

-- Before retirement: chat finds the server text, the reader its bundle, Listen its pin; nothing is retired yet.
select test.assert(public.worker_chat_context(:'A',(:'fixture'::jsonb->>'document')::uuid)->>'path' like 'raw/%/standalone.mmd','chat reads the server text');
select test.assert(public.worker_reader_descriptor(:'A',:'item')->>'artifact_id'=:'fixture'::jsonb->>'artifact','the reader finds the bundle');
select test.assert(app_private.podcast_item_pin(:'A',:'item') is not null,'Listen pins the server text');
select test.assert((public.worker_paper_copies_status()->>'retired_at') is null and (public.worker_paper_copies_status()->>'live')::int=6,'status: six live paper copies, not retired');
select test.reject('select public.worker_paper_copies_project(10)','paper_copies_not_retired');
select test.reject(format('select public.worker_paper_copies_deleted(array[%L]::uuid[])',:'UP'),'paper_copies_not_retired');
select test.reject('select public.worker_paper_copies_retire(0)','invalid_limit');
-- Writing new paper copies is still possible before retirement (the fence is the retirement's).
insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type)
 values(gen_random_uuid(),'paper-assets','raw/'||repeat('d',64)||'/lines.json',(:'fixture'::jsonb->>'document')::uuid,'pending',sha256('pending'),10,'application/json');

-- An unresolved paper write refuses retirement (a late upload could recreate a file).
set local session_replication_role=replica;
insert into app_private.pdf_upload_write_attempts(id,upload_id,part_index,object_id) values('80000000-0000-4000-8000-0000000000d1',gen_random_uuid(),0,:'UP');
set local session_replication_role=origin;
select test.reject('select public.worker_paper_copies_retire(10)','asset_write_uncertain');
select test.assert((public.worker_paper_copies_status()->>'open_writes')::int=1,'status counts the unresolved write');
set local session_replication_role=replica;
update app_private.pdf_upload_write_attempts set finished_at=now(),evidence='upload_response' where id='80000000-0000-4000-8000-0000000000d1';
set local session_replication_role=origin;

-- Retirement: fence on, availability marked, every paper copy scheduled, a page returned.
select public.worker_paper_copies_retire(3) as retired \gset
select test.assert((:'retired'::jsonb->>'retired_at') is not null and (:'retired'::jsonb->>'scheduled')::int=7
 and (:'retired'::jsonb->>'deleting')::int=7 and jsonb_array_length(:'retired'::jsonb->'objects')=3
 and (:'retired'::jsonb->>'availability_marked')::int=2,'seven copies scheduled (bundle, text, original, pending output, upload chunk); first page of three');
select test.assert((select bool_and(o->>'bucket' in ('paper-assets','paper-uploads') and (o->>'bytes')::int>0) from jsonb_array_elements(:'retired'::jsonb->'objects') o),'pages name only paper copies, with sizes');
select test.assert((select count(*) from app_private.stored_objects where bucket not in ('paper-assets','paper-uploads') and state='verified')=:'controls'::int,
 'podcast audio, episode text and report attachments are untouched');
select test.assert((select bool_and(state='unavailable' and reason='missing') from app_private.paper_asset_availability
 where object_id in ((:'fixture'::jsonb->>'original')::uuid,(:'fixture'::jsonb->>'reader')::uuid)),'availability says unavailable');
-- A repeat returns the next page without changing anything else.
select public.worker_paper_copies_retire(1000) as again \gset
select test.assert((:'again'::jsonb->>'scheduled')::int=0 and jsonb_array_length(:'again'::jsonb->'objects')=7
 and :'again'::jsonb->>'retired_at'=:'retired'::jsonb->>'retired_at','a repeat lists all seven, schedules none, keeps the retirement time');

-- The fence: no paper copy may be registered again; other buckets still accept files.
select test.reject(format('insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values(gen_random_uuid(),%L,%L,%L,%L,sha256(%L),10,%L,now())',
 'paper-assets','originals/'||repeat('e',64)||'.pdf',:'fixture'::jsonb->>'document','verified','new','application/pdf'),'paper_copies_retired');
select test.reject(format('insert into app_private.stored_objects(id,bucket,path,owner_id,state,sha256,byte_count,media_type) values(gen_random_uuid(),%L,%L,%L,%L,sha256(%L),10,%L)',
 'paper-uploads',:'A'||'/'||repeat('f',64)||'/0',:'A','pending','chunk2','application/octet-stream'),'paper_copies_retired');
insert into app_private.stored_objects(id,bucket,path,owner_id,state,sha256,byte_count,media_type,verified_at)
 values(gen_random_uuid(),'support',:'A'||'/second.png',:'A','verified',sha256('png2'),512,'image/png',now());

-- Reading, chat and Listen answer unavailable; another account's chat is refused as before.
select test.reject(format('select public.worker_reader_descriptor(%L,%L)',:'A',:'item'),'reader_unavailable');
select test.reject(format('select public.worker_chat_context(%L,%L)',:'A',:'fixture'::jsonb->>'document'),'document_unavailable');
select test.reject(format('select public.worker_chat_context(%L,%L)',:'B',:'fixture'::jsonb->>'document'),'document_unavailable');
select test.assert(app_private.podcast_item_pin(:'A',:'item') is null,'Listen finds no server text (the quote says source_unavailable)');
-- The text prepared on the device still answers: a legacy arXiv item is accepted as the local context's membership, for
-- its own account, exact source and revision only; a removed item or another account's is refused.
select source_id,source_revision from app_private.catalog_metadata where id=(select metadata_id from app_private.catalog_asset_approvals
 where id=(:'fixture'::jsonb->>'approval')::uuid) \gset
select test.assert(public.worker_local_chat_context(:'A',:'item',:'source_id',:'source_revision'::int)->>'title'='Retired fixture one','a legacy item takes the device text');
select test.reject(format('select public.worker_local_chat_context(%L,%L,%L,%s)',:'B',:'item',:'source_id',:'source_revision'),'document_unavailable');
select test.reject(format('select public.worker_local_chat_context(%L,%L,%L,%s)',:'A',:'item',:'source_id',(:'source_revision'::int)+1),'document_unavailable');
select test.reject(format('select public.worker_local_chat_context(%L,%L,%L,%s)',:'A',:'item','2501.00001',:'source_revision'),'document_unavailable');
select test.reject(format('select public.worker_local_chat_context(%L,%L,%L,%s)',:'A',gen_random_uuid(),:'source_id',:'source_revision'),'document_unavailable');

-- The library: unavailable at a newer revision, ids kept, one change emitted; a second pass finds nothing to do.
select last_seq as seq_before from app_private.library_sync_state where account_id=:'A' \gset
select public.worker_paper_copies_project(10) as projected \gset
select test.assert((:'projected'::jsonb->>'projected')::int=1 and (:'projected'::jsonb->>'remaining')::int=0,'one item projected, none left');
select app_private.library_item_entry(:'A',:'item') as after \gset
select test.assert(:'after'::jsonb->>'render_availability'='unavailable' and :'after'::jsonb->>'original_availability'='unavailable'
 and :'after'::jsonb->>'readiness'='unavailable','the library says the server copy is unavailable');
select test.assert((:'after'::jsonb->>'render_availability_revision')::bigint>(:'before'::jsonb->>'render_availability_revision')::bigint
 and (:'after'::jsonb->>'original_availability_revision')::bigint>(:'before'::jsonb->>'original_availability_revision')::bigint,'at newer revisions');
select test.assert(:'after'::jsonb->>'artifact_id'=:'before'::jsonb->>'artifact_id' and :'after'::jsonb->>'original_object_id'=:'before'::jsonb->>'original_object_id'
 and :'after'::jsonb->>'document_id'=:'before'::jsonb->>'document_id','artifact, original and document ids are kept');
select test.assert((select last_seq from app_private.library_sync_state where account_id=:'A')>:'seq_before'::bigint
 and (select state_seq from app_private.library_items where id=:'item')=(select last_seq from app_private.library_sync_state where account_id=:'A'),'the change is emitted to devices at the next sequence');
select test.assert((public.worker_paper_copies_project(10)->>'projected')::int=0,'a second pass projects nothing');

-- Storage's confirmation: deleting -> deleted, counted once; the retirement completes when nothing is left.
select public.worker_paper_copies_deleted(array(select (o->>'id')::uuid from jsonb_array_elements(:'again'::jsonb->'objects') o where o->>'bucket'='paper-uploads')) as first_confirm \gset
select test.assert((:'first_confirm'::jsonb->>'confirmed')::int=1 and (:'first_confirm'::jsonb->>'completed_at') is null,'one confirmed; not complete yet');
select public.worker_paper_copies_deleted(array(select (o->>'id')::uuid from jsonb_array_elements(:'again'::jsonb->'objects') o)) as confirm \gset
select test.assert((:'confirm'::jsonb->>'confirmed')::int=6 and (:'confirm'::jsonb->>'completed_at') is not null,'the rest confirmed once; complete');
select test.assert((public.worker_paper_copies_deleted(array[:'UP']::uuid[])->>'confirmed')::int=0,'a repeated confirmation changes nothing');
select public.worker_paper_copies_status() as status \gset
select test.assert((:'status'::jsonb->>'live')::int=0 and (:'status'::jsonb->>'objects_deleted')::int=7
 and (:'status'::jsonb->>'bytes_deleted')::bigint=1000+100+5000+100+700+10+4096,'status: zero live, seven deleted with their bytes');
select test.assert((select bool_and(state='deleted') from app_private.stored_objects where bucket in ('paper-assets','paper-uploads')),'every paper copy row is deleted (rows kept)');
select test.assert((select count(*) from app_private.documents where id=(:'fixture'::jsonb->>'document')::uuid)=1
 and (select count(*) from app_private.render_artifacts where id=(:'fixture'::jsonb->>'artifact')::uuid)=1,'documents and artifacts are kept as history');
select test.assert((select count(*) from app_private.stored_objects where bucket not in ('paper-assets','paper-uploads') and state='verified')=:'controls'::int+1,
 'other buckets untouched (plus the screenshot added after the fence)');

-- Only the service role may run the retirement.
select test.assert(not has_function_privilege('authenticated','public.worker_paper_copies_retire(integer)','EXECUTE')
 and not has_function_privilege('anon','public.worker_paper_copies_status()','EXECUTE')
 and has_function_privilege('service_role','public.worker_paper_copies_deleted(uuid[])','EXECUTE')
 and not has_function_privilege('authenticated','public.worker_chat_context(uuid,uuid)','EXECUTE')
 and not has_function_privilege('authenticated','public.worker_local_chat_context(uuid,uuid,text,integer)','EXECUTE')
 and has_function_privilege('service_role','public.worker_local_chat_context(uuid,uuid,text,integer)','EXECUTE'),'service role only');
rollback;
