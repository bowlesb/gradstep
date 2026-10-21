-- 0104 (review A11): the operator's budget change is owner-attributed, audited, applies to this UTC month and later
-- months, never resumes a paused month and stays within the schema ceiling.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set A '10400000-0000-4000-8000-00000000000a'
\set OWN '10400000-0000-4000-8000-0000000000ff'
\set R '10400000-0000-4000-8009-000000000001'
insert into auth.users(id,email) values(:'A','reader-104@gradstep.test.org'),(:'OWN','owner-104@gradstep.test.org');
insert into app_private.app_roles(account_id,role) values(:'OWN','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month, (date_trunc('month',now() at time zone 'UTC')+interval '1 month')::date as next_month \gset
select public.worker_set_platform_budget(:'month',25000000,false); -- paused (for example by the tripwire)
select public.worker_ensure_platform_budget();
set role service_role;
select test.reject(format('select public.worker_owner_set_budget_limit(%L,gen_random_uuid(),40000000,%L)',:'A','Reader cannot'),'owner');
select test.reject(format('select public.worker_owner_set_budget_limit(%L,gen_random_uuid(),40000000,%L)',:'OWN','x'),'invalid_budget');
select test.reject(format('select public.worker_owner_set_budget_limit(%L,gen_random_uuid(),60000000,%L)',:'OWN','Above the schema ceiling'),'platform_budgets_limit_microusd_check1');
select test.assert((public.worker_owner_set_budget_limit(:'OWN',:'R',40000000,'Testing month; owner approved')->>'before_microusd')::bigint=25000000,'set, with the earlier limit');
select test.assert((public.worker_owner_set_budget_limit(:'OWN',:'R',40000000,'Testing month; owner approved')->>'replayed')::boolean,'replay-safe');
select test.reject(format('select public.worker_owner_set_budget_limit(%L,%L,45000000,%L)',:'OWN',:'R','Testing month; owner approved'),'request_id_conflict');
reset role;
select test.assert((select bool_and(limit_microusd=40000000) and count(*)=2 from app_private.platform_budgets where period in (:'month',:'next_month')),
 'this month and next carry the new limit');
select test.assert((select not bool_or(work_enabled) from app_private.platform_budgets where period in (:'month',:'next_month')),
 'a paused month stays paused: the switch is never touched');
select test.assert((select actor_id=:'OWN' and details->>'before_microusd'='25000000' and jsonb_array_length(details->'periods')=2
 from app_private.admin_audit_events where id=:'R'),'audited to the owner with both months');
rollback;
