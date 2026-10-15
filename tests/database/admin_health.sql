-- Service health (migration 069, docs/architecture/ADMIN_HEALTH.md): the limiter records which accounts used the
-- service each day, a rejected request records nothing, a closed account is forgotten, test accounts stay out of the
-- people and use graphs, and only an owner with MFA reads the aggregates. Synthetic local SQL.
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

\set O '69000000-0000-0000-0000-00000000000f'
\set A '69000000-0000-0000-0000-00000000000a'
\set B '69000000-0000-0000-0000-00000000000b'
\set T '69000000-0000-0000-0000-00000000000c'
insert into auth.users(id,email) values(:'O','owner@gradstep.test.org'),(:'A','reader-a@gradstep.test.org'),(:'B','reader-b@gradstep.test.org'),(:'T','gradstep-smoke-x@example.invalid');
insert into app_private.app_roles(account_id,role) values(:'O','owner');

-- The limiter's requests become activity days with their routes; the environment scope is not an account.
select public.worker_consume_request(:'A','chat');
select public.worker_consume_request(:'A','chat');
select public.worker_consume_request(:'A','sync-read');
select public.worker_consume_request(:'B','sync-read');
select public.worker_consume_request(:'T','chat');
select test.assert((select routes from app_private.account_activity_days where account_id=:'A')=array['chat','sync-read'],'one row per account-day; each route once');
select test.assert((select count(*) from app_private.account_activity_days where day=(now() at time zone 'UTC')::date)=3,'three accounts active today, the environment scope left out');
-- Yesterday, for the 7-day window and returning accounts.
insert into app_private.account_activity_days values((now() at time zone 'UTC')::date-1,:'B','{library-read}');
update app_private.accounts set created_at=now()-interval '10 days' where id=:'B';

-- A rejected request records nothing (the limiter's exception rolls the row back).
update app_private.api_rate_rules set account_limit=1 where route='discover';
select public.worker_consume_request(:'A','discover');
select test.reject($$select public.worker_consume_request('69000000-0000-0000-0000-00000000000a','discover')$$,'request_rate_limit');
select test.assert((select routes @> array['discover'] from app_private.account_activity_days where account_id=:'A'),'the accepted request counted');

-- Paid work and paper adds for the use graphs.
insert into app_private.import_requests(account_id,id,request_sha256,source_id,requested_revision,observed_cursor,created_seq,state_seq,intent_revision,desired_present,phase,retryable,created_at,error_code)
select :'A',gen_random_uuid(),sha256(convert_to(n::text,'UTF8')),'2610.0000'||n,1,0,n,n,1,true,case when n=3 then 'failed' else 'source_only' end,false,now(),case when n=3 then 'metadata_unavailable' end
from generate_series(1,3) n;

-- Owner with MFA only.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject('select public.v1_admin_health(30)','owner_mfa_required');
select set_config('request.jwt.claim.sub',:'O',false);
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject('select public.v1_admin_health(30)','owner_mfa_required');
select set_config('request.jwt.claim.aal','aal2',false);
select test.reject('select public.v1_admin_health(0)','invalid_metrics_window');
select public.v1_admin_health(7) as h \gset
select test.assert((:'h'::jsonb->'people'->>'accounts')::int=3,'owner and two readers; the smoke account left out');
select test.assert((:'h'::jsonb->'people'->>'active_7d')::int=2,'two readers active this week; the smoke account left out');
select test.assert((:'h'::jsonb->'people'->>'returning_7d')::int=1,'the older account came back');
select test.assert(jsonb_array_length(:'h'::jsonb->'people'->'daily')=7,'seven zero-filled days');
select test.assert((select (d->>'active')::int from jsonb_array_elements(:'h'::jsonb->'people'->'daily') d order by d->>'day' desc limit 1)=2,'today: two active');
select test.assert((:'h'::jsonb->'use'->>'papers_added')::int=3 and (:'h'::jsonb->'reliability'->>'papers_failed')::int=1,'papers added and failed');
select test.assert((:'h'::jsonb->'reliability'->'paper_failure_codes'->>'metadata_unavailable')::int=1,'failure codes');
select test.assert(:'h'::jsonb->'money' ? 'chat_cache' and :'h'::jsonb->'money' ? 'month_to_date_microusd','money headlines present');
reset role;

-- A closed account leaves no activity behind.
update app_private.accounts set closed_at=now() where id=:'B';
select test.assert(not exists(select 1 from app_private.account_activity_days where account_id=:'B'),'closed account forgotten');
-- Rows are private to the database.
set role authenticated;
select test.reject('select * from app_private.account_activity_days','permission denied');
reset role;
rollback;
