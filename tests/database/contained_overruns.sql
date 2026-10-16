-- Contained overruns and early endings (migration 079; owner decisions 2026-10-16, docs/architecture/RESILIENCE.md fix 1
-- and docs/architecture/CHAT.md "When an answer stops early"): an operation over its ceiling is a budget anomaly and
-- never pauses the month by itself; more than five in an hour (the tripwire), an operator, or the hard monthly limit
-- still do. A chat settlement records how it ended: the reader pays only for completed or stopped work; an uncharged
-- ending charges nothing and its cost stays platform spend. A reader's Stop is recorded by their own app. Synthetic
-- local SQL; nothing leaves the machine. Runs after the HTML-first cutover migrations (scripts/test-database.py).
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

\set A '79000000-0000-0000-0000-00000000000a'
\set B '79000000-0000-0000-0000-00000000000b'
\set T '79000000-0000-0000-0000-00000000000c'
\set OWN '79000000-0000-0000-0000-0000000000ff'
insert into auth.users(id,email) values(:'A','reader-79@gradstep.test.org'),(:'B','other-79@gradstep.test.org'),
 (:'T','gradstep-check-drill-79@example.invalid'),(:'OWN','owner-79@gradstep.test.org');
insert into app_private.app_roles(account_id,role) values(:'OWN','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
select public.worker_grant_credits(a,'adjustment','overrun-79-'||a,1000,now()-interval '1 day',null,'Overrun fixture')
 from unnest(array[:'A',:'B',:'T']::uuid[]) a;
create function test.month_enabled() returns boolean language sql as $$
 select work_enabled from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date $$;
create function test.available(acct uuid) returns bigint language sql as $$
 select coalesce(sum(balance-reserved),0)::bigint from app_private.credit_buckets where account_id=acct $$;
create function test.held(acct uuid) returns bigint language sql as $$
 select coalesce(sum(reserved),0)::bigint from app_private.credit_buckets where account_id=acct $$;
-- One operation whose single attempt (ceiling 10,000 micro-USD) reports more than it was allowed, then settles.
create function test.overrun(acct uuid, op uuid, actual bigint default 15000) returns void language plpgsql as $$
declare attempt uuid := gen_random_uuid();
begin
 perform public.worker_reserve_operation(acct, op, 'chat', sha256(convert_to(op::text,'UTF8')), 'beta-credits-v1', 10, 10000);
 perform public.worker_provider_attempt_begin(acct, op, attempt, 'anthropic', 'chat', 'claude-sonnet-5-5', sha256(convert_to(attempt::text,'UTF8')), 10000, '{"output_tokens":1}');
 perform public.worker_provider_attempt_finish(acct, op, attempt, 'succeeded', 'req-'||left(attempt::text,8), actual, '{"output_tokens":1000}', null);
 perform public.worker_settle_operation(acct, op, 2, actual);
end $$;

-- 1. An attempt over its ceiling is recorded (the attempt, and its operation), alerted, and pauses nothing.
\set O1 '79000000-0000-0000-0001-000000000001'
select coalesce((select spent_microusd from app_private.platform_budgets where period=:'month'),0) as spent0 \gset
set role service_role;
select public.worker_reserve_operation(:'A',:'O1','chat',sha256('o1'),'beta-credits-v1',10,10000);
select public.worker_provider_attempt_begin(:'A',:'O1','79000000-0000-0000-0002-000000000001','anthropic','chat','claude-sonnet-5-5',sha256('o1-r'),10000,'{"output_tokens":1}');
select public.worker_provider_attempt_finish(:'A',:'O1','79000000-0000-0000-0002-000000000001','succeeded','req-o1',15000,'{"output_tokens":1000}',null);
reset role;
select test.assert(test.month_enabled(),'an overrunning attempt no longer pauses the month');
select test.assert((select array_agg(kind||':'||ceiling_microusd||':'||observed_microusd order by kind) from app_private.budget_anomalies where operation_id=:'O1')
 ='{attempt_over_ceiling:10000:15000,operation_over_ceiling:10000:15000}','the attempt and its operation are recorded with ceiling and cost');
select test.assert((select bool_and(not paused_month and not test_account) from app_private.budget_anomalies where operation_id=:'O1'),'not a pause, not a test account');
set role service_role;
select public.worker_settle_operation(:'A',:'O1',2,15000);
reset role;
select test.assert(test.month_enabled(),'settling the overrun still pauses nothing');
select test.assert((select count(*)=2 from app_private.budget_anomalies where operation_id=:'O1'),'settlement adds no second operation row');
select test.assert((select spent_microusd=:spent0+15000 from app_private.platform_budgets where period=:'month'),'the true provider cost is spent');
select test.assert((public.worker_operation_outcome(:'A',:'O1')->'anomalies'->0->>'kind')='attempt_over_ceiling','the outcome readback lists them');

-- 2. A legacy operation (no attempt accounting) settled above its ceiling: recorded, not paused.
\set O2 '79000000-0000-0000-0001-000000000002'
select public.worker_reserve_operation(:'A',:'O2','chat',sha256('o2'),'beta-credits-v1',5,1000);
select public.worker_settle_operation(:'A',:'O2',1,5000);
select test.assert(test.month_enabled() and (select kind='operation_over_ceiling' and observed_microusd=5000 from app_private.budget_anomalies where operation_id=:'O2'),
 'a legacy overrun is recorded, not paused');

-- 3. The tripwire: more than five operations over their ceiling within the hour pause the month; the row that tripped it says so.
select test.overrun(:'A','79000000-0000-0000-0001-000000000003');
select test.overrun(:'B','79000000-0000-0000-0001-000000000004');
select test.overrun(:'A','79000000-0000-0000-0001-000000000005');
select test.assert(test.month_enabled(),'five operations in the hour: still running');
select test.assert((public.worker_budget_health()->>'anomalies_in_window')::int=5 and not (public.worker_budget_health()->>'paused_by_tripwire')::boolean,'the budget check counts them');
select test.overrun(:'B','79000000-0000-0000-0001-000000000006');
select test.assert(not test.month_enabled(),'the sixth pauses the month');
select test.assert((select paused_month from app_private.budget_anomalies where operation_id='79000000-0000-0000-0001-000000000006' and kind='attempt_over_ceiling'),
 'the tripping anomaly is marked');
select test.assert((public.worker_budget_health()->>'paused_by_tripwire')::boolean,'the budget check says the tripwire paused it');
select test.reject(format('select public.worker_reserve_operation(%L,%L,%L,sha256(%L),%L,1,1)',:'A','79000000-0000-0000-0001-000000000007','chat','paused','beta-credits-v1'),
 'platform_budget_exhausted');
-- An operator resumes it; the count restarts from the pause, so one more anomaly in the same hour does not re-pause.
select public.worker_set_platform_budget(:'month',10000000,true);
select test.overrun(:'A','79000000-0000-0000-0001-000000000008');
select test.assert(test.month_enabled(),'after a resume the tripwire counts afresh');

-- 4. Unchanged: the operator's pause and the hard monthly limit.
select public.worker_set_platform_budget(:'month',10000000,false);
select test.reject(format('select public.worker_reserve_operation(%L,%L,%L,sha256(%L),%L,1,1)',:'A','79000000-0000-0000-0001-000000000009','chat','op','beta-credits-v1'),
 'platform_budget_exhausted');
select public.worker_set_platform_budget(:'month',10000000,true);
select test.reject(format('select public.worker_reserve_operation(%L,%L,%L,sha256(%L),%L,1,%s)',:'A','79000000-0000-0000-0001-00000000000a','chat','limit','beta-credits-v1',10000000),
 'platform_budget_exhausted');
select test.assert(test.month_enabled(),'a hold over the limit is refused without pausing');

-- 5. A chat settlement records its ending and what Gradstep absorbed, in the same transaction as the money.
\set C1 '79000000-0000-0000-0003-000000000001'
\set C2 '79000000-0000-0000-0003-000000000002'
\set C3 '79000000-0000-0000-0003-000000000003'
select test.available(:'A') as before_a \gset
select coalesce((select spent_microusd from app_private.platform_budgets where period=:'month'),0) as spent1 \gset
set role service_role;
select public.worker_reserve_operation(:'A',:'C1','chat',sha256('c1'),'beta-credits-v1',20,50000);
select public.worker_settle_chat(:'A',:'C1',3,12000,'answer','completed',44);
-- The provider failing mid-answer: nothing charged, the whole cost absorbed and still spent.
select public.worker_reserve_operation(:'A',:'C2','chat',sha256('c2'),'beta-credits-v1',20,50000);
select public.worker_settle_chat(:'A',:'C2',0,9000,'study','provider',9000);
reset role;
select test.assert(test.available(:'A')=:before_a-3 and test.held(:'A')=0,'only the completed answer is charged; both holds released');
select test.assert((select spent_microusd=:spent1+21000 from app_private.platform_budgets where period=:'month'),'absorbed cost is platform spend, never hidden');
select test.assert((select array_agg(action||':'||ending||':'||charged||':'||credits||':'||absorbed_microusd order by operation_id) from app_private.chat_endings
 where account_id=:'A')='{answer:completed:true:3:44,study:provider:false:0:9000}','both endings recorded');
-- Replays: identical is a no-op; anything different conflicts; an uncharged ending can never charge; only chat, known codes.
set role service_role;
select public.worker_settle_chat(:'A',:'C1',3,12000,'answer','completed',44);
select test.reject(format('select public.worker_settle_chat(%L,%L,3,12000,%L,%L,44)',:'A',:'C1','answer','stopped'),'settlement_id_conflict');
select test.reject(format('select public.worker_settle_chat(%L,%L,0,12000,%L,%L,44)',:'A',:'C1','answer','completed'),'settlement_id_conflict');
select public.worker_reserve_operation(:'A',:'C3','chat',sha256('c3'),'beta-credits-v1',20,50000);
select test.reject(format('select public.worker_settle_chat(%L,%L,2,9000,%L,%L,9000)',:'A',:'C3','answer','limit'),'invalid_settlement');
select test.reject(format('select public.worker_settle_chat(%L,%L,0,9000,%L,%L,9000)',:'A',:'C3','answer','vanished'),'invalid_settlement');
select test.reject(format('select public.worker_settle_chat(%L,%L,0,9000,%L,%L,9000)',:'A',:'C3','unknown','server'),'invalid_settlement');
select test.reject(format('select public.worker_settle_chat(%L,%L,0,9000,%L,%L,-1)',:'A',:'C3','answer','server'),'invalid_settlement');
select public.worker_reserve_operation(:'A','79000000-0000-0000-0003-00000000000f','metadata',sha256('meta'),'beta-credits-v1',0,0);
select test.reject(format('select public.worker_settle_chat(%L,%L,0,0,%L,%L,0)',:'A','79000000-0000-0000-0003-00000000000f','answer','server'),'invalid_settlement');
reset role;
select test.assert((select state='reserved' from app_private.metered_operations where id=:'C3'),'a refused settlement changes nothing');

-- 6. The reader's Stop, from their own app: their own chat operations only; the chat function reads it back.
select set_config('request.jwt.claim.sub',:'A',false);
set role authenticated;
select test.assert((public.v1_chat_stop(:'C3')->>'recorded')::boolean,'the reader records their Stop');
select test.assert((public.v1_chat_stop(:'C3')->>'recorded')::boolean,'again: still one record');
select test.assert(not (public.v1_chat_stop(gen_random_uuid())->>'recorded')::boolean,'an unknown operation records nothing');
select test.assert(not (public.v1_chat_stop('79000000-0000-0000-0003-00000000000f')->>'recorded')::boolean,'nor a non-chat one');
select test.reject(format('select public.worker_settle_chat(%L,%L,0,0,%L,%L,0)',:'A',:'C3','answer','stopped'),'permission denied');
select test.reject(format('select public.worker_chat_stop_requested(%L,%L)',:'A',:'C3'),'permission denied');
reset role;
select set_config('request.jwt.claim.sub',:'B',false);
set role authenticated;
select test.assert(not (public.v1_chat_stop(:'C3')->>'recorded')::boolean,'another reader cannot stop it');
reset role;
select set_config('request.jwt.claim.sub','',false);
set role anon;
select test.reject(format('select public.v1_chat_stop(%L)',:'C3'),'permission denied');
reset role;
set role service_role;
select test.assert(public.worker_chat_stop_requested(:'A',:'C3') and not public.worker_chat_stop_requested(:'B',:'C3'),'read back per account');
select public.worker_settle_chat(:'A',:'C3',1,3000,'answer','stopped',0);
reset role;
select test.assert((select count(*)=1 from app_private.chat_stop_requests where operation_id=:'C3'),'one record');
select test.assert((public.worker_operation_outcome(:'A',:'C3')->>'ending')='stopped' and (public.worker_operation_outcome(:'A',:'C3')->>'stop_requested')::boolean,'outcome readback');

-- 7. A hold whose invocation died is swept as our server's ending: nothing charged, its held attempt absorbed.
\set C4 '79000000-0000-0000-0003-000000000004'
select public.worker_reserve_operation(:'A',:'C4','chat',sha256('c4'),'beta-credits-v1',20,50000);
select public.worker_provider_attempt_begin(:'A',:'C4','79000000-0000-0000-0002-000000000004','anthropic','chat','claude-haiku-5-5',sha256('c4-r'),4000,'{"output_tokens":1}');
update app_private.metered_operations set created_at=now()-interval '31 minutes' where id=:'C4';
select test.assert(public.worker_expire_stale_chat_operations()>=1,'swept');
select test.assert((select action='unknown' and ending='server' and not charged and credits=0 and absorbed_microusd=4000 from app_private.chat_endings where operation_id=:'C4'),
 'recorded as our server failing, the held attempt absorbed');

-- 8. Health: the anomalies and the early endings; an account over 20 uncharged endings today is listed (test accounts never).
do $$
declare acct uuid; op uuid;
begin
 foreach acct in array array['79000000-0000-0000-0000-00000000000b','79000000-0000-0000-0000-00000000000c']::uuid[] loop
  for i in 1..21 loop
   op := gen_random_uuid();
   perform public.worker_reserve_operation(acct, op, 'chat', sha256(convert_to(op::text,'UTF8')), 'beta-credits-v1', 1, 1000);
   perform public.worker_settle_chat(acct, op, 0, 100, 'answer', 'connection', 100);
  end loop;
 end loop;
end $$;
select set_config('request.jwt.claim.sub',:'OWN',false);
select set_config('request.jwt.claim.aal','aal2',false);
select public.v1_admin_health(7) as h \gset
select set_config('request.jwt.claim.sub','',false);
select set_config('request.jwt.claim.aal','',false);
select test.assert((:'h'::jsonb ? 'people') and (:'h'::jsonb ? 'providers'),'the earlier sections are unchanged');
select test.assert((:'h'::jsonb->'anomalies'->>'pause_after')::int=5 and (:'h'::jsonb->'anomalies'->>'window_minutes')::int=60,'the tripwire numbers');
select test.assert((:'h'::jsonb->'anomalies'->>'last_24h')::int=7 and (:'h'::jsonb->'anomalies'->>'last_24h_test')::int=0,'seven operations overran today, none on a test account');
select test.assert(exists(select 1 from jsonb_array_elements(:'h'::jsonb->'anomalies'->'recent') r where (r->>'paused_month')::boolean),'the pause is listed');
select test.assert((:'h'::jsonb->'early_endings'->>'attention_daily')::int=20,'the abuse guard number');
select test.assert((:'h'::jsonb->'early_endings'->'by_ending'->>'connection')::int=42 and (:'h'::jsonb->'early_endings'->'by_ending'->>'completed')::int=1,'endings by kind');
select test.assert((:'h'::jsonb->'early_endings'->'today'->>'uncharged')::int=44,'today''s uncharged endings, test accounts included in the money');
select test.assert(jsonb_array_length(:'h'::jsonb->'early_endings'->'accounts_over_today')=1
 and :'h'::jsonb->'early_endings'->'accounts_over_today'->0->>'account_id'=:'B'
 and (:'h'::jsonb->'early_endings'->'accounts_over_today'->0->>'uncharged')::int=21,'only the real account over 20 is listed');
select test.assert(test.month_enabled(),'the reader is never blocked for it');
select test.assert((public.worker_budget_health()->>'uncharged_endings_today')::int=44 and (public.worker_budget_health()->>'absorbed_microusd_today')::int=4200+9000+4000+44,
 'the budget check sees them');

-- 9. Drills: streamed fault modes for test accounts; their synthetic attempts reconcile to zero, a reader's never.
select test.assert((public.worker_fault_injection_set(:'T','anthropic','chat','midstream',1,5,'Drill: mid-stream')->>'id') is not null,'midstream drills');
select test.assert((public.worker_fault_injection_set(:'T','anthropic','chat','slow',1,5,'Drill: Stop')->>'id') is not null,'slow drills');
select test.reject(format('select public.worker_fault_injection_set(%L,%L,%L,%L,1,5,%L)',:'T','anthropic','chat','explode','bad mode'),'fault_injection_mode_check');
\set D1 '79000000-0000-0000-0004-000000000001'
\set D2 '79000000-0000-0000-0004-000000000002'
select coalesce((select reserved_microusd from app_private.platform_budgets where period=:'month'),0) as reserved_before \gset
select public.worker_reserve_operation(:'T',:'D1','chat',sha256('d1'),'beta-credits-v1',10,10000);
select public.worker_provider_attempt_begin(:'T',:'D1','79000000-0000-0000-0005-000000000001','anthropic','chat','claude-haiku-5-5',sha256('d1-r'),3000,'{"output_tokens":1}');
select public.worker_provider_attempt_finish(:'T',:'D1','79000000-0000-0000-0005-000000000001','unknown','drill-midstream-1',null,'{}',null);
select public.worker_settle_chat(:'T',:'D1',0,40,'answer','provider',40);
select test.assert((select reserved_microusd=:reserved_before+3000 from app_private.platform_budgets where period=:'month'),'the synthetic attempt is held as a liability');
-- The overrun drill: a one-micro-USD attempt ceiling, three reported, on a test account.
select coalesce((select spent_microusd from app_private.platform_budgets where period=:'month'),0) as spent2 \gset
select public.worker_reserve_operation(:'T',:'D2','chat',sha256('d2'),'beta-credits-v1',1,2);
select public.worker_provider_attempt_begin(:'T',:'D2','79000000-0000-0000-0005-000000000002','anthropic','chat','claude-haiku-5-5',sha256('d2-r'),1,'{"output_tokens":1}');
select public.worker_provider_attempt_finish(:'T',:'D2','79000000-0000-0000-0005-000000000002','succeeded','drill-overrun-1',3,'{"output_tokens":1}',null);
select public.worker_settle_operation(:'T',:'D2',0,3);
select test.assert(test.month_enabled() and (select bool_and(test_account) and count(*)=2 from app_private.budget_anomalies where operation_id=:'D2'),
 'the drill overrun is recorded as a test account''s, and pauses nothing');
select test.reject(format('select public.worker_fault_drill_reconcile(%L)',:'A'),'fault_target_not_test_account');
set role service_role;
select test.assert(public.worker_fault_drill_reconcile(:'T')=2,'both synthetic attempts reconciled');
select test.assert(public.worker_fault_drill_reconcile(:'T')=0,'once');
reset role;
select test.assert((select reserved_microusd=:reserved_before and spent_microusd=:spent2 from app_private.platform_budgets where period=:'month'),
 'the held ceiling is released and the synthetic cost leaves the month');
select test.assert((select bool_and(state='reconciled' and actual_microusd=0) from app_private.provider_attempts where account_id=:'T'),'reconciled at zero');
select test.assert((select count(*)=2 from app_private.provider_attempt_adjustments j join app_private.provider_attempts a on a.id=j.attempt_id
 where a.account_id=:'T' and j.evidence_reference='fault-drill:synthetic' and j.actor_id is null),'with an evidence trail');
select test.assert((select state='succeeded' and actual_microusd=15000 from app_private.provider_attempts where id='79000000-0000-0000-0002-000000000001'),
 'a reader''s attempt is never touched');
set role authenticated;
select test.reject(format('select public.worker_fault_drill_reconcile(%L)',:'T'),'permission denied');
select test.reject(format('select public.worker_operation_outcome(%L,%L)',:'A',:'C1'),'permission denied');
select test.reject('select * from app_private.chat_endings','permission denied');
select test.reject('select * from app_private.budget_anomalies','permission denied');
reset role;
rollback;
