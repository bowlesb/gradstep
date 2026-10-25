-- Migration 0159 (2026-10-25): the deletion sweep's listing read each earlier list once per account row (032 and 095),
-- so it grew with the cube of the accounts and every worker call timed out on staging from 2026-10-12. Checks: the same
-- lists in the same order as the 032/095/128 bodies (copied below as references), the same files per account as 017's
-- account_deletion_objects, each layer evaluated once per call, a listing of 1,500 closed accounts well inside the
-- gateway's 8 s, and the sweep's listing reports in Health. Synthetic local SQL, all migrations; nothing leaves the machine.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;

-- References: the bodies before 0159, verbatim apart from their names (each reads the reference below it).
create function test.old_objects(a uuid) returns setof uuid language sql stable as $$
 select o.id from app_private.stored_objects o
 where o.owner_id=a or o.document_id in (select d.id from app_private.documents d where d.owner_id=a)
$$;
create function test.old_before_095(p_limit integer default 5) returns uuid[] language sql stable as $$
 select coalesce(array_agg(id order by closed_at,id),'{}') from (
  select a.id,a.closed_at from app_private.accounts a
  where a.id=any(app_private.worker_account_deletions_pending(20))
   or (a.closed_at is not null and a.closed_at>now()-interval '30 days'
    and (exists(select 1 from app_private.library_v4_entries e where e.account_id=a.id)
     or exists(select 1 from app_private.library_query_entries q where q.account_id=a.id)))
  order by a.closed_at,a.id limit greatest(1,least(p_limit,20))
 ) pending
$$;
create function test.old_before_128(p_limit integer default 5) returns uuid[] language sql stable as $$
 select coalesce(array_agg(id order by closed_at,id),'{}') from (
  select a.id,a.closed_at from app_private.accounts a
  where a.id=any(test.old_before_095(20))
   or (a.closed_at is not null and a.closed_at>now()-interval '30 days'
    and exists(select 1 from app_private.note_assets n where n.account_id=a.id))
  order by a.closed_at,a.id limit greatest(1,least(p_limit,20))
 ) pending
$$;
create function test.old_pending(p_limit integer default 5) returns uuid[] language sql stable as $$
 with earlier as (select unnest(test.old_before_128(20)) id),
 due as (
  select a.id,a.closed_at,s.last_attempt_at from app_private.accounts a
  left join app_private.account_deletion_sweeps s on s.account_id=a.id
  where a.closed_at is not null and (s.next_attempt_at is null or s.next_attempt_at<=now())
   and (a.id in (select id from earlier) or app_private.account_deletion_unfinished(a.id))
  order by s.last_attempt_at nulls first,a.closed_at,a.id
  limit greatest(1,least(coalesce(p_limit,5),20)))
 select coalesce(array_agg(id order by last_attempt_at nulls first,closed_at,id),'{}') from due
$$;

-- 1. A mix of unfinished and finished deletions, inside and beyond 017's 30 days.
create function test.acct(n integer) returns uuid language sql immutable as $$ select ('15900000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid $$;
grant usage on schema test to service_role;
grant execute on all functions in schema test to service_role;
insert into auth.users(id,email) select test.acct(g),'speed-'||g||'@gradstep.test.org' from generate_series(1,40) g;
-- 1–6: login still linked (017), closed 1–3 and 35–45 days ago.
update app_private.accounts a set closed_at=now()-make_interval(days=>d) from (values(1,1),(2,2),(3,3),(4,35),(5,40),(6,45)) v(n,d) where a.id=test.acct(v.n);
-- 7–8: a note image left (095).
set role service_role;
select public.worker_note_asset_reserve(test.acct(7),'15930000-0000-4000-8000-000000000007',decode(repeat('ab',32),'hex'),64);
select public.worker_note_asset_reserve(test.acct(8),'15930000-0000-4000-8000-000000000008',decode(repeat('cd',32),'hex'),64);
reset role;
update app_private.accounts set closed_at=now()-interval '2 days' where id=test.acct(7);
update app_private.accounts set closed_at=now()-interval '31 days' where id=test.acct(8);
-- 9–11: an owned support file not yet removed (017's files); 12: a file of its private conversion being deleted.
insert into app_private.stored_objects(bucket,path,owner_id,state,sha256,byte_count,media_type)
 select 'support',test.acct(g)||'/r/'||k||'.png',test.acct(g),case when k=1 then 'pending' else 'deleted' end,sha256('x'::bytea),10,'image/png'
 from generate_series(9,11) g,generate_series(1,2) k;
insert into app_private.documents(id,sha256,scope,owner_id,byte_count,page_count)
 values('15910000-0000-4000-8000-000000000012',sha256('private 12'::bytea),'owner_private',test.acct(12),1000,1),
       ('15910000-0000-4000-8000-000000000013',sha256('private 13'::bytea),'owner_private',test.acct(13),1000,1);
insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
 values('15920000-0000-4000-8000-000000000001',sha256('shared 1'::bytea),'shared_catalog','{"fixture":true}',1000,1);
insert into app_private.stored_objects(bucket,path,document_id,state,sha256,byte_count,media_type) values
 ('paper-assets','raw/'||encode(sha256('private 12'::bytea),'hex')||'/manifest.json','15910000-0000-4000-8000-000000000012','deleting',sha256('x'::bytea),10,'application/json'),
 ('paper-assets','raw/'||encode(sha256('private 13'::bytea),'hex')||'/manifest.json','15910000-0000-4000-8000-000000000013','deleted',sha256('x'::bytea),10,'application/json'),
 ('paper-assets','reader/'||encode(sha256('shared 1'::bytea),'hex')||'/a.json','15920000-0000-4000-8000-000000000001','deleted',sha256('x'::bytea),10,'application/json');
update app_private.accounts a set closed_at=now()-make_interval(days=>d) from (values(9,1),(10,5),(11,32),(12,4),(13,6)) v(n,d) where a.id=test.acct(v.n);
-- 14–33: finished deletions (closed, login gone, nothing left). 34–40 stay open.
update app_private.accounts set closed_at=now()-make_interval(hours=>g) from generate_series(14,33) g where id=test.acct(g);
delete from auth.users where id in (select test.acct(g) from generate_series(7,33) g);
alter table app_private.accounts disable trigger user;
update app_private.accounts set auth_user_id=null where id in (test.acct(7),test.acct(8));
alter table app_private.accounts enable trigger user;
-- One account in back-off, one tried and due again.
insert into app_private.account_deletion_sweeps(account_id,attempts,last_attempt_at,next_attempt_at,last_step,last_code) values
 (test.acct(2),1,now()-interval '1 minute',now()+interval '4 minutes','files','deletion_scan_incomplete'),
 (test.acct(9),3,now()-interval '2 hours',now()-interval '1 minute','files',null);

-- 2. Same files, same lists, same order.
select test.assert((select bool_and(array(select id from app_private.account_deletion_objects(test.acct(g)) order by id)
  =array(select test.old_objects(test.acct(g)) order by 1)) from generate_series(1,40) g),'account_deletion_objects: the same files for every account');
select test.assert((select count(*) from app_private.account_deletion_objects(test.acct(12)))=1
 and (select count(*) from app_private.account_deletion_objects(test.acct(9)))=2
 and (select count(*) from app_private.account_deletion_objects(test.acct(14)))=0,'owned files and private-conversion files, each once; none for others');
select test.assert(app_private.account_deletions_pending_before_095(n)=test.old_before_095(n)
 and app_private.account_deletions_pending_before_128(n)=test.old_before_128(n),'032 and 095 layers unchanged for limit '||n)
 from unnest(array[1,3,5,20]) n;
set role service_role;
select public.worker_account_deletions_pending(20) as listed \gset
select public.worker_account_deletions_pending(3) as first3 \gset
reset role;
select test.assert(:'listed'::uuid[]=test.old_pending(20) and :'first3'::uuid[]=test.old_pending(3),'128 listing unchanged');
-- Untried by closing date (45, 40, 35, 32, 31, 5, 4, 3, 2, 1 days), then the one tried two hours ago; 2 waits out its
-- back-off; 13 (its only file deleted) and 14–40 are finished or open.
select test.assert(:'listed'::uuid[]=array[test.acct(6),test.acct(5),test.acct(4),test.acct(11),test.acct(8),test.acct(10),
  test.acct(12),test.acct(3),test.acct(7),test.acct(1),test.acct(9)],'every unfinished deletion past its back-off, untried first');

-- 3. Each layer evaluated once per call (before 0159: 017's function once per pair of account rows).
set local track_functions='all';
set role service_role;
select public.worker_account_deletions_pending(5);
reset role;
select test.assert(pg_stat_get_xact_function_calls(p::regprocedure)=1,p||' evaluated once per listing') from unnest(array[
 'app_private.worker_account_deletions_pending(integer)','app_private.account_deletions_pending_before_095(integer)',
 'app_private.account_deletions_pending_before_128(integer)']) p;
reset track_functions;

-- 4. Scale: 1,500 more closed accounts, each with files tracked as deleted, as test and check accounts leave them.
insert into auth.users(id,email) select test.acct(g),'speed-'||g||'@gradstep.test.org' from generate_series(1001,2500) g;
insert into app_private.stored_objects(bucket,path,owner_id,state,sha256,byte_count,media_type)
 select 'support',test.acct(g)||'/r/'||k||'.png',test.acct(g),'deleted',sha256('x'::bytea),10,'image/png' from generate_series(1001,2500) g,generate_series(1,3) k;
update app_private.accounts set closed_at=now()-make_interval(mins=>g) from generate_series(1001,2500) g where id=test.acct(g);
delete from auth.users where id in (select test.acct(g) from generate_series(1001,2500) g);
analyze app_private.accounts; analyze app_private.stored_objects;
create temp table timing(step text,ms numeric);
set local statement_timeout='6s';
do $$ declare t timestamptz:=clock_timestamp(); begin
 perform public.worker_account_deletions_pending(5); insert into timing values('listing',extract(epoch from clock_timestamp()-t)*1000);
 t:=clock_timestamp(); perform app_private.account_deletion_health(); insert into timing values('health',extract(epoch from clock_timestamp()-t)*1000);
end $$;
reset statement_timeout;
select step,round(ms) ms from timing;
select test.assert(ms<3000,step||' with 1,533 closed accounts took '||round(ms)||' ms (the gateway cancels at 8 s)') from timing;

-- 5. The sweep reports each listing; Health shows it and the deletions it has never reached.
set role service_role;
select test.assert((public.worker_account_deletion_sweep_report(false,null,8001,'57014')->>'failures_in_row')::int=1,'a failed listing counts');
select test.assert((public.worker_account_deletion_sweep_report(false,null,8003,'57014')->>'failures_in_row')::int=2,'in a row');
select public.worker_account_deletion_health() as h \gset
reset role;
select test.assert((:'h'::jsonb->'sweep'->>'failures_in_row')::int=2 and :'h'::jsonb->'sweep'->>'last_code'='57014'
 and :'h'::jsonb->'sweep'->>'last_ok_at' is null and (:'h'::jsonb->'sweep'->>'last_ms')::int=8003,'Health names the failing listing');
-- Unfinished, closed over an hour ago and never tried: 1, 3–8, 10–12 (2 and 9 have attempts).
select test.assert((:'h'::jsonb->>'untried_over_1h')::int=10 and (:'h'::jsonb->>'unfinished')::int=12 and (:'h'::jsonb->>'retrying')::int=2
 and (:'h'::jsonb->>'stalled')::int=5,'untried over an hour, alongside 128''s counts');
select test.assert(not (:'h'::jsonb::text ~ 'gradstep\.test\.org|15900000'),'counts, times and codes only');
set role service_role;
select public.worker_account_deletion_sweep_report(true,3,42);
select public.worker_account_deletion_health() as h2 \gset
reset role;
select test.assert((:'h2'::jsonb->'sweep'->>'failures_in_row')::int=0 and (:'h2'::jsonb->'sweep'->>'last_ok_at')::timestamptz>now()-interval '1 minute'
 and :'h2'::jsonb->'sweep'->>'last_failed_at' is not null and (:'h2'::jsonb->'sweep'->>'last_ms')::int=42,'a listing clears the run of failures');
set role service_role;
select test.reject('select public.worker_account_deletion_sweep_report(true,3,10,''57014'')','invalid_sweep_report');
select test.reject('select public.worker_account_deletion_sweep_report(false,null,10,''account 1 failed'')','invalid_sweep_report');
select test.reject('select public.worker_account_deletion_sweep_report(false,2,10,''list_failed'')','invalid_sweep_report');
select test.reject('select public.worker_account_deletion_sweep_report(true,21,10,null)','invalid_sweep_report');
select test.reject('select public.worker_account_deletion_sweep_report(null,1,10,null)','invalid_sweep_report');
reset role;
select test.assert(not has_function_privilege('authenticated','public.worker_account_deletion_sweep_report(boolean,integer,integer,text)','execute')
 and not has_function_privilege('anon','public.worker_account_deletion_health()','execute')
 and not has_function_privilege('authenticated','public.worker_account_deletion_health()','execute')
 and has_function_privilege('service_role','public.worker_account_deletion_health()','execute')
 and not has_table_privilege('service_role','app_private.account_deletion_sweep_runs','select'),'service role only; the table through its functions');
rollback;
