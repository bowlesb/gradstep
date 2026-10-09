-- Web imports (migration 019): identity, worker flow, private provenance, and
-- the v2 readers (installed builds) never seeing a web entry.
begin;
insert into auth.users values('19000000-0000-0000-0000-00000000000a');
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits('19000000-0000-0000-0000-00000000000a','adjustment','web-test-a',100,now()-interval '1 day',null,'Web test grant');
select public.worker_set_pipeline_enabled(true);
reset role;

-- Customers name an OpenAlex work, never a URL; the two begin RPCs keep their kinds apart.
set role anon;
select test.reject('select public.v3_library_page()','permission denied');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','19000000-0000-0000-0000-00000000000a',false);
select test.reject($q$select public.worker_pipeline_web_metadata(gen_random_uuid(),gen_random_uuid(),1,'{}',null,'{https://example.org/a.pdf}',null)$q$,'permission denied');
select test.reject($q$select public.v2_begin_web_import('19000000-0000-0000-0000-0000000000a0','2305.18290',0)$q$,'invalid_web_source_id');
select test.reject($q$select public.v2_begin_web_import('19000000-0000-0000-0000-0000000000a0','https://example.org/paper.pdf',0)$q$,'invalid_web_source_id');
select test.reject($q$select public.v2_begin_import('19000000-0000-0000-0000-0000000000a0','openalex:W1000000001',0)$q$,'invalid_arxiv_id');
select test.reject($q$select public.v2_begin_web_import('19000000-0000-0000-0000-0000000000a0','openalex:W0001000000001',0)$q$,'invalid_web_source_id');
select public.v2_begin_web_import('19000000-0000-0000-0000-0000000000a1',' openalex:w1000000001 ',0) as began \gset
select test.assert(:'began'::jsonb->'entry'->>'source'='web' and :'began'::jsonb->'entry'->>'source_id'='openalex:W1000000001'
 and :'began'::jsonb->'entry'->>'source_url'='https://openalex.org/works/W1000000001' and :'began'::jsonb->'entry'->'requested_revision'='null'::jsonb,'web import entry');
select test.assert((public.v2_begin_web_import('19000000-0000-0000-0000-0000000000a1','openalex:W1000000001',0)->>'replayed')::boolean,'web import replays');
select public.v2_begin_import('19000000-0000-0000-0000-0000000000a2','2006.11239',1);
select public.v2_begin_web_import('19000000-0000-0000-0000-0000000000a3','openalex:W1000000002',2);
select public.v2_begin_import('19000000-0000-0000-0000-0000000000a4','2305.18290',3);

-- Sequences 1 and 3 are web, 2 and 4 arXiv.
select test.assert((select count(*) from jsonb_array_elements(public.v2_library_page()->'entries') e where e->>'source'<>'arxiv')=0
 and jsonb_array_length(public.v2_library_page()->'entries')=2,'v2 baseline shows only the arXiv imports');
select test.assert((public.v2_library_page(null,1)->>'has_more')::boolean and not (public.v2_library_page(public.v2_library_page(null,1)->'next_cursor',1)->>'has_more')::boolean,
 'v2 baseline pages over hidden entries');
select test.assert(jsonb_array_length(public.v3_library_page()->'entries')=4,'v3 baseline shows everything');
select public.v2_library_changes(0,null,1) as page1 \gset
select test.assert(:'page1'::jsonb->'changes'->0->>'seq'='2' and (:'page1'::jsonb->>'has_more')::boolean and :'page1'::jsonb->>'next_cursor'='2','v2 changes skip a hidden batch');
select public.v2_library_changes(2,null,1) as page2 \gset
select test.assert(:'page2'::jsonb->'changes'->0->>'seq'='4' and not (:'page2'::jsonb->>'has_more')::boolean and :'page2'::jsonb->>'next_cursor'='4','v2 changes end at the boundary');
select public.v2_library_changes(3,null,100) as tail \gset
select test.assert(jsonb_array_length(:'tail'::jsonb->'changes')=1,'v2 tail');
select test.assert(jsonb_array_length(public.v3_library_changes(0)->'changes')=4,'v3 changes include web batches');
-- A tail of hidden batches only: nothing to show, and the cursor still advances.
select public.v2_cancel_import('19000000-0000-0000-0000-0000000000a5','19000000-0000-0000-0000-0000000000a3',1);
select public.v2_library_changes(4) as hidden_tail \gset
select test.assert(jsonb_array_length(:'hidden_tail'::jsonb->'changes')=0 and not (:'hidden_tail'::jsonb->>'has_more')::boolean
 and :'hidden_tail'::jsonb->>'next_cursor'=:'hidden_tail'::jsonb->>'through' and (:'hidden_tail'::jsonb->>'through')::bigint=5,'hidden-only tail advances the cursor');
reset role;

-- Worker: metadata from OpenAlex, private split, hardened locations.
update app_private.pipeline_papers set next_attempt_at=now()+interval '1 hour' where source_id<>'openalex:W1000000001';
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'id') as shared, (:'entry'::jsonb->>'generation')::bigint as gen \gset
select test.assert(:'entry'::jsonb->>'source_kind'='web' and :'entry'::jsonb->>'stage'='metadata','claimed the web paper at metadata');
\set meta '{"title":"Deep learning","authors":["Yann LeCun","Yoshua Bengio","Geoffrey Hinton"],"abstract":null,"published_at":"2015-05-27","updated_at":null,"categories":[],"venue":"Nature"}'
select test.reject(format('select public.worker_pipeline_metadata(%L,%L,%s,1,%L,false,%L)',:'shared',:'claim',:'gen',:'meta','https://example.org/'),'invalid_arxiv_id');
select test.reject(format('select public.worker_pipeline_web_metadata(%L,%L,%s,%L,null,%L,null)',:'shared',:'claim',:'gen',:'meta',x),'invalid_pipeline_metadata')
 from unnest(array['{http://repository.example.org/a.pdf}','{https://127.0.0.1/a.pdf}','{https://repository.example.org:8443/a.pdf}',
  '{https://user@repository.example.org/a.pdf}','{https://localhost/a.pdf}',
  '{https://a.example.org/1.pdf,https://b.example.org/2.pdf,https://c.example.org/3.pdf,https://d.example.org/4.pdf}']) x;
select test.reject(format('select public.worker_pipeline_web_metadata(%L,%L,%s,%L,null,%L,null)',:'shared',:'claim',:'gen',x,'{https://repository.example.org/a.pdf}'),'invalid_catalog_metadata')
 from unnest(array['{"title":"x","authors":[],"categories":[],"doi":"10.1/x"}','{"title":"Deep\u0002 learning","authors":[],"categories":[]}',
  '{"title":"Deep learning","authors":["Yann\u0085 LeCun"],"categories":[]}']) x;
select test.reject(format('select public.worker_pipeline_web_metadata(%L,%L,%s,%L,null,%L,null)',:'shared',:'claim',:'gen',:'meta','{https://repository.example.org}'),'invalid_pipeline_metadata');
select public.worker_pipeline_web_metadata(:'shared',:'claim',:'gen',:'meta','10.1038/NATURE14539',
 '{https://repository.example.org/deep-learning.pdf,https://www.example-publisher.com/articles/nature14539.pdf}','https://doi.org/10.1038/nature14539') as recorded \gset
select test.assert(:'recorded'::jsonb->>'stage'='private_split' and :'recorded'::jsonb->>'revision'='1' and :'recorded'::jsonb->>'eligible'='false'
 and :'recorded'::jsonb->>'license_uri'='https://doi.org/10.1038/nature14539','web metadata recorded; always private');
select test.assert(public.worker_pipeline_split_private(:'shared',:'claim',:'gen')=1,'one private web paper');
select public.worker_pipeline_sync_imports(:'shared',:'claim',:'gen');
select public.worker_pipeline_release(:'shared',:'claim',:'gen');
reset role;
select test.reject($q$update app_private.pipeline_papers set eligible=true where source_id='openalex:W1000000001' and owner_id is null$q$,'pipeline_web_private');
select test.reject($q$update app_private.pipeline_papers set pdf_urls='{https://repository.example.org/a.pdf}' where source_id='2006.11239'$q$,'pipeline_web_locations');
select test.assert((select count(*) from app_private.publication_identifiers where namespace='openalex' and identifier='W1000000001')=1
 and (select count(*) from app_private.publication_identifiers where namespace='doi' and identifier='10.1038/nature14539')=1,'catalog identifiers');
select id as private from app_private.pipeline_papers where owner_id='19000000-0000-0000-0000-00000000000a' and source_id='openalex:W1000000001' \gset
select test.assert((select stage='download' and landing_url='https://doi.org/10.1038/nature14539' and cardinality(pdf_urls)=2 from app_private.pipeline_papers where id=:'private'),
 'private paper carries the PDF locations');

-- Download, conversion and resolution of the private copy.
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'generation')::bigint as gen \gset
select test.assert(:'entry'::jsonb->>'id'=:'private' and :'entry'::jsonb->'pdf_urls'->>0='https://repository.example.org/deep-learning.pdf','worker sees the locations');
select test.assert((public.worker_pipeline_admit_download(:'private',:'claim',:'gen')->>'admitted')::boolean,'admitted');
select test.assert(public.worker_pipeline_web_locations(:'private',:'claim',:'gen','{https://new-home.example.org/deep-learning.pdf}')->'pdf_urls'->>0
 ='https://new-home.example.org/deep-learning.pdf','locations refreshed before download');
select test.reject(format('select public.worker_pipeline_web_locations(%L,%L,%s,%L)',:'private',:'claim',:'gen','{http://new-home.example.org/a.pdf}'),'invalid_pipeline_metadata');
select test.assert(public.worker_pipeline_original(:'private',:'claim',:'gen',('\x'||repeat('77',32))::bytea,500000,9,
 'private/19000000-0000-0000-0000-00000000000a/originals/'||repeat('77',32)||'.pdf')->>'stage'='ocr_fund','private web original');
select test.assert(public.worker_pipeline_sync_imports(:'private',:'claim',:'gen')=1,'private paper projects its import');
reset role;
select test.assert(app_private.library_import_entry('19000000-0000-0000-0000-00000000000a','19000000-0000-0000-0000-0000000000a1')->>'phase'='acquiring'
 and app_private.library_import_entry('19000000-0000-0000-0000-00000000000a','19000000-0000-0000-0000-0000000000a1')->>'source_revision'='1'
 and app_private.library_import_entry('19000000-0000-0000-0000-00000000000a','19000000-0000-0000-0000-0000000000a1')->>'progress'='converting','import acquiring with metadata');
set role service_role;
reset role;
-- Progress is stored with the import's state: a stage change alone never alters an entry at the same state_seq.
select app_private.library_import_entry('19000000-0000-0000-0000-00000000000a','19000000-0000-0000-0000-0000000000a1') as before_fund \gset
set role service_role;
select test.assert(public.worker_pipeline_fund(:'private',:'claim',:'gen',9,('\x'||repeat('17',32))::bytea,('\x'||repeat('18',32))::bytea)->>'funding'='funded','owner funds');
reset role;
select test.assert(app_private.library_import_entry('19000000-0000-0000-0000-00000000000a','19000000-0000-0000-0000-0000000000a1')=:'before_fund'::jsonb,
 'entry unchanged until the worker projects it');
set role service_role;
select public.worker_pipeline_begin_submit(:'private',:'claim',:'gen')->>'attempt_id' as attempt \gset
select public.worker_pipeline_submitted(:'attempt','web-job-1');
select public.worker_pipeline_collected(:'private',:'claim',:'gen',9,('\x'||repeat('7a',32))::bytea,2048);
select test.assert(public.worker_pipeline_published(:'private',:'claim',:'gen',('\x'||repeat('7b',32))::bytea,2048,'timestep-mathpix-mathml-v1')->>'stage'='done','published');
select test.assert(public.worker_pipeline_sync_imports(:'private',:'claim',:'gen')=1,'web import resolved');
reset role;
select test.assert((select evidence->>'source_url'='https://doi.org/10.1038/nature14539' and evidence->'pdf_urls'->>0='https://new-home.example.org/deep-learning.pdf'
 and policy_version='owner-private-v1' from app_private.catalog_asset_approvals where id=(select approval_id from app_private.pipeline_papers where id=:'private')),'web provenance pinned');
select library_item_id as web_item from app_private.import_requests where id='19000000-0000-0000-0000-0000000000a1' \gset
select test.assert(app_private.library_item_entry('19000000-0000-0000-0000-00000000000a',:'web_item')->>'source'='web'
 and app_private.library_item_entry('19000000-0000-0000-0000-00000000000a',:'web_item')->>'source_url'='https://doi.org/10.1038/nature14539'
 and app_private.library_item_entry('19000000-0000-0000-0000-00000000000a',:'web_item')->>'scope'='owner_private','web item entry');

-- The same bytes through arXiv never resolve onto the web-pinned item.
update app_private.pipeline_papers set next_attempt_at=now() where source_id='2006.11239';
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'id') as shared2, (:'entry'::jsonb->>'generation')::bigint as gen \gset
select test.assert(:'entry'::jsonb->>'source_id'='2006.11239' and :'entry'::jsonb->>'source_kind'='arxiv','claimed the arXiv paper');
select public.worker_pipeline_metadata(:'shared2',:'claim',:'gen',2,'{"title":"Denoising Diffusion Probabilistic Models","authors":["Jonathan Ho"],"categories":["cs.LG"]}',
 false,'http://arxiv.org/licenses/nonexclusive-distrib/1.0/',jsonb_build_object('private_permission','fixture-approved'));
select public.worker_pipeline_split_private(:'shared2',:'claim',:'gen');
select public.worker_pipeline_release(:'shared2',:'claim',:'gen');
reset role;
select id as private2 from app_private.pipeline_papers where owner_id='19000000-0000-0000-0000-00000000000a' and source_id='2006.11239' \gset
update app_private.pipeline_papers set next_attempt_at=now()+interval '1 hour' where id<>:'private2';
set role service_role;
select gen_random_uuid() as claim \gset
select (public.worker_pipeline_claim(:'claim')->>'generation')::bigint as gen \gset
select test.assert(public.worker_pipeline_original(:'private2',:'claim',:'gen',('\x'||repeat('77',32))::bytea,500000,9,
 'private/19000000-0000-0000-0000-00000000000a/originals/'||repeat('77',32)||'.pdf')->>'stage'='done','identical bytes reuse the render');
select public.worker_pipeline_sync_imports(:'private2',:'claim',:'gen');
reset role;
select test.assert((select phase='membership_conflict' and library_item_id is null and document_id is null and approval_id is null
 from app_private.import_requests where id='19000000-0000-0000-0000-0000000000a2'),'arXiv import does not adopt the web item');
select test.assert((select approval_id from app_private.library_items where id=:'web_item')=(select approval_id from app_private.pipeline_papers where id=:'private'),'web pin unchanged');
set role authenticated;
select set_config('request.jwt.claim.sub','19000000-0000-0000-0000-00000000000a',false);
select test.assert(not exists(select 1 from jsonb_array_elements(public.v2_library_page()->'entries') e where e->>'source'='web' or e->>'library_item_id'=:'web_item'),
 'v2 readers see no web entry and no reference to one');
select test.assert(not exists(select 1 from jsonb_array_elements(public.v2_library_changes(0)->'changes') c, jsonb_array_elements(c->'entries') e where e->>'source'='web'),
 'v2 changes carry no web entry');
select test.assert(exists(select 1 from jsonb_array_elements(public.v3_library_page()->'entries') e where e->>'kind'='item' and e->>'source'='web'),'v3 shows the web item');
reset role;
rollback;
