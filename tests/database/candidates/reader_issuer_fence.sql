-- Local-only fixture: no Storage access, remote account or paid provider.
create schema test;
grant usage on schema test to anon,authenticated,service_role;
create function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create function test.reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin
 begin execute statement; exception when others then
  if position(expected in sqlerrm)=0 then raise exception 'Unexpected rejection: % (wanted %)',sqlerrm,expected; end if;
  rejected:=true;
 end;
 if not rejected then raise exception 'Expected rejection: %',expected; end if;
end $$;

insert into auth.users(id) values('45000000-0000-0000-0000-000000000001');
insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
 values('45000000-0000-0000-0000-000000000002',decode(repeat('a',64),'hex'),'shared_catalog','{"fixture":true}',1000,1);
insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values
 ('45000000-0000-0000-0000-000000000003','paper-assets','reader/'||repeat('b',64)||'/manifest.json',
  '45000000-0000-0000-0000-000000000002','verified',decode(repeat('b',64),'hex'),100,'application/json',now()),
 ('45000000-0000-0000-0000-000000000004','paper-assets','reader/'||repeat('b',64)||'/index.html',
  '45000000-0000-0000-0000-000000000002','verified',decode(repeat('c',64),'hex'),200,'text/html',now());
insert into app_private.paper_asset_manifest_members values
 ('45000000-0000-0000-0000-000000000003','45000000-0000-0000-0000-000000000004','index.html');
insert into app_private.ocr_runs(id,document_id,provider,options_sha256)
 values('45000000-0000-0000-0000-000000000005','45000000-0000-0000-0000-000000000002','fixture',decode(repeat('d',64),'hex'));
insert into app_private.render_artifacts(id,ocr_run_id,renderer_version,manifest_object_id)
 values('45000000-0000-0000-0000-000000000006','45000000-0000-0000-0000-000000000005','timestep-mathpix-mathml-v1',
  '45000000-0000-0000-0000-000000000003');
select app_private.mark_paper_availability('45000000-0000-0000-0000-000000000003','available');
insert into app_private.library_items(id,account_id,document_id,artifact_id)
 values('45000000-0000-0000-0000-000000000007','45000000-0000-0000-0000-000000000001',
  '45000000-0000-0000-0000-000000000002','45000000-0000-0000-0000-000000000006');
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true;
update app_private.reader_delivery_policy set mode='dual';

set role service_role;
select test.assert(current_user='service_role','actual legacy issuer role');
\if :already_applied
select test.reject($q$select public.worker_reader_descriptor('45000000-0000-0000-0000-000000000001',
 '45000000-0000-0000-0000-000000000007')$q$,'permission denied');
\else
select test.assert(public.worker_reader_descriptor('45000000-0000-0000-0000-000000000001',
 '45000000-0000-0000-0000-000000000007')->>'bucket'='paper-assets','baseline legacy bypass exists');
\endif
reset role;

-- Exclude only the intentional ACL difference. Preserve physical identities,
-- function bodies, inventory enforcement, delivery mode, counters and grants.
create function test.unchanged_state() returns text language sql as $$
 select md5(jsonb_build_object(
  'functions',(select jsonb_agg(pg_get_functiondef(oid) order by oid) from pg_proc where oid in
   ('public.worker_reader_descriptor(uuid,uuid)'::regprocedure,'public.worker_reader_delivery_create(uuid,uuid,bytea,text)'::regprocedure)),
  'objects',(select jsonb_agg(to_jsonb(o) order by id) from app_private.stored_objects o),
  'members',(select jsonb_agg(to_jsonb(m) order by manifest_object_id,object_id) from app_private.paper_asset_manifest_members m),
  'assets',(select to_jsonb(p) from app_private.paper_asset_policy p where singleton),
  'delivery',(select to_jsonb(p) from app_private.reader_delivery_policy p where singleton),
  'months',(select jsonb_agg(to_jsonb(m) order by period,scope_id,kind) from app_private.reader_transfer_months m),
  'grants',(select jsonb_agg(to_jsonb(g) order by id) from app_private.reader_delivery_grants g)
 )::text)
$$;
select test.unchanged_state() as state_before \gset
\if :candidate
 \i :fence_migration
\endif
select test.assert(test.unchanged_state()=:'state_before','fence only changes legacy execute ACL');

set role service_role;
select test.reject($q$select public.worker_reader_descriptor('45000000-0000-0000-0000-000000000001',
 '45000000-0000-0000-0000-000000000007')$q$,'permission denied');
select test.assert(public.worker_reader_delivery_create('45000000-0000-0000-0000-000000000001',
 '45000000-0000-0000-0000-000000000007',decode(repeat('1',64),'hex'),'bounded-v1')->>'transport'='bounded-v1',
 'current SECURITY DEFINER route still calls the fenced helper');
select test.assert(public.worker_reader_delivery_create('45000000-0000-0000-0000-000000000001',
 '45000000-0000-0000-0000-000000000007',decode(repeat('2',64),'hex'),'legacy')->>'transport'='legacy',
 'dual mode remains an explicit replay exposure');
reset role;

set role anon;
select test.reject($q$select public.worker_reader_descriptor(null,null)$q$,'permission denied');
select test.reject($q$select public.worker_reader_delivery_create(null,null,null,null)$q$,'permission denied');
reset role;
set role authenticated;
select test.reject($q$select public.worker_reader_descriptor(null,null)$q$,'permission denied');
select test.reject($q$select public.worker_reader_delivery_create(null,null,null,null)$q$,'permission denied');
reset role;

-- Strict policy is a SEPARATE explicit operator action, exercised only locally.
select public.worker_asset_enforcement(true,'bounded');
select legacy_descriptors as last_legacy_count from app_private.reader_delivery_policy \gset
set role service_role;
select test.reject($q$select public.worker_reader_delivery_create('45000000-0000-0000-0000-000000000001',
 '45000000-0000-0000-0000-000000000007',decode(repeat('3',64),'hex'),'legacy')$q$,'reader_upgrade_required');
select test.reject($q$select public.worker_reader_descriptor('45000000-0000-0000-0000-000000000001',
 '45000000-0000-0000-0000-000000000007')$q$,'permission denied');
select test.assert(public.worker_reader_delivery_create('45000000-0000-0000-0000-000000000001',
 '45000000-0000-0000-0000-000000000007',decode(repeat('4',64),'hex'),'bounded-v1')->>'transport'='bounded-v1',
 'strict mode admits current transport');
select test.assert(public.worker_reader_delivery_redeem('45000000-0000-0000-0000-000000000001',
 decode(repeat('4',64),'hex'),'45000000-0000-0000-0000-000000000004')->>'bytes'='200','authorized exact immutable member');
select test.reject($q$select public.worker_reader_delivery_redeem('45000000-0000-0000-0000-000000000001',
 decode(repeat('4',64),'hex'),'45000000-0000-0000-0000-000000000004')$q$,'reader_grant_consumed');
reset role;
select test.assert((select legacy_descriptors=:'last_legacy_count' from app_private.reader_delivery_policy),
 'strict requests never increment legacy issue count');

-- A policy rollback need not regrant the obsolete RPC. It REOPENS signed URLs
-- through the supported current issuer and starts an entirely new retirement.
select public.worker_asset_enforcement(true,'dual');
set role service_role;
select test.assert(public.worker_reader_delivery_create('45000000-0000-0000-0000-000000000001',
 '45000000-0000-0000-0000-000000000007',decode(repeat('5',64),'hex'),'legacy')->>'transport'='legacy',
 'policy rollback reopens current legacy issuance');
select test.reject($q$select public.worker_reader_descriptor(null,null)$q$,'permission denied');
reset role;
select test.assert((select enforced from app_private.paper_asset_policy),'rollback retains storage enforcement');

-- Full code rollback would require deliberate EXECUTE restoration, even while
-- mode=bounded; this reintroduces the BYPASS and invalidates the retirement proof.
select public.worker_asset_enforcement(true,'bounded');
begin;
grant execute on function public.worker_reader_descriptor(uuid,uuid) to service_role;
set local role service_role;
select test.assert(public.worker_reader_descriptor('45000000-0000-0000-0000-000000000001',
 '45000000-0000-0000-0000-000000000007')->>'bucket'='paper-assets','regrant bypasses strict policy');
rollback;
set role service_role;
select test.reject($q$select public.worker_reader_descriptor(null,null)$q$,'permission denied');
reset role;
