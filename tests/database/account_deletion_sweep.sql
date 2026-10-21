-- Review A22 (migration 128): the deletion sweep backs off a failing account so it never holds every slot, keeps
-- listing an unfinished account after 30 days (never-tried accounts first), and Health reports unfinished, retrying and
-- stalled deletions. Synthetic local SQL, all migrations; nothing leaves the machine.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;

\set O '12800000-0000-4000-8000-00000000000f'
\set OLD '12800000-0000-4000-8000-0000000000a1'
\set NEW '12800000-0000-4000-8000-0000000000a2'
\set DONE '12800000-0000-4000-8000-0000000000a3'
insert into auth.users(id,email) values(:'O','sweep-owner@gradstep.test.org'),(:'OLD','sweep-old@gradstep.test.org'),
 (:'NEW','sweep-new@gradstep.test.org'),(:'DONE','sweep-done@gradstep.test.org');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
-- Twenty-five accounts that cannot finish (their logins stay linked), closed 40 days ago, older than everything else.
create temp table stuck as select ('12800000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid id from generate_series(1,25) n;
grant select on stuck to service_role;
insert into auth.users(id,email) select id,'stuck-'||id||'@gradstep.test.org' from stuck;
update app_private.accounts set closed_at=now()-interval '40 days' where id in (select id from stuck);
update app_private.accounts set closed_at=now()-interval '35 days' where id=:'OLD';
update app_private.accounts set closed_at=now()-interval '1 day' where id=:'NEW';
-- A finished deletion: closed and its login gone.
update app_private.accounts set closed_at=now()-interval '2 days' where id=:'DONE';
delete from auth.users where id=:'DONE';

set role service_role;
-- Unfinished accounts are listed past the old 30-day cut-off; a finished one never.
select test.assert(cardinality(public.worker_account_deletions_pending(20))=20,'a full page of unfinished accounts');
select test.assert(not (:'DONE'::uuid=any(public.worker_account_deletions_pending(20))),'a finished deletion is not listed');
-- Every stuck account fails once: each backs off and the newer accounts get their turn at once.
select public.worker_account_deletion_attempt(id,false,'files','deletion_scan_incomplete') from stuck;
select public.worker_account_deletions_pending(3) as next \gset
reset role;
select test.assert(:'next'::uuid[]=array[:'OLD',:'NEW']::uuid[],'accounts in back-off give up their slots (oldest untried first)');
select test.assert((select bool_and(next_attempt_at between now()+interval '4 minutes' and now()+interval '6 minutes' and attempts=1) from app_private.account_deletion_sweeps
 where account_id in (select id from stuck)),'the first failure waits five minutes');

-- A repeated failure waits longer, at most a day; once the wait passes the account returns, after untried ones.
set role service_role;
select public.worker_account_deletion_attempt(:'OLD',false,'begin','account_busy');
select public.worker_account_deletion_attempt(:'OLD',false,'begin','account_busy');
reset role;
select test.assert((select attempts=2 and next_attempt_at between now()+interval '9 minutes' and now()+interval '11 minutes' and last_code='account_busy'
 from app_private.account_deletion_sweeps where account_id=:'OLD'),'back-off doubles');
update app_private.account_deletion_sweeps set attempts=40 where account_id=:'OLD';
set role service_role;
select public.worker_account_deletion_attempt(:'OLD',false,'files',null);
reset role;
select test.assert((select next_attempt_at<=now()+interval '24 hours' and next_attempt_at>now()+interval '23 hours' from app_private.account_deletion_sweeps where account_id=:'OLD'),'never more than a day');
update app_private.account_deletion_sweeps set next_attempt_at=now()-interval '1 minute' where account_id in (select id from stuck) or account_id=:'OLD';
set role service_role;
select public.worker_account_deletions_pending(3) as again \gset
reset role;
select test.assert((:'again'::uuid[])[1]=:'NEW'::uuid,'a never-tried account goes first');
select test.assert(not (:'OLD'::uuid=any(:'again'::uuid[])),'then the least recently tried (OLD was tried last)');

-- A completed deletion clears its row; bad reports and open accounts are refused.
set role service_role;
select public.worker_account_deletion_attempt(:'NEW',false,'login',null);
select public.worker_account_deletion_attempt(:'NEW',true);
select test.reject(format('select public.worker_account_deletion_attempt(%L,false,%L,null)',:'NEW','private text'),'invalid_deletion_attempt');
select test.reject(format('select public.worker_account_deletion_attempt(%L,false,null,%L)',:'NEW','other_code'),'invalid_deletion_attempt');
select test.reject(format('select public.worker_account_deletion_attempt(%L,true,%L,null)',:'NEW','files'),'invalid_deletion_attempt');
select test.reject(format('select public.worker_account_deletion_attempt(%L,false,%L,null)',:'O','files'),'account_not_closed');
reset role;
select test.assert(not exists(select 1 from app_private.account_deletion_sweeps where account_id=:'NEW'),'a completed deletion clears its back-off');

-- The owner's Health: unfinished, retrying and stalled (over 30 days) deletions, with the commonest code.
set role authenticated;
select set_config('request.jwt.claim.sub',:'O',false);
select set_config('request.jwt.claim.aal','aal2',false);
select public.v1_admin_health(7)->'account_deletions' as d \gset
reset role;
select test.assert((:'d'::jsonb->>'unfinished')::int=27 and (:'d'::jsonb->>'retrying')::int=26 and (:'d'::jsonb->>'stalled')::int=26,'counts: 25 stuck + OLD + NEW unfinished; 26 retrying; 26 past 30 days');
select test.assert((:'d'::jsonb->>'top_code')='deletion_scan_incomplete' and (:'d'::jsonb->>'oldest_closed_at')::timestamptz<now()-interval '39 days','commonest code and oldest closing');
select test.assert(not (:'d'::jsonb::text ~ 'gradstep\.test\.org'),'no address in the health readout');
set role authenticated;
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject('select public.v1_admin_health(7)','owner_mfa_required');
reset role;

select test.assert(not has_function_privilege('authenticated','public.worker_account_deletion_attempt(uuid,boolean,text,text)','execute')
 and not has_function_privilege('authenticated','public.worker_account_deletions_pending(integer)','execute')
 and has_function_privilege('service_role','public.worker_account_deletion_attempt(uuid,boolean,text,text)','execute'),'service role only');
rollback;
