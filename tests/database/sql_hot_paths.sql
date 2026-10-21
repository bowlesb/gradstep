-- 0108 (review C7): the stale-hold sweep records an operation it cannot settle and moves on, instead of retrying the same
-- oldest operations forever; the hot counts have partial indexes.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set A '10800000-0000-4000-8000-000000000001'
\set BAD '10800000-0000-4000-8001-000000000001'
\set OK '10800000-0000-4000-8001-000000000002'
insert into auth.users(id,email) values(:'A','sweep-108@gradstep.test.org');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','sweep-108',1000,now()-interval '1 day',null,'Sweep fixture');
set role service_role;
select public.worker_reserve_operation(:'A',:'BAD','chat',sha256('bad'),'beta-credits-v1',10,1000);
select public.worker_reserve_operation(:'A',:'OK','chat',sha256('ok'),'beta-credits-v1',10,1000);
reset role;
update app_private.metered_operations set created_at=now()-interval '2 hours' where account_id=:'A' and id=:'BAD';
update app_private.metered_operations set created_at=now()-interval '1 hour' where account_id=:'A' and id=:'OK';
-- An operation that cannot settle (simulated: settling it raises) is older than the other.
create function test.refuse_bad() returns trigger language plpgsql as $$
begin if new.id='10800000-0000-4000-8001-000000000001' and new.state='settled' then raise exception 'simulated' using errcode='P0001'; end if; return new; end $$;
create trigger refuse_bad before update on app_private.metered_operations for each row execute function test.refuse_bad();
set role service_role;
select test.assert(public.worker_expire_stale_chat_operations(30)=1,'the settleable one is swept despite the older failing one');
select test.assert(public.worker_expire_stale_chat_operations(30)=0,'the failing one is backed off, not retried at once');
select test.assert((public.worker_budget_health()->>'stale_sweep_failing')::integer=1,'the budget check counts it');
reset role;
select test.assert((select failures=1 and last_code='P0001' and next_at>now() from app_private.stale_sweep_failures where operation_id=:'BAD'),
 'its SQLSTATE is recorded, never a message');
select test.assert((select state='settled' from app_private.metered_operations where id=:'OK'),'the other operation settled');
drop trigger refuse_bad on app_private.metered_operations;
update app_private.stale_sweep_failures set next_at=now()-interval '1 second';
set role service_role;
select test.assert(public.worker_expire_stale_chat_operations(30)=1,'once settleable and due, it is swept');
reset role;
select test.assert(not exists(select 1 from app_private.stale_sweep_failures where operation_id=:'BAD'),'and its failure record cleared');
select test.assert((select count(*)=3 from pg_indexes where schemaname='app_private' and indexname in
 ('metered_operations_open_by_account','metered_operations_open_chat','import_requests_active')),'partial indexes exist');
rollback;
