-- 120: Server adds without duplicates (review A5, 2026-10-21). Design: docs/architecture/HTML_FIRST_READER.md
-- "Server adds without duplicates". Add by DOI/link/text (add-paper), a reference's Add to library (add-reference) and
-- chat Ingest begin an import only when the reader does not already have the paper: a visible import in
-- accepted/resolving/acquiring/source_only, or a visible library item whose catalog metadata names the source. The
-- check and the insert happen under the library locks, in one call, so concurrent adds of one paper insert once.
-- Additive: v2_begin_import, v2_begin_web_import and the v5 wrappers keep their contracts for existing clients.
begin;
set local lock_timeout='15s';

-- The presence check reads one account's live imports of one source (not its whole import history).
create index import_requests_account_source on app_private.import_requests(account_id, source_id) where desired_present;

-- What the reader already has for this source, if anything: {status:'present', kind, id}. Callers hold the account's
-- library locks. A failed, cancelled or conflicting import is not present (Add after a failure starts a new attempt).
create function app_private.library_source_present(a uuid, p_source_id text) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(
  (select jsonb_build_object('status','present','kind','import','id',i.id) from app_private.import_requests i
   where i.account_id=a and i.source_id=p_source_id and i.desired_present and i.phase in ('accepted','resolving','acquiring','source_only')
   order by i.created_seq desc limit 1),
  (select jsonb_build_object('status','present','kind','item','id',li.id) from app_private.library_items li
   join app_private.catalog_asset_approvals ca on ca.id=li.approval_id join app_private.catalog_metadata cm on cm.id=ca.metadata_id
   where li.account_id=a and li.removed_at is null and cm.source_id=p_source_id order by li.created_seq desc limit 1))
$$;

-- Begin an import of an arXiv paper (p_web false) or an open-access web paper (`openalex:W…`, p_web true) unless the
-- reader already has it. Replays its own receipt first (digest `server-add-v1`, never a client's v2_begin_import
-- receipt). Present answers without a receipt, change or capacity; otherwise the insert, checks and receipt are
-- exactly v2_begin_import's (010) / v2_begin_web_import's (019), with the account's current sequence as the observed
-- cursor (read under the lock: the server has seen the whole library).
create function public.v2_add_paper_once(p_operation_id uuid, p_source_id text, p_web boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); src text; digest bytea; replay jsonb; present jsonb; s bigint; head bigint;
 p app_private.library_policy;
begin
 if p_operation_id is null or p_web is null then raise exception 'invalid_import_request'; end if;
 src:=case when p_web then app_private.validate_web_source_id(p_source_id) else app_private.validate_arxiv_id(p_source_id) end;
 digest:=sha256(convert_to(jsonb_build_array('server-add-v1',p_web,src)::text,'UTF8'));
 perform public.worker_consume_request(a,'library-write'); perform app_private.lock_library_account(a); perform app_private.lock_library_state(a);
 replay:=app_private.library_replay(a,p_operation_id,digest); if replay is not null then return replay; end if;
 present:=app_private.library_source_present(a,src);
 if present is not null then return app_private.library_command_response(a,present,false); end if;
 select * into strict p from app_private.library_policy;
 perform app_private.library_check_receipt_capacity(a,true);
 if (select count(*) from app_private.import_requests where account_id=a)+1>p.account_imports then raise exception 'library_account_import_limit'; end if;
 if (select count(*) from app_private.import_requests)+1>p.environment_imports then raise exception 'library_environment_import_limit'; end if;
 if (select count(*) from app_private.import_requests where account_id=a and desired_present and phase in ('accepted','resolving','acquiring'))+1>p.account_active_imports
 or (select count(*) from app_private.import_requests where desired_present and phase in ('accepted','resolving','acquiring'))+1>p.environment_active_imports
 then raise exception 'library_active_import_limit'; end if;
 select last_seq into strict head from app_private.library_sync_state where account_id=a;
 s:=app_private.library_next_seq(a);
 insert into app_private.import_requests(account_id,id,request_sha256,source_id,requested_revision,observed_cursor,created_seq,state_seq)
 values(a,p_operation_id,digest,src,null,head,s,s);
 perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,p_operation_id)));
 return app_private.library_receipt(a,p_operation_id,digest,jsonb_build_object('status','applied','kind','import','id',p_operation_id,'seq',s,'revision',1));
end $$;

revoke all on function app_private.library_source_present(uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.v2_add_paper_once(uuid,text,boolean) from public,anon,authenticated,service_role;
grant execute on function public.v2_add_paper_once(uuid,text,boolean) to authenticated;
notify pgrst,'reload schema';
commit;
