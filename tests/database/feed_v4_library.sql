-- For you reads the v4 library (migration 0154; docs/architecture/PERSONALIZED_FEED.md "Interest signals"): HTML-first
-- imports (source_only, no library item) are library papers in the profile, with the catalog's or the device's record
-- and the Library's tags; a paper with both an item and an import counts once; such papers are never offered; other
-- readers' imports count toward "Added by several readers this week"; a topic may name an own tag on an import.
-- Synthetic local SQL; nothing leaves the machine.
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

\set R '15400000-0000-4000-8000-00000000000a'
\set O1 '15400000-0000-4000-8000-000000000001'
\set O2 '15400000-0000-4000-8000-000000000002'
\set O3 '15400000-0000-4000-8000-000000000003'
\set I1 '15400000-0000-4000-8001-000000000001'
\set I2 '15400000-0000-4000-8001-000000000002'
\set I3 '15400000-0000-4000-8001-000000000003'
\set I4 '15400000-0000-4000-8001-000000000004'
\set I5 '15400000-0000-4000-8001-000000000005'
\set X1 '15400000-0000-4000-8002-000000000001'
\set X2 '15400000-0000-4000-8002-000000000002'
\set X3 '15400000-0000-4000-8002-000000000003'
\set X4 '15400000-0000-4000-8002-000000000004'
insert into auth.users(id) values(:'R'),(:'O1'),(:'O2'),(:'O3');
select public.worker_set_feed_policy('all',false);

-- A catalog record (publication, version, metadata) for a paper; returns the metadata id.
create or replace function test.v4_meta(src text,md jsonb) returns uuid language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid();
begin
 insert into app_private.publications(id,title) values(pub,md->>'title');
 insert into app_private.publication_versions(id,publication_id,source,revision) values(ver,pub,'arxiv','1');
 insert into app_private.catalog_metadata(id,version_id,source_id,source_revision,metadata,metadata_sha256)
  values(meta,ver,src,1,md,sha256(convert_to(md::text,'UTF8')));
 return meta;
end $$;
-- A legacy library item for an existing catalog record.
create or replace function test.v4_item(a uuid,meta uuid,tags text[]) returns uuid language plpgsql as $$
declare doc uuid:=gen_random_uuid(); appr uuid:=gen_random_uuid(); orig uuid:=gen_random_uuid(); ver uuid; src text; item uuid;
begin
 select version_id,source_id into strict ver,src from app_private.catalog_metadata where id=meta;
 insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
  values(doc,sha256(convert_to(src||'-'||a::text,'UTF8')),'shared_catalog','{"license":"CC-BY-4.0"}',1000,2);
 insert into app_private.version_documents values(ver,doc) on conflict do nothing;
 insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
  values(orig,'paper-assets','originals/'||encode(sha256(convert_to(src||a::text,'UTF8')),'hex')||'.pdf',doc,'verified',
   sha256(convert_to(src||a::text,'UTF8')),1000,'application/pdf',now());
 insert into app_private.catalog_asset_approvals(id,version_id,document_id,metadata_id,original_object_id,license_uri,policy_version,evidence)
  values(appr,ver,doc,meta,orig,'https://creativecommons.org/licenses/by/4.0/','arxiv-reuse-v1','{}');
 insert into app_private.library_items(account_id,document_id,approval_id,user_tags) values(a,doc,appr,tags) returning id into item;
 return item;
end $$;
-- Settle an import as the HTML-first reader leaves it, and publish its Library entry (the v4 projection the Library reads).
create or replace function test.v4_settle(a uuid,i uuid,meta uuid,device jsonb,tags text[],customized boolean,archived boolean) returns void
language plpgsql as $$
declare s bigint;
begin
 s:=app_private.library_next_seq(a);
 update app_private.import_requests set phase='source_only',metadata_id=meta,device_metadata=device,
  device_metadata_origin=case when device is not null then 'arxiv_html' end,device_metadata_sha256=case when device is not null then sha256(convert_to(device::text,'UTF8')) end,
  device_metadata_revision=case when device is not null then 1 end,device_metadata_at=case when device is not null then now() end,
  source_tags=tags,source_tags_customized=customized,source_archived=archived,state_seq=s
 where account_id=a and id=i;
 perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,i)));
end $$;

-- The reader: two HTML-first papers (one with a catalog record and customized tags, one with only the device's record,
-- archived), one import still in flight, a paper with both a legacy item and an import, a removed import.
set role authenticated;
select set_config('request.jwt.claim.sub',:'R',false);
select public.v2_add_paper_once(:'I1','2401.11111',false);
select public.v2_add_paper_once(:'I2','2401.22222',false);
select public.v2_add_paper_once(:'I3','2401.33333',false);
select public.v2_add_paper_once(:'I4','2401.44444',false);
select public.v2_add_paper_once(:'I5','2401.55555',false);
reset role;
select test.v4_meta('2401.11111',jsonb_build_object('title','Direct Preference Optimization',
 'authors',jsonb_build_array('Ada One','Bo Two','Cy Three','Di Four','Ed Five'),'categories',jsonb_build_array('cs.LG','cs.CL'))) as m1 \gset
select test.v4_settle(:'R',:'I1',:'m1',null,'{"Preference optimization","Reward hacking","Machine learning"}',true,false);
select test.v4_settle(:'R',:'I2',null,jsonb_build_object('title','A device-only record','authors',jsonb_build_array('Fay Six'),
 'categories',jsonb_build_array('cs.CV')),'{}',false,true);
select test.v4_meta('2401.44444',jsonb_build_object('title','Both an item and an import','authors',jsonb_build_array('Gil Seven'),
 'categories',jsonb_build_array('cs.LG'))) as m4 \gset
select test.v4_settle(:'R',:'I4',:'m4',null,'{"Import tag"}',true,false);
select test.v4_item(:'R',:'m4','{"Item tag"}');
update app_private.import_requests set phase='cancelled',desired_present=false where account_id=:'R' and id=:'I5';

-- The Library's projection is what the profile reads for tags and archive.
select test.assert((select effective_tags='{"Preference optimization","Reward hacking","Machine learning"}' and not archived and visible
 from app_private.library_query_entries where account_id=:'R' and kind='import' and id=:'I1'),'the Library shows the customized tags');
select test.assert((select archived from app_private.library_query_entries where account_id=:'R' and kind='import' and id=:'I2'),'the Library shows it archived');

-- The profile.
create temp table prof as select * from app_private.feed_profile(:'R');
select test.assert((select count(*) from prof)=4,'four papers: two HTML-first, one item (also an import), one in flight: '||(select count(*) from prof));
select test.assert((select count(*) from prof where source_id='2401.44444')=1,'a paper with an item and an import counts once');
select test.assert((select own_tags='{"Item tag"}' and not pending from prof where source_id='2401.44444'),'as the item');
select test.assert(not exists(select 1 from prof where source_id='2401.55555'),'a removed import is not in the profile');
select test.assert((select not pending and not archived and title='Direct Preference Optimization' and categories='{cs.LG,cs.CL}'
 and tags='{"Preference optimization","Reward hacking","Machine learning"}'
 and added_at=(select created_at from app_private.import_requests where id=:'I1')
 from prof where source_id='2401.11111'),'an HTML-first import is a library paper with the catalog record and the Library''s tags');
select test.assert((select own_tags='{"Preference optimization","Reward hacking"}' from prof where source_id='2401.11111'),
 'own tags: the customized tags less the paper''s category tag');
select test.assert((select author_keys @> '{"ada one","bo two","cy three","ed five"}' and cardinality(author_keys)=4 from prof where source_id='2401.11111'),
 'lead authors: first three and last');
select test.assert((select not pending and archived and title='A device-only record' and categories='{cs.CV}' and tags='{"Computer vision"}'
 and own_tags='{}' and author_keys='{"fay six"}' from prof where source_id='2401.22222'),
 'a device-only record: its title, authors and category tag; archived as the Library shows it; no own tags when not customized');
select test.assert((select pending and title is null and tags='{}' from prof where source_id='2401.33333'),'an import in flight stays pending');

-- The pool: papers sharing a topic, an author or an own tag (as a phrase) with the HTML-first paper, the reader's own
-- papers, and one paper that only other readers added.
insert into app_private.feed_papers(source_id,revision,title,authors,author_keys,abstract,categories,topics,announced_on,announce_type) values
 ('2610.90001',1,'Preference optimization at scale','{"Zed Zero"}','{"zed zero"}','Scaling preference learning.','{cs.LG}','{"Preference optimization"}',(now() at time zone 'UTC')::date,'new'),
 ('2610.90002',1,'A paper by a library author','{"Ada One","Hal Eight"}','{"ada one","hal eight"}','Something else entirely.','{cs.RO}','{}',(now() at time zone 'UTC')::date,'new'),
 ('2610.90003',1,'Detecting shortcuts','{"Ivy Nine"}','{"ivy nine"}','We measure reward hacking in deployed agents.','{cs.AI}','{}',(now() at time zone 'UTC')::date,'new'),
 ('2610.90004',1,'Popular among other readers','{"Jo Ten"}','{"jo ten"}','Unrelated to the reader.','{cs.SE}','{}',(now() at time zone 'UTC')::date,'new'),
 ('2401.11111',1,'Direct Preference Optimization','{"Ada One"}','{"ada one"}','The reader already has this.','{cs.LG}','{"Preference optimization"}',(now() at time zone 'UTC')::date,'new'),
 ('2401.22222',1,'A device-only record','{"Fay Six"}','{"fay six"}','The reader already has this.','{cs.CV}','{}',(now() at time zone 'UTC')::date,'new'),
 ('2401.33333',1,'In flight','{"Fay Six"}','{"fay six"}','The reader is adding this.','{cs.LG}','{"Preference optimization"}',(now() at time zone 'UTC')::date,'new'),
 ('2401.44444',1,'Both an item and an import','{"Gil Seven"}','{"gil seven"}','The reader already has this.','{cs.LG}','{"Preference optimization"}',(now() at time zone 'UTC')::date,'new');

-- Other readers this week: 2610.90001 by three accounts (two HTML-first imports and one legacy item), 2610.90002 by two.
set role authenticated;
select set_config('request.jwt.claim.sub',:'O1',false);
select public.v2_add_paper_once(:'X1','2610.90001',false);
select public.v2_add_paper_once(:'X3','2610.90002',false);
select set_config('request.jwt.claim.sub',:'O2',false);
select public.v2_add_paper_once(:'X2','2610.90001',false);
select public.v2_add_paper_once(:'X4','2610.90002',false);
reset role;
select test.v4_settle(:'O1',:'X1',null,jsonb_build_object('title','Preference optimization at scale','authors',jsonb_build_array('Zed Zero'),
 'categories',jsonb_build_array('cs.LG')),'{}',false,false);
select test.v4_item(:'O3',test.v4_meta('2610.90001',jsonb_build_object('title','Preference optimization at scale','authors',jsonb_build_array('Zed Zero'),
 'categories',jsonb_build_array('cs.LG'))),'{}');
select test.assert((select count(*) from app_private.feed_readers(:'R','{2610.90001,2610.90002}'))=1,'only papers with three other readers are reported');
select test.assert((select n from app_private.feed_readers(:'R','{2610.90001}'))=3,'imports (settled or in flight) and items count');
select test.assert((select count(*) from app_private.feed_readers(:'O1','{2610.90001}'))=0,'the asking reader is not counted');

-- For you inputs.
set role service_role;
select public.worker_feed_candidates_v2(:'R') as v \gset
reset role;
create temp table fy as select :'v'::jsonb v;
create temp table cand as select c->>'source_id' source_id,c from fy,jsonb_array_elements(v->'candidates') c;
select test.assert((select jsonb_array_length(v->'profile')=4 from fy),'the profile is not empty');
select test.assert(not exists(select 1 from cand where source_id in ('2401.11111','2401.22222','2401.33333','2401.44444')),
 'papers in the v4 library (and in flight) are never offered');
select test.assert((select (c->'topics')?'Preference optimization' from cand where source_id='2610.90001'),'a topic of the HTML-first paper');
select test.assert((select (c->>'readers')::int=3 from cand where source_id='2610.90001'),'Added by several readers: three other accounts');
select test.assert((select c->'readers'='null'::jsonb from cand where source_id='2610.90002'),'two other readers are not reported');
select test.assert((select (c->'author_keys')?'ada one' from cand where source_id='2610.90002'),'an author of the HTML-first paper');
select test.assert((select c->'matched_tags'='["Reward hacking"]'::jsonb from cand where source_id='2610.90003'),
 'an own tag of the HTML-first paper, matched as a phrase');
-- The profile feeds the ranking: its own tag, an author and a titled, settled paper (the tag, author and added reasons).
select test.assert(exists(select 1 from jsonb_array_elements((select v->'profile' from fy)) p where p->>'source_id'='2401.11111'
 and p->>'pending'='false' and p->>'title'='Direct Preference Optimization' and (p->'own_tags')?'Reward hacking' and (p->'author_keys')?'ada one'),
 'the ranking sees the HTML-first paper as a library paper');

-- A topic on an own tag that is only on an HTML-first import; a tag the reader does not have is refused.
set role service_role;
select test.assert((select test_v->'candidates'->0->>'source_id'='2610.90003' and jsonb_array_length(test_v->'candidates')=1
 from (select public.worker_feed_candidates_v2(:'R',null,null,'Reward hacking') test_v) x),'own-tag topic from an import');
select test.reject(format('select public.worker_feed_candidates_v2(%L,null,null,''Never tagged'')',:'R'),'invalid_feed_topic');
select test.reject(format('select public.worker_feed_candidates_v2(%L,null,null,''Machine learning'')',:'R'),'invalid_feed_topic');
reset role;

-- Grants: the helpers are private; candidates stay the service's.
select test.assert(not has_function_privilege('authenticated','app_private.feed_readers(uuid,text[])','execute')
 and not has_function_privilege('service_role','app_private.feed_readers(uuid,text[])','execute'),'readers helper is private');
select test.assert(not has_function_privilege('anon','app_private.feed_import_own_tags(text,text[],boolean,jsonb)','execute'),'own-tags helper is private');
select test.assert(not has_function_privilege('authenticated','app_private.feed_profile(uuid)','execute'),'profile stays private');
select test.assert(has_function_privilege('service_role','public.worker_feed_candidates_v2(uuid,text[],text[],text,jsonb)','execute')
 and not has_function_privilege('authenticated','public.worker_feed_candidates_v2(uuid,text[],text[],text,jsonb)','execute'),'candidates: service only');
rollback;
