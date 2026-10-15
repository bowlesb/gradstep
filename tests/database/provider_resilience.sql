-- Resilience, server side (migration 073, docs/architecture/RESILIENCE.md): provider health counts and the breaker per
-- provider; fault injection only ever reaches a test account; a podcast refused with a 429 requeues where nothing paid
-- is lost, and nothing else does; the owner's Health tab reads it all. Synthetic local SQL; nothing leaves the machine.
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

-- 1. Counts per hour, provider, route and outcome; nothing about who or what.
select test.assert((public.worker_provider_health('anthropic','chat','ok',120)->>'state')='closed','an ok call: closed');
select public.worker_provider_health('anthropic','chat','ok',80);
select test.assert((select calls=2 and latency_ms_total=200 and latency_ms_max=120 from app_private.provider_health_hours
 where provider='anthropic' and route='chat' and outcome='ok'),'calls and latency add up in the hour');
select test.assert(public.worker_provider_health('Anthropic!','chat','ok',1) is null,'a bad provider name records nothing');
select test.assert(public.worker_provider_health('anthropic','chat','sideways',1) is null,'an unknown outcome records nothing');
select test.assert((select count(*)=1 from app_private.provider_health_hours),'only the valid rows exist');
select test.assert((select array_agg(column_name::text order by column_name) from information_schema.columns
 where table_schema='app_private' and table_name='provider_health_hours')
 ='{calls,hour,latency_ms_max,latency_ms_total,outcome,provider,retry_after_max_s,route}','no column can hold content or an account');

-- 2. The breaker: five failures within a minute open it; client errors and failed-fast calls never count.
select public.worker_provider_health('tavily','chat_search','rejected',10) from generate_series(1,6);
select test.assert((select count(*)=0 from app_private.provider_breakers where provider='tavily' and state='open'),'4xx refusals are not the provider failing');
select public.worker_provider_health('anthropic','chat','throttled',5,30) from generate_series(1,4);
select test.assert((select state='closed' and consecutive_failures=4 from app_private.provider_breakers where provider='anthropic'),'four failures: still closed');
select public.worker_provider_health('anthropic','chat','overloaded',5) as opened \gset
select test.assert((:'opened'::jsonb->>'state')='open','the fifth failure opens it');
select test.assert((select state='open' and open_count=1 and reopen_at between now()+interval '29 seconds' and now()+interval '31 seconds'
 from app_private.provider_breakers where provider='anthropic'),'cools off for 30 seconds first');
select test.assert((select retry_after_max_s=30 from app_private.provider_health_hours where provider='anthropic' and outcome='throttled'),'the largest Retry-After is kept');
select public.worker_provider_health('anthropic','chat','breaker_open',0);
select public.worker_provider_health('anthropic','chat','timeout',5);
select test.assert((select open_count=1 and reopen_at < now()+interval '31 seconds' from app_private.provider_breakers where provider='anthropic'),
 'a straggler failing while open changes nothing');
select test.assert((select jsonb_array_length(public.worker_provider_breakers())=1),'the open breaker is listed');
-- After the cool-off: half open; a failed probe reopens for longer; a success closes.
update app_private.provider_breakers set reopen_at=now()-interval '1 second' where provider='anthropic';
select test.assert((public.worker_provider_health('anthropic','chat','breaker_open',0)->>'state')='half_open','after the cool-off it reads half open');
select public.worker_provider_health('anthropic','chat','server_error',5);
select test.assert((select state='open' and open_count=2 and reopen_at between now()+interval '59 seconds' and now()+interval '61 seconds'
 from app_private.provider_breakers where provider='anthropic'),'a failed probe doubles the cool-off');
update app_private.provider_breakers set reopen_at=now()-interval '1 second' where provider='anthropic';
select test.assert((public.worker_provider_health('anthropic','chat','ok',90)->>'state')='closed','a successful probe closes it');
select test.assert((select state='closed' and consecutive_failures=0 and open_count=0 and reopen_at is null from app_private.provider_breakers where provider='anthropic'),'closed and reset');
-- Failures more than a minute apart never add up.
select public.worker_provider_health('deepseek','podcast','timeout',5) from generate_series(1,4);
update app_private.provider_breakers set last_failure_at=now()-interval '2 minutes' where provider='deepseek';
select public.worker_provider_health('deepseek','podcast','timeout',5);
select test.assert((select state='closed' and consecutive_failures=1 from app_private.provider_breakers where provider='deepseek'),'a quiet minute starts the count again');
-- The cool-off never passes five minutes.
update app_private.provider_breakers set open_count=9, consecutive_failures=4, last_failure_at=now() where provider='deepseek';
select public.worker_provider_health('deepseek','podcast','timeout',5);
select test.assert((select reopen_at <= now()+interval '300 seconds' from app_private.provider_breakers where provider='deepseek'),'at most five minutes');

-- 3. Grants: the worker writes, nobody else reads or writes.
select test.assert(not has_function_privilege('authenticated','public.worker_provider_health(text,text,text,integer,integer,boolean)','execute'),'readers cannot record');
select test.assert(not has_function_privilege('anon','public.worker_provider_breakers()','execute'),'nor read breakers');
select test.assert(has_function_privilege('service_role','public.worker_provider_health(text,text,text,integer,integer,boolean)','execute'),'the worker records');
-- A drill's synthetic failures are counted apart and never open a breaker (a test account can't pause a provider).
select public.worker_provider_health('tavily','chat','throttled',1,5,true) from generate_series(1,8);
select test.assert((select calls=8 from app_private.provider_health_hours where provider='tavily' and route='drill' and outcome='throttled'),'drills counted under drill');
select test.assert(not exists(select 1 from app_private.provider_breakers where provider='tavily' and (state='open' or consecutive_failures>0)),'drills never move the breaker');
select test.assert(exists(select 1 from jsonb_array_elements(public.worker_provider_health_recent(10)) r where r->>'route'='drill' and (r->>'calls')::int=8),'the drill reads its rows back');
select test.assert(not has_table_privilege('authenticated','app_private.provider_health_hours','select'),'no table access');

-- 4. Fault injection: one test account, at most an hour, every row kept.
\set T '73000000-0000-0000-0000-00000000000a'
\set U '73000000-0000-0000-0000-00000000000b'
\set O '73000000-0000-0000-0000-00000000000f'
insert into auth.users(id,email) values(:'T','gradstep-smoke-drill@example.invalid'),(:'U','reader@gradstep.test.org'),(:'O','owner@gradstep.test.org');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select test.reject(format('select public.worker_fault_injection_set(%L,%L,%L,%L,1,5,%L)',:'U','anthropic','chat','throttle','drill on a reader'),'fault_target_not_test_account');
select test.reject(format('select public.worker_fault_injection_set(%L,%L,%L,%L,1,61,%L)',:'T','anthropic','chat','throttle','too long'),'invalid_fault');
select test.reject(format('select public.worker_fault_injection_set(%L,%L,%L,%L,1,5,%L)',:'T','anthropic','chat','explode','bad mode'),'fault_injection_mode_check');
select public.worker_fault_injection_set(:'T','anthropic','chat','throttle',1,5,'Drill: chat answers when Anthropic throttles');
select test.assert((select jsonb_array_length(public.worker_fault_injection_active(:'T'))=1
 and public.worker_fault_injection_active(:'T')->0->>'mode'='throttle'),'the test account sees its fault');
-- A row for a real reader (written directly, bypassing the rule) is never honoured.
insert into app_private.fault_injection(account_id,provider,mode,until,set_by,reason) values(:'U','anthropic','error',now()+interval '5 minutes','script','direct write');
select test.assert(public.worker_fault_injection_active(:'U')='[]'::jsonb,'a real reader is never faulted');
select test.assert(public.worker_fault_injection_clear(:'T')=1,'cleared');
select test.assert(public.worker_fault_injection_active(:'T')='[]'::jsonb and (select count(*)=2 from app_private.fault_injection),'cleared, kept as the record');
-- The owner's path is audited.
select set_config('request.jwt.claim.sub',:'O',false);
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject(format('select public.v1_admin_fault_injection_set(%L,%L,null,%L,1,5,%L)',:'T','google','overload','owner drill'),'owner_mfa_required');
select set_config('request.jwt.claim.aal','aal2',false);
select public.v1_admin_fault_injection_set(:'T','google',null,'overload',0.5,10,'Owner drill: voices overloaded');
select test.assert((select count(*)=1 from app_private.admin_audit_events where action='fault_injection_set' and target_id=:'T'),'audited');
select test.assert(not has_function_privilege('authenticated','public.worker_fault_injection_set(uuid,text,text,text,numeric,integer,text)','execute'),'readers cannot set faults');

-- 5. The Health tab: providers' errors per day, the last hour, open breakers; the hourly table.
select public.worker_provider_health('google','podcast','throttled',5) from generate_series(1,5);
select public.v1_admin_health(7) as h \gset
select test.assert((:'h'::jsonb->'providers'->'daily'->-1->'by_provider'->'anthropic'->>'throttled')::int=4,'throttled per day');
select test.assert((:'h'::jsonb->'providers'->'daily'->-1->'by_provider'->'anthropic'->>'failed')::int=3,'failed per day (overloaded, timeout, server error)');
select test.assert(jsonb_array_length(:'h'::jsonb->'providers'->'daily')=7,'zero-filled days');
select test.assert(exists(select 1 from jsonb_array_elements(:'h'::jsonb->'providers'->'breakers') b where b->>'provider'='google' and b->>'state'='open'),'the open breaker is on the tab');
select test.assert(exists(select 1 from jsonb_array_elements(:'h'::jsonb->'providers'->'last_hour') r where r->>'provider'='anthropic' and (r->>'calls')::int>=10),'the last hour');
select test.assert((:'h'::jsonb ? 'people') and (:'h'::jsonb ? 'money'),'the earlier sections are unchanged');
select test.assert(jsonb_array_length(public.v1_admin_provider_hours(24))>=4,'the hourly table');
select test.assert(not exists(select 1 from jsonb_array_elements(public.v1_admin_provider_hours(24)) r where r->>'provider'='tavily' and (r->>'throttled')::int>0),'drills stay out of the admin views');
select test.reject('select public.v1_admin_provider_hours(0)','invalid_metrics_window');
select set_config('request.jwt.claim.sub',:'U',false);
select test.reject('select public.v1_admin_provider_hours(24)','owner_mfa_required');
select set_config('request.jwt.claim.sub','',false);
rollback;

-- 6. Podcasts: a 429 requeues where nothing paid is lost; anything else still fails. (A separate transaction: the
-- fixture below builds its own catalog paper, as tests/database/podcast_script_repair.sql does.)
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
\set O '73000000-0000-0000-0000-0000000000ff'
insert into auth.users(id) values(:'O');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);
create or replace function test.requeue_paper(tag text) returns uuid language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid(); appr uuid:=gen_random_uuid();
 run uuid:=gen_random_uuid(); art uuid:=gen_random_uuid(); orig uuid:=gen_random_uuid(); rawm uuid:=gen_random_uuid(); txt uuid:=gen_random_uuid();
 readm uuid:=gen_random_uuid(); raw_digest text:=encode(sha256(convert_to(tag||'-raw','UTF8')),'hex'); reader_digest text:=encode(sha256(convert_to(tag||'-reader','UTF8')),'hex');
 metadata jsonb:=jsonb_build_object('title','Requeue fixture '||tag,'authors',jsonb_build_array('R. Fixture'),'published_at','2025-01-02','categories',jsonb_build_array('cs.LG'));
begin
 insert into app_private.publications(id,title) values(pub,'Requeue fixture '||tag);
 insert into app_private.publication_versions(id,publication_id,source,revision) values(ver,pub,'arxiv','1');
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
  values(meta,ver,'2501.7'||lpad((abs(hashtext(tag))%10000)::text,4,'0'),1,metadata,sha256(convert_to(metadata::text,'UTF8')));
 insert into app_private.catalog_asset_approvals(id,version_id,document_id,metadata_id,original_object_id,license_uri,policy_version,evidence)
  values(appr,ver,doc,meta,orig,'https://creativecommons.org/licenses/by/4.0/','arxiv-reuse-v1','{}');
 insert into app_private.ocr_runs(id,document_id,provider,options_sha256,raw_bundle_object_id) values(run,doc,'mathpix',sha256(convert_to(tag||'-options','UTF8')),rawm);
 insert into app_private.render_artifacts(id,ocr_run_id,renderer_version,manifest_object_id) values(art,run,'podcast-requeue-test-v1',readm);
 return appr;
end $$;
-- One paid attempt finished as the worker would: succeeded, rejected (with its HTTP code) or unknown.
create or replace function test.attempt(j uuid,c uuid,g bigint,route text,state text,failure text default null) returns jsonb language plpgsql as $$
declare attempt uuid:=gen_random_uuid(); admission jsonb;
begin
 admission:=public.worker_podcast_attempt_begin(j,c,g,attempt,route,sha256(convert_to(route||attempt::text,'UTF8')));
 if (admission->>'granted')::boolean then
  perform public.worker_provider_attempt_finish((admission->>'account_id')::uuid,(admission->>'operation_id')::uuid,attempt,state,
   case when state='rejected' then null else 'req_'||left(attempt::text,8) end,case when state='succeeded' then 50000 when state='rejected' then 0 end,
   case when state='succeeded' then '{"input_tokens":30000,"output_tokens":2000}'::jsonb else '{}'::jsonb end,failure);
 end if;
 return admission;
end $$;
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),'{"seed_enabled":true}','Requeue test: seeds on');
select public.worker_podcast_seed_period(:'O',gen_random_uuid(),:'month',4000000,true,'owner-decision-20261008',8);

-- (a) The draft was refused with a 429: requeued after about a minute, the route free again, the refusal kept.
select test.requeue_paper('one') as approval \gset
select (public.worker_podcast_seed_admit(:'O','73000000-0000-0000-0001-000000000001',:'approval','CC BY 4.0 verified; requeue test')->>'id') as job \gset
select '73000000-0000-0000-0002-000000000001' as claim \gset
select (public.worker_podcast_claim(:'claim')->>'generation')::bigint as gen \gset
select test.attempt(:'job',:'claim',:'gen','podcast_script','rejected','http_429') as refused \gset
select public.worker_podcast_requeue(:'job',:'claim',:'gen','script_rejected') as requeued \gset
select test.assert((:'requeued'::jsonb->>'requeued')::boolean and :'requeued'::jsonb->>'state'='queued','requeued to the queue');
select test.assert((select retry_at between now()+interval '47 seconds' and now()+interval '73 seconds' and transient_retries=1 and claim_id is null and finished_at is null
 from app_private.podcast_jobs where id=:'job'),'waits about a minute, unclaimed and unfinished');
select test.assert((select count(*)=0 from app_private.podcast_job_attempts where job_id=:'job'),'the refused attempt is unlinked');
select test.assert((select state='rejected' and coalesce(actual_microusd,0)=0 from app_private.provider_attempts where id=(:'refused'::jsonb->>'attempt_id')::uuid),
 'its zero-cost record stays');
select test.assert((select count(*)>=2 from app_private.podcast_job_events where job_id=:'job' and kind in ('transient_refusal','retry_scheduled')),'the job says why');
select test.assert(not (public.worker_podcast_claim('73000000-0000-0000-0002-000000000002')->>'claimed')::boolean,'not claimed before its time');
select test.assert((public.worker_podcast_kick_retries()->>'due')::int=0,'nothing due yet');
update app_private.podcast_jobs set retry_at=clock_timestamp()-interval '1 second' where id=:'job';
select test.assert((public.worker_podcast_kick_retries()->>'due')::int=1,'due now: the minute schedule wakes the worker');
select '73000000-0000-0000-0002-000000000003' as claim2 \gset
select (public.worker_podcast_claim(:'claim2')->>'generation')::bigint as gen2 \gset
select test.assert((select claim_id=:'claim2'::uuid from app_private.podcast_jobs where id=:'job'),'claimed again once due');
select test.assert((test.attempt(:'job',:'claim2',:'gen2','podcast_script','succeeded')->>'granted')::boolean,'the draft can be bought now');

-- (b) A 400 is not transient: no requeue (the worker then fails the job as before).
select test.requeue_paper('two') as approval2 \gset
select (public.worker_podcast_seed_admit(:'O','73000000-0000-0000-0001-000000000002',:'approval2','CC BY 4.0 verified; requeue test two')->>'id') as job2 \gset
select '73000000-0000-0000-0002-000000000004' as claim4 \gset
select (public.worker_podcast_claim(:'claim4')->>'generation')::bigint as gen4 \gset
select test.attempt(:'job2',:'claim4',:'gen4','podcast_script','rejected','http_400');
select test.assert(public.worker_podcast_requeue(:'job2',:'claim4',:'gen4','script_rejected')->>'reason'='not_transient','a 400 stays a failure');
select test.assert((select count(*)=1 from app_private.podcast_job_attempts where job_id=:'job2'),'and its attempt stays linked');
select public.worker_podcast_fail(:'job2',:'claim4',:'gen4','script_rejected',false);

-- (c) An unknown outcome (a 5xx or timeout may have been processed and billed) is never re-sent.
select test.requeue_paper('three') as approval3 \gset
select (public.worker_podcast_seed_admit(:'O','73000000-0000-0000-0001-000000000003',:'approval3','CC BY 4.0 verified; requeue test three')->>'id') as job3 \gset
select '73000000-0000-0000-0002-000000000005' as claim5 \gset
select (public.worker_podcast_claim(:'claim5')->>'generation')::bigint as gen5 \gset
select test.attempt(:'job3',:'claim5',:'gen5','podcast_script','unknown','http_503');
select test.assert(public.worker_podcast_requeue(:'job3',:'claim5',:'gen5','script_rejected')->>'reason'='outcome_unknown','unknown outcomes are not requeued');
select public.worker_podcast_fail(:'job3',:'claim5',:'gen5','script_outcome_unknown',false);

-- (d) A paid draft then a refused review on a single-request profile: requeueing would re-buy the draft, so no; the
-- unlinking is undone.
select test.requeue_paper('four') as approval4 \gset
select (public.worker_podcast_seed_admit(:'O','73000000-0000-0000-0001-000000000004',:'approval4','CC BY 4.0 verified; requeue test four')->>'id') as job4 \gset
select '73000000-0000-0000-0002-000000000006' as claim6 \gset
select (public.worker_podcast_claim(:'claim6')->>'generation')::bigint as gen6 \gset
select test.attempt(:'job4',:'claim6',:'gen6','podcast_script','succeeded');
select public.worker_podcast_advance(:'job4',:'claim6',:'gen6','checking');
select test.attempt(:'job4',:'claim6',:'gen6','podcast_review','rejected','http_429');
select test.assert((select coalesce((app_private.podcast_job_spec(j)->>'staged')::boolean,false)=false from app_private.podcast_jobs j where j.id=:'job4'),'a single-request profile');
select test.assert(public.worker_podcast_requeue(:'job4',:'claim6',:'gen6','script_rejected')->>'reason'='not_resumable','paid work is never re-bought');
select test.assert((select count(*)=2 from app_private.podcast_job_attempts where job_id=:'job4'),'nothing was unlinked');
select test.assert((select transient_retries=0 and retry_at is null from app_private.podcast_jobs where id=:'job4'),'and nothing scheduled');

-- (e) Four requeues at most, each waiting longer.
update app_private.podcast_jobs set transient_retries=4 where id=:'job';
select public.worker_podcast_advance(:'job',:'claim2',:'gen2','checking');
select test.attempt(:'job',:'claim2',:'gen2','podcast_review','rejected','http_429');
select test.assert(public.worker_podcast_requeue(:'job',:'claim2',:'gen2','script_rejected')->>'reason' in ('retries_exhausted','not_resumable'),'retries end');
select test.assert(not has_function_privilege('authenticated','public.worker_podcast_requeue(uuid,uuid,bigint,text)','execute'),'the worker alone requeues');
rollback;
