-- DeepSeek script provider (migration 063, docs/architecture/PAPER_PODCASTS.md): version-4 profiles write, review
-- and repair the script on deepseek-v4-pro at peak list prices; a deepseek attempt is admitted for the script routes
-- and refused elsewhere; a version-4 quote names "DeepSeek (script)" and consent podcast-private-v2, which the start
-- requires exactly, while version-3 quotes still require v1. Synthetic local SQL; nothing leaves the machine.
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

-- Version 4 of every length exists beside versions 2 and 3, on DeepSeek, with every ceiling at the peak rates and the
-- same token caps and routes as version 3.
select test.assert((select count(*)=4 from app_private.podcast_profiles where version=4),'four version-4 profiles');
select test.assert((select count(*)=4 from app_private.podcast_profiles where version=3),'version-3 rows untouched');
select test.assert((select bool_and(
  spec->'script'->>'provider'='deepseek' and spec->'script'->>'model'='deepseek-v4-pro'
  and spec->'script'->'rates_microusd_per_token'='{"input":1.32,"output":3.96}'::jsonb
  and spec->>'consent_version'='podcast-private-v2'
  and (select count(*) from jsonb_array_elements(p.spec->'script'->'calls') c)=3
  and (select bool_and((c->>'ceiling_microusd')::bigint=ceil((c->>'max_input_tokens')::numeric*1.32+(c->>'max_output_tokens')::numeric*3.96)::bigint)
       from jsonb_array_elements(p.spec->'script'->'calls') c)
  and (select bool_and(t.c->>'route'=u.e->>'route' and t.c->>'max_input_tokens'=u.e->>'max_input_tokens' and t.c->>'max_output_tokens'=u.e->>'max_output_tokens')
       from jsonb_array_elements(p.spec->'script'->'calls') with ordinality as t(c,o)
       join jsonb_array_elements((select v.spec->'script'->'calls' from app_private.podcast_profiles v where v.id=p.id and v.version=3)) with ordinality as u(e,o) on u.o=t.o)
  and (spec->>'ceiling_microusd')::bigint=(select sum((c->>'ceiling_microusd')::bigint) from jsonb_array_elements(p.spec->'script'->'calls') c)+(spec->'speech'->>'ceiling_microusd')::bigint
  and (spec->>'max_credits')::bigint=ceil((spec->>'ceiling_microusd')::numeric/50000)*10
  and (spec->>'hold_microusd')::bigint=(spec->>'max_credits')::bigint*5000
  and spec->'speech'->>'provider'='google')
 from app_private.podcast_profiles p where version=4),'version-4 provider, model, rates, consent, call caps, ceilings, credits and hold');
select test.assert((select jsonb_object_agg(id,spec->>'max_credits') from app_private.podcast_profiles where version=4)
 ='{"podcast-short-v1":"140","podcast-5min-v1":"150","podcast-10min-v1":"280","podcast-20min-v1":"500"}'::jsonb,'the version-4 maxima');
select test.assert(app_private.podcast_script_provider_label((select spec from app_private.podcast_profiles where id='podcast-5min-v1' and version=4))='DeepSeek (script)'
 and app_private.podcast_script_provider_label((select spec from app_private.podcast_profiles where id='podcast-5min-v1' and version=3))='Anthropic (script)','provider labels');
select test.assert(position('maximum 150 credits' in app_private.podcast_estimate((select spec from app_private.podcast_profiles where id='podcast-5min-v1' and version=4)))>0
 and position('55–60' in app_private.podcast_estimate((select spec from app_private.podcast_profiles where id='podcast-5min-v1' and version=4)))=0,
 'the DeepSeek five-minute estimate makes no Sonnet-measured claim');

\set O '63000000-0000-0000-0000-00000000000f'
\set A '63000000-0000-0000-0000-00000000000a'
\set R '63000000-0000-0000-0001-000000000001'
insert into auth.users(id) values(:'O'),(:'A');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
select public.worker_grant_credits(:'A','adjustment','deepseek-a',2000,now()-interval '1 day',null,'DeepSeek fixture');
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);

-- A converted CC BY catalog paper with its exact standalone text (as podcast_script_repair.sql), returning its ids.
create or replace function test.ds_paper(tag text) returns jsonb language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid(); appr uuid:=gen_random_uuid();
 run uuid:=gen_random_uuid(); art uuid:=gen_random_uuid(); orig uuid:=gen_random_uuid(); rawm uuid:=gen_random_uuid(); txt uuid:=gen_random_uuid();
 readm uuid:=gen_random_uuid(); raw_digest text:=encode(sha256(convert_to(tag||'-raw','UTF8')),'hex'); reader_digest text:=encode(sha256(convert_to(tag||'-reader','UTF8')),'hex');
 metadata jsonb:=jsonb_build_object('title','DeepSeek fixture '||tag,'authors',jsonb_build_array('R. Fixture'),'published_at','2025-01-02','categories',jsonb_build_array('cs.LG'));
begin
 insert into app_private.publications(id,title) values(pub,'DeepSeek fixture '||tag);
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
 return jsonb_build_object('approval',appr,'document',doc,'artifact',art);
end $$;

create or replace function test.ds_attempt(j uuid,c uuid,g bigint,route text) returns jsonb language plpgsql as $$
declare attempt uuid:=gen_random_uuid(); admission jsonb;
begin
 admission:=public.worker_podcast_attempt_begin(j,c,g,attempt,route,sha256(convert_to(route||attempt::text,'UTF8')));
 if (admission->>'granted')::boolean then
  perform public.worker_provider_attempt_finish((admission->>'account_id')::uuid,(admission->>'operation_id')::uuid,attempt,'succeeded','req_'||left(attempt::text,8),50000,'{"input_tokens":30000,"output_tokens":2000}'::jsonb,null);
 end if;
 return admission;
end $$;


-- The audited pointer move (053): every length on version 4, generation on.
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),'{"seed_enabled":true,"generation_enabled":true,"catalog_enabled":true,"delivery_enabled":true}','DeepSeek test: switches on');
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),
 '{"profile_id":"podcast-5min-v1","profile_version":4,"allowed_profiles":["podcast-short-v1:4","podcast-5min-v1:4","podcast-10min-v1:4","podcast-20min-v1:4"]}','DeepSeek test: version 4');
select test.assert((select profile_version=4 from app_private.podcast_policy where singleton),'pointer on version 4');
select test.assert((select jsonb_agg(l->>'max_credits' order by (l->>'target_seconds')::int) from jsonb_array_elements(app_private.podcast_lengths()) l)='["140","150","280","500"]'::jsonb,'the lengths quote the version-4 maxima');
select public.worker_podcast_seed_period(:'O',gen_random_uuid(),:'month',4000000,true,'owner-decision-20261014',4);

-- A seed job on version 4: every script route is admitted under the deepseek provider at the version-4 ceilings.
select test.ds_paper('one') as fixture \gset
select (public.worker_podcast_seed_admit(:'O',:'R',(:'fixture'::jsonb->>'approval')::uuid,'CC BY 4.0 verified; DeepSeek route test')->>'id') as job \gset
select test.assert((select (app_private.podcast_job_spec(j)->>'version')::int=4 from app_private.podcast_jobs j where j.id=:'job'),'the job runs on version 4');
select '63000000-0000-0000-0002-000000000001' as claim \gset
select (public.worker_podcast_claim(:'claim')->>'generation')::bigint as gen \gset
select test.ds_attempt(:'job',:'claim',:'gen','podcast_script') as draft \gset
select test.assert((:'draft'::jsonb->>'granted')::boolean and (:'draft'::jsonb->>'provider')='deepseek' and (:'draft'::jsonb->>'model')='deepseek-v4-pro'
 and (:'draft'::jsonb->>'ceiling_microusd')::bigint=(select (spec->'script'->'calls'->0->>'ceiling_microusd')::bigint from app_private.podcast_profiles where id='podcast-5min-v1' and version=4),'draft granted to deepseek at the version-4 ceiling');
select test.assert((select provider='deepseek' and model='deepseek-v4-pro' and pricing_snapshot->>'tariff'='deepseek-token-rates-peak-20261014'
  and (pricing_snapshot->'rates_microusd'->'v4_pro'->>'output')::numeric=3.96 from app_private.provider_attempts where id=(:'draft'::jsonb->>'attempt_id')::uuid),'the attempt records the provider and its peak rates');
select public.worker_podcast_advance(:'job',:'claim',:'gen','checking');
select test.assert((test.ds_attempt(:'job',:'claim',:'gen','podcast_review')->>'provider')='deepseek','review under deepseek');
select test.assert((test.ds_attempt(:'job',:'claim',:'gen','podcast_script_repair')->>'provider')='deepseek','repair under deepseek');
select public.worker_podcast_advance(:'job',:'claim',:'gen','synthesizing');
select test.assert((select state='synthesizing' from app_private.podcast_jobs where id=:'job'),'speech follows, still with Google');

-- The provider's routes are the script ones only: a deepseek chat or speech attempt is refused before any accounting.
select operation_account_id as opa,operation_id as opo from app_private.podcast_jobs where id=:'job' \gset
select test.reject(format('select public.worker_provider_attempt_begin(%L,%L,gen_random_uuid(),%L,%L,%L,sha256(%L),1000,%L::jsonb)',:'opa',:'opo','deepseek','chat','deepseek-v4-pro','x','{"input_tokens":1,"output_tokens":1}'),'invalid_provider_route');
select test.reject(format('select public.worker_provider_attempt_begin(%L,%L,gen_random_uuid(),%L,%L,%L,sha256(%L),1000,%L::jsonb)',:'opa',:'opo','deepseek','podcast_speech','deepseek-v4-pro','x','{"input_tokens":1,"output_tokens":1}'),'invalid_provider_route');

-- A customer quote on version 4 names DeepSeek and consent v2; the start requires exactly that consent.
insert into app_private.library_items(account_id,document_id,artifact_id,approval_id)
 values(:'A',(:'fixture'::jsonb->>'document')::uuid,(:'fixture'::jsonb->>'artifact')::uuid,(:'fixture'::jsonb->>'approval')::uuid);
select id as item from app_private.library_items where account_id=:'A' \gset
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
\set Q1 '63000000-0000-0000-00b0-000000000001'
select public.v1_podcast_quote(:'item',:'Q1','podcast-10min-v1') as qt \gset
select test.assert((:'qt'::jsonb->'quote'->>'consent_version')='podcast-private-v2' and (:'qt'::jsonb->'quote'->'providers')='["DeepSeek (script)","Google Vertex AI (speech)"]'::jsonb
 and (:'qt'::jsonb->'quote'->>'max_credits')::int=280,'a version-4 quote names DeepSeek, consent v2 and the version-4 maximum');
select test.reject(format('select public.v1_podcast_start(%L,%L,%L)',:'qt'::jsonb->'quote'->>'id',:'Q1','podcast-private-v1'),'consent_required');
select test.reject(format('select public.v1_podcast_start(%L,%L,%L)',:'qt'::jsonb->'quote'->>'id',:'Q1','podcast-private-v3'),'consent_required');
select public.v1_podcast_start((:'qt'::jsonb->'quote'->>'id')::uuid,:'Q1','podcast-private-v2') as st \gset
select test.assert((:'st'::jsonb->'job'->>'held_credits')::int=280 and (:'st'::jsonb->'job'->>'profile')='podcast-10min-v1','the version-2 consent starts a 280-credit hold');
reset role;
select test.assert((select consent_version='podcast-private-v2' from app_private.podcast_quotes where id=(:'qt'::jsonb->'quote'->>'id')::uuid),'the quote row carries consent v2');

-- Back on version 3 (Anthropic), a quote names Anthropic and consent v1, and v2 is refused.
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),
 '{"profile_id":"podcast-5min-v1","profile_version":3,"allowed_profiles":["podcast-short-v1:3","podcast-5min-v1:3","podcast-10min-v1:3","podcast-20min-v1:3"]}','DeepSeek test: back to version 3');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
\set Q2 '63000000-0000-0000-00b0-000000000002'
select public.v1_podcast_quote(:'item',:'Q2','podcast-short-v1') as q3 \gset
select test.assert((:'q3'::jsonb->'quote'->>'consent_version')='podcast-private-v1' and (:'q3'::jsonb->'quote'->'providers'->>0)='Anthropic (script)'
 and (:'q3'::jsonb->'quote'->>'max_credits')::int=180,'a version-3 quote still names Anthropic and consent v1');
select test.reject(format('select public.v1_podcast_start(%L,%L,%L)',:'q3'::jsonb->'quote'->>'id',:'Q2','podcast-private-v2'),'consent_required');
reset role;
rollback;
