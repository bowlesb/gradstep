-- The paper's AI Explainer (migration 145, docs/proposals/LEARNING_GUIDE.md): `paper_explainer` settles like every chat
-- action, with its ending recorded (charged when completed, nothing for an early ending); the earlier actions still
-- settle and an unknown action is still refused. Synthetic local SQL; nothing leaves the machine. Final phase.
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

\set A '14500000-0000-0000-0000-00000000000a'
\set P1 '14500000-0000-0000-0001-000000000001'
\set P2 '14500000-0000-0000-0001-000000000002'
\set S1 '14500000-0000-0000-0001-000000000003'
\set X '14500000-0000-0000-0001-000000000009'
insert into auth.users(id,email) values(:'A','reader-145@gradstep.test.org');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
select public.worker_grant_credits(:'A','adjustment','paper-explainer-145',1000,now()-interval '1 day',null,'Paper explainer fixture');
create function test.available(acct uuid) returns bigint language sql as $$
 select coalesce(sum(balance-reserved),0)::bigint from app_private.credit_buckets where account_id=acct $$;
select test.available(:'A') as before_a \gset

set role service_role;
-- An explainer that finished is charged; one cut off at its allowance is our limit, not charged; a Study turn unchanged.
select public.worker_reserve_operation(:'A',:'P1','chat',sha256('p1'),'beta-credits-v1',40,200000);
select public.worker_settle_chat(:'A',:'P1',4,18000,'paper_explainer','completed',0);
select public.worker_reserve_operation(:'A',:'P2','chat',sha256('p2'),'beta-credits-v1',40,200000);
select public.worker_settle_chat(:'A',:'P2',0,20000,'paper_explainer','limit',20000);
select public.worker_reserve_operation(:'A',:'S1','chat',sha256('s1'),'beta-credits-v1',40,200000);
select public.worker_settle_chat(:'A',:'S1',2,6000,'study','completed',0);
-- Replays: identical is a no-op, a different action conflicts; an early ending can never charge; unknown actions refused.
select public.worker_settle_chat(:'A',:'P1',4,18000,'paper_explainer','completed',0);
select test.reject(format('select public.worker_settle_chat(%L,%L,4,18000,%L,%L,0)',:'A',:'P1','figure','completed'),'settlement_id_conflict');
select public.worker_reserve_operation(:'A',:'X','chat',sha256('x'),'beta-credits-v1',40,200000);
select test.reject(format('select public.worker_settle_chat(%L,%L,3,9000,%L,%L,9000)',:'A',:'X','paper_explainer','provider'),'invalid_settlement');
select test.reject(format('select public.worker_settle_chat(%L,%L,0,9000,%L,%L,9000)',:'A',:'X','paper_map','server'),'invalid_settlement');
reset role;

select test.assert(test.available(:'A')=:before_a-4-2-40,'only the finished explainer and the Study turn are charged; the cut-off hold is released (the refused one stays held)');
select test.assert((select array_agg(action||':'||ending||':'||charged||':'||credits order by operation_id) from app_private.chat_endings
 where account_id=:'A')='{paper_explainer:completed:true:4,paper_explainer:limit:false:0,study:completed:true:2}', 'each ending is recorded with the action');
select test.reject(format('insert into app_private.chat_endings(account_id,operation_id,action,ending,charged,credits) values(%L,%L,%L,%L,false,0)',
 :'A',:'X','paper_map','server'),'chat_endings_action_check');
select test.assert(not has_function_privilege('authenticated','public.worker_settle_chat(uuid,uuid,bigint,bigint,text,text,bigint)','execute')
 and has_function_privilege('service_role','public.worker_settle_chat(uuid,uuid,bigint,bigint,text,text,bigint)','execute'),'only the service role settles');
rollback;
