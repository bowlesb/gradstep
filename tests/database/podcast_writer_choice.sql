-- Writer choice (migration 065, docs/architecture/PAPER_PODCASTS.md "Writer choice"): the policy offers one version
-- per writer for each length (version 3 Claude Sonnet 5.5, version 5 DeepSeek V4 Pro; version 4 never); the lengths
-- list carries the writers; a quote takes a writer and names it; a replay with the other writer conflicts; a start
-- resolves the quote's own version and refuses one withdrawn since. Synthetic local SQL; nothing leaves the machine.
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

-- The helpers read the spec: writer and label.
select test.assert(app_private.podcast_writer((select spec from app_private.podcast_profiles where id='podcast-5min-v1' and version=3))='anthropic'
 and app_private.podcast_writer((select spec from app_private.podcast_profiles where id='podcast-5min-v1' and version=5))='deepseek','writers by version');
select test.assert(app_private.podcast_writer_label((select spec from app_private.podcast_profiles where id='podcast-5min-v1' and version=3))='Claude Sonnet 5.5'
 and app_private.podcast_writer_label((select spec from app_private.podcast_profiles where id='podcast-5min-v1' and version=5))='DeepSeek V4 Pro'
 and app_private.podcast_writer_label('{"script":{"provider":"deepseek","model":"deepseek-flash"}}'::jsonb)='DeepSeek Flash'
 and app_private.podcast_writer_label('{"script":{"model":"claude-opus-5-5"}}'::jsonb)='claude-opus-5-5','writer labels');

\set O '65000000-0000-0000-0000-00000000000f'
\set A '65000000-0000-0000-0000-00000000000a'
insert into auth.users(id) values(:'O'),(:'A');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
select public.worker_grant_credits(:'A','adjustment','writer-a',2000,now()-interval '1 day',null,'Writer choice fixture');
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);

-- A converted CC BY catalog paper with its exact standalone text (as podcast_deepseek_profiles.sql), returning its ids.
create or replace function test.wc_paper(tag text) returns jsonb language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid(); appr uuid:=gen_random_uuid();
 run uuid:=gen_random_uuid(); art uuid:=gen_random_uuid(); orig uuid:=gen_random_uuid(); rawm uuid:=gen_random_uuid(); txt uuid:=gen_random_uuid();
 readm uuid:=gen_random_uuid(); raw_digest text:=encode(sha256(convert_to(tag||'-raw','UTF8')),'hex'); reader_digest text:=encode(sha256(convert_to(tag||'-reader','UTF8')),'hex');
 metadata jsonb:=jsonb_build_object('title','Writer fixture '||tag,'authors',jsonb_build_array('R. Fixture'),'published_at','2025-01-02','categories',jsonb_build_array('cs.LG'));
begin
 insert into app_private.publications(id,title) values(pub,'Writer fixture '||tag);
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
 insert into app_private.render_artifacts(id,ocr_run_id,renderer_version,manifest_object_id) values(art,run,'writer-choice-test-v1',readm);
 return jsonb_build_object('approval',appr,'document',doc,'artifact',art);
end $$;

-- The audited pointer move (053): switches on, then both writers of every length, default DeepSeek (version 5).
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),'{"seed_enabled":true,"generation_enabled":true,"catalog_enabled":true,"delivery_enabled":true}','Writer test: switches on');
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),
 '{"profile_id":"podcast-5min-v1","profile_version":5,"allowed_profiles":["podcast-short-v1:5","podcast-short-v1:3","podcast-5min-v1:5","podcast-5min-v1:3","podcast-10min-v1:5","podcast-10min-v1:3","podcast-20min-v1:5","podcast-20min-v1:3"]}',
 'Writer test: both writers of every length, DeepSeek default');
select test.assert((select profile_version=5 and cardinality(allowed_profiles)=8 from app_private.podcast_policy where singleton),'eight entries, pointer on version 5');
-- Two versions of one length with the same writer (4 and 5 are both DeepSeek) are refused; version 4 is never offered.
select test.reject(format('select public.worker_podcast_policy_set(%L,gen_random_uuid(),%L,%L)',:'O',
 '{"allowed_profiles":["podcast-5min-v1:4","podcast-5min-v1:5"]}','Writer test: duplicate writer'),'invalid_podcast_policy');
select test.reject(format('select public.worker_podcast_policy_set(%L,gen_random_uuid(),%L,%L)',:'O',
 '{"allowed_profiles":["podcast-5min-v1:5","podcast-5min-v1:5"]}','Writer test: duplicate entry'),'invalid_podcast_policy');

-- The lengths: one row per length, the default writer's figures on top, both writers listed, DeepSeek first.
select app_private.podcast_lengths() as lengths \gset
select test.assert(jsonb_array_length(:'lengths'::jsonb)=4,'four lengths');
select test.assert((select bool_and(jsonb_array_length(l->'writers')=2 and l->'writers'->0->>'writer'='deepseek' and l->'writers'->1->>'writer'='anthropic'
   and l->'writers'->0->>'label'='DeepSeek V4 Pro' and l->'writers'->1->>'label'='Claude Sonnet 5.5'
   and l->'writers'->0->>'consent_version'='podcast-private-v2' and l->'writers'->1->>'consent_version'='podcast-private-v1'
   and (l->>'max_credits')::int=(l->'writers'->0->>'max_credits')::int and (l->'writers'->0->>'estimate') is not null)
  from jsonb_array_elements(:'lengths'::jsonb) l),'each length lists DeepSeek first, then Sonnet, with the default figures on top');
select test.assert((select jsonb_agg(l->>'max_credits' order by (l->>'target_seconds')::int) from jsonb_array_elements(:'lengths'::jsonb) l)='["140","150","300","520"]'::jsonb,
 'the top-level maxima are version 5''s (never version 4''s 280 for ten minutes)');
select test.assert((select jsonb_agg(l->'writers'->1->>'max_credits' order by (l->>'target_seconds')::int) from jsonb_array_elements(:'lengths'::jsonb) l)='["180","200","360","610"]'::jsonb,
 'the Sonnet writer carries the version-3 maxima');
select test.assert((select bool_and(l ? 'profile' and l ? 'label' and l ? 'target_seconds' and l ? 'estimate') from jsonb_array_elements(:'lengths'::jsonb) l),'the row keys older clients read are still there');

-- Resolution: a writer picks the version; the default writer is the pointer's; an unknown writer or length is named.
select test.assert((app_private.podcast_allowed_spec('podcast-10min-v1','anthropic')->>'version')::int=3,'anthropic resolves version 3');
select test.assert((app_private.podcast_allowed_spec('podcast-10min-v1','deepseek')->>'version')::int=5,'deepseek resolves version 5');
select test.assert((app_private.podcast_allowed_spec('podcast-10min-v1')->>'version')::int=5 and (app_private.podcast_allowed_spec(null)->>'id')='podcast-5min-v1','no writer: the default');
select test.reject('select app_private.podcast_allowed_spec(''podcast-10min-v1'',''flash'')','podcast_writer_unavailable');
select test.reject('select app_private.podcast_allowed_spec(''podcast-10min-v1'',''Bad!'')','podcast_writer_unavailable');
select test.reject('select app_private.podcast_allowed_spec(''podcast-99min-v1'',''anthropic'')','podcast_profile_unavailable');
select test.reject('select app_private.podcast_allowed_version(''podcast-10min-v1'',4)','podcast_profile_unavailable');
select test.assert((app_private.podcast_allowed_version('podcast-10min-v1',3)->>'version')::int=3,'a quoted version still offered resolves');

-- Quotes: the writer names the providers, the consent and the maximum; a replay with the other writer conflicts.
select test.wc_paper('one') as fixture \gset
insert into app_private.library_items(account_id,document_id,artifact_id,approval_id)
 values(:'A',(:'fixture'::jsonb->>'document')::uuid,(:'fixture'::jsonb->>'artifact')::uuid,(:'fixture'::jsonb->>'approval')::uuid);
select id as item from app_private.library_items where account_id=:'A' \gset
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
\set Q1 '65000000-0000-0000-00b0-000000000001'
\set Q2 '65000000-0000-0000-00b0-000000000002'
\set Q3 '65000000-0000-0000-00b0-000000000003'
select public.v1_podcast_quote(:'item',:'Q1','podcast-10min-v1','anthropic') as sonnet \gset
select test.assert((:'sonnet'::jsonb->'quote'->>'writer')='anthropic' and (:'sonnet'::jsonb->'quote'->>'writer_label')='Claude Sonnet 5.5'
 and (:'sonnet'::jsonb->'quote'->'providers')='["Anthropic (script)","Google Vertex AI (speech)"]'::jsonb
 and (:'sonnet'::jsonb->'quote'->>'consent_version')='podcast-private-v1' and (:'sonnet'::jsonb->'quote'->>'max_credits')::int=360
 and (:'sonnet'::jsonb->'quote'->>'profile')='podcast-10min-v1','a Sonnet quote: version 3, Anthropic, consent v1, 360 credits');
select test.assert(jsonb_array_length(:'sonnet'::jsonb->'options')=4 and (:'sonnet'::jsonb->'options'->0->'writers'->0->>'writer')='deepseek','the quote carries the lengths with their writers');
select public.v1_podcast_quote(:'item',:'Q2','podcast-10min-v1','deepseek') as deepseek \gset
select test.assert((:'deepseek'::jsonb->'quote'->>'writer')='deepseek' and (:'deepseek'::jsonb->'quote'->>'writer_label')='DeepSeek V4 Pro'
 and (:'deepseek'::jsonb->'quote'->'providers')='["DeepSeek (script)","Google Vertex AI (speech)"]'::jsonb
 and (:'deepseek'::jsonb->'quote'->>'consent_version')='podcast-private-v2' and (:'deepseek'::jsonb->'quote'->>'max_credits')::int=300,'a DeepSeek quote: version 5, consent v2, 300 credits');
select public.v1_podcast_quote(:'item',:'Q3','podcast-10min-v1') as default_quote \gset
select test.assert((:'default_quote'::jsonb->'quote'->>'writer')='deepseek' and (:'default_quote'::jsonb->'quote'->>'max_credits')::int=300,'no writer: the default, DeepSeek');
select test.reject(format('select public.v1_podcast_quote(%L,%L,%L,%L)',:'item','65000000-0000-0000-00b0-000000000009','podcast-10min-v1','flash'),'podcast_writer_unavailable');
select test.reject(format('select public.v1_podcast_quote(%L,%L,%L,%L)',:'item',:'Q1','podcast-10min-v1','deepseek'),'podcast_request_conflict');
select test.assert((public.v1_podcast_quote(:'item',:'Q1','podcast-10min-v1','anthropic')->'quote'->>'id')=(:'sonnet'::jsonb->'quote'->>'id'),'the same request with the same writer replays the quote');
-- The start requires the consent the quote named, and charges the quoted version.
select test.reject(format('select public.v1_podcast_start(%L,%L,%L)',:'deepseek'::jsonb->'quote'->>'id',:'Q2','podcast-private-v1'),'consent_required');
select public.v1_podcast_start((:'sonnet'::jsonb->'quote'->>'id')::uuid,:'Q1','podcast-private-v1') as started \gset
select test.assert((:'started'::jsonb->'job'->>'held_credits')::int=360 and (:'started'::jsonb->'job'->>'profile')='podcast-10min-v1','the Sonnet start holds 360 credits');
reset role;
select test.assert((select (app_private.podcast_job_spec(j)->>'version')::int=3 and app_private.podcast_writer(app_private.podcast_job_spec(j))='anthropic'
  from app_private.podcast_jobs j join app_private.podcast_requests r on r.job_id=j.id where r.request_id=:'Q1' and r.account_id=:'A'),'the job runs on version 3 with Anthropic');

-- A writer withdrawn after quoting: the quote's own version is what is checked, so the start says the length is gone.
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),
 '{"allowed_profiles":["podcast-short-v1:5","podcast-5min-v1:5","podcast-10min-v1:5","podcast-20min-v1:5"]}','Writer test: Sonnet withdrawn');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
\set Q4 '65000000-0000-0000-00b0-000000000004'
select test.reject(format('select public.v1_podcast_quote(%L,%L,%L,%L)',:'item',:'Q4','podcast-10min-v1','anthropic'),'podcast_writer_unavailable');
reset role;
select test.assert((select bool_and(jsonb_array_length(l->'writers')=1 and l->'writers'->0->>'writer'='deepseek') from jsonb_array_elements(app_private.podcast_lengths()) l),'one writer per length again');
rollback;
