-- Real admission, retention and authority behavior; no Apple/Google calls.
begin;
insert into auth.users values('33000000-0000-0000-0000-000000000001'),('33000000-0000-0000-0000-000000000002'),
 ('33000000-0000-0000-0000-000000000003');
create function pg_temp.verifier_id(stamp timestamptz default clock_timestamp()) returns uuid language sql volatile as $$
 select (lpad(to_hex(floor(extract(epoch from stamp)*1000)::bigint),12,'0')||'7'||substr(replace(gen_random_uuid()::text,'-',''),1,3)
  ||'8'||substr(replace(gen_random_uuid()::text,'-',''),1,15))::uuid
$$;
\set A '\'33000000-0000-0000-0000-000000000001\''
\set B '\'33000000-0000-0000-0000-000000000002\''
\set C '\'33000000-0000-0000-0000-000000000003\''
\set P '\'app-store-sandbox-v1\''
set role authenticated;
select set_config('request.jwt.claim.sub','33000000-0000-0000-0000-000000000001',true);
select test.reject($q$select public.worker_store_verifier_readiness()$q$,'permission denied');
select test.reject($q$select public.worker_start_store_verifier('app','33000000-0000-0000-0000-000000000001',pg_temp.verifier_id(),20,'app-store-sandbox-v1')$q$,'permission denied');
select test.reject($q$select public.worker_set_store_verifier_enabled('app',1,true)$q$,'permission denied');
select test.reject($q$select public.worker_finish_store_verifier(gen_random_uuid(),'verified',10)$q$,'permission denied');
select test.reject($q$select public.worker_prune_store_verifier()$q$,'permission denied');
select test.reject($q$select public.v1_admin_store_verifier_usage()$q$,'owner_mfa_required');
reset role;
insert into app_private.app_roles(account_id,role) values(:A,'owner');
set role authenticated;
select test.reject($q$select public.v1_admin_store_verifier_usage()$q$,'owner_mfa_required');
select set_config('request.jwt.claim.aal','aal2',true);
select test.assert(public.v1_admin_store_verifier_usage()->>'policy_id'='app-store-sandbox-v1','only owner with MFA can inspect allowance');
reset role;
set role anon;
select test.reject($q$select public.worker_start_store_verifier('notification',null,pg_temp.verifier_id(),20,'app-store-sandbox-v1')$q$,'permission denied');
select test.reject($q$select public.v1_admin_store_verifier_usage()$q$,'permission denied');
reset role;

set role service_role;
select test.assert(public.worker_store_verifier_readiness() @> '{"version":1,"migration":"202610070033_purchase_verification_transport","channels":[{"channel":"app","enabled":false,"revision":1,"limits":{"account_hour":50,"hour":500,"day":300,"month":3000}},{"channel":"notification","enabled":false,"revision":1,"limits":{"account_hour":null,"hour":60,"day":200,"month":1000}}]}','initial exact policy is paused');
select test.assert(public.worker_start_store_verifier('notification',null,pg_temp.verifier_id(),20,:P)->>'reason'='disabled','paused notification admission fails closed');
select test.reject($q$select public.worker_start_store_verifier('app',null,pg_temp.verifier_id(),20,'app-store-sandbox-v1')$q$,'invalid_store_verifier_request');
select test.reject($q$select public.worker_start_store_verifier('notification','33000000-0000-0000-0000-000000000001',pg_temp.verifier_id(),20,'app-store-sandbox-v1')$q$,'invalid_store_verifier_request');
select test.reject($q$select public.worker_start_store_verifier('notification',null,pg_temp.verifier_id(),64001,'app-store-sandbox-v1')$q$,'invalid_store_verifier_request');
select test.reject($q$select public.worker_start_store_verifier('notification',null,pg_temp.verifier_id(),20,'app-store-production-v1')$q$,'invalid_store_verifier_request');
select test.reject($q$select public.worker_start_store_verifier('notification',null,gen_random_uuid(),20,'app-store-sandbox-v1')$q$,'invalid_store_verifier_attempt');
select test.reject($q$select public.v1_admin_store_verifier_usage()$q$,'permission denied');
select test.assert(public.worker_set_store_verifier_enabled('app',1,true)->>'revision'='2','CAS enables app');
select test.assert(public.worker_set_store_verifier_enabled('notification',1,true)->>'revision'='2','CAS enables notification independently');
select test.reject($q$select public.worker_set_store_verifier_enabled('app',1,false)$q$,'store_verifier_policy_conflict');
select test.assert(public.worker_set_store_verifier_enabled('app',2,true)->>'revision'='2','same observed state is idempotent');
reset role;
select test.assert((select count(*)=0 from app_private.store_verifier_starts),'invalid and paused traffic allocate no attempt rows');
select test.assert((select count(*)=3 from app_private.store_verifier_windows),'denied anonymous traffic has only fixed aggregate windows');

-- Every committed start is one-use, even before a completion observation or
-- when the original caller never received its RPC reply.
create temporary table selected_id as select pg_temp.verifier_id() id;
grant select on selected_id to service_role;
set role service_role;
select test.assert(public.worker_start_store_verifier('app',:A,(select id from selected_id),64000,:P)->>'granted'='true','exact maximum admitted');
select test.assert(public.worker_start_store_verifier('app',:A,(select id from selected_id),64000,:P)->>'reason'='attempt_replayed','lost acknowledgment cannot grant again');
select test.assert(public.worker_start_store_verifier('app',:B,(select id from selected_id),20,:P)->>'reason'='attempt_replayed','another account cannot reuse attempt');
select test.assert(public.worker_start_store_verifier('notification',null,(select id from selected_id),20,:P)->>'reason'='attempt_replayed','another channel cannot reuse attempt');
select test.assert(public.worker_finish_store_verifier((select id from selected_id),'verification_unavailable',70000),'uncertain timeout observed');
select test.assert(public.worker_finish_store_verifier((select id from selected_id),'verification_unavailable',70000),'exact completion replay is inert');
select test.reject($q$select public.worker_finish_store_verifier((select id from selected_id),'verified',10)$q$,'store_verifier_observation_conflict');
select test.assert(public.worker_start_store_verifier('app',:A,(select id from selected_id),64000,:P)->>'reason'='attempt_replayed','completion never refunds or rearms');
select test.assert(public.worker_start_store_verifier('app',:A,pg_temp.verifier_id(),20,:P)->>'granted'='true','intentional retry consumes fresh admission');
reset role;
select test.assert((select count(*)=2 from app_private.store_verifier_starts),'two admissions, not calls or credit grants');
select test.assert((select bool_and(starts=2) from app_private.store_verifier_windows where channel='app'),'all three windows retain timeout liability');
select test.assert((select starts=2 from app_private.store_verifier_account_hours where account_id=:A),'account count also retained');

-- The real account hourly boundary, and notification allowance isolation.
set role service_role;
do $$ begin
 for n in 1..48 loop
  perform test.assert(public.worker_start_store_verifier('app','33000000-0000-0000-0000-000000000001',pg_temp.verifier_id(),20,'app-store-sandbox-v1')->>'granted'='true','within account allowance');
 end loop;
end $$;
select test.assert(public.worker_start_store_verifier('app',:A,pg_temp.verifier_id(),20,:P)->>'reason'='account_limit','51st account admission refused');
select test.assert(public.worker_start_store_verifier('app',:B,pg_temp.verifier_id(),20,:P)->>'granted'='true','other account still has own allowance');
do $$ begin
 for n in 1..60 loop
  perform test.assert(public.worker_start_store_verifier('notification',null,pg_temp.verifier_id(),20,'app-store-sandbox-v1')->>'granted'='true','within notification allowance');
 end loop;
end $$;
select test.assert(public.worker_start_store_verifier('notification',null,pg_temp.verifier_id(),20,:P)->>'reason'='channel_limit','61st notification refused');
select test.assert(public.worker_start_store_verifier('app',:B,pg_temp.verifier_id(),20,:P)->>'granted'='true','notification exhaustion does not consume app allowance');
reset role;
select test.assert((select count(*)=112 from app_private.store_verifier_starts),'denied starts were not allocated');

-- Seed near the otherwise expensive month/day ceilings, then exercise real
-- admission. Old-hour rows do not reset the day or month totals.
update app_private.store_verifier_windows set starts=case unit when 'hour' then 0 when 'day' then 199 else 999 end where channel='notification';
set role service_role;
select test.assert(public.worker_start_store_verifier('notification',null,pg_temp.verifier_id(),20,:P)->>'granted'='true','last daily/monthly slot admitted');
select test.assert(public.worker_start_store_verifier('notification',null,pg_temp.verifier_id(),20,:P)->>'reason'='channel_limit','month/day cannot be bypassed by a fresh hour');
select public.worker_set_store_verifier_enabled('notification',2,false);
select public.worker_set_store_verifier_enabled('notification',3,true);
select test.assert(public.worker_start_store_verifier('notification',null,pg_temp.verifier_id(),20,:P)->>'reason'='channel_limit','disable/re-enable preserves all usage');
reset role;

-- An account that closes cannot start verification. Its environment totals
-- remain; later deletion of the Auth mapping cannot reset them.
update app_private.accounts set closed_at=clock_timestamp(),auth_user_id=null where id=:B;
delete from auth.users where id=:B;
set role service_role;
select test.assert(public.worker_start_store_verifier('app',:B,pg_temp.verifier_id(),20,:P)->>'reason'='account_unavailable','closed account denied');
select test.assert(public.worker_start_store_verifier('app','33000000-0000-0000-0000-000000000099',pg_temp.verifier_id(),20,:P)->>'reason'='account_unavailable','missing account denied without a sentinel');
reset role;
select test.assert((select bool_and(starts=52) from app_private.store_verifier_windows where channel='app'),'global liability survives account closure');

-- Time, retention and non-UTC sessions. Old IDs remain expired even after
-- their row is gone. A backwards server clock cannot reopen old windows.
set local timezone='America/Los_Angeles';
set role service_role;
select test.assert(public.worker_start_store_verifier('app',:C,pg_temp.verifier_id(clock_timestamp()-interval '121 seconds'),20,:P)->>'reason'='attempt_expired','stale attempt refused');
select test.assert(public.worker_start_store_verifier('app',:C,pg_temp.verifier_id(clock_timestamp()+interval '31 seconds'),20,:P)->>'reason'='attempt_expired','future attempt refused');
select test.assert(public.worker_start_store_verifier('app',:C,pg_temp.verifier_id(clock_timestamp()+interval '29 seconds'),20,:P)->>'granted'='true','small permitted clock skew');
reset role;
select test.assert((select bool_and(period=date_trunc(unit,clock_timestamp() at time zone 'UTC') at time zone 'UTC') from app_private.store_verifier_windows),'all window keys use UTC, not caller time zone');
update app_private.store_verifier_policy set clock_floor=clock_timestamp()+interval '1 hour' where channel='app';
set role service_role;
select test.assert(public.worker_start_store_verifier('app',:C,pg_temp.verifier_id(),20,:P)->>'reason'='clock_unavailable','backwards clock fails closed');
reset role;
update app_private.store_verifier_policy set clock_floor=clock_timestamp() where channel='app';
create temporary table expired_id as select pg_temp.verifier_id(clock_timestamp()-interval '40 days') id;
grant select on expired_id to service_role;
insert into app_private.store_verifier_starts(id,channel,account_id,policy_id,payload_bytes,started_at,expires_at)
 select id,'app',:C,:P,20,stamp,stamp+interval '840 hours' from expired_id
 cross join (select clock_timestamp()-interval '960 hours' stamp) boundary;
set role service_role;
select public.worker_prune_store_verifier();
select test.assert(public.worker_start_store_verifier('app',:C,(select id from expired_id),20,:P)->>'reason'='attempt_expired','pruning never re-arms a previously consumed ID');
reset role;
select test.assert(not exists(select 1 from app_private.store_verifier_starts where id=(select id from expired_id)),'expired attempt removed');
select test.assert((select starts=53 from app_private.store_verifier_windows where channel='app' and unit='month'),'pruning retained the monthly aggregate');
rollback;
