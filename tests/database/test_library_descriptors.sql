-- Opaque synthetic ciphertext. CryptoKit/WebCrypto exercise the real shared vectors separately.
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
create function test.descriptor(id uuid,rev integer,mutation uuid,author uuid,epoch integer,n integer default 28) returns jsonb language sql as $$
 select jsonb_build_object('descriptor_id',id,'revision',rev,'mutation_id',mutation,'device_id',author,'epoch',epoch,'format',1,
  'ciphertext',replace(encode(decode(repeat('11',n),'hex'),'base64'),E'\n',''),'sha256',encode(sha256(decode(repeat('11',n),'hex')),'hex'))
$$;
\set A '39000000-0000-0000-0000-000000000041'
\set B '39000000-0000-0000-0000-000000000042'
\set first_device '39000000-0000-0000-0000-000000000051'
\set surviving_device '39000000-0000-0000-0000-000000000052'
\set descriptor '39000000-0000-0000-0000-000000000061'
\set mutation '39000000-0000-0000-0000-000000000062'
\set import '39000000-0000-0000-0000-000000000063'
insert into auth.users values(:'A'),(:'B');
select set_config('request.jwt.claim.sub',:'A',false);
set role authenticated;
select public.v1_bootstrap_keys(:'first_device',decode(repeat('21',32),'hex'),decode(repeat('22',60),'hex'),decode(repeat('23',32),'hex'),decode(repeat('24',60),'hex'),decode(repeat('25',32),'hex'));
select public.v2_begin_import(:'import','2410.03941',0);
select test.descriptor(:'descriptor',1,:'mutation',:'first_device',1) as envelope \gset
select public.v1_put_library_descriptor('2410.03941',0,:'first_device',decode(repeat('23',32),'hex'),:'envelope') as result \gset
select test.assert(:'result'::jsonb->'result'->>'status'='applied' and :'result'::jsonb->'result'->'reference'->>'revision'='1','initial opaque descriptor accepted');
select test.assert((public.v1_put_library_descriptor('2410.03941',0,:'first_device',decode(repeat('23',32),'hex'),:'envelope')->>'replayed')::boolean,'exact mutation replay');
select test.reject(format('select public.v1_put_library_descriptor(''2410.03941'',0,%L,decode(repeat(''23'',32),''hex''),%L)',:'first_device',jsonb_set(:'envelope'::jsonb,'{ciphertext}','"bad"')),'invalid_library_descriptor');
select test.reject(format('select public.v1_put_library_descriptor(''2410.03941'',0,%L,decode(repeat(''23'',32),''hex''),%L)',:'first_device',:'envelope'::jsonb||'{"title":"private"}'),'invalid_library_descriptor');
select test.reject(format('select public.v1_put_library_descriptor(''2410.03999'',0,%L,decode(repeat(''23'',32),''hex''),%L)',:'first_device',test.descriptor(gen_random_uuid(),1,gen_random_uuid(),:'first_device',1)),'library_descriptor_source_unavailable');
select test.assert(public.v1_library_descriptors(jsonb_build_array(jsonb_build_object('descriptor_id',:'descriptor','revision',1)))->'records'->0->'envelope'=:'envelope'::jsonb,'canonical base64 envelope round trip');
select test.reject('select * from app_private.library_descriptors','permission denied');
reset role;
select test.assert((select descriptor_bytes=28 and descriptor_count=1 and ciphertext_bytes=0 and event_count=0 from app_private.sync_account_storage where account_id=:'A'),'descriptor capacity is separate from event count');
select test.assert(public.v1_sync_usage()->>'descriptor_bytes'='28' and public.v1_sync_usage()->>'descriptor_count'='1'
 and public.v1_sync_usage()->>'accounted_storage_bytes'='28' and public.v1_sync_usage()->>'ciphertext_bytes'='0','usage displays the actual shared allowance with separate components');
select test.assert((select count(*)=2 from app_private.library_commands where account_id=:'A'),'descriptor shares existing immutable receipt capacities');
select test.assert((select request_sha256 is not null and result->>'kind'='descriptor' from app_private.library_commands where account_id=:'A' and id=:'mutation'),'receipt records digest/result, not ciphertext');
-- A second approved device survives a real rotation. Historical envelope authorship is unchanged.
insert into app_private.devices(account_id,id,public_key,challenge) values(:'A',:'surviving_device',decode(repeat('26',32),'hex'),decode(repeat('27',32),'hex'));
set role authenticated;
select public.v1_rotate_keys(gen_random_uuid(),1,decode(repeat('23',32),'hex'),decode(repeat('33',32),'hex'),decode(repeat('34',60),'hex'),array[:'first_device'::uuid],
 jsonb_build_array(jsonb_build_object('device_id',:'surviving_device','envelope','\x'||repeat('35',60))));
select test.assert((public.v1_put_library_descriptor('2410.03941',0,:'surviving_device',decode(repeat('33',32),'hex'),:'envelope')->>'replayed')::boolean,'surviving caller with current authority resolves old author acknowledgment');
select test.reject(format('select public.v1_put_library_descriptor(''2410.03941'',0,%L,decode(repeat(''23'',32),''hex''),%L)',:'surviving_device',:'envelope'),'key_authority_required');
select test.reject(format('select public.v1_put_library_descriptor(''2410.03941'',0,%L,decode(repeat(''33'',32),''hex''),%L)',:'first_device',:'envelope'),'key_authority_required');
select test.reject(format('select public.v1_put_library_descriptor(''2410.03941'',1,%L,decode(repeat(''33'',32),''hex''),%L)',:'surviving_device',test.descriptor(:'descriptor',2,gen_random_uuid(),:'first_device',1)),'stale_key_epoch');
select test.descriptor(:'descriptor',2,gen_random_uuid(),:'surviving_device',2) as newer \gset
select public.v1_put_library_descriptor('2410.03941',1,:'surviving_device',decode(repeat('33',32),'hex'),:'newer');
select test.assert(public.v1_library_descriptors(jsonb_build_array(jsonb_build_object('descriptor_id',:'descriptor','revision',1)))->'records'->0->>'status'='stale','old reference never silently hydrates newer ciphertext');
select test.assert(public.v1_put_library_descriptor('2410.03941',0,:'surviving_device',decode(repeat('33',32),'hex'),test.descriptor(:'descriptor',1,gen_random_uuid(),:'surviving_device',2))->'result'->>'status'='revision_conflict','stale CAS preserves newer revision');
select set_config('request.jwt.claim.sub',:'B',false);
select test.reject(format('select public.v1_library_descriptors(%L)',jsonb_build_array(jsonb_build_object('descriptor_id',:'descriptor','revision',2))),'library_descriptor_unavailable');
reset role;
select test.assert((select count(*)=1 and max(revision)=2 from app_private.library_descriptors where account_id=:'A'),'current envelope only; superseded ciphertext is not retained');

-- Old encrypted-history writes and new descriptors share the same byte ceiling.
update app_private.sync_storage_policy set account_bytes=100;
select set_config('request.jwt.claim.sub',:'A',false);
set role authenticated;
select test.reject(format('select public.v1_append_event(%L,gen_random_uuid(),2,1,decode(repeat(''11'',80),''hex''),decode(repeat(''33'',32),''hex''))',:'surviving_device'),'sync_account_storage_limit');
select public.v1_append_event(:'surviving_device',gen_random_uuid(),2,1,decode(repeat('11',40),'hex'),decode(repeat('33',32),'hex'));
select test.reject(format('select public.v1_put_library_descriptor(''2410.03941'',2,%L,decode(repeat(''33'',32),''hex''),%L)',:'surviving_device',test.descriptor(:'descriptor',3,gen_random_uuid(),:'surviving_device',2,64)),'sync_account_storage_limit');
select public.v2_cancel_import(gen_random_uuid(),:'import',1);
reset role;
select query_revision as query_before,last_seq as seq_before from app_private.library_sync_state where account_id=:'A' \gset
set role authenticated;
select public.v1_put_library_descriptor('2410.03941',2,:'surviving_device',decode(repeat('33',32),'hex'),test.descriptor(:'descriptor',3,gen_random_uuid(),:'surviving_device',2));
reset role;
select test.assert((select query_revision>:'query_before' and last_seq>:'seq_before' from app_private.library_sync_state where account_id=:'A'),'hidden entry edits still advance sync and invalidate query generation');
select test.assert((select descriptor_count=1 and descriptor_bytes=28 and ciphertext_bytes=40 and event_count=1 from app_private.sync_account_storage where account_id=:'A'),'both byte counters remain accurate after rejected update');
select test.assert(public.v1_sync_usage()->>'accounted_storage_bytes'='68','reported allowance includes encrypted history and descriptors');
select public.worker_delete_account_begin(:'A');
select test.assert(not exists(select 1 from app_private.library_descriptors where account_id=:'A') and not exists(select 1 from app_private.library_commands where account_id=:'A'),'deletion erases descriptor and command references');
select test.assert((select descriptor_count=0 and descriptor_bytes=0 from app_private.sync_environment_storage),'deletion releases exactly descriptor bytes without fake events');
rollback;
