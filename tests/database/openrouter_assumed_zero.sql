-- 0162 (JUDGMENT_LOG 21): an OpenRouter attempt left `unknown` that sent no output and that OpenRouter still has no record
-- of after 12 tries (or that never got a generation id) settles at zero, distinguishably and audited: never charged to the
-- reader, the hold released, never counted as provider-reported usage, shown on Health and Spending, and corrected by a
-- late record. Everything else keeps 0102's behaviour. Synthetic local SQL; no provider is called.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set A '16200000-0000-4000-8000-000000000001'
\set OWN '16200000-0000-4000-8000-0000000000ff'
\set O '16200000-0000-4000-8001-000000000001'
\set O2 '16200000-0000-4000-8001-000000000002'
\set Z1 '16200000-0000-4000-8002-000000000001'
\set Z2 '16200000-0000-4000-8002-000000000002'
\set Z3 '16200000-0000-4000-8002-000000000003'
\set Z4 '16200000-0000-4000-8002-000000000004'
\set Z5 '16200000-0000-4000-8002-000000000005'
\set Z6 '16200000-0000-4000-8002-000000000006'
\set Z7 '16200000-0000-4000-8002-000000000007'
\set Z8 '16200000-0000-4000-8002-000000000008'
\set M '{"transport_model":"anthropic/claude-sonnet-5.5","endpoint":"google-vertex/us","feature":"chat","caller":"chat"}'
\set P '{"transport_model":"anthropic/claude-sonnet-5.5","endpoint":"google-vertex/us","feature":"podcast_script","caller":"podcast"}'
-- What chat's admittedModelCalls records for a stream with no bill: its hold estimate, `attempts`, no `first_data_ms`.
\set U '{"input_tokens":53535,"output_tokens":10000,"cache_read_tokens":0,"cache_write_5m_tokens":0,"cache_write_1h_tokens":0,"web_searches":0,"attempts":1}'
\set UF '{"input_tokens":53535,"output_tokens":10000,"cache_read_tokens":0,"cache_write_5m_tokens":0,"cache_write_1h_tokens":0,"web_searches":0,"attempts":1,"first_data_ms":4200}'
\set R '{"generation_id":"gen-z1","provider":"Google","model":"anthropic/claude-sonnet-5.5","total_cost_microusd":51200}'
insert into auth.users(id,email,email_confirmed_at) values(:'A','assumed-zero-162@gradstep.test.org',now()),(:'OWN','owner-162@gradstep.test.org',now());
insert into app_private.app_roles(account_id,role) values(:'OWN','owner');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','assumed-zero-162',1000,now()-interval '1 day',null,'Assumed zero fixture');
select test.assert(has_function_privilege('service_role','public.worker_openrouter_reconcile_absent(uuid,text)','execute')
 and not has_function_privilege('authenticated','public.worker_openrouter_reconcile_absent(uuid,text)','execute')
 and not has_function_privilege('anon','public.worker_openrouter_reconcile_absent(uuid,text)','execute'),'the zero settlement is the worker''s only');

set role service_role;
select public.worker_reserve_operation(:'A',:'O','chat',sha256('assumed-zero-162'),'beta-credits-v1',100,900000);
select public.worker_reserve_operation(:'A',:'O2','chat',sha256('assumed-zero-162-open'),'beta-credits-v1',10,200000);
-- Z1 silent (the candidate), Z2 its first output arrived, Z3 a record was once read, Z4 no generation id was issued,
-- Z5 our own code lost it (no units), Z6 a podcast script (no first-output record exists), Z7 its operation still open,
-- Z8 a candidate whose late record will not match.
create temporary table fixture(id uuid,op uuid,meta jsonb,gen text,units jsonb,failure text);
insert into fixture values
 (:'Z1',:'O',:'M','gen-z1',:'U','provider_error'),(:'Z2',:'O',:'M','gen-z2',:'UF','provider_error'),
 (:'Z3',:'O',:'M','gen-z3',:'U','aborted'),(:'Z4',:'O',:'M',null,:'U','provider_error'),
 (:'Z5',:'O',:'M',null,'{}','transport_unknown'),(:'Z6',:'O',:'P','gen-z6',:'U','provider_error'),
 (:'Z7',:'O2',:'M','gen-z7',:'U','provider_error'),(:'Z8',:'O',:'M','gen-z8',:'U','provider_error');
select test.assert((select bool_and((public.worker_provider_attempt_begin(:'A',f.op,f.id,'openrouter','chat','anthropic/claude-sonnet-5.5',
 sha256(f.id::text::bytea),100000,'{"output_tokens":2000}')->>'granted')::boolean) from fixture f),'all admitted');
select test.assert((select bool_and(public.worker_openrouter_dispatch(:'A',f.op,f.id,f.meta)) from fixture f),'all dispatched');
select public.worker_provider_attempt_finish(:'A',f.op,f.id,'unknown',f.gen,null,f.units,f.failure) from fixture f;
select public.worker_settle_operation(:'A',:'O',0,0);
reset role;
update app_private.provider_attempts set created_at=now()-interval '2 hours' where id in (select id from fixture);
select reserved_microusd as reserved_before,spent_microusd as spent_before from app_private.platform_budgets
 where period=date_trunc('month',now() at time zone 'UTC')::date \gset
select provider_liability_microusd as liability_before,actual_credits as credits_before from app_private.metered_operations where id=:'O' \gset
select (select coalesce(sum(balance),0)||'/'||coalesce(sum(reserved),0) from app_private.credit_buckets where account_id=:'A')
 ||'/'||(select count(*) from app_private.credit_ledger where account_id=:'A') as balance_before \gset
select (public.worker_budget_health()->>'unknown_openrouter_attempts_over_1h')::integer as unknown_before \gset
select test.assert(:liability_before=700000,'seven unresolved ceilings held by the settled operation');

-- The reconciler's tries: the candidate without a generation id joins the queue (no lookup); the lost one never does.
set role service_role;
select public.worker_openrouter_reconcile_claim(50) as first \gset
select test.assert(jsonb_array_length(:'first'::jsonb)=7,'every attempt but Z5 is claimed');
select test.assert(not exists(select 1 from jsonb_array_elements(:'first'::jsonb) c where c->>'attempt_id'=:'Z5'),'our own lost call is not tried');
select test.assert((select c->'generation_id'='null'::jsonb and (c->>'tries')::int=1 and not (c->>'final')::boolean and not (c->>'assumed_zero')::boolean
 from jsonb_array_elements(:'first'::jsonb) c where c->>'attempt_id'=:'Z4'),'no generation id: claimed without one, first try');
select test.assert(not exists(select 1 from jsonb_array_elements(:'first'::jsonb) c where (c->>'final')::boolean),'no try before the 12th is final');
select test.assert(jsonb_array_length(public.worker_openrouter_reconcile_claim(50))=0,'and a claim backs off');
select public.worker_openrouter_reconcile_miss(:'Z3','mismatch');
select public.worker_openrouter_reconcile_miss(:'Z1','unreadable');
select test.reject(format('select public.worker_openrouter_reconcile_miss(%L,%L)',:'Z1','gone'),'invalid_reconciliation');
-- Before the 12th try nothing is assumed, whatever the worker says.
select test.assert((public.worker_openrouter_reconcile_absent(:'Z1','gen-z1')->>'reason')='too_early','too early');
reset role;
select test.assert((select record_seen and last_outcome='mismatch' from app_private.openrouter_reconcile_queue where attempt_id=:'Z3'),'a read record is remembered');
select test.assert((select not record_seen and last_outcome='not_found' from app_private.openrouter_reconcile_queue where attempt_id=:'Z1'),
 'the refused settlement recorded the read as not found');

-- The 12th try.
update app_private.openrouter_reconcile_queue set tries=11,next_at=now()-interval '1 minute';
set role service_role;
select public.worker_openrouter_reconcile_claim(50) as twelfth \gset
select test.assert((select array_agg(c->>'attempt_id' order by c->>'attempt_id') from jsonb_array_elements(:'twelfth'::jsonb) c where (c->>'final')::boolean)
 =array[:'Z1',:'Z4',:'Z7',:'Z8'],'final only for candidates: no output, no record seen, chat');
select test.assert((select bool_and((c->>'tries')::int=12) from jsonb_array_elements(:'twelfth'::jsonb) c),'the 12th try');
-- The database decides, whatever the worker asks.
select test.assert((public.worker_openrouter_reconcile_absent(:'Z2','gen-z2')->>'reason')='output_or_age','first output arrived: never assumed');
select test.assert((public.worker_openrouter_reconcile_absent(:'Z3','gen-z3')->>'reason')='record_seen','a record was read: never assumed');
select test.assert((public.worker_openrouter_reconcile_absent(:'Z6','gen-z6')->>'reason')='output_or_age','another caller: never assumed');
select test.assert((public.worker_openrouter_reconcile_absent(:'Z7','gen-z7')->>'reason')='operation_open','an open operation: not yet');
select test.reject(format('select public.worker_openrouter_reconcile_absent(%L,%L)',:'Z1','gen-other'),'invalid_reconciliation');
select test.reject(format('select public.worker_openrouter_reconcile_absent(%L,null)',:'Z1'),'invalid_reconciliation');
select public.worker_openrouter_reconcile_absent(:'Z1','gen-z1') as settled \gset
select test.assert((:'settled'::jsonb->>'settled')::boolean and (:'settled'::jsonb->>'released_microusd')::bigint=100000,'Z1 settled at zero');
select test.assert((public.worker_openrouter_reconcile_absent(:'Z1','gen-z1')->>'reason')='not_unknown','a second call changes nothing');
select test.assert((public.worker_openrouter_reconcile_absent(:'Z4',null)->>'settled')::boolean,'no generation id: settled at zero');
select test.assert((public.worker_openrouter_reconcile_absent(:'Z8','gen-z8')->>'settled')::boolean,'Z8 settled at zero');
reset role;

-- Distinguishable and audited.
select test.assert((select state='reconciled' and actual_microusd=0 and actual_units='{"estimated":1}'::jsonb and failure_code='provider_error'
 and receipt_metadata='{}'::jsonb and finished_at is not null from app_private.provider_attempts where id=:'Z1'),
 'reconciled at 0, marked estimated, its failure kept, no receipt');
select test.assert((select not app_private.usage_reported(state,actual_units) from app_private.provider_attempts where id=:'Z1'),
 'never provider-reported usage (0160)');
select test.assert((select actor_id is null and before_microusd=0 and after_microusd=0 and released_liability_microusd=100000
 and evidence_reference='openrouter-no-record:gen-z1' and reason like 'Automatic: assumed zero%' and units='{"estimated":1}'::jsonb
 from app_private.provider_attempt_adjustments where attempt_id=:'Z1'),'the adjustment keeps the ceiling as the assumed-zero liability');
select test.assert((select evidence_reference='openrouter-no-record:no-generation-id' from app_private.provider_attempt_adjustments where attempt_id=:'Z4'),
 'no generation id named as such');
select test.assert((select count(*)=1 from app_private.provider_attempt_events where attempt_id=:'Z1' and state='reconciled'
 and details->>'settled_reason'='no_record_no_bytes' and (details->>'assumed_zero_microusd')::bigint=100000 and (details->>'automatic')::boolean),
 'one reconciled event with its reason');
select test.assert((select last_outcome='assumed_zero' and assumed_zero_at is not null and next_at>now()+interval '23 hours'
 from app_private.openrouter_reconcile_queue where attempt_id=:'Z1'),'the queue marks it and reads again tomorrow');
select test.assert((select state='unknown' and actual_microusd is null from app_private.provider_attempts where id=:'Z2'),'Z2 untouched');
select test.assert((select state='unknown' from app_private.provider_attempts where id=:'Z7'),'Z7 untouched');
-- Money: the holds are released, nothing is spent, and the reader is never charged.
select test.assert((select reserved_microusd=:reserved_before-300000 and spent_microusd=:spent_before from app_private.platform_budgets
 where period=date_trunc('month',now() at time zone 'UTC')::date),'the month: three ceilings released, nothing spent');
select test.assert((select provider_liability_microusd=:liability_before-300000 and actual_credits is not distinct from :credits_before
 from app_private.metered_operations where id=:'O'),'the operation: liability down, credits unchanged');
select test.assert((select (select coalesce(sum(balance),0)||'/'||coalesce(sum(reserved),0) from app_private.credit_buckets where account_id=:'A')
 ||'/'||(select count(*) from app_private.credit_ledger where account_id=:'A')=:'balance_before'),'the reader''s credits unchanged');
select test.assert((public.worker_budget_health()->>'unknown_openrouter_attempts_over_1h')::integer=:unknown_before-3,'no longer unknown');
-- Model health still counts the failure (a reconciled attempt with no failure code would count as answered).
select test.assert((select (m->>'answered')::int=0 from jsonb_array_elements(app_private.model_health(24)->'models') m
 where m->>'model'='anthropic/claude-sonnet-5.5'),'still failed in model health');

-- Health: counted this month with the assumed ceilings; the rest named as before.
set role service_role;
select public.worker_budget_health()->'reconciliation' as rh \gset
reset role;
select test.assert((:'rh'::jsonb->'assumed_zero'->>'attempts')::int=3 and (:'rh'::jsonb->'assumed_zero'->>'ceiling_microusd')::bigint=300000
 and (:'rh'::jsonb->'assumed_zero'->>'corrected')::int=0 and (:'rh'::jsonb->'assumed_zero'->>'checking')::int=2
 and (:'rh'::jsonb->'assumed_zero'->>'contradicted')::int=0,'Health: three assumed zero this month (300,000 µ$), two still read for a late record');
select test.assert((:'rh'::jsonb->>'gave_up')::int=3,'Z2, Z3 and Z6 given up as before');
select test.assert((:'rh'::jsonb->>'automatic_pending')::int=1,'Z7 can still settle');
select test.assert((:'rh'::jsonb->>'without_generation')::int=1,'Z5 lost before its generation id, manual as before');
select test.assert((:'rh'::jsonb->>'manual_held_microusd')::bigint=400000,'with the ceilings they hold');
select test.assert(app_private.admin_health_extra()->'reconciliation' ? 'assumed_zero','Admin Health carries it');

-- Given up stays given up; a candidate past its 12th try is read once a day (back-off capped, no overflow).
update app_private.openrouter_reconcile_queue set next_at=now()-interval '1 minute' where attempt_id in (:'Z2',:'Z3',:'Z6',:'Z7');
update app_private.openrouter_reconcile_queue set tries=40 where attempt_id=:'Z7';
set role service_role;
select public.worker_openrouter_reconcile_claim(50) as later \gset
reset role;
select test.assert((select array_agg(c->>'attempt_id') from jsonb_array_elements(:'later'::jsonb) c)=array[:'Z7'],'only Z7 is read again');
select test.assert((select (c->>'final')::boolean and (c->>'tries')::int=41 from jsonb_array_elements(:'later'::jsonb) c),'still final');
select test.assert((select next_at between now()+interval '23 hours' and now()+interval '25 hours' from app_private.openrouter_reconcile_queue where attempt_id=:'Z7'),
 'a day later');

-- A late record corrects an assumed zero to the record's cost: nothing left to release, the cost spent, still not charged.
update app_private.openrouter_reconcile_queue set next_at=now()-interval '1 minute' where attempt_id in (:'Z1',:'Z4',:'Z8');
set role service_role;
select public.worker_openrouter_reconcile_claim(50) as late \gset
select test.assert((select array_agg(c->>'attempt_id' order by c->>'attempt_id') from jsonb_array_elements(:'late'::jsonb) c)=array[:'Z1',:'Z8'],
 'assumed-zero attempts with a generation id are read again');
select test.assert((select bool_and((c->>'assumed_zero')::boolean and not (c->>'final')::boolean) from jsonb_array_elements(:'late'::jsonb) c),'marked as such');
select public.worker_openrouter_reconcile(:'Z1','gen-z1',:'R',51200,'{"input_tokens":10000,"cache_read_tokens":30000,"output_tokens":900}') as corrected \gset
select test.assert((:'corrected'::jsonb->>'reconciled')::boolean and (:'corrected'::jsonb->>'corrected')::boolean
 and (:'corrected'::jsonb->>'released_microusd')::bigint=0,'corrected; nothing left to release');
select test.assert(not (public.worker_openrouter_reconcile(:'Z1','gen-z1',:'R',51200,'{"input_tokens":10000,"cache_read_tokens":30000,"output_tokens":900}')->>'reconciled')::boolean,
 'a second correction changes nothing');
select public.worker_openrouter_reconcile_miss(:'Z8','mismatch');
reset role;
select test.assert((select state='reconciled' and actual_microusd=51200 and failure_code='provider_error' and receipt_metadata->>'generation_id'='gen-z1'
 and app_private.usage_reported(state,actual_units) from app_private.provider_attempts where id=:'Z1'),'the record''s cost and units, its failure kept');
select test.assert((select count(*)=2 and bool_or(reason like 'Automatic: a late OpenRouter record corrects%' and before_microusd=0 and after_microusd=51200
 and released_liability_microusd=0 and evidence_reference='openrouter-generation:gen-z1') from app_private.provider_attempt_adjustments where attempt_id=:'Z1'),
 'audited as a correction, the assumed zero kept');
select test.assert((select r.adjustment_microusd=51200 from app_private.provider_reconciliations r join app_private.provider_usage_events u on u.id=r.usage_event_id
 where u.provider_event_id='attempt:'||:'Z1'),'the usage record carries the correction');
select test.assert((select reserved_microusd=:reserved_before-300000 and spent_microusd=:spent_before+51200 from app_private.platform_budgets
 where period=date_trunc('month',now() at time zone 'UTC')::date),'the month: the cost spent, nothing reserved again');
select test.assert((select provider_liability_microusd=:liability_before-300000 and actual_credits is not distinct from :credits_before
 from app_private.metered_operations where id=:'O'),'still not charged to the reader');
select test.assert((select (select coalesce(sum(balance),0)||'/'||coalesce(sum(reserved),0) from app_private.credit_buckets where account_id=:'A')
 ||'/'||(select count(*) from app_private.credit_ledger where account_id=:'A')=:'balance_before'),'the reader''s credits unchanged');
set role service_role;
select test.assert(not exists(select 1 from jsonb_array_elements(public.worker_openrouter_reconcile_claim(50)) c where c->>'attempt_id'=:'Z1'),'corrected: no more reads');
select public.worker_budget_health()->'reconciliation'->'assumed_zero' as az \gset
reset role;
select test.assert((:'az'::jsonb->>'attempts')::int=3 and (:'az'::jsonb->>'corrected')::int=1 and (:'az'::jsonb->>'corrected_microusd')::bigint=51200
 and (:'az'::jsonb->>'checking')::int=1 and (:'az'::jsonb->>'contradicted')::int=1,'Health: one corrected at its cost, one contradicted by a record');

-- An owner's reconciliation of the contradicted attempt stands: no more reads, no contradiction, never overridden.
set role service_role;
select public.worker_provider_attempt_reconcile(:'OWN',gen_random_uuid(),:'Z8',7000,'{"input_tokens":1000,"output_tokens":20}','openrouter-dashboard:gen-z8','Owner: record names a dated model');
reset role;
update app_private.openrouter_reconcile_queue set next_at=now()-interval '1 minute' where attempt_id=:'Z8';
set role service_role;
select test.assert(not exists(select 1 from jsonb_array_elements(public.worker_openrouter_reconcile_claim(50)) c where c->>'attempt_id'=:'Z8'),'owner-settled: no more reads');
select test.assert(not (public.worker_openrouter_reconcile(:'Z8','gen-z8',jsonb_set(jsonb_set(:'R'::jsonb,'{generation_id}','"gen-z8"'),'{total_cost_microusd}','9000'),9000,'{"output_tokens":20}')->>'reconciled')::boolean,
 'the reconciler never overrides the owner');
select test.assert((public.worker_budget_health()->'reconciliation'->'assumed_zero'->>'contradicted')::int=0,'no contradiction left');
reset role;
select test.assert((select actual_microusd=7000 from app_private.provider_attempts where id=:'Z8'),'the owner''s cost stands');

-- Spending (owner with MFA): the window's assumed zeros and corrections, for all accounts or one.
set role authenticated;
select set_config('request.jwt.claim.sub',:'OWN',false);
select set_config('request.jwt.claim.aal','aal2',false);
select public.v1_admin_spending(30,null)->'assumed_zero' as sz \gset
select public.v1_admin_spending(30,:'OWN')->'assumed_zero' as other \gset
reset role;
select test.assert((:'sz'::jsonb->>'attempts')::int=3 and (:'sz'::jsonb->>'ceiling_microusd')::bigint=300000 and (:'sz'::jsonb->>'corrected')::int=1
 and (:'sz'::jsonb->>'corrected_microusd')::bigint=51200,'Spending: assumed zero with the original ceilings, and the late record''s correction');
select test.assert((:'other'::jsonb->>'attempts')::int=0,'filtered by account');
rollback;
