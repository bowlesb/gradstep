-- Migration 051: default or uncertain arXiv licenses stay source-only.  The
-- fixture is deliberately not a CC license and supplies no private permission
-- evidence, which is the production worker's path.
begin;
create schema rights_test;
create function rights_test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
grant usage on schema rights_test to anon,authenticated,service_role;
grant execute on all functions in schema rights_test to anon,authenticated,service_role;

insert into auth.users values('51000000-0000-0000-0000-00000000000a');
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_set_pipeline_enabled(true);
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub','51000000-0000-0000-0000-00000000000a',false);
select public.v2_begin_import('51000000-0000-0000-0000-0000000000a1','2401.12345',0)->'entry'->>'phase' as phase \gset
select rights_test.assert(:'phase'='accepted','source-only import accepted');
reset role;

set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as claimed \gset
select (:'claimed'::jsonb->>'id') as paper, (:'claimed'::jsonb->>'generation')::bigint as gen \gset
select rights_test.assert(:'claimed'::jsonb->>'stage'='metadata','source-only paper starts at metadata');
select public.worker_pipeline_metadata(:'paper',:'claim',:'gen',1,
 '{"title":"Rights fixture","authors":["Fixture Author"],"categories":["cs.LG"]}',
 false,'http://arxiv.org/licenses/nonexclusive-distrib/1.0/',null) as recorded \gset
select rights_test.assert(:'recorded'::jsonb->>'stage'='source_only'
 and :'recorded'::jsonb->>'rights_mode'='source_only'
 and :'recorded'::jsonb->>'error_code'='license_unverified','default license enters source-only mode');
select rights_test.assert(public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen')=1,'source-only import projected');
select public.worker_pipeline_release(:'paper',:'claim',:'gen');
reset role;

select rights_test.assert((select phase='source_only' and error_code='license_unverified' and document_id is null and library_item_id is null
 from app_private.import_requests where account_id='51000000-0000-0000-0000-00000000000a' and id='51000000-0000-0000-0000-0000000000a1'),
 'source-only import has metadata and no server document');
select rights_test.assert((select count(*)=1 and bool_and(owner_id is null and stage='source_only' and document_id is null and original_object_id is null and artifact_id is null)
 from app_private.pipeline_papers where source_id='2401.12345'),'no private paper or stored reader asset was created');
select rights_test.assert((select app_private.library_import_entry('51000000-0000-0000-0000-00000000000a','51000000-0000-0000-0000-0000000000a1')->>'source_url'='https://arxiv.org/abs/2401.12345v1'),
 'source-only entry keeps the versioned arXiv link');
rollback;
