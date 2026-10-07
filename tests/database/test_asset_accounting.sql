-- Synthetic local SQL. Storage responses are represented explicitly by write
-- receipts; network-side ordering is covered by asset-delivery.test.ts.
begin;
create schema test;
grant usage on schema test to anon,authenticated,service_role;
create function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create function test.reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin begin execute statement; exception when others then
 if position(expected in sqlerrm)=0 then raise exception 'Unexpected rejection: % (wanted %)',sqlerrm,expected; end if; rejected:=true; end;
 if not rejected then raise exception 'Expected rejection: %',expected; end if; end $$;

insert into auth.users values('34000000-0000-0000-0000-000000000001'),('34000000-0000-0000-0000-000000000002'),('34000000-0000-0000-0000-000000000003');
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true where singleton;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits('34000000-0000-0000-0000-000000000001','adjustment','asset-test-a',1000,now()-interval '1 day',null,'Asset accounting fixture');
select public.worker_set_pipeline_enabled(true);
select set_config('request.jwt.claim.sub','34000000-0000-0000-0000-000000000001',false);
select public.v2_begin_import('34000000-0000-0000-0000-000000000011','2410.03401',0);
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'id') as paper,( :'entry'::jsonb->>'generation')::bigint as gen \gset
select public.worker_pipeline_metadata(:'paper',:'claim',:'gen',1,
 '{"title":"Asset fixture","authors":["Fixture Author"],"abstract":"Testing","published_at":"2024-10-01","categories":["cs.LG"]}',
 true,'https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2410.03401','source_revision',1,'source_url','https://arxiv.org/abs/2410.03401v1',
 'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('a',64),'observed_at','2026-10-07T05:00:00Z'));
select test.assert((public.worker_pipeline_admit_download(:'paper',:'claim',:'gen')->>'admitted')::boolean,'whole pipeline admitted');
select test.assert((select count(*)=3 and sum(bytes)=159907840 from app_private.paper_asset_holds where paper_id=:'paper'),'all three phase ceilings reserved atomically');

select gen_random_uuid() as upload \gset
select jsonb_build_array(jsonb_build_object('path','originals/'||repeat('a',64)||'.pdf','sha256',repeat('a',64),'bytes',1000,'media_type','application/pdf')) as objects \gset
select public.worker_pipeline_asset_plan(:'paper',:'claim',:'gen',:'upload','original',:'objects',2) as plan \gset
select (:'plan'::jsonb->'objects'->0->>'id') as original \gset
select test.assert((select state='pending' and byte_count=1000 from app_private.stored_objects where id=:'original'),'original inventoried before upload');
select test.assert(not exists(select 1 from app_private.paper_asset_holds where paper_id=:'paper' and kind='original'),'exact inventory replaces original reserve');
select test.assert(public.worker_pipeline_asset_plan(:'paper',:'claim',:'gen',:'upload','original',:'objects',2)=:'plan'::jsonb,'plan replay is idempotent');
select test.reject(format('select public.worker_pipeline_original(%L,%L,%s,%L::bytea,1000,2,%L)',:'paper',:'claim',:'gen','\x'||repeat('a',64),'originals/'||repeat('a',64)||'.pdf'),'asset_inventory_incomplete');
select gen_random_uuid() as write \gset
select test.assert((public.worker_pipeline_asset_write(:'paper',:'claim',:'gen',:'upload',:'original',:'write')->>'write')::boolean,'one write admitted');
select test.assert(not (public.worker_pipeline_asset_write(:'paper',:'claim',:'gen',:'upload',:'original',gen_random_uuid())->>'write')::boolean,'unknown prior write blocks another send');
select test.reject(format('select public.worker_pipeline_asset_written(%L,null)',:'write'),'asset_write_proof_required');
select public.worker_pipeline_asset_written(:'write',true);
select public.worker_pipeline_asset_written(:'write',true);
select public.worker_pipeline_original(:'paper',:'claim',:'gen',decode(repeat('a',64),'hex'),1000,2,'originals/'||repeat('a',64)||'.pdf');
select public.worker_pipeline_admit_processing(:'paper',:'claim',:'gen');
select public.worker_pipeline_fund(:'paper',:'claim',:'gen',2,decode(repeat('b',64),'hex'),decode(repeat('c',64),'hex'));
select public.worker_pipeline_begin_submit(:'paper',:'claim',:'gen')->>'attempt_id' as attempt \gset
select public.worker_pipeline_submitted(:'attempt','asset-fixture-job');

-- The helper models terminal successful Storage responses for each admitted
-- immutable object; it is not an actual upload or provider call.
create function test.complete_asset_plan(p uuid,c uuid,g bigint,k text,objects jsonb) returns jsonb language plpgsql as $$
declare plan jsonb; row jsonb; upload uuid:=gen_random_uuid(); write uuid;
begin
 plan:=public.worker_pipeline_asset_plan(p,c,g,upload,k,objects);
 for row in select value from jsonb_array_elements(plan->'objects') loop
  if not (row->>'verified')::boolean then
   write:=gen_random_uuid();
   perform test.assert((public.worker_pipeline_asset_write(p,c,g,upload,(row->>'id')::uuid,write)->>'write')::boolean,'fixture write granted');
   perform public.worker_pipeline_asset_written(write,true);
  end if;
 end loop;
 return plan;
end $$;
select test.complete_asset_plan(:'paper',:'claim',:'gen','raw',jsonb_build_array(
 jsonb_build_object('path','raw/'||repeat('d',64)||'/manifest.json','sha256',repeat('d',64),'bytes',100,'media_type','application/json'),
 jsonb_build_object('path','raw/'||repeat('d',64)||'/standalone.mmd','sha256',repeat('e',64),'bytes',50,'media_type','text/plain; charset=utf-8'),
 jsonb_build_object('path','raw/'||repeat('d',64)||'/output.mmd.zip','sha256',repeat('f',64),'bytes',100,'media_type','application/zip'),
 jsonb_build_object('path','raw/'||repeat('d',64)||'/lines.json','sha256',repeat('1',64),'bytes',100,'media_type','application/json')));
select public.worker_pipeline_collected(:'paper',:'claim',:'gen',2,decode(repeat('d',64),'hex'),100);
select test.complete_asset_plan(:'paper',:'claim',:'gen','reader',jsonb_build_array(
 jsonb_build_object('path','reader/'||repeat('2',64)||'/manifest.json','sha256',repeat('2',64),'bytes',100,'media_type','application/json'),
 jsonb_build_object('path','reader/'||repeat('2',64)||'/index.html','sha256',repeat('3',64),'bytes',200,'media_type','text/html; charset=utf-8'),
 jsonb_build_object('path','reader/'||repeat('2',64)||'/index.json','sha256',repeat('4',64),'bytes',100,'media_type','application/json'))) as reader_plan \gset
select public.worker_pipeline_published(:'paper',:'claim',:'gen',decode(repeat('2',64),'hex'),100,'timestep-mathpix-mathml-v1');
select public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen');
select id as item,document_id as doc from app_private.library_items where account_id='34000000-0000-0000-0000-000000000001' \gset
select test.assert(not exists(select 1 from app_private.paper_asset_holds where paper_id=:'paper'),'publication releases unused future holds');
select test.assert((select count(*)=8 and sum(byte_count)=1750 from app_private.stored_objects where document_id=:'doc'),'all physical members counted, not just manifests');

update app_private.reader_delivery_policy set mode='dual' where singleton;
select public.worker_reader_delivery_create('34000000-0000-0000-0000-000000000001',:'item',decode(repeat('5',64),'hex'),'bounded-v1') as delivery \gset
select (:'delivery'::jsonb->'members'->0->>'id') as member \gset
select test.assert((select reserved_bytes=300 and authorized_bytes=1048576 from app_private.reader_transfer_months where scope_id='34000000-0000-0000-0000-000000000001' and kind='reader'),'descriptor is charged even without member downloads');
select public.worker_reader_delivery_redeem('34000000-0000-0000-0000-000000000001',decode(repeat('5',64),'hex'),:'member') as redeemed \gset
select test.reject(format('select public.worker_reader_delivery_redeem(%L,%L::bytea,%L)','34000000-0000-0000-0000-000000000001','\x'||repeat('5',64),:'member'),'reader_grant_consumed');
select test.reject(format('select public.worker_reader_delivery_redeem(%L,%L::bytea,%L)','34000000-0000-0000-0000-000000000002','\x'||repeat('5',64),:'member'),'reader_grant_unavailable');
select test.assert((select authorized_bytes=1048576+(:'redeemed'::jsonb->>'bytes')::bigint from app_private.reader_transfer_months where scope_id='34000000-0000-0000-0000-000000000001' and kind='reader'),'actual GET admitted once');
update app_private.reader_delivery_grants set expires_at=clock_timestamp()-interval '1 second' where id=(:'delivery'::jsonb->>'grant_id')::uuid;
select public.worker_reader_delivery_expire();
select test.assert((select reserved_bytes=0 and authorized_bytes>1048576 from app_private.reader_transfer_months where scope_id='34000000-0000-0000-0000-000000000001' and kind='reader'),'expiry releases only unused reservation');
select test.reject(format('select public.worker_reader_delivery_redeem(%L,%L::bytea,%L)','34000000-0000-0000-0000-000000000001','\x'||repeat('5',64),:'member'),'reader_grant_unavailable');
select test.assert(public.worker_chat_context('34000000-0000-0000-0000-000000000001',:'doc')->>'byte_count'='50','context authorizes exact inventoried MMD bytes');
update app_private.reader_delivery_policy set mode='bounded' where singleton;
select test.reject(format('select public.worker_reader_delivery_create(%L,%L,%L::bytea,%L)','34000000-0000-0000-0000-000000000001',:'item','\x'||repeat('6',64),'legacy'),'reader_upgrade_required');
update app_private.reader_delivery_policy set account_bytes_month=1 where singleton;
select test.reject(format('select public.worker_reader_delivery_create(%L,%L,%L::bytea,%L)','34000000-0000-0000-0000-000000000001',:'item','\x'||repeat('6',64),'bounded-v1'),'reader_transfer_limit');
update app_private.reader_delivery_policy set account_bytes_month=268435456 where singleton;

-- Private upload uncertainty fences physical account erasure before removal.
insert into app_private.pipeline_papers(owner_id,source_id,revision,stage,eligible,claim_id,generation,lease_until)
 values('34000000-0000-0000-0000-000000000003','2410.03403',1,'download',false,gen_random_uuid(),1,clock_timestamp()+interval '5 minutes') returning id as private_paper,claim_id as private_claim \gset
select public.worker_pipeline_asset_plan(:'private_paper',:'private_claim',1,gen_random_uuid(),'original',jsonb_build_array(
 jsonb_build_object('path','private/34000000-0000-0000-0000-000000000003/originals/'||repeat('7',64)||'.pdf','sha256',repeat('7',64),'bytes',1000,'media_type','application/pdf')),1) as private_plan \gset
select gen_random_uuid() as private_write \gset
select public.worker_pipeline_asset_write(:'private_paper',:'private_claim',1,(:'private_plan'::jsonb->>'upload_id')::uuid,
 (:'private_plan'::jsonb->'objects'->0->>'id')::uuid,:'private_write');
select public.worker_delete_account_begin('34000000-0000-0000-0000-000000000003') as deletion \gset
select test.assert(:'deletion'::jsonb->>'blocked'='asset_write_uncertain' and jsonb_array_length(:'deletion'::jsonb->'objects')=0,'closure returns no physical deletion authority during unresolved upload');
select test.assert((select closed_at is not null from app_private.accounts where id='34000000-0000-0000-0000-000000000003'),'closure commits while erasure waits');
select test.reject($q$select public.worker_delete_account_finish('34000000-0000-0000-0000-000000000003')$q$,'asset_write_uncertain');
select public.worker_pipeline_asset_written(:'private_write',true);
select public.worker_delete_account_begin('34000000-0000-0000-0000-000000000003') as deletion \gset
select test.assert(jsonb_array_length(:'deletion'::jsonb->'objects')=1,'terminal writer permits exact later deletion');
select public.worker_delete_account_finish('34000000-0000-0000-0000-000000000003');
select test.assert((select state='deleted' from app_private.stored_objects where id=(:'private_plan'::jsonb->'objects'->0->>'id')::uuid),'capacity released after terminal write and confirmed delete');

select public.worker_delete_account_begin('34000000-0000-0000-0000-000000000001');
select test.assert(not exists(select 1 from app_private.reader_delivery_grants where account_id='34000000-0000-0000-0000-000000000001'),'personal grant membership erased');
select test.assert(not exists(select 1 from app_private.reader_transfer_months where scope_id='34000000-0000-0000-0000-000000000001'),'personal counters erased');
select test.assert(exists(select 1 from app_private.reader_transfer_months where scope_id='environment' and authorized_bytes>0),'environment cost evidence retained');
select test.reject(format('select public.worker_reader_delivery_observed(%L,%L,0,0,%L)',:'delivery'::jsonb->>'grant_id',:'member','upstream_failed'),'query returned no rows');
select test.assert(not exists(select 1 from app_private.reader_transfer_months where scope_id='34000000-0000-0000-0000-000000000001'),'late observation cannot resurrect private rows');

-- Operator scans require a fully drained pipeline and never enable enforcement.
select test.reject('select public.worker_asset_inventory_begin(gen_random_uuid())','asset_workers_not_drained');
select public.worker_set_pipeline_enabled(false);
update app_private.pipeline_papers set claim_id=null,lease_until=null;
select gen_random_uuid() as scan \gset
select public.worker_asset_inventory_begin(:'scan');
select public.worker_asset_inventory_begin(:'scan');
select test.reject('select public.worker_asset_inventory_begin(gen_random_uuid())','asset_inventory_reconciling');
select test.reject('select public.worker_asset_enforcement(true,''dual'')','asset_inventory_incomplete');
select test.reject(format('select public.worker_asset_inventory_page(%L,null,null)',:'scan'),'invalid_inventory_scan');
select test.assert(jsonb_array_length(public.worker_asset_inventory_page(:'scan',null,1)->'objects')=1,'inventory pages are bounded');

-- A verified legacy manifest is the authority for member ownership; the
-- operator must hash the manifest and every member before this trusted RPC.
insert into app_private.stored_objects(bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
 values('paper-assets','raw/'||repeat('8',64)||'/manifest.json',:'doc','verified',decode(repeat('8',64),'hex'),100,'application/json',clock_timestamp())
 returning id as legacy_manifest \gset
select jsonb_build_array(
 jsonb_build_object('relative_path','standalone.mmd','sha256',repeat('9',64),'bytes',100,'media_type','text/plain; charset=utf-8'),
 jsonb_build_object('relative_path','output.mmd.zip','sha256',repeat('a',64),'bytes',100,'media_type','application/zip'),
 jsonb_build_object('relative_path','lines.json','sha256',repeat('b',64),'bytes',100,'media_type','application/json')) as legacy_members \gset
select public.worker_asset_inventory_manifest(:'scan',:'legacy_manifest',:'legacy_members');
select public.worker_asset_inventory_manifest(:'scan',:'legacy_manifest',:'legacy_members');
select test.assert((select count(*)=3 from app_private.paper_asset_manifest_members where manifest_object_id=:'legacy_manifest'),'legacy members imported idempotently');
select test.assert((select media_type='text/plain' from app_private.stored_objects where path='raw/'||repeat('8',64)||'/standalone.mmd'),'canonical MIME agrees across new writes and legacy import');
select test.reject(format('select public.worker_asset_inventory_manifest(%L,%L,%L)',:'scan',:'legacy_manifest','[{"relative_path":"../outside","sha256":"'||repeat('b',64)||'","bytes":1,"media_type":"text/plain"}]'),'invalid_manifest_inventory');
select test.reject(format('select public.worker_asset_inventory_manifest(%L,%L,%L)',:'scan',:'legacy_manifest','[{"relative_path":"missing-sha","bytes":1,"media_type":"text/plain"}]'),'invalid_manifest_inventory');
select test.reject(format('select public.worker_asset_inventory_manifest(%L,%L,%L)',:'scan',:'legacy_manifest',jsonb_set(:'legacy_members'::jsonb,'{0,bytes}','101')),'asset_identity_conflict');
select test.reject(format('select public.worker_asset_inventory_finish(%L,0,0,%L,decode(repeat(''c'',64),''hex''))',:'scan','{"incomplete":0}'),'invalid_inventory_scan');
select public.worker_set_pipeline_enabled(true);
select test.reject(format('select public.worker_asset_inventory_finish(%L,0,0,%L,decode(repeat(''c'',64),''hex''))',:'scan','{"incomplete":0,"mismatched":0,"missing_verified":0,"unowned":0,"untracked":0}'),'asset_workers_not_drained');
select public.worker_set_pipeline_enabled(false);
select public.worker_asset_inventory_finish(:'scan',12,2150,'{"incomplete":0,"mismatched":0,"missing_verified":0,"unowned":0,"untracked":1}',decode(repeat('c',64),'hex'));
select test.assert((select not enforced and inventory_verified_at is null and inventory_discrepancies=1 from app_private.paper_asset_policy),'incomplete scan cannot leave enforcement certified');
select test.reject('select public.worker_asset_enforcement(true,''dual'')','asset_inventory_incomplete');
select gen_random_uuid() as clean_scan \gset
select public.worker_asset_inventory_begin(:'clean_scan');
select public.worker_asset_inventory_finish(:'clean_scan',12,2150,'{"incomplete":0,"mismatched":0,"missing_verified":0,"unowned":0,"untracked":0}',decode(repeat('d',64),'hex'));
select public.worker_asset_inventory_finish(:'clean_scan',12,2150,'{"incomplete":0,"mismatched":0,"missing_verified":0,"unowned":0,"untracked":0}',decode(repeat('d',64),'hex'));
select test.assert((select not enforced and inventory_verified_at is not null from app_private.paper_asset_policy),'successful reconciliation still requires explicit enforcement cutover');
select test.reject(format('select public.worker_asset_inventory_finish(%L,13,2150,%L,decode(repeat(''d'',64),''hex''))',:'clean_scan','{"incomplete":0,"mismatched":0,"missing_verified":0,"unowned":0,"untracked":0}'),'inventory_result_conflict');
select public.worker_asset_enforcement(true,'dual');
select test.assert((select enforced from app_private.paper_asset_policy),'explicit cutover follows a complete scan');

-- Maintenance can release a future phase, but never uncertain physical bytes
-- or a still-claimed/active paper's reservation.
insert into app_private.pipeline_papers(source_id,stage,document_id,generation)
 values('2410.03408','failed',:'doc',1) returning id as stopped_paper \gset
insert into app_private.pipeline_papers(source_id,stage,document_id,generation,claim_id,lease_until)
 values('2410.03409','failed',:'doc',1,gen_random_uuid(),clock_timestamp()+interval '5 minutes') returning id as active_paper \gset
insert into app_private.paper_asset_holds(paper_id,kind,bytes,objects)
 values(:'stopped_paper','reader',1000,2),(:'active_paper','reader',1000,2);
insert into app_private.stored_objects(bucket,path,document_id,sha256,byte_count,media_type)
 values('paper-assets','raw/'||repeat('f',64)||'/unresolved.mmd',:'doc',decode(repeat('f',64),'hex'),123,'text/plain') returning id as unresolved_object \gset
insert into app_private.paper_asset_uploads(id,paper_id,claim_id,generation,kind,document_id,manifest_object_id,request_sha256)
 values(gen_random_uuid(),:'stopped_paper',gen_random_uuid(),1,'raw',:'doc',:'unresolved_object',decode(repeat('a',64),'hex')) returning id as stopped_upload \gset
insert into app_private.paper_asset_upload_members values(:'stopped_upload',:'unresolved_object');
insert into app_private.paper_asset_write_attempts(id,upload_id,object_id)
 values(gen_random_uuid(),:'stopped_upload',:'unresolved_object');
select public.worker_asset_maintenance(100);
select test.assert(not exists(select 1 from app_private.paper_asset_holds where paper_id=:'stopped_paper'),'future unused phase released');
select test.assert(exists(select 1 from app_private.paper_asset_holds where paper_id=:'active_paper'),'claimed future phase retained');
select test.assert((select state='pending' and byte_count=123 from app_private.stored_objects where id=:'unresolved_object'),'physical pending bytes remain inventoried');
select test.assert(exists(select 1 from app_private.paper_asset_write_attempts where object_id=:'unresolved_object' and finished_at is null),'unknown write remains quarantined');
update app_private.pipeline_papers set claim_id=null,lease_until=null;
select test.assert(not (select enabled from app_private.pipeline_policy),'scan guard fixture is disabled');
select test.reject('select public.worker_asset_inventory_begin(gen_random_uuid())','asset_workers_not_drained');
select public.worker_pipeline_asset_written(id,true) from app_private.paper_asset_write_attempts where object_id=:'unresolved_object';
select gen_random_uuid() as maintenance_scan \gset
select public.worker_asset_inventory_begin(:'maintenance_scan');
select public.worker_asset_maintenance(100);
select test.assert(exists(select 1 from app_private.paper_asset_holds where paper_id=:'active_paper'),'scan preserves even unclaimed terminal future holds');
-- The trusted fixture models an unexpected legacy writer; finalization must
-- independently recheck drain state rather than trust the earlier begin.
insert into app_private.paper_asset_write_attempts(id,upload_id,object_id)
 values(gen_random_uuid(),:'stopped_upload',:'unresolved_object');
select test.reject(format('select public.worker_asset_inventory_finish(%L,0,0,%L,decode(repeat(''d'',64),''hex''))',:'maintenance_scan','{"incomplete":0,"mismatched":0,"missing_verified":0,"unowned":0,"untracked":0}'),'asset_workers_not_drained');
set role authenticated;
select test.reject('select public.worker_asset_spending_status()','permission denied');
select test.reject('select * from app_private.paper_asset_write_attempts','permission denied');
reset role;
rollback;
