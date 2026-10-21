-- No import quota (migration 0142; owner 2026-10-21; docs/architecture/LIBRARY_CAPACITY.md "No import quota"): the
-- lifetime counts on imports, memberships, library commands and shared catalog records are gone (a NULL limit never
-- refuses), imports in flight have a generous backstop, and the per-account request rates remain the abuse protection.
-- Synthetic local SQL; nothing leaves the machine.
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

\set A '14200000-0000-4000-8000-00000000000a'
insert into auth.users(id,email) values(:'A','no-import-quota-142@gradstep.test.org');

-- The policy: no lifetime limit anywhere, a generous in-flight backstop.
select test.assert((select account_items is null and environment_items is null and account_imports is null and environment_imports is null
 and account_receipts is null and environment_receipts is null and metadata_rows is null and metadata_bytes is null
 from app_private.library_policy where singleton),'no lifetime limit is configured');
select test.assert((select account_active_imports=100 and environment_active_imports=2000 from app_private.library_policy where singleton),
 'imports in flight: 100 per account, 2,000 for the service');
-- What stays: the request rates and the per-row bounds (unchanged by 0142).
select test.assert((select account_limit=120 and window_seconds=3600 from app_private.api_rate_rules where route='add-paper'),'add-paper: 120 an hour');
select test.assert((select account_limit=120 and window_seconds=3600 from app_private.api_rate_rules where route='add-reference'),'add-reference: 120 an hour');
select test.assert((select account_limit=1000 and window_seconds=3600 from app_private.api_rate_rules where route='library-write'),'library-write: 1,000 an hour');

set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
-- More papers in flight at once than the old backstop (10) allowed: every one is accepted.
select test.assert(bool_and(public.v2_add_paper_once(('14200000-0000-4000-8001-'||lpad(n::text,12,'0'))::uuid,format('2401.%s',lpad(n::text,5,'0')),false)
 ->'result'->>'status'='applied'),'twelve adds in a row') from generate_series(1,12) n;
reset role;
select test.assert((select count(*)=12 from app_private.import_requests where account_id=:'A' and phase='accepted'),'twelve imports in flight');

-- The lifetime count is still counted (for history) but refuses nothing: with a cap configured at today's count the next
-- add is refused, exactly as before 0142; with the cap removed (null, as 0142 leaves it) it is accepted.
update app_private.library_policy set account_imports=(select count(*) from app_private.import_requests where account_id=:'A') where singleton;
set role authenticated;
select test.reject(format('select public.v2_add_paper_once(%L,%L,false)','14200000-0000-4000-8002-000000000001','2402.00001'),'library_account_import_limit');
reset role;
update app_private.library_policy set account_imports=null where singleton;
set role authenticated;
select test.assert(public.v2_add_paper_once('14200000-0000-4000-8002-000000000001','2402.00001',false)->'result'->>'status'='applied','no limit: accepted');
reset role;

-- The same for library commands (receipts), which once capped every reader together at 120,000.
update app_private.library_policy set account_receipts=(select count(*) from app_private.library_commands where account_id=:'A') where singleton;
set role authenticated;
select test.reject(format('select public.v2_add_paper_once(%L,%L,false)','14200000-0000-4000-8002-000000000002','2402.00002'),'library_account_receipt_limit');
reset role;
update app_private.library_policy set account_receipts=null where singleton;
set role authenticated;
select test.assert(public.v2_add_paper_once('14200000-0000-4000-8002-000000000002','2402.00002',false)->'result'->>'status'='applied','no limit: accepted');
reset role;

-- The service-wide counts too: null environment limits refuse nothing.
select test.assert((select environment_imports is null and environment_receipts is null from app_private.library_policy),'service-wide: no limit');
-- And the in-flight backstop still holds (lowered here to show it): a reader at it waits for one to finish.
update app_private.library_policy set account_active_imports=14 where singleton;
set role authenticated;
select test.reject(format('select public.v2_add_paper_once(%L,%L,false)','14200000-0000-4000-8002-000000000003','2402.00003'),'library_active_import_limit');
reset role;
rollback;
