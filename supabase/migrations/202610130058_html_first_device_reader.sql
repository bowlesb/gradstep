-- HTML-first device reader. Operational admission fences, not a legacy data
-- migration: no original, artifact, provider attempt or reservation is deleted.
-- Design: docs/architecture/HTML_FIRST_READER.md (implementation contract).
begin;
set local lock_timeout='15s';

-- Keep outstanding attempts/physical writes accounted for. Never re-enable PDF
-- processing during rollback; operators may pause metadata imports instead.
update app_private.pdf_upload_policy set enabled=false where singleton;
update app_private.pipeline_papers set generation=generation+1, claim_id=null, lease_until=null
 where lease_until is not null;

alter table app_private.import_requests add column source_archived boolean not null default false;
alter table app_private.import_requests add column source_tags text[] not null default '{}';
alter table app_private.import_requests add constraint source_tags_valid check(app_private.valid_tag_list(source_tags,32));

alter function app_private.library_import_entry(uuid,uuid) rename to library_import_entry_before_058;
create function app_private.library_import_entry(a uuid,p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select app_private.library_import_entry_before_058(a,p_id)
  ||case when i.desired_present and i.source_archived then jsonb_build_object('archived',true) else '{}'::jsonb end
  ||case when i.desired_present and cardinality(i.source_tags)>0 then jsonb_build_object('user_tags',to_jsonb(i.source_tags)) else '{}'::jsonb end
 from app_private.import_requests i where i.account_id=a and i.id=p_id
$$;

create function public.v5_set_source_details(p_dataset_epoch uuid,p_operation_id uuid,p_import_id uuid,
 p_archived boolean,p_tags text[],p_expected_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); epoch uuid:=app_private.library_command_epoch(p_dataset_epoch,false);
 digest bytea; replay jsonb; i app_private.import_requests; s bigint; result jsonb;
begin
 if p_archived is null or p_tags is null or not app_private.valid_tag_list(p_tags,32) or p_expected_revision is null or p_expected_revision<1
 then raise exception 'invalid_source_command'; end if;
 digest:=sha256(convert_to(jsonb_build_array('source-details-v1',p_import_id,p_archived,p_tags,p_expected_revision)::text,'UTF8'));
 perform public.worker_consume_request(a,'library-write'); perform app_private.lock_library_account(a); perform app_private.lock_library_state(a);
 replay:=app_private.library_replay(a,p_operation_id,digest);
 if replay is not null then result:=replay;
 else
  select * into i from app_private.import_requests where account_id=a and id=p_import_id;
  if not found then raise exception 'document_unavailable' using errcode='42501'; end if;
  perform app_private.library_check_receipt_capacity(a,false);
  if not i.desired_present or i.phase<>'source_only' then raise exception 'document_unavailable' using errcode='42501'; end if;
  if i.intent_revision<>p_expected_revision then
   result:=app_private.library_receipt(a,p_operation_id,digest,jsonb_build_object('status','revision_conflict','kind','import','id',i.id,'revision',i.intent_revision));
  else
   s:=app_private.library_next_seq(a);
   update app_private.import_requests set source_archived=p_archived,source_tags=p_tags,intent_revision=intent_revision+1,state_seq=s where account_id=a and id=i.id;
   perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,i.id)));
   result:=app_private.library_receipt(a,p_operation_id,digest,jsonb_build_object('status','applied','kind','import','id',i.id,'seq',s,'revision',p_expected_revision+1));
  end if;
 end if;
 epoch:=app_private.library_command_epoch(p_dataset_epoch,true);
 return result||jsonb_build_object('dataset_epoch',epoch);
end $$;

create function public.worker_local_chat_context(p_account_id uuid,p_membership_id uuid,p_source_id text,p_revision integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 select jsonb_build_object('title',cm.metadata->>'title') into result
 from app_private.import_requests i join app_private.catalog_metadata cm on cm.id=i.metadata_id
 join app_private.accounts a on a.id=i.account_id and a.closed_at is null
 where i.account_id=p_account_id and i.id=p_membership_id and i.desired_present and i.phase='source_only'
  and i.source_id=p_source_id and cm.source_id=p_source_id and cm.source_revision=p_revision;
 if result is null then raise exception 'document_unavailable' using errcode='42501'; end if;
 return result;
end $$;

create or replace function public.worker_pipeline_metadata(
 p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_revision integer,p_metadata jsonb,
 p_eligible boolean,p_license_uri text default null,p_evidence jsonb default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; meta uuid; private_permission boolean; next_stage text; mode text;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'metadata' then raise exception 'invalid_pipeline_stage'; end if;
 if p.source_id like 'openalex:%' or p.source_id like 'upload:%' then raise exception 'invalid_arxiv_id'; end if;
 if p.owner_id is not null or p_eligible is null or p_revision is null or (p.requested_revision>0 and p_revision<>p.requested_revision)
  or (p_eligible and (p_license_uri is null or p_evidence is null)) then raise exception 'invalid_pipeline_metadata'; end if;
 private_permission:=not p_eligible and p_evidence is not null and jsonb_typeof(p_evidence)='object'
  and length(coalesce(p_evidence->>'private_permission','')) between 1 and 512;
 if not p_eligible and private_permission and p_evidence->>'private_permission' !~ '^[A-Za-z0-9._:/ -]+$' then
  raise exception 'invalid_pipeline_metadata';
 end if;
 meta:=public.worker_record_arxiv_metadata(p.source_id,p_revision,p_metadata);
 next_stage:='source_only';
 mode:=case when p_eligible then 'shared' when private_permission then 'private' else 'source_only' end;
 update app_private.pipeline_papers set revision=p_revision,metadata_id=meta,eligible=p_eligible,rights_mode=mode,
  license_uri=case when p_eligible or (length(p_license_uri)<=512 and p_license_uri ~ '^https?://[A-Za-z0-9.-]+/[ -~]*$') then p_license_uri
   else 'https://arxiv.org/abs/'||p.source_id||'v'||p_revision end,
  evidence=case when p_eligible or private_permission then p_evidence else null end where id=p.id;
 perform app_private.pipeline_set_stage(p.id,next_stage,null);
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

create or replace function public.worker_pipeline_web_metadata(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_metadata jsonb,
 p_doi text,p_pdf_urls text[],p_landing_url text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; meta uuid; landing text;
begin
 p:=app_private.pipeline_fenced(p_paper_id,p_claim_id,p_generation);
 if p.stage<>'metadata' then raise exception 'invalid_pipeline_stage'; end if;
 if p.owner_id is not null or p.source_id not like 'openalex:%' or p_pdf_urls is null
  or (cardinality(p_pdf_urls)>0 and not app_private.web_urls_ok(p_pdf_urls)) or array_ndims(p_pdf_urls)>1
 then raise exception 'invalid_pipeline_metadata'; end if;
 meta:=app_private.record_web_metadata(p.source_id,p_metadata,p_doi);
 landing:=case when length(p_landing_url)<=512 and app_private.web_url_ok(p_landing_url) then p_landing_url
  else 'https://openalex.org/works/'||substr(p.source_id,10) end;
 update app_private.pipeline_papers set revision=1,metadata_id=meta,eligible=false,rights_mode='private',license_uri=landing,evidence=null,
  pdf_urls=case when cardinality(p_pdf_urls)>0 then p_pdf_urls end,landing_url=landing where id=p.id;
 perform app_private.pipeline_set_stage(p.id,'source_only');
 select * into p from app_private.pipeline_papers where id=p.id;
 return app_private.pipeline_entry(p);
end $$;

create or replace function public.worker_pipeline_sync_imports(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns integer
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; link record; i app_private.import_requests; s bigint; changed integer:=0; target text; err text; retry boolean;
 acct uuid; ready uuid[]:='{}';
begin
 select * into p from app_private.pipeline_papers where id=p_paper_id;
 if not found or p.claim_id is distinct from p_claim_id or p.generation is distinct from p_generation or p.lease_until<=clock_timestamp()
 then raise exception 'stale_pipeline_claim'; end if;
 for acct in select distinct pi.account_id from app_private.pipeline_imports pi where pi.paper_id=p.id and pi.synced_revision<p.state_revision
  and pi.next_sync_at<=clock_timestamp() order by pi.account_id loop
  begin
   perform public.worker_consume_request(acct,'library-write');
   ready:=ready||acct;
  exception when others then
   update app_private.pipeline_imports set sync_failures=sync_failures+1,
    next_sync_at=clock_timestamp()+make_interval(secs=>least(3600,15*power(2,least(sync_failures,8))::integer))
    where paper_id=p.id and account_id=acct;
  end;
 end loop;
 perform 1 from app_private.accounts where id=any(ready) and closed_at is null order by id for no key update;
 for link in select pi.* from app_private.pipeline_imports pi where pi.paper_id=p.id and pi.synced_revision<p.state_revision
  and pi.account_id=any(ready) order by pi.account_id,pi.import_id loop
  begin
   select * into i from app_private.import_requests where account_id=link.account_id and id=link.import_id;
   if i.desired_present and i.phase in ('accepted','resolving','acquiring') then
    if true then
     target:=case when p.metadata_id is not null then 'source_only' when p.stage='metadata' then 'resolving'
      when p.stage in ('private_split','download','ocr_fund','ocr_submit','ocr_wait','ocr_uncertain','render') then 'acquiring'
      when p.stage='source_only' then 'source_only' else 'failed' end;
     err:=case when p.metadata_id is not null then null when p.stage='needs_credits' then 'insufficient_credits'
      when p.stage='failed' then case when p.auto_retry_at is not null and p.resume_stage='download' then 'download_retrying'
       when p.error_code in ('metadata_unavailable','download_failed','pdf_invalid','rate_limited','too_large','conversion_failed',
        'source_unavailable','source_blocked','not_pdf','pdf_restricted','not_open','upload_failed') then p.error_code
       when p.resume_stage='metadata' then 'metadata_unavailable' when p.resume_stage='download' then 'download_failed' else 'conversion_failed' end end;
     retry:=p.metadata_id is null and p.stage='failed' and p.resume_stage='metadata';
     perform app_private.lock_library_account(i.account_id); perform app_private.lock_library_state(i.account_id);
     select * into strict i from app_private.import_requests where account_id=link.account_id and id=link.import_id;
     if i.desired_present and i.phase in ('accepted','resolving','acquiring') then
      s:=app_private.library_next_seq(i.account_id);
      update app_private.import_requests set phase=target,metadata_id=coalesce(metadata_id,p.metadata_id),state_seq=s,
       error_code=err,retryable=coalesce(retry,false),progress=coalesce(app_private.pipeline_progress(p.stage),progress),
       auto_retry_at=case when target='failed' then p.auto_retry_at end
       where account_id=i.account_id and id=i.id;
      perform app_private.library_emit(i.account_id,s,jsonb_build_array(app_private.library_import_entry(i.account_id,i.id)));
     end if;
    end if;
    changed:=changed+1;
   end if;
   update app_private.pipeline_imports set synced_revision=p.state_revision,sync_failures=0 where account_id=link.account_id and import_id=link.import_id;
  exception when others then
   update app_private.pipeline_imports set sync_failures=sync_failures+1,
    next_sync_at=clock_timestamp()+make_interval(secs=>least(3600,15*power(2,least(sync_failures,8))::integer))
    where account_id=link.account_id and import_id=link.import_id;
  end;
 end loop;
 return changed;
end $$;

create or replace function public.worker_pipeline_claim(p_claim_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare pol app_private.pipeline_policy; p app_private.pipeline_papers;
begin
 if p_claim_id is null then raise exception 'invalid_claim'; end if;
 select * into strict pol from app_private.pipeline_policy;
 if not pol.enabled then return null; end if;
 select pp.* into p from app_private.pipeline_papers pp
 where (pp.lease_until is null or pp.lease_until<=clock_timestamp()) and (
  (pp.stage='metadata' and pp.next_attempt_at<=clock_timestamp() and app_private.pipeline_interest(pp.id))
  or exists(select 1 from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
   where pi.paper_id=pp.id and i.desired_present and i.phase in ('accepted','resolving','acquiring')
   and (pi.synced_revision<pp.state_revision or pi.retry_requested) and pi.next_sync_at<=clock_timestamp()))
 order by pp.next_attempt_at,pp.id limit 1 for no key update skip locked;
 if not found then return null; end if;
 if p.stage='failed' and p.resume_stage='metadata' and exists(select 1 from app_private.pipeline_imports where paper_id=p.id and retry_requested) then
  perform app_private.pipeline_set_stage(p.id,'metadata');
 end if;
 update app_private.pipeline_imports set retry_requested=false where paper_id=p.id;
 update app_private.pipeline_papers set generation=generation+1,claim_id=p_claim_id,stage_claims=stage_claims+1,
  lease_until=clock_timestamp()+make_interval(secs=>pol.lease_seconds),updated_at=now() where id=p.id returning * into p;
 return app_private.pipeline_entry(p);
end $$;
-- New encrypted source identities require an explicit reader generation.
alter table app_private.sync_events drop constraint sync_events_format_check;
alter table app_private.sync_events add constraint sync_events_format_check check(format in (1,2));
alter function public.v2_pull_events(bigint,integer) rename to v3_pull_events;
create function public.v2_pull_events(p_after bigint,p_limit integer default 200) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=public.v3_pull_events(p_after,p_limit);
 if exists(select 1 from jsonb_array_elements(result->'events') e where (e->>'format')::integer<>1)
 then raise exception 'reader_update_required'; end if;
 return result;
end $$;
create or replace function public.v1_pull_events(p_after bigint,p_limit integer default 200) returns jsonb
language plpgsql security definer set search_path='' as $$
declare page jsonb;
begin
 page:=public.v2_pull_events(p_after,p_limit);
 if (page->>'has_more')::boolean and jsonb_array_length(page->'events')<p_limit then raise exception 'sync_page_too_large'; end if;
 return page->'events';
end $$;

-- Block new admission even from an old running worker. Observation/settlement
-- RPCs remain available for existing physical/provider liabilities.
do $fence$
declare f record;
begin
 for f in select pg_get_function_arguments(p.oid) args,pg_get_function_result(p.oid) result,p.proname
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=any(array[
   'worker_prepare_original','worker_reserve_original','worker_mark_original_uploading',
   'worker_claim_original_verification','worker_publish_original','worker_authorize_original_read','v2_original_descriptor',
   'worker_pipeline_split_private','worker_pipeline_original','worker_pipeline_upload_original',
   'worker_pipeline_fund','worker_pipeline_begin_submit','worker_pipeline_asset_plan','worker_pipeline_asset_write','worker_pipeline_published',
   'worker_request_ocr','worker_claim_job',
   'worker_begin_pdf_upload','worker_pdf_upload_part','worker_pdf_upload_write','worker_freeze_pdf_upload',
   'worker_finalize_pdf_upload','worker_pdf_upload_read'
  ]) loop
  execute format('create or replace function public.%I(%s) returns %s language plpgsql security definer set search_path='''' as $body$ begin raise exception ''pdf_device_only'' using errcode=''42501''; end $body$',f.proname,f.args,f.result);
 end loop;
end $fence$;
alter table app_private.pdf_upload_policy add constraint pdf_device_only check(not enabled);

alter function public.v1_reader_capabilities() rename to reader_capabilities_before_058;
alter function public.reader_capabilities_before_058() set schema app_private;
create function public.v1_reader_capabilities() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 return app_private.reader_capabilities_before_058()||jsonb_build_object('device_reader',
  jsonb_build_object('protocol','source-membership-v1','source','arxiv-html','private_event_format',2,'pdfs','device-only'));
end $$;

revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
revoke all on function public.worker_local_chat_context(uuid,uuid,text,integer) from public,anon,authenticated,service_role;
grant execute on function public.worker_local_chat_context(uuid,uuid,text,integer) to service_role;
revoke all on function public.v5_set_source_details(uuid,uuid,uuid,boolean,text[],bigint),public.v3_pull_events(bigint,integer),
 public.v2_pull_events(bigint,integer),public.v1_reader_capabilities() from public,anon,authenticated,service_role;
grant execute on function public.v5_set_source_details(uuid,uuid,uuid,boolean,text[],bigint),public.v3_pull_events(bigint,integer),
 public.v2_pull_events(bigint,integer),public.v1_reader_capabilities() to authenticated;
notify pgrst,'reload schema';
commit;
