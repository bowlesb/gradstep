-- 0103 (review A7): an owner's pause and the tripwire hold across the month boundary; resuming resumes every month
-- created; test-account anomalies are recorded but never pause the service.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
\set A '10300000-0000-4000-8000-00000000000a'
\set T '10300000-0000-4000-8000-00000000000c'
\set OWN '10300000-0000-4000-8000-0000000000ff'
insert into auth.users(id,email) values(:'A','reader-103@gradstep.test.org'),(:'T','gradstep-check-drill-103@example.invalid'),(:'OWN','owner-103@gradstep.test.org');
insert into app_private.app_roles(account_id,role) values(:'OWN','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month, (date_trunc('month',now() at time zone 'UTC')+interval '1 month')::date as next_month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
select public.worker_ensure_platform_budget();
select public.worker_grant_credits(a,'adjustment','pause-103-'||a,1000,now()-interval '1 day',null,'Pause fixture') from unnest(array[:'A',:'T']::uuid[]) a;
create function test.enabled(p date) returns boolean language sql as $$ select work_enabled from app_private.platform_budgets where period=p $$;
create function test.overrun(acct uuid) returns void language plpgsql as $$
declare op uuid:=gen_random_uuid(); attempt uuid:=gen_random_uuid();
begin
 perform public.worker_reserve_operation(acct,op,'chat',sha256(convert_to(op::text,'UTF8')),'beta-credits-v1',10,10000);
 perform public.worker_provider_attempt_begin(acct,op,attempt,'openrouter','chat','anthropic/claude-haiku-5.5',sha256(convert_to(attempt::text,'UTF8')),10000,'{"output_tokens":1}');
 perform public.worker_provider_attempt_finish(acct,op,attempt,'succeeded','gen-'||left(attempt::text,8),15000,'{"output_tokens":1000}',null);
 perform public.worker_settle_operation(acct,op,2,15000);
end $$;
grant execute on all functions in schema test to service_role,authenticated,anon;
select test.assert(test.enabled(:'next_month'),'next month exists ahead and is enabled');

-- 1. Seven drill overruns on a test account in the hour: recorded, shown, never a pause.
select test.overrun(:'T') from generate_series(1,7);
select test.assert(test.enabled(:'month') and test.enabled(:'next_month'),'test-account anomalies cannot pause everyone');
select test.assert((select count(distinct operation_id)=7 and bool_and(test_account) from app_private.budget_anomalies where account_id=:'T'),'they are recorded as a test account''s');
select test.assert(app_private.anomalies_toward_tripwire()=0,'and not counted toward the tripwire');

-- 2. The owner's pause holds into next month; a daily run cannot lift it; resuming resumes both.
set role authenticated;
select set_config('request.jwt.claim.sub',:'OWN',false);
select set_config('request.jwt.claim.aal','aal2',false);
select public.v1_admin_pause_work(true,'Pause for the review');
reset role;
select test.assert(not test.enabled(:'month') and not test.enabled(:'next_month'),'paused now and next month');
select public.worker_ensure_platform_budget();
select test.assert(not test.enabled(:'next_month'),'the daily budget run keeps the pause');
select test.assert((select details->'periods'=jsonb_build_array(:'month'::text,:'next_month'::text) from app_private.admin_audit_events
 where action='set_work_paused' and actor_id=:'OWN' order by created_at desc limit 1),'the audit row names both months');
set role authenticated;
select public.v1_admin_pause_work(false,'Resume after the review');
reset role;
select test.assert(test.enabled(:'month') and test.enabled(:'next_month'),'resumed now and next month');

-- 3. The tripwire (more than five real overruns in the hour) pauses this month and next.
select test.overrun(:'A') from generate_series(1,5);
select test.assert(test.enabled(:'month'),'five: still running');
select test.overrun(:'A');
select test.assert(not test.enabled(:'month') and not test.enabled(:'next_month'),'the sixth pauses this month and next');
rollback;
