-- Search without OpenAlex (migration 072, docs/architecture/ARXIV_DEVICE_ONLY.md §5.6): both switches keep today's
-- behaviour by default; the reader capability follows `device_search_enabled` and keeps the earlier capabilities
-- (source metadata from 071); the server functions' policy is for the service role only. Synthetic local SQL.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin begin execute statement; exception when others then
 if position(expected in sqlerrm)=0 then raise exception 'Unexpected rejection: % (wanted %)',sqlerrm,expected; end if; rejected:=true; end;
 if not rejected then raise exception 'Expected rejection: %',expected; end if; end $$;
grant usage on schema test to anon,authenticated,service_role;
grant execute on all functions in schema test to anon,authenticated,service_role;

\set A '72000000-0000-0000-0000-00000000000a'
insert into auth.users(id,email) values(:'A','a@gradstep.test.org');

-- Defaults: device search off, OpenAlex still used by the server.
select test.assert((select device_search_enabled=false and openalex_enabled from app_private.pipeline_policy where singleton),'defaults keep today''s search');
set role service_role;
select test.assert(public.worker_search_policy()='{"openalex":true,"device_search":false}'::jsonb,'the functions see the defaults');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert(public.v1_reader_capabilities()->'device_search'='{"enabled":false,"format":"device-search-v1"}'::jsonb,'capability off by default');
select test.assert(public.v1_reader_capabilities() ? 'source_metadata' and public.v1_reader_capabilities() ? 'library','earlier capabilities kept');
select test.reject($$select public.worker_search_policy()$$,'permission denied');
reset role;
set role anon;
select test.reject($$select public.v1_reader_capabilities()$$,'permission denied');
select test.reject($$select public.worker_search_policy()$$,'permission denied');
reset role;

-- Switched: the capability and the functions' policy follow.
update app_private.pipeline_policy set device_search_enabled=true,openalex_enabled=false where singleton;
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert((public.v1_reader_capabilities()->'device_search'->>'enabled')::boolean,'capability on with the switch');
reset role;
set role service_role;
select test.assert(public.worker_search_policy()='{"openalex":false,"device_search":true}'::jsonb,'the functions see the switches');
reset role;
rollback;
