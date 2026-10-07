-- Archive (owner request 2026-10-06: "why can't I delete or archive references?"):
-- an archived library item stays in the library (and synced across devices) but
-- is hidden from the default list. Additive over 010/011/019.
--
-- Wire: item entries gain a top-level `archived: true` only while archived, so a
-- non-archived item's JSON is unchanged at every state_seq (installed builds and
-- caches compare entries at equal state_seq; builds before this ignore the key).
-- An archive change is a membership change for revision purposes: it bumps
-- membership_revision and state_seq, so concurrent Remove/Archive commands made
-- from an older revision get a revision_conflict receipt.
begin;
set local lock_timeout='15s';

alter table app_private.library_items add column archived_at timestamptz;

-- 019's item entry, plus `archived` (only when true).
create or replace function app_private.library_item_entry(a uuid,p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind','item','id',li.id,'document_id',li.document_id,'created_seq',li.created_seq,'state_seq',li.state_seq,
  'membership_revision',li.membership_revision,'visible',li.removed_at is null,'added_at',li.added_at,
  'last_remove_seq',li.last_remove_seq,'approval_id',li.approval_id,'version_id',ca.version_id,'metadata_id',cm.id,
  'source',case when cm.id is null then null when cm.source_id like 'openalex:%' then 'web' else 'arxiv' end,'source_id',cm.source_id,'source_revision',cm.source_revision,
  'metadata',cm.metadata,'metadata_recorded_at',cm.recorded_at,
  'source_url',case when cm.id is null then null when cm.source_id like 'openalex:%' then ca.evidence->>'source_url'
   else 'https://arxiv.org/abs/'||cm.source_id||'v'||cm.source_revision end,
  'scope',d.scope,'page_count',d.page_count,'original_object_id',ca.original_object_id,'artifact_id',li.artifact_id,
  'original_availability',coalesce(ap.original_availability,'unverified'),'render_availability',coalesce(ap.render_availability,'unverified'),
  'original_availability_revision',coalesce(ap.original_availability_revision,0),'render_availability_revision',coalesce(ap.render_availability_revision,0),
  'readiness',case when ap.render_availability='available' then 'converted_ready' when ap.original_availability='available' then 'pdf_ready'
   when ca.id is not null or li.artifact_id is not null then 'unavailable' else 'unverified' end)
  ||case when li.archived_at is not null and li.removed_at is null then jsonb_build_object('archived',true) else '{}'::jsonb end
 from app_private.library_items li join app_private.documents d on d.id=li.document_id
 left join app_private.catalog_asset_approvals ca on ca.id=li.approval_id left join app_private.catalog_metadata cm on cm.id=ca.metadata_id
 left join app_private.library_asset_projection ap on (ap.account_id,ap.item_id)=(li.account_id,li.id) where li.account_id=a and li.id=p_id
$$;

-- Removing an item clears its archive mark, so a later re-add starts unarchived.
create function app_private.clear_archive_on_remove() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.removed_at is not null and old.removed_at is null then new.archived_at:=null; end if;
 return new;
end $$;
create trigger library_item_archive_on_remove before update of removed_at on app_private.library_items
 for each row execute function app_private.clear_archive_on_remove();

-- Mirrors v2_set_library_item (010): replayable receipt, revision precondition.
create function public.v2_set_item_archived(p_operation_id uuid,p_document_id uuid,p_archived boolean,p_expected_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); digest bytea; replay jsonb; li app_private.library_items; s bigint; r jsonb;
begin
 if p_archived is null or p_expected_revision is null or p_expected_revision<1 then raise exception 'invalid_archive_command'; end if;
 digest:=sha256(convert_to(jsonb_build_array('archive-v1',p_document_id,p_archived,p_expected_revision)::text,'UTF8'));
 perform public.worker_consume_request(a,'library-write'); perform app_private.lock_library_account(a);
 perform 1 from app_private.documents where id=p_document_id and (scope='shared_catalog' or owner_id=a) for key share;
 if not found then raise exception 'document_unavailable' using errcode='42501'; end if;
 perform app_private.lock_library_state(a);
 replay:=app_private.library_replay(a,p_operation_id,digest); if replay is not null then return replay; end if;
 select * into li from app_private.library_items where account_id=a and document_id=p_document_id;
 perform app_private.library_check_receipt_capacity(a,false);
 if li.id is null or li.removed_at is not null or li.membership_revision<>p_expected_revision then
  r:=jsonb_build_object('status','revision_conflict','kind','item','id',li.id,'revision',coalesce(li.membership_revision,0));
  return app_private.library_receipt(a,p_operation_id,digest,r);
 end if;
 s:=app_private.library_next_seq(a);
 update app_private.library_items set archived_at=case when p_archived then coalesce(archived_at,now()) end,
  state_seq=s,membership_revision=membership_revision+1 where id=li.id;
 perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_item_entry(a,li.id)));
 return app_private.library_receipt(a,p_operation_id,digest,jsonb_build_object('status','applied','kind','item','id',li.id,'seq',s,'revision',p_expected_revision+1));
end $$;

revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
revoke all on function public.v2_set_item_archived(uuid,uuid,boolean,bigint) from public,anon,authenticated,service_role;
grant execute on function public.v2_set_item_archived(uuid,uuid,boolean,bigint) to authenticated;
notify pgrst,'reload schema';
commit;
