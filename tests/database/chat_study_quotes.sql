-- Study map-update ceilings (migration 061, docs/architecture/CHAT.md#study): a chat quote may carry the
-- study_model / study_max_tokens / study_ceiling_microusd group, all three keys or none, never beside the follow-up
-- group; partial or null groups and a replay with a different ceiling are refused; a quote without it records nulls.
-- Runs after the HTML-first cutover migrations (scripts/test-database.py).
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
insert into auth.users(id) values('61000000-0000-0000-0000-00000000000a');
\set A '61000000-0000-0000-0000-00000000000a'
\set O '61000000-0000-0000-0001-000000000001'
\set R '61000000-0000-0000-0001-000000000003'
\set S '61000000-0000-0000-0001-000000000004'
\set Q '{"profile_version":"chat-profiles-v1","profile":"sonnet-low-standard","model":"claude-sonnet-5-5","effort":"low","length":"standard","tariff":"anthropic-list-prices-2026-10-08","max_output_tokens":9000,"input_estimate_tokens":40000,"max_searches":0,"title_model":"claude-haiku-5-5","title_max_tokens":40,"title_ceiling_microusd":3000}'
\set F '{"profile_version":"chat-profiles-v1","profile":"sonnet-low-standard","model":"claude-sonnet-5-5","effort":"low","length":"standard","tariff":"anthropic-list-prices-2026-10-08","max_output_tokens":9000,"input_estimate_tokens":40000,"max_searches":0,"title_model":"claude-haiku-5-5","title_max_tokens":40,"title_ceiling_microusd":3000,"study_model":"claude-haiku-5-5","study_max_tokens":1200,"study_ceiling_microusd":60000}'
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','study-a',1000,now()-interval '1 day',null,'Study quote fixture');
select test.assert(not (public.worker_reserve_chat(:'A',:'O',sha256('plain'),'beta-credits-v1',120,600000,:'Q'::jsonb)->>'replayed')::boolean,'a quote without the group still reserves');
select test.assert(not (public.worker_reserve_chat(:'A',:'R',sha256('follow'),'beta-credits-v1',130,609000,:'F'::jsonb)->>'replayed')::boolean,'reservation with a Study ceiling');
select test.assert((public.worker_reserve_chat(:'A',:'R',sha256('follow'),'beta-credits-v1',130,609000,:'F'::jsonb)->>'replayed')::boolean,'identical Study replay');
select test.reject(format('select public.worker_reserve_chat(%L,%L,sha256(%L),%L,130,609000,%L::jsonb)',:'A',:'R','follow','beta-credits-v1',
 jsonb_set(:'F'::jsonb,'{study_ceiling_microusd}','60001')),'operation_id_conflict');
select test.reject(format('select public.worker_reserve_chat(%L,%L,sha256(%L),%L,130,609000,%L::jsonb)',:'A',:'R','follow','beta-credits-v1',:'Q'),'operation_id_conflict');
select test.reject(format('select public.worker_reserve_chat(%L,%L,sha256(%L),%L,10,1000,%L::jsonb)',:'A',:'S','x','beta-credits-v1',q),'invalid_reservation')
 from (values ((:'F'::jsonb)-'study_model'),(jsonb_set(:'F'::jsonb,'{study_model}','null')),(jsonb_set(:'F'::jsonb,'{study_max_tokens}','"1200"')),
  (jsonb_set(:'F'::jsonb,'{study_ceiling_microusd}','-1')),(jsonb_set(:'F'::jsonb,'{study_model}','"Haiku 5.5"')),(:'Q'::jsonb||'{"study_model":"claude-haiku-5-5"}'),
  ((:'F'::jsonb)||'{"follow_ups_model":"claude-haiku-5-5","follow_ups_max_tokens":160,"follow_ups_ceiling_microusd":9000}'),
  ((:'F'::jsonb)||'{"prompt":"secret"}')) v(q);
reset role;
select test.assert((select study_model='claude-haiku-5-5' and study_max_tokens=1200 and study_ceiling_microusd=60000 and follow_ups_model is null and title_model='claude-haiku-5-5'
 from app_private.chat_quotes where account_id=:'A' and operation_id=:'R'),'Study ceiling recorded with the quote');
select test.assert((select study_model is null and study_max_tokens is null and study_ceiling_microusd is null
 from app_private.chat_quotes where account_id=:'A' and operation_id=:'O'),'a quote without the group records nulls');
select test.assert((select count(*)=0 from app_private.metered_operations where account_id=:'A' and id=:'S'),'a refused Study quote leaves no hold');
select test.assert((select reserved=250 from app_private.credit_buckets where external_key='study-a'),'only the valid holds are reserved');
set role service_role;
select public.worker_settle_operation(:'A',:'O',10,30000);
select public.worker_settle_operation(:'A',:'R',12,40000);
reset role;
select test.assert((select count(*)=2 from app_private.chat_quotes where account_id=:'A'),'quotes kept after settlement');
select test.reject(format('update app_private.chat_quotes set study_model=%L where account_id=%L','claude-sonnet-5-5',:'A'),'immutable');
rollback;
