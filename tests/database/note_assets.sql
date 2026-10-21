-- Notes images (migration 095, docs/architecture/NOTES_AND_SNIPPETS.md "Implementation contract"): idempotent
-- reservation and digest conflicts, quotas with pending objects counted, two-account isolation, monthly download
-- metering, privileges, the admin Spending summary and account deletion. Synthetic local SQL; no Storage.
-- The blob is the encryption vector of tests/fixtures/notes/notes-v1.json (36 stored bytes).
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

\set A '95000000-0000-0000-0000-00000000000a'
\set B '95000000-0000-0000-0000-00000000000b'
\set O '95000000-0000-0000-0000-00000000000f'
\set X '0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a'
\set Y '95000000-0000-4000-8000-0000000000b2'
\set XSHA '86774a89efd8346c392d61276a99a2b41e983260064a9bce3aa777edf437ef39'
insert into auth.users(id,email) values(:'A','notes-a@gradstep.test.org'),(:'B','notes-b@gradstep.test.org'),(:'O','notes-owner@gradstep.test.org');
insert into app_private.app_roles(account_id,role) values(:'O','owner');

-- Privileges: readers reach none of this; the service role only through the functions.
select test.assert(not has_function_privilege(r,f,'execute'),r||' cannot call '||f) from unnest(array['anon','authenticated']) r,
 unnest(array['public.worker_note_asset_reserve(uuid,uuid,bytea,bigint)','public.worker_note_asset_confirm(uuid,uuid,bytea,bigint)',
  'public.worker_note_asset_download(uuid,uuid)','public.worker_delete_account_begin(uuid)','public.worker_delete_account_finish(uuid)',
  'app_private.note_transfer_charge(uuid,text,bigint)','app_private.note_asset_usage(uuid)']) f;
select test.assert(has_function_privilege('service_role',f,'execute'),'service role calls '||f) from
 unnest(array['public.worker_note_asset_reserve(uuid,uuid,bytea,bigint)','public.worker_note_asset_confirm(uuid,uuid,bytea,bigint)',
  'public.worker_note_asset_download(uuid,uuid)']) f;
select test.assert(not has_function_privilege('service_role','app_private.note_asset_usage(uuid)','execute'),'usage is read through the owner''s admin call only');
select test.assert(not has_table_privilege(r,t,p),r||' has no '||p||' on '||t) from unnest(array['anon','authenticated','service_role']) r,
 unnest(array['app_private.note_assets','app_private.note_asset_policy','app_private.note_asset_totals','app_private.note_asset_transfer_months']) t,
 unnest(array['select','insert','update','delete']) p;
select test.assert((select bool_and(relrowsecurity) from pg_class where oid in ('app_private.note_assets'::regclass,
 'app_private.note_asset_policy'::regclass,'app_private.note_asset_totals'::regclass,'app_private.note_asset_transfer_months'::regclass)),'deny-by-default RLS');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject($$select public.worker_note_asset_reserve('95000000-0000-0000-0000-00000000000a','0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a',decode(repeat('00',32),'hex'),36)$$,'permission denied');
select test.reject($$select public.worker_note_asset_download('95000000-0000-0000-0000-00000000000a','0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a')$$,'permission denied');
select test.reject($$select * from app_private.note_assets$$,'permission denied');
reset role;
select test.assert((select (max_blob_bytes,account_bytes,account_objects,environment_bytes,account_download_bytes_month,environment_download_bytes_month)
 =(2097180,134217728,4000,536870912,536870912,4294967296::bigint) from app_private.note_asset_policy),'the contract''s quotas, in one row');

-- 1. A first PUT reserves a pending object at {account}/{blob}; repeating the same bytes is the same object.
set role service_role;
select test.assert(public.worker_note_asset_reserve(:'A',:'X',decode(:'XSHA','hex'),36)
 =jsonb_build_object('state','pending','bytes',36,'path',:'A'||'/'||:'X','retry',false),'first PUT reserves a pending object');
select test.assert(public.worker_note_asset_reserve(:'A',:'X',decode(:'XSHA','hex'),36)
 =jsonb_build_object('state','pending','bytes',36,'path',:'A'||'/'||:'X','retry',true),'a repeated PUT of a pending object writes it again (upsert)');
select test.reject($$select public.worker_note_asset_reserve('95000000-0000-0000-0000-00000000000a','0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a',decode(repeat('00',32),'hex'),36)$$,'note_asset_conflict');
select test.reject($$select public.worker_note_asset_reserve('95000000-0000-0000-0000-00000000000a','0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a',decode('86774a89efd8346c392d61276a99a2b41e983260064a9bce3aa777edf437ef39','hex'),37)$$,'note_asset_conflict');
select test.reject($$select public.worker_note_asset_confirm('95000000-0000-0000-0000-00000000000a','0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a',decode(repeat('00',32),'hex'),36)$$,'note_asset_conflict');
-- A pending object is not downloadable.
select test.reject($$select public.worker_note_asset_download('95000000-0000-0000-0000-00000000000a','0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a')$$,'note_asset_unavailable');
select test.assert(public.worker_note_asset_confirm(:'A',:'X',decode(:'XSHA','hex'),36)=jsonb_build_object('state','ready','bytes',36),'confirmed after the read-back');
select test.assert(public.worker_note_asset_confirm(:'A',:'X',decode(:'XSHA','hex'),36)=jsonb_build_object('state','ready','bytes',36),'confirmation is idempotent');
select test.assert(public.worker_note_asset_reserve(:'A',:'X',decode(:'XSHA','hex'),36)
 =jsonb_build_object('state','ready','bytes',36,'path',:'A'||'/'||:'X','retry',false),'a PUT of a ready object writes nothing');
reset role;
select test.assert((select (state,attempts) from app_private.note_assets where account_id=:'A' and blob_id=:'X')=('ready'::text,2),'one row, two write attempts');
select test.assert((select (bytes,requests) from app_private.note_asset_transfer_months where scope_id=:'A' and kind='verify')=(72::bigint,2::bigint),
 'each write attempt charges one read-back; the ready replay charges none');
select test.assert((select (bytes,objects) from app_private.note_asset_totals)=(36::bigint,1::bigint),'environment totals count the object once');

-- Bounds: 28 bytes (empty plaintext) up to 2 MiB + 28.
set role service_role;
select test.reject($$select public.worker_note_asset_reserve('95000000-0000-0000-0000-00000000000a',gen_random_uuid(),decode(repeat('11',32),'hex'),27)$$,'invalid_note_asset');
select test.reject($$select public.worker_note_asset_reserve('95000000-0000-0000-0000-00000000000a',gen_random_uuid(),decode(repeat('11',32),'hex'),2097181)$$,'invalid_note_asset');
select test.reject($$select public.worker_note_asset_reserve('95000000-0000-0000-0000-00000000000a',gen_random_uuid(),decode(repeat('11',31),'hex'),36)$$,'invalid_note_asset');
select test.assert(public.worker_note_asset_reserve(:'A',gen_random_uuid(),decode(repeat('11',32),'hex'),2097180)->>'state'='pending','the largest stored blob fits');

-- 2. Downloads: the owner's ready object, charged before any read.
select test.assert(public.worker_note_asset_download(:'A',:'X')=jsonb_build_object('path',:'A'||'/'||:'X','bytes',36,'sha256',:'XSHA'),'download admission names the object and its digest');
reset role;
select test.assert((select (bytes,requests) from app_private.note_asset_transfer_months where scope_id=:'A' and kind='download')=(36::bigint,1::bigint),'account charged');
select test.assert((select (bytes,requests) from app_private.note_asset_transfer_months where scope_id='environment' and kind='download')=(36::bigint,1::bigint),'environment charged');

-- 3. Two accounts: B cannot read, confirm or collide with A's object; the same blob ID is B's own object.
set role service_role;
select test.reject($$select public.worker_note_asset_download('95000000-0000-0000-0000-00000000000b','0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a')$$,'note_asset_unavailable');
select test.reject($$select public.worker_note_asset_confirm('95000000-0000-0000-0000-00000000000b','0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a',decode('86774a89efd8346c392d61276a99a2b41e983260064a9bce3aa777edf437ef39','hex'),36)$$,'note_asset_unavailable');
select test.assert(public.worker_note_asset_reserve(:'B',:'X',decode(repeat('22',32),'hex'),40)
 =jsonb_build_object('state','pending','bytes',40,'path',:'B'||'/'||:'X','retry',false),'B''s object of the same ID lives in B''s folder');
select test.reject($$select public.worker_note_asset_download('95000000-0000-0000-0000-00000000000b','0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a')$$,'note_asset_unavailable');
reset role;
select test.assert((select (sha256,state) from app_private.note_assets where account_id=:'A' and blob_id=:'X')=(decode(:'XSHA','hex'),'ready'::text),'A''s object is untouched');

-- 4. Quotas count pending objects; a refusal changes nothing.
update app_private.note_asset_policy set account_objects=(select count(*)+1 from app_private.note_assets where account_id=:'A');
set role service_role;
select test.assert(public.worker_note_asset_reserve(:'A',:'Y',decode(repeat('33',32),'hex'),100)->>'state'='pending','the last object slot (pending objects count)');
select test.reject($$select public.worker_note_asset_reserve('95000000-0000-0000-0000-00000000000a',gen_random_uuid(),decode(repeat('44',32),'hex'),100)$$,'note_asset_quota');
select test.assert(public.worker_note_asset_reserve(:'A',:'Y',decode(repeat('33',32),'hex'),100)->>'retry'='true','a full account can still repeat its pending PUT');
reset role;
update app_private.note_asset_policy set account_objects=4000,account_bytes=(select sum(byte_count)+50 from app_private.note_assets where account_id=:'A');
set role service_role;
select test.reject($$select public.worker_note_asset_reserve('95000000-0000-0000-0000-00000000000a',gen_random_uuid(),decode(repeat('44',32),'hex'),51)$$,'note_asset_quota');
select test.assert(public.worker_note_asset_reserve(:'A',gen_random_uuid(),decode(repeat('44',32),'hex'),50)->>'state'='pending','exactly the account''s bytes fit');
reset role;
update app_private.note_asset_policy set account_bytes=134217728,environment_bytes=(select bytes+60 from app_private.note_asset_totals);
set role service_role;
select test.reject($$select public.worker_note_asset_reserve('95000000-0000-0000-0000-00000000000b',gen_random_uuid(),decode(repeat('55',32),'hex'),61)$$,'note_asset_quota');
select test.assert(public.worker_note_asset_reserve(:'B',gen_random_uuid(),decode(repeat('55',32),'hex'),60)->>'state'='pending','exactly the environment''s bytes fit');
select test.reject($$select public.worker_note_asset_reserve('95000000-0000-0000-0000-00000000000b',gen_random_uuid(),decode(repeat('55',32),'hex'),28)$$,'note_asset_quota');
reset role;
update app_private.note_asset_policy set environment_bytes=536870912;
select test.assert((select (t.bytes,t.objects)=(s.b,s.n) from app_private.note_asset_totals t,
 (select sum(byte_count)::bigint b,count(*) n from app_private.note_assets) s),'totals equal the inventory after refusals');

-- 5. Monthly limits: a download or read-back over the allowance is refused and charges nothing.
update app_private.note_asset_policy set account_download_bytes_month=72;
set role service_role;
select public.worker_note_asset_download(:'A',:'X');
select test.reject($$select public.worker_note_asset_download('95000000-0000-0000-0000-00000000000a','0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a')$$,'note_transfer_limit');
reset role;
select test.assert((select (bytes,requests) from app_private.note_asset_transfer_months where scope_id=:'A' and kind='download')=(72::bigint,2::bigint),'the refused download charged nothing');
update app_private.note_asset_policy set account_download_bytes_month=536870912,environment_download_bytes_month=72;
set role service_role;
select test.reject($$select public.worker_note_asset_download('95000000-0000-0000-0000-00000000000a','0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a')$$,'note_transfer_limit');
reset role;
update app_private.note_asset_policy set environment_download_bytes_month=4294967296,
 account_verify_bytes_month=(select bytes from app_private.note_asset_transfer_months where scope_id=:'B' and kind='verify');
set role service_role;
select test.reject($$select public.worker_note_asset_reserve('95000000-0000-0000-0000-00000000000b',gen_random_uuid(),decode(repeat('66',32),'hex'),30)$$,'note_transfer_limit');
reset role;
select test.assert(not exists(select 1 from app_private.note_assets where sha256=decode(repeat('66',32),'hex')),'no object reserved without its read-back');
update app_private.note_asset_policy set account_verify_bytes_month=268435456;

-- 6. Suspended or closed accounts cannot write or read.
update app_private.accounts set spending_suspended=true where id=:'B';
set role service_role;
select test.reject($$select public.worker_note_asset_reserve('95000000-0000-0000-0000-00000000000b',gen_random_uuid(),decode(repeat('77',32),'hex'),30)$$,'account_unavailable');
reset role;
update app_private.accounts set spending_suspended=false where id=:'B';

-- 7. The admin Spending summary (owner with MFA) shows storage, this month's transfer and the limits.
select bytes as env_bytes,objects as env_objects from app_private.note_asset_totals \gset
select count(*) as b_objects from app_private.note_assets where account_id=:'B' \gset
set role authenticated;
select set_config('request.jwt.claim.sub',:'O',false);
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject($$select public.v1_admin_spending(30,null)$$,'owner_mfa_required');
select set_config('request.jwt.claim.aal','aal2',false);
select test.assert((public.v1_admin_spending(30,null)->'note_assets'->'stored'->>'bytes')::bigint=:env_bytes,'stored bytes');
select test.assert((public.v1_admin_spending(30,null)->'note_assets'->'stored'->>'objects')::bigint=:env_objects,'stored objects');
select test.assert((public.v1_admin_spending(30,null)->'note_assets'->'month'->>'download_bytes')::bigint=72,'this month''s downloads');
select test.assert((public.v1_admin_spending(30,null)->'note_assets'->'limits'->>'environment_bytes')::bigint=536870912,'limits are shown');
select test.assert(public.v1_admin_spending(30,null)->'note_assets'->'account'='null'::jsonb,'no account section without a filter');
select test.assert((public.v1_admin_spending(30,:'B')->'note_assets'->'account'->>'objects')::bigint=:b_objects,'the filtered account''s objects');
select test.assert(public.v1_admin_spending(30,null) ? 'attempts','the earlier summary is unchanged');
select set_config('request.jwt.claim.sub',:'B',false);
select test.reject($$select public.v1_admin_spending(30,null)$$,'owner_mfa_required');
reset role;

-- 8. Account deletion. A write that may still land blocks removal; then every object and the folder are planned.
select count(*) as a_objects,sum(byte_count) as a_bytes from app_private.note_assets where account_id=:'A' \gset
set role service_role;
select test.assert(public.worker_delete_account_begin(:'A')->>'blocked'='asset_write_uncertain','a recent pending write blocks removal');
select test.reject($$select public.worker_delete_account_finish('95000000-0000-0000-0000-00000000000a')$$,'asset_write_uncertain');
-- The account is closed: nothing new can be written, confirmed or read.
select test.reject($$select public.worker_note_asset_reserve('95000000-0000-0000-0000-00000000000a',gen_random_uuid(),decode(repeat('88',32),'hex'),30)$$,'account_unavailable');
select test.reject($$select public.worker_note_asset_confirm('95000000-0000-0000-0000-00000000000a','95000000-0000-4000-8000-0000000000b2',decode(repeat('33',32),'hex'),100)$$,'account_unavailable');
select test.reject($$select public.worker_note_asset_download('95000000-0000-0000-0000-00000000000a','0f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a')$$,'account_unavailable');
reset role;
select test.assert(not exists(select 1 from app_private.note_asset_transfer_months where scope_id=:'A'),'personal monthly counters are erased');
select test.assert(exists(select 1 from app_private.note_asset_transfer_months where scope_id='environment'),'environment totals stay');
update app_private.note_assets set attempt_at=clock_timestamp()-interval '11 minutes' where account_id=:'A';
set role service_role;
create temp table plan as select public.worker_delete_account_begin(:'A') p;
select test.assert(not ((select p from plan) ? 'blocked'),'after the grace nothing blocks');
select test.assert((select count(*) from jsonb_array_elements((select p->'objects' from plan)) o where o->>'bucket'='note-assets')=:a_objects,'every inventoried object is planned');
select test.assert((select p->'objects' from plan) @> jsonb_build_array(jsonb_build_object('bucket','note-assets','path',:'A'||'/'||:'X')),'including the ready one');
select test.assert(not exists(select 1 from jsonb_array_elements((select p->'objects' from plan)) o where o->>'path' like :'B'||'/%'),'never another account''s object');
select test.assert((select p->'prefixes' from plan) @> jsonb_build_array(jsonb_build_object('bucket','note-assets','prefix',:'A'||'/')),'the account''s folder is swept');
select test.assert(not exists(select 1 from jsonb_array_elements((select p->'prefixes' from plan)) e where e->>'bucket'='note-assets' and e->>'prefix'<>:'A'||'/'),'only that folder');
select test.assert((select p->'prefixes' from plan) @> jsonb_build_array(jsonb_build_object('bucket','podcast-assets','prefix','private/'||:'A'||'/')),'earlier folders stay in the plan');
select test.assert(:'A'=any(public.worker_account_deletions_pending(20)),'the sweep finds it');
select test.assert((public.worker_account_deletion_status(:'A')->>'note_assets')::bigint=:a_objects,'status counts the rows left');
select test.assert(public.worker_delete_account_finish(:'A')>=:a_objects,'finish');
reset role;
select test.assert(not exists(select 1 from app_private.note_assets where account_id=:'A'),'every inventory row is gone');
select test.assert((select (bytes,objects) from app_private.note_asset_totals)=((:env_bytes-:a_bytes)::bigint,(:env_objects-:a_objects)::bigint),'capacity released exactly');
select test.assert((select count(*) from app_private.note_assets where account_id=:'B')=:b_objects,'the other account keeps its objects');
delete from auth.users where id=:'A';
set role service_role;
select test.assert((public.worker_account_deletion_status(:'A')->>'note_assets')::bigint=0,'status: none left');
select test.assert((public.worker_account_deletion_status(:'A')->>'personal_rows')::bigint=0,'no personal rows');
select test.assert(not (:'A'=any(public.worker_account_deletions_pending(20))),'nothing left to sweep');
reset role;
rollback;
