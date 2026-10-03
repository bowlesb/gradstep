-- Deterministic local fixtures only. No downloads, provider calls or real data.
begin;
insert into auth.users values('01000000-0000-0000-0000-000000000001'),('01000000-0000-0000-0000-000000000002'),('01000000-0000-0000-0000-000000000003');
set role anon;
select test.reject('select public.v2_library_page()','permission denied');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','01000000-0000-0000-0000-000000000001',false);
select test.reject('select * from app_private.library_commands','permission denied');
select test.reject($q$select public.worker_record_arxiv_metadata('2401.01234',1,'{}')$q$,'permission denied');
select test.assert(public.v2_library_page()->'entries'='[]'::jsonb,'empty baseline');
select test.assert((public.v2_library_changes(0)->>'next_cursor')::bigint=0,'empty delta');
reset role;
set role service_role;
select public.worker_record_arxiv_metadata('2401.01234',1,'{"title":"Alpha attention","authors":["Ada Researcher"],"abstract":"Version one","published_at":"2024-01-03","updated_at":"2024-01-03","categories":["cs.LG"],"venue":null}') as meta1 \gset
select public.worker_record_arxiv_metadata('2401.01234',2,'{"title":"Beta attention","authors":["Ada Researcher"],"abstract":"Version two","published_at":"2024-01-03","updated_at":"2024-01-04","categories":["cs.LG","cs.AI"],"venue":null}') as meta2 \gset
select public.worker_record_arxiv_metadata('math/0301001',1,'{"title":"Alias paper","authors":[],"categories":["math.ST"]}') as metaalias \gset
select test.assert(public.worker_record_arxiv_metadata('math/0301001',1,'{"categories":["math.ST"],"authors":[],"title":"Alias paper"}')=:'metaalias'::uuid,'normalized metadata replay');
select test.reject($q$select public.worker_record_arxiv_metadata('2413.01234',1,'{}')$q$,'invalid_arxiv_id');
select test.reject($q$select public.worker_record_arxiv_metadata('2401.01234',1,'{"title":"bad","authors":[42],"categories":[]}')$q$,'invalid_catalog_metadata');
reset role;
insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values
 ('01000000-0000-0000-0000-000000000010',decode(repeat('10',32),'hex'),'shared_catalog','{"legacy_fixture":true}',1000,2),
 ('01000000-0000-0000-0000-000000000020',decode(repeat('20',32),'hex'),'shared_catalog','{"legacy_fixture":true}',2000,3);
insert into app_private.documents(id,sha256,scope,owner_id,byte_count,page_count) values
 ('01000000-0000-0000-0000-000000000030',decode(repeat('30',32),'hex'),'owner_private','01000000-0000-0000-0000-000000000002',1000,2);
insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values
 ('01000000-0000-0000-0000-000000000011','paper-assets','test/library/original-1.pdf','01000000-0000-0000-0000-000000000010','verified',decode(repeat('10',32),'hex'),1000,'application/pdf',now()),
 ('01000000-0000-0000-0000-000000000021','paper-assets','test/library/original-2.pdf','01000000-0000-0000-0000-000000000020','verified',decode(repeat('20',32),'hex'),2000,'application/pdf',now()),
 ('01000000-0000-0000-0000-000000000012','paper-assets','test/library/manifest.json','01000000-0000-0000-0000-000000000010','verified',decode(repeat('12',32),'hex'),100,'application/json',now());
set role service_role;
select public.worker_approve_arxiv_asset('01000000-0000-0000-0000-000000000101',:'meta1','01000000-0000-0000-0000-000000000010','01000000-0000-0000-0000-000000000011','https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2401.01234','source_revision',1,'source_url','https://arxiv.org/abs/2401.01234v1','license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('a',64),'observed_at','2026-10-03T01:00:00Z'));
select public.worker_approve_arxiv_asset('01000000-0000-0000-0000-000000000102',:'meta2','01000000-0000-0000-0000-000000000020','01000000-0000-0000-0000-000000000021','https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2401.01234','source_revision',2,'source_url','https://arxiv.org/abs/2401.01234v2','license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('b',64),'observed_at','2026-10-03T01:00:00Z'));
select public.worker_approve_arxiv_asset('01000000-0000-0000-0000-000000000103',:'metaalias','01000000-0000-0000-0000-000000000010','01000000-0000-0000-0000-000000000011','https://creativecommons.org/publicdomain/zero/1.0/',
 jsonb_build_object('source_id','math/0301001','source_revision',1,'source_url','https://arxiv.org/abs/math/0301001v1','license_uri','https://creativecommons.org/publicdomain/zero/1.0/','evidence_sha256',repeat('c',64),'observed_at','2026-10-03T01:00:00Z'));
select test.reject(format('select public.worker_approve_arxiv_asset(gen_random_uuid(),%L,%L,%L,%L,%L)',:'meta1','01000000-0000-0000-0000-000000000010','01000000-0000-0000-0000-000000000021','https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2401.01234','source_revision',1,'source_url','https://arxiv.org/abs/2401.01234v1','license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('a',64),'observed_at','2026-10-03T01:00:00Z')::text),'original_object_mismatch');
select test.reject(format('select public.worker_approve_arxiv_asset(gen_random_uuid(),%L,%L,%L,%L,%L)',:'meta1','01000000-0000-0000-0000-000000000010','01000000-0000-0000-0000-000000000011','https://creativecommons.org/licenses/by/4.0/','{}'),'reuse_evidence_mismatch');
reset role;
insert into app_private.ocr_runs(id,document_id,provider,options_sha256) values('01000000-0000-0000-0000-000000000013','01000000-0000-0000-0000-000000000010','local-fixture',decode(repeat('13',32),'hex'));
insert into app_private.render_artifacts(id,ocr_run_id,renderer_version,manifest_object_id) values('01000000-0000-0000-0000-000000000014','01000000-0000-0000-0000-000000000013','fixture-renderer-v1','01000000-0000-0000-0000-000000000012');

-- The cursor is derived bookkeeping, not an obstacle to pristine-account
-- cleanup. Immutable receipts still prevent unsafe account deletion, and the
-- failed deletion must also roll back its attempted cursor cascade.
do $$ declare pristine uuid:=gen_random_uuid(); retained uuid:=gen_random_uuid(); operation uuid:=gen_random_uuid();
begin
 insert into auth.users values(pristine),(retained);
 perform test.assert(exists(select 1 from app_private.library_sync_state where account_id=pristine),'initializer creates pristine library cursor');
 delete from app_private.accounts where id=pristine;
 perform test.assert(not exists(select 1 from app_private.library_sync_state where account_id=pristine),'pristine account deletion cascades only derived cursor state');
 perform set_config('request.jwt.claim.sub',retained::text,false);
 perform test.assert(public.v2_set_library_item(operation,'01000000-0000-0000-0000-000000000010',false,99)->'result'->>'status'='revision_conflict','conflict creates only an immutable command receipt');
 perform test.assert(not exists(select 1 from app_private.library_items where account_id=retained)
  and not exists(select 1 from app_private.import_requests where account_id=retained),'receipt-only deletion fixture has no other substantive library children');
 perform test.reject(format('delete from app_private.accounts where id=%L',retained),'library_commands_account_id_fkey');
 perform test.assert(exists(select 1 from app_private.accounts where id=retained)
  and exists(select 1 from app_private.library_sync_state where account_id=retained and v2_writes_started)
  and exists(select 1 from app_private.library_commands where account_id=retained and id=operation),'receipt deletion gate preserves account, cursor and receipt together');
end $$;

set role authenticated;
select set_config('request.jwt.claim.sub','01000000-0000-0000-0000-000000000001',false);
select test.reject($q$select public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000030',true,0)$q$,'document_unavailable');
select test.reject($q$select public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000010',true,0)$q$,'document_not_verified');
select public.v2_begin_import('01000000-0000-0000-0000-000000000201','2401.01234',0,1) as initial \gset
select test.assert((public.v2_begin_import('01000000-0000-0000-0000-000000000201',' 2401.01234 ',0,1)->>'replayed')::boolean,'begin replay canonicalizes source');
select test.reject($q$select public.v2_begin_import('01000000-0000-0000-0000-000000000201','2401.01234',0,2)$q$,'operation_id_conflict');
select test.assert((public.v2_library_changes(0)->>'next_cursor')::int=1,'exact replay consumes no cursor');
select test.assert(jsonb_array_length(public.v2_library_page()->'entries')=1,'pending import appears before any document membership');
reset role;
set role service_role;
select test.reject($q$select public.worker_resolve_import('01000000-0000-0000-0000-000000000001','01000000-0000-0000-0000-000000000201',1,1,'01000000-0000-0000-0000-000000000102')$q$,'import_source_mismatch');
select test.reject($q$select public.worker_resolve_import('01000000-0000-0000-0000-000000000001','01000000-0000-0000-0000-000000000201',1,1,'01000000-0000-0000-0000-000000000101','01000000-0000-0000-0000-000000000014')$q$,'artifact_incompatible');
reset role;
update app_private.library_policy set compatible_renderers=array['fixture-renderer-v1'];
set role service_role;
select public.worker_resolve_import('01000000-0000-0000-0000-000000000001','01000000-0000-0000-0000-000000000201',1,1,'01000000-0000-0000-0000-000000000101','01000000-0000-0000-0000-000000000014');
select public.worker_resolve_import('01000000-0000-0000-0000-000000000001','01000000-0000-0000-0000-000000000201',1,1,'01000000-0000-0000-0000-000000000101','01000000-0000-0000-0000-000000000014');
select test.assert(public.worker_request_ocr('01000000-0000-0000-0000-000000000001','01000000-0000-0000-0000-000000000010','local-fixture',decode(repeat('13',32),'hex'),gen_random_uuid(),decode(repeat('31',32),'hex'),'none',0,0)->>'state'='ready','legacy cache observation requires compatible verified artifact and creates no paid work');
reset role;
select test.assert((select last_seq=2 from app_private.library_sync_state where account_id='01000000-0000-0000-0000-000000000001'),'resolution replay consumes no cursor');
select test.assert((select jsonb_array_length(entries)=2 from app_private.library_changes where account_id='01000000-0000-0000-0000-000000000001' and seq=2),'resolution mapping and membership share one atomic batch');
select test.assert(not exists(select 1 from app_private.metered_operations where account_id='01000000-0000-0000-0000-000000000001'),'ready reuse reserves no provider credits');
set role authenticated;
select test.assert((public.v2_begin_import('01000000-0000-0000-0000-000000000201','2401.01234',0,1)->'entry'->>'phase')='ready','receipt returns current state, not original pending row');
select public.v2_begin_import('01000000-0000-0000-0000-000000000202','math/0301001',2,1);
select public.v2_set_library_item('01000000-0000-0000-0000-000000000203','01000000-0000-0000-0000-000000000010',false,1);
select test.reject($q$select public.v1_set_library_item('01000000-0000-0000-0000-000000000010',true)$q$,'library_update_required');
reset role;
set role service_role;
select test.assert(public.worker_resolve_import('01000000-0000-0000-0000-000000000001','01000000-0000-0000-0000-000000000202',3,1,'01000000-0000-0000-0000-000000000103')->>'phase'='membership_conflict','alias resolves after removal without restoring');
select test.reject($q$select public.worker_request_ocr('01000000-0000-0000-0000-000000000001','01000000-0000-0000-0000-000000000010','local-fixture',decode(repeat('13',32),'hex'),gen_random_uuid(),decode(repeat('31',32),'hex'),'none',0,0)$q$,'library_membership_required');
reset role;
set role authenticated;
-- This Add arrives after removal, but was initiated from an old offline view.
select public.v2_begin_import('01000000-0000-0000-0000-000000000204','2401.01234',2,1);
reset role;
set role service_role;
select test.assert(public.worker_resolve_import('01000000-0000-0000-0000-000000000001','01000000-0000-0000-0000-000000000204',6,1,'01000000-0000-0000-0000-000000000101')->>'phase'='membership_conflict','offline Add cannot restore a newer removal');
reset role;
select test.assert((select removed_at is not null and membership_revision=2 from app_private.library_items where account_id='01000000-0000-0000-0000-000000000001' and document_id='01000000-0000-0000-0000-000000000010'),'both removal fences survived callbacks');
set role authenticated;
select public.v2_set_library_item('01000000-0000-0000-0000-000000000205','01000000-0000-0000-0000-000000000010',true,2,'01000000-0000-0000-0000-000000000101');
select test.reject($q$select public.v1_set_library_item('01000000-0000-0000-0000-000000000010',false)$q$,'library_update_required');
select test.assert((public.v2_set_library_item('01000000-0000-0000-0000-000000000203','01000000-0000-0000-0000-000000000010',false,1)->'entry'->>'visible')::boolean,'old removal receipt does not remove explicit restoration');
select test.assert(public.v2_set_library_item('01000000-0000-0000-0000-000000000206','01000000-0000-0000-0000-000000000010',false,1)->'result'->>'status'='revision_conflict','stale revision returns a durable conflict');
select public.v2_cancel_import('01000000-0000-0000-0000-000000000207','01000000-0000-0000-0000-000000000201',1);
reset role;
select test.assert((select removed_at is null from app_private.library_items where account_id='01000000-0000-0000-0000-000000000001' and document_id='01000000-0000-0000-0000-000000000010'),'cancel old import cannot undo newer Add');

-- Version pinning survives retries and different revision metadata publication.
set role authenticated;
select public.v2_begin_import('01000000-0000-0000-0000-000000000208','2401.01234',9,null) as unversioned \gset
reset role;
set role service_role;
select public.worker_checkpoint_import('01000000-0000-0000-0000-000000000001','01000000-0000-0000-0000-000000000208',10,1,'acquiring',:'meta1');
select public.worker_checkpoint_import('01000000-0000-0000-0000-000000000001','01000000-0000-0000-0000-000000000208',11,1,'failed',null,'download_failed',true);
reset role;
set role authenticated;
select public.v2_retry_import('01000000-0000-0000-0000-000000000209','01000000-0000-0000-0000-000000000208',1);
reset role;
set role service_role;
select test.reject(format('select public.worker_checkpoint_import(%L,%L,13,2,%L,%L)', '01000000-0000-0000-0000-000000000001','01000000-0000-0000-0000-000000000208','acquiring',:'meta2'),'import_source_mismatch');
reset role;
set role authenticated;
select public.v2_cancel_import('01000000-0000-0000-0000-000000000210','01000000-0000-0000-0000-000000000208',2);
reset role;
set role service_role;
select test.reject($q$select public.worker_resolve_import('01000000-0000-0000-0000-000000000001','01000000-0000-0000-0000-000000000208',13,2,'01000000-0000-0000-0000-000000000101')$q$,'stale_import_checkpoint');
reset role;

-- A second account independently attaches the same verified bytes; private
-- document and first-account commands remain inaccessible.
set role authenticated;
select set_config('request.jwt.claim.sub','01000000-0000-0000-0000-000000000002',false);
select test.assert(public.v2_library_page()->'entries'='[]'::jsonb,'second account sees no first-account library');
select test.reject($q$select public.v2_cancel_import(gen_random_uuid(),'01000000-0000-0000-0000-000000000201',1)$q$,'import_unavailable');
select public.v2_begin_import('01000000-0000-0000-0000-000000000201','2401.01234',0,1);
reset role;
set role service_role;
select public.worker_resolve_import('01000000-0000-0000-0000-000000000002','01000000-0000-0000-0000-000000000201',1,1,'01000000-0000-0000-0000-000000000101');
reset role;
select test.assert((select count(*)=2 from app_private.library_items where document_id='01000000-0000-0000-0000-000000000010' and account_id::text like '01000000%'),'same eligible bytes support independent memberships');
select test.assert((select count(*)=1 from app_private.documents where sha256=decode(repeat('10',32),'hex')),'no duplicate shared file');

-- More than 500 rows, stable creation pagination, concurrent mutations and
-- baseline-to-delta reconciliation. Keep the view model keyed by kind+ID.
select set_config('request.jwt.claim.sub','01000000-0000-0000-0000-000000000003',false);
do $$ declare doc uuid; page jsonb; continuation jsonb:=null; h bigint; changes jsonb; seen uuid[]:='{}'; row jsonb; first boolean:=true; removed uuid;
begin
 for n in 1..505 loop
  insert into app_private.documents(sha256,scope,reuse_evidence,byte_count,page_count) values(sha256(convert_to('library-pagination-'||n,'UTF8')),'shared_catalog','{"test":true}',10,1) returning id into doc;
  perform public.v1_set_library_item(doc,true); if n=3 then removed:=doc; end if;
 end loop;
 loop
  page:=public.v2_library_page(continuation,77);
  if first then
   h:=(page->>'baseline_cursor')::bigint;
   perform public.v1_set_library_item(removed,false);
   insert into app_private.documents(sha256,scope,reuse_evidence,byte_count,page_count) values(sha256(convert_to('library-pagination-late','UTF8')),'shared_catalog','{"test":true}',10,1) returning id into doc;
   perform public.v1_set_library_item(doc,true); first:=false;
  end if;
  for row in select value from jsonb_array_elements(page->'entries') loop
   perform test.assert(not (row->>'id')::uuid=any(seen),'baseline never repeats an entry'); seen:=array_append(seen,(row->>'id')::uuid);
  end loop;
  exit when not (page->>'has_more')::boolean; continuation:=page->'next_cursor';
 end loop;
 perform test.assert(cardinality(seen)=505,'baseline crosses 500 and excludes later creation');
 changes:=public.v2_library_changes(h,null,1);
 perform test.assert((changes->>'has_more')::boolean,'delta has explicit continuation');
 perform test.assert(not (changes->'changes'->0->'entries'->0->>'visible')::boolean,'delta retains removal tombstone');
 changes:=public.v2_library_changes((changes->>'next_cursor')::bigint,(changes->>'through')::bigint,1);
 perform test.assert(not (changes->>'has_more')::boolean and (changes->'changes'->0->'entries'->0->>'visible')::boolean,'delta delivers late addition');
end $$;

-- Journal compaction forces resync without deleting receipts or remove fences.
-- Cancellation withdraws one import interest, not independent library intent.
do $$ declare a uuid:=gen_random_uuid(); ia uuid; ib uuid; r jsonb; sa bigint; sb bigint; rev bigint; cursor bigint;
begin
 insert into auth.users values(a); perform set_config('request.jwt.claim.sub',a::text,false);
 ia:=gen_random_uuid(); r:=public.v2_begin_import(ia,'2401.01234',0,1); sa:=(r->'entry'->>'state_seq')::bigint;
 perform public.worker_resolve_import(a,ia,sa,1,'01000000-0000-0000-0000-000000000101','01000000-0000-0000-0000-000000000014');
 ib:=gen_random_uuid(); r:=public.v2_begin_import(ib,'math/0301001',sa,1); sb:=(r->'entry'->>'state_seq')::bigint;
 perform public.worker_resolve_import(a,ib,sb,1,'01000000-0000-0000-0000-000000000103');
 perform public.v2_cancel_import(gen_random_uuid(),ib,1);
 perform test.assert((select removed_at is null and approval_id='01000000-0000-0000-0000-000000000101' and artifact_id='01000000-0000-0000-0000-000000000014' from app_private.library_items where account_id=a),'duplicate alias cancellation preserves earlier membership and source/artifact pins');
 perform public.v2_cancel_import(gen_random_uuid(),ia,1);
 perform test.assert((select removed_at is not null and last_remove_seq=0 from app_private.library_items where account_id=a),'last import cancellation withdraws without a document-level removal fence');
 -- B began first, A resolves and is cancelled, then older B finishes.
 ib:=gen_random_uuid(); r:=public.v2_begin_import(ib,'math/0301001',0,1); sb:=(r->'entry'->>'state_seq')::bigint;
 ia:=gen_random_uuid(); r:=public.v2_begin_import(ia,'2401.01234',0,1); sa:=(r->'entry'->>'state_seq')::bigint;
 perform public.worker_resolve_import(a,ia,sa,1,'01000000-0000-0000-0000-000000000101');
 perform public.v2_cancel_import(gen_random_uuid(),ia,1);
 perform public.worker_resolve_import(a,ib,sb,1,'01000000-0000-0000-0000-000000000103');
 perform test.assert((select removed_at is null from app_private.library_items where account_id=a),'older unresolved independent import can finish after implicit withdrawal');
 -- Explicit Remove invalidates even resolved old interests.
 select membership_revision into rev from app_private.library_items where account_id=a;
 r:=public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000010',false,rev); cursor:=(r->'result'->>'seq')::bigint;
 ia:=gen_random_uuid(); r:=public.v2_begin_import(ia,'2401.01234',cursor,1); sa:=(r->'entry'->>'state_seq')::bigint;
 perform public.worker_resolve_import(a,ia,sa,1,'01000000-0000-0000-0000-000000000101');
 perform public.v2_cancel_import(gen_random_uuid(),ia,1);
 perform test.assert((select removed_at is not null and last_remove_seq=cursor from app_private.library_items where account_id=a),'superseded ready import cannot keep later restoration alive');
 select membership_revision into rev from app_private.library_items where account_id=a;
 perform public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000010',true,rev,'01000000-0000-0000-0000-000000000103');
 select membership_revision into rev from app_private.library_items where account_id=a;
 perform public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000010',true,rev,'01000000-0000-0000-0000-000000000101');
 perform test.assert((select removed_at is null and membership_source='explicit' and artifact_id='01000000-0000-0000-0000-000000000014' from app_private.library_items where account_id=a),'redundant direct Add preserves converted artifact and establishes explicit intent');
end $$;

-- Typed cursors never turn malformed/null tokens into false completion.
select set_config('request.jwt.claim.sub','01000000-0000-0000-0000-000000000001',false);
select test.reject($q$select public.v2_library_page('{"format":2,"account_id":"01000000-0000-0000-0000-000000000001","through":null,"created_seq":0,"id":"00000000-0000-0000-0000-000000000000","kind":"item"}')$q$,'invalid_library_cursor');
select test.reject($q$select public.v2_library_page('{"format":2,"account_id":"01000000-0000-0000-0000-000000000001","through":1,"created_seq":null,"id":"00000000-0000-0000-0000-000000000000","kind":"item"}')$q$,'invalid_library_cursor');
select test.reject($q$select public.v2_library_page('{"format":2,"account_id":"01000000-0000-0000-0000-000000000001","through":1,"created_seq":0,"id":null,"kind":"item"}')$q$,'invalid_library_cursor');
select test.reject($q$select public.v2_library_page('{"format":2,"account_id":"01000000-0000-0000-0000-000000000002","through":1,"created_seq":0,"id":"00000000-0000-0000-0000-000000000000","kind":"item"}')$q$,'invalid_library_cursor');
select test.reject($q$update app_private.documents set sha256=decode(repeat('99',32),'hex') where id='01000000-0000-0000-0000-000000000010'$q$,'immutable_document_identity');
select test.reject($q$update app_private.stored_objects set path='rewritten.pdf' where id='01000000-0000-0000-0000-000000000011'$q$,'immutable_object_identity');
select test.reject($q$update app_private.stored_objects set state='pending' where id='01000000-0000-0000-0000-000000000011'$q$,'invalid_object_transition');
select test.reject($q$update app_private.render_artifacts set renderer_version='different' where id='01000000-0000-0000-0000-000000000014'$q$,'immutable_record');

-- Repeated no-op/conflicting commands cannot spend the slots reserved for real
-- removals. Exercise both account and environment receipt limits.
do $$ declare a uuid:=gen_random_uuid(); t uuid; r jsonb; active bigint; commands bigint;
begin
 insert into auth.users values(a); perform set_config('request.jwt.claim.sub',a::text,false);
 perform public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000010',true,0,'01000000-0000-0000-0000-000000000101');
 perform public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000020',true,0,'01000000-0000-0000-0000-000000000102');
 insert into app_private.documents(sha256,scope,reuse_evidence,byte_count,page_count) values(sha256(convert_to('quota-tombstone','UTF8')),'shared_catalog','{"test":true}',10,1) returning id into t;
 perform public.v2_set_library_item(gen_random_uuid(),t,false,0);
 update app_private.library_policy set account_receipts=5;
 perform test.reject(format('select public.v2_set_library_item(gen_random_uuid(),%L,false,1)',t),'library_account_receipt_limit');
 perform test.reject($q$select public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000010',false,0)$q$,'library_account_receipt_limit');
 perform public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000010',false,1);
 perform public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000020',false,1);
 perform test.assert((select count(*)=5 from app_private.library_commands where account_id=a),'real removals use reserved account receipt capacity');
 update app_private.library_policy set account_receipts=20;
 perform public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000010',true,2,'01000000-0000-0000-0000-000000000101');
 perform public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000020',true,2,'01000000-0000-0000-0000-000000000102');
 select count(*) into commands from app_private.library_commands;
 active:=(select count(*) from app_private.library_items where removed_at is null)+(select count(*) from app_private.import_requests where desired_present and phase<>'ready');
 update app_private.library_policy set environment_receipts=commands+active;
 perform test.reject(format('select public.v2_set_library_item(gen_random_uuid(),%L,false,1)',t),'library_environment_receipt_limit');
 perform public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000010',false,3);
 perform public.v2_set_library_item(gen_random_uuid(),'01000000-0000-0000-0000-000000000020',false,3);
 perform test.assert((select count(*)=commands+2 from app_private.library_commands),'real removals use reserved environment receipt capacity');
 update app_private.library_policy set account_receipts=12000,environment_receipts=120000;
end $$;

-- Count AND UTF-8 encoded-byte bounds, plus higher-revision baseline rows.
do $$ declare a uuid:=gen_random_uuid(); m uuid; iid uuid; r jsonb; page jsonb; next_page jsonb; old_cursor jsonb; changed uuid; h bigint; seq bigint; amount bigint;
begin
 insert into auth.users values(a); perform set_config('request.jwt.claim.sub',a::text,false);
 update app_private.library_policy set account_active_imports=100,environment_active_imports=200;
 m:=public.worker_record_arxiv_metadata('2402.01234',1,jsonb_build_object('title','Long metadata','authors',jsonb_build_array('A'),'abstract',repeat('界',7900),'categories',jsonb_build_array('cs.LG')));
 for n in 1..60 loop
  iid:=gen_random_uuid(); r:=public.v2_begin_import(iid,'2402.01234',0,1);
  perform public.worker_checkpoint_import(a,iid,(r->'entry'->>'state_seq')::bigint,1,'acquiring',m);
  if n=60 then changed:=iid; end if;
 end loop;
 page:=public.v2_library_page(null,100); h:=(page->>'baseline_cursor')::bigint; old_cursor:=page->'next_cursor';
 perform test.assert(octet_length(page::text)<=1048576 and jsonb_array_length(page->'entries')<100 and (page->>'has_more')::boolean,'baseline byte bound has explicit short-page continuation');
 perform public.v2_cancel_import(gen_random_uuid(),changed,1);
 next_page:=public.v2_library_page(old_cursor,100);
 perform test.assert(exists(select 1 from jsonb_array_elements(next_page->'entries') e where e->>'id'=changed::text and (e->>'state_seq')::bigint>h),'baseline may contain a state newer than its creation boundary');
 r:=public.v2_library_changes(0,null,100);
 perform test.assert(octet_length(r::text)<=1048576 and jsonb_array_length(r->'changes')<100 and (r->>'has_more')::boolean,'delta byte bound has explicit short-page continuation');
 r:=public.v2_library_changes(h);
 perform test.assert(r->'changes'->0->'entries'->0->>'phase'='cancelled','baseline continuation still catches up from H0');
 update app_private.library_policy set metadata_rows=(select count(*) from app_private.catalog_metadata);
 perform test.reject($q$select public.worker_record_arxiv_metadata('2402.99999',1,'{"title":"Too many","authors":[],"categories":[]}')$q$,'catalog_metadata_limit');
 update app_private.library_policy set metadata_rows=10000;
 select reserved_bytes into amount from app_private.library_transfer_months where scope_id=a::text;
 update app_private.library_policy set account_transfer_bytes=amount+1;
 perform test.reject('select public.v2_library_page()','library_account_transfer_limit');
 update app_private.library_policy set account_transfer_bytes=268435456;
 update app_private.library_policy set account_journal_events=2;
 perform public.v2_cancel_import(gen_random_uuid(),(select id from app_private.import_requests where account_id=a and desired_present order by created_seq limit 1),1);
 perform test.reject(format('select public.v2_library_page(%L)',old_cursor::text),'library_resync_required');
 perform test.assert(jsonb_array_length(public.v2_library_page()->'entries')>0,'fresh baseline remains available after mid-page compaction');
 update app_private.library_policy set account_journal_events=10000,account_active_imports=10,environment_active_imports=100;
end $$;

update app_private.library_policy set account_journal_events=2;
select set_config('request.jwt.claim.sub','01000000-0000-0000-0000-000000000001',false);
select public.v2_set_library_item('01000000-0000-0000-0000-000000000211','01000000-0000-0000-0000-000000000010',false,3);
select test.reject('select public.v2_library_changes(0)','library_resync_required');
select test.assert((select last_remove_seq>0 and removed_at is not null from app_private.library_items where account_id='01000000-0000-0000-0000-000000000001' and document_id='01000000-0000-0000-0000-000000000010'),'compaction retains removal fence');
select test.assert((public.v2_set_library_item('01000000-0000-0000-0000-000000000205','01000000-0000-0000-0000-000000000010',true,2,'01000000-0000-0000-0000-000000000101')->>'replayed')::boolean,'command receipts survive compaction');
select test.assert(not (public.v2_set_library_item('01000000-0000-0000-0000-000000000205','01000000-0000-0000-0000-000000000010',true,2,'01000000-0000-0000-0000-000000000101')->'entry'->>'visible')::boolean,'old add replay after compaction does not resurrect');

-- Capacity failures roll back receipt, sequence and intent together; exact
-- replay and reading remain available. Clear another account's old test quota.
update app_private.library_policy set account_imports=(select count(*) from app_private.import_requests where account_id='01000000-0000-0000-0000-000000000001');
select last_seq as before_quota from app_private.library_sync_state where account_id='01000000-0000-0000-0000-000000000001' \gset
select test.reject($q$select public.v2_begin_import('01000000-0000-0000-0000-000000000212','2401.01234',0,1)$q$,'library_account_import_limit');
select test.assert((select last_seq=:'before_quota'::bigint from app_private.library_sync_state where account_id='01000000-0000-0000-0000-000000000001'),'quota rejection consumes no cursor');
select test.assert(not exists(select 1 from app_private.library_commands where id='01000000-0000-0000-0000-000000000212'),'quota rejection leaves no receipt');
select test.assert((public.v2_library_page()->>'baseline_cursor')::bigint=:'before_quota'::bigint,'new baseline survives compaction');
select test.assert(not exists(select 1 from pg_tables where schemaname='app_private' and not rowsecurity),'all new tables have RLS');
rollback;
