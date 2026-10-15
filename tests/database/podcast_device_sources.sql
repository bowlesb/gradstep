-- Episodes from the paper on this device (migration 066, docs/architecture/PAPER_PODCASTS.md "Episodes from the paper
-- on this device"): the Edge function stores the device's text and registers it (service role); a quote names it by
-- digest with the paper's identity; the pin is ids and digests and recomputes from its own fields; the start creates a
-- private episode with a device source; the claim hands the worker the same source shape; the paper lookup by
-- membership id finds the job; a wrong digest, a bad id or another account's text is refused. Synthetic local SQL;
-- nothing leaves the machine. Runs after the HTML-first cutover migrations (scripts/test-database.py).
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

\set O '66000000-0000-0000-0000-00000000000f'
\set A '66000000-0000-0000-0000-00000000000a'
\set B '66000000-0000-0000-0000-00000000000b'
insert into auth.users(id) values(:'O'),(:'A'),(:'B');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
select public.worker_grant_credits(:'A','adjustment','device-a',2000,now()-interval '1 day',null,'Device source fixture');
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),'{"seed_enabled":true,"generation_enabled":true,"catalog_enabled":true,"delivery_enabled":true}','Device test: switches on');
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),
 '{"profile_id":"podcast-5min-v1","profile_version":5,"allowed_profiles":["podcast-short-v1:5","podcast-short-v1:3","podcast-5min-v1:5","podcast-5min-v1:3","podcast-10min-v1:5","podcast-10min-v1:3","podcast-20min-v1:5","podcast-20min-v1:3"]}',
 'Device test: both writers of every length');

-- The Edge function stored the text; the service role registers it once per account and digest.
select encode(sha256(convert_to('¶1 A paper read on this device.','UTF8')),'hex') as digest \gset
select public.worker_podcast_source_register(:'A',:'digest',31) as stored \gset
select test.assert((:'stored'::jsonb->>'bucket')='private-content' and (:'stored'::jsonb->>'path')='podcast-sources/'||:'A'||'/'||:'digest'||'.txt'
 and (:'stored'::jsonb->>'bytes')::int=31,'the text is registered under the account by digest');
select test.assert((select state='verified' and owner_id=:'A' and media_type='text/plain' and document_id is null
 from app_private.stored_objects where id=(:'stored'::jsonb->>'object_id')::uuid),'verified and owner-scoped');
select test.assert((public.worker_podcast_source_register(:'A',:'digest',31)->>'object_id')=(:'stored'::jsonb->>'object_id'),'the same digest again is the same object');
select test.reject(format('select public.worker_podcast_source_register(%L,%L,%s)',:'A',:'digest',32),'source_unavailable');
select test.reject(format('select public.worker_podcast_source_register(%L,%L,%s)',:'A',repeat('z',64),10),'invalid_podcast_request');
select test.reject(format('select public.worker_podcast_source_register(%L,%L,%s)',:'A',repeat('a',64),409601),'invalid_podcast_request');

-- The pin: ids and digests, recomputable from its own fields, this account's text only.
\set M '66000000-0000-4000-8000-0000000000aa'
select app_private.podcast_device_pin(:'A',jsonb_build_object('membership_id',:'M','source','arxiv','source_id','2610.16334','revision',1,
 'manifest_sha256',repeat('b',64),'text_sha256',:'digest','title','Toward Study','authors',jsonb_build_array('Gayoung Kim','Go-Eum Cha'))) as pin \gset
select test.assert((:'pin'::jsonb->>'kind')='device' and (:'pin'::jsonb->>'text_object_id')=(:'stored'::jsonb->>'object_id') and (:'pin'::jsonb->>'text_bytes')::int=31
 and (:'pin'::jsonb->>'normalization_version')='gradstep-paper-context-v2' and (:'pin'::jsonb->>'title')='Toward Study' and jsonb_array_length(:'pin'::jsonb->'authors')=2
 and (:'pin'::jsonb->>'membership_id')=:'M','the pin names the object, the digest and the paper');
select test.assert(app_private.podcast_device_pin(:'A',:'pin'::jsonb)=:'pin'::jsonb,'the pin recomputes from its own fields');
select test.assert(app_private.podcast_device_pin(:'B',:'pin'::jsonb) is null,'another account cannot pin this text');
select test.assert(app_private.podcast_device_pin(:'A',:'pin'::jsonb||jsonb_build_object('text_sha256',repeat('c',64))) is null,'an unknown digest pins nothing');
select test.assert(app_private.podcast_device_pin(:'A',:'pin'::jsonb||'{"source_id":"not an id"}'::jsonb) is null,'a bad source id pins nothing');
select test.assert(octet_length(app_private.podcast_device_pin(:'A',:'pin'::jsonb||jsonb_build_object('title',repeat('t',600),'authors',
 (select jsonb_agg(repeat('a',300)) from generate_series(1,20))))::text)<=4096,'a long title and many authors still fit the quote''s pin bound');

-- A quote with the device descriptor, as the account; a wrong digest or no source at all is refused.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
\set Q1 '66000000-0000-0000-00b0-000000000001'
select public.v1_podcast_quote(:'M',:'Q1','podcast-5min-v1','deepseek',jsonb_build_object('source','arxiv','source_id','2610.16334','revision',1,
 'manifest_sha256',repeat('b',64),'text_sha256',:'digest','title','Toward Study','authors',jsonb_build_array('Gayoung Kim'))) as quoted \gset
select test.assert((:'quoted'::jsonb->'quote'->>'profile')='podcast-5min-v1' and (:'quoted'::jsonb->'quote'->>'writer')='deepseek'
 and (:'quoted'::jsonb->'quote'->>'consent_version')='podcast-private-v2','a device source quotes like any paper');
select test.reject(format('select public.v1_podcast_quote(%L,%L,%L,%L,%L::jsonb)',:'M','66000000-0000-0000-00b0-000000000002','podcast-5min-v1','deepseek',
 jsonb_build_object('source','arxiv','source_id','2610.16334','revision',1,'manifest_sha256',repeat('b',64),'text_sha256',repeat('c',64))::text),'source_unavailable');
select test.reject(format('select public.v1_podcast_quote(%L,%L,%L,%L)',:'M','66000000-0000-0000-00b0-000000000003','podcast-5min-v1','deepseek'),'source_unavailable');
select public.v1_podcast_start((:'quoted'::jsonb->'quote'->>'id')::uuid,:'Q1','podcast-private-v2') as started \gset
select test.assert((:'started'::jsonb->'job'->>'state')='queued' and (:'started'::jsonb->'job'->>'profile')='podcast-5min-v1','the start queues a private job');
select public.v1_podcast_paper(:'M') as lookup \gset
select test.assert((:'lookup'::jsonb->'job'->>'request_id')=:'Q1' and (:'lookup'::jsonb->'episodes')='[]'::jsonb and (:'lookup'::jsonb->'capabilities') is not null,
 'the paper lookup finds the running job by membership id');
select test.assert((public.v1_podcast_quote(:'M','66000000-0000-0000-00b0-000000000004','podcast-5min-v1','deepseek',jsonb_build_object('source','arxiv','source_id','2610.16334',
 'revision',1,'manifest_sha256',repeat('b',64),'text_sha256',:'digest'))->'join'->>'request_id')=:'Q1','the same text and length join the running job');
reset role;
select test.assert((select count(*)=1 from app_private.podcast_device_sources d where d.owner_id=:'A' and d.membership_id=:'M' and d.text_sha256=decode(:'digest','hex')
 and d.title='Toward Study' and d.authors='["Gayoung Kim"]'::jsonb),'one device source row with the paper''s title and authors');
select test.assert((select count(*)=0 from app_private.podcast_sources s join app_private.podcast_episode_keys k on k.id=s.episode_id where k.owner_id=:'A'),'no Mathpix source row');

-- The claim hands the worker the device text with the shape it already reads; the paper is named by its membership id.
select public.worker_podcast_claim('66000000-0000-4000-8000-0000000000c1',true) as claim \gset
select test.assert((:'claim'::jsonb->>'claimed')='true' and (:'claim'::jsonb->'source'->>'bucket')='private-content'
 and (:'claim'::jsonb->'source'->>'path')='podcast-sources/'||:'A'||'/'||:'digest'||'.txt' and (:'claim'::jsonb->'source'->>'sha256')=:'digest'
 and (:'claim'::jsonb->'source'->>'bytes')::int=31 and (:'claim'::jsonb->'source'->>'normalization_version')='gradstep-paper-context-v2'
 and (:'claim'::jsonb->'source'->>'document_id')=:'M' and (:'claim'::jsonb->'metadata'->>'title')='Toward Study'
 and (:'claim'::jsonb->'metadata'->'authors')='["Gayoung Kim"]'::jsonb,'the claim names the device text and the paper');
rollback;
