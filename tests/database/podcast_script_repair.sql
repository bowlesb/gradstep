-- Podcast script repair (migration 062, docs/architecture/PAPER_PODCASTS.md): a third script route, granted once per
-- job in `checking` after a succeeded review, refused on a profile without the call; version-3 profiles carry the call
-- and their ceilings add up; speech still proceeds after a repair. Synthetic local SQL; nothing leaves the machine.
-- Runs after the HTML-first cutover migrations (scripts/test-database.py).
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

-- Version 3 of every length exists beside version 2, carries the repair call, and its totals add up.
select test.assert((select count(*)=4 from app_private.podcast_profiles where version=3),'four version-3 profiles');
select test.assert((select count(*)=4 from app_private.podcast_profiles where version=2),'version-2 rows untouched');
select test.assert((select bool_and(
  (select count(*) from jsonb_array_elements(p.spec->'script'->'calls') c)=3
  and (spec->'script'->'calls'->2->>'route')='podcast_script_repair'
  and (spec->'script'->'calls'->2->>'max_output_tokens')::bigint=(spec->'script'->'calls'->0->>'max_output_tokens')::bigint
  and (spec->'script'->'calls'->2->>'max_input_tokens')::bigint=80000+(spec->'script'->'calls'->0->>'max_output_tokens')::bigint+2000
  and (spec->>'ceiling_microusd')::bigint=(select sum((c->>'ceiling_microusd')::bigint) from jsonb_array_elements(p.spec->'script'->'calls') c)+(spec->'speech'->>'ceiling_microusd')::bigint
  and (spec->>'max_credits')::bigint=ceil((spec->>'ceiling_microusd')::numeric/50000)*10
  and (spec->>'hold_microusd')::bigint=(spec->>'max_credits')::bigint*5000
  and ((spec->>'staged')::boolean=(spec->'script'->'calls'->2 ? 'window_seconds')))
 from app_private.podcast_profiles p where version=3),'version-3 call, ceiling, credits and hold arithmetic');
select test.assert((select jsonb_object_agg(id,spec->>'max_credits') from app_private.podcast_profiles where version=3)
 ='{"podcast-short-v1":"180","podcast-5min-v1":"200","podcast-10min-v1":"360","podcast-20min-v1":"610"}'::jsonb,'the version-3 maxima');
select test.assert(position('55–60 credits' in app_private.podcast_estimate((select spec from app_private.podcast_profiles where id='podcast-5min-v1' and version=3)))>0,
 'the measured five-minute estimate holds for version 3');

\set O '62000000-0000-0000-0000-00000000000f'
\set R '62000000-0000-0000-0001-000000000001'
insert into auth.users(id) values(:'O');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);

-- A converted CC BY catalog paper with its exact standalone text (as test_podcast_checker_reports).
create or replace function test.repair_paper(tag text) returns uuid language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid(); appr uuid:=gen_random_uuid();
 run uuid:=gen_random_uuid(); art uuid:=gen_random_uuid(); orig uuid:=gen_random_uuid(); rawm uuid:=gen_random_uuid(); txt uuid:=gen_random_uuid();
 readm uuid:=gen_random_uuid(); raw_digest text:=encode(sha256(convert_to(tag||'-raw','UTF8')),'hex'); reader_digest text:=encode(sha256(convert_to(tag||'-reader','UTF8')),'hex');
 metadata jsonb:=jsonb_build_object('title','Repair fixture '||tag,'authors',jsonb_build_array('R. Fixture'),'published_at','2025-01-02','categories',jsonb_build_array('cs.LG'));
begin
 insert into app_private.publications(id,title) values(pub,'Repair fixture '||tag);
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
  values(meta,ver,'2501.6'||lpad((abs(hashtext(tag))%10000)::text,4,'0'),1,metadata,sha256(convert_to(metadata::text,'UTF8')));
 insert into app_private.catalog_asset_approvals(id,version_id,document_id,metadata_id,original_object_id,license_uri,policy_version,evidence)
  values(appr,ver,doc,meta,orig,'https://creativecommons.org/licenses/by/4.0/','arxiv-reuse-v1','{}');
 insert into app_private.ocr_runs(id,document_id,provider,options_sha256,raw_bundle_object_id) values(run,doc,'mathpix',sha256(convert_to(tag||'-options','UTF8')),rawm);
 insert into app_private.render_artifacts(id,ocr_run_id,renderer_version,manifest_object_id) values(art,run,'podcast-repair-test-v1',readm);
 return appr;
end $$;
-- One paid attempt with an explicit receipt, as the worker records it; returns the admission.
create or replace function test.repair_attempt(j uuid,c uuid,g bigint,route text) returns jsonb language plpgsql as $$
declare attempt uuid:=gen_random_uuid(); admission jsonb;
begin
 admission:=public.worker_podcast_attempt_begin(j,c,g,attempt,route,sha256(convert_to(route||attempt::text,'UTF8')));
 if (admission->>'granted')::boolean then
  perform public.worker_provider_attempt_finish((admission->>'account_id')::uuid,(admission->>'operation_id')::uuid,attempt,'succeeded','req_'||left(attempt::text,8),50000,'{"input_tokens":30000,"output_tokens":2000}'::jsonb,null);
 end if;
 return admission;
end $$;

-- The audited pointer move (053): the five-minute length on version 3, the other lengths with it.
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),'{"seed_enabled":true}','Repair test: seeds on');
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),
 '{"profile_id":"podcast-5min-v1","profile_version":3,"allowed_profiles":["podcast-short-v1:3","podcast-5min-v1:3","podcast-10min-v1:3","podcast-20min-v1:3"]}','Repair test: version 3');
select test.assert((select profile_version=3 and allowed_profiles='{podcast-short-v1:3,podcast-5min-v1:3,podcast-10min-v1:3,podcast-20min-v1:3}' from app_private.podcast_policy where singleton),'pointer on version 3');
select test.assert((select jsonb_agg(l->>'max_credits' order by (l->>'target_seconds')::int) from jsonb_array_elements(app_private.podcast_lengths()) l)='["180","200","360","610"]'::jsonb,'the lengths quote the version-3 maxima');
select public.worker_podcast_seed_period(:'O',gen_random_uuid(),:'month',4000000,true,'owner-decision-20261008',4);

-- A seed job on version 3, claimed by the worker.
select test.repair_paper('one') as approval \gset
select (public.worker_podcast_seed_admit(:'O',:'R',:'approval','CC BY 4.0 verified; repair route test')->>'id') as job \gset
select test.assert((select (app_private.podcast_job_spec(j)->>'version')::int=3 from app_private.podcast_jobs j where j.id=:'job'),'the job runs on version 3');
select '62000000-0000-0000-0002-000000000001' as claim \gset
select (public.worker_podcast_claim(:'claim')->>'generation')::bigint as gen \gset
-- Not before the draft, not before the review.
select test.reject(format('select public.worker_podcast_attempt_begin(%L,%L,%s,gen_random_uuid(),%L,sha256(%L))',:'job',:'claim',:'gen','podcast_script_repair','x'),'invalid_podcast_stage');
select test.assert((test.repair_attempt(:'job',:'claim',:'gen','podcast_script')->>'granted')::boolean,'draft granted');
select public.worker_podcast_advance(:'job',:'claim',:'gen','checking');
select test.reject(format('select public.worker_podcast_attempt_begin(%L,%L,%s,gen_random_uuid(),%L,sha256(%L))',:'job',:'claim',:'gen','podcast_script_repair','y'),'invalid_podcast_stage');
select test.assert((test.repair_attempt(:'job',:'claim',:'gen','podcast_review')->>'granted')::boolean,'review granted');
-- The repair: granted once, at the profile's third call ceiling, under the anthropic provider; a second one is route_used.
select test.repair_attempt(:'job',:'claim',:'gen','podcast_script_repair') as repair \gset
select test.assert((:'repair'::jsonb->>'granted')::boolean and (:'repair'::jsonb->>'provider')='anthropic'
 and (:'repair'::jsonb->>'ceiling_microusd')::bigint=(select (spec->'script'->'calls'->2->>'ceiling_microusd')::bigint from app_private.podcast_profiles where id='podcast-5min-v1' and version=3),'repair granted at its ceiling');
select test.assert((select count(*)=1 and bool_and(pa.route='podcast_script_repair' and pa.state='succeeded') from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id
 where ja.job_id=:'job' and ja.route='podcast_script_repair'),'one repair attempt recorded under its route');
select test.assert((test.repair_attempt(:'job',:'claim',:'gen','podcast_script_repair')->>'reason')='route_used','one repair per job');
-- Speech still follows the review (the repair is optional), and the job's own stage gate is unchanged.
select public.worker_podcast_advance(:'job',:'claim',:'gen','synthesizing');
select test.assert((select state='synthesizing' from app_private.podcast_jobs where id=:'job'),'synthesizing after a repair');
select test.assert(app_private.podcast_route_succeeded(:'job','podcast_review') and app_private.podcast_route_succeeded(:'job','podcast_script_repair'),'route success reads the repair too');

-- A job on version 2 (the pointer moved back) has no repair grant: refused with route_unavailable, never an error.
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),
 '{"profile_id":"podcast-5min-v1","profile_version":2,"allowed_profiles":["podcast-short-v1:2","podcast-5min-v1:2","podcast-10min-v1:2","podcast-20min-v1:2"]}','Repair test: back to version 2');
select test.repair_paper('two') as approval2 \gset
select (public.worker_podcast_seed_admit(:'O','62000000-0000-0000-0001-000000000002',:'approval2','CC BY 4.0 verified; version-2 control')->>'id') as job2 \gset
select '62000000-0000-0000-0002-000000000002' as claim2 \gset
select (public.worker_podcast_claim(:'claim2')->>'generation')::bigint as gen2 \gset
select test.assert((select (app_private.podcast_job_spec(j)->>'version')::int=2 from app_private.podcast_jobs j where j.id=:'job2'),'the control job runs on version 2');
select test.assert((test.repair_attempt(:'job2',:'claim2',:'gen2','podcast_script')->>'granted')::boolean,'control draft granted');
select public.worker_podcast_advance(:'job2',:'claim2',:'gen2','checking');
select test.assert((test.repair_attempt(:'job2',:'claim2',:'gen2','podcast_review')->>'granted')::boolean,'control review granted');
select test.repair_attempt(:'job2',:'claim2',:'gen2','podcast_script_repair') as refused \gset
select test.assert(not (:'refused'::jsonb->>'granted')::boolean and (:'refused'::jsonb->>'reason')='route_unavailable','no repair grant on version 2');
select test.assert((select state='checking' from app_private.podcast_jobs where id=:'job2'),'the refusal does not settle the job');
select test.assert((select count(*)=0 from app_private.podcast_job_attempts where job_id=:'job2' and route='podcast_script_repair'),'no attempt row for the refusal');
select public.worker_podcast_advance(:'job2',:'claim2',:'gen2','synthesizing');
select test.assert((select state='synthesizing' from app_private.podcast_jobs where id=:'job2'),'the version-2 job goes on to speech');
rollback;
