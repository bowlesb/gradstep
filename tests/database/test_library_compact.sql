-- Local v4 fixtures only: no provider calls, external data or paid operations.
begin;
-- Fixture-only epoch accessor keeps dynamic rejection SQL readable. It is rolled
-- back with this test and is never part of a migration or a hosted API.
create function test.library_epoch() returns uuid language sql stable security definer set search_path='' as $$
 select dataset_epoch from app_private.library_v4_config where singleton
$$;
grant execute on function test.library_epoch() to anon,authenticated,service_role;
insert into auth.users values('31000000-0000-0000-0000-00000000000a'),('31000000-0000-0000-0000-00000000000b'),
 ('31000000-0000-0000-0000-00000000000c'),('31000000-0000-0000-0000-00000000000d');
select dataset_epoch as epoch from app_private.library_v4_config where singleton \gset
select test.assert((select count(*)=1 from app_private.library_v4_config),'one persistent dataset epoch');
select test.assert((select count(*)=2 from pg_tables where schemaname='app_private'
 and tablename in ('library_v4_config','library_v4_entries') and rowsecurity),'new private tables have RLS');
set role anon;
select test.reject('select public.v4_library_page()','permission denied');
select test.reject(format('select public.v4_library_changes(%L,0)',:'epoch'),'permission denied');
select test.reject('select public.v4_library_metadata(test.library_epoch(),array[]::uuid[])','permission denied');
reset role;
set role service_role;
select test.reject('select public.v4_library_page()','permission denied');
select test.reject(format('select public.v4_library_changes(%L,0)',:'epoch'),'permission denied');
select test.reject('select public.v4_library_metadata(test.library_epoch(),array[]::uuid[])','permission denied');
select test.reject('select * from app_private.library_v4_entries','permission denied');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','31000000-0000-0000-0000-00000000000a',false);
select test.reject('select * from app_private.library_v4_entries','permission denied');
select test.reject('select * from app_private.library_v4_config','permission denied');
select test.reject($q$select app_private.library_v4_read_account('31000000-0000-0000-0000-00000000000a')$q$,'permission denied');
select public.v4_library_page() as empty_page \gset
select test.assert(:'empty_page'::jsonb->'format'='4'::jsonb and :'empty_page'::jsonb->>'dataset_epoch'=:'epoch'
 and :'empty_page'::jsonb->>'account_id'='31000000-0000-0000-0000-00000000000a'
 and :'empty_page'::jsonb->'entries'='[]'::jsonb and :'empty_page'::jsonb->'next_cursor'='null'::jsonb
 and :'empty_page'::jsonb->>'baseline_cursor'='0' and :'empty_page'::jsonb->>'has_more'='false','empty v4 baseline');
select test.assert(public.v4_library_changes(:'epoch',0)->>'next_cursor'='0','empty v4 delta');
select test.assert(public.v4_library_metadata(test.library_epoch(),array[]::uuid[])->'records'='[]'::jsonb,'empty bounded metadata request');
select test.reject('select public.v4_library_metadata(null,array[]::uuid[])','library_resync_required');
select test.reject('select public.v4_library_metadata(gen_random_uuid(),array[]::uuid[])','library_resync_required');
select test.reject('select public.v4_library_page(null,101)','invalid_library_page');
select test.reject('select public.v4_library_page(null,0)','invalid_library_page');
select test.reject('select public.v4_library_page(null,null)','invalid_library_page');
select test.reject(format('select public.v4_library_changes(%L,0,null,101)',:'epoch'),'invalid_library_cursor');
select test.reject(format('select public.v4_library_changes(%L,-1)',:'epoch'),'invalid_library_cursor');
select test.reject('select public.v4_library_changes(null,0)','invalid_library_cursor');
select test.reject('select public.v4_library_changes(gen_random_uuid(),0)','library_resync_required');
reset role;

set role service_role;
select public.worker_record_arxiv_metadata('2407.03101',1,'{"title":"Compact paper","authors":["Fixture Author"],"abstract":"Immutable metadata stays outside compact sync.","categories":["cs.LG"]}') as meta \gset
select public.worker_record_arxiv_metadata('2407.03102',1,'{"title":"Other account metadata","authors":[],"categories":[]}') as unrelated \gset
reset role;
insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
 values('31000000-0000-0000-0000-000000000010',decode(repeat('31',32),'hex'),'shared_catalog','{"fixture":true}',1000,2);
insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
 values('31000000-0000-0000-0000-000000000011','paper-assets','test/compact/original.pdf','31000000-0000-0000-0000-000000000010',
 'verified',decode(repeat('31',32),'hex'),1000,'application/pdf',now());
set role service_role;
select public.worker_approve_arxiv_asset('31000000-0000-0000-0000-000000000012',:'meta','31000000-0000-0000-0000-000000000010',
 '31000000-0000-0000-0000-000000000011','https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2407.03101','source_revision',1,'source_url','https://arxiv.org/abs/2407.03101v1',
 'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('3',64),'observed_at','2026-10-07T01:00:00Z'));
reset role;
set role authenticated;
select public.v2_begin_import('31000000-0000-0000-0000-000000000101','2407.03101',0,1);
reset role;
set role service_role;
select public.worker_checkpoint_import('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-000000000101',1,1,'acquiring',:'meta');
select public.worker_resolve_import('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-000000000101',2,1,'31000000-0000-0000-0000-000000000012');
reset role;
select id as item from app_private.library_items where account_id='31000000-0000-0000-0000-00000000000a' \gset
select test.assert((select count(*)=2 from app_private.library_v4_entries where account_id='31000000-0000-0000-0000-00000000000a'),
 'resolution projects its hidden import mapping and membership atomically');
select test.assert(not exists(select 1 from app_private.library_v4_entries p where p.account_id='31000000-0000-0000-0000-00000000000a'
 and p.entry is distinct from (case p.kind when 'item' then app_private.library_item_entry(p.account_id,p.id)
 else app_private.library_import_entry(p.account_id,p.id) end)-'metadata'),'projection removes only metadata, including metadata_recorded_at');
select test.assert((select jsonb_array_length(entries)=2 and entries->0 ? 'metadata' and entries->1 ? 'metadata'
 from app_private.library_changes where account_id='31000000-0000-0000-0000-00000000000a' and seq=3),'legacy grouped journal is untouched');
set role authenticated;
select public.v3_library_page() as legacy_before \gset
select public.v4_library_changes(:'epoch',2,null,1) as resolution \gset
select test.assert(jsonb_array_length(:'resolution'::jsonb->'changes')=1
 and jsonb_array_length(:'resolution'::jsonb->'changes'->0->'entries')=2
 and :'resolution'::jsonb->'changes'->0->>'seq'='3'
 and not (:'resolution'::jsonb->'changes'->0->'entries'->0 ? 'metadata')
 and not (:'resolution'::jsonb->'changes'->0->'entries'->1 ? 'metadata'),'v4 never splits a grouped resolution');
select test.assert(public.v3_library_page()=:'legacy_before'::jsonb,'v4 reads preserve exact legacy baseline');
select test.assert((public.v2_begin_import('31000000-0000-0000-0000-000000000101','2407.03101',0,1)->>'replayed')::boolean,
 'existing operation ID replay still works');
select test.assert(public.v4_library_changes(:'epoch',3)->>'next_cursor'='3','replay emits no sequence or compact change');
select public.v4_library_metadata(test.library_epoch(),array[:'meta'::uuid]) as hydrated \gset
select test.assert(:'hydrated'::jsonb->'format'='4'::jsonb and :'hydrated'::jsonb->>'dataset_epoch'=:'epoch'
 and :'hydrated'::jsonb->'records'->0->>'metadata_id'=:'meta'
 and :'hydrated'::jsonb->'records'->0->>'source_id'='2407.03101'
 and :'hydrated'::jsonb->'records'->0->>'source'='arxiv'
 and :'hydrated'::jsonb->'records'->0 ? 'version_id' and :'hydrated'::jsonb->'records'->0 ? 'recorded_at'
 and not (:'hydrated'::jsonb->'records'->0 ? 'metadata_sha256'),'metadata carries immutable identity/provenance, not a wire-byte hash');
select test.reject(format('select public.v4_library_metadata(test.library_epoch(),array[%L::uuid,%L::uuid])',:'meta',:'unrelated'),'library_metadata_unavailable');
select test.reject('select public.v4_library_metadata(test.library_epoch(),array[gen_random_uuid()])','library_metadata_unavailable');
select test.reject('select public.v4_library_metadata(test.library_epoch(),null)','invalid_library_metadata_request');
select test.reject('select public.v4_library_metadata(test.library_epoch(),array[null]::uuid[])','invalid_library_metadata_request');
select test.reject(format('select public.v4_library_metadata(test.library_epoch(),array[%L::uuid,%L::uuid])',:'meta',:'meta'),'invalid_library_metadata_request');
select test.reject(format('select public.v4_library_metadata(test.library_epoch(),array[[%L::uuid]])',:'meta'),'invalid_library_metadata_request');
select test.reject(format('select public.v4_library_metadata(test.library_epoch(),array_fill(%L::uuid,array[25]))',:'meta'),'invalid_library_metadata_request');
select public.v2_set_item_tags(gen_random_uuid(),'31000000-0000-0000-0000-000000000010',array['Preference Learning'],array[]::text[],1);
select public.v2_set_item_archived(gen_random_uuid(),'31000000-0000-0000-0000-000000000010',true,2);
select test.assert(exists(select 1 from jsonb_array_elements(public.v4_library_page()->'entries') e
 where e->>'kind'='item' and e->>'archived'='true' and e->'user_tags'='["Preference Learning"]'::jsonb),'tag/archive commands project without extra writers');
select public.v2_set_library_item(gen_random_uuid(),'31000000-0000-0000-0000-000000000010',false,3);
select test.assert(exists(select 1 from jsonb_array_elements(public.v4_library_page()->'entries') e
 where e->>'kind'='item' and e->>'visible'='false' and not(e ? 'archived') and not(e ? 'user_tags')),'removal tombstone stays retained');
select test.assert(jsonb_array_length(public.v4_library_metadata(test.library_epoch(),array[:'meta'::uuid])->'records')=1,'removed membership/hidden mapping retains metadata authority');
select set_config('request.jwt.claim.sub','31000000-0000-0000-0000-00000000000b',false);
select test.assert(public.v4_library_page()->'entries'='[]'::jsonb,'account isolation');
select test.reject(format('select public.v4_library_metadata(test.library_epoch(),array[%L::uuid])',:'meta'),'library_metadata_unavailable');
select test.reject(format('select public.v4_library_metadata(test.library_epoch(),array[%L::uuid])',:'unrelated'),'library_metadata_unavailable');
select test.reject('select public.v4_library_metadata(test.library_epoch(),array[gen_random_uuid()])','library_metadata_unavailable');
select set_config('request.jwt.claim.sub','31000000-0000-0000-0000-00000000000a',false);
select public.v2_begin_web_import('31000000-0000-0000-0000-000000000102','openalex:W310001',6);
reset role;
select app_private.record_web_metadata('openalex:W310001','{"title":"Web metadata","authors":[],"categories":[]}',null) as webmeta \gset
set role service_role;
select public.worker_checkpoint_import('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-000000000102',7,1,'acquiring',:'webmeta');
reset role;
set role authenticated;
select test.assert(exists(select 1 from jsonb_array_elements(public.v4_library_page()->'entries') e where e->>'source'='web')
 and not exists(select 1 from jsonb_array_elements(public.v2_library_page()->'entries') e where e->>'source'='web'),'v4 includes web, v2 filter stays unchanged');
select test.assert(public.v4_library_metadata(test.library_epoch(),array[:'webmeta'::uuid])->'records'->0->>'source'='web','web metadata provenance');
select public.v2_cancel_import(gen_random_uuid(),'31000000-0000-0000-0000-000000000102',1);
select test.assert(jsonb_array_length(public.v4_library_metadata(test.library_epoch(),array[:'webmeta'::uuid])->'records')=1,'cancelled import retains pinned metadata authorization');
reset role;

-- Reject equal-state corruption atomically; identical repeats and stale states
-- do not rewrite the projection or regress its latest state.
do $$ declare a uuid:='31000000-0000-0000-0000-00000000000a'; e jsonb; before_row text; before_seq bigint;
begin
 select entry,ctid::text into e,before_row from app_private.library_v4_entries where account_id=a and kind='item';
 perform app_private.library_emit(a,app_private.library_next_seq(a),jsonb_build_array(e));
 perform test.assert((select ctid::text=before_row from app_private.library_v4_entries where account_id=a and kind='item'),'identical equal-state entry is not rewritten');
 perform app_private.library_emit(a,app_private.library_next_seq(a),
  (select jsonb_build_array(entries->1) from app_private.library_changes where account_id=a and seq=3));
 perform test.assert((select entry=e from app_private.library_v4_entries where account_id=a and kind='item'),'older journal payload cannot regress projection');
 select last_seq into before_seq from app_private.library_sync_state where account_id=a;
 perform test.reject(format('select app_private.library_emit(%L,app_private.library_next_seq(%L),%L)',a,a,jsonb_build_array(e||'{"visible":true}'::jsonb)),
  'library_compact_state_conflict');
 perform test.assert((select last_seq=before_seq from app_private.library_sync_state where account_id=a)
  and not exists(select 1 from app_private.library_changes where account_id=a and seq>before_seq),'conflicting equal-state event rolls back its journal and sequence');
 perform test.reject(format('select app_private.library_emit(%L,app_private.library_next_seq(%L),%L)',a,a,
  jsonb_build_array(e||jsonb_build_object('state_seq',before_seq+1,'created_seq',(e->>'created_seq')::bigint+1))),'library_compact_identity_conflict');
end $$;

-- Strict cursor shape/type/account/epoch binding, including numeric overflow.
set role authenticated;
select public.v4_library_page(null,1)->'next_cursor' as cursor \gset
select test.reject(format('select public.v4_library_page(%L)',:'cursor'::jsonb||'{"extra":true}'::jsonb),'invalid_library_cursor');
select test.reject(format('select public.v4_library_page(%L)',:'cursor'::jsonb-'kind'),'invalid_library_cursor');
select test.reject(format('select public.v4_library_page(%L)',:'cursor'::jsonb||'{"format":"4"}'::jsonb),'invalid_library_cursor');
select test.reject(format('select public.v4_library_page(%L)',:'cursor'::jsonb||'{"created_seq":1.1}'::jsonb),'invalid_library_cursor');
select test.reject(format('select public.v4_library_page(%L)',:'cursor'::jsonb||'{"through":9223372036854775808}'::jsonb),'invalid_library_cursor');
select test.reject(format('select public.v4_library_page(%L)',:'cursor'::jsonb||'{"created_seq":9223372036854775808}'::jsonb),'invalid_library_cursor');
select test.reject(format('select public.v4_library_page(%L)',:'cursor'::jsonb||'{"id":"not-a-uuid"}'::jsonb),'invalid_library_cursor');
select test.reject(format('select public.v4_library_page(%L)',:'cursor'::jsonb||jsonb_build_object('id',gen_random_uuid())),'invalid_library_cursor');
select test.reject(format('select public.v4_library_page(%L)',:'cursor'::jsonb||jsonb_build_object('dataset_epoch',gen_random_uuid())),'library_resync_required');
select test.reject(format('select public.v4_library_page(%L)',:'cursor'::jsonb||jsonb_build_object('dataset_epoch',gen_random_uuid(),'through',9223372036854775807::bigint)),
 'library_resync_required');
select test.reject('select public.v4_library_changes(gen_random_uuid(),9223372036854775807)','library_resync_required');
select test.reject($q$select public.v4_library_page('null'::jsonb)$q$,'invalid_library_cursor');
select test.reject($q$select public.v4_library_page('[]'::jsonb)$q$,'invalid_library_cursor');
select set_config('request.jwt.claim.sub','31000000-0000-0000-0000-00000000000b',false);
select test.reject(format('select public.v4_library_page(%L)',:'cursor'),'invalid_library_cursor');
reset role;

-- Creation-boundary pagination includes retained tombstones, handles ties, and
-- permits newer states on later pages only with mandatory catch-up afterward.
do $$ declare a uuid:='31000000-0000-0000-0000-00000000000c'; d uuid; removed uuid; first boolean:=true;
 page jsonb; continuation jsonb; boundary bigint; tail jsonb; seen uuid[]:='{}'; e jsonb; epoch uuid;
begin
 perform set_config('request.jwt.claim.sub',a::text,false);
 select dataset_epoch into epoch from app_private.library_v4_config;
 for n in 1..105 loop
  insert into app_private.documents(sha256,scope,reuse_evidence,byte_count,page_count)
   values(sha256(convert_to('compact-pagination-'||n,'UTF8')),'shared_catalog','{"fixture":true}',10,1) returning id into d;
  perform public.v1_set_library_item(d,true); if n=104 then removed:=d; end if;
 end loop;
 loop
  page:=public.v4_library_page(continuation,100);
  perform test.assert(jsonb_array_length(page->'entries')<=100 and octet_length(page::text)<=1048576,'baseline count/byte bounds');
  if first then
   boundary:=(page->>'baseline_cursor')::bigint;
   perform public.v1_set_library_item(removed,false);
   insert into app_private.documents(sha256,scope,reuse_evidence,byte_count,page_count)
    values(sha256(convert_to('compact-pagination-late','UTF8')),'shared_catalog','{"fixture":true}',10,1) returning id into d;
   perform public.v1_set_library_item(d,true); first:=false;
  else
   perform test.assert(exists(select 1 from jsonb_array_elements(page->'entries') x where (x->>'state_seq')::bigint>boundary),
    'creation boundary does not pretend to freeze historical values');
  end if;
  for e in select value from jsonb_array_elements(page->'entries') loop
   perform test.assert(not (e->>'id')::uuid=any(seen),'baseline identity appears once'); seen:=array_append(seen,(e->>'id')::uuid);
  end loop;
  exit when not (page->>'has_more')::boolean; continuation:=page->'next_cursor';
 end loop;
 perform test.assert(cardinality(seen)=105,'late creation stays outside baseline');
 tail:=public.v4_library_changes(epoch,boundary,null,1);
 perform test.assert(tail->>'has_more'='true' and tail->'changes'->0->'entries'->0->>'visible'='false','bounded catch-up includes newer removal');
 tail:=public.v4_library_changes(epoch,(tail->>'next_cursor')::bigint,(tail->>'through')::bigint,1);
 perform test.assert(tail->>'has_more'='false' and tail->'changes'->0->'entries'->0->>'visible'='true'
  and tail->>'next_cursor'=tail->>'through','catch-up reaches fixed boundary with late creation');
 perform test.reject(format('select public.v4_library_changes(%L,%s,%s)',epoch,boundary,boundary-1),'invalid_library_cursor');
end $$;

-- Maximum-size metadata remains a separate bounded response. These cancelled
-- canonical imports deliberately retain 24 distinct pinned metadata identities.
do $$ declare a uuid:='31000000-0000-0000-0000-00000000000b'; meta uuid; ids uuid[]:='{}'; operation uuid; s bigint; result jsonb;
begin
 perform set_config('request.jwt.claim.sub',a::text,false);
 for n in 1..24 loop
  meta:=public.worker_record_arxiv_metadata('2408.'||lpad(n::text,5,'0'),1,
   jsonb_build_object('title','Bounded metadata '||n,'authors','[]'::jsonb,'categories','[]'::jsonb,'abstract',repeat('x',23999)));
  ids:=array_append(ids,meta); operation:=gen_random_uuid(); s:=app_private.library_next_seq(a);
  insert into app_private.import_requests(account_id,id,request_sha256,source_id,observed_cursor,created_seq,state_seq,desired_present,phase,metadata_id)
   values(a,operation,sha256(convert_to(operation::text,'UTF8')),'2408.'||lpad(n::text,5,'0'),0,s,s,false,'cancelled',meta);
  perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,operation)));
 end loop;
 result:=public.v4_library_metadata(test.library_epoch(),ids);
 perform test.assert(jsonb_array_length(result->'records')=24 and octet_length(result::text)<=1048576,'24 large immutable records fit metadata response bound');
 perform test.assert(result->'records'->0->>'metadata_id'=ids[1]::text and result->'records'->23->>'metadata_id'=ids[24]::text,'metadata preserves requested order');
 perform test.assert(octet_length(public.v4_library_page()::text)<octet_length(public.v3_library_page()::text)/4,'compact baseline actually avoids repeated abstracts');
end $$;

-- Future-compatible large compact entries exercise the byte cap independently
-- of the 100-row cap. Padding is fixture-only, within the original journal bound.
do $$ declare a uuid:='31000000-0000-0000-0000-00000000000d'; e jsonb; s bigint; page jsonb; delta jsonb; epoch uuid;
begin
 perform set_config('request.jwt.claim.sub',a::text,false);
 select dataset_epoch into epoch from app_private.library_v4_config;
 for n in 1..100 loop
  s:=app_private.library_next_seq(a);
  e:=jsonb_build_object('kind','import','id',gen_random_uuid(),'created_seq',s,'state_seq',s,'metadata_id',null,
   'visible',false,'source','arxiv','source_id','2407.03105','phase','cancelled','intent_revision',1,'fixture_padding',repeat('z',15000));
  perform app_private.library_emit(a,s,jsonb_build_array(e));
 end loop;
 page:=public.v4_library_page(); delta:=public.v4_library_changes(epoch,0);
 perform test.assert(jsonb_array_length(page->'entries') between 1 and 99 and page->>'has_more'='true'
  and octet_length(page::text)<=1048576,'baseline byte cap ends a page before count cap');
 perform test.assert(jsonb_array_length(delta->'changes') between 1 and 99 and delta->>'has_more'='true'
  and octet_length(delta::text)<=1048576,'delta byte cap preserves whole batches');
end $$;

-- Retention expiry and dataset replacement force an explicit resync. Neither
-- retirement nor v4 reads mutate the existing command receipts or tombstones.
select set_config('request.jwt.claim.sub','31000000-0000-0000-0000-00000000000a',false);
select count(*) as receipt_count from app_private.library_commands where account_id='31000000-0000-0000-0000-00000000000a' \gset
select public.v4_library_page(null,1)->'next_cursor' as before_retirement \gset
update app_private.library_policy set account_journal_events=1;
select public.v2_begin_import(gen_random_uuid(),'2407.03103',(select last_seq from app_private.library_sync_state where account_id='31000000-0000-0000-0000-00000000000a'));
select public.v2_begin_import(gen_random_uuid(),'2407.03104',(select last_seq from app_private.library_sync_state where account_id='31000000-0000-0000-0000-00000000000a'));
set role authenticated;
select test.reject(format('select public.v4_library_page(%L)',:'before_retirement'),'library_resync_required');
select test.reject(format('select public.v4_library_changes(%L,0)',:'epoch'),'library_resync_required');
reset role;
select test.assert((select count(*)=:receipt_count+2 from app_private.library_commands where account_id='31000000-0000-0000-0000-00000000000a'),'retirement keeps original receipts');
select test.assert((select entry->>'visible'='false' from app_private.library_v4_entries where account_id='31000000-0000-0000-0000-00000000000a' and kind='item'),'retirement keeps compact removal fence');
select public.v4_library_page(null,1)->'next_cursor' as before_epoch \gset
update app_private.library_v4_config set dataset_epoch=gen_random_uuid();
set role authenticated;
select test.reject(format('select public.v4_library_page(%L)',:'before_epoch'),'library_resync_required');
select test.reject(format('select public.v4_library_changes(%L,%s)',:'epoch',:'before_epoch'::jsonb->>'through'),'library_resync_required');
select test.reject(format('select public.v4_library_metadata(%L,array[%L::uuid])',:'epoch',:'meta'),'library_resync_required');
reset role;

-- Simulate the sync checkpoint of a restored dataset being below a previously
-- saved valid cursor. Its old epoch must win over the new highwater/anchor
-- checks. The savepoint keeps this deliberate rewind out of later fixtures.
select public.v4_library_page(null,1)->'next_cursor' as before_rewind \gset
savepoint dataset_rewind;
update app_private.library_v4_config set dataset_epoch=gen_random_uuid();
update app_private.library_sync_state set last_seq=0,retained_after=0 where account_id='31000000-0000-0000-0000-00000000000a';
set role authenticated;
select test.reject(format('select public.v4_library_page(%L)',:'before_rewind'),'library_resync_required');
select test.reject(format('select public.v4_library_changes(%L,%s)',:'before_rewind'::jsonb->>'dataset_epoch',:'before_rewind'::jsonb->>'through'),
 'library_resync_required');
reset role;
rollback to savepoint dataset_rewind;
release savepoint dataset_rewind;

-- All three readers share the existing rate and transfer budgets.
update app_private.library_policy set account_transfer_bytes=1;
set role authenticated;
select test.reject('select public.v4_library_page()','library_account_transfer_limit');
select test.reject('select public.v4_library_metadata(test.library_epoch(),array[]::uuid[])','library_account_transfer_limit');
reset role;
update app_private.library_policy set account_transfer_bytes=268435456;
update app_private.api_rate_rules set account_limit=1 where route='library-read';
set role authenticated;
select test.reject('select public.v4_library_page()','request_rate_limit');
select test.reject('select public.v4_library_metadata(test.library_epoch(),array[]::uuid[])','request_rate_limit');
reset role;

-- The projection is derived account state: existing deletion removes it through
-- the library_sync_state FK, and closed accounts cannot recreate read counters.
select public.worker_delete_account_begin('31000000-0000-0000-0000-00000000000a');
select test.assert(not exists(select 1 from app_private.library_v4_entries where account_id='31000000-0000-0000-0000-00000000000a'),'deletion cascades projection');
set role authenticated;
select test.reject('select public.v4_library_page()','authentication_required');
select test.reject('select public.v4_library_metadata(test.library_epoch(),array[]::uuid[])','authentication_required');
reset role;
select test.assert(not exists(select 1 from app_private.library_transfer_months where scope_id='31000000-0000-0000-0000-00000000000a')
 and not exists(select 1 from app_private.api_rate_windows where scope_id='31000000-0000-0000-0000-00000000000a'),'closed reads recreate no account counters');
rollback;
