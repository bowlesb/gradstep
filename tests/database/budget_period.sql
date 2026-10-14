-- Budget periods and the stale-hold sweep (migration 060, docs/reviews/COST_CREDITS_AND_SYNC_AUDIT_20261014.md).
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

-- With this month's row in place (the test schema starts without one), the scheduled call creates next month's from it:
-- same limit, same switch; a second call creates nothing.
delete from app_private.platform_budgets where period>=date_trunc('month',now() at time zone 'UTC')::date;
insert into app_private.platform_budgets(period,limit_microusd,work_enabled) values(date_trunc('month',now() at time zone 'UTC')::date,25000000,true);
set role service_role;
select test.assert(public.worker_ensure_platform_budget()->'created'=to_jsonb(array[((date_trunc('month',now() at time zone 'UTC')+interval '1 month')::date)::text]),'next month created');
select test.assert(public.worker_ensure_platform_budget()->'created'='[]'::jsonb,'ensuring again creates nothing');
reset role;
select test.assert((select limit_microusd from app_private.platform_budgets where period=(date_trunc('month',now() at time zone 'UTC')+interval '1 month')::date)=25000000,'next month carries this month''s limit');
-- A missing current month is recreated from the latest earlier period, never larger.
delete from app_private.platform_budgets where period=(date_trunc('month',now() at time zone 'UTC')+interval '1 month')::date;
update app_private.platform_budgets set limit_microusd=12000000 where period=date_trunc('month',now() at time zone 'UTC')::date;
set role service_role;
select test.assert(public.worker_ensure_platform_budget()->'created'=to_jsonb(array[((date_trunc('month',now() at time zone 'UTC')+interval '1 month')::date)::text]),'next month recreated');
-- The health readback names the period, the switch and the aged counts.
select test.assert((public.worker_budget_health()->>'next_period_exists')::boolean and (public.worker_budget_health()->>'unknown_attempts_over_1h')::int=0
 and public.worker_budget_health()?'work_enabled','health readback');
reset role;
select test.assert((select limit_microusd from app_private.platform_budgets where period=(date_trunc('month',now() at time zone 'UTC')+interval '1 month')::date)=12000000,'copied, not raised');
set role authenticated;
select test.reject('select public.worker_budget_health()','permission denied');
select test.reject('select public.worker_ensure_platform_budget()','permission denied');
reset role;
-- The stale-hold sweep (migration 060) releases a dead chat hold without booking its ceiling as platform spend.
insert into auth.users(id) values('60000000-0000-0000-0000-00000000000a');
set role service_role;
select public.worker_grant_credits('60000000-0000-0000-0000-00000000000a','adjustment','sweep-a',100,now()-interval '1 day',null,'Sweep fixture');
select public.worker_reserve_operation('60000000-0000-0000-0000-00000000000a','60000000-0000-0000-0001-000000000001','chat',decode(repeat('cc',32),'hex'),'beta-credits-v1',20,100000);
reset role;
update app_private.metered_operations set created_at=now()-interval '2 hours' where id='60000000-0000-0000-0001-000000000001';
\set spent_before `echo 0`
select spent_microusd as spent_before from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date \gset
set role service_role;
select test.assert(public.worker_expire_stale_chat_operations()=1,'stale chat hold swept');
reset role;
select test.assert((select state='settled' and actual_credits=0 and actual_microusd=0 from app_private.metered_operations where id='60000000-0000-0000-0001-000000000001'),'released without charge or booked spend');
select test.assert((select spent_microusd from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date)=:spent_before,'platform spend unchanged by the sweep');
select test.assert((select reserved from app_private.credit_buckets where external_key='sweep-a')=0,'the reader''s hold is released');
rollback;
