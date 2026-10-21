-- 0102 (review A6): unresolved OpenRouter attempts are claimed in bounded, backed-off batches and reconciled at their
-- generation record's cost with an audit trail; nothing still streaming, mismatched or given up is released.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set A '10200000-0000-4000-8000-000000000001'
\set O '10200000-0000-4000-8001-000000000001'
\set T '10200000-0000-4000-8002-000000000001'
\set F '10200000-0000-4000-8002-000000000002'
\set G '10200000-0000-4000-8002-000000000003'
\set M '{"transport_model":"anthropic/claude-sonnet-5.5","endpoint":"google-vertex/us","feature":"chat","caller":"chat"}'
\set R '{"generation_id":"gen-102","provider":"Google","model":"anthropic/claude-sonnet-5.5","total_cost_microusd":51200}'
insert into auth.users(id,email) values(:'A','reconcile-102@gradstep.test.org');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','reconcile-102',1000,now()-interval '1 day',null,'Reconcile fixture');
set role service_role;
select public.worker_reserve_operation(:'A',:'O','chat',sha256('reconcile102'),'beta-credits-v1',100,900000);
-- T: a stopped answer (unknown, generation id known). F: another, still streaming (just now). G: lost before headers (no id).
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',:'T','openrouter','chat','anthropic/claude-sonnet-5.5',sha256('t'),300000,'{"output_tokens":2000}')->>'granted')::boolean,'T admitted');
select test.assert(public.worker_openrouter_dispatch(:'A',:'O',:'T',:'M'),'T dispatched');
select public.worker_provider_attempt_finish(:'A',:'O',:'T','unknown','gen-102',null,'{}','aborted');
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',:'F','openrouter','chat','anthropic/claude-sonnet-5.5',sha256('f'),300000,'{"output_tokens":2000}')->>'granted')::boolean,'F admitted');
select test.assert(public.worker_openrouter_dispatch(:'A',:'O',:'F',:'M'),'F dispatched');
select public.worker_provider_attempt_finish(:'A',:'O',:'F','unknown','gen-102f',null,'{}','aborted');
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',:'G','openrouter','chat','anthropic/claude-sonnet-5.5',sha256('g'),200000,'{"output_tokens":2000}')->>'granted')::boolean,'G admitted');
select test.assert(public.worker_openrouter_dispatch(:'A',:'O',:'G',:'M'),'G dispatched');
select public.worker_provider_attempt_finish(:'A',:'O',:'G','unknown',null,null,'{}','transport_unknown');
select public.worker_settle_operation(:'A',:'O',0,0);
reset role;
update app_private.provider_attempts set created_at=now()-interval '2 hours' where id in (:'T',:'G');
select reserved_microusd as reserved_before,spent_microusd as spent_before from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date \gset
select test.assert(:reserved_before>=800000,'the three unresolved ceilings are reserved');

set role service_role;
select test.assert(public.worker_openrouter_reconcile_claim(10)->0->>'attempt_id'=:'T' and jsonb_array_length(public.worker_openrouter_reconcile_claim(10))=0,
 'only T is claimable (F is too recent, G has no generation id), and a claim backs off');
select test.reject('select public.worker_openrouter_reconcile_claim(51)','invalid_limit');
-- The record must name this generation and this model, at its own cost.
select test.reject(format('select public.worker_openrouter_reconcile(%L,%L,%L,51200,%L)',:'T','gen-other',:'R','{"input_tokens":10}'),'invalid_reconciliation');
select test.reject(format('select public.worker_openrouter_reconcile(%L,%L,%L,51200,%L)',:'T','gen-102',jsonb_set(:'R'::jsonb,'{model}','"openai/x"')::text,'{"input_tokens":10}'),'receipt_model_mismatch');
select test.reject(format('select public.worker_openrouter_reconcile(%L,%L,%L,51201,%L)',:'T','gen-102',:'R','{"input_tokens":10}'),'invalid_reconciliation');
select test.assert((public.worker_openrouter_reconcile(:'T','gen-102',:'R',51200,'{"input_tokens":10000,"cache_read_tokens":30000,"output_tokens":900}')->>'released_microusd')::bigint=300000,
 'reconciled: the whole ceiling released');
select test.assert(not (public.worker_openrouter_reconcile(:'T','gen-102',:'R',51200,'{"input_tokens":10000,"cache_read_tokens":30000,"output_tokens":900}')->>'reconciled')::boolean,
 'a second reconciliation changes nothing');
reset role;
select test.assert((select state='reconciled' and actual_microusd=51200 and receipt_metadata->>'generation_id'='gen-102' from app_private.provider_attempts where id=:'T'),
 'the attempt carries the record cost and its receipt');
select test.assert((select actor_id is null and evidence_reference='openrouter-generation:gen-102' and released_liability_microusd=300000 and after_microusd=51200
 from app_private.provider_attempt_adjustments where attempt_id=:'T'),'audited like an owner reconciliation, with no actor');
select test.assert((select count(*)=1 from app_private.provider_attempt_events where attempt_id=:'T' and state='reconciled' and (details->>'automatic')::boolean),'one reconciled event');
select test.assert((select reserved_microusd=:reserved_before-300000 and spent_microusd=:spent_before+51200 from app_private.platform_budgets
 where period=date_trunc('month',now() at time zone 'UTC')::date),'the month: ceiling released, actual cost spent');
select test.assert((select last_outcome='reconciled' from app_private.openrouter_reconcile_queue where attempt_id=:'T'),'queue records the outcome');

-- A record that never comes: after 12 tries the attempt is left for an owner and named.
update app_private.provider_attempts set created_at=now()-interval '2 hours' where id=:'F';
set role service_role;
select test.assert(public.worker_openrouter_reconcile_claim(10)->0->>'attempt_id'=:'F','F claimable once old enough');
select public.worker_openrouter_reconcile_miss(:'F','not_found');
reset role;
update app_private.openrouter_reconcile_queue set tries=12,next_at=now()-interval '1 minute' where attempt_id=:'F';
set role service_role;
select test.assert(jsonb_array_length(public.worker_openrouter_reconcile_claim(10))=0,'given up after 12 tries');
select test.assert((public.worker_budget_health()->'reconciliation'->>'gave_up')::integer=1,'the budget check names it');
select test.assert((public.worker_budget_health()->'reconciliation'->>'without_generation')::integer=1,'and the one lost before its generation id');
select test.assert((public.worker_budget_health()->'reconciliation'->>'manual_held_microusd')::bigint=500000,'with the ceilings they still hold');
select test.assert((public.worker_budget_health()->'reconciliation'->>'reconciled_24h')::integer=1,'and what was reconciled today');
reset role;
select test.assert(app_private.admin_health_extra() ? 'reconciliation' and app_private.admin_health_extra() ? 'tariffs','Health carries both');
select test.assert(not has_function_privilege('authenticated','public.worker_openrouter_reconcile(uuid,text,jsonb,bigint,jsonb)','execute'),'service only');
rollback;
