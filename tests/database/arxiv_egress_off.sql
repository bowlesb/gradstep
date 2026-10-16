-- Migration 077 (docs/architecture/ARXIV_DEVICE_ONLY.md, rollout steps 5–7): our servers never contact arXiv. The switches
-- cannot point a server at arXiv again; the old pacing gate never reserves; the metadata stage records an arXiv paper from
-- DataCite's evidence, deciding shared reuse itself and keeping the record's provenance; a device's record for an import
-- still waiting for DataCite asks the pipeline again. Synthetic local SQL.
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

-- 1. Switches.
select test.assert((select not arxiv_egress and source_metadata_enabled and feed_source='datacite' from app_private.pipeline_policy where singleton),'077 switched');
select test.reject($q$update app_private.pipeline_policy set arxiv_egress=true where singleton$q$,'pipeline_policy_arxiv_egress_off');
select test.reject($q$update app_private.pipeline_policy set feed_source='arxiv_rss' where singleton$q$,'pipeline_policy_feed_source_check');
select test.assert(app_private.feed_active_source()='datacite-ml','the pool reads DataCite''s row');

-- 2. The pacing gate fails closed, for the service role only.
set role service_role;
select test.assert(public.worker_pipeline_arxiv_slot(2,45000)='{"reserved":false,"code":"arxiv_egress_disabled","wait_ms":600000}'::jsonb,'nothing reserved');
select test.assert((public.worker_pipeline_arxiv_slot()->>'reserved')::boolean=false,'defaults too');
select public.worker_set_pipeline_enabled(true);
reset role;
set role authenticated;
select test.reject('select public.worker_pipeline_arxiv_slot()','permission denied');
select test.reject($q$select public.worker_pipeline_datacite_metadata(gen_random_uuid(),gen_random_uuid(),1,1,'{}','{}')$q$,'permission denied');
reset role;

-- 3. The metadata stage from DataCite.
\set A '76000000-0000-4000-8000-00000000000a'
\set B '76000000-0000-4000-8000-00000000000b'
\set IA '76000000-0000-4000-8000-0000000000a1'
\set IB '76000000-0000-4000-8000-0000000000b1'
insert into auth.users values(:'A'),(:'B');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_begin_import(:'IA','2305.18290',0,3);
reset role;

create temp table fixture_record as select '{"title":"Direct Preference Optimization: Your Language Model is Secretly a Reward Model","authors":["Rafael Rafailov","Archit Sharma"],"abstract":"While large-scale unsupervised language models learn broad world knowledge.","published_at":"2023-05-29","updated_at":"2024-07-29","categories":["cs.LG","cs.AI"],"venue":null}'::jsonb m;
create temp table fixture_evidence as select jsonb_build_object('origin','datacite','doi','10.48550/arxiv.2305.18290','source_id','2305.18290','source_revision',3,
 'source_url','https://arxiv.org/abs/2305.18290v3','version',3,'title','Direct Preference Optimization: Your Language Model is Secretly a Reward Model',
 'first_author','Rafael Rafailov','license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_url','https://api.datacite.org/dois/10.48550/arXiv.2305.18290',
 'evidence_format','datacite','evidence_sha256',repeat('ab',32),'observed_at','2026-10-16T00:00:00.000Z') e;
grant select on fixture_record, fixture_evidence to service_role;

set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select :'entry'::jsonb->>'id' as paper, (:'entry'::jsonb->>'generation')::bigint as gen \gset
-- What DataCite said must name this paper and this version; a licence only for the version DataCite describes.
select test.reject(format('select public.worker_pipeline_datacite_metadata(%L,%L,%s,3,(select m from fixture_record),(select e from fixture_evidence)||%L)',:'paper',:'claim',:'gen','{"doi":"10.48550/arXiv.2305.18291"}'),'invalid_pipeline_metadata');
select test.reject(format('select public.worker_pipeline_datacite_metadata(%L,%L,%s,3,(select m from fixture_record),(select e from fixture_evidence)||%L)',:'paper',:'claim',:'gen','{"source_url":"https://evil.test/abs/2305.18290v3"}'),'invalid_pipeline_metadata');
select test.reject(format('select public.worker_pipeline_datacite_metadata(%L,%L,%s,3,(select m from fixture_record),(select e from fixture_evidence)||%L)',:'paper',:'claim',:'gen','{"version":2}'),'invalid_pipeline_metadata');
select test.reject(format('select public.worker_pipeline_datacite_metadata(%L,%L,%s,3,(select m from fixture_record),(select e from fixture_evidence)||%L)',:'paper',:'claim',:'gen','{"license_uri":"https://example.com/mine"}'),'invalid_pipeline_metadata');
select test.reject(format('select public.worker_pipeline_datacite_metadata(%L,%L,%s,3,(select m from fixture_record),(select e from fixture_evidence)-%L)',:'paper',:'claim',:'gen','evidence_sha256'),'invalid_pipeline_metadata');
select test.reject(format('select public.worker_pipeline_datacite_metadata(%L,%L,%s,3,(select m from fixture_record),(select e from fixture_evidence)-%L)',:'paper',:'claim',:'gen','license_uri'),'invalid_pipeline_metadata');
select test.reject(format('select public.worker_pipeline_datacite_metadata(%L,%L,%s,3,(select m from fixture_record),(select e from fixture_evidence)||%L)',:'paper',:'claim',:'gen','{"origin":"arxiv"}'),'invalid_pipeline_metadata');
select test.reject(format('select public.worker_pipeline_datacite_metadata(%L,gen_random_uuid(),%s,3,(select m from fixture_record),(select e from fixture_evidence))',:'paper',:'gen'),'stale_pipeline_claim');
select public.worker_pipeline_datacite_metadata(:'paper',:'claim',:'gen',3,(select m from fixture_record),(select e from fixture_evidence))->>'stage' as stage \gset
select test.assert(:'stage'='source_only','recorded; the paper ends at metadata');
reset role;
select test.assert((select eligible and rights_mode='shared' and license_uri='https://creativecommons.org/licenses/by/4.0/' and evidence->>'evidence_format'='datacite'
 from app_private.pipeline_papers where id=:'paper'),'CC BY for the exact latest version: shared reuse, with the DataCite evidence');
select test.assert((select pr.origin='datacite' and pr.import_id is null and pr.evidence_sha256=decode(repeat('ab',32),'hex')
 from app_private.pipeline_papers p join app_private.catalog_metadata_provenance pr on pr.metadata_id=p.metadata_id where p.id=:'paper'),'provenance: DataCite');
select test.assert((select cm.metadata->>'title' like 'Direct Preference%' and cm.source_revision=3 from app_private.pipeline_papers p join app_private.catalog_metadata cm on cm.id=p.metadata_id where p.id=:'paper'),'the catalog record');
select test.reject($q$insert into app_private.catalog_metadata_provenance(metadata_id,origin,evidence_sha256) select metadata_id,'operator',decode(repeat('cd',32),'hex') from app_private.pipeline_papers limit 1$q$,'catalog_metadata_provenance_import');
set role service_role;
select test.assert(public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen')=1,'the membership follows');
select public.worker_pipeline_release(:'paper',:'claim',:'gen');
reset role;
select test.assert((select phase='source_only' and metadata_id is not null from app_private.import_requests where id=:'IA'),'the import is readable');
select test.assert(app_private.library_import_entry(:'A',:'IA')->'metadata'->>'title' like 'Direct Preference%','projected to the library');

-- An older version: DataCite describes the latest, so this version's licence is unknown and nothing is shared.
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select public.v2_begin_import(:'IB','2305.18290',0,2);
reset role;
set role service_role;
select gen_random_uuid() as claim2 \gset
select public.worker_pipeline_claim(:'claim2') as entry2 \gset
select :'entry2'::jsonb->>'id' as paper2, (:'entry2'::jsonb->>'generation')::bigint as gen2 \gset
select test.reject(format('select public.worker_pipeline_datacite_metadata(%L,%L,%s,2,(select m from fixture_record),(select e from fixture_evidence)||%L)',:'paper2',:'claim2',:'gen2','{"source_revision":2,"source_url":"https://arxiv.org/abs/2305.18290v2"}'),'invalid_pipeline_metadata');
select public.worker_pipeline_datacite_metadata(:'paper2',:'claim2',:'gen2',2,(select m from fixture_record)||'{"updated_at":"2023-12-13"}',
 (select e from fixture_evidence)||'{"source_revision":2,"source_url":"https://arxiv.org/abs/2305.18290v2","license_uri":null}');
reset role;
select test.assert((select not eligible and rights_mode='source_only' and license_uri='https://arxiv.org/abs/2305.18290v2' and evidence is null
 from app_private.pipeline_papers where id=:'paper2'),'older version: source only, linked to its abstract');

-- 4. A device's record for an import still waiting for DataCite asks again now.
\set IC '76000000-0000-4000-8000-0000000000a2'
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_begin_import(:'IC','2610.00001',0,1);
reset role;
update app_private.pipeline_papers set next_attempt_at=now()+interval '50 minutes',failures=3,error_code='metadata_pending'
 where source_id='2610.00001' and stage='metadata';
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert(public.v1_submit_source_metadata(:'IC',jsonb_build_object('format','arxiv-source-metadata-v1','source_id','2610.00001','revision',1,
 'origin','arxiv_html','title','A new paper','authors',jsonb_build_array('Ada Lovelace'),'abstract',null,'categories',jsonb_build_array('cs.LG'),
 'license_uri',null,'version_date','2026-10-01','html_available',true,'observed_at','2026-10-16T00:00:00Z'),1)->>'status'='stored','stored');
reset role;
select test.assert((select next_attempt_at<=clock_timestamp() and stage='metadata' from app_private.pipeline_papers where source_id='2610.00001'),
 'the paper is due again at once');
select test.assert((select device_metadata->>'title'='A new paper' and phase in ('accepted','resolving') from app_private.import_requests where id=:'IC'),
 'kept on the account''s own import; never in the shared catalog');
select test.assert(not exists(select 1 from app_private.catalog_metadata where source_id='2610.00001'),'nothing shared from a device');
rollback;
