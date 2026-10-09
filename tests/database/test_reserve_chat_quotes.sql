-- Chat quotes (migration 047): the chat reservation freezes its profile, model, output allowance, rate version and
-- tariff with the hold, atomically; replays must match; invalid quotes roll the hold back; only the service calls it.
begin;
insert into auth.users(id) values('47000000-0000-0000-0000-00000000000a');
\set A '47000000-0000-0000-0000-00000000000a'
\set O '47000000-0000-0000-0001-000000000001'
\set P '47000000-0000-0000-0001-000000000002'
\set Q '{"profile_version":"chat-profiles-v1","profile":"opus-high-detailed","model":"claude-opus-5-5","effort":"high","length":"detailed","tariff":"anthropic-list-prices-2026-10-08","max_output_tokens":18000,"input_estimate_tokens":41500,"max_searches":3,"title_model":"claude-haiku-5-5","title_max_tokens":40,"title_ceiling_microusd":420}'
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','quote-a',1000,now()-interval '1 day',null,'Quote fixture');
select test.assert(not (public.worker_reserve_chat(:'A',:'O',sha256('quote'),'beta-credits-v1',120,600000,:'Q'::jsonb)->>'replayed')::boolean,'chat reservation with its quote');
select test.assert((public.worker_reserve_chat(:'A',:'O',sha256('quote'),'beta-credits-v1',120,600000,:'Q'::jsonb)->>'replayed')::boolean,'identical replay');
select test.reject(format('select public.worker_reserve_chat(%L,%L,sha256(%L),%L,120,600000,%L::jsonb)',:'A',:'O','quote','beta-credits-v1',
 jsonb_set(:'Q'::jsonb,'{model}','"claude-sonnet-5-5"')),'operation_id_conflict');
-- Malformed quotes are refused before anything is held.
select test.reject(format('select public.worker_reserve_chat(%L,%L,sha256(%L),%L,10,1000,%L::jsonb)',:'A',:'P','x','beta-credits-v1',q),'invalid_reservation')
 from (values (:'Q'::jsonb-'tariff'),(:'Q'::jsonb||'{"prompt":"secret"}'),(jsonb_set(:'Q'::jsonb,'{max_output_tokens}','"18000"')),
  (jsonb_set(:'Q'::jsonb,'{max_output_tokens}','-1')),(jsonb_set(:'Q'::jsonb,'{max_output_tokens}','1.5')),
  (jsonb_set(:'Q'::jsonb,'{effort}','"max"')),(jsonb_set(:'Q'::jsonb,'{max_output_tokens}','200000')),
  (jsonb_set(:'Q'::jsonb,'{title_model}','null')),('[]'::jsonb),('null'::jsonb)) v(q);
reset role;
select test.assert((select count(*)=0 from app_private.metered_operations where account_id=:'A' and id=:'P'),'a refused quote leaves no hold');
select test.assert((select reserved=120 from app_private.credit_buckets where external_key='quote-a'),'only the valid hold is reserved');
select test.assert((select profile='opus-high-detailed' and model='claude-opus-5-5' and max_output_tokens=18000 and rate_version='beta-credits-v1'
 and tariff='anthropic-list-prices-2026-10-08' and title_model='claude-haiku-5-5' and credit_ceiling=120 and spend_ceiling_microusd=600000
 from app_private.chat_quotes where account_id=:'A' and operation_id=:'O'),'quote recorded with the reservation');
select test.reject(format('update app_private.chat_quotes set model=%L where account_id=%L','claude-haiku-5-5',:'A'),'immutable');
select test.reject(format('delete from app_private.chat_quotes where account_id=%L',:'A'),'immutable');
-- A quote without a title, and a repair quote, are both valid.
set role service_role;
select test.assert(not (public.worker_reserve_chat(:'A',:'P',sha256('repair'),'beta-credits-v1',5,20000,
 '{"profile_version":"chat-profiles-v1","profile":"diagram_fix","model":"claude-sonnet-5-5","effort":"low","length":"repair","tariff":"anthropic-list-prices-2026-10-08","max_output_tokens":2000,"input_estimate_tokens":3000,"max_searches":0,"title_model":null,"title_max_tokens":null,"title_ceiling_microusd":null}'::jsonb)->>'replayed')::boolean,'repair quote');
select public.worker_settle_operation(:'A',:'O',10,30000);
select public.worker_settle_operation(:'A',:'P',1,2000);
reset role;
select test.assert((select count(*)=2 from app_private.chat_quotes where account_id=:'A'),'quotes kept after settlement');
-- Customers and anonymous callers can neither reserve nor read quotes.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject(format('select public.worker_reserve_chat(%L,gen_random_uuid(),sha256(%L),%L,1,1,%L::jsonb)',:'A','x','beta-credits-v1',:'Q'),'permission denied');
select test.reject('select * from app_private.chat_quotes','permission denied');
reset role;
set role anon;
select test.reject('select * from app_private.chat_quotes','permission denied');
reset role;
rollback;
