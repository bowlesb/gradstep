-- 0101 (review A4): one renewable table of OpenRouter card validity, read by admission, snapshots, the chat policy read,
-- Health and the budget check; renewal is an owner's audited, bounded act; podcast quotes stop a day before a lapse.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set A '10100000-0000-4000-8000-000000000001'
\set W '10100000-0000-4000-8000-000000000002'
\set O '10100000-0000-4000-8001-000000000001'
insert into auth.users(id,email) values(:'A','tariff-101@gradstep.test.org'),(:'W','owner-101@gradstep.test.org');
insert into app_private.app_roles(account_id,role) values(:'W','owner');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','tariff-101',1000,now()-interval '1 day',null,'Tariff fixture');

select test.assert((select count(*)=7 and bool_and(valid_until='2027-01-01T00:00:00Z') from app_private.openrouter_tariffs),
 'every admitted model has its card, with the date it had (no price change)');
select test.assert(app_private.openrouter_tariff_expires('unlisted/model')='-infinity'::timestamptz,'a model without a card fails closed');
set role service_role;
select test.assert(public.worker_provider_spending_policy()->'openrouter_tariffs' ? 'anthropic/claude-sonnet-5.5','the chat policy read names each card');
select public.worker_reserve_operation(:'A',:'O','chat',sha256('tariff101'),'beta-credits-v1',40,200000);
create temp table attempt_ids(label text, id uuid) on commit drop;
reset role;
grant all on attempt_ids to service_role;
insert into attempt_ids values ('open',gen_random_uuid()),('lapsed',gen_random_uuid()),('renewed',gen_random_uuid());
set role service_role;
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',(select id from attempt_ids where label='open'),'openrouter','chat','anthropic/claude-haiku-5.5',sha256('open'),3000,'{"output_tokens":40}')->>'granted')::boolean,
 'a valid card admits');
reset role;
select test.assert((select pricing_snapshot->>'expires_at'='2027-01-01T00:00:00Z' from app_private.provider_attempts where id=(select id from attempt_ids where label='open')),
 'the snapshot records the card validity in the same format as before');

-- A lapsed card refuses, as before the table existed.
update app_private.openrouter_tariffs set valid_until=now()-interval '1 minute' where model='anthropic/claude-haiku-5.5';
set role service_role;
select test.assert(public.worker_provider_attempt_begin(:'A',:'O',(select id from attempt_ids where label='lapsed'),'openrouter','chat','anthropic/claude-haiku-5.5',sha256('lapsed'),3000,'{"output_tokens":40}')->>'reason'='tariff_expired',
 'a lapsed card is refused at admission');
-- Renewal: owner only, evidence and reason required, at most six months ahead, audited, replay-safe; no new models.
select test.reject(format('select public.worker_openrouter_tariff_renew(%L,gen_random_uuid(),%L,now()+interval %L,%L,%L)',:'A','anthropic/claude-haiku-5.5','30 days','endpoints 2026-12-01','Prices unchanged'),'owner');
select test.reject(format('select public.worker_openrouter_tariff_renew(%L,gen_random_uuid(),%L,now()+interval %L,%L,%L)',:'W','anthropic/claude-haiku-5.5','200 days','endpoints 2026-12-01','Prices unchanged'),'invalid_tariff_renewal');
select test.reject(format('select public.worker_openrouter_tariff_renew(%L,gen_random_uuid(),%L,now()+interval %L,%L,%L)',:'W','anthropic/claude-haiku-5.5','30 days','<bad>','Prices unchanged'),'invalid_tariff_renewal');
select test.reject(format('select public.worker_openrouter_tariff_renew(%L,gen_random_uuid(),%L,now()+interval %L,%L,%L)',:'W','openai/new-model','30 days','endpoints 2026-12-01','A new model'),'tariff_unknown');
select test.assert(not (public.worker_openrouter_tariff_renew(:'W','10100000-0000-4000-8009-000000000001','anthropic/claude-haiku-5.5','2027-03-01T00:00:00Z','endpoints 2026-12-01','Prices unchanged on review')->>'replayed')::boolean,'renewed');
select test.assert((public.worker_openrouter_tariff_renew(:'W','10100000-0000-4000-8009-000000000001','anthropic/claude-haiku-5.5','2027-03-01T00:00:00Z','endpoints 2026-12-01','Prices unchanged on review')->>'replayed')::boolean,'the same request replays');
select test.reject(format('select public.worker_openrouter_tariff_renew(%L,%L,%L,%L,%L,%L)',:'W','10100000-0000-4000-8009-000000000001','anthropic/claude-haiku-5.5','2027-04-01T00:00:00Z','endpoints 2026-12-01','Prices unchanged on review'),'request_id_conflict');
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',(select id from attempt_ids where label='renewed'),'openrouter','chat','anthropic/claude-haiku-5.5',sha256('renewed'),3000,'{"output_tokens":40}')->>'granted')::boolean,
 'a renewed card admits again, with no migration');
reset role;
select test.assert((select actor_id=:'W' and action='openrouter_tariff' and target_id='anthropic/claude-haiku-5.5' and details->>'evidence_reference'='endpoints 2026-12-01'
 from app_private.admin_audit_events where id='10100000-0000-4000-8009-000000000001'),'renewal audited to the owner, with its evidence');
select test.assert((select pricing_snapshot->>'expires_at'='2027-03-01T00:00:00Z' from app_private.provider_attempts where id=(select id from attempt_ids where label='renewed')),
 'the snapshot records the renewed validity');

-- Six weeks ahead: Health and the budget check warn.
update app_private.openrouter_tariffs set valid_until=now()+interval '20 days' where model='gemini-3.8-flash';
select test.assert(app_private.openrouter_tariff_attention()->'expiring'->0->>'model'='gemini-3.8-flash','a card within six weeks is listed');
select test.assert(app_private.admin_health_extra()->'tariffs'->'expiring'->0->>'model'='gemini-3.8-flash','Health carries it');
set role service_role;
select test.assert((public.worker_budget_health()->>'tariffs_expiring_within_42d')::integer=1,'the scheduled budget check counts it');
reset role;
select test.assert(not has_function_privilege('authenticated','public.worker_openrouter_tariff_renew(uuid,uuid,text,timestamptz,text,text)','execute'),'renewal is service-only');
select test.assert(not has_function_privilege('anon','public.v1_podcast_quote(uuid,uuid,text,text,jsonb)','execute'),'podcast quotes stay closed to anon');
select test.assert(has_function_privilege('authenticated','public.v1_podcast_quote(uuid,uuid,text,text,jsonb)','execute'),'readers can still ask for a quote');
rollback;
