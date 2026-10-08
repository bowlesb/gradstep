-- Actual read/projection SQL, synthetic canonical rows only. No Storage or provider calls.
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
\set A '39500000-0000-0000-0000-000000000001'
\set B '39500000-0000-0000-0000-000000000002'
\set U '39500000-0000-0000-0000-000000000011'
\set R '39500000-0000-0000-0000-000000000012'
\set V '39500000-0000-0000-0000-000000000013'
\set W '39500000-0000-0000-0000-000000000014'
insert into auth.users values(:'A'),(:'B');
select dataset_epoch as old_epoch,upload_dataset_epoch as epoch from app_private.library_v4_config \gset
select test.assert(:'old_epoch'<>:'epoch','visibility capabilities have distinct dataset identities');

create function test.visibility_import(a uuid,i uuid,src text,title text,descriptor boolean) returns uuid
language plpgsql as $$
declare pub uuid; ver uuid; m uuid; s bigint; meta jsonb:=jsonb_build_object('title',title,'authors','[]'::jsonb,'categories','[]'::jsonb);
begin
 insert into app_private.publications(title) values(title) returning id into pub;
 insert into app_private.publication_versions(publication_id,source,revision) values(pub,src,'1') returning id into ver;
 insert into app_private.catalog_metadata(version_id,source_id,source_revision,metadata,metadata_sha256)
  values(ver,src,1,meta,sha256(convert_to(meta::text,'UTF8'))) returning id into m;
 if descriptor then
  insert into app_private.library_descriptors(account_id,source_id,id,revision,mutation_id,device_id,epoch,format,ciphertext,sha256)
   values(a,src,gen_random_uuid(),1,gen_random_uuid(),gen_random_uuid(),1,1,decode(repeat('11',28),'hex'),sha256(decode(repeat('11',28),'hex')));
 end if;
 s:=app_private.library_next_seq(a);
 insert into app_private.import_requests(account_id,id,request_sha256,source_id,requested_revision,observed_cursor,created_seq,state_seq,metadata_id)
  values(a,i,sha256(convert_to(i::text,'UTF8')),src,case when src not like 'upload:%' and src not like 'openalex:%' then 1 end,0,s,s,m);
 perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,i)));
 return m;
end $$;
select test.visibility_import(:'A',:'U','upload:'||:'U','Uploaded PDF',true) as upload_meta \gset
select test.visibility_import(:'A',:'R','2410.03951','Arxiv visible paper',false) as arxiv_meta \gset
select test.visibility_import(:'A',:'V','upload:'||:'V','Uploaded PDF',true) as upload_meta2 \gset
select test.visibility_import(:'A',:'W','openalex:W395001','Web visible paper',false) as web_meta \gset
select test.assert((select array_agg(minimum_source_level order by created_seq)=array[4,2,4,3]::smallint[]
 from app_private.library_v4_entries where account_id=:'A'),'source level is persisted per current entry');
select test.assert((select bool_and(encoded_bytes=octet_length(entries::text)+128 and entries->0 ? 'minimum_source_level')
 from app_private.library_changes where account_id=:'A'),'journal admission and storage measure stamped bytes');

set role anon;
select test.reject('select public.v5_library_page()','permission denied');
select test.reject(format('select public.v5_library_changes(%L,0)',:'epoch'),'permission denied');
select test.reject('select public.v5_library_compact_page()','permission denied');
select test.reject('select public.v5_library_query()','permission denied');
reset role;
set role service_role;
select test.reject('select public.v5_library_page()','permission denied');
select test.reject(format('select public.v5_library_compact_changes(%L,0)',:'epoch'),'permission denied');
select test.reject(format('select public.v5_library_metadata(%L,array[]::uuid[])',:'epoch'),'permission denied');
select test.reject('select public.v5_library_query()','permission denied');
reset role;
select test.assert(to_regprocedure('public.v5_library_changes(bigint,bigint,integer)') is null,'no unbound v5 delta overload');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v5_library_page(null,1) as full5,public.v5_library_compact_page(null,1) as compact5,
 public.v3_library_page(null,1) as full3,public.v4_library_page(null,1) as compact4 \gset
select public.v5_library_page(:'full5'::jsonb->'next_cursor',100) as full5_tail,
 public.v1_reader_capabilities() as native_capabilities \gset
select test.assert(:'full5'::jsonb->>'format'='2' and :'full5'::jsonb->>'dataset_epoch'=:'epoch'
 and :'full5'::jsonb->'next_cursor'->>'read_level'='4' and :'full5'::jsonb->'next_cursor'->>'dataset_epoch'=:'epoch'
 and :'full5'::jsonb->'entries'->0->>'id'=:'U' and :'full5'::jsonb->'entries'->0 ? 'descriptor_ref','full v5 binds capability and epoch');
select test.assert(:'compact5'::jsonb->>'format'='5' and :'compact5'::jsonb->>'dataset_epoch'=:'epoch'
 and not (:'compact5'::jsonb->'entries'->0 ? 'metadata') and :'compact5'::jsonb->'entries'->0 ? 'descriptor_ref','compact v5 separates metadata and descriptor refs');
select test.assert(:'full3'::jsonb->'entries'->0->>'id'=:'R' and :'compact4'::jsonb->'entries'->0->>'id'=:'R'
 and jsonb_array_length(public.v2_library_page()->'entries')=1
 and jsonb_array_length(public.v3_library_page()->'entries')=2 and jsonb_array_length(public.v4_library_page()->'entries')=2,
 'hidden uploads do not consume legacy baseline page slots');
select test.assert(not exists(select 1 from jsonb_array_elements(public.v4_library_page()->'entries') e
 where e ? 'descriptor_ref' or e ? 'minimum_source_level'),'internal fields absent from legacy wire');
select test.reject(format('select public.v5_library_page(%L)',:'full3'::jsonb->'next_cursor'),'invalid_library_cursor');
select test.reject(format('select public.v3_library_page(%L)',:'full5'::jsonb->'next_cursor'),'invalid_library_cursor');
select test.reject(format('select public.v5_library_page(%L)',(:'full5'::jsonb->'next_cursor')-'dataset_epoch'),'invalid_library_cursor');
select test.reject(format('select public.v5_library_page(%L)',(:'full5'::jsonb->'next_cursor')||jsonb_build_object('dataset_epoch',:'old_epoch')),'library_resync_required');
select test.reject(format('select public.v4_library_page(%L)',:'compact5'::jsonb->'next_cursor'),'invalid_library_cursor');
select test.reject(format('select public.v5_library_compact_page(%L)',:'compact4'::jsonb->'next_cursor'),'invalid_library_cursor');
select test.reject(format('select public.v5_library_compact_changes(%L,0)',:'old_epoch'),'library_resync_required');
select test.reject(format('select public.v4_library_changes(%L,0)',:'epoch'),'library_resync_required');
select test.reject('select public.v5_library_changes(null,0)','invalid_library_cursor');
select test.reject(format('select public.v5_library_changes(%L,0)',:'old_epoch'),'library_resync_required');

-- Hidden changes never produce an empty continuation in installed decoders.
select public.v3_library_changes(0,null,1) as hidden3,public.v4_library_changes(:'old_epoch',0,null,1) as hidden4 \gset
select test.assert(jsonb_array_length(:'hidden3'::jsonb->'changes')=1 and :'hidden3'::jsonb->>'next_cursor'='2'
 and :'hidden3'::jsonb->>'has_more'='true' and :'hidden3'::jsonb->'changes'->0->>'seq'='2'
 and jsonb_array_length(:'hidden4'::jsonb->'changes')=1 and :'hidden4'::jsonb->'changes'->0->>'seq'='2'
 and :'hidden4'::jsonb->>'next_cursor'='2' and :'hidden4'::jsonb->>'has_more'='true','hidden batches are skipped before bounded visible paging');
select test.assert(public.v3_library_changes(2,null,1)->'changes'->0->>'seq'='4'
 and public.v5_library_changes(:'epoch',0,null,1)->'changes'->0->'entries'->0->>'id'=:'U','next page and full v5 retain proper observations');
select test.reject(format('select public.v4_library_metadata(%L,array[%L::uuid,%L::uuid])',:'old_epoch',:'arxiv_meta',:'upload_meta'),'library_metadata_unavailable');
select test.assert(public.v5_library_metadata(:'epoch',array[:'upload_meta'::uuid])->'records'->0->'metadata'->>'title'='Uploaded PDF',
 'immutable upload catalog stays neutral; private custom title is not decrypted by server');
select test.reject($q$select public.v4_library_query('{"source":"upload"}')$q$,'invalid_library_query');
select public.v5_library_query('{}',null,1) as query5,public.v4_library_query('{}',null,1) as query4 \gset
select test.assert(jsonb_array_length(public.v4_library_query()->'rows')=2
 and jsonb_array_length(public.v5_library_query()->'rows')=4
 and jsonb_array_length(public.v5_library_query('{"source":"upload"}')->'rows')=2,'query candidates use their visibility capability');
select test.reject(format('select public.v4_library_query(''{}'',%L)',:'query5'::jsonb->'next_cursor'),'invalid_library_cursor');
select test.reject(format('select public.v5_library_query(''{}'',%L)',:'query4'::jsonb->'next_cursor'),'invalid_library_cursor');
select test.reject(format('select public.v5_library_query(''{}'',%L)',(:'query5'::jsonb->'next_cursor')||jsonb_build_object('dataset_epoch',:'old_epoch')),'library_query_restart_required');
reset role;

-- Full/compact pages match the independently sorted source population; query
-- continuations match a complete page across every ordering and capability.
do $$ declare a uuid:='39500000-0000-0000-0000-000000000001'; level integer; mode text; order_name text; direction text;
 page jsonb; cursor jsonb; visits integer; actual uuid[]; expected uuid[]; e jsonb;
begin
 foreach level in array array[3,4] loop
  foreach mode in array array['full','compact'] loop
   cursor:=null; visits:=0; actual:='{}';
   loop
    page:=case when mode='full' then app_private.library_baseline_at(a,cursor,1,level) else app_private.library_compact_baseline_at(a,cursor,1,level) end;
    for e in select value from jsonb_array_elements(page->'entries') loop actual:=array_append(actual,(e->>'id')::uuid); end loop;
    visits:=visits+1; perform test.assert(visits<=5,'baseline terminates');
    exit when not (page->>'has_more')::boolean;
    cursor:=page->'next_cursor';
   end loop;
   select array_agg(id order by created_seq,id,kind) into expected from app_private.library_v4_entries where account_id=a and minimum_source_level<=level;
   perform test.assert(actual=expected,'complete baseline matches capability');
  end loop;
  foreach order_name in array array['recent','title','year'] loop
   foreach direction in array array['asc','desc'] loop
    cursor:=null; visits:=0; actual:='{}';
    loop
     page:=app_private.library_query_page_at(a,jsonb_build_object('sort',order_name,'direction',direction),cursor,1,level);
     for e in select value from jsonb_array_elements(page->'rows') loop actual:=array_append(actual,(e->'state'->>'id')::uuid); end loop;
     visits:=visits+1; perform test.assert(visits<=5,'query terminates');
     exit when not (page->>'has_more')::boolean; cursor:=page->'next_cursor';
    end loop;
    select array_agg((value->'state'->>'id')::uuid order by n) into expected
     from jsonb_array_elements(app_private.library_query_page_at(a,jsonb_build_object('sort',order_name,'direction',direction),null,50,level)->'rows') with ordinality x(value,n);
    perform test.assert(actual=expected and cardinality(actual)=case when level=4 then 4 else 2 end,'query pagination preserves sorted population');
   end loop;
  end loop;
 end loop;
end $$;

-- Changing only an opaque descriptor invalidates query continuation and emits
-- immutable refs. Catalog UUID/payload remains byte-for-byte unchanged.
select query_revision as before_revision from app_private.library_sync_state where account_id=:'A' \gset
update app_private.library_descriptors set revision=2,mutation_id=gen_random_uuid(),ciphertext=decode(repeat('22',28),'hex'),sha256=sha256(decode(repeat('22',28),'hex'))
 where account_id=:'A' and source_id='upload:'||:'U';
select app_private.library_descriptor_emit(:'A','upload:'||:'U');
select test.assert((select query_revision>:before_revision from app_private.library_sync_state where account_id=:'A'),
 'descriptor-only rename invalidates query ordering');
select test.assert((select metadata->>'title'='Uploaded PDF' from app_private.catalog_metadata where id=:'upload_meta'),
 'rename never mutates public metadata identity');
select test.assert((select entries->0->'descriptor_ref'->>'revision'='1' from app_private.library_changes where account_id=:'A' and seq=1),
 'old journal descriptor refs never rewritten');
select test.assert(app_private.library_delta_at(:'A',4,5,1,3)->'changes'='[]'::jsonb
 and app_private.library_delta_at(:'A',4,5,1,3)->>'has_more'='false'
 and app_private.library_delta_at(:'A',4,5,1,3)->>'next_cursor'='5','all-hidden remainder completes at highwater');
select test.assert(app_private.library_delta_at(:'A',0,3,1,3)->>'next_cursor'='3'
 and app_private.library_delta_at(:'A',0,3,1,3)->>'has_more'='false','hidden tail after last visible batch completes without a phantom continuation');
-- The local integration runner captures these actual SQL responses and feeds
-- them through unchanged installed Swift and Web decoders.
select 'LEGACY_DECODER_FIXTURE '||jsonb_build_object('baselines',jsonb_build_array(
 app_private.library_baseline_at(:'A',null,100,2),app_private.library_baseline_at(:'A',null,100,3)),
 'changes',jsonb_build_array(
 app_private.library_delta_at(:'A',0,5,1,3),app_private.library_delta_at(:'A',2,5,1,3),
 app_private.library_delta_at(:'A',0,3,1,3),app_private.library_delta_at(:'A',4,5,1,3)))::text;
set role authenticated;
select test.reject(format('select public.v5_library_query(''{}'',%L)',:'query5'::jsonb->'next_cursor'),'library_query_restart_required');
select test.assert(public.v5_library_page()->'entries'->0->'descriptor_ref'->>'revision'='2','full v5 reads latest descriptor pin');
reset role;

-- Source-null tombstones inherit prior capability/ref, per entry in a mixed
-- group. One upload removal can neither hide the public sibling nor leak itself.
do $$ declare a uuid:='39500000-0000-0000-0000-000000000001'; u uuid:='39500000-0000-0000-0000-000000000011';
 r uuid:='39500000-0000-0000-0000-000000000012'; s bigint; up jsonb; ar jsonb; page jsonb;
begin
 s:=app_private.library_next_seq(a);
 select entry-'minimum_source_level' into up from app_private.library_v4_entries where account_id=a and id=u;
 ar:=app_private.library_import_entry(a,r);
 up:=(up-'source'-'source_id'-'metadata_id')||jsonb_build_object('visible',false,'state_seq',s,'metadata_id',null);
 ar:=ar||jsonb_build_object('visible',false,'state_seq',s);
 perform app_private.library_emit(a,s,jsonb_build_array(up,ar));
 perform test.assert((select minimum_source_level=4 and entry->'descriptor_ref'->>'revision'='2'
  from app_private.library_v4_entries where account_id=a and id=u),'source-null tombstone retains hidden identity and last descriptor pin');
 page:=app_private.library_delta_at(a,s-1,s,1,3);
 perform test.assert(jsonb_array_length(page->'changes'->0->'entries')=1 and page->'changes'->0->'entries'->0->>'id'=r::text,
  'mixed batch filters per entry without losing visible sibling');
 perform test.assert(jsonb_array_length(app_private.library_delta_at(a,s-1,s,1,4)->'changes'->0->'entries')=2,'v5 group stays atomic');
 perform test.reject(format('select app_private.library_emit(%L,%s,%L)',a,s,jsonb_build_array(up||'{"minimum_source_level":2}'::jsonb)),
  'library_source_identity_conflict');
 perform test.reject(format('select app_private.library_v4_project_entry(%L,%L)',a,up||'{"source":"arxiv"}'::jsonb),
  'library_source_identity_conflict');
end $$;
select 'LEGACY_MIXED_FIXTURE '||app_private.library_delta_at(:'A',5,6,1,3)::text;
set role authenticated;
select 'NATIVE_V5_FIXTURE '||jsonb_build_object(
 'capabilities',:'native_capabilities'::jsonb,
 'baselines',jsonb_build_array(:'full5'::jsonb,:'full5_tail'::jsonb),
 'changes',jsonb_build_array(public.v5_library_changes(:'epoch',4,5,100),public.v5_library_changes(:'epoch',5,6,1)))::text;
reset role;

-- A long hidden history cannot consume legacy page slots or change completion.
-- Direct fixture inserts retain the real stamping/projection triggers; no
-- admission cap or customer allowance is raised for this internal read test.
insert into app_private.library_changes(account_id,seq,entries)
 select :'A',n,jsonb_build_array(entry||jsonb_build_object('state_seq',n))
 from app_private.library_v4_entries e cross join generate_series(7,1006) n
 where e.account_id=:'A' and e.id=:'U';
update app_private.library_sync_state set last_seq=1006 where account_id=:'A';
select test.assert(app_private.library_delta_at(:'A',6,1006,1,3)->'changes'='[]'::jsonb
 and app_private.library_delta_at(:'A',6,1006,1,3)->>'next_cursor'='1006'
 and app_private.library_delta_at(:'A',6,1006,1,3)->>'has_more'='false','one thousand hidden batches finish without empty continuations');
select test.assert((select count(*)=3 from app_private.library_visible_changes(:'A',0,1006,100,3))
 and (select count(*)=1 from app_private.library_visible_changes(:'A',6,1006,1,4)),
 'capability seeks select visible batches before loading payloads');
select test.assert(pg_get_indexdef('app_private.library_changes_visibility'::regclass)
 like '%(account_id, minimum_source_level, seq)%','equality capability ranges have a bounded sequence index');

-- Restore/replacement rotates the common v5 epoch. Even plausible highwaters
-- and existing anchor identities cannot revive old full/compact/query cursors.
update app_private.library_v4_config set upload_dataset_epoch=gen_random_uuid();
set role authenticated;
select test.reject(format('select public.v5_library_page(%L)',:'full5'::jsonb->'next_cursor'),'library_resync_required');
select test.reject(format('select public.v5_library_changes(%L,0)',:'epoch'),'library_resync_required');
select test.reject(format('select public.v5_library_compact_page(%L)',:'compact5'::jsonb->'next_cursor'),'library_resync_required');
select test.reject(format('select public.v5_library_compact_changes(%L,0)',:'epoch'),'library_resync_required');
select test.reject(format('select public.v5_library_metadata(%L,array[%L::uuid])',:'epoch',:'upload_meta'),'library_resync_required');
select test.reject(format('select public.v5_library_query(''{}'',%L)',:'query5'::jsonb->'next_cursor'),'library_query_restart_required');
select set_config('request.jwt.claim.sub',:'B',false);
select test.assert(public.v5_library_page()->'entries'='[]'::jsonb and public.v5_library_query()->'rows'='[]'::jsonb,'other account cannot see uploads');
select test.reject(format('select public.v5_library_page(%L)',:'full5'::jsonb->'next_cursor'),'invalid_library_cursor');
select test.reject(format('select public.v4_library_metadata(%L,array[%L::uuid])',:'old_epoch',:'arxiv_meta'),'library_metadata_unavailable');
reset role;
rollback;
