-- Account deletion (owner decision 2026-10-05). Personal content and the login
-- are deleted; credit, usage, operation, subscription and audit records are
-- kept under the account's random ID, which no longer maps to a person once the
-- login is gone (accounts.auth_user_id is set null by its foreign key).
--
-- Two steps, both service-role only and repeatable:
--   worker_delete_account_begin(account): refuses while paid work is held,
--     closes the account (app_private.actor() then rejects any remaining login
--     token), deletes personal rows, stops private conversions, and marks the
--     account's private and support files 'deleting' (returned for removal).
--   worker_delete_account_finish(account): after the caller removed those files
--     from Storage, marks them 'deleted'. The caller then deletes the login.
begin;

-- Append-only personal records may be deleted only by the deletion transaction
-- for the same account (a transaction-local setting set by the function below;
-- customer roles have no direct DML on these tables).
create function app_private.immutable_unless_account_deletion() returns trigger language plpgsql set search_path='' as $$
declare target text := current_setting('app_private.deleting_account', true);
begin
 if tg_op='DELETE' and coalesce(target,'')<>'' then
  if tg_table_name='support_status_events' then
   if exists(select 1 from app_private.support_reports r where r.id=old.report_id and r.account_id::text=target) then return old; end if;
  elsif old.account_id::text=target then
   return old;
  end if;
 end if;
 raise exception 'immutable_record_requires_compensating_entry';
end $$;

drop trigger library_commands_immutable on app_private.library_commands;
create trigger library_commands_immutable before update or delete on app_private.library_commands
 for each row execute function app_private.immutable_unless_account_deletion();
drop trigger key_transitions_immutable on app_private.key_transitions;
create trigger key_transitions_immutable before update or delete on app_private.key_transitions
 for each row execute function app_private.immutable_unless_account_deletion();
drop trigger support_status_immutable on app_private.support_status_events;
create trigger support_status_immutable before update or delete on app_private.support_status_events
 for each row execute function app_private.immutable_unless_account_deletion();

-- Encrypted-history capacity: the deletion adjusts the counters once for the
-- whole account (a per-row update locks the environment counter for minutes on
-- a large history), so the trigger skips rows of the account being deleted.
create or replace function app_private.account_sync_storage() returns trigger
language plpgsql security definer set search_path = '' as $$
declare a uuid; delta_bytes bigint; delta_events bigint; policy app_private.sync_storage_policy;
 environment app_private.sync_environment_storage; account app_private.sync_account_storage;
begin
 if TG_OP='DELETE' and OLD.account_id::text=coalesce(current_setting('app_private.deleting_account',true),'') then return null; end if;
 if TG_OP='INSERT' then a:=NEW.account_id; delta_bytes:=octet_length(NEW.ciphertext); delta_events:=1;
 else a:=OLD.account_id; delta_bytes:=-octet_length(OLD.ciphertext); delta_events:=-1; end if;
 select * into strict policy from app_private.sync_storage_policy where singleton;
 -- The append RPC already holds the account keyring. All accounts then acquire
 -- environment storage before their own counter. Deletion jobs use this order.
 update app_private.sync_environment_storage set ciphertext_bytes=ciphertext_bytes+delta_bytes,event_count=event_count+delta_events
 where singleton returning * into strict environment;
 if delta_events>0 and (environment.ciphertext_bytes>policy.environment_bytes or environment.event_count>policy.environment_events)
 then raise exception 'sync_environment_storage_limit'; end if;
 if delta_events>0 then
  insert into app_private.sync_account_storage values(a,delta_bytes,delta_events)
  on conflict(account_id) do update set ciphertext_bytes=app_private.sync_account_storage.ciphertext_bytes+excluded.ciphertext_bytes,
   event_count=app_private.sync_account_storage.event_count+excluded.event_count returning * into account;
 else
  update app_private.sync_account_storage set ciphertext_bytes=ciphertext_bytes+delta_bytes,event_count=event_count+delta_events
   where account_id=a returning * into strict account;
 end if;
 if delta_events>0 and (account.ciphertext_bytes>policy.account_bytes or account.event_count>policy.account_events)
 then raise exception 'sync_account_storage_limit'; end if;
 return null;
end $$;

-- Files of the account being deleted: its support attachments and the objects
-- of its private (owner_private) conversions.
create function app_private.account_deletion_objects(a uuid) returns setof app_private.stored_objects
language sql stable security definer set search_path='' as $$
 select o.* from app_private.stored_objects o
 where o.owner_id=a or o.document_id in (select d.id from app_private.documents d where d.owner_id=a)
$$;

create function public.worker_delete_account_begin(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare acct app_private.accounts;
begin
 select * into acct from app_private.accounts where id=p_account_id for update;
 if not found then raise exception 'account_unavailable'; end if;
 -- Same order as encrypted appends: keyring, then the storage counters.
 perform 1 from app_private.keyrings where account_id=p_account_id for update;
 -- Held credits belong to in-flight paid work (an answer or a conversion);
 -- deleting mid-flight would orphan its settlement. The caller retries later.
 if exists(select 1 from app_private.metered_operations where account_id=p_account_id and state<>'settled') then
  raise exception 'account_busy';
 end if;
 update app_private.accounts set closed_at=coalesce(closed_at,now()) where id=p_account_id;
 perform set_config('app_private.deleting_account',p_account_id::text,true);

 -- Library (foreign-key order).
 delete from app_private.pipeline_imports where account_id=p_account_id;
 delete from app_private.import_requests where account_id=p_account_id;      -- acquisition_interests cascade
 delete from app_private.library_items where account_id=p_account_id;        -- library_asset_projection cascades
 delete from app_private.library_commands where account_id=p_account_id;
 delete from app_private.library_changes where account_id=p_account_id;
 delete from app_private.library_sync_state where account_id=p_account_id;
 delete from app_private.library_transfer_months where scope_id=p_account_id::text;
 delete from app_private.paper_read_grants where account_id=p_account_id;

 -- Encrypted history, devices and keys (capacity adjusted once, see trigger).
 update app_private.sync_environment_storage e set ciphertext_bytes=e.ciphertext_bytes-s.bytes, event_count=e.event_count-s.events
 from (select coalesce(sum(octet_length(ciphertext)),0) bytes, count(*) events from app_private.sync_events where account_id=p_account_id) s
 where e.singleton and s.events>0;
 delete from app_private.sync_events where account_id=p_account_id;
 delete from app_private.device_envelopes where account_id=p_account_id;
 delete from app_private.enrollment_requests where account_id=p_account_id;
 delete from app_private.key_transitions where account_id=p_account_id;
 delete from app_private.devices where account_id=p_account_id;
 delete from app_private.keyrings where account_id=p_account_id;
 delete from app_private.sync_account_storage where account_id=p_account_id;
 delete from app_private.sync_transfer_months where scope_id=p_account_id::text;

 -- Support reports and everything attached to them.
 delete from app_private.support_status_events where report_id in (select id from app_private.support_reports where account_id=p_account_id);
 delete from app_private.support_messages where report_id in (select id from app_private.support_reports where account_id=p_account_id);
 delete from app_private.support_attachments where account_id=p_account_id;
 delete from app_private.attachment_uploads where account_id=p_account_id;
 delete from app_private.support_reports where account_id=p_account_id;

 -- Rate-limit counters and operator roles.
 delete from app_private.api_rate_windows where scope_id=p_account_id::text;
 delete from app_private.app_roles where account_id=p_account_id;

 -- Private conversions: stop pending work (fenced worker calls then fail).
 update app_private.pipeline_papers set stage='failed', resume_stage=null, error_code='owner_deleted',
  claim_id=null, lease_until=null, generation=generation+1, state_revision=state_revision+1, updated_at=now()
 where owner_id=p_account_id and stage not in ('done','failed','source_only');

 -- Files to remove: verified or pending objects become 'deleting'.
 update app_private.stored_objects set state='deleting'
 where id in (select id from app_private.account_deletion_objects(p_account_id)) and state in ('pending','verified');

 -- Besides tracked objects: the account's folders. A private conversion's OCR
 -- output and reader live in raw/<sha>/ and reader/<sha>/ folders (only the
 -- manifest is tracked; the digests include the private attempt, so the
 -- folders are this owner's alone).
 return jsonb_build_object('account_id',p_account_id,
  'objects',coalesce((select jsonb_agg(jsonb_build_object('bucket',o.bucket,'path',o.path) order by o.path)
   from app_private.account_deletion_objects(p_account_id) o where o.state='deleting'),'[]'::jsonb),
  'prefixes',jsonb_build_array(jsonb_build_object('bucket','paper-assets','prefix','private/'||p_account_id::text||'/'),
   jsonb_build_object('bucket','support','prefix',p_account_id::text||'/'))
   ||coalesce((select jsonb_agg(distinct jsonb_build_object('bucket',o.bucket,'prefix',regexp_replace(o.path,'manifest\.json$','')))
    from app_private.account_deletion_objects(p_account_id) o
    where o.bucket='paper-assets' and o.document_id is not null and o.path ~ '^(raw|reader)/[0-9a-f]{64}/manifest\.json$'),'[]'::jsonb),
  'private_prefix','private/'||p_account_id::text||'/');
end $$;

create function public.worker_delete_account_finish(p_account_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is not null) then
  raise exception 'account_not_closed';
 end if;
 update app_private.stored_objects set state='deleted'
 where id in (select id from app_private.account_deletion_objects(p_account_id)) and state='deleting';
 get diagnostics n=row_count;
 return n;
end $$;

-- Closed accounts whose deletion is unfinished (login still linked, personal
-- rows written in a race, or files not yet removed), for the worker's sweep.
create function public.worker_account_deletions_pending(p_limit integer default 5) returns uuid[]
language sql stable security definer set search_path='' as $$
 select coalesce(array_agg(id),'{}') from (
  select a.id from app_private.accounts a
  where a.closed_at is not null and a.closed_at>now()-interval '30 days'
   and (a.auth_user_id is not null
    or exists(select 1 from app_private.keyrings k where k.account_id=a.id)
    or exists(select 1 from app_private.library_items l where l.account_id=a.id)
    or exists(select 1 from app_private.import_requests i where i.account_id=a.id)
    or exists(select 1 from app_private.support_reports r where r.account_id=a.id)
    or exists(select 1 from app_private.account_deletion_objects(a.id) o where o.state in ('pending','verified','deleting')))
  order by a.closed_at limit greatest(1,least(p_limit,20))) pending
$$;
revoke all on function public.worker_account_deletions_pending(integer) from public, anon, authenticated;
grant execute on function public.worker_account_deletions_pending(integer) to service_role;

-- Operator check: personal rows left (should be 0 after deletion) and the
-- billing rows kept under the closed account.
create function public.worker_account_deletion_status(p_account_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'closed',(select closed_at is not null from app_private.accounts where id=p_account_id),
  'login_linked',(select auth_user_id is not null from app_private.accounts where id=p_account_id),
  'personal_rows',
   (select count(*) from app_private.keyrings where account_id=p_account_id)
   +(select count(*) from app_private.devices where account_id=p_account_id)
   +(select count(*) from app_private.sync_events where account_id=p_account_id)
   +(select count(*) from app_private.library_items where account_id=p_account_id)
   +(select count(*) from app_private.import_requests where account_id=p_account_id)
   +(select count(*) from app_private.library_commands where account_id=p_account_id)
   +(select count(*) from app_private.support_reports where account_id=p_account_id),
  'files_not_deleted',(select count(*) from app_private.account_deletion_objects(p_account_id) o where o.state<>'deleted'),
  'billing_rows',
   (select count(*) from app_private.metered_operations where account_id=p_account_id)
   +(select count(*) from app_private.credit_ledger where account_id=p_account_id))
$$;

revoke all on function public.worker_account_deletion_status(uuid) from public, anon, authenticated;
grant execute on function public.worker_account_deletion_status(uuid) to service_role;
revoke all on function app_private.immutable_unless_account_deletion() from public, anon, authenticated;
revoke all on function app_private.account_deletion_objects(uuid) from public, anon, authenticated;
revoke all on function public.worker_delete_account_begin(uuid) from public, anon, authenticated;
revoke all on function public.worker_delete_account_finish(uuid) from public, anon, authenticated;
grant execute on function public.worker_delete_account_begin(uuid) to service_role;
grant execute on function public.worker_delete_account_finish(uuid) to service_role;
commit;
