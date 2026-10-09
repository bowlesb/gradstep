-- Checker reports (migration 050): the worker records a bounded, text-free report as a `checked`
-- job event under its fenced claim, before settlement; the operator reads a job's event log.
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

\set O '50000000-0000-0000-0000-00000000000f'
\set R '50000000-0000-0000-0001-000000000001'
insert into auth.users(id) values(:'O');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);

-- A converted CC BY catalog paper with its exact standalone text (direct fixture rows, as in test_podcast_seed_episodes).
create or replace function test.report_paper() returns uuid language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid(); appr uuid:=gen_random_uuid();
 run uuid:=gen_random_uuid(); art uuid:=gen_random_uuid(); orig uuid:=gen_random_uuid(); rawm uuid:=gen_random_uuid(); txt uuid:=gen_random_uuid();
 readm uuid:=gen_random_uuid(); raw_digest text:=encode(sha256(convert_to('report-raw','UTF8')),'hex'); reader_digest text:=encode(sha256(convert_to('report-reader','UTF8')),'hex');
 metadata jsonb:=jsonb_build_object('title','Checker report fixture','authors',jsonb_build_array('R. Fixture'),'published_at','2025-01-02','categories',jsonb_build_array('cs.LG'));
begin
 insert into app_private.publications(id,title) values(pub,'Checker report fixture');
 insert into app_private.publication_versions(id,publication_id,source,revision) values(ver,pub,'arxiv','1');
 insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
  values(doc,sha256(convert_to('report-document','UTF8')),'shared_catalog','{"license":"CC-BY-4.0"}',1000,2);
 insert into app_private.version_documents values(ver,doc);
 insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values
  (orig,'paper-assets','originals/'||encode(sha256(convert_to('report-original','UTF8')),'hex')||'.pdf',doc,'verified',sha256(convert_to('report-original','UTF8')),1000,'application/pdf',now()),
  (rawm,'paper-assets','raw/'||raw_digest||'/manifest.json',doc,'verified',decode(raw_digest,'hex'),100,'application/json',now()),
  (txt,'paper-assets','raw/'||raw_digest||'/standalone.mmd',doc,'verified',sha256(convert_to('report-text','UTF8')),5000,'text/plain',now()),
  (readm,'paper-assets','reader/'||reader_digest||'/manifest.json',doc,'verified',decode(reader_digest,'hex'),100,'application/json',now());
 insert into app_private.paper_asset_manifest_members values(rawm,txt,'standalone.mmd');
 insert into app_private.catalog_metadata(id,version_id,source_id,source_revision,metadata,metadata_sha256)
  values(meta,ver,'2501.50001',1,metadata,sha256(convert_to(metadata::text,'UTF8')));
 insert into app_private.catalog_asset_approvals(id,version_id,document_id,metadata_id,original_object_id,license_uri,policy_version,evidence)
  values(appr,ver,doc,meta,orig,'https://creativecommons.org/licenses/by/4.0/','arxiv-reuse-v1','{}');
 insert into app_private.ocr_runs(id,document_id,provider,options_sha256,raw_bundle_object_id) values(run,doc,'mathpix',sha256(convert_to('report-options','UTF8')),rawm);
 insert into app_private.render_artifacts(id,ocr_run_id,renderer_version,manifest_object_id) values(art,run,'podcast-report-test-v1',readm);
 return appr;
end $$;
select test.report_paper() as approval \gset
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),'{"seed_enabled":true}','Checker reports (050 test)');
select public.worker_podcast_seed_period(:'O',gen_random_uuid(),:'month',2000000,true,'owner-decision-20261008',2);

-- Privileges: the recorder and the read view are for the service role only; the validator is internal.
select test.assert((select bool_and(has_function_privilege('service_role',p.oid,'execute') and not has_function_privilege('authenticated',p.oid,'execute')
 and not has_function_privilege('anon',p.oid,'execute') and p.prosecdef and p.proconfig=array['search_path=""'])
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('worker_podcast_checked','worker_podcast_job_events')),
 'recorder and read view: security definer, empty search_path, service role only');
select test.assert((select not has_function_privilege('service_role',p.oid,'execute') and not has_function_privilege('authenticated',p.oid,'execute')
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and p.proname='podcast_report_valid'),'validator is internal');

-- One paid attempt with an explicit receipt, as the worker records it.
create or replace function test.report_attempt(j uuid,c uuid,g bigint,route text,cost bigint,units jsonb) returns void language plpgsql as $$
declare attempt uuid:=gen_random_uuid(); admission jsonb;
begin
 admission:=public.worker_podcast_attempt_begin(j,c,g,attempt,route,sha256(convert_to(route||attempt::text,'UTF8')));
 perform test.assert((admission->>'granted')::boolean,'grant '||route);
 perform public.worker_provider_attempt_finish((admission->>'account_id')::uuid,(admission->>'operation_id')::uuid,attempt,'succeeded','req_'||left(attempt::text,8),cost,units,null);
end $$;

-- A seed job, claimed by the worker: draft and review billed (the staging units), then the checker runs.
select (public.worker_podcast_seed_admit(:'O',:'R',:'approval','CC BY 4.0 verified; no third-party exclusions found')->>'id') as job \gset
select '50000000-0000-0000-0002-000000000001' as claim \gset
select (public.worker_podcast_claim(:'claim')->>'generation')::bigint as gen \gset
select test.report_attempt(:'job',:'claim',:'gen','podcast_script',107134,'{"input_tokens":32257,"output_tokens":4262}'::jsonb);
select public.worker_podcast_advance(:'job',:'claim',:'gen','checking');
select test.report_attempt(:'job',:'claim',:'gen','podcast_review',82052,'{"input_tokens":37036,"output_tokens":798}'::jsonb);

-- The report of a rejected script (the shape podcast-script.ts's CheckReport serializes to).
select '{"checker":"podcast-checker-v3","stage":"checker","outcome":"rejected","segments":{"checked":26,"kept":17,"removed":9},
 "removed":{"number_not_in_evidence":5,"evidence_missing":4},"evidence":{"checked":18,"verified":11,"unverified":7,"excess":0,"spans":10},
 "unverified":{"not_found":6,"math_only":1},"repaired":{"formatting":4,"escapes":2},"math":{"checked":2,"dropped":1},"words":512,"spoken_characters":3010,
 "rules":["evidence_unverified_share","segments_removed_share","chapter_unsupported:c3"],
 "items":[{"segment":"s11","item":0,"reason":"not_found","chars":132,"canonical":108,"matched":66,"offset":1429}],
 "removals":[{"segment":"s13","reason":"number_not_in_evidence"}]}' as report \gset
select test.assert((public.worker_podcast_checked(:'job',:'claim',:'gen',:'report'::jsonb)->>'recorded')::boolean,'a valid report is recorded');
select test.assert((select details=:'report'::jsonb from app_private.podcast_job_events where job_id=:'job' and kind='checked'),'recorded exactly as sent');

-- No free text, ever: prose, capitals, spaces, long strings, odd keys, deep, wide or oversized structures, null and non-objects are refused.
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,%L)',:'job',:'claim',:'gen','{"checker":"podcast-checker-v3","rules":["Sparse routing reaches 41.2 perplexity"]}'),'invalid_podcast_report');
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,%L)',:'job',:'claim',:'gen','{"checker":"podcast-checker-v3","note":"Contains Capitals"}'),'invalid_podcast_report');
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,%L)',:'job',:'claim',:'gen','{"checker":"podcast-checker-v3","note":"two words"}'),'invalid_podcast_report');
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,%L)',:'job',:'claim',:'gen',jsonb_build_object('rules',jsonb_build_array(repeat('a',65)))),'invalid_podcast_report');
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,%L)',:'job',:'claim',:'gen','{"The quote":1}'),'invalid_podcast_report');
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,%L)',:'job',:'claim',:'gen','{"a":{"b":{"c":{"d":{"e":{"f":1}}}}}}'),'invalid_podcast_report');
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,%L)',:'job',:'claim',:'gen',jsonb_build_object('items',(select jsonb_agg(n) from generate_series(1,51) n))),'invalid_podcast_report');
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,%L)',:'job',:'claim',:'gen',jsonb_build_object('items',(select jsonb_agg(jsonb_build_object('segment','s'||n,'reason','number_not_in_evidence','offset',n*1000)) from generate_series(1,50) n))),'invalid_podcast_report');
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,%L)',:'job',:'claim',:'gen','{"checker":null}'),'invalid_podcast_report');
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,%L)',:'job',:'claim',:'gen','["podcast-checker-v3"]'),'invalid_podcast_report');
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,null)',:'job',:'claim',:'gen'),'invalid_podcast_report');
-- Only the job's current claim may record.
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,%L)',:'job',gen_random_uuid(),:'gen','{"checker":"podcast-checker-v3","rules":[]}'),'stale_podcast_claim');
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,%L)',:'job',:'claim',:'gen'::bigint+1,'{"checker":"podcast-checker-v3","rules":[]}'),'stale_podcast_claim');
select test.assert((select count(*)=1 from app_private.podcast_job_events where job_id=:'job' and kind='checked'),'refused reports leave no event');

-- The worker then fails the job: the report precedes the settlement in the job's event log.
select test.assert((public.worker_podcast_fail(:'job',:'claim',:'gen','script_evidence_rejected',true)->>'state')='failed','quality failure settles');
select test.assert((select array_agg(kind order by id) from app_private.podcast_job_events where job_id=:'job' and kind in ('checked','settled'))=array['checked','settled'],
 'checked, then settled');
select test.reject(format('select public.worker_podcast_checked(%L,%L,%s,%L)',:'job',:'claim',:'gen','{"checker":"podcast-checker-v3","rules":[]}'),'stale_podcast_claim');

-- The operator's read view: the whole bounded log, state and failure code; unknown jobs read as null.
select public.worker_podcast_job_events(:'job') as events \gset
select test.assert((:'events'::jsonb->>'state')='failed' and (:'events'::jsonb->>'failure')='script_evidence_rejected','state and failure code');
select test.assert((select array_agg(e->>'kind' order by (e->>'id')::bigint) from jsonb_array_elements(:'events'::jsonb->'events') e)
 =array['admitted','claimed','attempt','stage','attempt','checked','settled'],'full event log in order');
select test.assert((select (e->'details'->'segments'->>'removed')::integer=9 from jsonb_array_elements(:'events'::jsonb->'events') e where e->>'kind'='checked'),'report readable');
select test.assert(public.worker_podcast_job_events(gen_random_uuid()) is null,'unknown job');

rollback;
