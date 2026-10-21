-- 0100 (review A2): attempt capacity is a rolling window of granted attempts; refused ones and old ones never count,
-- the counter rows are pruned, the limits can be raised without a migration, and the owner sees the 80% warning.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set A '10000000-0000-4000-8000-000000000001'
\set B '10000000-0000-4000-8000-000000000002'
\set O '10000000-0000-4000-8001-000000000001'
\set P '10000000-0000-4000-8001-000000000002'
\set Q '10000000-0000-4000-8001-000000000003'
insert into auth.users(id,email) values(:'A','window-100@gradstep.test.org'),(:'B','window-other-100@gradstep.test.org');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','window-100',1000,now()-interval '1 day',null,'Window fixture');
select public.worker_grant_credits(:'B','adjustment','window-100-b',1000,now()-interval '1 day',null,'Window fixture');

select test.assert((select attempt_limit=50000 and account_attempt_limit=10000 and attempt_window_hours=24 from app_private.provider_spending_policy),
 'per-window limits: 50,000 a day for the platform, 10,000 for one account');
update app_private.provider_spending_policy set account_attempt_limit=2;
create function test.begin(acct uuid,op uuid,label text) returns jsonb language sql as $$
 select public.worker_provider_attempt_begin(acct,op,gen_random_uuid(),'openrouter','chat','anthropic/claude-haiku-5.5',sha256(convert_to(label,'UTF8')),3000,'{"output_tokens":40}')
$$;
grant execute on function test.begin(uuid,uuid,text) to service_role;
set role service_role;
select public.worker_reserve_operation(:'A',:'O','chat',sha256('window100'),'beta-credits-v1',40,200000);
select public.worker_reserve_operation(:'A',:'P','chat',sha256('window100p'),'beta-credits-v1',40,200000);
select public.worker_reserve_operation(:'B',:'Q','chat',sha256('window100q'),'beta-credits-v1',40,200000);
select test.assert((test.begin(:'A',:'O','one')->>'granted')::boolean,'first grant');
select test.assert((test.begin(:'A',:'P','two')->>'granted')::boolean,'second grant, another operation');
select test.assert(test.begin(:'A',:'O','three')->>'reason'='attempt_capacity','the account window is full');
select test.assert((test.begin(:'B',:'Q','other')->>'granted')::boolean,'another account is unaffected');
reset role;
select test.assert((select attempts=2 from app_private.provider_attempt_hours where scope_id=:'A' and hour=app_private.attempt_hour(now())),
 'only granted attempts are counted');
select test.assert((select attempts=3 from app_private.provider_attempt_hours where scope_id='00000000-0000-0000-0000-000000000000' and hour=app_private.attempt_hour(now())),
 'the platform counts every account');

-- Yesterday's attempts leave the window: the account may continue, whatever its lifetime total.
update app_private.provider_attempt_hours set hour=hour-interval '25 hours' where scope_id=:'A';
update app_private.provider_attempts set created_at=created_at-interval '25 hours' where account_id=:'A';
insert into app_private.provider_attempt_hours(scope_id,hour,attempts) values(:'A',app_private.attempt_hour(now())-interval '9 days',100000);
set role service_role;
select test.assert((test.begin(:'A',:'O','after a day')->>'granted')::boolean,'a new window: granted again');
reset role;
select test.assert(not exists(select 1 from app_private.provider_attempt_hours where scope_id=:'A' and hour<now()-interval '8 days'),
 'counter rows older than 8 days are pruned');

-- A refusal for another reason (a paused platform) is not counted either.
update app_private.platform_budgets set work_enabled=false where period=date_trunc('month',now() at time zone 'UTC')::date;
select attempts as before_paused from app_private.provider_attempt_hours where scope_id=:'B' and hour=app_private.attempt_hour(now()) \gset
set role service_role;
select test.assert(test.begin(:'B',:'Q','paused')->>'reason'='platform_paused','a paused platform refuses');
reset role;
select test.assert((select attempts=:before_paused from app_private.provider_attempt_hours where scope_id=:'B' and hour=app_private.attempt_hour(now())),
 'a refused attempt is not counted');
update app_private.platform_budgets set work_enabled=true where period=date_trunc('month',now() at time zone 'UTC')::date;

-- Limits are policy, raisable without a migration, within the new maxima.
update app_private.provider_spending_policy set attempt_limit=1000000,account_attempt_limit=200000;
select test.reject('update app_private.provider_spending_policy set attempt_limit=1000001','provider_attempt_window_limit');
select test.reject('update app_private.provider_spending_policy set attempt_window_hours=169','attempt_window_hours');

-- The owner's warning: an account at 80% of its window.
update app_private.provider_spending_policy set account_attempt_limit=1; -- one granted attempt in this window: at the limit
select test.assert((app_private.provider_attempt_window()->>'eighty_percent')::boolean,'80% of an account window is a warning');
select test.assert(app_private.provider_attempt_window()->>'busiest_account_used'='1','busiest account reported');
set role service_role;
select test.assert((public.worker_budget_health()->>'attempt_capacity_eighty_percent')::boolean,'the scheduled budget check sees it');
select test.assert(public.worker_budget_health() ? 'unknown_attempts_over_1h','the earlier budget fields remain');
reset role;
update app_private.provider_spending_policy set account_attempt_limit=10000;
select test.assert(not (app_private.provider_attempt_window()->>'eighty_percent')::boolean,'below 80%: no warning');
select test.assert(not has_function_privilege('authenticated','public.worker_budget_health()','execute'),'the budget check stays service-only');
select test.assert(not has_function_privilege('anon','public.v1_admin_spending(integer,uuid)','execute'),'the spending tab stays closed to anon');
rollback;
