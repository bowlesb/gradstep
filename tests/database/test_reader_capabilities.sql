-- Only protocol shape and account-scoped admission advice. No Storage/provider calls.
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
\set A '39100000-0000-0000-0000-000000000071'
\set B '39100000-0000-0000-0000-000000000072'
insert into auth.users values(:'A'),(:'B');
select upload_dataset_epoch as epoch from app_private.library_v4_config \gset
set role anon;
select test.reject('select public.v1_reader_capabilities()','permission denied');
reset role;
set role service_role;
select test.reject('select public.v1_reader_capabilities()','permission denied');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','',false);
select test.reject('select public.v1_reader_capabilities()','authentication_required');
select set_config('request.jwt.claim.sub',:'A',false);
select public.v1_reader_capabilities() as caps \gset
select test.assert(:'caps'::jsonb=jsonb_build_object('format',1,'account_id',:'A',
 'library',jsonb_build_object('endpoint_family','full-v5','wire_format',2,'source_level',4,'dataset_epoch',:'epoch'),
 'descriptors',jsonb_build_object('format',1,'maximum_batch',24),
 'uploads',jsonb_build_object('protocol','upload-chunks-v1','enabled',false,'chunk_bytes',4194304,
  'maximum_bytes',67108864,'maximum_parts',16,'part_attempts',3)),
 'fixed capability shape has no credentials, paths or environment allowances');
select test.assert(public.v5_library_page()->>'dataset_epoch'=:'epoch','paused ingress preserves upload-capable reads');
reset role;
select test.assert(exists(select 1 from app_private.library_transfer_months where scope_id=:'A' and reserved_bytes>0),
 'capability responses consume the existing account transfer allowance');
update app_private.pdf_upload_policy set enabled=true;
select test.assert((public.v1_reader_capabilities()->'uploads'->>'enabled')::boolean=false,'missing inventory keeps ingress advice disabled');
update app_private.paper_asset_policy set enforced=true,inventory_scope=2,inventory_verified_at=clock_timestamp(),inventory_discrepancies=0;
select test.assert((public.v1_reader_capabilities()->'uploads'->>'enabled')::boolean,'policy plus inventory advertises supported ingress');
-- Advice is not capacity: an upload still performs current server admission.
update app_private.accounts set spending_suspended=true where id=:'A';
select test.assert(not (public.v1_reader_capabilities()->'uploads'->>'enabled')::boolean
 and public.v5_library_page()->>'dataset_epoch'=:'epoch','suspension disables new ingress, not existing library reads');
select set_config('request.jwt.claim.sub',:'B',false);
select test.assert(public.v1_reader_capabilities()->>'account_id'=:'B'
 and (public.v1_reader_capabilities()->'uploads'->>'enabled')::boolean,'capabilities bind the current account');
select set_config('request.jwt.claim.sub',:'A',false);
update app_private.accounts set closed_at=clock_timestamp() where id=:'A';
select sum(reserved_bytes) as before_closed from app_private.library_transfer_months \gset
select test.reject('select public.v1_reader_capabilities()','authentication_required');
select test.assert((select sum(reserved_bytes) from app_private.library_transfer_months)=:'before_closed'::bigint,
 'closed account is fenced before transfer accounting');
rollback;
