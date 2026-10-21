-- AI recommendations (migration 0143; docs/architecture/AI_RECOMMENDATIONS.md): begin (replay, daily limit, seeds only
-- from the reader's own library, exclusions, the 1-credit hold), the Feed pool search, finish (picks, settlement only
-- when a paper was added), stale runs settled uncharged, account deletion, grants and the admin figures.
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

\set A '14300000-0000-4000-8000-00000000000a'
\set B '14300000-0000-4000-8000-00000000000b'
\set OP1 '14300000-0000-4000-8001-000000000001'
\set OP2 '14300000-0000-4000-8001-000000000002'
\set OP3 '14300000-0000-4000-8001-000000000003'
\set OP4 '14300000-0000-4000-8001-000000000004'
\set OP5 '14300000-0000-4000-8001-000000000005'
\set OP6 '14300000-0000-4000-8001-000000000006'
\set OP7 '14300000-0000-4000-8001-000000000007'
\set OP8 '14300000-0000-4000-8001-000000000008'
\set IMPORT '14300000-0000-4000-8002-000000000001'
\set GONE '14300000-0000-4000-8002-000000000002'
\set BIMPORT '14300000-0000-4000-8002-00000000000b'
\set ADD1 '14300000-0000-4000-8003-000000000001'
\set ADD2 '14300000-0000-4000-8003-000000000002'
insert into auth.users(id) values(:'A'),(:'B');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','recommend-143-a',10,now()-interval '1 day',null,'Recommendation fixture');

-- Grants: the function's service role only; the helpers are private.
select test.assert(has_function_privilege('service_role','public.worker_recommend_begin(uuid,uuid,bytea,text,text[],integer)','execute'),'service may begin');
select test.assert(not has_function_privilege('authenticated','public.worker_recommend_begin(uuid,uuid,bytea,text,text[],integer)','execute'),'readers may not');
select test.assert(not has_function_privilege('anon','public.worker_recommend_finish(uuid,uuid,jsonb,text,bigint)','execute'),'never anonymous');
select test.assert(not has_function_privilege('authenticated','public.worker_recommend_pool(uuid,text[],text[],integer)','execute'),'pool is the service''s');
select test.assert(not has_function_privilege('service_role','app_private.recommend_seed(uuid,text)','execute'),'helpers are private');
select test.assert(not has_function_privilege('authenticated','public.worker_expire_stale_chat_operations(integer)','execute'),'sweep stays the service''s');
select test.assert((select enabled and daily_runs=20 and credits=1 and hold_microusd=15000 from app_private.recommendation_policy),'policy defaults');
select test.assert((select window_seconds=3600 and account_limit=30 and environment_limit=600 from app_private.api_rate_rules where route='recommend'),'request gate');

-- The reader's library: a visible item with catalog metadata and own tags (the seed), an HTML-first import with the
-- device's record, a removed item, a cancelled import, a Feed "Not interested". B has one import of its own.
create or replace function test.rec_item(a uuid, src text, md jsonb) returns uuid language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid();
 appr uuid:=gen_random_uuid(); orig uuid:=gen_random_uuid(); item uuid;
begin
 insert into app_private.publications(id,title) values(pub,md->>'title');
 insert into app_private.publication_versions(id,publication_id,source,revision) values(ver,pub,'arxiv','1');
 insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
  values(doc,sha256(convert_to(src||'-document','UTF8')),'shared_catalog','{"license":"CC-BY-4.0"}',1000,2);
 insert into app_private.version_documents values(ver,doc);
 insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
  values(orig,'paper-assets','originals/'||encode(sha256(convert_to(src,'UTF8')),'hex')||'.pdf',doc,'verified',sha256(convert_to(src,'UTF8')),1000,'application/pdf',now());
 insert into app_private.catalog_metadata(id,version_id,source_id,source_revision,metadata,metadata_sha256)
  values(meta,ver,src,1,md,sha256(convert_to(md::text,'UTF8')));
 insert into app_private.catalog_asset_approvals(id,version_id,document_id,metadata_id,original_object_id,license_uri,policy_version,evidence)
  values(appr,ver,doc,meta,orig,'https://creativecommons.org/licenses/by/4.0/','arxiv-reuse-v1','{}');
 insert into app_private.library_items(account_id,document_id,approval_id,user_tags) values(a,doc,appr,'{"Semantic indexes"}') returning id into item;
 return item;
end $$;
select test.rec_item(:'A','2401.00001',jsonb_build_object('title','Evolving Semantic Indexes for Generative Retrieval',
 'authors',jsonb_build_array('Ada One','Bo Two','Cy Three','Di Four'),'abstract','We study generative retrieval with semantic document identifiers.',
 'categories',jsonb_build_array('cs.IR','cs.CL'))) as seed_item \gset
select test.rec_item(:'A','2401.00002',jsonb_build_object('title','Removed generative retrieval paper','authors','[]'::jsonb,'categories','[]'::jsonb)) as gone_item \gset
update app_private.library_items set removed_at=now() where id=:'gone_item';
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_add_paper_once(:'IMPORT','2305.18290',false);
select public.v2_add_paper_once(:'GONE','2402.00003',false);
select set_config('request.jwt.claim.sub',:'B',false);
select public.v2_add_paper_once(:'BIMPORT','2404.00009',false);
reset role;
update app_private.import_requests set phase='source_only',device_metadata=jsonb_build_object('title','Direct Preference Optimization',
 'authors',jsonb_build_array('R. Rafailov'),'abstract','Preference optimization without a reward model.','categories',jsonb_build_array('cs.LG')),
 device_metadata_origin='arxiv_html',device_metadata_sha256=sha256('dpo'),device_metadata_revision=1,device_metadata_at=now(),source_tags='{"Preference optimization"}'
 where account_id=:'A' and id=:'IMPORT';
update app_private.import_requests set phase='cancelled',desired_present=false where account_id=:'A' and id=:'GONE';
update app_private.import_requests set phase='source_only',device_metadata=jsonb_build_object('title','B paper','authors','[]'::jsonb,'categories','[]'::jsonb),
 device_metadata_origin='arxiv_html',device_metadata_sha256=sha256('b'),device_metadata_revision=1,device_metadata_at=now()
 where account_id=:'B' and id=:'BIMPORT';
insert into app_private.feed_feedback(account_id,source_id,kind) values(:'A','2403.00004','not_interested');
insert into app_private.feed_papers(source_id,revision,title,authors,author_keys,abstract,categories,announced_on,announce_type) values
 ('2410.00001',1,'Generative retrieval with learned document codes','{"E. Five","F. Six","G. Seven","H. Eight"}','{"e five","f six","g seven","h eight"}',
  'Generative retrieval maps queries to document identifiers.','{cs.IR}',(now() at time zone 'UTC')::date,'new'),
 ('2410.00002',1,'Semantic indexes for dense retrieval','{"I. Nine"}','{"i nine"}','Dense retrieval over semantic indexes.','{cs.CL}',(now() at time zone 'UTC')::date,'new'),
 ('2403.00004',1,'Generative retrieval the reader dismissed','{}','{}','Generative retrieval again.','{cs.IR}',(now() at time zone 'UTC')::date,'new'),
 ('2402.00003',1,'Generative retrieval the reader removed','{}','{}','Generative retrieval, removed.','{cs.IR}',(now() at time zone 'UTC')::date,'new'),
 ('2410.00003',1,'Protein folding at scale','{}','{}','Nothing about retrieval.','{q-bio.BM}',(now() at time zone 'UTC')::date,'new');

set role service_role;
-- Shape: one seed for a paper, 1–8 distinct for a catalog, 1/3/5 papers, a 32-byte digest.
select test.reject(format('select public.worker_recommend_begin(%L,%L,sha256(''x''),''paper'',array[''2401.00001''],2)',:'A',:'OP1'),'invalid_recommendation');
select test.reject(format('select public.worker_recommend_begin(%L,%L,sha256(''x''),''paper'',array[''2401.00001'',''2305.18290''],3)',:'A',:'OP1'),'invalid_recommendation');
select test.reject(format('select public.worker_recommend_begin(%L,%L,sha256(''x''),''catalog'',array[''2401.00001'',''2401.00001''],3)',:'A',:'OP1'),'invalid_recommendation');
select test.reject(format('select public.worker_recommend_begin(%L,%L,sha256(''x''),''shelf'',array[''2401.00001''],3)',:'A',:'OP1'),'invalid_recommendation');
select test.reject(format('select public.worker_recommend_begin(%L,%L,''\x00''::bytea,''paper'',array[''2401.00001''],3)',:'A',:'OP1'),'invalid_recommendation');
-- Seeds come from the reader's own library only: another account's paper, a removed item, a cancelled import, unknown.
select test.reject(format('select public.worker_recommend_begin(%L,%L,sha256(''x''),''paper'',array[''2404.00009''],3)',:'A',:'OP1'),'recommend_seed_unavailable');
select test.reject(format('select public.worker_recommend_begin(%L,%L,sha256(''x''),''paper'',array[''2401.00002''],3)',:'A',:'OP1'),'recommend_seed_unavailable');
select test.reject(format('select public.worker_recommend_begin(%L,%L,sha256(''x''),''paper'',array[''2402.00003''],3)',:'A',:'OP1'),'recommend_seed_unavailable');
select test.reject(format('select public.worker_recommend_begin(%L,%L,sha256(''x''),''paper'',array[''9999.99999''],3)',:'A',:'OP1'),'recommend_seed_unavailable');
reset role;
select test.assert(not exists(select 1 from app_private.metered_operations where account_id=:'A'),'a refused request holds nothing');

-- A request: seeds as the server holds them, everything the reader has or had excluded, a 1-credit hold.
set role service_role;
select public.worker_recommend_begin(:'A',:'OP1',sha256('op1'),'paper',array['2401.00001'],3) as b1 \gset
reset role;
create temp table j as select :'b1'::jsonb v;
select test.assert((select v->>'replayed'='false' and v->>'state'='running' and (v->>'requested')::int=3 and (v->>'credits')::int=1 from j),'begun');
select test.assert((select v->'seeds'->0->>'title'='Evolving Semantic Indexes for Generative Retrieval'
 and v->'seeds'->0->'authors'='["Ada One","Bo Two","Cy Three"]'::jsonb and v->'seeds'->0->'categories'='["cs.IR","cs.CL"]'::jsonb
 and v->'seeds'->0->'tags' ? 'Semantic indexes' and v->'seeds'->0->>'abstract' like 'We study%' from j),'seed from the catalog record, bounded');
select test.assert((select v->'exclude' ?& array['2401.00001','2401.00002','2305.18290','2402.00003','2403.00004'] and not v->'exclude' ? '2404.00009' from j),
 'exclusions: own items and imports (removed too) and Not interested; never another account''s');
select test.assert((select kind='recommend' and credit_ceiling=1 and spend_ceiling_microusd=15000 and state='reserved' from app_private.metered_operations
 where account_id=:'A' and id=:'OP1'),'held like any paid request');
select test.assert((select reserved=1 from app_private.credit_buckets where account_id=:'A'),'one credit held');
-- The same request again: its state, never a second hold; another request under the same id conflicts.
set role service_role;
select test.assert(public.worker_recommend_begin(:'A',:'OP1',sha256('op1'),'paper',array['2401.00001'],3)->>'replayed'='true','replay');
select test.reject(format('select public.worker_recommend_begin(%L,%L,sha256(''other''),''paper'',array[''2401.00001''],3)',:'A',:'OP1'),'operation_id_conflict');
reset role;
select test.assert((select count(*) from app_private.metered_operations where account_id=:'A')=1,'still one operation');

-- The Feed pool: any term's words, the shared category first, the reader's exclusions gone.
set role service_role;
select public.worker_recommend_pool(:'A',array['generative retrieval','semantic indexes'],array['cs.IR'],10) as pool \gset
reset role;
select test.assert((select array_agg(x->>'source_id' order by n) from jsonb_array_elements(:'pool'::jsonb) with ordinality t(x,n))='{2410.00001,2410.00002}','pool matches, excluded and unrelated gone');
select test.assert((select x->'authors'='["E. Five","F. Six","G. Seven"]'::jsonb and (x->>'year')::int=extract(year from now())::int and x->>'abstract' like 'Generative%'
 from jsonb_array_elements(:'pool'::jsonb) x where x->>'source_id'='2410.00001'),'bounded rows');
set role service_role;
select test.assert(public.worker_recommend_pool(:'A',array['of the'],'{}',5)='[]'::jsonb,'stop words only: nothing');
select test.reject(format('select public.worker_recommend_pool(%L,array[]::text[],''{}'',5)',:'A'),'invalid_recommendation');
select test.reject(format('select public.worker_recommend_pool(%L,array[''x''],''{}'',5)',:'A'),'invalid_recommendation');
select test.reject(format('select public.worker_recommend_pool(%L,array[''retrieval''],''{}'',31)',:'A'),'invalid_recommendation');
select test.reject(format('select public.worker_recommend_pool(%L,array[''retrieval''],array[''cs.IR; drop''],5)',:'A'),'invalid_recommendation');
reset role;

-- Finish: picks recorded, 1 credit because papers were added; identical replay is a no-op, a different one conflicts.
\set PICKS '[{"source_id":"2410.00001","revision":1,"title":"Generative retrieval with learned document codes","authors":["E. Five"],"year":2026,"reason":"Same task; learns the codes instead of fixing them","status":"added","import_id":"14300000-0000-4000-8003-000000000001"},{"source_id":"2410.00002","title":"Semantic indexes for dense retrieval","reason":"Dense counterpart of its semantic index","status":"added","import_id":"14300000-0000-4000-8003-000000000002"},{"source_id":"2305.18290","title":"Direct Preference Optimization","reason":"Already present","status":"present","import_id":null}]'
set role service_role;
select test.reject(format('select public.worker_recommend_finish(%L,%L,%L::jsonb,null,1700)',:'A',:'OP1','[{"source_id":"2410.00001","title":"t","reason":"r","status":"maybe"}]'),'invalid_recommendation');
select test.reject(format('select public.worker_recommend_finish(%L,%L,%L::jsonb,null,1700)',:'A',:'OP1','[{"source_id":"2410.00001","title":"t","reason":"r","status":"added","prompt":"x"}]'),'invalid_recommendation');
select test.reject(format('select public.worker_recommend_finish(%L,%L,%L::jsonb,null,1700)',:'A',:'OP1','[{"source_id":"2410.00001","title":"t","reason":"r","status":"added"},{"source_id":"2410.00001","title":"t","reason":"r","status":"added"}]'),'invalid_recommendation');
select test.reject(format('select public.worker_recommend_finish(%L,%L,%L::jsonb,''Bad Code'',1700)',:'A',:'OP1','[]'),'invalid_recommendation');
select test.reject(format('select public.worker_recommend_finish(%L,%L,%L::jsonb,null,1700)',:'B',:'OP1','[]'),'recommendation_unavailable');
select public.worker_recommend_finish(:'A',:'OP1',:'PICKS'::jsonb,null,1700) as f1 \gset
reset role;
select test.assert(:'f1'::jsonb=jsonb_build_object('state','finished','added',2,'credits',1,'charged',true,'replayed',false),'finished, charged 1 credit');
select test.assert((select state='settled' and actual_credits=1 from app_private.metered_operations where account_id=:'A' and id=:'OP1'),'operation settled');
select test.assert((select balance=9 and reserved=0 from app_private.credit_buckets where account_id=:'A'),'one credit spent, nothing held');
select test.assert((select state='finished' and added=2 and credits=1 and jsonb_array_length(picks)=3 and finished_at is not null
 from app_private.recommendation_runs where account_id=:'A' and id=:'OP1'),'run recorded');
set role service_role;
select test.assert(public.worker_recommend_finish(:'A',:'OP1',:'PICKS'::jsonb,null,1700)->>'replayed'='true','identical finish replays');
select test.reject(format('select public.worker_recommend_finish(%L,%L,''[]''::jsonb,null,1700)',:'A',:'OP1'),'settlement_id_conflict');
select test.assert(public.worker_recommend_begin(:'A',:'OP1',sha256('op1'),'paper',array['2401.00001'],3)->'picks'=:'PICKS'::jsonb,'a replayed begin returns the picks');

-- A catalog request with nothing related: finished, nothing charged.
select public.worker_recommend_begin(:'A',:'OP2',sha256('op2'),'catalog',array['2401.00001','2305.18290'],1) as b2 \gset
select test.assert(jsonb_array_length(:'b2'::jsonb->'seeds')=2 and :'b2'::jsonb->'seeds'->1->>'title'='Direct Preference Optimization'
 and :'b2'::jsonb->'seeds'->1->'tags'='["Preference optimization"]'::jsonb,'a catalog request reads each seed, the device record too');
select test.reject(format('select public.worker_recommend_finish(%L,%L,%L::jsonb,null,0)',:'A',:'OP2',:'PICKS'),'invalid_recommendation');
select test.assert(public.worker_recommend_finish(:'A',:'OP2','[]'::jsonb,null,1500)=jsonb_build_object('state','finished','added',0,'credits',0,'charged',false,'replayed',false),'nothing added: free');
-- A failed request (the model could not be reached): failed, free.
select public.worker_recommend_begin(:'A',:'OP3',sha256('op3'),'paper',array['2305.18290'],5);
select test.assert(public.worker_recommend_finish(:'A',:'OP3','[]'::jsonb,'model_unavailable',0)->>'state'='failed','failed');
reset role;
select test.assert((select actual_credits=0 from app_private.metered_operations where account_id=:'A' and id=:'OP2')
 and (select actual_credits=0 from app_private.metered_operations where account_id=:'A' and id=:'OP3'),'no credits for either');
select test.assert((select balance=9 and reserved=0 from app_private.credit_buckets where account_id=:'A'),'balance unchanged by free requests');

-- A run whose function died: the stale sweep settles it uncharged after 30 minutes.
set role service_role;
select public.worker_recommend_begin(:'A',:'OP4',sha256('op4'),'paper',array['2401.00001'],1);
reset role;
update app_private.recommendation_runs set created_at=now()-interval '40 minutes' where account_id=:'A' and id=:'OP4';
update app_private.metered_operations set created_at=now()-interval '40 minutes' where account_id=:'A' and id=:'OP4';
set role service_role;
select test.assert(public.worker_expire_stale_chat_operations(30)>=1,'the sweep settled it');
reset role;
select test.assert((select state='failed' and failure='expired' from app_private.recommendation_runs where account_id=:'A' and id=:'OP4')
 and (select state='settled' and actual_credits=0 from app_private.metered_operations where account_id=:'A' and id=:'OP4'),'expired, uncharged');

-- The daily limit counts every request in the last 24 hours (4 so far).
update app_private.recommendation_policy set daily_runs=5;
set role service_role;
select public.worker_recommend_begin(:'A',:'OP5',sha256('op5'),'paper',array['2401.00001'],1);
select test.reject(format('select public.worker_recommend_begin(%L,%L,sha256(''op6''),''paper'',array[''2401.00001''],1)',:'A',:'OP6'),'recommend_daily_limit');
reset role;
update app_private.recommendation_runs set created_at=now()-interval '25 hours' where account_id=:'A' and id in (:'OP1',:'OP2');
-- OP5 was left open by a killed function: the account's next request settles it first (after 10 minutes).
update app_private.recommendation_runs set created_at=now()-interval '11 minutes' where account_id=:'A' and id=:'OP5';
set role service_role;
select test.assert(public.worker_recommend_begin(:'A',:'OP6',sha256('op6'),'paper',array['2401.00001'],1)->>'state'='running','older requests leave the window');
reset role;
select test.assert((select state='failed' and failure='expired' from app_private.recommendation_runs where account_id=:'A' and id=:'OP5'),'own stale run expired first');
-- Switched off: refused before anything is held.
update app_private.recommendation_policy set enabled=false;
set role service_role;
select test.reject(format('select public.worker_recommend_begin(%L,%L,sha256(''op7''),''paper'',array[''2401.00001''],1)',:'A',:'OP7'),'recommend_unavailable');
reset role;
update app_private.recommendation_policy set enabled=true,daily_runs=20;
-- No credits: refused by the reservation, nothing recorded.
set role service_role;
select test.reject(format('select public.worker_recommend_begin(%L,%L,sha256(''b''),''paper'',array[''2404.00009''],3)',:'B',:'OP8'),'insufficient_credits');
reset role;
select test.assert(not exists(select 1 from app_private.recommendation_runs where account_id=:'B'),'nothing recorded for B');

-- Admin: Costs names the feature; Health counts requests.
select test.assert(app_private.cost_feature('chat','recommend')='recommendations' and app_private.cost_feature('chat','chat')='chat','cost feature');
select test.assert((app_private.admin_health_extra()->'recommendations'->'last_30d'->>'runs')::int=6
 and (app_private.admin_health_extra()->'recommendations'->'last_24h'->>'papers_added')::int=0
 and (app_private.admin_health_extra()->'recommendations'->'last_30d'->>'papers_added')::int=2
 and (app_private.admin_health_extra()->'recommendations'->'last_24h'->>'running')::int=1
 and app_private.admin_health_extra() ? 'tariffs','health block, earlier keys kept');

-- Account deletion: refused while a request is open; then the runs go with the library (billing rows stay).
set role service_role;
select public.worker_recommend_finish(:'A',:'OP6','[]'::jsonb,null,0);
select test.assert((public.worker_account_deletion_status(:'A')->>'recommendation_runs')::int=6,'counted as personal rows');
select public.worker_delete_account_begin(:'A');
reset role;
select test.assert(not exists(select 1 from app_private.recommendation_runs where account_id=:'A'),'runs deleted with the account');
select test.assert((select count(*) from app_private.metered_operations where account_id=:'A' and kind='recommend')=6,'operations stay as the billing record');
set role service_role;
select test.assert((public.worker_account_deletion_status(:'A')->>'recommendation_runs')::int=0,'none left');
reset role;
rollback;
