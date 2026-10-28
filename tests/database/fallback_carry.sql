-- 0163 (JUDGMENT_LOG 55): a fallback after a silent attempt fits the reader's hold. The staging case of 2026-10-28 14:12 UTC
-- (paper explainer, quote 30 credits / 149,531 µ$; Flash silent with its 132,872 µ$ ceiling unresolved; Haiku's 149,531 µ$
-- denied `operation_ceiling`) is replayed: the old admission still refuses it, the fallback's admission carries the silent
-- ceiling for Gradstep (counted against the month, never the reader's credits), and settlement, Your AI usage and 0162's
-- assumed zero treat the silent attempt as before. Refusals (the month, the free pool, a testing cap), refusals that cost
-- nothing, output that arrived, replays and other operations carry nothing. Synthetic local SQL; no provider is called.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
\set A '16300000-0000-4000-8000-000000000001'
\set O '16300000-0000-4000-8001-000000000001'
\set FL '16300000-0000-4000-8002-000000000001'
\set HK '16300000-0000-4000-8002-000000000002'
\set Q '{"profile_version":"chat-profiles-v1","profile":"gemini-low-standard","model":"gemini-3.8-flash","effort":"low","length":"standard","tariff":"openrouter-google-flash-vertex-us-20261017","max_output_tokens":5500,"input_estimate_tokens":127135,"max_searches":0,"title_model":null,"title_max_tokens":null,"title_ceiling_microusd":null}'
\set MF '{"transport_model":"google/gemini-3.8-flash","endpoint":"google-vertex/us","feature":"paper_explainer","caller":"chat"}'
\set MH '{"transport_model":"anthropic/claude-haiku-5.5","endpoint":"google-vertex/us","feature":"paper_explainer","caller":"chat"}'
-- What chat's admittedModelCalls records for the silent attempt (staging's row): its estimate, `attempts`, no first output.
\set U '{"input_tokens":127135,"output_tokens":5500,"cache_read_tokens":0,"cache_write_5m_tokens":0,"cache_write_1h_tokens":0,"web_searches":0,"attempts":1}'
\set UH '{"input_tokens":578,"output_tokens":800,"cache_read_tokens":34562,"cache_write_5m_tokens":0,"cache_write_1h_tokens":0,"web_searches":0,"attempts":1,"first_data_ms":1800}'
insert into auth.users(id,email,email_confirmed_at) values(:'A','fallback-carry-163@gradstep.test.org',now());
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','fallback-carry-163',1000,now()-interval '1 day',null,'Fallback carry fixture');
-- One operation as chat reserves it, with a silent Flash attempt finished as chat finishes one.
create function test.silent(p_op uuid,p_attempt uuid,p_gen text,p_state text default 'unknown',p_units jsonb default null) returns void
language plpgsql as $$
begin
 perform public.worker_reserve_chat('16300000-0000-4000-8000-000000000001',p_op,sha256(convert_to(p_op::text,'UTF8')),'beta-credits-v1',30,149531,
  '{"profile_version":"chat-profiles-v1","profile":"gemini-low-standard","model":"gemini-3.8-flash","effort":"low","length":"standard","tariff":"openrouter-google-flash-vertex-us-20261017","max_output_tokens":5500,"input_estimate_tokens":127135,"max_searches":0,"title_model":null,"title_max_tokens":null,"title_ceiling_microusd":null}');
 perform test.assert((public.worker_openrouter_admit('16300000-0000-4000-8000-000000000001',p_op,p_attempt,'chat','gemini-3.8-flash',sha256(convert_to(p_attempt::text,'UTF8')),132872,
  '{"output_tokens":5500,"web_searches":0}','{"transport_model":"google/gemini-3.8-flash","endpoint":"google-vertex/us","feature":"paper_explainer","caller":"chat"}')->>'dispatched')::boolean,'primary sent');
 perform public.worker_provider_attempt_finish('16300000-0000-4000-8000-000000000001',p_op,p_attempt,p_state,p_gen,case when p_state='unknown' then null else 0 end,
  coalesce(p_units,case when p_state='unknown' then '{"input_tokens":127135,"output_tokens":5500,"cache_read_tokens":0,"cache_write_5m_tokens":0,"cache_write_1h_tokens":0,"web_searches":0,"attempts":1}'::jsonb
   else '{"input_tokens":0,"output_tokens":0,"cache_read_tokens":0,"cache_write_5m_tokens":0,"cache_write_1h_tokens":0,"web_searches":0,"attempts":0}'::jsonb end),'provider_error');
end $$;
-- The fallback's first request as chat sends it (Haiku's long-prompt ceiling, the staging figure).
create function test.fallback(p_op uuid,p_attempt uuid,p_after uuid) returns jsonb language sql as $$
 select public.worker_openrouter_admit_fallback('16300000-0000-4000-8000-000000000001',p_op,p_attempt,'chat','anthropic/claude-haiku-5.5',
  sha256(convert_to(p_attempt::text,'UTF8')),149531,'{"output_tokens":5500,"web_searches":0}',
  '{"transport_model":"anthropic/claude-haiku-5.5","endpoint":"google-vertex/us","feature":"paper_explainer","caller":"chat"}',p_after)
$$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;

select test.assert(has_function_privilege('service_role','public.worker_openrouter_admit_fallback(uuid,uuid,uuid,text,text,bytea,bigint,jsonb,jsonb,uuid)','execute')
 and not has_function_privilege('authenticated','public.worker_openrouter_admit_fallback(uuid,uuid,uuid,text,text,bytea,bigint,jsonb,jsonb,uuid)','execute')
 and not has_function_privilege('anon','public.worker_openrouter_admit_fallback(uuid,uuid,uuid,text,text,bytea,bigint,jsonb,jsonb,uuid)','execute'),
 'the fallback admission is the chat function''s only');
select test.assert(has_function_privilege('service_role','public.worker_reserve_chat(uuid,uuid,bytea,text,bigint,bigint,jsonb)','execute')
 and not has_function_privilege('authenticated','public.worker_reserve_chat(uuid,uuid,bytea,text,bigint,bigint,jsonb)','execute')
 and not has_function_privilege('service_role','app_private.reserve_chat_before_0163(uuid,uuid,bytea,text,bigint,bigint,jsonb)','execute'),
 'the reservation keeps its grants; the inner function is private');

select reserved_microusd as base_reserved,spent_microusd as base_spent from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date \gset

-- 1. The staging case.
set role service_role;
select test.silent(:'O',:'FL','gen-silent-163');
reset role;
select test.assert((select reserved_microusd=:base_reserved+149531 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),
 'the month holds the reader''s hold');
-- Before 0163 (and still, through the plain admission): the silent ceiling fills the hold; the fallback is refused.
savepoint before_0163;
set role service_role;
select test.assert(public.worker_openrouter_admit(:'A',:'O',:'HK','chat','anthropic/claude-haiku-5.5',sha256('hk'),149531,'{"output_tokens":5500,"web_searches":0}',:'MH')
 ->>'reason'='operation_ceiling','the 14:12 refusal: 132,872 + 149,531 > 149,531');
reset role;
rollback to savepoint before_0163;
-- The fallback's admission: the silent ceiling moves out of the reader's hold, and the fallback fits.
set role service_role;
select test.fallback(:'O',:'HK',:'FL') as admitted \gset
reset role;
select test.assert((:'admitted'::jsonb->>'granted')::boolean and (:'admitted'::jsonb->>'dispatched')::boolean
 and (:'admitted'::jsonb->>'carried_microusd')::bigint=132872 and not (:'admitted'::jsonb ? 'carry_refused'),'granted, dispatched, carried');
select test.assert((select spend_ceiling_microusd=149531+132872 and credit_ceiling=30 and state='reserved' from app_private.metered_operations where id=:'O'),
 'the operation''s provider ceiling grows by the silent ceiling; the reader''s credit hold is the quote''s');
select test.assert((select spend_ceiling_microusd=149531 and credit_ceiling=30 from app_private.chat_quotes where operation_id=:'O'),'the quote is unchanged');
select test.assert((select reserved_microusd=:base_reserved+149531+132872 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),
 'the month counts the carried ceiling');
select test.assert((select sum(reserved)=30 from app_private.credit_buckets where account_id=:'A'),'the reader''s credits held: the quote''s 30, no more');
select sum(balance) as balance_before from app_private.credit_buckets where account_id=:'A' \gset
select test.assert((select count(*)=1 and (min(details->>'carried_microusd'))::bigint=132872 and min(details->>'fallback_attempt_id')=:'HK'
 and (min(details->>'spend_ceiling_before'))::bigint=149531 and (min(details->>'spend_ceiling_after'))::bigint=282403
 from app_private.provider_attempt_events where attempt_id=:'FL' and state='carried'),'a carried event on the silent attempt');
select test.assert(app_private.operation_carried_microusd(:'A',:'O')=132872,'what the operation carries');
select test.assert((select state='unknown' and ceiling_microusd=132872 and failure_code='provider_error' and actual_microusd is null
 from app_private.provider_attempts where id=:'FL'),'the silent attempt itself is untouched');
-- A replayed admission carries nothing more; a replayed reservation is still a replay, never a conflict.
set role service_role;
select test.fallback(:'O',:'HK',:'FL') as replayed \gset
select test.assert(:'replayed'::jsonb->>'reason'='attempt_replayed' and (:'replayed'::jsonb->>'carried_microusd')::bigint=0,'replay: no second carry');
select test.assert((public.worker_reserve_chat(:'A',:'O',sha256(convert_to(:'O','UTF8')),'beta-credits-v1',30,149531,:'Q'::jsonb)->>'replayed')::boolean,
 'the device''s retry of the same operation is a replay');
select test.reject(format('select public.worker_reserve_chat(%L,%L,sha256(convert_to(%L,%L)),%L,30,282403,%L::jsonb)',:'A',:'O',:'O','UTF8','beta-credits-v1',:'Q'),
 'operation_id_conflict');
reset role;
select test.assert((select spend_ceiling_microusd=282403 from app_private.metered_operations where id=:'O')
 and (select count(*)=1 from app_private.provider_attempt_events where attempt_id=:'FL' and state='carried'),'still one carry');

-- Haiku answers; the reader pays only that answer; the silent ceiling stays Gradstep's unresolved liability.
set role service_role;
select public.worker_provider_attempt_finish(:'A',:'O',:'HK','succeeded','gen-haiku-163',8069,:'UH',null);
select public.worker_settle_chat(:'A',:'O',2,8069,'answer','completed',0);
reset role;
select test.assert((select state='settled' and actual_credits=2 and actual_microusd=8069 and provider_liability_microusd=132872
 from app_private.metered_operations where id=:'O'),'settled: 2 credits for Haiku''s answer; the silent ceiling is the liability');
select test.assert((select reserved_microusd=:base_reserved+132872 and spent_microusd=:base_spent+8069 from app_private.platform_budgets
 where period=date_trunc('month',now() at time zone 'UTC')::date),'the month: the hold released, the liability kept, the answer spent');
select test.assert(not exists(select 1 from app_private.budget_anomalies where operation_id=:'O'),
 'no overrun: the carried ceiling is inside the operation''s provider ceiling');
select test.assert((select sum(reserved)=0 and sum(balance)=:balance_before-2 from app_private.credit_buckets where account_id=:'A'),'the reader paid 2 credits');
select test.assert((select ending='completed' and charged and credits=2 from app_private.chat_endings where operation_id=:'O'),'the ending');
-- Your AI usage (0160, 0161): the model that wrote it, the silent call flagged as unreported, the credits as settled.
select test.assert((select model='anthropic/claude-haiku-5.5' and credits=2 and calls=2 and unreported_calls=1 and output_tokens=800 and pending
 from app_private.usage_operations(:'A',now()-interval '1 day') where id=:'O'),'usage names Haiku, leaves the silent estimate out and says it is being checked');

-- 0162: after 12 tries with no OpenRouter record, the silent attempt is assumed zero and its ceiling leaves the month.
update app_private.provider_attempts set created_at=now()-interval '2 hours' where operation_id=:'O';
set role service_role;
select public.worker_openrouter_reconcile_claim(50) \g /dev/null
reset role;
update app_private.openrouter_reconcile_queue set tries=11,next_at=now()-interval '1 minute' where attempt_id=:'FL';
set role service_role;
select test.assert(exists(select 1 from jsonb_array_elements(public.worker_openrouter_reconcile_claim(50)) c where c->>'attempt_id'=:'FL' and (c->>'final')::boolean),
 'a candidate on its 12th try');
select public.worker_openrouter_reconcile_absent(:'FL','gen-silent-163') as absent \gset
reset role;
select test.assert((:'absent'::jsonb->>'settled')::boolean and (:'absent'::jsonb->>'released_microusd')::bigint=132872,'assumed zero, its ceiling released');
select test.assert((select provider_liability_microusd=0 and actual_credits=2 from app_private.metered_operations where id=:'O'),'no liability left; credits unchanged');
select test.assert((select reserved_microusd=:base_reserved and spent_microusd=:base_spent+8069 from app_private.platform_budgets
 where period=date_trunc('month',now() at time zone 'UTC')::date),'the month is back to its base reservation');
select test.assert((select state='reconciled' and actual_microusd=0 and failure_code='provider_error' and not app_private.usage_reported(state,actual_units)
 from app_private.provider_attempts where id=:'FL'),'reconciled at 0, failure kept, still unreported');
select test.assert((select model='anthropic/claude-haiku-5.5' and credits=2 and unreported_calls=1 and not pending
 from app_private.usage_operations(:'A',now()-interval '1 day') where id=:'O'),'usage: no longer being checked');

-- 2. Nothing to carry: a refusal that cost nothing (a 429), and an attempt whose output arrived.
\set O2 '16300000-0000-4000-8001-000000000002'
\set O3 '16300000-0000-4000-8001-000000000003'
set role service_role;
select test.silent(:'O2','16300000-0000-4000-8002-000000000021','gen-429-163','rejected');
select test.fallback(:'O2','16300000-0000-4000-8002-000000000022','16300000-0000-4000-8002-000000000021') as refused429 \gset
select test.silent(:'O3','16300000-0000-4000-8002-000000000031','gen-out-163','unknown',jsonb_set(:'U'::jsonb,'{first_data_ms}','900'));
select test.fallback(:'O3','16300000-0000-4000-8002-000000000032','16300000-0000-4000-8002-000000000031') as output \gset
reset role;
select test.assert((:'refused429'::jsonb->>'granted')::boolean and (:'refused429'::jsonb->>'carried_microusd')::bigint=0,'a 429: fits without a carry');
select test.assert(not (:'output'::jsonb->>'granted')::boolean and :'output'::jsonb->>'reason'='operation_ceiling'
 and (:'output'::jsonb->>'carried_microusd')::bigint=0,'output arrived: never carried (and no fallback is asked then)');
select test.assert((select spend_ceiling_microusd=149531 from app_private.metered_operations where id=:'O2')
 and (select spend_ceiling_microusd=149531 from app_private.metered_operations where id=:'O3'),'ceilings unchanged');
set role service_role;
select public.worker_settle_chat(:'A',o,0,0,'answer','provider',0) from unnest(array[:'O2',:'O3']::uuid[]) o;
reset role;

-- 3. The month, the free pool or a testing cap cannot take the carried ceiling: nothing is carried; the fallback is refused
-- by the operation's own bound, as before, and the reason is returned for the log.
\set O4 '16300000-0000-4000-8001-000000000004'
\set O5 '16300000-0000-4000-8001-000000000005'
\set O6 '16300000-0000-4000-8001-000000000006'
set role service_role;
select test.silent(:'O4','16300000-0000-4000-8002-000000000041','gen-month-163');
select test.silent(:'O5','16300000-0000-4000-8002-000000000051','gen-pool-163');
select test.silent(:'O6','16300000-0000-4000-8002-000000000061','gen-cap-163');
reset role;
select reserved_microusd as r4 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date \gset
update app_private.platform_budgets set limit_microusd=spent_microusd+reserved_microusd+132871 where period=date_trunc('month',now() at time zone 'UTC')::date;
set role service_role;
select test.fallback(:'O4','16300000-0000-4000-8002-000000000042','16300000-0000-4000-8002-000000000041') as month \gset
reset role;
select test.assert(not (:'month'::jsonb->>'granted')::boolean and :'month'::jsonb->>'reason'='operation_ceiling'
 and :'month'::jsonb->>'carry_refused'='platform_budget_exhausted' and (:'month'::jsonb->>'carried_microusd')::bigint=0,'the month is full: refused');
select test.assert((select spend_ceiling_microusd=149531 from app_private.metered_operations where id=:'O4')
 and (select reserved_microusd=:r4 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date)
 and not exists(select 1 from app_private.provider_attempt_events where attempt_id='16300000-0000-4000-8002-000000000041' and state='carried'),
 'nothing moved');
update app_private.platform_budgets set limit_microusd=10000000 where period=date_trunc('month',now() at time zone 'UTC')::date;
update app_private.metered_operations set free_funded=true where id=:'O5';
update app_private.ai_controls set free_pool_microusd=app_private.free_pool_used()+132871;
set role service_role;
select test.fallback(:'O5','16300000-0000-4000-8002-000000000052','16300000-0000-4000-8002-000000000051') as pool \gset
reset role;
select test.assert(:'pool'::jsonb->>'carry_refused'='free_pool_exhausted' and not (:'pool'::jsonb->>'granted')::boolean,'free credits pay and the pool is full: refused');
update app_private.ai_controls set free_pool_microusd=15000000;
insert into app_private.testing_allowances(account_id,enabled,bucket_id,monthly_cap_microusd)
 select :'A',true,id,app_private.account_month_spend(:'A')+132871 from app_private.credit_buckets where account_id=:'A' limit 1;
set role service_role;
select test.fallback(:'O6','16300000-0000-4000-8002-000000000062','16300000-0000-4000-8002-000000000061') as cap \gset
reset role;
select test.assert(:'cap'::jsonb->>'carry_refused'='testing_cap_reached' and not (:'cap'::jsonb->>'granted')::boolean,'a testing cap that cannot take it: refused');
delete from app_private.testing_allowances where account_id=:'A';
-- With room again, the same fallback is carried and admitted.
set role service_role;
select test.assert((test.fallback(:'O4','16300000-0000-4000-8002-000000000043','16300000-0000-4000-8002-000000000041')->>'carried_microusd')::bigint=132872,
 'carried once the month has room');
select public.worker_settle_chat(:'A',o,0,0,'answer','provider',0) from unnest(array[:'O4',:'O5',:'O6']::uuid[]) o;
reset role;
select test.assert(not exists(select 1 from app_private.budget_anomalies where account_id=:'A'),'no overruns anywhere');

-- 4. Carried, then refused for another reason (the month paused): the carry is undone in the same transaction.
\set O7 '16300000-0000-4000-8001-000000000007'
set role service_role;
select test.silent(:'O7','16300000-0000-4000-8002-000000000071','gen-paused-163');
reset role;
select reserved_microusd as r7 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date \gset
update app_private.platform_budgets set work_enabled=false where period=date_trunc('month',now() at time zone 'UTC')::date;
set role service_role;
select test.fallback(:'O7','16300000-0000-4000-8002-000000000072','16300000-0000-4000-8002-000000000071') as paused \gset
reset role;
select test.assert(:'paused'::jsonb->>'reason'='platform_paused' and (:'paused'::jsonb->>'carried_microusd')::bigint=0,'paused: refused, nothing carried');
select test.assert((select spend_ceiling_microusd=149531 from app_private.metered_operations where id=:'O7')
 and (select reserved_microusd=:r7 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date)
 and not exists(select 1 from app_private.provider_attempt_events where attempt_id='16300000-0000-4000-8002-000000000071' and state='carried'),'undone');
update app_private.platform_budgets set work_enabled=true where period=date_trunc('month',now() at time zone 'UTC')::date;

-- 5. Only an attempt of the same operation, never the fallback itself; a settled operation carries nothing.
set role service_role;
select test.reject(format('select test.fallback(%L,gen_random_uuid(),%L)',:'O7','16300000-0000-4000-8002-000000000041'),'invalid_provider_attempt');
select test.reject(format('select test.fallback(%L,%L,%L)',:'O7','16300000-0000-4000-8002-000000000071','16300000-0000-4000-8002-000000000071'),'invalid_provider_attempt');
select public.worker_settle_chat(:'A',:'O7',0,0,'answer','provider',0);
select test.fallback(:'O7','16300000-0000-4000-8002-000000000073','16300000-0000-4000-8002-000000000071') as settled \gset
reset role;
select test.assert(:'settled'::jsonb->>'reason'='operation_settled' and (:'settled'::jsonb->>'carried_microusd')::bigint=0,'settled: nothing carried');
rollback;
