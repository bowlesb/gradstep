-- 095: Encrypted note images (docs/architecture/NOTES_AND_SNIPPETS.md "Implementation contract"). The note-assets
-- Edge function is the only reader and writer of the private `note-assets` bucket (objects at `{account}/{blob}`,
-- provisioned and drift-checked by scripts/deploy-staging.py from infra/staging.json, like every other bucket). Each
-- object is ciphertext the server cannot read: nonce || AES-256-GCM ciphertext || tag, at most 2 MiB + 28 bytes.
--
-- This migration adds, all service-role only:
--  * one policy row holding every quota (the single place for them), environment totals and the inventory;
--  * worker_note_asset_reserve: before a write, in one transaction, an idempotent reservation. Same blob ID and
--    digest returns the existing row; a different digest is a conflict. Pending rows count against the per-account
--    (128 MiB, 4,000 objects) and environment (512 MiB) quotas exactly like ready ones;
--  * worker_note_asset_confirm: marks a row ready after the function has read the stored bytes back and checked them;
--  * worker_note_asset_download: meters a download (512 MiB per account and 4 GiB per environment each UTC month)
--    before Storage is read; the function's own read-back of an upload is metered separately ("verify");
--  * account deletion: the plan lists every inventoried object and the account's `{account}/` folder, waits while a
--    write could still land, and the finish removes the inventory rows; personal monthly counters are erased;
--  * the admin Spending summary gains `note_assets` (stored, pending, this month's transfer and the limits).
-- Nothing about a note (title, comment, paper, image) reaches the server; rows hold opaque IDs, digests and sizes.
begin;
set local lock_timeout='15s';

-- 1. Quotas: one row, the only place they are set. max_blob_bytes mirrors the function's transport bound.
create table app_private.note_asset_policy (
 singleton boolean primary key default true check(singleton),
 max_blob_bytes integer not null check(max_blob_bytes between 28 and 16777216),
 account_bytes bigint not null check(account_bytes>0),
 account_objects integer not null check(account_objects>0),
 environment_bytes bigint not null check(environment_bytes>0),
 account_download_bytes_month bigint not null check(account_download_bytes_month>0),
 environment_download_bytes_month bigint not null check(environment_download_bytes_month>0),
 -- The function reads each written object back once to check it; retries of a pending object read it again.
 account_verify_bytes_month bigint not null check(account_verify_bytes_month>0),
 environment_verify_bytes_month bigint not null check(environment_verify_bytes_month>0),
 -- A pending object whose last write began less than this long ago may still land in Storage (Edge's wall-clock
 -- limit is well below it), so account deletion waits rather than racing a late write.
 write_grace_seconds integer not null check(write_grace_seconds between 60 and 86400)
);
insert into app_private.note_asset_policy(max_blob_bytes,account_bytes,account_objects,environment_bytes,
 account_download_bytes_month,environment_download_bytes_month,account_verify_bytes_month,environment_verify_bytes_month,write_grace_seconds)
values(2097152+28,134217728,4000,536870912,536870912,4294967296,268435456,1073741824,600);

-- 2. Environment totals of every inventoried object (pending and ready), kept in the same transaction as the rows.
create table app_private.note_asset_totals (
 singleton boolean primary key default true check(singleton),
 bytes bigint not null default 0 check(bytes>=0),
 objects bigint not null default 0 check(objects>=0)
);
insert into app_private.note_asset_totals default values;

-- 3. Inventory. The object path is derived: account_id || '/' || blob_id. The surrogate id names backup archives.
create table app_private.note_assets (
 id uuid primary key default gen_random_uuid(),
 account_id uuid not null references app_private.accounts(id),
 blob_id uuid not null,
 sha256 bytea not null check(octet_length(sha256)=32),
 byte_count integer not null check(byte_count between 28 and 16777216),
 state text not null default 'pending' check(state in ('pending','ready')),
 created_at timestamptz not null default clock_timestamp(),
 attempt_at timestamptz not null default clock_timestamp(),
 attempts integer not null default 1 check(attempts>=1),
 ready_at timestamptz,
 unique(account_id,blob_id),
 check((state='ready')=(ready_at is not null))
);
create index note_assets_pending on app_private.note_assets(attempt_at) where state='pending';

-- 4. Monthly transfer (UTC months), per account and for the environment ('environment').
create table app_private.note_asset_transfer_months (
 period date not null,
 scope_id text not null check(scope_id='environment' or scope_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
 kind text not null check(kind in ('download','verify')),
 bytes bigint not null default 0 check(bytes>=0),
 requests bigint not null default 0 check(requests>=0),
 primary key(period,scope_id,kind)
);

alter table app_private.note_asset_policy enable row level security;
alter table app_private.note_asset_totals enable row level security;
alter table app_private.note_assets enable row level security;
alter table app_private.note_asset_transfer_months enable row level security;
revoke all on app_private.note_asset_policy,app_private.note_asset_totals,app_private.note_assets,app_private.note_asset_transfer_months
 from public,anon,authenticated,service_role;

-- Request rates (the same limiter as every user function): an upload is one PUT, a download one GET.
insert into app_private.api_rate_rules values('note-upload',3600,300,3000),('note-download',3600,1000,10000) on conflict(route) do nothing;

-- Charge one transfer to the environment, then the account (always in that order; a refusal rolls both back).
create function app_private.note_transfer_charge(p_account uuid,p_kind text,p_bytes bigint) returns void
language plpgsql security definer set search_path='' as $$
declare pol app_private.note_asset_policy; month date:=date_trunc('month',clock_timestamp() at time zone 'UTC')::date;
 s text; used bigint; maximum bigint;
begin
 if p_kind not in ('download','verify') or p_bytes is null or p_bytes<0 then raise exception 'invalid_note_asset'; end if;
 select * into strict pol from app_private.note_asset_policy where singleton;
 foreach s in array array['environment',p_account::text] loop
  maximum:=case when p_kind='download' then case when s='environment' then pol.environment_download_bytes_month else pol.account_download_bytes_month end
   else case when s='environment' then pol.environment_verify_bytes_month else pol.account_verify_bytes_month end end;
  insert into app_private.note_asset_transfer_months as t(period,scope_id,kind,bytes,requests) values(month,s,p_kind,p_bytes,1)
   on conflict(period,scope_id,kind) do update set bytes=t.bytes+excluded.bytes,requests=t.requests+1 returning t.bytes into used;
  if used>maximum then raise exception 'note_transfer_limit'; end if;
 end loop;
end $$;

create function app_private.note_asset_path(p_account uuid,p_blob uuid) returns text
language sql immutable strict set search_path='' as $$ select p_account::text||'/'||p_blob::text $$;

-- 5. Before a write. Lock order: account, then totals, then the row, then transfer counters (deletion and
-- download admission take the account first too).
create function public.worker_note_asset_reserve(p_account_id uuid,p_blob_id uuid,p_sha256 bytea,p_bytes bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.note_asset_policy; t app_private.note_asset_totals; r app_private.note_assets; used_bytes bigint; used_objects bigint;
begin
 if p_account_id is null or p_blob_id is null or p_sha256 is null or octet_length(p_sha256)<>32 or p_bytes is null then
  raise exception 'invalid_note_asset';
 end if;
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended for key share;
 if not found then raise exception 'account_unavailable' using errcode='42501'; end if;
 select * into strict pol from app_private.note_asset_policy where singleton;
 if p_bytes<28 or p_bytes>pol.max_blob_bytes then raise exception 'invalid_note_asset'; end if;
 select * into strict t from app_private.note_asset_totals where singleton for update;
 select * into r from app_private.note_assets where account_id=p_account_id and blob_id=p_blob_id for update;
 if found then
  if r.sha256<>p_sha256 or r.byte_count<>p_bytes then raise exception 'note_asset_conflict'; end if;
  if r.state='ready' then
   return jsonb_build_object('state','ready','bytes',r.byte_count,'path',app_private.note_asset_path(p_account_id,p_blob_id),'retry',false);
  end if;
  -- The same bytes again (a timeout or failure on an earlier attempt): one more write and read-back.
  perform app_private.note_transfer_charge(p_account_id,'verify',p_bytes);
  update app_private.note_assets set attempt_at=clock_timestamp(),attempts=attempts+1 where id=r.id;
  return jsonb_build_object('state','pending','bytes',r.byte_count,'path',app_private.note_asset_path(p_account_id,p_blob_id),'retry',true);
 end if;
 -- Totals are locked, so every reservation sees all committed rows, pending ones included.
 select coalesce(sum(byte_count),0),count(*) into used_bytes,used_objects from app_private.note_assets where account_id=p_account_id;
 if used_bytes+p_bytes>pol.account_bytes or used_objects+1>pol.account_objects or t.bytes+p_bytes>pol.environment_bytes then
  raise exception 'note_asset_quota';
 end if;
 perform app_private.note_transfer_charge(p_account_id,'verify',p_bytes);
 insert into app_private.note_assets(account_id,blob_id,sha256,byte_count) values(p_account_id,p_blob_id,p_sha256,p_bytes);
 update app_private.note_asset_totals set bytes=bytes+p_bytes,objects=objects+1 where singleton;
 return jsonb_build_object('state','pending','bytes',p_bytes,'path',app_private.note_asset_path(p_account_id,p_blob_id),'retry',false);
end $$;

-- 6. After the function has read the stored object back and checked its length and digest.
create function public.worker_note_asset_confirm(p_account_id uuid,p_blob_id uuid,p_sha256 bytea,p_bytes bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.note_assets;
begin
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended for key share;
 if not found then raise exception 'account_unavailable' using errcode='42501'; end if;
 select * into r from app_private.note_assets where account_id=p_account_id and blob_id=p_blob_id for update;
 if not found then raise exception 'note_asset_unavailable' using errcode='42501'; end if;
 if p_sha256 is null or r.sha256<>p_sha256 or p_bytes is null or r.byte_count<>p_bytes then raise exception 'note_asset_conflict'; end if;
 if r.state='pending' then
  update app_private.note_assets set state='ready',ready_at=clock_timestamp() where id=r.id returning * into r;
 end if;
 return jsonb_build_object('state','ready','bytes',r.byte_count);
end $$;

-- 7. Before a download is read from Storage: the account's own ready object, charged in full first.
create function public.worker_note_asset_download(p_account_id uuid,p_blob_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.note_assets;
begin
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended for key share;
 if not found then raise exception 'account_unavailable' using errcode='42501'; end if;
 select * into r from app_private.note_assets where account_id=p_account_id and blob_id=p_blob_id and state='ready';
 if not found then raise exception 'note_asset_unavailable' using errcode='42501'; end if;
 perform app_private.note_transfer_charge(p_account_id,'download',r.byte_count);
 return jsonb_build_object('path',app_private.note_asset_path(p_account_id,p_blob_id),'bytes',r.byte_count,'sha256',encode(r.sha256,'hex'));
end $$;

-- 8. Usage for the admin Spending page (owner with MFA, checked by the wrapped function before this runs).
create function app_private.note_asset_usage(p_account_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 with cur as (select date_trunc('month',now() at time zone 'UTC')::date period),
 inv as (select state,count(*) objects,coalesce(sum(byte_count),0) bytes,min(attempt_at) oldest
  from app_private.note_assets group by state),
 xfer as (select x.scope_id,x.kind,x.bytes,x.requests from app_private.note_asset_transfer_months x join cur on x.period=cur.period)
 select jsonb_build_object(
  'period',(select period from cur),
  'limits',(select jsonb_build_object('max_blob_bytes',max_blob_bytes,'account_bytes',account_bytes,'account_objects',account_objects,
    'environment_bytes',environment_bytes,'account_download_bytes_month',account_download_bytes_month,
    'environment_download_bytes_month',environment_download_bytes_month,'account_verify_bytes_month',account_verify_bytes_month,
    'environment_verify_bytes_month',environment_verify_bytes_month) from app_private.note_asset_policy where singleton),
  'stored',(select jsonb_build_object('bytes',t.bytes,'objects',t.objects,
    'ready_bytes',coalesce((select bytes from inv where state='ready'),0),'ready_objects',coalesce((select objects from inv where state='ready'),0),
    'pending_bytes',coalesce((select bytes from inv where state='pending'),0),'pending_objects',coalesce((select objects from inv where state='pending'),0),
    'oldest_pending_at',(select oldest from inv where state='pending'),
    'accounts',(select count(distinct account_id) from app_private.note_assets)) from app_private.note_asset_totals t where singleton),
  'month',jsonb_build_object(
    'download_bytes',coalesce((select bytes from xfer where scope_id='environment' and kind='download'),0),
    'downloads',coalesce((select requests from xfer where scope_id='environment' and kind='download'),0),
    'verify_bytes',coalesce((select bytes from xfer where scope_id='environment' and kind='verify'),0),
    'verifies',coalesce((select requests from xfer where scope_id='environment' and kind='verify'),0)),
  'account',case when p_account_id is null then null else jsonb_build_object(
    'bytes',(select coalesce(sum(byte_count),0) from app_private.note_assets where account_id=p_account_id),
    'objects',(select count(*) from app_private.note_assets where account_id=p_account_id),
    'pending_objects',(select count(*) from app_private.note_assets where account_id=p_account_id and state='pending'),
    'download_bytes',coalesce((select bytes from xfer where scope_id=p_account_id::text and kind='download'),0),
    'verify_bytes',coalesce((select bytes from xfer where scope_id=p_account_id::text and kind='verify'),0)) end)
$$;

alter function public.v1_admin_spending(integer,uuid) rename to admin_spending_before_095;
alter function public.admin_spending_before_095(integer,uuid) set schema app_private;
create function public.v1_admin_spending(p_days integer default 30,p_account_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb;
begin
 -- The earlier function checks the owner with MFA, the window and the request rate before anything is read.
 base:=app_private.admin_spending_before_095(p_days,p_account_id);
 return base||jsonb_build_object('note_assets',app_private.note_asset_usage(p_account_id));
end $$;

-- 9. Account deletion (the existing resumable design: begin closes and plans, the caller removes the files, then
-- finish). The plan adds every inventoried object and the account's folder; personal monthly counters go now.
alter function public.worker_delete_account_begin(uuid) rename to delete_account_begin_before_095;
alter function public.delete_account_begin_before_095(uuid) set schema app_private;
create function public.worker_delete_account_begin(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; grace integer;
begin
 result:=app_private.delete_account_begin_before_095(p_account_id);
 delete from app_private.note_asset_transfer_months where scope_id=p_account_id::text;
 if result ? 'blocked' then return result; end if;
 -- The account is closed now, so no new reservation or confirmation can start; a write that began within the grace
 -- may still land in Storage after a listing. Nothing is removed until it cannot (the sweep retries).
 select write_grace_seconds into strict grace from app_private.note_asset_policy where singleton;
 if exists(select 1 from app_private.note_assets where account_id=p_account_id and state='pending'
  and attempt_at>clock_timestamp()-make_interval(secs=>grace)) then
  return jsonb_build_object('account_id',p_account_id,'blocked','asset_write_uncertain','objects','[]'::jsonb,'prefixes','[]'::jsonb);
 end if;
 result:=jsonb_set(result,'{objects}',coalesce(result->'objects','[]'::jsonb)||coalesce((select jsonb_agg(jsonb_build_object('bucket','note-assets',
  'path',app_private.note_asset_path(account_id,blob_id)) order by blob_id) from app_private.note_assets where account_id=p_account_id),'[]'::jsonb));
 return jsonb_set(result,'{prefixes}',coalesce(result->'prefixes','[]'::jsonb)||jsonb_build_array(
  jsonb_build_object('bucket','note-assets','prefix',p_account_id::text||'/')));
end $$;

alter function public.worker_delete_account_finish(uuid) rename to delete_account_finish_before_095;
alter function public.delete_account_finish_before_095(uuid) set schema app_private;
create function public.worker_delete_account_finish(p_account_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare grace integer; n integer; b bigint;
begin
 perform 1 from app_private.accounts where id=p_account_id and closed_at is not null for update;
 if not found then raise exception 'account_not_closed'; end if;
 select write_grace_seconds into strict grace from app_private.note_asset_policy where singleton;
 if exists(select 1 from app_private.note_assets where account_id=p_account_id and state='pending'
  and attempt_at>clock_timestamp()-make_interval(secs=>grace)) then raise exception 'asset_write_uncertain'; end if;
 -- The caller has removed the planned objects (and the Edge function has re-listed the folder as empty).
 perform 1 from app_private.note_asset_totals where singleton for update;
 select count(*),coalesce(sum(byte_count),0) into n,b from app_private.note_assets where account_id=p_account_id;
 delete from app_private.note_assets where account_id=p_account_id;
 update app_private.note_asset_totals set bytes=bytes-b,objects=objects-n where singleton;
 return app_private.delete_account_finish_before_095(p_account_id)+n;
end $$;

alter function public.worker_account_deletions_pending(integer) rename to account_deletions_pending_before_095;
alter function public.account_deletions_pending_before_095(integer) set schema app_private;
create function public.worker_account_deletions_pending(p_limit integer default 5) returns uuid[]
language sql stable security definer set search_path='' as $$
 select coalesce(array_agg(id order by closed_at,id),'{}') from (
  select a.id,a.closed_at from app_private.accounts a
  where a.id=any(app_private.account_deletions_pending_before_095(20))
   or (a.closed_at is not null and a.closed_at>now()-interval '30 days'
    and exists(select 1 from app_private.note_assets n where n.account_id=a.id))
  order by a.closed_at,a.id limit greatest(1,least(p_limit,20))
 ) pending
$$;

alter function public.worker_account_deletion_status(uuid) rename to account_deletion_status_before_095;
alter function public.account_deletion_status_before_095(uuid) set schema app_private;
create function public.worker_account_deletion_status(p_account_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 with old as (select app_private.account_deletion_status_before_095(p_account_id) value),
 notes as (select count(*) n from app_private.note_assets where account_id=p_account_id)
 select old.value||jsonb_build_object('personal_rows',(old.value->>'personal_rows')::bigint+notes.n,
  'files_not_deleted',(old.value->>'files_not_deleted')::bigint+notes.n,'note_assets',notes.n) from old,notes
$$;

revoke all on function app_private.note_transfer_charge(uuid,text,bigint),app_private.note_asset_path(uuid,uuid),
 app_private.note_asset_usage(uuid),app_private.admin_spending_before_095(integer,uuid),
 app_private.delete_account_begin_before_095(uuid),app_private.delete_account_finish_before_095(uuid),
 app_private.account_deletions_pending_before_095(integer),app_private.account_deletion_status_before_095(uuid)
 from public,anon,authenticated,service_role;
revoke all on function public.worker_note_asset_reserve(uuid,uuid,bytea,bigint),public.worker_note_asset_confirm(uuid,uuid,bytea,bigint),
 public.worker_note_asset_download(uuid,uuid),public.worker_delete_account_begin(uuid),public.worker_delete_account_finish(uuid),
 public.worker_account_deletions_pending(integer),public.worker_account_deletion_status(uuid)
 from public,anon,authenticated,service_role;
grant execute on function public.worker_note_asset_reserve(uuid,uuid,bytea,bigint),public.worker_note_asset_confirm(uuid,uuid,bytea,bigint),
 public.worker_note_asset_download(uuid,uuid),public.worker_delete_account_begin(uuid),public.worker_delete_account_finish(uuid),
 public.worker_account_deletions_pending(integer),public.worker_account_deletion_status(uuid)
 to service_role;
revoke all on function public.v1_admin_spending(integer,uuid) from public,anon;
grant execute on function public.v1_admin_spending(integer,uuid) to authenticated;

notify pgrst,'reload schema';
commit;
