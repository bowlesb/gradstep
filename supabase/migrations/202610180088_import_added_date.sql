-- Source-only memberships are imports, not library_items. Preserve their actual creation date in the Added column.
-- Design: HTML_FIRST_READER.md, "Import creation date in Library". Additive format-2 projection; no data copies.
begin;
set local lock_timeout='15s';
alter table app_private.import_requests add column source_tags_customized boolean not null default false;
alter function app_private.library_import_entry(uuid,uuid) rename to library_import_entry_before_088;
create function app_private.library_import_entry(a uuid,p_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select app_private.library_import_entry_before_088(a,p_id) || jsonb_build_object('added_at',i.created_at,'tags_customized',i.source_tags_customized or cardinality(i.source_tags)>0)
 from app_private.import_requests i where i.account_id=a and i.id=p_id
$$;
revoke all on function app_private.library_import_entry(uuid,uuid) from public,anon,authenticated;
revoke all on function app_private.library_import_entry_before_088(uuid,uuid) from public,anon,authenticated;
create or replace function public.v5_set_source_details(p_dataset_epoch uuid,p_operation_id uuid,p_import_id uuid,
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
   update app_private.import_requests set source_archived=p_archived,source_tags=p_tags,
    source_tags_customized=source_tags_customized or p_tags<>source_tags or p_archived=source_archived,
    intent_revision=intent_revision+1,state_seq=s where account_id=a and id=i.id;
   perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,i.id)));
   result:=app_private.library_receipt(a,p_operation_id,digest,jsonb_build_object('status','applied','kind','import','id',i.id,'seq',s,'revision',p_expected_revision+1));
  end if;
 end if;
 epoch:=app_private.library_command_epoch(p_dataset_epoch,true);
 return result||jsonb_build_object('dataset_epoch',epoch);
end $$;


-- Existing clients have consumed the original entries. Emit new versions rather than silently changing a revision.
do $$
declare a uuid; r record; s bigint;
begin
 for a in select distinct account_id from app_private.import_requests where desired_present and phase<>'ready' order by account_id loop
  perform app_private.lock_library_account(a);
  perform app_private.lock_library_state(a);
  for r in select id from app_private.import_requests where account_id=a and desired_present and phase<>'ready' order by id for update loop
   s := app_private.library_next_seq(a);
   update app_private.import_requests set state_seq=s where account_id=a and id=r.id;
   perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,r.id)));
  end loop;
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
