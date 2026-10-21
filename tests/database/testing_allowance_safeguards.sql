-- 0105 (review A9): the testing allowance names the acting owner, needs an owner/tester target, ends with a sign-in
-- disable (and does not come back with re-enable), can be disabled in any state, and caps the account's monthly spend.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set OWN '10500000-0000-4000-8000-0000000000ff'
\set TST '10500000-0000-4000-8000-00000000000a'
\set RDR '10500000-0000-4000-8000-00000000000b'
insert into auth.users(id,email,email_confirmed_at) values(:'OWN','owner-105@gradstep.test.org',now()),(:'TST','tester-105@gradstep.test.org',now()),
 (:'RDR','reader-105@gradstep.test.org',now());
insert into app_private.app_roles(account_id,role) values(:'OWN','owner'),(:'TST','tester');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);

set role service_role;
select test.reject(format('select public.worker_set_testing_allowance(%L,gen_random_uuid(),%L,true,%L)',:'TST',:'TST','Self-service'),'owner_required');
select test.reject(format('select public.worker_set_testing_allowance(%L,gen_random_uuid(),%L,true,%L)',:'OWN',:'RDR','An ordinary reader'),'testing_allowance_role_required');
select test.reject(format('select public.worker_set_testing_allowance(%L,gen_random_uuid(),%L,true,%L,60000000)',:'OWN',:'TST','Over the cap maximum'),'invalid_testing_allowance');
select test.assert((public.worker_set_testing_allowance(:'OWN','10500000-0000-4000-8009-000000000001',:'TST',true,'Tester round two',10000)->>'monthly_cap_microusd')::bigint=10000,
 'enabled with a monthly cap');
reset role;
select test.assert((select actor_id=:'OWN' and target_id=:'TST' and details->>'source'='admin-accounts' from app_private.admin_audit_events
 where id='10500000-0000-4000-8009-000000000001'),'audited to the acting owner, not the target');

-- The cap: the account's provider cost this month may not pass it, whatever the refilled credits allow.
set role service_role;
select public.worker_reserve_operation(:'TST','10500000-0000-4000-8001-000000000001','chat',sha256('one'),'beta-credits-v1',10,6000);
select test.reject(format('select public.worker_reserve_operation(%L,%L,%L,sha256(%L),%L,10,6000)',:'TST','10500000-0000-4000-8001-000000000002','chat','two','beta-credits-v1'),'testing_cap_reached');
select test.assert((public.worker_reserve_operation(:'TST','10500000-0000-4000-8001-000000000001','chat',sha256('one'),'beta-credits-v1',10,6000)->>'replayed')::boolean,
 'an exact replay is still answered');
select public.worker_settle_operation(:'TST','10500000-0000-4000-8001-000000000001',1,1000);
select test.assert(not (public.worker_reserve_operation(:'TST','10500000-0000-4000-8001-000000000003','chat',sha256('three'),'beta-credits-v1',10,6000)->>'replayed')::boolean,
 'after settling at its actual cost, room opens again');

-- Disabling sign-in ends the allowance (audited to the same owner); re-enabling sign-in does not bring it back.
select public.worker_admin_set_sign_in(:'OWN','10500000-0000-4000-8009-000000000002',:'TST',true,'Paused for review');
reset role;
select test.assert((select not enabled from app_private.testing_allowances where account_id=:'TST'),'the allowance ended with the sign-in');
select test.assert((select bool_and(actor_id=:'OWN') and count(*)=1 from app_private.admin_audit_events
 where action='testing_allowance' and target_id=:'TST' and details->>'source'='sign-in-disabled'),'and that is audited to the owner');
set role service_role;
select public.worker_admin_set_sign_in(:'OWN','10500000-0000-4000-8009-000000000003',:'TST',false,'Review done');
reset role;
select test.assert((select not enabled from app_private.testing_allowances where account_id=:'TST'),'re-enabling sign-in does not restore unlimited credits');

-- Disabling works while the account is suspended.
set role service_role;
select test.assert((public.worker_set_testing_allowance(:'OWN','10500000-0000-4000-8009-000000000004',:'TST',true,'Back for testing')->>'enabled')::boolean,'re-enabled explicitly');
reset role;
update app_private.accounts set spending_suspended=true where id=:'TST';
set role service_role;
select test.assert(not (public.worker_set_testing_allowance(:'OWN','10500000-0000-4000-8009-000000000005',:'TST',false,'Ends while suspended')->>'enabled')::boolean,
 'disabled although suspended');
reset role;

-- Admin › Accounts lists the allowance, its cap and this month's spend.
set role authenticated;
select set_config('request.jwt.claim.sub',:'OWN',false);
select set_config('request.jwt.claim.aal','aal2',false);
select test.assert((select (x->>'monthly_cap_microusd')::bigint=10000 and (x->>'month_spend_microusd')::bigint>=7000
 from jsonb_array_elements(public.v1_admin_accounts(null,'created',false,50)->'testing_allowances') x where x->>'account_id'=:'TST'),
 'Accounts shows the allowance');
reset role;
rollback;
