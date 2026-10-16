-- Listen on a legacy arXiv item from the text prepared on the device (migration 081; DATA_HANDLING_AND_COSTS.md
-- "Server paper copies: retired"): with the server copy retired the item pins no server text; a device source named by
-- the library item's own id pins only that item's exact arXiv source and revision (a wrong revision or source, or a
-- removed item, pins nothing); the paper lookup by the item finds the job and then the ready episode; the episode and
-- the `mine` list name the item's document, as clients identify a legacy paper. Another account's item id is only a
-- name to them (066's behaviour: their own text, their own episode, never the other account's document). A source
-- membership's device episode is unchanged. Synthetic local SQL; nothing leaves the machine. Runs after every
-- migration (scripts/test-database.py).
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

\set O '81000000-0000-0000-0000-00000000000f'
\set A '81000000-0000-0000-0000-00000000000a'
\set B '81000000-0000-0000-0000-00000000000b'
insert into auth.users(id) values(:'O'),(:'A'),(:'B');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
select public.worker_grant_credits(:'A','adjustment','legacy-a',5000,now()-interval '1 day',null,'Legacy device source fixture');
select public.worker_grant_credits(:'B','adjustment','legacy-b',5000,now()-interval '1 day',null,'Legacy device source fixture');
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),'{"seed_enabled":true,"generation_enabled":true,"catalog_enabled":true,"delivery_enabled":true}','Legacy test: switches on');
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),
 '{"profile_id":"podcast-5min-v1","profile_version":5,"allowed_profiles":["podcast-short-v1:5","podcast-short-v1:3","podcast-5min-v1:5","podcast-5min-v1:3","podcast-10min-v1:5","podcast-10min-v1:3","podcast-20min-v1:5","podcast-20min-v1:3"]}',
 'Legacy test: every length');

-- A converted arXiv paper as the old pipeline left it (original, Mathpix text, reader bundle), in A's library.
create or replace function test.legacy_paper(tag text,source_id text) returns jsonb language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid(); appr uuid:=gen_random_uuid();
 run uuid:=gen_random_uuid(); art uuid:=gen_random_uuid(); orig uuid:=gen_random_uuid(); rawm uuid:=gen_random_uuid(); txt uuid:=gen_random_uuid();
 readm uuid:=gen_random_uuid(); raw_digest text:=encode(sha256(convert_to(tag||'-raw','UTF8')),'hex');
 reader_digest text:=encode(sha256(convert_to(tag||'-reader','UTF8')),'hex');
 metadata jsonb:=jsonb_build_object('title','Legacy fixture '||tag,'authors',jsonb_build_array('L. Fixture'),'published_at','2025-01-02','categories',jsonb_build_array('cs.LG'));
begin
 insert into app_private.publications(id,title) values(pub,'Legacy fixture '||tag);
 insert into app_private.publication_versions(id,publication_id,source,revision) values(ver,pub,'arxiv','2');
 insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
  values(doc,sha256(convert_to(tag||'-document','UTF8')),'shared_catalog','{"license":"CC-BY-4.0"}',1000,2);
 insert into app_private.version_documents values(ver,doc);
 insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values
  (orig,'paper-assets','originals/'||encode(sha256(convert_to(tag||'-original','UTF8')),'hex')||'.pdf',doc,'verified',sha256(convert_to(tag||'-original','UTF8')),1000,'application/pdf',now()),
  (rawm,'paper-assets','raw/'||raw_digest||'/manifest.json',doc,'verified',decode(raw_digest,'hex'),100,'application/json',now()),
  (txt,'paper-assets','raw/'||raw_digest||'/standalone.mmd',doc,'verified',sha256(convert_to(tag||'-text','UTF8')),5000,'text/plain',now()),
  (readm,'paper-assets','reader/'||reader_digest||'/manifest.json',doc,'verified',decode(reader_digest,'hex'),100,'application/json',now());
 insert into app_private.paper_asset_manifest_members values(rawm,txt,'standalone.mmd');
 insert into app_private.catalog_metadata(id,version_id,source_id,source_revision,metadata,metadata_sha256)
  values(meta,ver,source_id,2,metadata,sha256(convert_to(metadata::text,'UTF8')));
 insert into app_private.catalog_asset_approvals(id,version_id,document_id,metadata_id,original_object_id,license_uri,policy_version,evidence)
  values(appr,ver,doc,meta,orig,'https://creativecommons.org/licenses/by/4.0/','arxiv-reuse-v1','{}');
 insert into app_private.ocr_runs(id,document_id,provider,options_sha256,raw_bundle_object_id) values(run,doc,'mathpix',sha256(convert_to(tag||'-options','UTF8')),rawm);
 insert into app_private.render_artifacts(id,ocr_run_id,renderer_version,manifest_object_id) values(art,run,'timestep-mathpix-mathml-v1',readm);
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 perform 1 from app_private.documents where id=doc for update;
 perform app_private.mark_paper_availability(orig,'available');
 perform app_private.mark_paper_availability(readm,'available');
 return jsonb_build_object('approval',appr,'document',doc,'artifact',art);
end $$;
select test.legacy_paper('one','2501.01234') as fixture \gset
select :'fixture'::jsonb->>'document' as doc \gset
insert into app_private.library_items(account_id,document_id,artifact_id,approval_id)
 values(:'A',:'doc'::uuid,(:'fixture'::jsonb->>'artifact')::uuid,(:'fixture'::jsonb->>'approval')::uuid) returning id as item \gset
select test.assert(app_private.podcast_item_pin(:'A',:'item') is not null,'fixture: before retirement Listen pins the server text');

-- The server copies are retired (migration 080): the item pins nothing, and a quote without the device text says so.
select public.worker_paper_copies_retire(1000);
select public.worker_paper_copies_project(100);
select test.assert(app_private.podcast_item_pin(:'A',:'item') is null,'after retirement no server text is pinned');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject(format('select public.v1_podcast_quote(%L,%L,%L,%L)',:'item','81000000-0000-0000-00b0-0000000000f0','podcast-5min-v1','deepseek'),'source_unavailable');
reset role;

-- The device prepared the item's official HTML (2501.01234v2) and sent its text (podcast?action=source).
select encode(sha256(convert_to('¶1 A legacy paper prepared on this device.','UTF8')),'hex') as digest \gset
select public.worker_podcast_source_register(:'A',:'digest',43,'podcast-sources/'||:'A'||'/'||:'digest'||'/81000000-0000-4000-8000-000000000001.txt');
select jsonb_build_object('source','arxiv','source_id','2501.01234','revision',2,'manifest_sha256',repeat('b',64),'text_sha256',:'digest',
 'title','Legacy fixture one','authors',jsonb_build_array('L. Fixture')) as device \gset

-- The pin: the item's own exact source and revision only.
select test.assert((app_private.podcast_device_pin(:'A',:'device'::jsonb||jsonb_build_object('membership_id',:'item'))->>'membership_id')=:'item','the item''s exact source pins its device text');
select test.assert(app_private.podcast_device_pin(:'A',:'device'::jsonb||jsonb_build_object('membership_id',:'item','revision',1)) is null,'another revision pins nothing');
select test.assert(app_private.podcast_device_pin(:'A',:'device'::jsonb||jsonb_build_object('membership_id',:'item','source_id','2501.09999')) is null,'another paper pins nothing');
savepoint removed;
update app_private.library_items set removed_at=now() where id=:'item';
select test.assert(app_private.podcast_device_pin(:'A',:'device'::jsonb||jsonb_build_object('membership_id',:'item')) is null,'a removed item pins nothing');
rollback to savepoint removed;

-- The quote and start as the reader: item_id is the library item, with the device descriptor.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject(format('select public.v1_podcast_quote(%L,%L,%L,%L,%L::jsonb)',:'item','81000000-0000-0000-00b0-0000000000f1','podcast-5min-v1','deepseek',
 (:'device'::jsonb||'{"revision":1}'::jsonb)::text),'source_unavailable');
\set Q1 '81000000-0000-0000-00b0-000000000001'
select public.v1_podcast_quote(:'item',:'Q1','podcast-5min-v1','deepseek',:'device'::jsonb) as quoted \gset
select test.assert((:'quoted'::jsonb->'quote'->>'profile')='podcast-5min-v1','a legacy item quotes from its device text');
select public.v1_podcast_start((:'quoted'::jsonb->'quote'->>'id')::uuid,:'Q1','podcast-private-v2') as started \gset
select test.assert((:'started'::jsonb->'job'->>'state')='queued','the start queues a private job');
select public.v1_podcast_paper(:'item') as lookup \gset
select test.assert((:'lookup'::jsonb->'job'->>'request_id')=:'Q1' and :'lookup'::jsonb->'episode'='null'::jsonb and :'lookup'::jsonb->'episodes'='[]'::jsonb,
 'the paper lookup by the library item finds the running job');
select public.v1_podcast_catalog(null,20)->'mine' as mine \gset
select test.assert((:'mine'::jsonb->'requests'->0->>'request_id')=:'Q1' and (:'mine'::jsonb->'requests'->0->>'document_id')=:'doc'
 and (:'mine'::jsonb->'requests'->0->>'title')='Legacy fixture one','Listen''s own list names the item''s document');
reset role;
select test.assert((select count(*)=1 from app_private.podcast_device_sources where owner_id=:'A' and membership_id=:'item' and source_id='2501.01234' and revision=2),
 'one device source row named by the library item');

-- The episode is made (published here directly, synthetic): the item's lookup and Listen's list show it on the document.
select q.job_id as job1,j.episode_id as ep1 from app_private.podcast_requests q join app_private.podcast_jobs j on j.id=q.job_id where q.account_id=:'A' and q.request_id=:'Q1' \gset
insert into app_private.podcast_scripts(job_id,episode_id,script_sha256,checker_version,decision,segments,chapters)
 values(:'job1',:'ep1',sha256('s81'),'podcast-checker-v6','accepted',20,4) returning id as script1 \gset
insert into app_private.podcast_releases(episode_id,job_id,script_id,scope,owner_id,origin,identity,manifest_sha256,duration_ms,state,published_seq,published_at)
 values(:'ep1',:'job1',:'script1','private',:'A','generated','{}',sha256('m81'),301000,'ready',nextval('app_private.podcast_publication_seq'),now()) returning id as rel1 \gset
update app_private.podcast_jobs set state='ready',finished_at=clock_timestamp() where id=:'job1';
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v1_podcast_paper(:'item') as lookup \gset
select test.assert((:'lookup'::jsonb->'episode'->>'release_id')=:'rel1' and (:'lookup'::jsonb->'episode'->>'document_id')=:'doc'
 and jsonb_array_length(:'lookup'::jsonb->'episodes')=1 and (:'lookup'::jsonb->'episodes'->0->>'document_id')=:'doc'
 and (:'lookup'::jsonb->'episode'->'source'->>'arxiv_id')='2501.01234' and :'lookup'::jsonb->'job'='null'::jsonb,
 'the ready episode is the item''s, on its document');
select public.v1_podcast_catalog(null,20)->'mine' as mine \gset
select test.assert(jsonb_array_length(:'mine'::jsonb->'episodes')=1 and (:'mine'::jsonb->'episodes'->0->>'release_id')=:'rel1'
 and (:'mine'::jsonb->'episodes'->0->>'document_id')=:'doc' and (:'mine'::jsonb->'episodes'->0->>'request_id')=:'Q1','Listen lists it on the document');
-- The made episode's text copy was deleted (076): asking again sends the text again, and the same length reuses it.
reset role;
select test.assert(app_private.podcast_device_pin(:'A',:'device'::jsonb||jsonb_build_object('membership_id',:'item')) is null,'the used text is gone');
select public.worker_podcast_source_register(:'A',:'digest',43,'podcast-sources/'||:'A'||'/'||:'digest'||'/81000000-0000-4000-8000-000000000003.txt');
set role authenticated;
select test.assert((public.v1_podcast_quote(:'item','81000000-0000-0000-00b0-000000000002','podcast-5min-v1','deepseek',:'device'::jsonb)->'reuse'->>'release_id')=:'rel1',
 'asking again reuses the episode');

-- A source membership (a paper added since the HTML-first reader) is unchanged: named by its membership id.
\set M '81000000-0000-4000-8000-0000000000aa'
\set Q3 '81000000-0000-0000-00b0-000000000003'
select public.v1_podcast_start((public.v1_podcast_quote(:'M',:'Q3','podcast-short-v1','deepseek',:'device'::jsonb||'{"source_id":"2610.16334","revision":1}'::jsonb)->'quote'->>'id')::uuid,
 :'Q3','podcast-private-v2');
select test.assert((public.v1_podcast_paper(:'M')->'job'->>'request_id')=:'Q3','a membership''s lookup finds its job');
select public.v1_podcast_catalog(null,20)->'mine' as mine \gset
select test.assert((:'mine'::jsonb->'requests'->0->>'request_id')=:'Q3' and (:'mine'::jsonb->'requests'->0->>'document_id')=:'M','a membership''s request keeps its membership id');
select test.assert(public.v1_podcast_paper(:'item')->'job'='null'::jsonb,'the legacy item does not see the membership''s job');

-- Another account: A's item id is not B's library item, so it is only a name (066): B's own text makes B's own episode,
-- which never names A's document, and A's lookup never sees it.
reset role;
select public.worker_podcast_source_register(:'B',:'digest',43,'podcast-sources/'||:'B'||'/'||:'digest'||'/81000000-0000-4000-8000-000000000002.txt');
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
\set Q4 '81000000-0000-0000-00b0-000000000004'
select public.v1_podcast_start((public.v1_podcast_quote(:'item',:'Q4','podcast-5min-v1','deepseek',:'device'::jsonb)->'quote'->>'id')::uuid,:'Q4','podcast-private-v2');
select public.v1_podcast_catalog(null,20)->'mine' as mine \gset
select test.assert((:'mine'::jsonb->'requests'->0->>'request_id')=:'Q4' and (:'mine'::jsonb->'requests'->0->>'document_id')=:'item'
 and position(:'doc' in :'mine')=0,'for B it names the id it was given, never A''s document');
select test.assert((public.v1_podcast_paper(:'item')->'job'->>'request_id')=:'Q4','B finds B''s own job by that id');
select set_config('request.jwt.claim.sub',:'A',false);
select public.v1_podcast_paper(:'item') as lookup \gset
select test.assert(:'lookup'::jsonb->'job'='null'::jsonb and (:'lookup'::jsonb->'episode'->>'release_id')=:'rel1','A sees only A''s episode');
reset role;

-- Helpers stay private.
select test.assert(not has_function_privilege('authenticated','app_private.podcast_device_paper(uuid,uuid)','EXECUTE')
 and not has_function_privilege('authenticated','app_private.podcast_device_pin(uuid,jsonb)','EXECUTE')
 and has_function_privilege('authenticated','public.v1_podcast_paper(uuid)','EXECUTE'),'helpers private; the lookup is the reader''s');
rollback;
