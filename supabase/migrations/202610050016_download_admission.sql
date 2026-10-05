-- Admission before any original PDF download (security review): the paper
-- store has an environment byte/object cap, private conversions have a
-- per-owner byte quota, and a private download requires the owner to hold
-- credits (a private copy can never be reused by anyone else). Also narrows
-- the arXiv search rate so a few accounts cannot starve shared arXiv pacing.
begin;

update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,5368709120),max_objects=greatest(max_objects,50000) where singleton;
alter table app_private.pipeline_policy add column private_bytes_per_owner bigint not null default 1073741824 check(private_bytes_per_owner>0);

create function public.worker_pipeline_admit_download(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; pol app_private.pipeline_policy; cap app_private.paper_storage_capacity; used bigint; objects bigint;
 owner_bytes bigint; available bigint;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'download' then raise exception 'invalid_pipeline_stage'; end if;
 select * into strict pol from app_private.pipeline_policy;
 select * into strict cap from app_private.paper_storage_capacity where singleton;
 select coalesce(sum(byte_count),0),count(*) into used,objects from app_private.stored_objects where bucket='paper-assets' and state<>'deleted';
 if used+pol.max_pdf_bytes>cap.max_bytes or objects+64>cap.max_objects then
  update app_private.pipeline_papers set next_attempt_at=clock_timestamp()+interval '1 hour',error_code='storage_full' where id=p.id;
  return jsonb_build_object('admitted',false,'reason','storage_full');
 end if;
 if p.owner_id is not null then
  select coalesce(sum(o.byte_count),0) into owner_bytes from app_private.stored_objects o join app_private.documents d on d.id=o.document_id
   where d.owner_id=p.owner_id and o.state<>'deleted';
  select coalesce(sum(balance-reserved) filter(where revoked_at is null and starts_at<=now() and (expires_at is null or expires_at>now())),0)
   into available from app_private.credit_buckets where account_id=p.owner_id;
  if owner_bytes+pol.max_pdf_bytes>pol.private_bytes_per_owner then
   perform app_private.pipeline_set_stage(p.id,'failed','too_large','download');
   return jsonb_build_object('admitted',false,'reason','owner_quota');
  end if;
  if available<1 then
   perform app_private.pipeline_set_stage(p.id,'needs_credits','insufficient_credits','download');
   return jsonb_build_object('admitted',false,'reason','needs_credits');
  end if;
 end if;
 return jsonb_build_object('admitted',true);
end $$;
revoke all on function public.worker_pipeline_admit_download(uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function public.worker_pipeline_admit_download(uuid,uuid,bigint) to service_role;

update app_private.api_rate_rules set account_limit=60,environment_limit=600 where route='discover';
notify pgrst,'reload schema';
commit;
