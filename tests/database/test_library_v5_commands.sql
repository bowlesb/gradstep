-- Epoch-bound v5 library commands (migration 042). Synthetic local rows only.
-- Account A sends v2 commands (installed v3 readers); account B sends the same
-- commands through v5. Their receipts, journal entries, digests and errors must
-- be identical apart from row identities and the v5 dataset_epoch.
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
-- Two accounts running the same commands differ only in their own row IDs.
create function test.shape(r jsonb) returns jsonb language sql immutable as $$
 select jsonb_build_object('result',(r->'result')-'id','replayed',r->'replayed',
  'entry',(r->'entry')-array['id','library_item_id','added_at'])
$$;
create function test.digest(a uuid,op uuid) returns bytea language sql stable as $$
 select request_sha256 from app_private.library_commands where account_id=a and id=op
$$;

\set A '41000000-0000-0000-0000-00000000000a'
\set B '41000000-0000-0000-0000-00000000000b'
\set NOBODY '41000000-0000-0000-0000-0000000000ff'
\set D '41000000-0000-0000-0000-000000000010'
\set O '41000000-0000-0000-0000-000000000011'
\set P '41000000-0000-0000-0000-000000000101'
\set IA1 '41000000-0000-0000-0000-0000000a0001'
\set IB1 '41000000-0000-0000-0000-0000000b0001'
\set IA2 '41000000-0000-0000-0000-0000000a0002'
\set IB2 '41000000-0000-0000-0000-0000000b0002'
\set UA '41000000-0000-0000-0000-0000000a0003'
\set UB '41000000-0000-0000-0000-0000000b0003'
\set XB '41000000-0000-0000-0000-0000000b00ff'
insert into auth.users values(:'A'),(:'B');
set role service_role;
select public.worker_record_arxiv_metadata('2410.04101',1,'{"title":"Parity paper","authors":["A. Reader"],"categories":["cs.LG"]}') as meta \gset
select public.worker_record_arxiv_metadata('2410.04102',1,'{"title":"Retry paper","authors":["B. Reader"],"categories":["cs.LG"]}') as meta2 \gset
reset role;
insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values
 (:'D',decode(repeat('41',32),'hex'),'shared_catalog','{"legacy_fixture":true}',1000,2);
insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values
 (:'O','paper-assets','test/v5-commands/original.pdf',:'D','verified',decode(repeat('41',32),'hex'),1000,'application/pdf',now());
set role service_role;
select public.worker_approve_arxiv_asset(:'P',:'meta',:'D',:'O','https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2410.04101','source_revision',1,'source_url','https://arxiv.org/abs/2410.04101v1',
  'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('a',64),'observed_at','2026-10-07T01:00:00Z'));
reset role;
select upload_dataset_epoch as epoch,dataset_epoch as compact_epoch from app_private.library_v4_config \gset
-- DO blocks below run as the customer role, which cannot read app_private.
select set_config('test.epoch',:'epoch',false),set_config('test.compact_epoch',:'compact_epoch',false);

-- Same exposure as the v2 commands: authenticated only, definer with an empty search path.
select test.assert((select count(*)=6 and bool_and(p.prosecdef and p.proconfig=array['search_path=""']
  and has_function_privilege('authenticated',p.oid,'execute') and not has_function_privilege('anon',p.oid,'execute')
  and not has_function_privilege('service_role',p.oid,'execute') and not has_function_privilege('public',p.oid,'execute'))
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  and p.proname in ('v5_begin_import','v5_set_library_item','v5_cancel_import','v5_retry_import','v5_set_item_archived','v5_set_item_tags')),
 'six v5 commands, definer/search_path pinned, executable only by authenticated');
select test.assert(not has_function_privilege('authenticated','app_private.library_command_epoch(uuid,boolean)','execute'),
 'the epoch helper is private');
set role anon;
select test.reject(format('select public.v5_begin_import(%L,gen_random_uuid(),%L,0,null)',:'epoch','2410.04101'),'permission denied');
select test.reject(format('select public.v5_set_item_tags(%L,gen_random_uuid(),%L,array[]::text[],array[]::text[],1)',:'epoch',:'D'),'permission denied');
reset role;
set role service_role;
select test.reject(format('select public.v5_cancel_import(%L,gen_random_uuid(),%L,1)',:'epoch',:'IB1'),'permission denied');
reset role;
set role authenticated;
-- Authentication precedes the dataset check, as require_actor precedes v2 work.
select set_config('request.jwt.claim.sub',:'NOBODY',false);
select test.reject(format('select public.v5_begin_import(%L,gen_random_uuid(),%L,0,null)',:'epoch','2410.04101'),'authentication_required');
select test.reject(format('select public.v5_begin_import(gen_random_uuid(),gen_random_uuid(),%L,0,null)','2410.04101'),'authentication_required');

-- 1. Begin import: identical receipt, entry and digest; v5 adds only dataset_epoch.
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_begin_import(:'IA1','2410.04101',0,null) as a1 \gset
select set_config('request.jwt.claim.sub',:'B',false);
select public.v5_begin_import(:'epoch',:'IB1','2410.04101',0,null) as b1 \gset
select test.assert(:'b1'::jsonb->>'dataset_epoch'=:'epoch' and not (:'a1'::jsonb ? 'dataset_epoch'),'only the v5 receipt names its dataset');
select test.assert(test.shape(:'a1')=test.shape(:'b1') and :'b1'::jsonb->'result'->>'status'='applied','begin: v5 equals v2');
select public.v2_begin_import(:'IB1','2410.04101',0,null) as b1v2 \gset
select test.assert((:'b1v2'::jsonb->>'replayed')::boolean and (:'b1'::jsonb-'dataset_epoch'-'replayed')=(:'b1v2'::jsonb-'replayed'),
 'a v5 receipt replays through v2 unchanged: same digest, same stored result');
select public.v5_begin_import(:'epoch',:'IB1','2410.04101',0,null) as b1again \gset
select test.assert((:'b1again'::jsonb->>'replayed')::boolean and :'b1again'::jsonb->'result'=:'b1'::jsonb->'result'
 and :'b1again'::jsonb->>'dataset_epoch'=:'epoch','exact v5 replay');
select test.reject(format('select public.v5_begin_import(%L,%L,%L,0,1)',:'epoch',:'IB1','2410.04101'),'operation_id_conflict');
-- The receipt floor is a v5 catch-up position in this epoch: one journal sequence.
select public.v5_library_changes(:'epoch',(:'b1'::jsonb->'result'->>'seq')::bigint-1) as delta \gset
select test.assert((:'delta'::jsonb->>'through')::bigint>=(:'b1'::jsonb->'result'->>'seq')::bigint
 and :'delta'::jsonb->'changes'->0->>'seq'=:'b1'::jsonb->'result'->>'seq'
 and :'delta'::jsonb->'changes'->0->'entries'->0->>'id'=:'IB1' and :'delta'::jsonb->>'dataset_epoch'=:'epoch',
 'v5 changes after the receipt floor deliver the committed batch');
reset role;
select test.assert(test.digest(:'A',:'IA1')=test.digest(:'B',:'IB1'),'begin: same request digest');

-- 2. Cancel; then Retry of a cancelled import is refused identically.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_cancel_import(gen_random_uuid(),:'IA1',1) as a2 \gset
select test.reject(format('select public.v2_retry_import(gen_random_uuid(),%L,2)',:'IA1'),'import_not_retryable');
select set_config('request.jwt.claim.sub',:'B',false);
select public.v5_cancel_import(:'epoch',gen_random_uuid(),:'IB1',1) as b2 \gset
select test.reject(format('select public.v5_retry_import(%L,gen_random_uuid(),%L,2)',:'epoch',:'IB1'),'import_not_retryable');
select test.assert(test.shape(:'a2')=test.shape(:'b2') and :'b2'::jsonb->'entry'->>'phase'='cancelled','cancel: v5 equals v2');

-- 3. Retry of a failed, retryable import.
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_begin_import(:'IA2','2410.04102',2,null) as a3 \gset
select set_config('request.jwt.claim.sub',:'B',false);
select public.v5_begin_import(:'epoch',:'IB2','2410.04102',2,null) as b3 \gset
select test.assert(test.shape(:'a3')=test.shape(:'b3'),'second begin: v5 equals v2');
select (:'a3'::jsonb->'entry'->>'state_seq')::bigint as s3 \gset
reset role;
set role service_role;
select public.worker_checkpoint_import(:'A',:'IA2',:s3,1,'acquiring',:'meta2');
select public.worker_checkpoint_import(:'A',:'IA2',:s3+1,1,'failed',null,'download_failed',true);
select public.worker_checkpoint_import(:'B',:'IB2',:s3,1,'acquiring',:'meta2');
select public.worker_checkpoint_import(:'B',:'IB2',:s3+1,1,'failed',null,'download_failed',true);
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_retry_import(gen_random_uuid(),:'IA2',1) as a4 \gset
select set_config('request.jwt.claim.sub',:'B',false);
select public.v5_retry_import(:'epoch',gen_random_uuid(),:'IB2',1) as b4 \gset
select test.assert(test.shape(:'a4')=test.shape(:'b4') and :'b4'::jsonb->'result'->>'status'='applied'
 and :'b4'::jsonb->'entry'->>'phase'='acquiring','retry: v5 equals v2');

-- 4. Explicit Add, archive, tags, a stale-revision conflict and Remove.
create temporary table pairs(label text,a jsonb,b jsonb,op_a uuid,op_b uuid) on commit drop;
grant all on pairs to authenticated;
do $$
declare d uuid:='41000000-0000-0000-0000-000000000010'; p uuid:='41000000-0000-0000-0000-000000000101';
 e uuid:=current_setting('test.epoch')::uuid;
 steps text[][]:=array[
  ['add','v2_set_library_item(%1$L,%2$L,true,0,%3$L)','v5_set_library_item(%4$L,%1$L,%2$L,true,0,%3$L)'],
  ['archive','v2_set_item_archived(%1$L,%2$L,true,1)','v5_set_item_archived(%4$L,%1$L,%2$L,true,1)'],
  ['tags','v2_set_item_tags(%1$L,%2$L,array[''Mine''],array[]::text[],2)','v5_set_item_tags(%4$L,%1$L,%2$L,array[''Mine''],array[]::text[],2)'],
  ['conflict','v2_set_item_archived(%1$L,%2$L,false,1)','v5_set_item_archived(%4$L,%1$L,%2$L,false,1)'],
  ['remove','v2_set_library_item(%1$L,%2$L,false,3,%3$L)','v5_set_library_item(%4$L,%1$L,%2$L,false,3,%3$L)']];
 step text[]; oa uuid; ob uuid; ra jsonb; rb jsonb;
begin
 foreach step slice 1 in array steps loop
  oa:=gen_random_uuid(); ob:=gen_random_uuid();
  perform set_config('request.jwt.claim.sub','41000000-0000-0000-0000-00000000000a',false);
  execute format('select public.'||step[2],oa,d,p,e) into ra;
  perform set_config('request.jwt.claim.sub','41000000-0000-0000-0000-00000000000b',false);
  execute format('select public.'||step[3],ob,d,p,e) into rb;
  insert into pairs values(step[1],ra,rb,oa,ob);
 end loop;
end $$;
reset role;
select test.assert((select bool_and(test.shape(a)=test.shape(b) and b->>'dataset_epoch'=:'epoch') from pairs),
 'membership, archive, tags, conflict and remove: v5 equals v2');
select test.assert((select jsonb_object_agg(label,jsonb_build_array(b->'result'->>'status',(b->'result'->>'revision')::int)) from pairs)
 ='{"add":["applied",1],"archive":["applied",2],"tags":["applied",3],"conflict":["revision_conflict",3],"remove":["applied",4]}'::jsonb,
 'expected outcomes and revisions');
select test.assert((select bool_and(test.digest(:'A',op_a)=test.digest(:'B',op_b)) from pairs),'same request digests');
select test.assert((select count(*) from app_private.library_changes c where c.account_id=:'A')
 =(select count(*) from app_private.library_changes c where c.account_id=:'B')
 and (select last_seq from app_private.library_sync_state where account_id=:'A')
  =(select last_seq from app_private.library_sync_state where account_id=:'B'),'identical journal positions');

-- 5. Validation and capacity errors are v2's own, in the same order.
set role authenticated;
do $$
declare d uuid:='41000000-0000-0000-0000-000000000010'; e uuid:=current_setting('test.epoch')::uuid;
 cases text[][]:=array[
  ['v2_begin_import(gen_random_uuid(),''not-an-id'',0,null)','v5_begin_import(%1$L,gen_random_uuid(),''not-an-id'',0,null)','invalid_arxiv_id'],
  ['v2_begin_import(gen_random_uuid(),''2410.04103'',-1,null)','v5_begin_import(%1$L,gen_random_uuid(),''2410.04103'',-1,null)','invalid_import_request'],
  ['v2_begin_import(gen_random_uuid(),''2410.04103'',999999,null)','v5_begin_import(%1$L,gen_random_uuid(),''2410.04103'',999999,null)','invalid_library_cursor'],
  ['v2_set_library_item(gen_random_uuid(),%2$L,null,0)','v5_set_library_item(%1$L,gen_random_uuid(),%2$L,null,0)','invalid_membership_command'],
  ['v2_set_library_item(gen_random_uuid(),gen_random_uuid(),true,0)','v5_set_library_item(%1$L,gen_random_uuid(),gen_random_uuid(),true,0)','document_unavailable'],
  ['v2_cancel_import(gen_random_uuid(),gen_random_uuid(),1)','v5_cancel_import(%1$L,gen_random_uuid(),gen_random_uuid(),1)','import_unavailable'],
  ['v2_retry_import(gen_random_uuid(),gen_random_uuid(),0)','v5_retry_import(%1$L,gen_random_uuid(),gen_random_uuid(),0)','invalid_import_revision'],
  ['v2_set_item_archived(gen_random_uuid(),%2$L,null,1)','v5_set_item_archived(%1$L,gen_random_uuid(),%2$L,null,1)','invalid_archive_command'],
  ['v2_set_item_tags(gen_random_uuid(),%2$L,array['' x''],array[]::text[],1)','v5_set_item_tags(%1$L,gen_random_uuid(),%2$L,array['' x''],array[]::text[],1)','invalid_tags_command']];
 c text[];
begin
 foreach c slice 1 in array cases loop
  perform set_config('request.jwt.claim.sub','41000000-0000-0000-0000-00000000000a',false);
  perform test.reject(format('select public.'||c[1],e,d),c[3]);
  perform set_config('request.jwt.claim.sub','41000000-0000-0000-0000-00000000000b',false);
  perform test.reject(format('select public.'||c[2],e,d),c[3]);
 end loop;
end $$;
reset role;
update app_private.library_policy set account_imports=2;
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject($q$select public.v2_begin_import(gen_random_uuid(),'2410.04103',0,null)$q$,'library_account_import_limit');
select set_config('request.jwt.claim.sub',:'B',false);
select test.reject(format('select public.v5_begin_import(%L,gen_random_uuid(),%L,0,null)',:'epoch','2410.04103'),'library_account_import_limit');
reset role;
update app_private.library_policy set account_imports=2000;

-- 6. A reader-uploaded import (source level 4) is cancelled through the same command.
create function test.upload_import(a uuid,i uuid) returns void language plpgsql as $$
declare pub uuid; ver uuid; m uuid; s bigint; src text:='upload:'||i;
 meta jsonb:=jsonb_build_object('title','Uploaded PDF','authors','[]'::jsonb,'categories','[]'::jsonb);
begin
 insert into app_private.publications(title) values('Uploaded PDF') returning id into pub;
 insert into app_private.publication_versions(publication_id,source,revision) values(pub,src,'1') returning id into ver;
 insert into app_private.catalog_metadata(version_id,source_id,source_revision,metadata,metadata_sha256)
  values(ver,src,1,meta,sha256(convert_to(meta::text,'UTF8'))) returning id into m;
 perform app_private.lock_library_account(a); perform app_private.lock_library_state(a);
 s:=app_private.library_next_seq(a);
 insert into app_private.import_requests(account_id,id,request_sha256,source_id,observed_cursor,created_seq,state_seq,metadata_id)
  values(a,i,sha256(convert_to(i::text,'UTF8')),src,0,s,s,m);
 perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,i)));
end $$;
select test.upload_import(:'A',:'UA');
select test.upload_import(:'B',:'UB');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_cancel_import(gen_random_uuid(),:'UA',1) as ua \gset
select set_config('request.jwt.claim.sub',:'B',false);
select public.v5_cancel_import(:'epoch',gen_random_uuid(),:'UB',1) as ub \gset
select test.assert(:'ub'::jsonb->'entry'->>'source'='upload' and :'ub'::jsonb->'entry'->>'phase'='cancelled'
 and (:'ua'::jsonb->'result')-'id'=(:'ub'::jsonb->'result')-'id','upload import: v5 cancel equals v2');
select test.assert(exists(select 1 from jsonb_array_elements(public.v5_library_changes(:'epoch',(:'ub'::jsonb->'result'->>'seq')::bigint-1)->'changes') c,
 jsonb_array_elements(c->'entries') x where x->>'id'=:'UB' and x->>'phase'='cancelled'),'v5 catch-up delivers the upload cancellation');

-- 7. Another dataset is refused before any v2 evaluation, and nothing is written.
reset role;
select last_seq as seq_before from app_private.library_sync_state where account_id=:'B' \gset
select count(*) as receipts_before from app_private.library_commands where account_id=:'B' \gset
select coalesce(sum(used),0) as writes_before from app_private.api_rate_windows where scope_id=:'B' and route='library-write' \gset
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select gen_random_uuid() as stale \gset
do $$
declare d uuid:='41000000-0000-0000-0000-000000000010'; p uuid:='41000000-0000-0000-0000-000000000101';
 x uuid:='41000000-0000-0000-0000-0000000b00ff'; i uuid:='41000000-0000-0000-0000-0000000b0002';
 compact uuid:=current_setting('test.compact_epoch')::uuid; stale uuid:=gen_random_uuid();
 calls text[]:=array[
  'v5_begin_import(%1$L,%2$L,''2410.04103'',0,null)',
  'v5_begin_import(%1$L,%2$L,''2410.04103'',999999,null)',  -- not invalid_library_cursor
  'v5_begin_import(%1$L,%2$L,''not-an-id'',0,null)',        -- not invalid_arxiv_id
  'v5_begin_import(%1$L,''41000000-0000-0000-0000-0000000b0001'',''2410.04101'',0,null)', -- an applied operation does not replay
  'v5_set_library_item(%1$L,%2$L,%3$L,true,0,%4$L)',
  'v5_cancel_import(%1$L,%2$L,%5$L,2)',
  'v5_retry_import(%1$L,%2$L,%5$L,2)',
  'v5_set_item_archived(%1$L,%2$L,%3$L,true,1)',
  'v5_set_item_tags(%1$L,%2$L,%3$L,array[''Other''],array[]::text[],1)'];
 call text; epoch uuid;
begin
 foreach epoch in array array[stale,compact] loop
  foreach call in array calls loop
   perform test.reject(format('select public.'||call,epoch,x,d,p,i),'library_resync_required');
  end loop;
 end loop;
 perform test.reject(format('select public.v5_begin_import(null,%L,''2410.04103'',0,null)',x),'invalid_library_cursor');
end $$;
reset role;
select test.assert((select last_seq from app_private.library_sync_state where account_id=:'B')=:seq_before
 and (select count(*) from app_private.library_commands where account_id=:'B')=:receipts_before
 and not exists(select 1 from app_private.import_requests where account_id=:'B' and id=:'XB')
 and (select coalesce(sum(used),0) from app_private.api_rate_windows where scope_id=:'B' and route='library-write')=:writes_before,
 'refused commands leave no receipt, journal batch, import or rate-window use');

-- 8. Rotation as restore quarantine performs it: old-epoch commands, including an
-- exact replay, are refused; the current epoch replays and applies; v2 is unaffected.
update app_private.library_v4_config set dataset_epoch=gen_random_uuid();
update app_private.library_v4_config set upload_dataset_epoch=gen_random_uuid();
select upload_dataset_epoch as rotated from app_private.library_v4_config \gset
select test.assert(:'rotated'<>:'epoch','the upload dataset identity changed');
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select test.reject(format('select public.v5_begin_import(%L,%L,%L,0,null)',:'epoch',:'IB1','2410.04101'),'library_resync_required');
select test.reject(format('select public.v5_set_item_tags(%L,gen_random_uuid(),%L,array[]::text[],array[]::text[],5)',:'epoch',:'D'),'library_resync_required');
select public.v5_begin_import(:'rotated',:'IB1','2410.04101',0,null) as b1rotated \gset
select test.assert((:'b1rotated'::jsonb->>'replayed')::boolean and :'b1rotated'::jsonb->'result'=:'b1'::jsonb->'result'
 and :'b1rotated'::jsonb->>'dataset_epoch'=:'rotated','a retained receipt replays only under the current dataset');
select (public.v5_library_page()->>'baseline_cursor')::bigint as fresh_cursor \gset
select public.v5_begin_import(:'rotated',gen_random_uuid(),'2410.04103',:fresh_cursor,null) as fresh \gset
select test.assert(:'fresh'::jsonb->'result'->>'status'='applied' and (:'fresh'::jsonb->'result'->>'seq')::bigint=:fresh_cursor+1,
 'a command observed in the new dataset applies');
select test.reject(format('select public.v5_library_changes(%L,0)',:'epoch'),'library_resync_required');
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert(public.v2_begin_import(gen_random_uuid(),'2410.04103',0,null)->'result'->>'status'='applied',
 'installed v2 writers have no dataset precondition and keep working');
reset role;
rollback;
