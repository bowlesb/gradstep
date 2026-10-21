-- 0107 (review C6): admission and dispatch in one transaction, with the same checks as the two separate calls.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set A '10700000-0000-4000-8000-000000000001'
\set O '10700000-0000-4000-8001-000000000001'
\set T '10700000-0000-4000-8002-000000000001'
\set M '{"transport_model":"anthropic/claude-sonnet-5.5","endpoint":"google-vertex/us","feature":"chat","caller":"chat"}'
insert into auth.users(id,email) values(:'A','admit-107@gradstep.test.org');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','admit-107',1000,now()-interval '1 day',null,'Admit fixture');
set role service_role;
select public.worker_reserve_operation(:'A',:'O','chat',sha256('admit107'),'beta-credits-v1',100,900000);
select test.assert((public.worker_openrouter_admit(:'A',:'O',:'T','chat','anthropic/claude-sonnet-5.5',sha256('t'),300000,'{"output_tokens":100}',:'M')
 ->>'dispatched')::boolean,'admitted and dispatched in one call');
select test.assert(not public.worker_openrouter_dispatch(:'A',:'O',:'T',:'M'),'a second dispatch is refused, as before');
select test.assert(public.worker_openrouter_admit(:'A',:'O',:'T','chat','anthropic/claude-sonnet-5.5',sha256('t'),300000,'{"output_tokens":100}',:'M')
 ->>'reason'='attempt_replayed','a replayed admission neither grants nor dispatches');
-- A dispatch that fails its checks rolls the admission back: nothing granted, nothing to send.
select test.reject(format('select public.worker_openrouter_admit(%L,%L,gen_random_uuid(),%L,%L,sha256(%L),300000,%L,%L)',:'A',:'O','chat',
 'anthropic/claude-sonnet-5.5','x','{"output_tokens":100}',jsonb_set(:'M'::jsonb,'{endpoint}','"deepinfra/fp8"')::text),'transport_route_mismatch');
reset role;
select test.assert((select count(*)=1 from app_private.provider_attempts where operation_id=:'O'),'the refused one left no attempt');
select test.assert((select dispatched_at is not null and transport_metadata=:'M'::jsonb from app_private.provider_attempts where id=:'T'),'dispatch recorded');
update app_private.platform_budgets set work_enabled=false where period=date_trunc('month',now() at time zone 'UTC')::date;
set role service_role;
select test.assert(not (public.worker_openrouter_admit(:'A',:'O',gen_random_uuid(),'chat','anthropic/claude-sonnet-5.5',sha256('p'),300000,'{"output_tokens":100}',:'M')
 ->>'dispatched')::boolean,'a refused admission dispatches nothing');
reset role;
select test.assert(not has_function_privilege('authenticated','public.worker_openrouter_admit(uuid,uuid,uuid,text,text,bytea,bigint,jsonb,jsonb)','execute'),'service only');
rollback;
