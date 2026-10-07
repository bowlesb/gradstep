-- Focused query edge fixtures. Local only; the complete transaction rolls back.
-- No quota changes, network, provider work or production-capacity claims.
begin;
insert into auth.users values('33000000-0000-0000-0000-000000000001'),('33000000-0000-0000-0000-000000000002'),
 ('33000000-0000-0000-0000-000000000003'),('33000000-0000-0000-0000-000000000004'),('33000000-0000-0000-0000-000000000005');

create function test.query_edge_paper(src text,title text,details jsonb default '{}'::jsonb) returns jsonb language plpgsql as $$
declare m uuid; d uuid:=gen_random_uuid(); o uuid:=gen_random_uuid(); ap uuid:=gen_random_uuid(); hash bytea:=sha256(convert_to(d::text,'UTF8'));
begin
 m:=public.worker_record_arxiv_metadata(src,1,jsonb_build_object('title',title,'authors','[]'::jsonb,'categories','[]'::jsonb,'published_at','2024-01-03')||details);
 insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values(d,hash,'shared_catalog','{"fixture":true}',1000,2);
 insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
 values(o,'paper-assets','test/query-edges/'||d||'.pdf',d,'verified',hash,1000,'application/pdf',now());
 perform public.worker_approve_arxiv_asset(ap,m,d,o,'https://creativecommons.org/licenses/by/4.0/',
  jsonb_build_object('source_id',src,'source_revision',1,'source_url','https://arxiv.org/abs/'||src||'v1',
   'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('a',64),'observed_at','2026-10-07T01:00:00Z'));
 return public.v2_set_library_item(gen_random_uuid(),d,true,0,ap)->'entry';
end $$;

-- Collect public pages using composite identities. Every continuation must
-- advance, and a generation can never deliver the same item/import twice.
create function test.query_edge_ids(q jsonb, page_limit integer default 1) returns text[] language plpgsql as $$
declare page jsonb; cursor jsonb; result text[]:='{}'; row jsonb; token text; visits integer:=0;
begin
 loop
  page:=public.v4_library_query(q,cursor,page_limit); visits:=visits+1;
  perform test.assert(visits<=100,'query identity collector always terminates');
  for row in select value from jsonb_array_elements(page->'rows') loop
   token:=(row->'state'->>'kind')||':'||(row->'state'->>'id');
   perform test.assert(not token=any(result),'query generation has no duplicate composite identity');
   result:=array_append(result,token);
  end loop;
  exit when not (page->>'has_more')::boolean;
  perform test.assert(jsonb_array_length(page->'rows')>0 and page->'next_cursor'<>'null'::jsonb,'nonterminal query makes progress');
  cursor:=page->'next_cursor';
 end loop;
 perform test.assert(page->'next_cursor'='null'::jsonb,'completed query has no continuation');
 return result;
end $$;

-- Obtain complete current item/import wire shapes from canonical commands.
-- The import is unlinked, visible, and pins the same metadata as the item.
select set_config('request.jwt.claim.sub','33000000-0000-0000-0000-000000000001',false);
select test.query_edge_paper('2412.03301','Pagination template') as template_item \gset
select public.v2_begin_import('33000000-0000-0000-0000-000000000101','2412.03301',1,1);
select public.worker_checkpoint_import('33000000-0000-0000-0000-000000000001','33000000-0000-0000-0000-000000000101',2,1,'acquiring',(:'template_item'::jsonb->>'metadata_id')::uuid);
create temporary table query_edge_templates(kind text primary key,entry jsonb not null);
insert into query_edge_templates values('item',:'template_item'::jsonb-'metadata'),
 ('import',app_private.library_import_entry('33000000-0000-0000-0000-000000000001','33000000-0000-0000-0000-000000000101')-'metadata');

-- Trusted projection-only fixture: future-compatible padding stresses response
-- bytes without manufacturing enormous canonical titles or raising any limit.
-- Eighty rows are well below current retained-entry capacity. The public API
-- must resume from its LAST RETURNED row, not its 50th candidate.
do $$ declare a uuid:='33000000-0000-0000-0000-000000000002'; base jsonb; id uuid; expected_asc text[]:='{}'; expected_desc text[]:='{}';
 direction text; page jsonb; cursor jsonb; actual text[]; token text; row jsonb; visits integer; byte_limited boolean;
begin
 select entry into strict base from query_edge_templates where kind='item';
 for n in 1..80 loop
  id:=('33010000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;
  perform app_private.library_v4_project_entry(a,base||jsonb_build_object('id',id,'created_seq',n,'state_seq',n,
   'visible',true,'fixture_padding',repeat('x',30000)));
  token:='item:'||id; expected_asc:=array_append(expected_asc,token); expected_desc:=array_prepend(token,expected_desc);
 end loop;
 update app_private.library_sync_state set last_seq=80 where account_id=a;
 perform set_config('request.jwt.claim.sub',a::text,false);
 foreach direction in array array['asc','desc'] loop
  cursor:=null; actual:='{}'; visits:=0; byte_limited:=false;
  loop
   page:=public.v4_library_query(jsonb_build_object('sort','recent','direction',direction),cursor,50);
   visits:=visits+1;
   perform test.assert(visits<=80,'byte-limited query always advances');
   perform test.assert(jsonb_array_length(page->'rows') between 1 and 50 and octet_length(page::text)<=1048576,'query row/byte bounds');
   for row in select value from jsonb_array_elements(page->'rows') loop
    token:=(row->'state'->>'kind')||':'||(row->'state'->>'id');
    perform test.assert(not token=any(actual),'byte-limited pages never repeat an identity');
    actual:=array_append(actual,token);
   end loop;
   if (page->>'has_more')::boolean then
    perform test.assert(page->'next_cursor'<>'null'::jsonb,'more rows require a continuation');
    perform test.assert(page->'next_cursor'->>'id'=page->'rows'->-1->'state'->>'id'
     and page->'next_cursor'->>'kind'=page->'rows'->-1->'state'->>'kind','byte-limited cursor anchors the last delivered row');
    byte_limited:=byte_limited or jsonb_array_length(page->'rows')<50;
   else
    perform test.assert(page->'next_cursor'='null'::jsonb,'terminal page has no continuation');
   end if;
   exit when not (page->>'has_more')::boolean;
   cursor:=page->'next_cursor';
  end loop;
  perform test.assert(byte_limited and visits>=3,'padding genuinely forces multiple byte-limited pages at p_limit 50');
  perform test.assert(actual=case when direction='asc' then expected_asc else expected_desc end,
   'exact concatenated identity sequence across byte-limited pages '||direction);
 end loop;
end $$;

-- Trusted projection-only identity fixture: item/import namespaces may share a
-- UUID, and creation sequences may tie (e.g. old baseline backfills). Metadata,
-- title and year also tie. The final kind key must survive a page boundary in
-- every supported ordering, with neither kind suppressed nor duplicated.
do $$ declare a uuid:='33000000-0000-0000-0000-000000000003'; id uuid; k text; base jsonb;
 expected_asc text[]:='{}'; expected_desc text[]:='{}'; actual text[]; s text; d text; page jsonb; cursor jsonb; token text; visits integer;
begin
 for n in 1..2 loop
  id:=('33020000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid;
  foreach k in array array['import','item'] loop
   select entry into strict base from query_edge_templates where kind=k;
   perform app_private.library_v4_project_entry(a,base||jsonb_build_object('id',id,'created_seq',1,'state_seq',1,'visible',true));
   token:=k||':'||id; expected_asc:=array_append(expected_asc,token); expected_desc:=array_prepend(token,expected_desc);
  end loop;
 end loop;
 update app_private.library_sync_state set last_seq=1 where account_id=a;
 perform set_config('request.jwt.claim.sub',a::text,false);
 foreach s in array array['recent','title','year'] loop
  foreach d in array array['asc','desc'] loop
   cursor:=null; actual:='{}'; visits:=0;
   loop
    page:=public.v4_library_query(jsonb_build_object('sort',s,'direction',d),cursor,1);
    visits:=visits+1; perform test.assert(visits<=4 and jsonb_array_length(page->'rows')=1,'tied identity query advances one row');
    token:=(page->'rows'->0->'state'->>'kind')||':'||(page->'rows'->0->'state'->>'id');
    perform test.assert(not token=any(actual),'tied composite identity appears once'); actual:=array_append(actual,token);
    exit when not (page->>'has_more')::boolean;
    cursor:=page->'next_cursor';
   end loop;
   perform test.assert(actual=case when d='asc' then expected_asc else expected_desc end,
    'exact UUID/kind tie order for '||s||' '||d);
  end loop;
 end loop;
end $$;

-- Both query strategies must return identical literal-AND/filter results at
-- the 50/51-visible-row boundary. All rows and transitions here use canonical
-- commands. An archived item is still visible for strategy selection; removed
-- retained rows are not. Queries intentionally have only one or two matches,
-- and p_limit=1 exercises continuations under both strategies.
insert into auth.users values('33000000-0000-0000-0000-000000000007');
do $$ declare a uuid:='33000000-0000-0000-0000-000000000007'; first jsonb; second jsonb; sentinel jsonb;
 first_id text; second_id text; both_ids text[]; old_cursor jsonb; q jsonb; actual text[]; expected text[];
 stage integer; query_index integer; visible_count integer; active_count integer;
 queries jsonb[]:=array[
  '{"text":"ÉCOLE sharedneedle"}'::jsonb,
  '{"text":"% sharedneedle"}'::jsonb,
  '{"text":"under_score sharedneedle"}'::jsonb,
  jsonb_build_object('text','slash'||chr(92)||'path sharedneedle'),
  '{"text":"needle tag sharedneedle"}'::jsonb,
  '{"text":"machine learning cs.LG"}'::jsonb,
  jsonb_build_object('text',U&'E\0301cole sharedneedle'),
  '{"tag":"NEEDLE TAG","text":"école"}'::jsonb,
  '{"tag":"Machine learning","text":"sharedneedle"}'::jsonb,
  '{"text":"notpresent %"}'::jsonb,
  '{"text":"Ωmega sharedneedle"}'::jsonb,
  '{"text":"ＳＨＡＲＥＤＮＥＥＤＬＥ"}'::jsonb,
  '{"text":"hiddenfourth sharedneedle"}'::jsonb
 ];
begin
 perform set_config('request.jwt.claim.sub',a::text,false);
 first:=test.query_edge_paper('2412.03401','ÉCOLE 100% under_score slash'||chr(92)||'path',
  '{"authors":["First","Second","Third","HiddenFourth Ωmega"],"abstract":"sharedneedle","categories":["cs.LG"]}');
 second:=test.query_edge_paper('2412.03402','École second match','{"abstract":"sharedneedle"}');
 perform public.v2_set_item_tags(gen_random_uuid(),(second->>'document_id')::uuid,array['Needle tag'],array[]::text[],1);
 first_id:='item:'||(first->>'id'); second_id:='item:'||(second->>'id'); both_ids:=array[first_id,second_id];
 for n in 1..48 loop
  perform test.query_edge_paper('2412.'||lpad((3410+n)::text,5,'0'),'Unrelated filler '||n);
 end loop;
 sentinel:=test.query_edge_paper('2412.03499','Unrelated cutoff sentinel');
 perform public.v2_set_library_item(gen_random_uuid(),(sentinel->>'document_id')::uuid,false,1);
 for stage in 0..5 loop
  if stage=1 then
   perform public.v2_set_library_item(gen_random_uuid(),(sentinel->>'document_id')::uuid,true,2,(sentinel->>'approval_id')::uuid);
  elsif stage=2 then
   perform public.v2_set_item_archived(gen_random_uuid(),(sentinel->>'document_id')::uuid,true,3);
  elsif stage=3 then
   perform public.v2_set_item_archived(gen_random_uuid(),(second->>'document_id')::uuid,true,2);
  elsif stage=4 then
   perform public.v2_set_library_item(gen_random_uuid(),(sentinel->>'document_id')::uuid,false,4);
  elsif stage=5 then
   perform public.v2_set_item_archived(gen_random_uuid(),(second->>'document_id')::uuid,false,3);
  end if;
  visible_count:=case when stage in (1,2,3) then 51 else 50 end;
  active_count:=case when stage=1 then 51 when stage in (3,4) then 49 else 50 end;
  perform test.assert((select count(*)=visible_count and count(*) filter(where not archived)=active_count
   from app_private.library_query_entries where account_id=a and visible),
   'cutoff fixture proves all-visible versus selected-active counts at stage '||stage);
  if old_cursor is not null then
   perform test.reject(format('select public.v4_library_query(%L,%L,1)',
    '{"text":"sharedneedle","archive":"all","sort":"recent","direction":"asc"}',old_cursor),
    'library_query_restart_required');
  end if;
  for query_index in 1..cardinality(queries) loop
   q:=queries[query_index]||'{"archive":"all","sort":"recent","direction":"asc"}'::jsonb;
   expected:=case when query_index in (1,7,12) then both_ids
    when query_index in (5,8) then array[second_id]
    when query_index=10 then array[]::text[] else array[first_id] end;
   actual:=test.query_edge_ids(q);
   perform test.assert(actual=expected,'search strategy parity at stage '||stage||', case '||query_index);
  end loop;
  actual:=test.query_edge_ids('{"text":"sharedneedle","sort":"recent","direction":"asc"}');
  perform test.assert(actual=case when stage in (3,4) then array[first_id] else both_ids end,
   'active search matches after archive/visibility transition at stage '||stage);
  actual:=test.query_edge_ids('{"text":"sharedneedle","archive":"archived","sort":"recent","direction":"asc"}');
  perform test.assert(actual=case when stage in (3,4) then array[second_id] else array[]::text[] end,
   'archived search matches while cutoff still counts all visible rows at stage '||stage);
  old_cursor:=public.v4_library_query('{"text":"sharedneedle","archive":"all","sort":"recent","direction":"asc"}',null,1)->'next_cursor';
  perform test.assert(old_cursor<>'null'::jsonb,'strategy transition keeps a real saved continuation');
 end loop;
end $$;

-- Canonical full-title continuation: three titles share all 64 prefix
-- characters but differ afterward. Two item IDs also name unlinked imports.
-- A separate prefix and two missing-metadata rows exercise every boundary of
-- the coarse ASC title guard; DESC keeps missing titles last too.
insert into auth.users values('33000000-0000-0000-0000-000000000008');
do $$ declare a uuid:='33000000-0000-0000-0000-000000000008'; first jsonb; middle jsonb; last jsonb; before_prefix jsonb;
 row jsonb; after_begin jsonb; observed bigint; expected_asc text[]; expected_desc text[];
 missing1 uuid:='33080000-0000-0000-0000-000000000001'; missing2 uuid:='33080000-0000-0000-0000-000000000002';
begin
 perform set_config('request.jwt.claim.sub',a::text,false);
 first:=test.query_edge_paper('2412.03501',repeat('λ',64)||' a');
 middle:=test.query_edge_paper('2412.03502',repeat('λ',64)||' b');
 last:=test.query_edge_paper('2412.03503',repeat('λ',64)||' z');
 before_prefix:=test.query_edge_paper('2412.03504','A different prefix');
 for row in select value from jsonb_array_elements(jsonb_build_array(first,last)) loop
  select last_seq into strict observed from app_private.library_sync_state where account_id=a;
  after_begin:=public.v2_begin_import((row->>'id')::uuid,row->>'source_id',observed,1);
  perform public.worker_checkpoint_import(a,(row->>'id')::uuid,(after_begin->'entry'->>'state_seq')::bigint,1,'acquiring',(row->>'metadata_id')::uuid);
 end loop;
 select last_seq into strict observed from app_private.library_sync_state where account_id=a;
 perform public.v2_begin_import(missing1,'2412.03505',observed,1);
 select last_seq into strict observed from app_private.library_sync_state where account_id=a;
 perform public.v2_begin_import(missing2,'2412.03506',observed,1);
 expected_asc:=array['item:'||(before_prefix->>'id'),'import:'||(first->>'id'),'item:'||(first->>'id'),
  'item:'||(middle->>'id'),'import:'||(last->>'id'),'item:'||(last->>'id'),'import:'||missing1,'import:'||missing2];
 expected_desc:=array['item:'||(last->>'id'),'import:'||(last->>'id'),'item:'||(middle->>'id'),
  'item:'||(first->>'id'),'import:'||(first->>'id'),'item:'||(before_prefix->>'id'),'import:'||missing2,'import:'||missing1];
 perform test.assert((select count(distinct title_prefix)=1 from app_private.library_query_entries
  where account_id=a and metadata_id in ((first->>'metadata_id')::uuid,(middle->>'metadata_id')::uuid,(last->>'metadata_id')::uuid)),
  'full-title fixture genuinely collides at every indexed prefix character');
 perform test.assert(test.query_edge_ids('{"sort":"title","direction":"asc"}')=expected_asc,
  'ASC coarse prefix guard preserves full-title order, cross-kind ties and missing-title continuations');
 perform test.assert(test.query_edge_ids('{"sort":"title","direction":"desc"}')=expected_desc,
  'DESC full-title order preserves cross-kind ties and keeps missing-title continuations last');
end $$;

-- Canonical coalescing journey, including different source kinds. A web alias
-- may resolve to an existing arXiv-pinned PRIVATE copy of the same bytes. Remove
-- before resolution -> visible conflict mapping; restore -> both retained rows
-- are visible, but the linked item must win BEFORE archive/tag/source filters.
-- Only the verified synthetic PDF/approval setup is privileged fixture data.
do $$ declare a uuid:='33000000-0000-0000-0000-000000000004'; d uuid:=gen_random_uuid(); o uuid:=gen_random_uuid();
 arxiv_meta uuid; web_meta uuid; arxiv_approval uuid; web_approval uuid; pipeline app_private.pipeline_papers;
 intent uuid:=gen_random_uuid(); item uuid; entry jsonb; result jsonb;
begin
 perform set_config('request.jwt.claim.sub',a::text,false);
 arxiv_meta:=public.worker_record_arxiv_metadata('2412.03302',1,
  '{"title":"Canonical private member","authors":[],"categories":["cs.LG"]}');
 web_meta:=app_private.record_web_metadata('openalex:W3302001',
  '{"title":"Web alias","authors":[],"categories":["cs.LG"]}',null);
 insert into app_private.documents(id,sha256,scope,owner_id,byte_count,page_count)
  values(d,sha256(convert_to(d::text,'UTF8')),'owner_private',a,1000,2);
 insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
  values(o,'paper-assets','test/query-edges/private/'||d||'.pdf',d,'verified',sha256(convert_to(d::text,'UTF8')),1000,'application/pdf',now());
 pipeline:=jsonb_populate_record(null::app_private.pipeline_papers,jsonb_build_object('owner_id',a,'metadata_id',arxiv_meta,
  'license_uri','https://arxiv.org/licenses/nonexclusive-distrib/1.0/'));
 arxiv_approval:=app_private.approve_private_asset(pipeline,d,o);
 pipeline:=jsonb_populate_record(null::app_private.pipeline_papers,jsonb_build_object('owner_id',a,'metadata_id',web_meta,
  'license_uri','https://papers.example.org/alias','landing_url','https://papers.example.org/alias',
  'pdf_urls',jsonb_build_array('https://papers.example.org/alias.pdf')));
 web_approval:=app_private.approve_private_asset(pipeline,d,o);
 entry:=public.v2_set_library_item(gen_random_uuid(),d,true,0,arxiv_approval)->'entry'; item:=(entry->>'id')::uuid;
 perform public.v2_begin_web_import(intent,'openalex:W3302001',1);
 perform public.v2_set_library_item(gen_random_uuid(),d,false,1);
 entry:=public.worker_resolve_import(a,intent,2,1,web_approval);
 perform test.assert(entry->>'phase'='membership_conflict' and entry->>'visible'='true' and entry->>'library_item_id'=item::text,
  'canonical resolution creates a visible alias linked to the removed item');
 perform public.v2_set_library_item(gen_random_uuid(),d,true,2,arxiv_approval);
 perform public.v2_set_item_tags(gen_random_uuid(),d,array['Canonical only'],array[]::text[],3);
 perform test.assert((select count(*)=2 from app_private.library_query_entries where account_id=a and visible),
  'coalescing fixture actually retains two visible rows');
 perform test.assert((select source='web' and effective_tags=array['Machine learning'] from app_private.library_query_entries where account_id=a and kind='import' and id=intent),
  'alias independently matches the source/tag filters excluded by its linked item');
 result:=public.v4_library_query();
 perform test.assert(jsonb_array_length(result->'rows')=1 and result->'rows'->0->'state'->>'id'=item::text,'visible item wins over its alias');
 perform test.assert(public.v4_library_query('{"source":"web"}')->'rows'='[]'::jsonb,'source filtering cannot resurrect the coalesced alias');
 perform test.assert(public.v4_library_query('{"tag":"Machine learning"}')->'rows'='[]'::jsonb,'tag filtering cannot resurrect the coalesced alias');
 perform test.assert(public.v4_library_query('{"tag":"Canonical only"}')->'rows'->0->'state'->>'id'=item::text,'matching item tag returns the canonical item');
 perform public.v2_set_item_archived(gen_random_uuid(),d,true,4);
 perform test.assert(public.v4_library_query()->'rows'='[]'::jsonb,'active filtering cannot resurrect alias of an archived visible item');
 result:=public.v4_library_query('{"archive":"archived"}');
 perform test.assert(jsonb_array_length(result->'rows')=1 and result->'rows'->0->'state'->>'id'=item::text,'archived query returns canonical item only');
 result:=public.v4_library_query('{"archive":"all"}');
 perform test.assert(jsonb_array_length(result->'rows')=1 and result->'rows'->0->'state'->>'id'=item::text,'all archive states still coalesce');
 perform test.assert(public.v4_library_query('{"archive":"all","source":"web","tag":"Machine learning"}')->'rows'='[]'::jsonb,
  'combined filters cannot resurrect alias');
 -- Positive control: coalescing applies only while the linked item is visible.
 perform public.v2_set_library_item(gen_random_uuid(),d,false,5);
 result:=public.v4_library_query('{"source":"web","tag":"Machine learning"}');
 perform test.assert(jsonb_array_length(result->'rows')=1 and result->'rows'->0->'state'->>'id'=intent::text,
  'alias legitimately returns once its linked item is removed');
end $$;

-- Exact tag identity uses simple case folding; free-text search uses NFKC.
-- These two real library items must stay distinct through the public API.
select set_config('request.jwt.claim.sub','33000000-0000-0000-0000-000000000005',false);
select test.query_edge_paper('2412.03303','ASCII label paper') as ascii_paper \gset
select test.query_edge_paper('2412.03304','Wide label paper') as wide_paper \gset
set role authenticated;
select public.v2_set_item_tags(gen_random_uuid(),(:'ascii_paper'::jsonb->>'document_id')::uuid,array['ML'],array[]::text[],1);
select public.v2_set_item_tags(gen_random_uuid(),(:'wide_paper'::jsonb->>'document_id')::uuid,array['ＭＬ'],array[]::text[],1);
select public.v4_library_query('{"tag":"ml"}') as ascii_match \gset
select public.v4_library_query('{"tag":"ｍｌ"}') as wide_match \gset
select test.assert(jsonb_array_length(:'ascii_match'::jsonb->'rows')=1
 and :'ascii_match'::jsonb->'rows'->0->'state'->>'id'=:'ascii_paper'::jsonb->>'id'
 and :'ascii_match'::jsonb->'rows'->0->'summary'->'tags'='["ML"]'::jsonb,'ASCII exact tag filter selects only ASCII label');
select test.assert(jsonb_array_length(:'wide_match'::jsonb->'rows')=1
 and :'wide_match'::jsonb->'rows'->0->'state'->>'id'=:'wide_paper'::jsonb->>'id'
 and :'wide_match'::jsonb->'rows'->0->'summary'->'tags'='["ＭＬ"]'::jsonb,'fullwidth exact tag filter selects only fullwidth label');
select test.assert(jsonb_array_length(public.v4_library_query('{"text":"ml"}')->'rows')=2
 and jsonb_array_length(public.v4_library_query('{"text":"ＭＬ"}')->'rows')=2,'NFKC text search intentionally matches both tag spellings');
reset role;

-- Short/non-trigram terms are still literal and account-scoped. Populate an
-- unrelated catalog record through the normal library fixture, then prove
-- neither its Unicode nor its short ASCII/emoji terms leak across accounts.
select set_config('request.jwt.claim.sub','33000000-0000-0000-0000-000000000001',false);
select test.query_edge_paper('2412.03305','Ω z9 🦊 outside-account') as other_paper \gset
set role authenticated;
select test.assert(jsonb_array_length(public.v4_library_query('{"text":"ω"}')->'rows')=1
 and jsonb_array_length(public.v4_library_query('{"text":"z9"}')->'rows')=1
 and jsonb_array_length(public.v4_library_query('{"text":"🦊"}')->'rows')=1,'short and non-alphanumeric terms match the owned paper');
select set_config('request.jwt.claim.sub','33000000-0000-0000-0000-000000000005',false);
select test.assert(public.v4_library_query('{"text":"ω"}')->'rows'='[]'::jsonb
 and public.v4_library_query('{"text":"z9"}')->'rows'='[]'::jsonb
 and public.v4_library_query('{"text":"🦊"}')->'rows'='[]'::jsonb,'unrelated catalog matches do not enter another account query');
reset role;
select test.assert(app_private.library_query_category_tags('["unknown","cs.CV","eess.IV","stat.ML","cs.LG","cs.CL","cs.RO"]')
 =array['Computer vision','Machine learning','Natural language processing'],'category fallback preserves first occurrence, deduplicates and stops at three');

-- A future interrupted cleanup can leave only derived state after the login
-- and canonical personal rows are gone. Trusted fixture intentionally creates
-- that state, without disabling FKs or triggers. The service diagnostics must
-- find it and the existing repeatable deletion must clear both projections.
insert into auth.users values('33000000-0000-0000-0000-000000000006');
select app_private.library_v4_project_entry('33000000-0000-0000-0000-000000000006',
 entry||jsonb_build_object('id','33060000-0000-0000-0000-000000000001','created_seq',1,'state_seq',1))
 from query_edge_templates where kind='item';
update app_private.accounts set closed_at=now() where id='33000000-0000-0000-0000-000000000006';
delete from auth.users where id='33000000-0000-0000-0000-000000000006';
select test.assert(app_private.worker_account_deletion_status('33000000-0000-0000-0000-000000000006')->>'personal_rows'='0'
 and not ('33000000-0000-0000-0000-000000000006'=any(app_private.worker_account_deletions_pending(20))),
 'legacy diagnostics genuinely miss a derived-only orphan');
set role anon;
select test.reject($q$select public.worker_account_deletion_status('33000000-0000-0000-0000-000000000006')$q$,'permission denied');
select test.reject('select public.worker_account_deletions_pending()','permission denied');
reset role;
set role authenticated;
select test.reject($q$select public.worker_account_deletion_status('33000000-0000-0000-0000-000000000006')$q$,'permission denied');
select test.reject('select public.worker_account_deletions_pending()','permission denied');
reset role;
set role service_role;
select test.reject($q$select app_private.worker_account_deletion_status('33000000-0000-0000-0000-000000000006')$q$,'permission denied');
select test.reject('select app_private.worker_account_deletions_pending()','permission denied');
select test.assert(public.worker_account_deletion_status('33000000-0000-0000-0000-000000000006')->>'personal_rows'='2'
 and public.worker_account_deletion_status('33000000-0000-0000-0000-000000000006')->>'library_derived_rows'='2',
 'service diagnostics count compact and query orphan rows');
select test.assert(public.worker_account_deletions_pending(1)=array['33000000-0000-0000-0000-000000000006'::uuid],
 'service sweep discovers derived-only orphan after login removal');
select public.worker_delete_account_begin('33000000-0000-0000-0000-000000000006');
select public.worker_delete_account_begin('33000000-0000-0000-0000-000000000006');
select test.assert(public.worker_account_deletion_status('33000000-0000-0000-0000-000000000006')->>'personal_rows'='0'
 and public.worker_account_deletion_status('33000000-0000-0000-0000-000000000006')->>'library_derived_rows'='0',
 'repeatable cleanup clears derived-only personal state');
select test.assert(not ('33000000-0000-0000-0000-000000000006'=any(public.worker_account_deletions_pending(20))),
 'cleaned orphan is no longer pending');
reset role;
select test.assert(not exists(select 1 from app_private.library_sync_state where account_id='33000000-0000-0000-0000-000000000006'),
 'derived cleanup removes its sync parent');
select test.assert((select count(*)=80 from app_private.library_v4_entries where account_id='33000000-0000-0000-0000-000000000002')
 and (select count(*)=80 from app_private.library_query_entries where account_id='33000000-0000-0000-0000-000000000002'),
 'derived cleanup preserves bystander projections');
rollback;
