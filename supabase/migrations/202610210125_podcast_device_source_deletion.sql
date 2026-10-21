-- 125: Account deletion removes the account's podcast device-source records (review A16, 2026-10-21;
-- docs/architecture/PAPER_PODCASTS.md "Privacy, corrections and deletion"). Each private episode made from the text on a
-- device keeps an immutable app_private.podcast_device_sources row (migration 066): owner, paper membership, arXiv id and
-- revision, title, authors, text digests. Nothing removed it, so a deleted account kept a record of the papers it made
-- episodes of. The row is personal library data, not a financial record: jobs, operations, provider attempts and the
-- ledger stay under the account's random UUID as before (the de-identified billing record). Additive:
--  1. the immutability trigger permits a DELETE only inside the same account's deletion transaction (the
--     `app_private.deleting_account` setting worker_delete_account_begin sets); every UPDATE and any other DELETE is
--     still refused;
--  2. worker_delete_account_begin (wrapped, earlier steps unchanged) deletes the account's rows;
--  3. worker_account_deletion_status counts them as personal rows;
--  4. rows already left by closed accounts are removed once, through the same deletion context.
-- Deletion still refuses while any of the account's operations is unsettled, so no running job loses its source.
begin;
set local lock_timeout='15s';

-- 1. Deletion-only removal.
create function app_private.podcast_device_source_immutable() returns trigger
language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' and old.owner_id::text=coalesce(current_setting('app_private.deleting_account',true),'') then return old; end if;
 raise exception 'immutable_record_requires_compensating_entry';
end $$;
drop trigger podcast_device_sources_immutable on app_private.podcast_device_sources;
create trigger podcast_device_sources_immutable before update or delete on app_private.podcast_device_sources
 for each row execute function app_private.podcast_device_source_immutable();

-- The account's rows, deleted under its own deletion context (also used once below for accounts closed earlier).
create function app_private.podcast_device_sources_forget(p_account_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is not null) then raise exception 'account_not_closed'; end if;
 perform set_config('app_private.deleting_account',p_account_id::text,true);
 delete from app_private.podcast_device_sources where owner_id=p_account_id;
 get diagnostics n=row_count;
 return n;
end $$;

-- 2. Deletion removes them, after the earlier steps closed the account and cancelled its podcast work.
alter function public.worker_delete_account_begin(uuid) rename to delete_account_begin_before_125;
alter function public.delete_account_begin_before_125(uuid) set schema app_private;
create function public.worker_delete_account_begin(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=app_private.delete_account_begin_before_125(p_account_id);
 perform app_private.podcast_device_sources_forget(p_account_id);
 return result;
end $$;

-- 3. The operator's check counts them with the other personal rows.
alter function public.worker_account_deletion_status(uuid) rename to account_deletion_status_before_125;
alter function public.account_deletion_status_before_125(uuid) set schema app_private;
create function public.worker_account_deletion_status(p_account_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 with old as (select app_private.account_deletion_status_before_125(p_account_id) value),
 dev as (select count(*) n from app_private.podcast_device_sources where owner_id=p_account_id)
 select old.value||jsonb_build_object('personal_rows',(old.value->>'personal_rows')::bigint+dev.n,'podcast_device_sources',dev.n) from old,dev
$$;

-- 4. Rows already left by closed accounts.
do $$
declare a uuid;
begin
 for a in select distinct d.owner_id from app_private.podcast_device_sources d join app_private.accounts x on x.id=d.owner_id
  where x.closed_at is not null order by 1 loop
  perform app_private.podcast_device_sources_forget(a);
 end loop;
 perform set_config('app_private.deleting_account','',true);
end $$;

revoke all on function app_private.podcast_device_source_immutable(),app_private.podcast_device_sources_forget(uuid),
 app_private.delete_account_begin_before_125(uuid),app_private.account_deletion_status_before_125(uuid) from public,anon,authenticated,service_role;
revoke all on function public.worker_delete_account_begin(uuid),public.worker_account_deletion_status(uuid) from public,anon,authenticated,service_role;
grant execute on function public.worker_delete_account_begin(uuid),public.worker_account_deletion_status(uuid) to service_role;
notify pgrst,'reload schema';
commit;
