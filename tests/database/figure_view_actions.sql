-- The figure view's chat actions (migration 082, docs/architecture/FIGURE_VIEW.md): `figure` and `figure_simpler` settle
-- like every chat action, with their ending recorded (charged when completed, nothing for an early ending); every
-- earlier action still settles, and an unknown action is still refused. Synthetic local SQL; nothing leaves the machine.
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
grant execute on all functions in schema test to anon,authenticated,service_role;

\set A '82000000-0000-0000-0000-00000000000a'
\set F1 '82000000-0000-0000-0001-000000000001'
\set F2 '82000000-0000-0000-0001-000000000002'
\set F3 '82000000-0000-0000-0001-000000000003'
\set E1 '82000000-0000-0000-0001-000000000004'
\set X '82000000-0000-0000-0001-000000000009'
insert into auth.users(id,email) values(:'A','reader-82@gradstep.test.org');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
select public.worker_grant_credits(:'A','adjustment','figure-view-82',1000,now()-interval '1 day',null,'Figure view fixture');
create function test.available(acct uuid) returns bigint language sql as $$
 select coalesce(sum(balance-reserved),0)::bigint from app_private.credit_buckets where account_id=acct $$;
select test.available(:'A') as before_a \gset

set role service_role;
-- A walkthrough that finished is charged; one part again that the provider cut short is not; a walkthrough cut off at
-- its allowance is our limit, not charged. An equation view settlement is unchanged.
select public.worker_reserve_operation(:'A',:'F1','chat',sha256('f1'),'beta-credits-v1',40,200000);
select public.worker_settle_chat(:'A',:'F1',6,28000,'figure','completed',0);
select public.worker_reserve_operation(:'A',:'F2','chat',sha256('f2'),'beta-credits-v1',40,200000);
select public.worker_settle_chat(:'A',:'F2',0,9000,'figure_simpler','provider',9000);
select public.worker_reserve_operation(:'A',:'F3','chat',sha256('f3'),'beta-credits-v1',40,200000);
select public.worker_settle_chat(:'A',:'F3',0,30000,'figure','limit',30000);
select public.worker_reserve_operation(:'A',:'E1','chat',sha256('e1'),'beta-credits-v1',40,200000);
select public.worker_settle_chat(:'A',:'E1',2,9000,'equation','completed',0);
-- Replays: identical is a no-op, a different action conflicts; a figure action that ended early can never charge.
select public.worker_settle_chat(:'A',:'F1',6,28000,'figure','completed',0);
select test.reject(format('select public.worker_settle_chat(%L,%L,6,28000,%L,%L,0)',:'A',:'F1','figure_simpler','completed'),'settlement_id_conflict');
select public.worker_reserve_operation(:'A',:'X','chat',sha256('x'),'beta-credits-v1',40,200000);
select test.reject(format('select public.worker_settle_chat(%L,%L,3,9000,%L,%L,9000)',:'A',:'X','figure','provider'),'invalid_settlement');
select test.reject(format('select public.worker_settle_chat(%L,%L,0,9000,%L,%L,9000)',:'A',:'X','figure_view','server'),'invalid_settlement');
select test.reject(format('select public.worker_settle_chat(%L,%L,0,9000,%L,%L,9000)',:'A',:'X','unknown','server'),'invalid_settlement');
reset role;

select test.assert(test.available(:'A')=:before_a-8-40,'only the finished walkthrough and the equation symbols are charged; the other holds are released (the refused one stays held)');
select test.assert((select array_agg(action||':'||ending||':'||charged||':'||credits||':'||absorbed_microusd order by operation_id) from app_private.chat_endings
 where account_id=:'A')='{figure:completed:true:6:0,figure_simpler:provider:false:0:9000,figure:limit:false:0:30000,equation:completed:true:2:0}',
 'each figure-view ending is recorded with the action');
select test.assert((select state='reserved' from app_private.metered_operations where id=:'X'),'a refused settlement changes nothing');
-- The table itself still refuses an action no client sends.
select test.reject(format('insert into app_private.chat_endings(account_id,operation_id,action,ending,charged,credits) values(%L,%L,%L,%L,false,0)',
 :'A',:'X','figure_view','server'),'chat_endings_action_check');
select test.assert(not has_function_privilege('authenticated','public.worker_settle_chat(uuid,uuid,bigint,bigint,text,text,bigint)','execute')
 and not has_function_privilege('anon','public.worker_settle_chat(uuid,uuid,bigint,bigint,text,text,bigint)','execute')
 and has_function_privilege('service_role','public.worker_settle_chat(uuid,uuid,bigint,bigint,text,text,bigint)','execute'),'only the service role settles');
rollback;
