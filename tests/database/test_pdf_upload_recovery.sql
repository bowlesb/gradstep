-- Recovery/progress regressions use synthetic immutable Storage receipts only.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create function test.ready_upload(a uuid,target text default 'paper',imported uuid default null,rev bigint default null) returns uuid language plpgsql as $$
declare u uuid:=gen_random_uuid(); w uuid:=gen_random_uuid(); hash bytea:=decode(repeat('11',32),'hex');
begin
 perform public.worker_begin_pdf_upload(a,u,hash,1000,array[hash],target,imported,rev);
 perform public.worker_pdf_upload_write(a,u,1,0,w,hash,1000);
 perform public.worker_pdf_upload_written(w,hash,1000);
 if target='paper' then
  insert into app_private.library_descriptors(account_id,source_id,id,revision,mutation_id,device_id,epoch,format,ciphertext,sha256)
   values(a,'upload:'||u,gen_random_uuid(),1,gen_random_uuid(),gen_random_uuid(),1,1,decode(repeat('11',28),'hex'),sha256(decode(repeat('11',28),'hex')));
 end if;
 perform public.worker_freeze_pdf_upload(a,u,1,2,0);
 perform public.worker_finalize_pdf_upload(a,u,1);
 return u;
end $$;
update app_private.paper_asset_policy set enforced=true,inventory_verified_at=clock_timestamp(),inventory_scope=2;
select public.worker_pdf_upload_policy(true);
select public.worker_set_pipeline_enabled(true);
do $$
declare a uuid:=gen_random_uuid(); initial uuid; replacement uuid; final_supply uuid; paper uuid; claim uuid:=gen_random_uuid(); result jsonb; hash bytea:=decode(repeat('11',32),'hex');
begin
 insert into auth.users values(a);
 perform public.worker_grant_credits(a,'adjustment','upload-replacement-'||a,1000,now()-interval '1 day',null,'Replacement fixture');
 initial:=test.ready_upload(a);
 select id into strict paper from app_private.pipeline_papers where owner_id=a and source_id='upload:'||initial;
 update app_private.pipeline_papers set claim_id=claim,generation=1,lease_until=clock_timestamp()+interval '10 minutes' where id=paper;
 perform public.worker_pipeline_admit_download(paper,claim,1);
 perform public.worker_pipeline_upload_rejected(paper,claim,1,initial);
 perform test.assert((select upload_id is null and upload_generation is null from app_private.pipeline_papers where id=paper),'invalid PDF clears only its exact source pin');
 perform test.assert((select sum(byte_count)=1000 from app_private.stored_objects where owner_id=a and state<>'deleted'),'rejected bytes remain charged');
 perform app_private.pipeline_set_stage(paper,'failed','pdf_invalid','download');
 perform public.worker_pipeline_sync_imports(paper,claim,1);
 perform public.worker_pipeline_release(paper,claim,1);
 replacement:=test.ready_upload(a,'import',initial,1);
 perform test.assert((select bound_import_id=initial and bound_intent_revision=2 from app_private.pdf_uploads where id=replacement),'replacement binds new intent on the same import');
 perform app_private.pipeline_set_stage(paper,'download');
 update app_private.pipeline_papers set claim_id=claim,generation=2,lease_until=clock_timestamp()+interval '10 minutes' where id=paper;
 result:=public.worker_pipeline_admit_download(paper,claim,2);
 perform test.assert(result->'upload'->>'id'=replacement::text,'replacement becomes admitted input after rejected original');
 perform public.worker_pdf_upload_read(gen_random_uuid(),replacement,1,paper,claim,2);
 perform test.assert((select count(*)=2 from app_private.stored_objects where owner_id=a and state<>'deleted'),'new source selection does not release the old physical object');

 -- A later Retry changes the exact wanted intent. The old checking upload is
 -- now unused; cleanup retires its pin, then a supplied PDF for the new intent
 -- can take its place. Its deletion batch still retains all physical bytes.
 perform app_private.pipeline_set_stage(paper,'failed','download_failed','download');
 perform public.worker_pipeline_sync_imports(paper,claim,2);
 perform public.worker_pipeline_release(paper,claim,2);
 perform set_config('request.jwt.claim.sub',a::text,true);
 perform public.v2_retry_import(gen_random_uuid(),initial,2);
 update app_private.pdf_uploads set finalized_at=clock_timestamp()-interval '8 days' where id=replacement;
 perform public.worker_claim_stale_pdf_uploads(50);
 perform test.assert((select state='abandoned' from app_private.pdf_uploads where id=replacement),'unused previous intent is retired');
 perform test.assert((select upload_id is null and upload_generation is null from app_private.pipeline_papers where id=paper),'retirement clears only its exact pin');
 perform test.assert((select sum(byte_count)=2000 from app_private.stored_objects where owner_id=a and state<>'deleted'),'deletion admission retains rejected and retired bytes');
 final_supply:=test.ready_upload(a,'import',initial,3);
 perform app_private.pipeline_set_stage(paper,'download');
 update app_private.pipeline_papers set claim_id=claim,generation=3,lease_until=clock_timestamp()+interval '10 minutes' where id=paper;
 result:=public.worker_pipeline_admit_download(paper,claim,3);
 perform test.assert(result->'upload'->>'id'=final_supply::text,'fresh supplied PDF replaces retired pin on new wanted intent');
end $$;

-- More than one bounded window of terminal receipts/unknown writes sorts
-- before a later expired upload. Only actionable work belongs in that window.
do $$
declare a uuid:=gen_random_uuid(); u uuid; obj uuid; w uuid; batch uuid; later uuid:='ffffffff-ffff-4fff-afff-ffffffffffff'; hash bytea:=decode(repeat('11',32),'hex'); j integer; result jsonb;
begin
 insert into auth.users values(a);
 perform public.worker_grant_credits(a,'adjustment','upload-cleanup-'||a,1000,now()-interval '1 day',null,'Cleanup fixture');
 for j in 1..102 loop
  u:=('00000000-0000-4000-a000-'||lpad(j::text,12,'0'))::uuid;
  insert into app_private.pdf_uploads(id,account_id,target,source_id,sha256,byte_count,chunk_bytes,part_count,request_sha256,state,expires_at)
   values(u,a,'paper','upload:'||u,hash,1,4194304,1,hash,'abandoned',clock_timestamp()-interval '1 day');
  obj:=gen_random_uuid();w:=gen_random_uuid();
  insert into app_private.stored_objects(id,bucket,path,owner_id,sha256,byte_count,state,media_type)
   values(obj,'paper-uploads',a||'/'||u||'/0/'||w||'.chunk',a,hash,1,case when j<=51 then 'deleted' else 'pending' end,'application/octet-stream');
  insert into app_private.pdf_upload_parts values(u,0,hash,1,null);
  insert into app_private.pdf_upload_write_attempts(id,upload_id,part_index,object_id,finished_at,evidence)
   values(w,u,0,obj,case when j<=51 then clock_timestamp() end,case when j<=51 then 'upload_response' end);
  if j<=51 then
   insert into app_private.pdf_upload_delete_batches(upload_id,completed_at) values(u,clock_timestamp()) returning id into batch;
   insert into app_private.pdf_upload_delete_members values(batch,obj);
  end if;
 end loop;
 perform public.worker_begin_pdf_upload(a,later,hash,1000,array[hash],'paper');
 w:=gen_random_uuid();perform public.worker_pdf_upload_write(a,later,1,0,w,hash,1000);perform public.worker_pdf_upload_written(w,hash,1000);
 update app_private.pdf_uploads set expires_at=clock_timestamp()-interval '1 minute' where id=later;
 result:=public.worker_claim_stale_pdf_uploads(50);
 perform test.assert(exists(select 1 from jsonb_array_elements(result) x join app_private.pdf_upload_delete_batches b on b.id=(x->>'batch_id')::uuid where b.upload_id=later),'clean and unknown cohorts do not starve later deletable upload');
 perform test.assert((select count(*)=51 from app_private.stored_objects where owner_id=a and state='pending'),'cleanup preserves every unknown physical liability');
 perform test.assert(not exists(select 1 from app_private.pdf_upload_holds where upload_id=later),'expired future holds released exactly once');
 -- A failed admission will not create a read receipt, yet the durable candidate
 -- schedule still moves past that account/cohort on the following sweep.
 update app_private.pdf_upload_write_attempts set started_at=clock_timestamp()-interval '20 minutes',reconciliation_after=clock_timestamp()-interval '1 minute' where upload_id in(select id from app_private.pdf_uploads where account_id=a) and finished_at is null;
 result:=public.worker_pdf_upload_reconciliation(3);
 perform test.assert(jsonb_array_length(result)=3,'bounded recovery window');
 perform test.assert(not exists(select 1 from jsonb_array_elements(result) old join jsonb_array_elements(public.worker_pdf_upload_reconciliation(3)) next on old->>'attempt_id'=next->>'attempt_id'),'discovery is paced even when later read admission never succeeds');
 perform test.assert((select count(*)=51 from app_private.pdf_upload_write_attempts where upload_id in(select id from app_private.pdf_uploads where account_id=a) and finished_at is null),'pacing does not settle unknown writes');
end $$;

-- Simulate a whole deletion window whose physical removals keep failing. Issue
-- paces those exact batches without releasing bytes, so a later eligible
-- session progresses on the following sweep. Confirmation bypasses pacing.
do $$
declare a uuid:=gen_random_uuid(); u uuid; obj uuid; w uuid; j integer; first_window jsonb; next_window jsonb;
 later uuid:='ffffffff-ffff-4fff-afff-fffffffffffe'; hash bytea:=decode(repeat('11',32),'hex'); before_bytes bigint;
begin
 insert into auth.users values(a);
 perform public.worker_grant_credits(a,'adjustment','upload-delete-progress-'||a,1000,now()-interval '1 day',null,'Delete progress fixture');
 for j in 1..51 loop
  u:=('00000000-0001-4000-a000-'||lpad(j::text,12,'0'))::uuid;
  insert into app_private.pdf_uploads(id,account_id,target,source_id,sha256,byte_count,chunk_bytes,part_count,request_sha256,state,expires_at)
   values(u,a,'paper','upload:'||u,hash,1,4194304,1,hash,'abandoned',clock_timestamp()-interval '1 day');
  obj:=gen_random_uuid();w:=gen_random_uuid();
  insert into app_private.stored_objects(id,bucket,path,owner_id,sha256,byte_count,state,media_type,verified_at)
   values(obj,'paper-uploads',a||'/'||u||'/0/'||w||'.chunk',a,hash,1,'verified','application/octet-stream',clock_timestamp());
  insert into app_private.pdf_upload_parts values(u,0,hash,1,obj);
  insert into app_private.pdf_upload_write_attempts(id,upload_id,part_index,object_id,finished_at,evidence)
   values(w,u,0,obj,clock_timestamp(),'upload_response');
 end loop;
 perform public.worker_begin_pdf_upload(a,later,hash,1000,array[hash],'paper');
 w:=gen_random_uuid();perform public.worker_pdf_upload_write(a,later,1,0,w,hash,1000);perform public.worker_pdf_upload_written(w,hash,1000);
 update app_private.pdf_uploads set expires_at=clock_timestamp()-interval '1 minute' where id=later;
 select sum(byte_count) into before_bytes from app_private.stored_objects where owner_id=a and state<>'deleted';
 first_window:=public.worker_claim_stale_pdf_uploads(50);
 perform test.assert(jsonb_array_length(first_window)=50,'filled removal window');
 next_window:=public.worker_claim_stale_pdf_uploads(50);
 perform test.assert(exists(select 1 from jsonb_array_elements(next_window) x join app_private.pdf_upload_delete_batches b on b.id=(x->>'batch_id')::uuid where b.upload_id=later),'failed removal cohort cannot starve later eligible deletion');
 perform test.assert(not exists(select 1 from jsonb_array_elements(first_window) f join jsonb_array_elements(next_window) n on f->>'batch_id'=n->>'batch_id'),'issued deletion batches are durably paced');
 perform test.assert((select sum(byte_count)=before_bytes from app_private.stored_objects where owner_id=a and state<>'deleted'),'issuing and retry scheduling release no physical bytes');
 perform test.assert(public.worker_confirm_pdf_uploads_deleted((first_window->0->>'batch_id')::uuid)=1,'positive confirmation is accepted while batch is paced');
 perform test.assert(public.worker_confirm_pdf_uploads_deleted((first_window->0->>'batch_id')::uuid)=0,'confirmation remains idempotent');
end $$;
rollback;
