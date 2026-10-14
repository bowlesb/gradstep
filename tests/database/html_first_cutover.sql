-- Exact new runtime contract, after 058. The historical pipeline suites still
-- run against their pre-cutover schema to protect retained accounting records.
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
\set A '58000000-0000-4000-8000-000000000001'
\set B '58000000-0000-4000-8000-000000000002'
\set I '58000000-0000-4000-8000-000000000003'
insert into auth.users values(:'A'),(:'B');
select upload_dataset_epoch as epoch from app_private.library_v4_config \gset
set role service_role;
select public.worker_set_pipeline_enabled(true);
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert(public.v1_reader_capabilities()->'device_reader'->>'protocol'='source-membership-v1','advertises device contract');
select test.assert(not (public.v1_reader_capabilities()->'uploads'->>'enabled')::boolean,'uploads disabled');
select public.v2_begin_import(:'I','2305.18290',0,3);
select test.reject(format('select public.worker_local_chat_context(%L,%L,%L,3)',:'A',:'I','2305.18290'),'permission denied');
reset role;
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select :'entry'::jsonb->>'id' as paper, (:'entry'::jsonb->>'generation')::bigint as gen \gset
select public.worker_pipeline_metadata(:'paper',:'claim',:'gen',3,
 '{"title":"HTML-only paper","authors":["Author"],"abstract":"Test","published_at":"2023-05-29","updated_at":"2024-07-29","categories":["cs.LG"],"venue":null}',false)->>'stage' as stage \gset
select test.assert(:'stage'='source_only','unshared paper ends at metadata');
select test.assert(public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen')=1,'projects source membership');
select test.assert(public.worker_local_chat_context(:'A',:'I','2305.18290',3)->>'title'='HTML-only paper','source membership authorizes chat');
select test.reject(format('select public.worker_local_chat_context(%L,%L,%L,3)',:'B',:'I','2305.18290'),'document_unavailable');
select test.reject(format('select public.worker_local_chat_context(%L,%L,%L,2)',:'A',:'I','2305.18290'),'document_unavailable');
select test.reject(format('select public.worker_pipeline_original(%L,%L,%s,%L::bytea,123,1,%L)',:'paper',:'claim',:'gen','\x'||repeat('92',32),'x.pdf'),'pdf_device_only');
select test.reject(format('select public.worker_pipeline_fund(%L,%L,%s,1,%L::bytea,%L::bytea)',:'paper',:'claim',:'gen','\x'||repeat('92',32),'\x'||repeat('93',32)),'pdf_device_only');
select test.reject(format('select public.worker_pipeline_begin_submit(%L,%L,%s)',:'paper',:'claim',:'gen'),'pdf_device_only');
select public.worker_pipeline_release(:'paper',:'claim',:'gen');
select test.assert(public.worker_pipeline_claim(gen_random_uuid()) is null,'never claims source paper for processing');
reset role;
select test.assert((select count(*)=0 from app_private.paper_originals),'no server original');
select test.assert((select count(*)=0 from app_private.documents),'no fake document');
select test.reject('update app_private.pdf_upload_policy set enabled=true','pdf_device_only');
set role authenticated;
select gen_random_uuid() as op \gset
select public.v5_set_source_details(:'epoch',:'op',:'I',true,array['local'],1) as receipt \gset
select test.assert(:'receipt'::jsonb->'result'->>'status'='applied','source details applied');
select test.assert(public.v5_set_source_details(:'epoch',:'op',:'I',true,array['local'],1)->'result'=:'receipt'::jsonb->'result','command replay exact');
select test.assert(public.v5_set_source_details(:'epoch',gen_random_uuid(),:'I',false,array[]::text[],1)->'result'->>'status'='revision_conflict','stale command rejected');
reset role;
select test.assert(app_private.library_import_entry(:'A',:'I')->'user_tags'='["local"]'::jsonb,'source tags projected');
select test.assert((app_private.library_import_entry(:'A',:'I')->>'archived')::boolean,'source archive projected');
set role authenticated;
select public.v1_bootstrap_keys('58000000-0000-4000-8000-000000000004',decode(repeat('11',32),'hex'),decode(repeat('22',60),'hex'),decode(repeat('33',32),'hex'),decode(repeat('44',92),'hex'),decode(repeat('aa',32),'hex'));
select public.v1_append_event('58000000-0000-4000-8000-000000000004','58000000-0000-4000-8000-000000000005',1,2,decode(repeat('55',100),'hex'),decode(repeat('33',32),'hex'));
select test.assert(public.v3_pull_events(0)->'events'->0->>'format'='2','new readers receive v2 encrypted envelopes');
select test.reject('select public.v2_pull_events(0)','sync_page_too_large');
select test.reject('select public.v1_pull_events(0)','sync_page_too_large');
select set_config('request.jwt.claim.sub',:'B',false);
select test.assert(public.v3_pull_events(0)->'events'='[]'::jsonb,'private payloads account scoped');
rollback;
