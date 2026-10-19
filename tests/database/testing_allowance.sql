-- True reservation/settlement/revocation behavior, with no provider transport.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(command text,expected text) returns void language plpgsql as $$
begin
 begin execute command; exception when others then
  if sqlerrm=expected then return; end if; raise;
 end;
 raise exception 'Expected rejection: %',expected;
end $$;
grant usage on schema test to anon,authenticated,service_role;
grant execute on all functions in schema test to anon,authenticated,service_role;
\set A '94000000-0000-0000-0000-000000000001'
\set B '94000000-0000-0000-0000-000000000002'
\set C '94000000-0000-0000-0000-000000000003'
\set ENABLE '94000000-0000-0000-0000-000000000011'
\set DISABLE '94000000-0000-0000-0000-000000000012'
\set OP1 '94000000-0000-0000-0000-000000000021'
\set OP2 '94000000-0000-0000-0000-000000000022'
insert into auth.users(id,email,email_confirmed_at) values
 (:'A','test-allowance-a@example.invalid',now()),(:'B','test-allowance-b@example.invalid',now());
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
set role service_role;
select public.worker_set_platform_budget(:'month',1000000,true);
select public.worker_grant_credits(:'A','purchased','testing-normal-purchase',400,now(),null,'Ordinary purchased balance') as purchased \gset
select public.worker_set_testing_allowance(:'A',:'ENABLE',true,'Owner requested unlimited testing');
select test.assert((public.worker_set_testing_allowance(:'A',:'ENABLE',true,'Owner requested unlimited testing')->>'replayed')::boolean,'enable replay');
reset role;
select test.assert((select count(*)=1 from app_private.admin_audit_events where id=:'ENABLE'),'one audit for replay');
select set_config('request.jwt.claim.sub',:'A',true);
set role authenticated;
select test.assert(public.v1_credit_balance()->>'unlimited_testing'='true','explicit unlimited state');
select test.assert((public.v1_credit_balance()->>'available')::bigint=100400,'balance is real credits');
reset role;

set role service_role;
select public.worker_reserve_operation(:'A',:'OP1','chat',sha256('one'),'beta-credits-v1',100001,5000);
select public.worker_reserve_operation(:'A',:'OP1','chat',sha256('one'),'beta-credits-v1',100001,5000);
reset role;
select test.assert((select count(*)=1 from app_private.credit_ledger where account_id=:'A' and entry_key='testing-refill:'||:'OP1'),'exact replay does not refill');
select test.assert((select balance=400 and reserved=0 from app_private.credit_buckets where id=:'purchased'),'testing never spends purchased credits');
select test.assert((select reserved_microusd=5000 from app_private.platform_budgets where period=:'month'),'normal provider budget reserved once');
set role service_role;
select public.worker_settle_operation(:'A',:'OP1',100001,100);
select public.worker_settle_operation(:'A',:'OP1',100001,100);
select public.worker_reserve_operation(:'A',:'OP2','chat',sha256('two'),'beta-credits-v1',50,5000);
reset role;
select test.assert((select balance=100000 and reserved=50 from app_private.credit_buckets where id=(select bucket_id from app_private.testing_allowances where account_id=:'A')),'exhausted allowance replenishes before next operation');
select test.assert((select spent_microusd=100 and reserved_microusd=5000 from app_private.platform_budgets where period=:'month'),'cost remains accounted');

-- A rejected operation must not mint/refill; suspension remains authoritative.
set role service_role;
select test.reject(format('select public.worker_reserve_operation(%L,gen_random_uuid(),%L,sha256(%L),%L,100000,2000000)',:'A','chat','denied','beta-credits-v1'),'platform_budget_exhausted');
reset role;
select test.assert((select balance=100000 from app_private.credit_buckets where id=(select bucket_id from app_private.testing_allowances where account_id=:'A')),'denial rolls back refill');
update app_private.accounts set spending_suspended=true where id=:'A';
set role service_role;
select test.reject(format('select public.worker_reserve_operation(%L,gen_random_uuid(),%L,sha256(%L),%L,1,1)',:'A','chat','suspended','beta-credits-v1'),'spending_suspended');
reset role;
update app_private.accounts set spending_suspended=false where id=:'A';

-- Revocation preserves held work; old enable replay never revives it.
set role service_role;
select public.worker_set_testing_allowance(:'A',:'DISABLE',false,'End the testing allowance');
select test.assert(public.worker_set_testing_allowance(:'A',:'ENABLE',true,'Owner requested unlimited testing')->>'enabled'='false','stale enable replay does not revive');
select public.worker_settle_operation(:'A',:'OP2',10,50);
reset role;
set role authenticated;
select test.assert(public.v1_credit_balance()->>'unlimited_testing'='false','revoked mode');
select test.assert((public.v1_credit_balance()->>'available')::bigint=400,'purchased credits survive; unused test hold cannot be spent');
reset role;

-- Other accounts get neither policy nor credit; client roles cannot grant it.
select set_config('request.jwt.claim.sub',:'B',true);
set role authenticated;
select test.assert(public.v1_credit_balance()->>'unlimited_testing'='false' and (public.v1_credit_balance()->>'available')::bigint=0,'account isolation');
reset role;
select test.assert(not has_function_privilege('authenticated','public.worker_set_testing_allowance(uuid,uuid,boolean,text)','execute')
 and not has_function_privilege('anon','public.worker_set_testing_allowance(uuid,uuid,boolean,text)','execute'),'service-only policy');
select test.assert(not has_table_privilege('authenticated','app_private.testing_allowances','update'),'no client policy write');

-- A fresh identity after actual deletion never inherits testing access.
set role service_role;
select public.worker_set_testing_allowance(:'A',gen_random_uuid(),true,'Testing enabled again');
select public.worker_delete_account_begin(:'A');
select public.worker_delete_account_finish(:'A');
select test.reject(format('select public.worker_reserve_operation(%L,gen_random_uuid(),%L,sha256(%L),%L,1,1)',:'A','chat','closed','beta-credits-v1'),'account_unavailable');
reset role;
delete from auth.users where id=:'A';
insert into auth.users(id,email,email_confirmed_at) values(:'C','test-allowance-a@example.invalid',now());
select test.assert(not exists(select 1 from app_private.testing_allowances where account_id=:'C'),'new UUID has no test policy');
select test.assert(not exists(select 1 from app_private.credit_buckets where account_id=:'C'),'new UUID has no inherited grants');
rollback;
