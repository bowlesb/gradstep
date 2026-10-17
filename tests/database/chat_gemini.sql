-- Gemini/OpenRouter admission and durable accounting, migration 085. Local synthetic data only.
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

insert into auth.users(id) values('85000000-0000-0000-0000-00000000000a');
\set A '85000000-0000-0000-0000-00000000000a'
\set O '85000000-0000-0000-0001-000000000001'
\set P '85000000-0000-0000-0001-000000000002'
\set D1 '85000000-0000-0000-0002-000000000001'
\set D2 '85000000-0000-0000-0002-000000000002'
\set H1 '85000000-0000-0000-0002-000000000003'
\set X '85000000-0000-0000-0002-000000000009'
\set Q '{"profile_version":"chat-profiles-v1","profile":"gemini-medium-standard","model":"gemini-3.8-flash","effort":"medium","length":"standard","tariff":"openrouter-google-flash-vertex-us-20261017","max_output_tokens":10000,"input_estimate_tokens":120000,"max_searches":0,"title_model":"claude-haiku-5-5","title_max_tokens":40,"title_ceiling_microusd":3000,"follow_ups_model":"claude-haiku-5-5","follow_ups_max_tokens":160,"follow_ups_ceiling_microusd":9000}'
select coalesce((select spent_microusd from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),0) as initial_spent \gset

set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','gemini-chat-a',1000,now()-interval '1 day',null,'Gemini chat fixture');


select test.assert(not (public.worker_reserve_chat(:'A',:'O',sha256('gemini'),'beta-credits-v1',40,200000,:'Q'::jsonb)->>'replayed')::boolean,'Gemini quote reserves');
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',:'D1','openrouter','chat','gemini-3.8-flash',sha256('round'),100000,'{"output_tokens":10000,"web_searches":0}')->>'granted')::boolean,'only the pinned Gemini route is admitted');
select test.assert(public.worker_provider_attempt_begin(:'A',:'O',:'D1','openrouter','chat','gemini-3.8-flash',sha256('round'),100000,'{"output_tokens":10000,"web_searches":0}')->>'reason'='attempt_replayed','same attempt cannot send twice');
select test.reject(format('select public.worker_provider_attempt_begin(%L,%L,gen_random_uuid(),%L,%L,%L,sha256(%L),1000,%L::jsonb)',:'A',:'O',
 'openrouter','chat',m,'x','{"output_tokens":1}'),'invalid_provider_route') from (values ('gemini-4-argon'),('claude-sonnet-5-5'),('google/gemini-3.8-flash')) v(m);
select test.reject(format('select public.worker_provider_attempt_begin(%L,%L,gen_random_uuid(),%L,%L,%L,sha256(%L),1000,%L::jsonb)',:'A',:'O',
 'openrouter',r,'gemini-3.8-flash','x','{"output_tokens":1}'),'invalid_provider_route') from (values ('catalog_tags'),('podcast_script'),('podcast_speech'),('chat_search')) v(r);
select test.assert(public.worker_provider_attempt_begin(:'A',:'O',:'X','openrouter','chat','gemini-3.8-flash',sha256('search'),1000,'{"output_tokens":100,"web_searches":1}')->>'reason'='native_search_unbounded','no provider-native search');
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',:'H1','anthropic','chat','claude-haiku-5-5',sha256('title'),3000,'{"output_tokens":40}')->>'granted')::boolean,'title remains a separately metered Anthropic attempt');
select public.worker_provider_attempt_finish(:'A',:'O',:'D1','succeeded','gen-test-85',1267,'{"input_tokens":1000,"cache_read_tokens":3000,"cache_storage_tokens":3000,"output_tokens":100}',null);
select public.worker_provider_attempt_finish(:'A',:'O',:'D1','succeeded','gen-test-85',1267,'{"input_tokens":1000,"cache_read_tokens":3000,"cache_storage_tokens":3000,"output_tokens":100}',null);
select public.worker_provider_attempt_finish(:'A',:'O',:'H1','succeeded','msg-title-85',100,'{"output_tokens":40}',null);
select public.worker_settle_operation(:'A',:'O',1,1367);
select public.worker_record_provider_usage(:'A',:'O','openrouter','operation:'||:'O','gemini-3.8-flash','{}',1367);
select public.worker_record_provider_usage(:'A',:'O','anthropic','summary-title-85','claude-haiku-5-5','{}',1367);
reset role;
select test.assert((select actual_units->>'cache_storage_tokens'='3000' and actual_units->>'cache_read_tokens'='3000'
 from app_private.provider_attempts where id=:'D1'),'overlapping storage/read counts retained separately');
select test.assert(not app_private.valid_provider_units('{"cache_storage_tokens":-1}')
 and not app_private.valid_provider_units('{"cache_storage_tokens":"3000"}')
 and not app_private.valid_provider_units('{"prompt_content":1}'),'unit bounds and allowlist still enforced');
select test.assert((select pricing_snapshot->>'inference_provider'='google-vertex/us' and pricing_snapshot->>'zdr'='true' and pricing_snapshot->>'cost_source'='openrouter_final_usage'
 and pricing_snapshot->>'tariff'='openrouter-google-flash-vertex-us-20261017' from app_private.provider_attempts where id=:'D1'),'frozen route and price evidence');
select test.assert((select count(*)=2 and sum(estimated_microusd)=1367 from app_private.provider_usage_events where operation_id=:'O'),'exactly one cost per attempt, no duplicate summary or retry');
select test.assert((select spent_microusd=:'initial_spent'::bigint+1367 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),'platform pays actual reported cost');
-- A lost final bill remains reserved after the failed answer releases customer credits.
set role service_role;
select public.worker_reserve_operation(:'A',:'P','chat',sha256('unknown'),'beta-credits-v1',10,50000);
select public.worker_provider_attempt_begin(:'A',:'P',:'D2','openrouter','chat','gemini-3.8-flash',sha256('unknown'),40000,'{"output_tokens":1000}');
select public.worker_provider_attempt_finish(:'A',:'P',:'D2','unknown','gen-lost-85',null,'{}','aborted');
select public.worker_settle_operation(:'A',:'P',0,0);
reset role;
select test.assert((select provider_liability_microusd=40000 and actual_credits=0 from app_private.metered_operations where account_id=:'A' and id=:'P'),'unknown cost is retained; reader is not charged for a failed answer');
rollback;
