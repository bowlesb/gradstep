-- Seed episode cap (migration 049): failed seed jobs are not episodes; in-flight jobs and
-- releases awaiting review or published are. The $2 dollar cap (committed spend, including
-- failed jobs' actual usage and unresolved ceilings, plus the next hold) stays binding.
-- Synthetic local SQL with explicit provider receipts at the staging pilot's units; each
-- phase starts from the same savepoint. Nothing leaves the machine.
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

\set O '49000000-0000-0000-0000-00000000000f'
insert into auth.users(id) values(:'O');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);

-- A converted CC BY catalog paper with its exact standalone text (direct fixture rows, as in the worker journey).
create or replace function test.seed_paper(n integer) returns uuid language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid(); appr uuid:=gen_random_uuid();
 run uuid:=gen_random_uuid(); art uuid:=gen_random_uuid(); orig uuid:=gen_random_uuid(); rawm uuid:=gen_random_uuid(); txt uuid:=gen_random_uuid();
 readm uuid:=gen_random_uuid(); raw_digest text:=encode(sha256(convert_to('raw'||n,'UTF8')),'hex'); reader_digest text:=encode(sha256(convert_to('reader'||n,'UTF8')),'hex');
 metadata jsonb:=jsonb_build_object('title','Seed fixture paper '||n,'authors',jsonb_build_array('S. Fixture'),'published_at','2025-01-02','categories',jsonb_build_array('cs.LG'));
begin
 insert into app_private.publications(id,title) values(pub,'Seed fixture paper '||n);
 insert into app_private.publication_versions(id,publication_id,source,revision) values(ver,pub,'arxiv','1');
 insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
  values(doc,sha256(convert_to('document'||n,'UTF8')),'shared_catalog','{"license":"CC-BY-4.0"}',1000,2);
 insert into app_private.version_documents values(ver,doc);
 insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values
  (orig,'paper-assets','originals/'||encode(sha256(convert_to('original'||n,'UTF8')),'hex')||'.pdf',doc,'verified',sha256(convert_to('original'||n,'UTF8')),1000,'application/pdf',now()),
  (rawm,'paper-assets','raw/'||raw_digest||'/manifest.json',doc,'verified',decode(raw_digest,'hex'),100,'application/json',now()),
  (txt,'paper-assets','raw/'||raw_digest||'/standalone.mmd',doc,'verified',sha256(convert_to('text'||n,'UTF8')),5000,'text/plain',now()),
  (readm,'paper-assets','reader/'||reader_digest||'/manifest.json',doc,'verified',decode(reader_digest,'hex'),100,'application/json',now());
 insert into app_private.paper_asset_manifest_members values(rawm,txt,'standalone.mmd');
 insert into app_private.catalog_metadata(id,version_id,source_id,source_revision,metadata,metadata_sha256)
  values(meta,ver,'2501.4900'||n,1,metadata,sha256(convert_to(metadata::text,'UTF8')));
 insert into app_private.catalog_asset_approvals(id,version_id,document_id,metadata_id,original_object_id,license_uri,policy_version,evidence)
  values(appr,ver,doc,meta,orig,'https://creativecommons.org/licenses/by/4.0/','arxiv-reuse-v1','{}');
 insert into app_private.ocr_runs(id,document_id,provider,options_sha256,raw_bundle_object_id) values(run,doc,'mathpix',sha256(convert_to('options'||n,'UTF8')),rawm);
 insert into app_private.render_artifacts(id,ocr_run_id,renderer_version,manifest_object_id) values(art,run,'podcast-seed-test-v1',readm);
 return appr;
end $$;
select test.seed_paper(1) as a1 \gset
select test.seed_paper(2) as a2 \gset
select test.seed_paper(3) as a3 \gset

select public.worker_podcast_policy_set(:'O',gen_random_uuid(),'{"seed_enabled":true}','Seed pilot (049 test)');
select public.worker_podcast_seed_period(:'O',gen_random_uuid(),:'month',2000000,true,'owner-decision-20261008',2);

-- One paid attempt with an explicit receipt (unknown keeps its whole ceiling).
create or replace function test.attempt(j uuid,c uuid,g bigint,route text,cost bigint,units jsonb,state text default 'succeeded') returns void language plpgsql as $$
declare attempt uuid:=gen_random_uuid(); admission jsonb;
begin
 admission:=public.worker_podcast_attempt_begin(j,c,g,attempt,route,sha256(convert_to(route||attempt::text,'UTF8')));
 perform test.assert((admission->>'granted')::boolean,'grant '||route||' '||coalesce(admission->>'reason',''));
 if state='unknown' then
  perform public.worker_provider_attempt_finish((admission->>'account_id')::uuid,(admission->>'operation_id')::uuid,attempt,'unknown',null,null,'{}','transport_unknown');
 else
  perform public.worker_provider_attempt_finish((admission->>'account_id')::uuid,(admission->>'operation_id')::uuid,attempt,'succeeded','req_'||left(attempt::text,8),cost,units,null);
 end if;
end $$;
-- The staging failure: a finished draft, then a review cut off at its cap; the worker fails the job (quality).
create or replace function test.fail_like_staging(j uuid,draft_cost bigint,draft_out bigint,review_cost bigint) returns jsonb language plpgsql as $$
declare c uuid:=gen_random_uuid(); claim jsonb; g bigint;
begin
 claim:=public.worker_podcast_claim(c);
 perform test.assert((claim->>'job_id')::uuid=j,'claimed the intended seed job');
 g:=(claim->>'generation')::bigint;
 perform test.attempt(j,c,g,'podcast_script',draft_cost,jsonb_build_object('input_tokens',29575,'output_tokens',draft_out));
 perform public.worker_podcast_advance(j,c,g,'checking');
 perform test.attempt(j,c,g,'podcast_review',review_cost,'{"input_tokens":34500,"output_tokens":4000}'::jsonb);
 return public.worker_podcast_fail(j,c,g,'script_incomplete',true);
end $$;
-- A complete seed episode: both script passes, speech, exact 3-object inventory, publication (pending review).
create or replace function test.publish_seed(j uuid,release_key text) returns uuid language plpgsql as $$
declare c uuid:=gen_random_uuid(); claim jsonb; g bigint; plan jsonb; row jsonb; upload uuid:=gen_random_uuid(); write uuid;
 prefix text:='shared/'||release_key||'/'; manifest text:=repeat('3',63)||right(release_key,1); published jsonb;
begin
 claim:=public.worker_podcast_claim(c);
 perform test.assert((claim->>'job_id')::uuid=j,'claimed the intended seed job');
 g:=(claim->>'generation')::bigint;
 perform test.attempt(j,c,g,'podcast_script',107000,'{"input_tokens":29575,"output_tokens":4785}'::jsonb);
 perform public.worker_podcast_advance(j,c,g,'checking');
 perform test.attempt(j,c,g,'podcast_review',72000,'{"input_tokens":34500,"output_tokens":300}'::jsonb);
 perform public.worker_podcast_advance(j,c,g,'synthesizing');
 perform test.attempt(j,c,g,'podcast_speech',140000,'{"text_input_tokens":1500,"audio_output_tokens":7500,"audio_ms":300000}'::jsonb);
 perform public.worker_podcast_advance(j,c,g,'verifying');
 perform public.worker_podcast_advance(j,c,g,'publishing');
 plan:=public.worker_podcast_asset_plan(j,c,g,upload,jsonb_build_array(
  jsonb_build_object('role','audio','path',prefix||'audio.m4a','sha256',repeat('1',63)||right(release_key,1),'bytes',2400000,'media_type','audio/mp4'),
  jsonb_build_object('role','transcript','path',prefix||'transcript.json','sha256',repeat('2',63)||right(release_key,1),'bytes',20000,'media_type','application/json'),
  jsonb_build_object('role','manifest','path',prefix||'manifest.json','sha256',manifest,'bytes',2000,'media_type','application/json')));
 for row in select value from jsonb_array_elements(plan->'objects') loop
  write:=gen_random_uuid();
  perform test.assert((public.worker_podcast_asset_write(j,c,g,upload,(row->>'id')::uuid,write)->>'write')::boolean,'podcast write grant');
  perform public.worker_podcast_asset_written(write,true);
 end loop;
 published:=public.worker_podcast_publish(j,c,g,upload,jsonb_build_object('script_sha256',repeat('4',64),'draft_sha256',repeat('5',64),
  'checker_version','podcast-checker-v2','segments',29,'chapters',5,'duration_ms',301000,'manifest_sha256',manifest,
  'identity',jsonb_build_object('script_model','claude-sonnet-5-5','speech_model','gemini-3.8-flash-tts','checker','podcast-checker-v2')));
 perform test.assert(published->'release'->>'state'='pending_review','seed release awaits operator review');
 return (published->'release'->>'release_id')::uuid;
end $$;
create or replace function test.admit(request uuid,approval uuid) returns jsonb language sql as $$
 select public.worker_podcast_seed_admit('49000000-0000-0000-0000-00000000000f'::uuid,request,approval,'CC BY 4.0 verified; no third-party exclusions found')
$$;
create or replace function test.episodes() returns integer language sql as $$
 select app_private.podcast_seed_episodes(date_trunc('month',now() at time zone 'UTC')::date)
$$;
create or replace function test.committed() returns bigint language sql as $$
 select app_private.podcast_seed_committed(date_trunc('month',now() at time zone 'UTC')::date)
$$;

-- 049 keeps 048's privileges: an internal security-definer helper with an empty search_path, no grants.
select test.assert((select p.prosecdef and p.proconfig=array['search_path=""'] and p.provolatile='s'
 and not has_function_privilege('authenticated',p.oid,'execute') and not has_function_privilege('anon',p.oid,'execute')
 and not has_function_privilege('service_role',p.oid,'execute')
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and p.proname='podcast_seed_episodes'),'helper privileges unchanged');
select test.assert(test.episodes()=0 and test.committed()=0,'empty seed period');
savepoint fresh;

-- Phase 1: two failed paid seed jobs (the staging pilot), then a third admission while dollars remain.
\set S1 '49000000-0000-0000-0001-000000000001'
\set S2 '49000000-0000-0000-0001-000000000002'
\set S3 '49000000-0000-0000-0001-000000000003'
select test.admit(:'S1',:'a1');
select test.assert(test.episodes()=1,'an in-flight seed job counts');
select test.assert((test.fail_like_staging(:'S1',107000,4785,109000)->>'state')='failed','first pilot job failed in the review');
select test.admit(:'S2',:'a2');
select test.assert((test.fail_like_staging(:'S2',109000,4497,114000)->>'state')='failed','second pilot job failed in the review');
select test.assert((select count(*)=2 from app_private.podcast_jobs where funding_kind='platform_seed' and state='failed'
 and failure_code='script_incomplete'),'two failed paid seed jobs');
select test.assert(test.committed()=439000,'failed jobs keep their actual spend ($0.439) in the allowance');
select test.assert(test.episodes()=0,'failed jobs are not episodes (048 counted both and refused a third)');
select (test.admit(:'S3',:'a1')->>'seed_committed_microusd')::bigint as committed3 \gset
select test.assert(:'committed3'::bigint=439000+750000,'a third admission succeeds with $1.56 left, holding the $0.75 profile ceiling');
select test.assert(test.episodes()=1,'the retried episode counts while in flight');
select test.assert((select (s->>'episodes')::integer=1 and (s->>'committed_microusd')::bigint=1189000
 from jsonb_array_elements(public.worker_podcast_status()->'seed_periods') s where (s->>'period')::date=:'month'),'operator status shows the new count');
rollback to savepoint fresh;

-- Phase 2: the dollar cap refuses once committed + the next ceiling exceeds $2, with episodes to spare.
\set S4 '49000000-0000-0000-0002-000000000001'
\set S5 '49000000-0000-0000-0002-000000000002'
\set S6 '49000000-0000-0000-0002-000000000003'
\set S7 '49000000-0000-0000-0002-000000000004'
select test.admit(:'S4',:'a1');
select test.fail_like_staging(:'S4',107000,4785,109000);
select test.admit(:'S5',:'a2');
-- An unknown speech outcome keeps its whole $0.303104 ceiling committed; the job is not an episode.
select gen_random_uuid() as c5 \gset
select (public.worker_podcast_claim(:'c5')->>'generation')::bigint as g5 \gset
select test.attempt(:'S5',:'c5',:'g5','podcast_script',107000,'{"input_tokens":29575,"output_tokens":4785}'::jsonb);
select public.worker_podcast_advance(:'S5',:'c5',:'g5','checking');
select test.attempt(:'S5',:'c5',:'g5','podcast_review',72000,'{"input_tokens":34500,"output_tokens":300}'::jsonb);
select public.worker_podcast_advance(:'S5',:'c5',:'g5','synthesizing');
select test.attempt(:'S5',:'c5',:'g5','podcast_speech',null,'{}'::jsonb,'unknown');
select test.assert((public.worker_podcast_fail(:'S5',:'c5',:'g5','speech_outcome_unknown',false)->>'state')='unknown_provider','unknown outcome retained');
select test.assert(test.committed()=216000+179000+303104,'committed: failed spend plus the retained unknown ceiling');
select test.assert(test.episodes()=0,'neither a failed nor an unknown-outcome job is an episode');
select test.admit(:'S6',:'a3');
select test.assert(test.committed()=698104+750000 and test.episodes()=1,'admitted: $1.448104 committed, one episode in flight');
select test.reject(format('select test.admit(%L,%L)',:'S7',:'a1'),'seed_allowance_exhausted');
select test.assert(test.episodes()=1,'refused by dollars while the episode cap (2) still had room');
rollback to savepoint fresh;

-- Phase 3: two produced episodes (one published, one awaiting review) refuse a third; a release the
-- operator rejects at review frees its slot, but never its spend.
\set E1 '49000000-0000-0000-0003-000000000001'
\set E2 '49000000-0000-0000-0003-000000000002'
\set E3 '49000000-0000-0000-0003-000000000003'
select test.admit(:'E1',:'a1');
select test.publish_seed(:'E1',repeat('a',64)) as r1 \gset
select public.worker_podcast_review(:'O',gen_random_uuid(),:'r1','publish','Listened end to end; claims match evidence');
select test.admit(:'E2',:'a2');
select test.publish_seed(:'E2',repeat('b',64)) as r2 \gset
select test.assert((select state from app_private.podcast_releases where id=:'r1')='ready'
 and (select state from app_private.podcast_releases where id=:'r2')='pending_review','one published, one awaiting review');
select test.assert(test.episodes()=2,'ready and pending-review releases are episodes');
select test.assert(test.committed()=2*319000,'two settled episodes: $0.638 committed');
select test.reject(format('select test.admit(%L,%L)',:'E3',:'a3'),'seed_episode_limit');
select test.assert(test.committed()+750000<=2000000,'refused by the episode cap, not by dollars');
select public.worker_podcast_review(:'O',gen_random_uuid(),:'r2','reject','Mispronounced the key result');
select test.assert(test.episodes()=1,'a release rejected at review is not an episode');
select test.assert(test.committed()=2*319000,'its spend still counts');
select test.assert((test.admit(:'E3',:'a3')->>'funding_kind')='platform_seed','replacement episode admitted');
select test.assert(test.episodes()=2,'in-flight replacement counts');
rollback to savepoint fresh;

rollback;
