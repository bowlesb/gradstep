-- Server paper copies retired (owner, 2026-10-16: "Yes, we can even delete them now, so it's obvious we have zero on
-- our system"). Design: docs/architecture/DATA_HANDLING_AND_COSTS.md "Server paper copies: retired".
--
-- Every PDF, Mathpix output and server reader bundle in the paper buckets (paper-assets: originals/, private/<account>/
-- originals/, raw/<sha>/, reader/<sha>/; paper-uploads: PDF upload chunks) is a leftover of the server PDF pipeline that
-- migration 058 fenced. This migration adds the operator's retirement, not the deletion itself:
--  1. worker_paper_copies_retire: switches the fence on, marks every paper copy's availability unavailable (reason
--     missing; the retirement row records why) and schedules every tracked paper-copy object for deletion
--     (verified/pending -> deleting, the lifecycle account deletion already uses), returning a page of them;
--     scripts/delete-paper-copies.mjs removes them from Storage, then worker_paper_copies_deleted confirms (-> deleted).
--  2. worker_paper_copies_project: library items whose projection still says available are recomputed and emitted
--     (render/original availability unavailable at a newer revision; artifact and original ids kept). Builds 57-60
--     then stop asking reader-artifact (prefetch and fallback need render_availability available), a legacy arXiv
--     item still opens from arXiv on the device, a copy already installed on a device keeps opening, and a non-arXiv
--     item says it has no reading copy on the server.
--  3. The fence: once retired, no paper-copy object can be registered again (insert or a return to pending/verified).
--  4. Chat on a legacy item whose server text is gone answers document_unavailable (it answered
--     asset_inventory_incomplete, a generic "service unavailable", once the inventory was enforced).
--  5. worker_paper_copies_status: the scheduled storage.no-papers check's view of the tracked rows.
--  6. worker_local_chat_context also accepts a legacy arXiv library item, so a client can ask about it from the text
--     prepared on the device (the browser does from this release; builds 57-60 still send the document id).
-- Rows are kept: documents, artifacts, OCR runs, manifests and their members, library items and the ledger stay as
-- history (accounting, provider attempts, encrypted chat bindings). Only the objects' state and availability change.
-- Reader delivery, podcast pins and grant redemption already require a verified object, so they answer
-- reader_unavailable, source_unavailable and reader_grant_unavailable.
begin;
set local lock_timeout='15s';

create table app_private.paper_copy_retirement (
 singleton boolean primary key default true check(singleton),
 retired_at timestamptz,
 completed_at timestamptz,
 objects_deleted bigint not null default 0 check(objects_deleted>=0),
 bytes_deleted bigint not null default 0 check(bytes_deleted>=0),
 check(completed_at is null or retired_at is not null)
);
insert into app_private.paper_copy_retirement default values;
alter table app_private.paper_copy_retirement enable row level security;
revoke all on app_private.paper_copy_retirement from public,anon,authenticated;
comment on table app_private.paper_copy_retirement is
 'Server paper copies (paper-assets, paper-uploads) retired: once retired_at is set, no paper-copy object may be registered again.';

-- The paper-copy buckets. Podcast audio (podcast-assets), the text a device sends for an episode (private-content)
-- and report attachments (support) are not paper copies and are never touched here.
create function app_private.paper_copy_bucket(p_bucket text) returns boolean language sql immutable set search_path='' as $$
 select p_bucket in ('paper-assets','paper-uploads')
$$;

-- 3. The fence.
create function app_private.paper_copies_fence() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if app_private.paper_copy_bucket(new.bucket) and new.state in ('pending','verified')
  and (tg_op='INSERT' or old.state is distinct from new.state)
  and exists(select 1 from app_private.paper_copy_retirement where singleton and retired_at is not null)
 then raise exception 'paper_copies_retired' using errcode='42501'; end if;
 return new;
end $$;
create trigger paper_copies_fence before insert or update of state on app_private.stored_objects
 for each row execute function app_private.paper_copies_fence();

-- 1. Retire: the fence goes on, every paper copy's availability becomes unavailable at a new revision, every tracked
-- paper copy is scheduled for deletion, and a page of the scheduled ones is returned for Storage. Refused while any
-- paper write's outcome is unknown (a late upload could recreate a file). Repeating it returns the next page.
create function public.worker_paper_copies_retire(p_limit integer default 500) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.paper_copy_retirement; scheduled integer; marked integer:=0; objects jsonb; o record;
begin
 if p_limit is null or p_limit not between 1 and 1000 then raise exception 'invalid_limit'; end if;
 -- mark_paper_availability's order: storage capacity, then the documents, then objects and availability.
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if exists(select 1 from app_private.paper_asset_write_attempts where finished_at is null)
  or exists(select 1 from app_private.pdf_upload_write_attempts where finished_at is null)
 then raise exception 'asset_write_uncertain'; end if;
 perform 1 from app_private.documents d where exists(select 1 from app_private.stored_objects s where s.document_id=d.id
  and app_private.paper_copy_bucket(s.bucket)) order by d.id for update;
 select * into strict r from app_private.paper_copy_retirement where singleton for update;
 update app_private.paper_copy_retirement set retired_at=coalesce(retired_at,clock_timestamp()) where singleton returning * into r;
 for o in select a.object_id from app_private.paper_asset_availability a join app_private.stored_objects s on s.id=a.object_id
  where s.bucket='paper-assets' and a.state<>'unavailable' order by a.object_id loop
  perform app_private.mark_paper_availability(o.object_id,'unavailable','missing');
  marked:=marked+1;
 end loop;
 update app_private.stored_objects set state='deleting'
  where app_private.paper_copy_bucket(bucket) and state in ('pending','verified');
 get diagnostics scheduled=row_count;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'bucket',x.bucket,'path',x.path,'bytes',x.byte_count) order by x.bucket,x.path),'[]'::jsonb)
  into objects from (select * from app_private.stored_objects where app_private.paper_copy_bucket(bucket) and state='deleting'
   order by bucket,path limit p_limit) x;
 return jsonb_build_object('retired_at',r.retired_at,'availability_marked',marked,'scheduled',scheduled,'objects',objects,
  'deleting',(select count(*) from app_private.stored_objects where app_private.paper_copy_bucket(bucket) and state='deleting'));
end $$;

-- 2. Library projections that still differ from the objects' state are recomputed and emitted, a page at a time
-- (worker_project_library_availability: the account, the document, then the library state; one item per call).
create function public.worker_paper_copies_project(p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare i record; n integer:=0; remaining integer;
begin
 if p_limit is null or p_limit not between 1 and 500 then raise exception 'invalid_limit'; end if;
 if not exists(select 1 from app_private.paper_copy_retirement where singleton and retired_at is not null) then
  raise exception 'paper_copies_not_retired'; end if;
 for i in select ap.account_id,ap.item_id from app_private.library_asset_projection ap
  where ap.render_availability='available' or ap.original_availability='available'
  order by ap.account_id,ap.item_id limit p_limit loop
  perform public.worker_project_library_availability(i.account_id,i.item_id);
  n:=n+1;
 end loop;
 select count(*) into remaining from app_private.library_asset_projection where render_availability='available' or original_availability='available';
 return jsonb_build_object('projected',n,'remaining',remaining);
end $$;

-- After Storage confirms the objects are gone: deleting -> deleted. Completion is recorded once nothing is left.
create function public.worker_paper_copies_deleted(p_object_ids uuid[]) returns jsonb
language plpgsql security definer set search_path='' as $$
declare n integer; bytes bigint; r app_private.paper_copy_retirement;
begin
 if p_object_ids is null or cardinality(p_object_ids) not between 1 and 1000 then raise exception 'invalid_limit'; end if;
 select * into strict r from app_private.paper_copy_retirement where singleton for update;
 if r.retired_at is null then raise exception 'paper_copies_not_retired'; end if;
 with done as (update app_private.stored_objects set state='deleted'
  where id=any(p_object_ids) and app_private.paper_copy_bucket(bucket) and state='deleting' returning byte_count)
 select count(*),coalesce(sum(byte_count),0) into n,bytes from done;
 update app_private.paper_copy_retirement set objects_deleted=objects_deleted+n,bytes_deleted=bytes_deleted+bytes,
  completed_at=case when not exists(select 1 from app_private.stored_objects where app_private.paper_copy_bucket(bucket)
   and state in ('pending','verified','deleting')) then coalesce(completed_at,clock_timestamp()) end
  where singleton returning * into r;
 return jsonb_build_object('confirmed',n,'bytes',bytes,'completed_at',r.completed_at);
end $$;

-- 5. What the database tracks in the paper-copy buckets, by bucket and state (counts and bytes only; no paths).
create function public.worker_paper_copies_status() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'retired_at',(select retired_at from app_private.paper_copy_retirement where singleton),
  'completed_at',(select completed_at from app_private.paper_copy_retirement where singleton),
  'objects_deleted',(select objects_deleted from app_private.paper_copy_retirement where singleton),
  'bytes_deleted',(select bytes_deleted from app_private.paper_copy_retirement where singleton),
  'tracked',coalesce((select jsonb_agg(jsonb_build_object('bucket',bucket,'state',state,'objects',n,'bytes',b) order by bucket,state)
   from (select bucket,state,count(*) n,sum(byte_count) b from app_private.stored_objects where app_private.paper_copy_bucket(bucket)
    group by bucket,state) t),'[]'::jsonb),
  'live',(select count(*) from app_private.stored_objects where app_private.paper_copy_bucket(bucket) and state in ('pending','verified','deleting')),
  'open_writes',(select count(*) from app_private.paper_asset_write_attempts where finished_at is null)
   +(select count(*) from app_private.pdf_upload_write_attempts where finished_at is null))
$$;

-- 4. Chat on a legacy document-backed item: no verified server text means the paper is unavailable for questions
-- (the same answer as a paper outside the library), never the inventory's generic failure.
alter function public.worker_chat_context(uuid,uuid) rename to worker_chat_context_before_080;
alter function public.worker_chat_context_before_080(uuid,uuid) set schema app_private;
create function public.worker_chat_context(p_account_id uuid,p_document_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare descriptor jsonb;
begin
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended for key share;
 if not found then raise exception 'account_unavailable'; end if;
 descriptor:=app_private.worker_chat_context(p_account_id,p_document_id);
 if not exists(select 1 from app_private.stored_objects where bucket=descriptor->>'bucket' and path=descriptor->>'path'
  and document_id=p_document_id and state='verified') then raise exception 'document_unavailable' using errcode='42501'; end if;
 return app_private.worker_chat_context_before_080(p_account_id,p_document_id);
end $$;

-- 6. With its server text gone, a legacy arXiv item can still be asked about from the text its reader prepared on the
-- device: the same local context a source membership sends, naming the library item as its membership. The item's
-- catalog record pins the exact source and revision; the text stays untrusted input, as for a membership.
alter function public.worker_local_chat_context(uuid,uuid,text,integer) rename to worker_local_chat_context_before_080;
alter function public.worker_local_chat_context_before_080(uuid,uuid,text,integer) set schema app_private;
create function public.worker_local_chat_context(p_account_id uuid,p_membership_id uuid,p_source_id text,p_revision integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 select jsonb_build_object('title',cm.metadata->>'title') into result
 from app_private.library_items li join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
 join app_private.catalog_metadata cm on cm.id=ca.metadata_id
 join app_private.accounts a on a.id=li.account_id and a.closed_at is null
 where li.account_id=p_account_id and li.id=p_membership_id and li.removed_at is null
  and cm.source_id=p_source_id and cm.source_revision=p_revision and cm.source_id !~ '^(openalex|upload):';
 if result is not null then return result; end if;
 return app_private.worker_local_chat_context_before_080(p_account_id,p_membership_id,p_source_id,p_revision);
end $$;

revoke all on function app_private.paper_copy_bucket(text),app_private.paper_copies_fence(),
 app_private.worker_chat_context_before_080(uuid,uuid),app_private.worker_local_chat_context_before_080(uuid,uuid,text,integer) from public,anon,authenticated,service_role;
revoke all on function public.worker_paper_copies_retire(integer),public.worker_paper_copies_project(integer),public.worker_paper_copies_deleted(uuid[]),
 public.worker_paper_copies_status(),public.worker_chat_context(uuid,uuid),public.worker_local_chat_context(uuid,uuid,text,integer) from public,anon,authenticated;
grant execute on function public.worker_paper_copies_retire(integer),public.worker_paper_copies_project(integer),public.worker_paper_copies_deleted(uuid[]),
 public.worker_paper_copies_status(),public.worker_chat_context(uuid,uuid),public.worker_local_chat_context(uuid,uuid,text,integer) to service_role;
notify pgrst,'reload schema';
commit;
