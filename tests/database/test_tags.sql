-- Topic tags (migration 029): catalog tags claimed, platform-funded, recorded and projected with
-- a new state_seq; personal tags replayable and revision-checked; untagged entries unchanged.
begin;
insert into auth.users values('28000000-0000-0000-0000-00000000000a'),('28000000-0000-0000-0000-00000000000b'),('28000000-0000-0000-0000-00000000000c');
set role service_role;
select public.worker_record_arxiv_metadata('2401.02801',1,'{"title":"Sparse attention for long documents","authors":["A. Reader"],"abstract":"We study attention.","categories":["cs.CL","cs.LG"]}') as meta1 \gset
select public.worker_record_arxiv_metadata('2401.02802',1,'{"title":"Strings at low energy","authors":["B. Physicist"],"categories":["hep-th"]}') as meta2 \gset
reset role;
insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values
 ('28000000-0000-0000-0000-000000000010',decode(repeat('5a',32),'hex'),'shared_catalog','{"legacy_fixture":true}',1000,2),
 ('28000000-0000-0000-0000-000000000020',decode(repeat('5b',32),'hex'),'shared_catalog','{"legacy_fixture":true}',1000,2);
insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values
 ('28000000-0000-0000-0000-000000000011','paper-assets','test/tags/one.pdf','28000000-0000-0000-0000-000000000010','verified',decode(repeat('5a',32),'hex'),1000,'application/pdf',now()),
 ('28000000-0000-0000-0000-000000000021','paper-assets','test/tags/two.pdf','28000000-0000-0000-0000-000000000020','verified',decode(repeat('5b',32),'hex'),1000,'application/pdf',now());
set role service_role;
select public.worker_approve_arxiv_asset('28000000-0000-0000-0000-000000000101',:'meta1','28000000-0000-0000-0000-000000000010','28000000-0000-0000-0000-000000000011','https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2401.02801','source_revision',1,'source_url','https://arxiv.org/abs/2401.02801v1','license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('a',64),'observed_at','2026-10-07T01:00:00Z'));
select public.worker_approve_arxiv_asset('28000000-0000-0000-0000-000000000201',:'meta2','28000000-0000-0000-0000-000000000020','28000000-0000-0000-0000-000000000021','https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2401.02802','source_revision',1,'source_url','https://arxiv.org/abs/2401.02802v1','license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('b',64),'observed_at','2026-10-07T01:00:00Z'));
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,1000000,false);
reset role;
select version_id as v1 from app_private.catalog_metadata where id=:'meta1' \gset
select version_id as v2 from app_private.catalog_metadata where id=:'meta2' \gset

-- Tag text rules.
select test.assert(app_private.valid_tag_list('{}',3) and app_private.valid_tag_list(array['Diffusion models','My reading group'],3),'valid lists');
select test.assert(not app_private.valid_tag_list(null,3) and not app_private.valid_tag_list(array[' padded'],3) and not app_private.valid_tag_list(array['two  spaces'],3)
 and not app_private.valid_tag_list(array['Same','same'],3) and not app_private.valid_tag_list(array[repeat('x',41)],3)
 and not app_private.valid_tag_list(array['a','b','c','d'],3) and not app_private.valid_tag_list(array[''],3)
 and not app_private.valid_tag_list(array['line'||chr(10)||'break'],3) and not app_private.valid_tag_list(array[[ 'a' ],[ 'b' ]],3),'invalid lists rejected');

-- Readers: A has both papers, B has the first.
set role authenticated;
select set_config('request.jwt.claim.sub','28000000-0000-0000-0000-00000000000a',false);
select public.v2_set_library_item('28000000-0000-0000-0000-0000000000a1','28000000-0000-0000-0000-000000000010',true,0,'28000000-0000-0000-0000-000000000101')->'entry' as a1 \gset
select public.v2_set_library_item('28000000-0000-0000-0000-0000000000a2','28000000-0000-0000-0000-000000000020',true,0,'28000000-0000-0000-0000-000000000201')->'entry' as a2 \gset
select test.assert(not (:'a1'::jsonb ?| array['tags','user_tags','hidden_tags']),'an untagged entry is unchanged');
select set_config('request.jwt.claim.sub','28000000-0000-0000-0000-00000000000b',false);
select public.v2_set_library_item('28000000-0000-0000-0000-0000000000b1','28000000-0000-0000-0000-000000000010',true,0,'28000000-0000-0000-0000-000000000101')->'entry' as b1 \gset
-- Customers cannot run the worker.
select test.reject($q$select public.worker_tags_claim(gen_random_uuid(),5,true,'gradstep-tags-v1')$q$,'permission denied');
select test.reject($q$select public.worker_tags_status()$q$,'permission denied');
reset role;
set role anon;
select test.reject($q$select public.v2_set_item_tags(gen_random_uuid(),'28000000-0000-0000-0000-000000000010','{}','{}',1)$q$,'permission denied');
reset role;

-- Budget paused: candidates come back without a hold; the worker records the category fallback.
set role service_role;
select test.assert((public.worker_tags_status()->>'wanted')::int=2 and (public.worker_tags_status()->>'untagged')::int=2,'two versions wanted, untagged');
select test.reject($q$select public.worker_tags_claim(gen_random_uuid(),0,true,'gradstep-tags-v1')$q$,'invalid_tag_claim');
select public.worker_tags_claim('28000000-0000-0000-0000-00000000c001',5,true,'gradstep-tags-v1') as claim \gset
select test.assert(jsonb_array_length(:'claim'::jsonb)=2 and not (:'claim'::jsonb->0->>'model')::boolean
 and :'claim'::jsonb->0->>'model_refused'='platform_budget_exhausted','paused budget: no hold, reason given');
select test.assert(exists(select 1 from jsonb_array_elements(:'claim'::jsonb) c where c->>'version_id'=:'v1' and c->>'title'='Sparse attention for long documents'
 and c->'categories'=jsonb_build_array('cs.CL','cs.LG')),'claim carries title, abstract, categories');
select test.assert(jsonb_array_length(public.worker_tags_claim(gen_random_uuid(),5,true,'gradstep-tags-v1'))=0,'claimed rows are not handed out twice');
select test.reject(format($q$select public.worker_tags_record(%L,gen_random_uuid(),%L,array['Machine learning'],'categories','gradstep-tags-v1',null,decode(repeat('01',32),'hex'),null,null,0,false)$q$,:'v1',:'meta1'),'stale_tag_claim');
select test.reject(format($q$select public.worker_tags_record(%L,'28000000-0000-0000-0000-00000000c001',%L,array['Machine learning'],'model','gradstep-tags-v1','claude-haiku-4-5-20251001',decode(repeat('01',32),'hex'),'msg_x',null,10,true)$q$,:'v1',:'meta1'),'unfunded_tag_call');
select test.reject(format($q$select public.worker_tags_record(%L,'28000000-0000-0000-0000-00000000c001',%L,array['Machine learning'],'categories','gradstep-tags-v1',null,decode(repeat('01',32),'hex'),null,null,0,false)$q$,:'v1',:'meta2'),'invalid_tag_result');
select public.worker_tags_record(:'v1','28000000-0000-0000-0000-00000000c001',:'meta1',array['Natural language processing','Machine learning'],'categories','gradstep-tags-v1',null,decode(repeat('01',32),'hex'),null,null,0,false) as rec \gset
select test.assert((:'rec'::jsonb->>'revision')::int=1 and (:'rec'::jsonb->>'changed')::boolean and jsonb_array_length(:'rec'::jsonb->'items')=2,'fallback recorded; both readers'' items need projection');
-- hep-th maps to no vocabulary tag: a completed, empty result (no projection, no entry change).
select public.worker_tags_record(:'v2','28000000-0000-0000-0000-00000000c001',:'meta2','{}','categories','gradstep-tags-v1',null,decode(repeat('02',32),'hex'),null,null,0,false) as rec2 \gset
select test.assert((:'rec2'::jsonb->>'revision')::int=0 and jsonb_array_length(:'rec2'::jsonb->'items')=0,'no suitable tags');
select test.assert(jsonb_array_length(public.worker_tags_pending_projection(100))=2,'two items lag');
reset role;
select state_seq as a1_seq from app_private.library_items where id=(:'a1'::jsonb->>'id')::uuid \gset
-- Recording alone changes no entry: an entry only changes with a new state_seq.
set role authenticated;
select set_config('request.jwt.claim.sub','28000000-0000-0000-0000-00000000000a',false);
select test.assert(exists(select 1 from jsonb_array_elements(public.v3_library_page()->'entries') e
 where e->>'id'=:'a1'::jsonb->>'id' and (e->>'state_seq')::bigint=:a1_seq and e=:'a1'::jsonb),'unprojected entry is byte-identical');
reset role;

-- Projection: one new state_seq and journal entry per visible item; idempotent.
set role service_role;
select test.assert(public.worker_tags_project('28000000-0000-0000-0000-00000000000a',(:'a1'::jsonb->>'id')::uuid),'projected A');
select test.assert(public.worker_tags_project('28000000-0000-0000-0000-00000000000b',(:'b1'::jsonb->>'id')::uuid),'projected B');
select test.assert(not public.worker_tags_project('28000000-0000-0000-0000-00000000000a',(:'a1'::jsonb->>'id')::uuid),'already current');
select test.assert(not public.worker_tags_project('28000000-0000-0000-0000-00000000000a',(:'a2'::jsonb->>'id')::uuid),'an untagged version changes nothing');
select test.assert(jsonb_array_length(public.worker_tags_pending_projection(100))=0,'nothing lags');
reset role;
select test.assert((select state_seq>:a1_seq and catalog_tags=array['Natural language processing','Machine learning'] from app_private.library_items where id=(:'a1'::jsonb->>'id')::uuid),'new state for the new tags');
set role authenticated;
select set_config('request.jwt.claim.sub','28000000-0000-0000-0000-00000000000a',false);
select test.assert(exists(select 1 from jsonb_array_elements(public.v3_library_changes(0)->'changes') c, jsonb_array_elements(c->'entries') e
 where e->>'id'=:'a1'::jsonb->>'id' and e->'tags'=jsonb_build_array('Natural language processing','Machine learning') and (e->>'state_seq')::bigint>:a1_seq),'other devices receive the tags');
select test.assert(exists(select 1 from jsonb_array_elements(public.v3_library_page()->'entries') e
 where e->>'id'=:'a2'::jsonb->>'id' and not (e ?| array['tags','user_tags','hidden_tags'])),'the empty result keeps the entry unchanged');
reset role;

-- Budget on: the fallback is upgraded by the model under a platform-funded hold (0 reader credits).
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,1000000,true);
reset role;
select spent_microusd as spent0,reserved_microusd as reserved0 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date \gset
select test.assert((select next_attempt_at>now() from app_private.catalog_tags where version_id=:'v1'),'an unattempted fallback waits before upgrading');
update app_private.catalog_tags set next_attempt_at=now() where version_id=:'v1';
set role service_role;
select test.assert(jsonb_array_length(public.worker_tags_claim(gen_random_uuid(),5,false,'gradstep-tags-v1'))=0,'without the model, fallbacks are not re-claimed');
select public.worker_tags_claim('28000000-0000-0000-0000-00000000c002',5,true,'gradstep-tags-v1') as claim2 \gset
select test.assert(jsonb_array_length(:'claim2'::jsonb)=1 and (:'claim2'::jsonb->0->>'model')::boolean and (:'claim2'::jsonb->0->>'hold_microusd')::int=10000
 and :'claim2'::jsonb->0->>'method'='categories','claimed for the model with a hold');
reset role;
select test.assert((select o.kind='metadata' and o.credit_ceiling=0 and o.spend_ceiling_microusd=10000 and o.state='reserved' and o.account_id='28000000-0000-0000-0000-00000000000a'
 from app_private.catalog_tags t join app_private.metered_operations o on (o.account_id,o.id)=(t.operation_account_id,t.operation_id) where t.version_id=:'v1'),
 'hold: platform-funded, first reader of record, no credits');
select test.assert((select reserved_microusd=:reserved0+10000 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),'budget reserved');
set role service_role;
select public.worker_tags_record(:'v1','28000000-0000-0000-0000-00000000c002',:'meta1',array['Natural language processing','Transformers','Long context'],'model','gradstep-tags-v1',
 'claude-haiku-4-5-20251001',decode(repeat('03',32),'hex'),'msg_tags_test_1','{"input_tokens":2900,"output_tokens":40}',3100,true) as rec3 \gset
select test.assert((:'rec3'::jsonb->>'revision')::int=2 and :'rec3'::jsonb->>'method'='model' and jsonb_array_length(:'rec3'::jsonb->'items')=2,'model tags replace the fallback');
reset role;
select test.assert((select spent_microusd=:spent0+3100 and reserved_microusd=:reserved0 and work_enabled from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),'settled at the actual cost');
select test.assert((select actual_credits=0 and actual_microusd=3100 from app_private.metered_operations where account_id='28000000-0000-0000-0000-00000000000a' and kind='metadata'),'reader not charged');
select test.assert((select provider='anthropic' and model='claude-haiku-4-5-20251001' and estimated_microusd=3100 and (units->>'input_tokens')::int=2900
 from app_private.provider_usage_events where provider_event_id='msg_tags_test_1'),'provider usage recorded');
select test.assert((select operation_id is null and claim_id is null and attempts=0 and model='claude-haiku-4-5-20251001' from app_private.catalog_tags where version_id=:'v1'),'claim cleared');

-- A later model failure (e.g. a vocabulary change) never downgrades model tags.
update app_private.catalog_tags set next_attempt_at=now() where version_id=:'v1';
set role service_role;
select public.worker_tags_claim('28000000-0000-0000-0000-00000000c003',5,true,'gradstep-tags-v2') as claim3 \gset
select test.assert(jsonb_array_length(:'claim3'::jsonb)=1,'a new vocabulary re-tags');
select public.worker_tags_record(:'v1','28000000-0000-0000-0000-00000000c003',:'meta1',array['Machine learning'],'categories','gradstep-tags-v2',null,decode(repeat('04',32),'hex'),null,null,0,true) as rec4 \gset
select test.assert(not (:'rec4'::jsonb->>'changed')::boolean and :'rec4'::jsonb->>'method'='model' and (:'rec4'::jsonb->>'revision')::int=2,'model tags kept');
reset role;
select test.assert((select attempts=1 and next_attempt_at>now()+interval '9 minutes' and vocabulary='gradstep-tags-v1' from app_private.catalog_tags where version_id=:'v1'),'retry backs off');

-- A worker that died mid-claim: the hold is spent at its ceiling and the claim released.
update app_private.catalog_tags set next_attempt_at=now() where version_id=:'v1';
set role service_role;
select test.assert(jsonb_array_length(public.worker_tags_claim('28000000-0000-0000-0000-00000000c004',5,true,'gradstep-tags-v2'))=1,'claimed again');
reset role;
update app_private.catalog_tags set lease_until=now()-interval '1 second' where version_id=:'v1';
set role service_role;
select public.worker_tags_claim(gen_random_uuid(),5,false,'gradstep-tags-v2');
reset role;
select test.assert((select claim_id is null and attempts=2 from app_private.catalog_tags where version_id=:'v1'),'expired claim released');
select test.assert((select spent_microusd=:spent0+13100 and reserved_microusd=:reserved0 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),'hold spent at its ceiling');
select test.assert(not exists(select 1 from app_private.metered_operations where kind='metadata' and state<>'settled'),'no open holds');

-- Projection of the model tags, then personal tags.
set role service_role;
select public.worker_tags_project(x.account_id,x.item_id) from jsonb_to_recordset(public.worker_tags_pending_projection(100)) x(account_id uuid,item_id uuid);
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','28000000-0000-0000-0000-00000000000a',false);
select (e->>'membership_revision')::bigint as rev from jsonb_array_elements(public.v3_library_page()->'entries') e where e->>'id'=:'a1'::jsonb->>'id' \gset
select test.reject($q$select public.v2_set_item_tags(gen_random_uuid(),'28000000-0000-0000-0000-000000000010',array[' x'],'{}',1)$q$,'invalid_tags_command');
select test.reject($q$select public.v2_set_item_tags(gen_random_uuid(),'28000000-0000-0000-0000-000000000010',array['A','a'],'{}',1)$q$,'invalid_tags_command');
select test.reject($q$select public.v2_set_item_tags(gen_random_uuid(),'28000000-0000-0000-0000-000000000010',(select array_agg('t'||n) from generate_series(1,13) n),'{}',1)$q$,'invalid_tags_command');
select test.reject($q$select public.v2_set_item_tags(gen_random_uuid(),'28000000-0000-0000-0000-000000000010',null,'{}',1)$q$,'invalid_tags_command');
select public.v2_set_item_tags('28000000-0000-0000-0000-0000000000a3','28000000-0000-0000-0000-000000000010',array['Reading group','To reproduce'],array['Long context'],:rev) as mine \gset
select test.assert(:'mine'::jsonb->'result'->>'status'='applied' and (:'mine'::jsonb->'result'->>'revision')::bigint=:rev+1,'personal tags applied');
select test.assert(:'mine'::jsonb->'entry'->'user_tags'=jsonb_build_array('Reading group','To reproduce') and :'mine'::jsonb->'entry'->'hidden_tags'=jsonb_build_array('Long context')
 and :'mine'::jsonb->'entry'->'tags'=jsonb_build_array('Natural language processing','Transformers','Long context'),'entry has catalog, own and hidden tags');
select test.assert((public.v2_set_item_tags('28000000-0000-0000-0000-0000000000a3','28000000-0000-0000-0000-000000000010',array['Reading group','To reproduce'],array['Long context'],:rev)->>'replayed')::boolean,'replay');
select test.reject($q$select public.v2_set_item_tags('28000000-0000-0000-0000-0000000000a3','28000000-0000-0000-0000-000000000010',array['Different'],'{}',$q$||:rev||')','operation_id_conflict');
select test.assert(public.v2_set_item_tags(gen_random_uuid(),'28000000-0000-0000-0000-000000000010','{}','{}',:rev)->'result'->>'status'='revision_conflict','stale revision conflicts');
select test.assert(exists(select 1 from jsonb_array_elements(public.v3_library_changes(0)->'changes') c, jsonb_array_elements(c->'entries') e
 where e->'user_tags'=jsonb_build_array('Reading group','To reproduce')),'other devices receive personal tags');
-- B's copy is untouched; an account without the item changes nothing.
select set_config('request.jwt.claim.sub','28000000-0000-0000-0000-00000000000b',false);
select test.assert(exists(select 1 from jsonb_array_elements(public.v3_library_page()->'entries') e
 where e->>'id'=:'b1'::jsonb->>'id' and e ? 'tags' and not (e ?| array['user_tags','hidden_tags'])),'personal tags are per reader');
select set_config('request.jwt.claim.sub','28000000-0000-0000-0000-00000000000c',false);
select test.assert(public.v2_set_item_tags(gen_random_uuid(),'28000000-0000-0000-0000-000000000010',array['x'],'{}',1)->'result'->>'revision'='0','no item, no change');
-- A new reader's item has the catalog tags from the start (no projection needed).
select public.v2_set_library_item(gen_random_uuid(),'28000000-0000-0000-0000-000000000010',true,0,'28000000-0000-0000-0000-000000000101')->'entry' as c1 \gset
select test.assert(:'c1'::jsonb->'tags'=jsonb_build_array('Natural language processing','Transformers','Long context'),'new item starts tagged');
-- Removal forgets personal tags; the removed entry shows none; a re-add shows the catalog's.
select set_config('request.jwt.claim.sub','28000000-0000-0000-0000-00000000000a',false);
select public.v2_set_library_item(gen_random_uuid(),'28000000-0000-0000-0000-000000000010',false,:rev+1)->'entry' as removed \gset
select test.assert(not (:'removed'::jsonb ?| array['tags','user_tags','hidden_tags']) and :'removed'::jsonb->>'visible'='false','removed entry shows no tags');
select test.assert(public.v2_set_item_tags(gen_random_uuid(),'28000000-0000-0000-0000-000000000010',array['x'],'{}',:rev+2)->'result'->>'status'='revision_conflict','a removed item cannot be tagged');
select public.v2_set_library_item(gen_random_uuid(),'28000000-0000-0000-0000-000000000010',true,:rev+2,'28000000-0000-0000-0000-000000000101')->'entry' as readded \gset
select test.assert(:'readded'::jsonb ? 'tags' and not (:'readded'::jsonb ?| array['user_tags','hidden_tags']),'re-add: catalog tags only');
reset role;
select test.assert((select user_tags='{}' and hidden_tags='{}' from app_private.library_items where id=(:'a1'::jsonb->>'id')::uuid),'personal tags cleared on removal');

set role service_role;
select test.assert((public.worker_tags_status()->>'model')::int=1 and (public.worker_tags_status()->>'stale_items')::int=0,'status counts');
select test.assert((public.worker_set_tagging_enabled(false)->>'enabled')::boolean=false,'kill switch');
select test.assert(jsonb_array_length(public.worker_tags_claim(gen_random_uuid(),5,true,'gradstep-tags-v3'))=0,'disabled: nothing claimed');
reset role;
rollback;
