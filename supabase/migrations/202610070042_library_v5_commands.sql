-- Dataset-epoch-bound library commands for upload-capable (full-v5) readers.
-- Design: docs/architecture/NATIVE_LIBRARY_COMMANDS.md#upload-capable-readers-v5-commands-migration-042.
--
-- A v5 reader's preconditions (observed cursor, membership/intent revisions)
-- were observed in one library dataset, named by upload_dataset_epoch (039).
-- Restore quarantine rotates that epoch because a restored database is rewound:
-- the same cursor/revision numbers can then describe different history, and an
-- operation committed after the backup has no receipt to replay. A v2 command
-- has no way to say which dataset it was observed in, so 039 left v5 writes off.
--
-- Each v5_* command below is exactly the corresponding v2_* command plus
-- p_dataset_epoch. It authenticates like v2, refuses another dataset with
-- library_resync_required, then calls the unchanged v2 function in the same
-- transaction: the same admission, rate window, locks, digests, receipts,
-- replay, limits, errors and response, plus the response's dataset_epoch.
-- Receipt seq/state_seq values are the shared journal sequence that v5 full
-- deltas page through (v3 merely hides upload batches), so a receipt is a
-- valid catch-up floor for v5_library_changes in that same epoch.
--
-- Fence: the final epoch read takes FOR SHARE on the library_v4_config row and
-- holds it until commit. Every epoch rotation is an UPDATE of that row (restore
-- quarantine in scripts/restore-local.py, and 039), whose row lock conflicts
-- with FOR SHARE. A command therefore commits entirely before a rotation, or
-- waits for it, re-reads the new epoch and rolls back. It is the command's last
-- lock: rotations take it after any library locks (039) or with no library locks
-- (quarantine), so the order stays acyclic. The earlier unlocked read only gives
-- library_resync_required precedence over errors computed from stale arguments.
begin;
set local lock_timeout='15s';

create function app_private.library_command_epoch(p_dataset_epoch uuid,p_fence boolean) returns uuid
language plpgsql security definer set search_path='' as $$
declare epoch uuid;
begin
 if p_dataset_epoch is null then raise exception 'invalid_library_cursor'; end if;
 if p_fence then
  select upload_dataset_epoch into strict epoch from app_private.library_v4_config where singleton for share;
 else
  select upload_dataset_epoch into strict epoch from app_private.library_v4_config where singleton;
 end if;
 if epoch<>p_dataset_epoch then raise exception 'library_resync_required'; end if;
 return epoch;
end $$;

create function public.v5_begin_import(p_dataset_epoch uuid,p_operation_id uuid,p_source_id text,p_observed_cursor bigint,
 p_requested_revision integer default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); epoch uuid:=app_private.library_command_epoch(p_dataset_epoch,false); result jsonb;
begin
 result:=public.v2_begin_import(p_operation_id,p_source_id,p_observed_cursor,p_requested_revision);
 epoch:=app_private.library_command_epoch(p_dataset_epoch,true);
 return result||jsonb_build_object('dataset_epoch',epoch);
end $$;

create function public.v5_set_library_item(p_dataset_epoch uuid,p_operation_id uuid,p_document_id uuid,p_present boolean,
 p_expected_revision bigint,p_approval_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); epoch uuid:=app_private.library_command_epoch(p_dataset_epoch,false); result jsonb;
begin
 result:=public.v2_set_library_item(p_operation_id,p_document_id,p_present,p_expected_revision,p_approval_id);
 epoch:=app_private.library_command_epoch(p_dataset_epoch,true);
 return result||jsonb_build_object('dataset_epoch',epoch);
end $$;

create function public.v5_cancel_import(p_dataset_epoch uuid,p_operation_id uuid,p_import_id uuid,p_expected_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); epoch uuid:=app_private.library_command_epoch(p_dataset_epoch,false); result jsonb;
begin
 result:=public.v2_cancel_import(p_operation_id,p_import_id,p_expected_revision);
 epoch:=app_private.library_command_epoch(p_dataset_epoch,true);
 return result||jsonb_build_object('dataset_epoch',epoch);
end $$;

create function public.v5_retry_import(p_dataset_epoch uuid,p_operation_id uuid,p_import_id uuid,p_expected_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); epoch uuid:=app_private.library_command_epoch(p_dataset_epoch,false); result jsonb;
begin
 result:=public.v2_retry_import(p_operation_id,p_import_id,p_expected_revision);
 epoch:=app_private.library_command_epoch(p_dataset_epoch,true);
 return result||jsonb_build_object('dataset_epoch',epoch);
end $$;

create function public.v5_set_item_archived(p_dataset_epoch uuid,p_operation_id uuid,p_document_id uuid,p_archived boolean,
 p_expected_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); epoch uuid:=app_private.library_command_epoch(p_dataset_epoch,false); result jsonb;
begin
 result:=public.v2_set_item_archived(p_operation_id,p_document_id,p_archived,p_expected_revision);
 epoch:=app_private.library_command_epoch(p_dataset_epoch,true);
 return result||jsonb_build_object('dataset_epoch',epoch);
end $$;

create function public.v5_set_item_tags(p_dataset_epoch uuid,p_operation_id uuid,p_document_id uuid,p_tags text[],p_hidden_tags text[],
 p_expected_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); epoch uuid:=app_private.library_command_epoch(p_dataset_epoch,false); result jsonb;
begin
 result:=public.v2_set_item_tags(p_operation_id,p_document_id,p_tags,p_hidden_tags,p_expected_revision);
 epoch:=app_private.library_command_epoch(p_dataset_epoch,true);
 return result||jsonb_build_object('dataset_epoch',epoch);
end $$;

revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
do $$ declare f record; begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
 and p.proname in ('v5_begin_import','v5_set_library_item','v5_cancel_import','v5_retry_import','v5_set_item_archived','v5_set_item_tags') loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
  execute format('grant execute on function %s to authenticated',f.signature);
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
