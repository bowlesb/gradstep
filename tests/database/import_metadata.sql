-- Build 69: source-only Added date and explicitly cleared keyword state, migration 088.
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
\set A '88000000-0000-4000-8000-000000000001'
\set B '88000000-0000-4000-8000-000000000002'
\set I '88000000-0000-4000-8000-000000000003'
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
reset role;
select app_private.library_import_entry(:'A',:'I') as before \gset
select test.assert((:'before'::jsonb->>'added_at')::timestamptz=(select created_at from app_private.import_requests where id=:'I'),'actual import creation time, never metadata time');
select test.assert(:'before'::jsonb->'tags_customized'='false'::jsonb,'new paper uses category keywords');
select (:'before'::jsonb->>'state_seq')::bigint as old_seq \gset
set role authenticated;
-- An older client archiving untouched inferred tags must not clear them.
select public.v5_set_source_details(:'epoch',gen_random_uuid(),:'I',true,array[]::text[],1);
reset role;
select test.assert(app_private.library_import_entry(:'A',:'I')->'tags_customized'='false'::jsonb,'archive-only legacy command preserves inferred keywords');
set role authenticated;
select gen_random_uuid() as op \gset
select public.v5_set_source_details(:'epoch',:'op',:'I',true,array[]::text[],2) as cleared \gset
select test.assert(:'cleared'::jsonb->'result'->>'status'='applied','clearing inferred keywords is a real edit');
select test.assert(public.v5_set_source_details(:'epoch',:'op',:'I',true,array[]::text[],2)->'result'=:'cleared'::jsonb->'result','clearing replay is idempotent');
reset role;
select app_private.library_import_entry(:'A',:'I') as after \gset
select test.assert(:'after'::jsonb->'tags_customized'='true'::jsonb and not (:'after'::jsonb ? 'user_tags'),'explicit empty remains distinguishable');
select test.assert(:'after'::jsonb->>'added_at'=:'before'::jsonb->>'added_at','editing preserves Added date');
select test.assert((:'after'::jsonb->>'state_seq')::bigint > :'old_seq','incremental clients get a new revision');
select test.assert(app_private.library_import_entry(:'B',:'I') is null,'another account cannot read source metadata');
set role authenticated;
select test.assert(public.v5_set_source_details(:'epoch',gen_random_uuid(),:'I',false,array['Custom'],1)->'result'->>'status'='revision_conflict','old revision cannot restore removed tags');
rollback;
