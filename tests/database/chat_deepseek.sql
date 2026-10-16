-- DeepSeek in chat (migration 078, docs/architecture/CHAT.md "DeepSeek in chat"): a chat quote names the DeepSeek
-- profile, model and tariff; a deepseek attempt is admitted on the chat route for deepseek-flash only, with its peak
-- pricing snapshot, and refused for any other DeepSeek model, any other non-podcast route and any provider search; its
-- Haiku title in the same operation is an Anthropic attempt; each attempt writes its own usage row and the operation's
-- summary is not counted again, while a summary for an operation without model attempts (and Tavily's) is still kept.
-- Synthetic local SQL; nothing leaves the machine. Runs after the HTML-first cutover migrations (scripts/test-database.py).
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

insert into auth.users(id) values('78000000-0000-0000-0000-00000000000a');
\set A '78000000-0000-0000-0000-00000000000a'
\set O '78000000-0000-0000-0001-000000000001'
\set P '78000000-0000-0000-0001-000000000002'
\set D1 '78000000-0000-0000-0002-000000000001'
\set D2 '78000000-0000-0000-0002-000000000002'
\set H1 '78000000-0000-0000-0002-000000000003'
\set X '78000000-0000-0000-0002-000000000009'
\set Q '{"profile_version":"chat-profiles-v1","profile":"deepseek-medium-standard","model":"deepseek-flash","effort":"medium","length":"standard","tariff":"deepseek-peak-list-prices-2026-10-16","max_output_tokens":10000,"input_estimate_tokens":120000,"max_searches":0,"title_model":"claude-haiku-5-5","title_max_tokens":40,"title_ceiling_microusd":3000,"follow_ups_model":"claude-haiku-5-5","follow_ups_max_tokens":160,"follow_ups_ceiling_microusd":9000}'
select coalesce((select spent_microusd from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),0) as initial_spent \gset

set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','deepseek-chat-a',1000,now()-interval '1 day',null,'DeepSeek chat fixture');

-- The quote: a DeepSeek profile with its resolved effort, model and tariff (the chat_quotes rules admit it unchanged).
select test.assert(not (public.worker_reserve_chat(:'A',:'O',sha256('deepseek'),'beta-credits-v1',40,200000,:'Q'::jsonb)->>'replayed')::boolean,'a DeepSeek quote reserves');
select test.reject(format('select public.worker_reserve_chat(%L,%L,sha256(%L),%L,40,200000,%L::jsonb)',:'A',:'P','auto','beta-credits-v1',
 jsonb_set(:'Q'::jsonb,'{effort}','"auto"')),'invalid_reservation');

-- The answer's attempt: deepseek on chat, deepseek-flash only, with DeepSeek's peak chat snapshot.
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',:'D1','deepseek','chat','deepseek-flash',sha256('round-1'),100000,'{"output_tokens":10000,"web_searches":0}')->>'granted')::boolean,
 'a deepseek-flash chat attempt is admitted');
reset role;
select test.assert((select provider='deepseek' and route='chat' and model='deepseek-flash' and state='admitted'
  and pricing_snapshot->>'tariff'='deepseek-token-rates-peak-20261016' and pricing_snapshot->>'version'='provider-bounds-20261016-chat-deepseek-v1'
  and (pricing_snapshot->'rates_microusd'->'flash'->>'input')::numeric=0.3 and (pricing_snapshot->'rates_microusd'->'flash'->>'output')::numeric=1.2
  and (pricing_snapshot->'rates_microusd'->'flash'->>'cache_read')::numeric=0.006
 from app_private.provider_attempts where id=:'D1'),'the attempt records DeepSeek and its peak rates');
set role service_role;
-- Any other DeepSeek model on chat, and every other non-podcast route, is refused before any accounting.
select test.reject(format('select public.worker_provider_attempt_begin(%L,%L,gen_random_uuid(),%L,%L,%L,sha256(%L),1000,%L::jsonb)',:'A',:'O',
 'deepseek','chat',m,'x','{"output_tokens":1}'),'invalid_provider_route')
 from (values ('deepseek-v4-pro'),('deepseek-chat'),('claude-sonnet-5-5')) v(m);
select test.reject(format('select public.worker_provider_attempt_begin(%L,%L,gen_random_uuid(),%L,%L,%L,sha256(%L),0,%L::jsonb)',:'A',:'O',
 'deepseek',r,'deepseek-flash','x','{"output_tokens":1}'),'invalid_provider_route')
 from (values ('chat_search'),('ingest_lookup'),('reference_lookup'),('catalog_tags'),('paper_ocr')) v(r);
-- DeepSeek never reserves a provider-side search (our Tavily tool has its own attempts).
select test.assert(public.worker_provider_attempt_begin(:'A',:'O',:'X','deepseek','chat','deepseek-flash',sha256('search'),50000,'{"output_tokens":100,"web_searches":3}')->>'reason'='native_search_unbounded',
 'a DeepSeek attempt reserving provider searches is denied');
-- A second round and the title (Claude Haiku) in the same operation.
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',:'D2','deepseek','chat','deepseek-flash',sha256('round-2'),60000,'{"output_tokens":4000,"web_searches":0}')->>'granted')::boolean,'a second round');
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',:'H1','anthropic','chat','claude-haiku-5-5',sha256('title'),3000,'{"output_tokens":40,"web_searches":0}')->>'granted')::boolean,'the Haiku title beside it');
select test.assert(public.worker_provider_attempt_begin(:'A',:'O',gen_random_uuid(),'deepseek','chat','deepseek-flash',sha256('round-3'),40000,'{"output_tokens":1}')->>'reason'='operation_ceiling',
 'rounds stay within the quoted spend ceiling');

-- Results: 30,000 cache-miss and 90,000 cache-hit input tokens and 1,500 output at peak rates.
select public.worker_provider_attempt_finish(:'A',:'O',:'D1','succeeded','6cc16e60-0ea4-4c29-a968-97f1b454d64e',ceil(30000*0.3+90000*0.006+1500*1.2)::bigint,
 '{"input_tokens":30000,"cache_read_tokens":90000,"output_tokens":1500,"attempts":1}',null);
select public.worker_provider_attempt_finish(:'A',:'O',:'D2','succeeded','8bde3cc9-0dd8-4bbe-b312-4d14b95d2f65',ceil(1000*0.3+121000*0.006+800*1.2)::bigint,
 '{"input_tokens":1000,"cache_read_tokens":121000,"output_tokens":800,"attempts":1}',null);
select public.worker_provider_attempt_finish(:'A',:'O',:'H1','succeeded','msg_title',1200,'{"input_tokens":1000,"output_tokens":10,"attempts":1}',null);
select public.worker_settle_operation(:'A',:'O',4,11340+1986+1200);
-- The chat function's summary under the answering provider (and under Anthropic): not a second count of the same spend.
select public.worker_record_provider_usage(:'A',:'O','deepseek','6cc16e60-0ea4-4c29-a968-97f1b454d64e','deepseek-flash','{"estimated":false}',14526);
select public.worker_record_provider_usage(:'A',:'O','anthropic','summary-anthropic','claude-haiku-5-5','{}',14526);
-- Tavily's summary keeps its own rule: kept when the operation has no Tavily attempt.
select public.worker_record_provider_usage(:'A',:'O','tavily','operation:'||:'O','search-basic','{"searches":1,"credits":1}',0);
reset role;

select test.assert((select count(*)=3 from app_private.provider_usage_events where operation_id=:'O' and provider_event_id like 'attempt:%'),'one usage row per attempt');
select test.assert((select estimated_microusd=11340 and provider='deepseek' and model='deepseek-flash' from app_private.provider_usage_events where provider_event_id='attempt:'||:'D1'),
 'the DeepSeek round is priced at peak rates under DeepSeek');
select test.assert((select provider='anthropic' from app_private.provider_usage_events where provider_event_id='attempt:'||:'H1'),'the title is an Anthropic row');
select test.assert(not exists(select 1 from app_private.provider_usage_events where operation_id=:'O' and provider in ('deepseek','anthropic') and provider_event_id not like 'attempt:%'),
 'no summary row counts the model spend twice');
select test.assert(exists(select 1 from app_private.provider_usage_events where operation_id=:'O' and provider='tavily'),'the Tavily summary is still kept');
select test.assert((select spent_microusd=:'initial_spent'::bigint+11340+1986+1200 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),
 'provider spend is the attempts once');
select test.assert((select actual_credits=4 and state='settled' from app_private.metered_operations where account_id=:'A' and id=:'O'),'settled at the reader''s credits');

-- An operation whose model attempts were all denied keeps the summary (the behaviour before attempts).
set role service_role;
select public.worker_reserve_operation(:'A',:'P','chat',sha256('denied'),'beta-credits-v1',10,50000);
select test.assert(public.worker_provider_attempt_begin(:'A',:'P',gen_random_uuid(),'deepseek','chat','deepseek-flash',sha256('denied'),40000,'{"output_tokens":100,"web_searches":2}')->>'reason'='native_search_unbounded','denied attempt');
select public.worker_settle_operation(:'A',:'P',0,0);
select public.worker_record_provider_usage(:'A',:'P','deepseek','operation:'||:'P','deepseek-flash','{"estimated":true}',0);
reset role;
select test.assert(exists(select 1 from app_private.provider_usage_events where operation_id=:'P' and provider='deepseek' and provider_event_id='operation:'||:'P'),
 'a summary without admitted attempts is recorded');
rollback;
