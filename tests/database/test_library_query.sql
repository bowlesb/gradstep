-- Real SQL, synthetic local data only. All changes roll back.
begin;
insert into auth.users values('32000000-0000-0000-0000-000000000001'),('32000000-0000-0000-0000-000000000002');
select set_config('request.jwt.claim.sub','32000000-0000-0000-0000-000000000001',false);

create function test.query_paper(src text,title text,details jsonb default '{}'::jsonb) returns jsonb
language plpgsql as $$
declare m uuid; d uuid:=gen_random_uuid(); o uuid:=gen_random_uuid(); ap uuid:=gen_random_uuid(); hash bytea:=sha256(convert_to(d::text,'UTF8')); r jsonb;
begin
 m:=public.worker_record_arxiv_metadata(src,1,jsonb_build_object('title',title,'authors',jsonb_build_array('First Author','Second Author','Third Author','Hidden Fourth'),
  'abstract','distinctabstract','categories',jsonb_build_array('cs.LG'),'published_at','2024-01-03')||details);
 insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values(d,hash,'shared_catalog','{"fixture":true}',1000,2);
 insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
 values(o,'paper-assets','test/query/'||d||'.pdf',d,'verified',hash,1000,'application/pdf',now());
 perform public.worker_approve_arxiv_asset(ap,m,d,o,'https://creativecommons.org/licenses/by/4.0/',
  jsonb_build_object('source_id',src,'source_revision',1,'source_url','https://arxiv.org/abs/'||src||'v1',
   'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('a',64),'observed_at','2026-10-07T01:00:00Z'));
 r:=public.v2_set_library_item(gen_random_uuid(),d,true,0,ap);
 return jsonb_build_object('metadata_id',m,'document_id',d,'item_id',r->'entry'->'id','approval_id',ap);
end $$;

select test.query_paper('2410.03201','ÉCOLE and 100% accuracy under_score', '{"venue":"Query Venue","published_at":"2022-01-03"}') as first \gset
select test.query_paper('2410.03202','Beta representation','{"published_at":null,"abstract":"Literal back\\slash; attention"}') as second \gset
select test.query_paper('2410.03203',repeat('界',1000)||' z') as long_z \gset
select test.query_paper('2410.03204',repeat('界',1000)||' a') as long_a \gset
-- NFKC expands this title well beyond B-tree key size, but it is valid metadata.
select test.query_paper('2410.03205',repeat('ﷺ',1900)) as expanded \gset
select test.assert(app_private.library_query_tags('{"tags":["ML","ＭＬ"],"hidden_tags":["ｍｌ"],"user_tags":["Ｍｌ"]}')=array['ML','Ｍｌ'],
 'tag identity retains compatibility-distinct labels before search normalization');

set role authenticated;
select test.assert(jsonb_array_length(public.v4_library_query()->'rows')=5,'query sees current library');
select test.assert(jsonb_array_length(public.v4_library_query('{"text":"hidden distinctabstract"}')->'rows')=4,'AND terms include authors beyond the list summary and abstracts');
select test.assert(jsonb_array_length(public.v4_library_query('{"text":"École"}')->'rows')=1,'Unicode simple lowercase');
select test.assert(jsonb_array_length(public.v4_library_query(jsonb_build_object('text',U&'E\0301cole'))->'rows')=1,'canonical Unicode normalization');
select test.assert(jsonb_array_length(public.v4_library_query('{"text":"ecole"}')->'rows')=0,'documented accent sensitivity');
select test.assert(jsonb_array_length(public.v4_library_query('{"text":"%"}')->'rows')=1,'percent is literal');
select test.assert(jsonb_array_length(public.v4_library_query('{"text":"_"}')->'rows')=1,'underscore is literal');
select test.assert(jsonb_array_length(public.v4_library_query(jsonb_build_object('text',chr(92)))->'rows')=1,'backslash is literal');
select test.assert(jsonb_array_length(public.v4_library_query('{"text":"AUTHORdistinctabstract"}')->'rows')=0,'term cannot bridge metadata fields');
select test.assert(public.v4_library_query('{"text":"2410.03201v1"}')->'rows'->0->'summary'->>'author_count'='4'
 and jsonb_array_length(public.v4_library_query('{"text":"2410.03201v1"}')->'rows'->0->'summary'->'authors')=3,'summary bounded without losing full search');
select test.assert(jsonb_array_length(public.v4_library_query('{"source":"web"}')->'rows')=0,'source filter');
select test.assert(jsonb_array_length(public.v4_library_query('{"tag":"Machine learning"}')->'rows')=5,'category fallback agrees with displayed tags');
select test.assert(jsonb_array_length(public.v4_library_query('{"text":"machine learning"}')->'rows')=5,'friendly category fallback is searchable');
select test.reject($q$select public.v4_library_query('{"sort":"opened"}')$q$,'invalid_library_query');
select test.reject($q$select public.v4_library_query('{"sort":"recent;drop table"}')$q$,'invalid_library_query');
select test.reject($q$select public.v4_library_query('{"text":null}')$q$,'invalid_library_query');
select test.reject($q$select public.v4_library_query(jsonb_build_object('text',repeat('x',513)))$q$,'invalid_library_query');
select test.reject($q$select public.v4_library_query(jsonb_build_object('text',(select string_agg(n::text,' ') from generate_series(1,17) n)))$q$,'invalid_library_query');
select test.reject($q$select public.v4_library_query('{}',null,51)$q$,'invalid_library_page');
select test.reject($q$select * from app_private.library_query_entries$q$,'permission denied');
select test.reject($q$select app_private.library_search_normalize('secret')$q$,'permission denied');
reset role;

-- Compare every paginated ordering to an independent full SQL reference.
do $$ declare s text; d text; page jsonb; cursor jsonb; actual uuid[]; expected uuid[]; visits integer; begin
 foreach s in array array['recent','title','year'] loop
  foreach d in array array['asc','desc'] loop
   cursor:=null; actual:='{}'; visits:=0;
   loop
    page:=public.v4_library_query(jsonb_build_object('sort',s,'direction',d),cursor,1);
    select actual||coalesce(array_agg((x->'state'->>'id')::uuid),'{}') into actual from jsonb_array_elements(page->'rows') x;
    visits:=visits+1; perform test.assert(visits<=5,'pagination advances');
    exit when not (page->>'has_more')::boolean;
    cursor:=page->'next_cursor';
   end loop;
   if s='title' then
    select array_agg(li.id order by
     case when d='asc' then app_private.library_search_normalize(cm.metadata->>'title') end collate "C" asc,
     case when d='desc' then app_private.library_search_normalize(cm.metadata->>'title') end collate "C" desc,
     case when d='asc' then li.id end asc,case when d='desc' then li.id end desc) into expected
    from app_private.library_items li join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
     join app_private.catalog_metadata cm on cm.id=ca.metadata_id where li.account_id=auth.uid();
   elsif s='year' then
    select array_agg(li.id order by (cm.metadata->>'published_at' is null) asc,
     case when d='asc' then left(cm.metadata->>'published_at',4)::integer end asc,
     case when d='desc' then left(cm.metadata->>'published_at',4)::integer end desc,
     case when d='asc' then li.id end asc,case when d='desc' then li.id end desc) into expected
    from app_private.library_items li join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
     join app_private.catalog_metadata cm on cm.id=ca.metadata_id where li.account_id=auth.uid();
   else
    select array_agg(id order by case when d='asc' then created_seq end asc,case when d='desc' then created_seq end desc,
     case when d='asc' then id end asc,case when d='desc' then id end desc) into expected
    from app_private.library_items where account_id=auth.uid();
   end if;
   perform test.assert(actual=expected,'full result and exact order '||s||' '||d);
  end loop;
 end loop;
end $$;

set role authenticated;
select public.v4_library_query('{}',null,1) as old_page \gset
select test.reject(format('select public.v4_library_query(%L,%L,1)','{"sort":"title"}',:'old_page'::jsonb->'next_cursor'),'invalid_library_cursor');
select test.reject(format('select public.v4_library_query(%L,%L,1)','{}',jsonb_set(:'old_page'::jsonb->'next_cursor','{query_revision}','999999999999999999999999999999')),'invalid_library_cursor');
select test.reject(format('select public.v4_library_query(%L,%L,1)','{}',jsonb_set(:'old_page'::jsonb->'next_cursor','{id}',to_jsonb(gen_random_uuid()))),'invalid_library_cursor');
select set_config('request.jwt.claim.sub','32000000-0000-0000-0000-000000000002',false);
select test.assert(public.v4_library_query()->'rows'='[]'::jsonb,'another account has no rows');
select test.reject(format('select public.v4_library_query(%L,%L,1)','{}',:'old_page'::jsonb->'next_cursor'),'invalid_library_cursor');
select set_config('request.jwt.claim.sub','32000000-0000-0000-0000-000000000001',false);
select public.v2_set_item_tags(gen_random_uuid(),(:'first'::jsonb->>'document_id')::uuid,array['Reading group'],'{}',1);
select test.reject(format('select public.v4_library_query(%L,%L,1)','{}',:'old_page'::jsonb->'next_cursor'),'library_query_restart_required');
select test.assert(jsonb_array_length(public.v4_library_query('{"tag":"READING GROUP"}')->'rows')=1,'effective-tag filter');
select test.assert(jsonb_array_length(public.v4_library_query('{"text":"group école"}')->'rows')=1,'AND can cross metadata and personal tags');
select public.v4_library_query('{}',null,1) as before_archive \gset
select public.v2_set_item_archived(gen_random_uuid(),(:'first'::jsonb->>'document_id')::uuid,true,2);
select test.reject(format('select public.v4_library_query(%L,%L,1)','{}',:'before_archive'::jsonb->'next_cursor'),'library_query_restart_required');
select test.assert(jsonb_array_length(public.v4_library_query()->'rows')=4 and jsonb_array_length(public.v4_library_query('{"archive":"archived"}')->'rows')=1,'archive partitions');
select test.assert(jsonb_array_length(public.v4_library_query('{"archive":"all"}')->'rows')=5,'all includes archived');

-- A pending import sorts after real titles/years, regardless of direction.
select public.v2_begin_import('32000000-0000-0000-0000-000000000101','2410.03209',(public.v4_library_page()->>'baseline_cursor')::bigint,1);
select test.assert(public.v4_library_query('{"sort":"title","direction":"desc"}')->'rows'->-1->'state'->>'id'='32000000-0000-0000-0000-000000000101','missing title last descending');
select public.v4_library_query('{}',null,1) as before_progress \gset
reset role;
do $$ declare a uuid:=auth.uid(); s bigint; i uuid:='32000000-0000-0000-0000-000000000101'; begin
 perform app_private.lock_library_account(a); perform app_private.lock_library_state(a); s:=app_private.library_next_seq(a);
 update app_private.import_requests set state_seq=s,progress='downloading' where account_id=a and id=i;
 perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,i)));
end $$;
set role authenticated;
select test.assert(public.v4_library_query('{}',:'before_progress'::jsonb->'next_cursor',1)->>'query_revision'=:'before_progress'::jsonb->>'query_revision','progress does not invalidate query');
reset role;

-- Upgrade/version/restore guards and transfer accounting fail closed.
update app_private.library_v4_config set search_version='unknown';
select test.reject('select public.v4_library_query()','library_query_rebuild_required');
update app_private.library_v4_config set search_version=app_private.library_search_version(),dataset_epoch=gen_random_uuid();
select test.reject(format('select public.v4_library_query(%L,%L,1)','{}',:'before_progress'::jsonb->'next_cursor'),'library_query_restart_required');
update app_private.library_policy set account_transfer_bytes=1;
select test.reject('select public.v4_library_query()','library_account_transfer_limit');
reset role;
set role anon;
select test.reject('select public.v4_library_query()','permission denied');
reset role;
rollback;
