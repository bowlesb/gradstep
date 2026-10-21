-- Review A16 (migration 125): account deletion removes the account's podcast device-source records (paper identity,
-- title, authors, digests); every other update/delete stays refused; another account's rows are untouched; the
-- de-identified billing records (job, operation) stay. Synthetic local SQL, all migrations; nothing leaves the machine.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;

\set A '12500000-0000-4000-8000-00000000000a'
\set B '12500000-0000-4000-8000-00000000000b'
\set O '12500000-0000-4000-8000-00000000000f'
insert into auth.users(id,email) values(:'A','device-source-a@gradstep.test.org'),(:'B','device-source-b@gradstep.test.org'),(:'O','device-source-owner@gradstep.test.org');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','device-source-a',10000,now()-interval '1 day',null,'Device source fixture');
select public.worker_grant_credits(:'B','adjustment','device-source-b',10000,now()-interval '1 day',null,'Device source fixture');
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),'{"generation_enabled":true,"delivery_enabled":true,"profile_id":"podcast-short-v1","profile_version":7,"allowed_profiles":["podcast-short-v1:6","podcast-short-v1:7"]}','Device source deletion fixture');

-- One queued private episode from device text per account, then cancelled (finished and settled).
create function test.device_episode(a uuid,title text) returns uuid language plpgsql as $$
declare item uuid:=gen_random_uuid(); req uuid:=gen_random_uuid(); quote jsonb; digest text:=encode(sha256(convert_to('Device paper text '||a::text,'UTF8')),'hex');
begin
 perform public.worker_podcast_source_register(a,digest,25,'podcast-sources/'||a::text||'/'||digest||'/'||gen_random_uuid()::text||'.txt');
 perform set_config('request.jwt.claim.sub',a::text,true);
 quote:=public.v1_podcast_quote(item,req,'podcast-short-v1','deepseek',jsonb_build_object('source','arxiv','source_id','2610.16334','revision',1,
  'manifest_sha256',repeat('b',64),'text_sha256',digest,'title',title,'authors',jsonb_build_array('A. Reader')));
 perform public.v1_podcast_start((quote->'quote'->>'id')::uuid,req,'podcast-private-v3');
 perform public.v1_podcast_cancel(req);
 return item;
end $$;
select test.device_episode(:'A','Paper A read on this device') as item_a \gset
select test.device_episode(:'B','Paper B read on this device') as item_b \gset
select test.assert((select count(*)=1 from app_private.podcast_device_sources where owner_id=:'A' and membership_id=:'item_a' and title='Paper A read on this device'),'A has a device-source record');
select test.assert((select count(*)=1 from app_private.podcast_device_sources where owner_id=:'B'),'B has a device-source record');
select count(*) as jobs_a from app_private.podcast_jobs where operation_account_id=:'A' \gset

-- Outside a deletion the rows stay immutable, and a deletion context for one account cannot touch another's rows.
select test.reject(format('update app_private.podcast_device_sources set title=null where owner_id=%L',:'A'),'immutable_record_requires_compensating_entry');
select test.reject(format('delete from app_private.podcast_device_sources where owner_id=%L',:'A'),'immutable_record_requires_compensating_entry');
select test.reject(format('select app_private.podcast_device_sources_forget(%L)',:'A'),'account_not_closed');
select set_config('app_private.deleting_account',:'A',true);
select test.reject(format('delete from app_private.podcast_device_sources where owner_id=%L',:'B'),'immutable_record_requires_compensating_entry');
select test.reject(format('update app_private.podcast_device_sources set title=null where owner_id=%L',:'A'),'immutable_record_requires_compensating_entry');
select set_config('app_private.deleting_account','',true);

-- Deleting A removes A's rows (personal), keeps its billing records, and leaves B alone.
set role service_role;
select public.worker_podcast_account_closing(:'A');
select public.worker_delete_account_begin(:'A') as plan \gset
reset role;
select test.assert(not (:'plan'::jsonb ? 'blocked'),'nothing blocks this deletion');
select test.assert(not exists(select 1 from app_private.podcast_device_sources where owner_id=:'A'),'deletion removes the account''s device-source records');
select test.assert((select count(*)=1 from app_private.podcast_device_sources where owner_id=:'B'),'another account''s records stay');
select test.assert((select count(*)=:jobs_a from app_private.podcast_jobs where operation_account_id=:'A'),'billing records (jobs) stay under the account UUID');
select test.assert(exists(select 1 from app_private.metered_operations where account_id=:'A' and kind='podcast'),'metered operations stay');
set role service_role;
select public.worker_account_deletion_status(:'A') as status \gset
reset role;
select test.assert((:'status'::jsonb->>'podcast_device_sources')::int=0,'status counts device-source rows');
-- Repeating the deletion is harmless.
set role service_role;
select public.worker_delete_account_begin(:'A');
reset role;

-- A closed account left with rows (closed before migration 125): the same scrub removes them once.
update app_private.accounts set closed_at=now() where id=:'B';
select test.assert(app_private.podcast_device_sources_forget(:'B')=1,'a closed account''s leftover rows are removed');
select test.assert(not exists(select 1 from app_private.podcast_device_sources where owner_id=:'B'),'gone');

select test.assert(not has_function_privilege('authenticated','public.worker_delete_account_begin(uuid)','execute')
 and not has_function_privilege('service_role','app_private.podcast_device_sources_forget(uuid)','execute')
 and not has_function_privilege('authenticated','app_private.podcast_device_sources_forget(uuid)','execute'),'only the deletion path can remove rows');
rollback;
