-- Review A17 (migration 126): a device's podcast source text is reserved before it is written. The reservation checks
-- the account, the podcast switch, a request limit and both storage quotas, and creates the object's pending row; the
-- existing registration confirms it; a pending row whose upload never came is swept a day later; nothing refused leaves
-- a row. Synthetic local SQL, all migrations; nothing leaves the machine.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;

\set A '12600000-0000-4000-8000-00000000000a'
\set B '12600000-0000-4000-8000-00000000000b'
\set O '12600000-0000-4000-8000-00000000000f'
insert into auth.users(id,email) values(:'A','reserve-a@gradstep.test.org'),(:'B','reserve-b@gradstep.test.org'),(:'O','reserve-owner@gradstep.test.org');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
select encode(sha256(convert_to('Reserved paper text','UTF8')),'hex') as digest \gset
create function test.path(a uuid,digest text,n integer) returns text language sql as $$
 select 'podcast-sources/'||a::text||'/'||digest||'/12600000-0000-4000-8000-'||lpad(n::text,12,'0')||'.txt' $$;
create function test.reserve(a uuid,digest text,n integer,bytes bigint default 19) returns jsonb language sql as $$
 select public.worker_podcast_source_reserve(a,digest,bytes,test.path(a,digest,n)) $$;
grant execute on all functions in schema test to service_role,authenticated,anon;

-- Podcasts switched off: nothing is reserved (and nothing stored).
set role service_role;
select test.reject(format('select test.reserve(%L,%L,1)',:'A',:'digest'),'podcast_unavailable');
reset role;
select test.assert(not exists(select 1 from app_private.stored_objects where owner_id=:'A'),'nothing reserved while podcasts are off');
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),'{"generation_enabled":true}','Reservation fixture: generation on');

-- A reservation is a pending row at the upload's own path; the registration turns it verified; a replay is the same row.
set role service_role;
select test.reserve(:'A',:'digest',1) as reserved \gset
reset role;
select test.assert((:'reserved'::jsonb->>'state')='pending','reserved as pending before the write');
select test.assert((select state='pending' and verified_at is null and byte_count=19 from app_private.stored_objects where id=(:'reserved'::jsonb->>'object_id')::uuid),'pending row with the reserved size');
select coalesce((select sum(used) from app_private.api_rate_windows where route='podcast-source' and scope_id=:'A'),0) as used_before \gset
set role service_role;
select test.assert((test.reserve(:'A',:'digest',1)->>'object_id')=(:'reserved'::jsonb->>'object_id'),'a replay returns the same reservation');
select public.worker_podcast_source_register(:'A',:'digest',19,test.path(:'A',:'digest',1)) as registered \gset
reset role;
select test.assert((select coalesce(sum(used),0) from app_private.api_rate_windows where route='podcast-source' and scope_id=:'A')=:used_before,'a replay counts no second request');
select test.assert((:'registered'::jsonb->>'object_id')=(:'reserved'::jsonb->>'object_id')
 and (select state='verified' from app_private.stored_objects where id=(:'reserved'::jsonb->>'object_id')::uuid),'the registration confirms the reserved row');
set role service_role;
select test.reject(format('select public.worker_podcast_source_reserve(%L,%L,20,%L)',:'A',:'digest',test.path(:'A',:'digest',1)),'source_unavailable');
-- Only an upload's own path under the caller's account and digest; never the one-per-digest form.
select test.reject(format('select public.worker_podcast_source_reserve(%L,%L,19,%L)',:'A',:'digest',test.path(:'B',:'digest',2)),'invalid_podcast_request');
select test.reject(format('select public.worker_podcast_source_reserve(%L,%L,19,%L)',:'A',:'digest','podcast-sources/'||:'A'||'/'||:'digest'||'.txt'),'invalid_podcast_request');
select test.reject(format('select public.worker_podcast_source_reserve(%L,%L,409601,%L)',:'A',:'digest',test.path(:'A',:'digest',3)),'invalid_podcast_request');
select test.reject(format('select public.worker_podcast_source_reserve(%L,%L,19,%L)',:'A','XYZ',test.path(:'A',:'digest',3)),'invalid_podcast_request');
reset role;

-- The account quota counts reservations: a reservation past 64 MiB is refused and leaves no row.
insert into app_private.stored_objects(bucket,path,owner_id,sha256,byte_count,media_type,state,verified_at)
 values('private-content',test.path(:'A',repeat('c',64),9),:'A',decode(repeat('c',64),'hex'),67108864-19-10,'text/plain','verified',now());
set role service_role;
select test.reserve(:'A',:'digest',4,10);
select test.reject(format('select test.reserve(%L,%L,5,1)',:'A',:'digest'),'storage_full');
reset role;
select test.assert(not exists(select 1 from app_private.stored_objects where path=test.path(:'A',:'digest',5)),'a refused reservation leaves no row');

-- The request limit applies (a separate route, podcast-source).
update app_private.api_rate_rules set account_limit=2 where route='podcast-source';
set role service_role;
select test.reserve(:'B',:'digest',1);
select test.reserve(:'B',:'digest',2);
select test.reject(format('select test.reserve(%L,%L,3)',:'B',:'digest'),'request_rate_limit');
reset role;
update app_private.api_rate_rules set account_limit=20 where route='podcast-source';

-- A suspended or closed account reserves nothing.
update app_private.accounts set spending_suspended=true where id=:'B';
set role service_role;
select test.reject(format('select test.reserve(%L,%L,6)',:'B',:'digest'),'spending_suspended');
reset role;
update app_private.accounts set spending_suspended=false,closed_at=now() where id=:'B';
set role service_role;
select test.reject(format('select test.reserve(%L,%L,7)',:'B',:'digest'),'account_unavailable');
reset role;

-- An upload that never came: the pending row is swept a day later and listed for Storage like any unused upload.
alter table app_private.stored_objects disable trigger object_identity_immutable;
update app_private.stored_objects set created_at=now()-interval '2 days' where path=test.path(:'A',:'digest',4);
alter table app_private.stored_objects enable trigger object_identity_immutable;
set role service_role;
select public.worker_podcast_source_cleanup(50) as sweep \gset
reset role;
select test.assert((select state='deleting' from app_private.stored_objects where path=test.path(:'A',:'digest',4)),'an unconfirmed reservation is scheduled for deletion');
select test.assert(exists(select 1 from jsonb_array_elements(:'sweep'::jsonb->'objects') o where o->>'path'=test.path(:'A',:'digest',4)),'and listed for Storage');

select test.assert(not has_function_privilege('authenticated','public.worker_podcast_source_reserve(uuid,text,bigint,text)','execute')
 and not has_function_privilege('anon','public.worker_podcast_source_reserve(uuid,text,bigint,text)','execute')
 and has_function_privilege('service_role','public.worker_podcast_source_reserve(uuid,text,bigint,text)','execute'),'service role only');
rollback;
