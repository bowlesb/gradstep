-- An episode's paper text is deleted once the episode is made (migration 074; owner, 2026-10-16: "I dont think we
-- should even expose the podcast source text"): each upload has its own path; a finished job schedules the copies of
-- its text uploaded before it started, unless another unfinished job needs the same text; the worker's sweep lists
-- them for Storage and confirms; a retry of the same episode uses its fresh upload; an upload no job used is swept a
-- day later; the original one-path-per-digest form still registers until its copy goes. Synthetic local SQL; nothing leaves the machine.
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

\set O '74000000-0000-0000-0000-00000000000f'
\set A '74000000-0000-0000-0000-00000000000a'
insert into auth.users(id) values(:'O'),(:'A');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
select public.worker_grant_credits(:'A','adjustment','source-a',5000,now()-interval '1 day',null,'Source deletion fixture');
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),'{"seed_enabled":true,"generation_enabled":true,"catalog_enabled":true,"delivery_enabled":true}','Source test: switches on');
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),
 '{"profile_id":"podcast-5min-v1","profile_version":5,"allowed_profiles":["podcast-short-v1:5","podcast-short-v1:3","podcast-5min-v1:5","podcast-5min-v1:3","podcast-10min-v1:5","podcast-10min-v1:3","podcast-20min-v1:5","podcast-20min-v1:3"]}',
 'Source test: every length');

-- Each upload names its own path; a path outside the account and digest is refused.
select encode(sha256(convert_to('¶1 A paper read on this device.','UTF8')),'hex') as digest \gset
\set U1 '74000000-0000-4000-8000-000000000001'
select public.worker_podcast_source_register(:'A',:'digest',31,'podcast-sources/'||:'A'||'/'||:'digest'||'/'||:'U1'||'.txt') as first \gset
select test.assert((:'first'::jsonb->>'path')='podcast-sources/'||:'A'||'/'||:'digest'||'/'||:'U1'||'.txt','an upload is registered at its own path');
select test.reject(format('select public.worker_podcast_source_register(%L,%L,31,%L)',:'A',:'digest','podcast-sources/'||:'O'||'/'||:'digest'||'/'||:'U1'||'.txt'),'invalid_podcast_request');
select test.reject(format('select public.worker_podcast_source_register(%L,%L,31,%L)',:'A',:'digest','podcast-sources/'||:'A'||'/other.txt'),'invalid_podcast_request');

-- A job in progress (or requeued after a provider was busy) keeps its text, however old the upload.
\set M '74000000-0000-4000-8000-0000000000aa'
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
\set Q1 '74000000-0000-0000-00b0-000000000001'
select jsonb_build_object('source','arxiv','source_id','2610.16334','revision',1,'manifest_sha256',repeat('b',64),'text_sha256',:'digest','title','Toward Study') as device \gset
select public.v1_podcast_start((public.v1_podcast_quote(:'M',:'Q1','podcast-5min-v1','deepseek',:'device'::jsonb)->'quote'->>'id')::uuid,:'Q1','podcast-private-v2');
reset role;
alter table app_private.stored_objects disable trigger object_identity_immutable;
update app_private.stored_objects set created_at=now()-interval '2 days' where id=(:'first'::jsonb->>'object_id')::uuid;
alter table app_private.stored_objects enable trigger object_identity_immutable;
select public.worker_podcast_source_cleanup(50);
select test.assert((select state from app_private.stored_objects where id=(:'first'::jsonb->>'object_id')::uuid)='verified','an unfinished job keeps its text');
-- The job finishes (canceled while queued): its text is scheduled for deletion.
set role authenticated;
select public.v1_podcast_cancel(:'Q1');
reset role;
select test.assert((select state from app_private.stored_objects where id=(:'first'::jsonb->>'object_id')::uuid)='deleting','a finished job schedules its text for deletion');

-- The worker's sweep lists it for Storage, then confirms; the text is gone for good.
select public.worker_podcast_source_cleanup(50) as sweep \gset
select test.assert((:'sweep'::jsonb->'objects'->0->>'path')=(:'first'::jsonb->>'path') and (:'sweep'::jsonb->'objects'->0->>'bucket')='private-content','the sweep names the copy to delete');
select test.assert(public.worker_podcast_source_cleanup_confirm(array[(:'first'::jsonb->>'object_id')::uuid])=1,'the confirmation marks it deleted');
select test.assert((select state from app_private.stored_objects where id=(:'first'::jsonb->>'object_id')::uuid)='deleted','deleted');
select test.assert(app_private.podcast_device_pin(:'A',:'device'::jsonb||jsonb_build_object('membership_id',:'M')) is null,'a deleted copy pins nothing');

-- A retry of the same episode uploads again (its own path); the claim reads that fresh copy, not the deleted one.
\set U2 '74000000-0000-4000-8000-000000000002'
select public.worker_podcast_source_register(:'A',:'digest',31,'podcast-sources/'||:'A'||'/'||:'digest'||'/'||:'U2'||'.txt') as second \gset
set role authenticated;
\set Q3 '74000000-0000-0000-00b0-000000000003'
select public.v1_podcast_start((public.v1_podcast_quote(:'M',:'Q3','podcast-5min-v1','deepseek',:'device'::jsonb)->'quote'->>'id')::uuid,:'Q3','podcast-private-v2');
reset role;
select public.worker_podcast_claim('74000000-0000-4000-8000-0000000000c1',true) as claim \gset
select test.assert((:'claim'::jsonb->>'claimed')='true' and (:'claim'::jsonb->'source'->>'path')=(:'second'::jsonb->>'path'),'the claim reads the newest copy of the text');
-- Listen lists the request being made (the first page of the catalog), titled by its paper; the canceled one is gone.
set role authenticated;
select public.v1_podcast_catalog(null,20)->'mine' as mine \gset
reset role;
select test.assert(jsonb_array_length(:'mine'::jsonb->'requests')=1 and (:'mine'::jsonb->'requests'->0->>'request_id')=:'Q3'
 and (:'mine'::jsonb->'requests'->0->>'status')='making' and (:'mine'::jsonb->'requests'->0->>'title')='Toward Study'
 and (:'mine'::jsonb->'requests'->0->>'document_id')=:'M' and (:'mine'::jsonb->'requests'->0->>'profile')='podcast-5min-v1'
 and (:'mine'::jsonb->'requests'->0->>'target_seconds')::int=300 and :'mine'::jsonb->'episodes'='[]'::jsonb,'Listen shows the episode being made');
select test.assert(position('podcast-sources' in :'mine')=0 and position('paper read on this device' in :'mine')=0,'never a path or the text');
set role authenticated;
select test.assert(public.v1_podcast_catalog('1',20)->'mine'='null'::jsonb,'later pages carry no list of your own');
reset role;
-- While the worker has it the text stays, however old; when it ends (here a failure with no provider call) it goes.
alter table app_private.stored_objects disable trigger object_identity_immutable;
update app_private.stored_objects set created_at=now()-interval '2 days' where id=(:'second'::jsonb->>'object_id')::uuid;
alter table app_private.stored_objects enable trigger object_identity_immutable;
select public.worker_podcast_source_cleanup(50);
select test.assert((select state from app_private.stored_objects where id=(:'second'::jsonb->>'object_id')::uuid)='verified','a job in progress keeps its text');
select public.worker_podcast_fail((:'claim'::jsonb->>'job_id')::uuid,(:'claim'::jsonb->>'claim_id')::uuid,(:'claim'::jsonb->>'generation')::bigint,'script_rejected',false);
select test.assert((select state from app_private.stored_objects where id=(:'second'::jsonb->>'object_id')::uuid)='deleting','a failed job schedules its text for deletion');
select test.assert(not exists(select 1 from app_private.stored_objects where owner_id=:'A' and path like 'podcast-sources/%' and sha256=decode(:'digest','hex') and state in ('pending','verified')),
 'no copy of the paper text remains');
set role authenticated;
select public.v1_podcast_catalog(null,20)->'mine' as mine \gset
reset role;
select test.assert((:'mine'::jsonb->'requests'->0->>'status')='failed' and (:'mine'::jsonb->'requests'->0->>'request_id')=:'Q3','a request that could not be made says so');

-- Trying again (a fresh copy of the text): the failed request gives way to the new one; once it is ready (published
-- here directly, synthetic) Listen lists the episode with its paper's title and the request that made it, and the text goes.
-- (One transaction shares one clock: the earlier request is dated a minute back, as it would be.)
update app_private.podcast_jobs set created_at=created_at-interval '1 minute' where id=(:'claim'::jsonb->>'job_id')::uuid;
\set U4 '74000000-0000-4000-8000-000000000004'
select public.worker_podcast_source_register(:'A',:'digest',31,'podcast-sources/'||:'A'||'/'||:'digest'||'/'||:'U4'||'.txt') as fourth \gset
\set Q4 '74000000-0000-0000-00b0-000000000004'
set role authenticated;
select public.v1_podcast_start((public.v1_podcast_quote(:'M',:'Q4','podcast-5min-v1','deepseek',:'device'::jsonb)->'quote'->>'id')::uuid,:'Q4','podcast-private-v2');
select public.v1_podcast_catalog(null,20)->'mine' as mine \gset
reset role;
select test.assert(jsonb_array_length(:'mine'::jsonb->'requests')=1 and (:'mine'::jsonb->'requests'->0->>'request_id')=:'Q4'
 and (:'mine'::jsonb->'requests'->0->>'status')='making','the new request replaces the failed one');
select q.job_id as job4,j.episode_id as ep4 from app_private.podcast_requests q join app_private.podcast_jobs j on j.id=q.job_id where q.account_id=:'A' and q.request_id=:'Q4' \gset
insert into app_private.podcast_scripts(job_id,episode_id,script_sha256,checker_version,decision,segments,chapters)
 values(:'job4',:'ep4',sha256('s4'),'podcast-checker-v6','accepted',20,4) returning id as script4 \gset
insert into app_private.podcast_releases(episode_id,job_id,script_id,scope,owner_id,origin,identity,manifest_sha256,duration_ms,state,published_seq,published_at)
 values(:'ep4',:'job4',:'script4','private',:'A','generated','{}',sha256('m4'),301000,'ready',nextval('app_private.podcast_publication_seq'),now()) returning id as rel4 \gset
update app_private.podcast_jobs set state='ready',finished_at=clock_timestamp() where id=:'job4';
select test.assert((select state from app_private.stored_objects where id=(:'fourth'::jsonb->>'object_id')::uuid)='deleting','the ready episode schedules its text for deletion');
set role authenticated;
select public.v1_podcast_catalog(null,20)->'mine' as mine \gset
reset role;
select test.assert(:'mine'::jsonb->'requests'='[]'::jsonb and jsonb_array_length(:'mine'::jsonb->'episodes')=1
 and (:'mine'::jsonb->'episodes'->0->>'release_id')=:'rel4' and (:'mine'::jsonb->'episodes'->0->>'request_id')=:'Q4'
 and (:'mine'::jsonb->'episodes'->0->>'title')='Toward Study' and (:'mine'::jsonb->'episodes'->0->>'scope')='private'
 and (:'mine'::jsonb->'episodes'->0->>'document_id')=:'M','Listen lists the ready episode');

-- An upload no job used is swept after a day; the original one-path-per-digest form still registers, and refuses once
-- that copy is scheduled for deletion (object rows never come back).
select encode(sha256(convert_to('¶1 Another paper.','UTF8')),'hex') as other \gset
\set U3 '74000000-0000-4000-8000-000000000003'
select public.worker_podcast_source_register(:'A',:'other',20,'podcast-sources/'||:'A'||'/'||:'other'||'/'||:'U3'||'.txt') as unused \gset
alter table app_private.stored_objects disable trigger object_identity_immutable;
update app_private.stored_objects set created_at=now()-interval '2 days' where id=(:'unused'::jsonb->>'object_id')::uuid;
alter table app_private.stored_objects enable trigger object_identity_immutable;
select test.assert((public.worker_podcast_kick_sources()->>'due')::int>=1,'the hourly schedule wakes the worker for it');
select test.assert((public.worker_podcast_source_cleanup(50)->>'orphaned')::int>=1,'the sweep counts the unused upload');
select test.assert((select state from app_private.stored_objects where id=(:'unused'::jsonb->>'object_id')::uuid)='deleting','an upload no job used is swept after a day');
select public.worker_podcast_source_register(:'A',:'other',20) as legacy \gset
select test.assert((:'legacy'::jsonb->>'path')='podcast-sources/'||:'A'||'/'||:'other'||'.txt','the three-argument form keeps the one-per-digest path');
select test.assert((public.worker_podcast_source_register(:'A',:'other',20)->>'object_id')=(:'legacy'::jsonb->>'object_id'),'registering it again returns the same copy');
update app_private.stored_objects set state='deleting' where id=(:'legacy'::jsonb->>'object_id')::uuid;
select test.reject(format('select public.worker_podcast_source_register(%L,%L,20)',:'A',:'other'),'source_unavailable');

-- Readers cannot list or confirm the sweep.
select test.assert(not has_function_privilege('authenticated','public.worker_podcast_source_cleanup(integer)','execute')
 and not has_function_privilege('authenticated','public.worker_podcast_source_cleanup_confirm(uuid[])','execute')
 and not has_function_privilege('authenticated','public.worker_podcast_source_register(uuid,text,bigint,text)','execute')
 and not has_function_privilege('authenticated','public.worker_podcast_kick_sources()','execute'),'service role only');
rollback;
