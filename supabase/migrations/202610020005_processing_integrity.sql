begin;
-- Enforce file ownership even when a privileged worker makes a programming error.
create function app_private.check_artifact_objects() returns trigger language plpgsql set search_path = '' as $$
declare document uuid;
begin
 select document_id into strict document from app_private.ocr_runs where id=new.ocr_run_id;
 if not exists(select 1 from app_private.stored_objects where id=new.manifest_object_id
   and document_id=document and bucket='paper-assets' and state='verified') then raise exception 'artifact_object_mismatch'; end if;
 return new;
end $$;
create trigger artifact_object_integrity before insert or update on app_private.render_artifacts for each row execute function app_private.check_artifact_objects();
create function app_private.check_support_object() returns trigger language plpgsql set search_path = '' as $$
begin
 perform 1 from app_private.support_reports where id=new.report_id for update;
 if not exists(select 1 from app_private.stored_objects where id=new.object_id and owner_id=new.account_id
   and bucket='support' and state='verified' and byte_count<=5242880 and media_type in ('image/png','image/jpeg')) then raise exception 'support_object_mismatch'; end if;
 if (select count(*) from app_private.support_attachments where report_id=new.report_id and id<>new.id)>=5 then raise exception 'attachment_limit'; end if;
 return new;
end $$;
create trigger support_object_integrity before insert or update on app_private.support_attachments for each row execute function app_private.check_support_object();
create function public.worker_request_ocr(p_account_id uuid,p_document_id uuid,p_provider text,p_options_sha256 bytea,
 p_operation_id uuid,p_request_sha256 bytea,p_rate_version text,p_credits bigint,p_microusd bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d app_private.documents; o app_private.ocr_runs; j app_private.processing_jobs; artifact uuid;
begin
 -- One canonical-document lock chooses the funding requester before reservation.
 select * into d from app_private.documents where id=p_document_id and (scope='shared_catalog' or owner_id=p_account_id) for update;
 if not found then raise exception 'document_unavailable' using errcode='42501'; end if;
 insert into app_private.ocr_runs(document_id,provider,options_sha256) values(d.id,p_provider,p_options_sha256)
   on conflict(document_id,provider,options_sha256) do nothing;
 select * into strict o from app_private.ocr_runs where document_id=d.id and provider=p_provider and options_sha256=p_options_sha256;
 insert into app_private.library_items(account_id,document_id) values(p_account_id,d.id)
   on conflict(account_id,document_id) do update set removed_at=null;
 select id into artifact from app_private.render_artifacts where ocr_run_id=o.id order by ready_at desc limit 1;
 if found then return jsonb_build_object('state','ready','artifact_id',artifact,'funding_requester',false); end if;
 select * into j from app_private.processing_jobs where ocr_run_id=o.id;
 if found then
  insert into app_private.job_requests(job_id,account_id) values(j.id,p_account_id) on conflict do nothing;
  return jsonb_build_object('state',j.state,'job_id',j.id,'funding_requester',j.funding_account_id=p_account_id);
 end if;
 perform public.worker_reserve_operation(p_account_id,p_operation_id,'ocr',p_request_sha256,p_rate_version,p_credits,p_microusd);
 insert into app_private.processing_jobs(ocr_run_id,funding_account_id,operation_id) values(o.id,p_account_id,p_operation_id) returning * into j;
 insert into app_private.job_requests(job_id,account_id) values(j.id,p_account_id);
 return jsonb_build_object('state',j.state,'job_id',j.id,'funding_requester',true);
end $$;
revoke all on function public.worker_request_ocr(uuid,uuid,text,bytea,uuid,bytea,text,bigint,bigint) from public,anon,authenticated;
grant execute on function public.worker_request_ocr(uuid,uuid,text,bytea,uuid,bytea,text,bigint,bigint) to service_role;
revoke all on all functions in schema app_private from public,anon,authenticated;
commit;
