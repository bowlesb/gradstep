-- Paper podcasts (migration 048): dark defaults, seed funding inside the
-- platform budget, private quote/start/cancel, fenced provider grants, storage
-- inventory, publication review, rights takedown, bounded delivery, recovery,
-- quality losses and account deletion. Synthetic local SQL; provider and Storage
-- outcomes are explicit fixture receipts, never network calls.
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

\set O '46000000-0000-0000-0000-00000000000f'
\set A '46000000-0000-0000-0000-00000000000a'
\set B '46000000-0000-0000-0000-00000000000b'
insert into auth.users(id) values(:'O'),(:'A'),(:'B');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
select coalesce(spent_microusd,0) as spent0,coalesce(reserved_microusd,0) as reserved0 from app_private.platform_budgets where period=:'month' \gset
select public.worker_grant_credits(:'A','adjustment','podcast-a',1000,now()-interval '1 day',null,'Podcast fixture');
select public.worker_grant_credits(:'B','adjustment','podcast-b',1000,now()-interval '1 day',null,'Podcast fixture');

-- A converted CC BY paper in A's library (the asset-accounting fixture path).
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0 where singleton;
select public.worker_set_pipeline_enabled(true);
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_begin_import('46000000-0000-0000-0001-000000000001','2410.04601',0);
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'id') as paper,(:'entry'::jsonb->>'generation')::bigint as gen \gset
select public.worker_pipeline_metadata(:'paper',:'claim',:'gen',1,
 '{"title":"Podcast fixture paper","authors":["Ada Fixture","Bo Example"],"abstract":"Testing","published_at":"2024-10-01","categories":["cs.LG"]}',
 true,'https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2410.04601','source_revision',1,'source_url','https://arxiv.org/abs/2410.04601v1',
 'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('a',64),'observed_at','2026-10-07T05:00:00Z'));
select test.assert((public.worker_pipeline_admit_download(:'paper',:'claim',:'gen')->>'admitted')::boolean,'paper admitted');
create or replace function test.complete_plan(p uuid,c uuid,g bigint,k text,objects jsonb,pages integer default null) returns jsonb language plpgsql as $$
declare plan jsonb; row jsonb; upload uuid:=gen_random_uuid(); write uuid;
begin
 plan:=public.worker_pipeline_asset_plan(p,c,g,upload,k,objects,pages);
 for row in select value from jsonb_array_elements(plan->'objects') loop
  if not (row->>'verified')::boolean then
   write:=gen_random_uuid();
   perform test.assert((public.worker_pipeline_asset_write(p,c,g,upload,(row->>'id')::uuid,write)->>'write')::boolean,'fixture paper write');
   perform public.worker_pipeline_asset_written(write,true);
  end if;
 end loop;
 return plan;
end $$;
select test.complete_plan(:'paper',:'claim',:'gen','original',jsonb_build_array(jsonb_build_object('path','originals/'||repeat('5',64)||'.pdf','sha256',repeat('5',64),'bytes',1000,'media_type','application/pdf')),2);
select public.worker_pipeline_original(:'paper',:'claim',:'gen',decode(repeat('5',64),'hex'),1000,2,'originals/'||repeat('5',64)||'.pdf');
select public.worker_pipeline_admit_processing(:'paper',:'claim',:'gen');
select public.worker_pipeline_fund(:'paper',:'claim',:'gen',2,decode(repeat('6',64),'hex'),decode(repeat('7',64),'hex'));
select public.worker_pipeline_begin_submit(:'paper',:'claim',:'gen')->>'attempt_id' as ocr_attempt \gset
select public.worker_pipeline_submitted(:'ocr_attempt','podcast-fixture-job');
select test.complete_plan(:'paper',:'claim',:'gen','raw',jsonb_build_array(
 jsonb_build_object('path','raw/'||repeat('8',64)||'/manifest.json','sha256',repeat('8',64),'bytes',100,'media_type','application/json'),
 jsonb_build_object('path','raw/'||repeat('8',64)||'/standalone.mmd','sha256',repeat('9',64),'bytes',5000,'media_type','text/plain; charset=utf-8'),
 jsonb_build_object('path','raw/'||repeat('8',64)||'/output.mmd.zip','sha256',repeat('b',64),'bytes',100,'media_type','application/zip'),
 jsonb_build_object('path','raw/'||repeat('8',64)||'/lines.json','sha256',repeat('c',64),'bytes',100,'media_type','application/json')));
select public.worker_pipeline_collected(:'paper',:'claim',:'gen',2,decode(repeat('8',64),'hex'),100);
select test.complete_plan(:'paper',:'claim',:'gen','reader',jsonb_build_array(
 jsonb_build_object('path','reader/'||repeat('d',64)||'/manifest.json','sha256',repeat('d',64),'bytes',100,'media_type','application/json'),
 jsonb_build_object('path','reader/'||repeat('d',64)||'/index.html','sha256',repeat('e',64),'bytes',200,'media_type','text/html; charset=utf-8'),
 jsonb_build_object('path','reader/'||repeat('d',64)||'/index.json','sha256',repeat('f',64),'bytes',100,'media_type','application/json')));
select public.worker_pipeline_published(:'paper',:'claim',:'gen',decode(repeat('d',64),'hex'),100,'timestep-mathpix-mathml-v1');
select public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen');
select id as item,document_id as doc,approval_id as approval from app_private.library_items where account_id=:'A' \gset
select test.assert(:'approval' is not null and (select license_uri from app_private.catalog_asset_approvals where id=:'approval')='https://creativecommons.org/licenses/by/4.0/','CC BY approval pinned');

-- Dark by default: no catalog, delivery, generation, seed or fixtures.
select test.assert((select not (catalog_enabled or delivery_enabled or generation_enabled or seed_enabled or fixtures_enabled) from app_private.podcast_policy),'every podcast switch starts off');
select test.assert(not exists(select 1 from app_private.podcast_seed_periods),'no seed allowance exists until configured');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert(public.v1_podcast_catalog(null,20)->'episodes'='[]'::jsonb,'disabled catalog is empty');
select test.assert(not (public.v1_podcast_capabilities()->>'generation')::boolean,'generation unavailable');
select test.reject(format('select public.v1_podcast_quote(%L,gen_random_uuid())',:'item'),'podcast_unavailable');
select test.reject('select public.worker_podcast_status()','permission denied');
select test.reject('select * from app_private.podcast_jobs','permission denied');
reset role;
set role anon;
select test.reject('select public.v1_podcast_catalog(null,20)','permission denied');
reset role;

-- Audited operator policy; enabling paid paths needs scope-3 inventory certification.
select test.reject(format('select public.worker_podcast_policy_set(%L,gen_random_uuid(),%L,%L)',:'A','{"catalog_enabled":true}','Not an owner'),'owner_required');
update app_private.paper_asset_policy set inventory_scope=2 where singleton;
select test.reject(format('select public.worker_podcast_policy_set(%L,gen_random_uuid(),%L,%L)',:'O','{"seed_enabled":true}','Pilot'),'asset_inventory_incomplete');
update app_private.paper_asset_policy set inventory_scope=3 where singleton;
select test.reject(format('select public.worker_podcast_policy_set(%L,gen_random_uuid(),%L,%L)',:'O','{"price":1}','Pilot'),'invalid_podcast_policy');
select public.worker_podcast_policy_set(:'O','46000000-0000-0000-0002-000000000001',
 '{"catalog_enabled":true,"delivery_enabled":true,"generation_enabled":true,"seed_enabled":true,"fixtures_enabled":true}','Local fixture activation');
select test.assert((public.worker_podcast_policy_set(:'O','46000000-0000-0000-0002-000000000001',
 '{"catalog_enabled":true,"delivery_enabled":true,"generation_enabled":true,"seed_enabled":true,"fixtures_enabled":true}','Local fixture activation')->>'replayed')::boolean,'policy replay');
select test.reject(format('select public.worker_podcast_policy_set(%L,%L,%L,%L)',:'O','46000000-0000-0000-0002-000000000001','{"catalog_enabled":false}','Different'),'podcast_policy_id_conflict');
select test.assert((select count(*)=1 from app_private.podcast_policy_events),'one audited policy change');

-- Seed allowance: at most $5 since migration 051 ($2 in 048), created explicitly, inside the platform budget.
select test.reject(format('select public.worker_podcast_seed_period(%L,gen_random_uuid(),%L,5000001,true,%L)',:'O',:'month','owner-decision-20261008'),'invalid_seed_period');
select test.reject(format('select public.worker_podcast_seed_admit(%L,gen_random_uuid(),%L,%L)',:'O',:'approval','Pilot seed before allowance'),'seed_allowance_unavailable');
select public.worker_podcast_seed_period(:'O','46000000-0000-0000-0002-000000000002',:'month',2000000,true,'owner-decision-20261008');
select test.assert((public.worker_podcast_seed_period(:'O','46000000-0000-0000-0002-000000000002',:'month',2000000,true,'owner-decision-20261008')->>'replayed')::boolean,'seed period replay');

select test.assert(exists(select 1 from jsonb_array_elements(public.worker_podcast_seed_candidates(20)) c
 where c->>'approval_id'=:'approval' and (c->>'text_bytes')::bigint=5000 and not (c->>'existing_release')::boolean),'pilot candidates list the eligible conversion');
\set S1 '46000000-0000-0000-0003-000000000001'
select spent_microusd as spent0,reserved_microusd as reserved0 from app_private.platform_budgets where period=:'month' \gset
select public.worker_podcast_seed_admit(:'O',:'S1',:'approval','CC BY 4.0 verified; no third-party exclusions found') as seed \gset
select test.assert((:'seed'::jsonb->>'funding_kind')='platform_seed' and (:'seed'::jsonb->>'seed_committed_microusd')::bigint=750000,'seed admitted at the $0.75 profile hold');
select test.assert((public.worker_podcast_seed_admit(:'O',:'S1',:'approval','CC BY 4.0 verified; no third-party exclusions found')->>'replayed')::boolean,'seed admission replay');
select test.reject(format('select public.worker_podcast_seed_admit(%L,gen_random_uuid(),%L,%L)',:'O',:'approval','Duplicate shared work'),'podcast_job_active');
select test.assert((select credit_ceiling=0 and spend_ceiling_microusd=750000 and kind='podcast' from app_private.metered_operations op join app_private.podcast_jobs j
 on (op.account_id,op.id)=(j.operation_account_id,j.operation_id) where j.id=:'S1'),'operator account, zero customer credits');
select test.assert((select reserved_microusd=:'reserved0'::bigint+750000 from app_private.platform_budgets where period=:'month'),'platform budget reserves the seed ceiling once');
select test.assert((select r.state='active' and r.license_uri='https://creativecommons.org/licenses/by/4.0/' from app_private.podcast_rights r join app_private.podcast_jobs j on j.episode_id=r.episode_id where j.id=:'S1'),'publication rights recorded');
select test.assert((select count(*)=1 and sum(bytes)=20971520 from app_private.podcast_asset_holds where job_id=:'S1'),'storage hold reserved at admission');

-- Worker lifecycle with explicit provider receipts.
create or replace function test.podcast_attempt(j uuid,c uuid,g bigint,route text,cost bigint,state text default 'succeeded') returns uuid language plpgsql as $$
declare attempt uuid:=gen_random_uuid(); admission jsonb;
begin
 admission:=public.worker_podcast_attempt_begin(j,c,g,attempt,route,sha256(convert_to(route||attempt::text,'UTF8')));
 perform test.assert((admission->>'granted')::boolean,'grant '||route||' '||coalesce(admission->>'reason',''));
 if state='unknown' then
  perform public.worker_provider_attempt_finish((admission->>'account_id')::uuid,(admission->>'operation_id')::uuid,attempt,'unknown',null,null,'{}','transport_unknown');
 else
  perform public.worker_provider_attempt_finish((admission->>'account_id')::uuid,(admission->>'operation_id')::uuid,attempt,'succeeded','req_'||left(attempt::text,8),cost,
   case when route='podcast_speech' then '{"text_input_tokens":1500,"audio_output_tokens":7500,"audio_ms":300000}'::jsonb
    else '{"input_tokens":20000,"output_tokens":3000}'::jsonb end,null);
 end if;
 return attempt;
end $$;
create or replace function test.podcast_publish(j uuid,c uuid,g bigint,owner uuid,release_key text) returns jsonb language plpgsql as $$
declare plan jsonb; row jsonb; upload uuid:=gen_random_uuid(); write uuid; prefix text; manifest text:=repeat('3',63)||right(release_key,1);
begin
 prefix:=case when owner is null then 'shared/' else 'private/'||owner::text||'/' end||release_key||'/';
 plan:=public.worker_podcast_asset_plan(j,c,g,upload,jsonb_build_array(
  jsonb_build_object('role','audio','path',prefix||'audio.m4a','sha256',repeat('1',63)||right(release_key,1),'bytes',2400000,'media_type','audio/mp4'),
  jsonb_build_object('role','transcript','path',prefix||'transcript.json','sha256',repeat('2',63)||right(release_key,1),'bytes',20000,'media_type','application/json'),
  jsonb_build_object('role','manifest','path',prefix||'manifest.json','sha256',manifest,'bytes',2000,'media_type','application/json')));
 for row in select value from jsonb_array_elements(plan->'objects') loop
  write:=gen_random_uuid();
  perform test.assert((public.worker_podcast_asset_write(j,c,g,upload,(row->>'id')::uuid,write)->>'write')::boolean,'podcast write grant');
  perform public.worker_podcast_asset_written(write,true);
 end loop;
 return public.worker_podcast_publish(j,c,g,upload,jsonb_build_object('script_sha256',repeat('4',64),'draft_sha256',repeat('5',64),
  'checker_version','podcast-checker-v1','segments',24,'chapters',5,'duration_ms',301000,'manifest_sha256',manifest,
  'identity',jsonb_build_object('script_model','claude-sonnet-5-5','speech_model','gemini-3.8-flash-tts','voices','{"explainer":"Sadaltager","skeptic":"Erinome"}'::jsonb)));
end $$;
select gen_random_uuid() as pc \gset
select public.worker_podcast_claim(:'pc') as job \gset
select test.assert((:'job'::jsonb->>'job_id')=:'S1' and (:'job'::jsonb->'source'->>'path')='raw/'||repeat('8',64)||'/standalone.mmd'
 and (:'job'::jsonb->'source'->>'sha256')=repeat('9',64),'claim pins the exact converted text');
select (:'job'::jsonb->>'generation')::bigint as pg \gset
select test.reject(format('select public.worker_provider_attempt_begin(%L,(select operation_id from app_private.podcast_jobs where id=%L),gen_random_uuid(),%L,%L,%L,sha256(%L),1,%L)',
 :'O',:'S1','anthropic','podcast_script','claude-haiku-4-5','cheap','{"input_tokens":1}'),'podcast_admission_required');
select test.reject(format('select public.worker_podcast_attempt_begin(%L,%L,%s,gen_random_uuid(),%L,sha256(%L))',:'S1',:'pc',:'pg','podcast_review','early'),'invalid_podcast_stage');
select test.reject(format('select public.worker_podcast_attempt_begin(%L,gen_random_uuid(),%s,gen_random_uuid(),%L,sha256(%L))',:'S1',:'pg','podcast_script','stale'),'stale_podcast_claim');
select test.podcast_attempt(:'S1',:'pc',:'pg','podcast_script',150000) as script_attempt \gset
select test.assert((select ceiling_microusd=220000 and reserved_units='{"input_tokens":80000,"output_tokens":6000}'::jsonb and model='claude-sonnet-5-5'
 and pricing_snapshot->>'profile'='podcast-5min-v1:1' from app_private.provider_attempts where id=:'script_attempt'),'profile-derived script ceiling');
select test.assert((public.worker_podcast_attempt_begin(:'S1',:'pc',:'pg',:'script_attempt','podcast_script',sha256('x'))->>'reason')='attempt_replayed','lost acknowledgement never re-grants');
select test.assert((public.worker_podcast_attempt_begin(:'S1',:'pc',:'pg',gen_random_uuid(),'podcast_script',sha256('y'))->>'reason')='route_used','one script call per job');
select public.worker_podcast_advance(:'S1',:'pc',:'pg','checking');
select test.podcast_attempt(:'S1',:'pc',:'pg','podcast_review',120000) as review_attempt \gset
select public.worker_podcast_advance(:'S1',:'pc',:'pg','synthesizing');
select test.podcast_attempt(:'S1',:'pc',:'pg','podcast_speech',140000) as speech_attempt \gset
select test.assert((select provider='google' and ceiling_microusd=303104 and reserved_units='{"text_input_tokens":8192,"audio_output_tokens":16384}'::jsonb
 and pricing_snapshot->>'tariff'='vertex-gemini-3.8-flash-tts-list-20270101' from app_private.provider_attempts where id=:'speech_attempt'),'speech reserved at its full serving limit');
select public.worker_podcast_advance(:'S1',:'pc',:'pg','verifying');
select public.worker_podcast_advance(:'S1',:'pc',:'pg','publishing');
select test.podcast_publish(:'S1',:'pc',:'pg',null,repeat('a',64)) as published \gset
select (:'published'::jsonb->'release'->>'release_id') as rel1 \gset
select test.assert((:'published'::jsonb->'release'->>'state')='pending_review','curated release waits for operator review');
select test.assert((select state='ready' and charged_credits is null from app_private.podcast_jobs where id=:'S1'),'seed job ready, no customer charge');
select test.assert((select op.state='settled' and actual_credits=0 and actual_microusd=410000 from app_private.metered_operations op join app_private.podcast_jobs j
 on (op.account_id,op.id)=(j.operation_account_id,j.operation_id) where j.id=:'S1'),'seed settles known usage, zero credits');
select test.assert((select spent_microusd=:'spent0'::bigint+410000 and reserved_microusd=:'reserved0'::bigint from app_private.platform_budgets where period=:'month'),'platform budget records actual seed spend');
select test.assert(app_private.podcast_seed_committed(:'month')=410000,'seed allowance consumes actual known usage');
select test.assert(not exists(select 1 from app_private.podcast_asset_holds where job_id=:'S1'),'hold replaced by exact inventory');
select test.assert((select count(*)=3 from app_private.stored_objects where bucket='podcast-assets' and state='verified' and document_id=:'doc'),'shared objects inventoried with document identity');
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select test.assert(public.v1_podcast_catalog(null,20)->'episodes'='[]'::jsonb,'pending review is not in the catalog');
select test.assert((public.v1_podcast_states(array[:'rel1'::uuid])->'states'->:'rel1'->>'state')='unavailable','pending review is not discoverable');
reset role;
select test.reject(format('select public.worker_podcast_review(%L,gen_random_uuid(),%L,%L,%L)',:'A',:'rel1','publish','Not owner'),'owner_required');
select public.worker_podcast_review(:'O','46000000-0000-0000-0004-000000000001',:'rel1','publish','Listened end to end; claims match evidence');
select test.assert((public.worker_podcast_review(:'O','46000000-0000-0000-0004-000000000001',:'rel1','publish','Listened end to end; claims match evidence')->>'replayed')::boolean,'review replay');
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select public.v1_podcast_catalog(null,20) as cat \gset
select test.assert(jsonb_array_length(:'cat'::jsonb->'episodes')=1,'published release listed');
select test.assert((:'cat'::jsonb->'episodes'->0->>'title')='Podcast fixture paper' and (:'cat'::jsonb->'episodes'->0->>'year')::integer=2024
 and (:'cat'::jsonb->'episodes'->0->>'duration_ms')::integer=301000 and (:'cat'::jsonb->'episodes'->0->>'ai_audio')::boolean
 and not (:'cat'::jsonb->'episodes'->0->>'fixture')::boolean and (:'cat'::jsonb->'episodes'->0->'source'->>'url')='https://arxiv.org/abs/2410.04601v1'
 and (:'cat'::jsonb->'episodes'->0->'audio'->>'bytes')::bigint=2400000,'public metadata only, with attribution');
select test.assert(not (:'cat'::jsonb::text like '%'||:'O'||'%') and not (:'cat'::jsonb::text like '%shared/%'),'no funder identity or storage path in the catalog');
select test.assert(public.v1_podcast_catalog('1',20)->'episodes'='[]'::jsonb,'keyset cursor');
select test.reject('select public.v1_podcast_catalog(null,51)','invalid_podcast_cursor');
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert((public.v1_podcast_paper(:'item')->'episode'->>'release_id')=:'rel1','paper detail finds the shared episode');
reset role;

-- Bounded delivery: transcript charged before Storage; audio grant single-use.
select public.worker_podcast_release(:'B',:'rel1') as detail \gset
select test.assert((:'detail'::jsonb->'transcript'->>'path')='shared/'||repeat('a',64)||'/transcript.json','episode transcript location for the Edge function');
select test.assert((select authorized_bytes=20000 from app_private.reader_transfer_months where period=:'month' and scope_id=:'B' and kind='podcast'),'transcript transfer charged');
select public.worker_podcast_delivery_create(:'B',:'rel1',sha256('grant-b')) as grant_b \gset
select (:'grant_b'::jsonb->'members'->0->>'id') as audio_object \gset
select test.assert((select reserved_bytes=2400000 from app_private.reader_transfer_months where period=:'month' and scope_id=:'B' and kind='podcast'),'grant reserves the audio bytes');
select test.reject(format('select public.worker_podcast_delivery_redeem(%L,sha256(%L),%L)',:'A','grant-b',:'audio_object'),'podcast_grant_unavailable');
select public.worker_podcast_delivery_redeem(:'B',sha256('grant-b'),:'audio_object') as redeemed \gset
select test.assert((:'redeemed'::jsonb->>'bucket')='podcast-assets' and (:'redeemed'::jsonb->>'bytes')::bigint=2400000,'redeemed exact audio object');
select test.reject(format('select public.worker_podcast_delivery_redeem(%L,sha256(%L),%L)',:'B','grant-b',:'audio_object'),'podcast_grant_consumed');
select public.worker_podcast_delivery_observed((:'redeemed'::jsonb->>'grant_id')::uuid,:'audio_object',2400000,2400000,'response_created');
select public.worker_podcast_delivery_observed((:'redeemed'::jsonb->>'grant_id')::uuid,:'audio_object',2400000,2400000,'response_created');
select test.assert((select reserved_bytes=0 and authorized_bytes=2420000 and response_bytes=2400000 from app_private.reader_transfer_months
 where period=:'month' and scope_id=:'B' and kind='podcast'),'redemption moves reservation to authorized bytes');
select test.assert((select authorized_bytes>=2420000 from app_private.reader_transfer_months where period=:'month' and scope_id='environment' and kind='reader'),'shared environment capacity charged too');
update app_private.podcast_policy set account_transfer_bytes_month=3000000;
select test.reject(format('select public.worker_podcast_delivery_create(%L,%L,sha256(%L))',:'B',:'rel1','grant-b2'),'podcast_transfer_limit');
update app_private.podcast_policy set account_transfer_bytes_month=104857600;

-- Takedown removes catalog visibility and future grants without rewriting history.
select public.worker_podcast_delivery_create(:'B',:'rel1',sha256('grant-b3')) as grant_b3 \gset
select r.episode_id as episode1 from app_private.podcast_releases r where r.id=:'rel1' \gset
select public.worker_podcast_rights(:'O','46000000-0000-0000-0005-000000000001',:'episode1','quarantined','Rights question received');
select test.reject(format('select public.worker_podcast_delivery_redeem(%L,sha256(%L),%L)',:'B','grant-b3',:'audio_object'),'podcast_grant_unavailable');
select test.reject(format('select public.worker_podcast_release(%L,%L)',:'B',:'rel1'),'podcast_release_unavailable');
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select test.assert(public.v1_podcast_catalog(null,20)->'episodes'='[]'::jsonb,'quarantined release hidden');
select test.assert((public.v1_podcast_states(array[:'rel1'::uuid])->'states'->:'rel1'->>'state')='quarantined','cached copy learns quarantine');
reset role;
select public.worker_podcast_rights(:'O','46000000-0000-0000-0005-000000000002',:'episode1','active','Resolved: license confirmed');
select test.assert((select op.state='settled' from app_private.metered_operations op join app_private.podcast_jobs j on (op.account_id,op.id)=(j.operation_account_id,j.operation_id) where j.id=:'S1'),'financial record unchanged by takedown');

-- Private generation: explicit quote, consent, one funding operation, max 150 credits.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
\set R1 '46000000-0000-0000-0006-000000000001'
select (public.v1_credit_balance()->>'available')::integer as avail_a,(public.v1_credit_balance()->>'reserved')::integer as held_a \gset
select public.v1_podcast_quote(:'item',:'R1') as q1 \gset
select test.assert((:'q1'::jsonb->'quote'->>'max_credits')::integer=150 and (:'q1'::jsonb->'quote'->>'estimate') like 'Estimate%maximum 150 credits'
 and (:'q1'::jsonb->'quote'->>'consent_version')='podcast-private-v1','explicit quote with maximum');
select (:'q1'::jsonb->'quote'->>'id') as quote1 \gset
select test.reject(format('select public.v1_podcast_start(%L,%L,%L)',:'quote1',:'R1','cloud-ai-v2'),'consent_required');
select public.v1_podcast_start(:'quote1',:'R1','podcast-private-v1') as st1 \gset
select test.assert((:'st1'::jsonb->'job'->>'state')='queued' and (:'st1'::jsonb->'job'->>'held_credits')::integer=150,'private job queued with a 150-credit hold');
select test.assert(public.v1_podcast_start(:'quote1',:'R1','podcast-private-v1')=:'st1'::jsonb,'start replay returns the same job');
select test.reject(format('select public.v1_podcast_start(gen_random_uuid(),%L,%L)',:'R1','podcast-private-v1'),'podcast_request_conflict');
select test.assert((public.v1_credit_balance()->>'reserved')::integer=:'held_a'::integer+150,'one customer hold');
-- A second device's quote joins the same owner job instead of charging again.
select test.assert(public.v1_podcast_quote(:'item','46000000-0000-0000-0006-000000000002')->'join'->>'request_id'=:'R1','concurrent device joins');
select set_config('request.jwt.claim.sub',:'B',false);
select test.reject(format('select public.v1_podcast_status(%L)',:'R1'),'podcast_request_unavailable');
select set_config('request.jwt.claim.sub',:'A',false);
select public.v1_podcast_cancel(:'R1') as c1 \gset
select test.assert((:'c1'::jsonb->'job'->>'state')='canceled' and (:'c1'::jsonb->'job'->>'charged_credits')::integer=0
 and (:'c1'::jsonb->'job'->>'released_credits')::integer=150,'cancel before submission releases the whole hold');
select test.assert((public.v1_credit_balance()->>'available')::integer=:'avail_a'::integer,'no charge for canceled queued job');
reset role;

-- Private job whose speech outcome is lost: customer refunded, liability retained.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v1_podcast_quote(:'item','46000000-0000-0000-0006-000000000003')->'quote'->>'id' as quote2 \gset
select public.v1_podcast_start(:'quote2','46000000-0000-0000-0006-000000000003','podcast-private-v1')->'job'->>'request_id' as r2 \gset
reset role;
select id as j2 from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select gen_random_uuid() as pc2 \gset
select (public.worker_podcast_claim(:'pc2')->>'generation')::bigint as pg2 \gset
select test.podcast_attempt(:'j2',:'pc2',:'pg2','podcast_script',100000);
select public.worker_podcast_advance(:'j2',:'pc2',:'pg2','checking');
select test.podcast_attempt(:'j2',:'pc2',:'pg2','podcast_review',90000);
select public.worker_podcast_advance(:'j2',:'pc2',:'pg2','synthesizing');
select test.podcast_attempt(:'j2',:'pc2',:'pg2','podcast_speech',0,'unknown');
select test.assert((public.worker_podcast_fail(:'j2',:'pc2',:'pg2','speech_outcome_unknown',false)->>'state')='unknown_provider','unknown speech outcome holds liability');
select test.assert((select actual_credits=0 and actual_microusd=190000 and provider_liability_microusd=303104 from app_private.metered_operations op join app_private.podcast_jobs j
 on (op.account_id,op.id)=(j.operation_account_id,j.operation_id) where j.id=:'j2'),'customer charged nothing; vendor liability retained');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert((public.v1_podcast_status(:'r2')->'job'->>'state')='unknown_provider','status reports the holding state');
select test.assert((public.v1_credit_balance()->>'available')::integer=:'avail_a'::integer and (public.v1_credit_balance()->>'reserved')::integer=:'held_a'::integer,'customer hold released');
-- No overlapping unknown work: the account waits until the outcome is reconciled.
select test.reject(format('select public.v1_podcast_quote(%L,%L)',:'item','46000000-0000-0000-0006-000000000009'),'podcast_outcome_pending');
reset role;
select test.assert((select platform_loss_microusd=190000 and quality_loss_microusd=0 from app_private.podcast_jobs where id=:'j2'),'zero-charge known cost is a platform loss');
select test.assert(app_private.podcast_customer_losses(:'month')=190000+303104,'losses count the held unknown ceiling');
select ja.attempt_id as speech2 from app_private.podcast_job_attempts ja where ja.job_id=:'j2' and ja.route='podcast_speech' \gset
select public.worker_provider_attempt_reconcile(:'O','46000000-0000-0000-0009-000000000001',:'speech2',0,'{"text_input_tokens":0,"audio_output_tokens":0}',
 'vertex-billing-fixture','Provider reports no charge for the lost request');
select test.assert(not app_private.podcast_account_unresolved(:'A'),'reconciled outcome releases the account');

-- Completed private job: actual usage charged within the maximum; owner-only.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v1_podcast_quote(:'item','46000000-0000-0000-0006-000000000004')->'quote'->>'id' as quote3 \gset
select public.v1_podcast_start(:'quote3','46000000-0000-0000-0006-000000000004','podcast-private-v1')->'job'->>'request_id' as r3 \gset
reset role;
select id as j3 from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select gen_random_uuid() as pc3 \gset
select (public.worker_podcast_claim(:'pc3')->>'generation')::bigint as pg3 \gset
select test.podcast_attempt(:'j3',:'pc3',:'pg3','podcast_script',120001);
select public.worker_podcast_advance(:'j3',:'pc3',:'pg3','checking');
select test.podcast_attempt(:'j3',:'pc3',:'pg3','podcast_review',80000);
select public.worker_podcast_advance(:'j3',:'pc3',:'pg3','synthesizing');
select test.podcast_attempt(:'j3',:'pc3',:'pg3','podcast_speech',100000);
select public.worker_podcast_advance(:'j3',:'pc3',:'pg3','verifying');
select public.worker_podcast_advance(:'j3',:'pc3',:'pg3','publishing');
select test.reject(format('select public.worker_podcast_asset_plan(%L,%L,%s,gen_random_uuid(),%L)',:'j3',:'pc3',:'pg3',
 jsonb_build_array(jsonb_build_object('role','audio','path','private/'||:'B'||'/'||repeat('c',64)||'/audio.m4a','sha256',repeat('1',64),'bytes',10,'media_type','audio/mp4'),
  jsonb_build_object('role','transcript','path','private/'||:'B'||'/'||repeat('c',64)||'/transcript.json','sha256',repeat('2',64),'bytes',10,'media_type','application/json'),
  jsonb_build_object('role','manifest','path','private/'||:'B'||'/'||repeat('c',64)||'/manifest.json','sha256',repeat('3',64),'bytes',10,'media_type','application/json'))),'invalid_asset_plan');
select test.podcast_publish(:'j3',:'pc3',:'pg3',:'A',repeat('b',64)) as published3 \gset
select (:'published3'::jsonb->'release'->>'release_id') as rel3 \gset
select test.assert((:'published3'::jsonb->>'charged_credits')::integer=61 and (:'published3'::jsonb->'release'->>'state')='ready'
 and (:'published3'::jsonb->'release'->>'scope')='private','private release ready; 300,001 micro-USD charged as 61 credits');
select test.assert((select count(*)=3 from app_private.stored_objects where bucket='podcast-assets' and owner_id=:'A' and document_id is null),'private objects carry owner identity');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert((public.v1_credit_balance()->>'available')::integer=:'avail_a'::integer-61,'61 credits charged, the rest of the hold released');
select test.assert((public.v1_podcast_paper(:'item')->'episode'->>'release_id')=:'rel3','own private episode preferred on paper detail');
select test.assert(public.v1_podcast_quote(:'item','46000000-0000-0000-0006-000000000005')->'reuse'->>'release_id'=:'rel3','identical private work reuses, zero reservation');
select set_config('request.jwt.claim.sub',:'B',false);
select test.assert(jsonb_array_length(public.v1_podcast_catalog(null,20)->'episodes')=1,'private release never enters the shared catalog');
select test.assert((public.v1_podcast_states(array[:'rel3'::uuid])->'states'->:'rel3'->>'state')='unavailable','no cross-account existence oracle');
reset role;
select test.reject(format('select public.worker_podcast_release(%L,%L)',:'B',:'rel3'),'podcast_release_unavailable');
select test.reject(format('select public.worker_podcast_delivery_create(%L,%L,sha256(%L))',:'B',:'rel3','steal'),'podcast_release_unavailable');
select test.assert((public.worker_podcast_release(:'A',:'rel3')->'episode'->>'scope')='private','owner can open the private episode');

-- Lease expiry: unrecorded attempt becomes unknown; never re-sent automatically.
-- B adds the same shared document: separate private work keys, isolation and recovery.
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select public.v1_set_library_item(:'doc',true);
reset role;
select id as itemb from app_private.library_items where account_id=:'B' and document_id=:'doc' \gset
update app_private.library_items set artifact_id=(select artifact_id from app_private.library_items where id=:'item'),
 approval_id=(select approval_id from app_private.library_items where id=:'item') where id=:'itemb';
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select public.v1_podcast_quote(:'itemb','46000000-0000-0000-0007-000000000001')->'quote'->>'id' as quoteb \gset
select public.v1_podcast_start(:'quoteb','46000000-0000-0000-0007-000000000001','podcast-private-v1')->'job'->>'request_id' as rb \gset
reset role;
select test.assert((select count(distinct k.id)=2 from app_private.podcast_episode_keys k where k.scope='private'),'same bytes, separate private work keys per account');
select id as jb from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select gen_random_uuid() as pcb \gset
select (public.worker_podcast_claim(:'pcb')->>'generation')::bigint as pgb \gset
select public.worker_podcast_attempt_begin(:'jb',:'pcb',:'pgb',gen_random_uuid(),'podcast_script',sha256('crash'));
update app_private.podcast_jobs set lease_until=clock_timestamp()-interval '1 second' where id=:'jb';
select test.reject(format('select public.worker_podcast_advance(%L,%L,%s,%L)',:'jb',:'pcb',:'pgb','checking'),'stale_podcast_claim');
select test.assert((public.worker_podcast_recover()->>'state')='unknown_provider','expired lease with an admitted call becomes unknown');
select test.assert((select pa.state='unknown' and pa.failure_code='worker_interrupted' from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id where ja.job_id=:'jb'),'attempt liability retained');
select test.assert((select op.actual_credits=0 from app_private.metered_operations op join app_private.podcast_jobs j on (op.account_id,op.id)=(j.operation_account_id,j.operation_id) where j.id=:'jb'),'interrupted job charges nothing');
select ja.attempt_id as crashed from app_private.podcast_job_attempts ja where ja.job_id=:'jb' \gset
select public.worker_provider_attempt_reconcile(:'O','46000000-0000-0000-0009-000000000002',:'crashed',0,'{"input_tokens":0,"output_tokens":0}',
 'anthropic-console-fixture','No request reached the provider');

-- Expired lease before any paid call is requeued safely.
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select public.v1_podcast_quote(:'itemb','46000000-0000-0000-0007-000000000002')->'quote'->>'id' as quoteb2 \gset
select public.v1_podcast_start(:'quoteb2','46000000-0000-0000-0007-000000000002','podcast-private-v1')->'job'->>'request_id' as rb2 \gset
reset role;
select id as jb2 from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select gen_random_uuid() as pcb2 \gset
select public.worker_podcast_claim(:'pcb2');
update app_private.podcast_jobs set lease_until=clock_timestamp()-interval '1 second' where id=:'jb2';
select test.assert((public.worker_podcast_recover()->>'state')='queued','no paid work yet: requeued');
-- Restore/epoch rotation fences stale workers and old jobs.
select gen_random_uuid() as pcb3 \gset
select (public.worker_podcast_claim(:'pcb3')->>'generation')::bigint as pgb3 \gset
update app_private.podcast_policy set epoch=gen_random_uuid();
select test.reject(format('select public.worker_podcast_advance(%L,%L,%s,%L)',:'jb2',:'pcb3',:'pgb3','checking'),'podcast_epoch_changed');
update app_private.podcast_jobs set lease_until=clock_timestamp()-interval '1 second' where id=:'jb2';
select public.worker_podcast_recover();
select test.assert((public.worker_podcast_claim(gen_random_uuid())->>'claimed')::boolean is false,'stale-epoch job is not claimed');
select test.assert((select state='failed' and failure_code='podcast_epoch_changed' from app_private.podcast_jobs where id=:'jb2'),'stale-epoch job fails closed');

-- Quality failure: customer charged zero; platform loss pauses new private work at the allocation.
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select public.v1_podcast_quote(:'itemb','46000000-0000-0000-0007-000000000003')->'quote'->>'id' as quoteb3 \gset
select public.v1_podcast_start(:'quoteb3','46000000-0000-0000-0007-000000000003','podcast-private-v1')->'job'->>'request_id' as rb3 \gset
select test.reject(format('select public.v1_podcast_start((select (public.v1_podcast_quote(%L,%L)->''quote''->>''id'')::uuid),%L,%L)',:'itemb','46000000-0000-0000-0007-000000000009','46000000-0000-0000-0007-000000000009','podcast-private-v1'),'podcast_request');
reset role;
select id as jb3 from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select gen_random_uuid() as pcb4 \gset
select (public.worker_podcast_claim(:'pcb4')->>'generation')::bigint as pgb4 \gset
select test.podcast_attempt(:'jb3',:'pcb4',:'pgb4','podcast_script',200000);
select test.assert((public.worker_podcast_fail(:'jb3',:'pcb4',:'pgb4','script_evidence_rejected',true)->>'charged_credits')::integer=0,'rejected script charges the customer zero');
select test.assert((select quality_loss_microusd=200000 from app_private.podcast_jobs where id=:'jb3'),'quality loss recorded separately');
update app_private.podcast_policy set quality_allocation_microusd=150000;
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select public.v1_podcast_quote(:'itemb','46000000-0000-0000-0007-000000000004')->'quote'->>'id' as quoteb4 \gset
select test.reject(format('select public.v1_podcast_start(%L,%L,%L)',:'quoteb4','46000000-0000-0000-0007-000000000004','podcast-private-v1'),'podcast_paused');
reset role;
update app_private.podcast_policy set quality_allocation_microusd=750000;

-- Storage capacity counts podcast holds; a full store refuses before any hold.
update app_private.paper_storage_capacity set max_bytes=(select coalesce(sum(byte_count),0)+1000 from app_private.stored_objects where state<>'deleted');
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select test.reject(format('select public.v1_podcast_start(%L,%L,%L)',:'quoteb4','46000000-0000-0000-0007-000000000005','podcast-private-v1'),'storage_full');
select test.assert((public.v1_credit_balance()->>'reserved')::integer=0,'refused admission leaves no hold');
reset role;
update app_private.paper_storage_capacity set max_bytes=536870912;

-- Provider attempt capacity: a denial that records no attempt row fails the job cleanly.
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select public.v1_podcast_quote(:'itemb','46000000-0000-0000-0007-000000000010')->'quote'->>'id' as quoteb10 \gset
select public.v1_podcast_start(:'quoteb10','46000000-0000-0000-0007-000000000010','podcast-private-v1');
reset role;
select id as jcap from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select gen_random_uuid() as pccap \gset
select (public.worker_podcast_claim(:'pccap')->>'generation')::bigint as pgcap \gset
select test.podcast_attempt(:'jcap',:'pccap',:'pgcap','podcast_script',50000);
select public.worker_podcast_advance(:'jcap',:'pccap',:'pgcap','checking');
update app_private.provider_spending_policy set operation_attempt_limit=1;
select test.assert((public.worker_podcast_attempt_begin(:'jcap',:'pccap',:'pgcap',gen_random_uuid(),'podcast_review',sha256('cap'))->>'reason')='attempt_capacity','capacity denial');
update app_private.provider_spending_policy set operation_attempt_limit=64;
select test.assert((select state='failed' and failure_code='provider_admission_refused' and platform_loss_microusd=50000 from app_private.podcast_jobs where id=:'jcap'),
 'job settles (no foreign-key error); its known cost is a platform loss');

-- Account closing commits before deletion: a queued job is canceled, a running one stops at its next step.
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select public.v1_podcast_quote(:'itemb','46000000-0000-0000-0007-000000000011')->'quote'->>'id' as quoteb11 \gset
select public.v1_podcast_start(:'quoteb11','46000000-0000-0000-0007-000000000011','podcast-private-v1');
reset role;
select id as jq from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select test.assert(public.worker_podcast_account_closing(:'B')=jsonb_build_object('canceled',1,'running',0),'queued job canceled at once');
select test.assert((select state='canceled' and charged_credits=0 from app_private.podcast_jobs where id=:'jq'),'nothing charged');
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select public.v1_podcast_quote(:'itemb','46000000-0000-0000-0007-000000000012')->'quote'->>'id' as quoteb12 \gset
select public.v1_podcast_start(:'quoteb12','46000000-0000-0000-0007-000000000012','podcast-private-v1');
reset role;
select id as jr from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select gen_random_uuid() as pcr \gset
select (public.worker_podcast_claim(:'pcr')->>'generation')::bigint as pgr \gset
select test.assert(public.worker_podcast_account_closing(:'B')=jsonb_build_object('canceled',0,'running',1),'running job asked to stop');
select test.assert((public.worker_podcast_advance(:'jr',:'pcr',:'pgr','checking')->>'canceled')::boolean,'running job stops at its next fenced step');

-- Seed allowance cannot be exceeded; a fixture never shares a seed work key.
select public.worker_podcast_seed_period(:'O','46000000-0000-0000-0002-000000000003',:'month',1000000,true,'owner-lowered-for-test');
select test.reject(format('select public.worker_podcast_seed_admit(%L,gen_random_uuid(),%L,%L)',:'O',:'approval','Second seed over allowance'),'seed_allowance_exhausted');
select public.worker_podcast_seed_period(:'O','46000000-0000-0000-0002-000000000004',:'month',2000000,true,'owner-episode-cap-test',1);
select test.reject(format('select public.worker_podcast_seed_admit(%L,gen_random_uuid(),%L,%L)',:'O',:'approval','Within dollars, over the episode cap'),'seed_episode_limit');
select test.reject(format('select public.worker_podcast_seed_period(%L,gen_random_uuid(),%L,2000000,true,%L,11)',:'O',:'month','eleven-episodes'),'invalid_seed_period');
select public.worker_podcast_seed_admit(:'O','46000000-0000-0000-0003-000000000009',:'approval','Labeled synthetic fixture for staged journeys',true) as fx \gset
select test.assert((:'fx'::jsonb->>'origin')='fixture' and (:'fx'::jsonb->>'operation_id') is null,'fixture job has no paid operation');
select (:'fx'::jsonb->>'id') as fxj \gset
select gen_random_uuid() as pcf \gset
update app_private.paper_asset_policy set reconciliation_id=gen_random_uuid();
select test.assert(public.worker_podcast_claim(gen_random_uuid())->>'reason'='asset_inventory_reconciling','no claim during an inventory scan');
update app_private.paper_asset_policy set reconciliation_id=null;
select (public.worker_podcast_claim(:'pcf')->>'generation')::bigint as pgf \gset
select test.reject(format('select public.worker_podcast_attempt_begin(%L,%L,%s,gen_random_uuid(),%L,sha256(%L))',:'fxj',:'pcf',:'pgf','podcast_script','none'),'invalid_provider_route');
select public.worker_podcast_advance(:'fxj',:'pcf',:'pgf','checking');
select public.worker_podcast_advance(:'fxj',:'pcf',:'pgf','synthesizing');
select public.worker_podcast_advance(:'fxj',:'pcf',:'pgf','verifying');
select public.worker_podcast_advance(:'fxj',:'pcf',:'pgf','publishing');
select test.podcast_publish(:'fxj',:'pcf',:'pgf',null,repeat('f',64)) as fxp \gset
update app_private.podcast_jobs set epoch=gen_random_uuid() where id=:'fxj';
select test.reject(format('select public.worker_podcast_review(%L,gen_random_uuid(),%L,%L,%L)',:'O',:'fxp'::jsonb->'release'->>'release_id','publish','Pre-restore release'),'podcast_epoch_changed');
update app_private.podcast_jobs set epoch=(select epoch from app_private.podcast_policy) where id=:'fxj';
select public.worker_podcast_review(:'O',gen_random_uuid(),(:'fxp'::jsonb->'release'->>'release_id')::uuid,'publish','Fixture visible for staged journey');
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select public.v1_podcast_catalog(null,20) as cat2 \gset
select test.assert(jsonb_array_length(:'cat2'::jsonb->'episodes')=2 and (:'cat2'::jsonb->'episodes'->0->>'fixture')::boolean
 and (:'cat2'::jsonb->'episodes'->0->>'title') like 'Synthetic fixture: %','fixture labeled in the catalog, newest first');
reset role;

-- Cleanup schedules objects of terminal jobs without a release; pending never-written objects close.
select public.worker_podcast_cleanup(50) as cleanup \gset
select test.assert(jsonb_array_length(:'cleanup'::jsonb->'objects')=0,'no orphaned objects in this fixture');

-- An uncertain write keeps capacity and blocks inventory until resolved with evidence.
insert into app_private.stored_objects(id,bucket,path,document_id,sha256,byte_count,media_type)
 values('46000000-0000-0000-000a-000000000001','podcast-assets','shared/'||repeat('9',64)||'/audio.m4a',:'doc',decode(repeat('9',64),'hex'),10,'audio/mp4');
insert into app_private.podcast_asset_uploads(id,job_id,claim_id,claim_generation,request_sha256,release_key)
 values('46000000-0000-0000-000a-000000000002',:'S1',gen_random_uuid(),9,sha256('uncertain'),repeat('9',64));
insert into app_private.podcast_asset_upload_members values('46000000-0000-0000-000a-000000000002','audio','46000000-0000-0000-000a-000000000001');
insert into app_private.podcast_asset_writes(id,upload_id,object_id) values('46000000-0000-0000-000a-000000000003','46000000-0000-0000-000a-000000000002','46000000-0000-0000-000a-000000000001');
select public.worker_set_pipeline_enabled(false);
update app_private.pipeline_papers set claim_id=null,lease_until=null;
select test.reject('select public.worker_asset_inventory_begin(gen_random_uuid())','asset_workers_not_drained');
select test.reject(format('select public.worker_podcast_write_resolve(%L,%L,%L,%L)',:'A','46000000-0000-0000-000a-000000000003','not_written','listing-fixture'),'owner_required');
select test.assert(not (public.worker_podcast_write_resolve(:'O','46000000-0000-0000-000a-000000000003','not_written','storage-listing-fixture')->>'replayed')::boolean,'resolved with evidence');
select test.assert((public.worker_podcast_write_resolve(:'O','46000000-0000-0000-000a-000000000003','not_written','storage-listing-fixture')->>'replayed')::boolean,'resolution replay');
select test.reject(format('select public.worker_podcast_write_resolve(%L,%L,%L,%L)',:'O','46000000-0000-0000-000a-000000000003','verified','listing-fixture'),'podcast_write_conflict');
select public.worker_podcast_cleanup(50) as cleanup2 \gset
select test.assert(:'cleanup2'::jsonb->'objects'->0->>'id'='46000000-0000-0000-000a-000000000001','orphan scheduled for confirmed deletion');
select test.assert(public.worker_podcast_cleanup_confirm(array['46000000-0000-0000-000a-000000000001'::uuid])=1,'deletion confirmed');

-- Inventory scope 3 includes the podcast bucket; scope-2 upload gates still open.
select public.worker_set_pipeline_enabled(false);
update app_private.pipeline_papers set claim_id=null,lease_until=null;
select public.worker_asset_inventory_begin('46000000-0000-0000-0008-000000000001') as scan \gset
select test.assert((:'scan'::jsonb->>'scope')::integer=3 and (:'scan'::jsonb->'buckets') ? 'podcast-assets','scope-3 scan covers podcast audio');
select test.assert(exists(select 1 from jsonb_array_elements(public.worker_asset_inventory_page('46000000-0000-0000-0008-000000000001',null,500)->'objects') o
 where o->>'bucket'='podcast-assets' and o->>'owner_id'=:'A'),'private podcast objects listed with their owner');
select public.worker_asset_inventory_finish('46000000-0000-0000-0008-000000000001',0,0,'{"incomplete":0,"mismatched":0,"missing_verified":0,"unowned":0,"untracked":0}',sha256('report'));
select test.assert((select inventory_scope=3 from app_private.paper_asset_policy),'certified scope 3');
select test.assert((public.worker_pdf_upload_policy(true)->>'enabled')::boolean,'upload gate accepts scope 3');
select public.worker_pdf_upload_policy(false);

-- Account deletion: queued work canceled, personal rows removed, private audio deleted.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
reset role;
select test.assert((select count(*)>0 from app_private.podcast_quotes where account_id=:'A'),'quotes exist before deletion');
select public.worker_podcast_delivery_create(:'A',:'rel1',sha256('a-unredeemed'));
select reserved_bytes as env_reserved from app_private.reader_transfer_months where period=:'month' and scope_id='environment' and kind='podcast' \gset
select public.worker_podcast_account_closing(:'A');
select public.worker_delete_account_begin(:'A') as del \gset
select test.assert((select reserved_bytes=:'env_reserved'::bigint-2400000 from app_private.reader_transfer_months
 where period=:'month' and scope_id='environment' and kind='podcast'),'unredeemed grant released from the environment total');
select test.assert(not exists(select 1 from app_private.reader_transfer_months where scope_id=:'A'),'no account counter re-created');
select test.assert(not exists(select 1 from app_private.podcast_quotes where account_id=:'A') and not exists(select 1 from app_private.podcast_requests where account_id=:'A'),'quotes and requests deleted');
select test.assert((select state='withdrawn' from app_private.podcast_releases where id=:'rel3'),'private release withdrawn');
select test.assert((select count(*)=3 from app_private.stored_objects where bucket='podcast-assets' and owner_id=:'A' and state='deleting'),'private audio scheduled for deletion');
select test.assert(exists(select 1 from jsonb_array_elements(:'del'::jsonb->'objects') o where o->>'bucket'='podcast-assets'),'deletion lists podcast objects');
select public.worker_delete_account_finish(:'A');
select test.assert((select count(*)=3 from app_private.stored_objects where bucket='podcast-assets' and owner_id=:'A' and state='deleted'),'confirmed deletion');
select test.assert((select state='ready' from app_private.podcast_releases where id=:'rel1'),'shared catalog content survives a listener''s deletion');

-- Operator status contains ids and numbers only.
select public.worker_podcast_status() as status \gset
select test.assert((:'status'::jsonb->'jobs'->>'ready')::integer=3 and (:'status'::jsonb->>'inventory_certified')::boolean,'operator status');
select test.reject('delete from app_private.podcast_job_events','immutable_record_requires_compensating_entry');
select test.reject(format('update app_private.podcast_releases set duration_ms=1 where id=%L',:'rel1'),'immutable_podcast_release');
rollback;
