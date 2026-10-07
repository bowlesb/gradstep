-- Additive library v4 replication. Canonical rows, command receipts, the full
-- v2/v3 journal and all existing RPCs keep their current identities/semantics.
-- The compact current projection drops ONLY bibliographic `metadata`; readers
-- hydrate immutable metadata separately, using retained account membership.
-- No capacity increase, new journal, paid work, or client rollout is enabled.
begin;
set local lock_timeout='15s';

-- Existing mutations/deletion lock accounts before the library policy/state.
-- Fence them in that order while installing the journal trigger and backfill.
-- EXCLUSIVE still permits ordinary SELECT, but blocks row-locking account
-- operations globally until commit. A lock timeout rolls this migration back.
lock table app_private.accounts in exclusive mode;
lock table app_private.library_policy,app_private.library_sync_state,
 app_private.library_items,app_private.import_requests,app_private.library_changes
 in share row exclusive mode;

create table app_private.library_v4_config (
 singleton boolean primary key default true check(singleton),
 dataset_epoch uuid not null default gen_random_uuid()
);
insert into app_private.library_v4_config default values;

create table app_private.library_v4_entries (
 account_id uuid not null references app_private.library_sync_state(account_id) on delete cascade,
 kind text not null check(kind in ('item','import')),
 id uuid not null,
 created_seq bigint not null check(created_seq>0),
 state_seq bigint not null check(state_seq>=created_seq),
 metadata_id uuid,
 entry jsonb not null check(jsonb_typeof(entry)='object' and not (entry ? 'metadata') and octet_length(entry::text)<=131072),
 primary key(account_id,kind,id),
 check(entry->'kind' is not distinct from to_jsonb(kind)),
 check(entry->'id' is not distinct from to_jsonb(id)),
 check(entry->'created_seq' is not distinct from to_jsonb(created_seq)),
 check(entry->'state_seq' is not distinct from to_jsonb(state_seq)),
 check(entry->'metadata_id' is not distinct from coalesce(to_jsonb(metadata_id),'null'::jsonb))
);
create index library_v4_entries_created on app_private.library_v4_entries(account_id,created_seq,id,kind);
create index library_v4_entries_metadata on app_private.library_v4_entries(account_id,metadata_id);

-- ON CONFLICT locks the existing row even when its WHERE rejects an update.
-- Therefore the equal-state check cannot race an independent newer publisher.
-- An identical replay does not UPDATE (nor wake downstream query projection).
create function app_private.library_v4_project_entry(a uuid,e jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare compact jsonb:=e-'metadata'; previous app_private.library_v4_entries;
 k text:=e->>'kind'; entry_id uuid:=(e->>'id')::uuid;
 created bigint:=(e->>'created_seq')::bigint; state bigint:=(e->>'state_seq')::bigint;
begin
 if compact is null or jsonb_typeof(compact)<>'object' then raise exception 'invalid_library_compact_entry'; end if;
 insert into app_private.library_v4_entries(account_id,kind,id,created_seq,state_seq,metadata_id,entry)
 values(a,k,entry_id,created,state,(e->>'metadata_id')::uuid,compact)
 on conflict(account_id,kind,id) do update
 set state_seq=excluded.state_seq,metadata_id=excluded.metadata_id,entry=excluded.entry
 where app_private.library_v4_entries.state_seq<excluded.state_seq
  and app_private.library_v4_entries.created_seq=excluded.created_seq;
 if not found then
  select * into strict previous from app_private.library_v4_entries where account_id=a and kind=k and id=entry_id;
  if previous.created_seq<>created then raise exception 'library_compact_identity_conflict'; end if;
  if previous.state_seq=state and previous.entry is distinct from compact then raise exception 'library_compact_state_conflict'; end if;
 end if;
end $$;

create function app_private.library_v4_project_change() returns trigger
language plpgsql security definer set search_path='' as $$
declare e jsonb;
begin
 for e in select value from jsonb_array_elements(new.entries) loop
  if (e->>'state_seq')::bigint>new.seq then raise exception 'library_sequence_mismatch'; end if;
  perform app_private.library_v4_project_entry(new.account_id,e);
 end loop;
 return new;
end $$;
create trigger library_v4_project_change after insert on app_private.library_changes
 for each row execute function app_private.library_v4_project_change();

-- Canonical rows, including removed items and hidden resolved/cancelled imports,
-- are authoritative for the initial current projection. Do not replay only the
-- retained journal: it may already have compacted older identities away. OFFSET
-- 0 keeps each full-entry function evaluated once per row without materializing
-- a whole environment's bibliographic payloads into one intermediate relation.
insert into app_private.library_v4_entries(account_id,kind,id,created_seq,state_seq,metadata_id,entry)
 select li.account_id,'item',li.id,li.created_seq,li.state_seq,(f.entry->>'metadata_id')::uuid,f.entry-'metadata'
 from app_private.library_items li
 cross join lateral (select app_private.library_item_entry(li.account_id,li.id) entry offset 0) f;
insert into app_private.library_v4_entries(account_id,kind,id,created_seq,state_seq,metadata_id,entry)
 select i.account_id,'import',i.id,i.created_seq,i.state_seq,(f.entry->>'metadata_id')::uuid,f.entry-'metadata'
 from app_private.import_requests i
 cross join lateral (select app_private.library_import_entry(i.account_id,i.id) entry offset 0) f;

-- A baseline fixes a CREATION boundary, not historical entry values. Later
-- pages may carry state_seq > baseline_cursor; mandatory fixed-boundary catch-up
-- must settle before a client publishes its complete observation. Continuations
-- expire when the original journal no longer covers that creation boundary.
create function app_private.library_v4_baseline(a uuid,p_cursor jsonb,p_limit integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare epoch uuid; high bigint; floor bigint; cursor_epoch uuid; cursor_high bigint;
 after_seq bigint:=0; after_id uuid:='00000000-0000-0000-0000-000000000000'; after_kind text:=''; result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'invalid_library_page'; end if;
 select dataset_epoch into strict epoch from app_private.library_v4_config where singleton;
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_cursor is not null then
  if jsonb_typeof(p_cursor) is distinct from 'object'
   or not (p_cursor ?& array['format','dataset_epoch','account_id','through','created_seq','id','kind'])
   or (p_cursor-array['format','dataset_epoch','account_id','through','created_seq','id','kind'])<>'{}'::jsonb
   or p_cursor->'format' is distinct from '4'::jsonb or p_cursor->'account_id' is distinct from to_jsonb(a)
   or jsonb_typeof(p_cursor->'dataset_epoch') is distinct from 'string'
   or not coalesce(p_cursor->>'dataset_epoch' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
   or jsonb_typeof(p_cursor->'through') is distinct from 'number' or not coalesce(p_cursor->>'through' ~ '^[0-9]+$',false)
   or jsonb_typeof(p_cursor->'created_seq') is distinct from 'number' or not coalesce(p_cursor->>'created_seq' ~ '^[0-9]+$',false)
   or jsonb_typeof(p_cursor->'id') is distinct from 'string'
   or not coalesce(p_cursor->>'id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
   or p_cursor->>'kind' not in ('item','import') or jsonb_typeof(p_cursor->'kind') is distinct from 'string'
  then raise exception 'invalid_library_cursor'; end if;
  begin
   cursor_epoch:=(p_cursor->>'dataset_epoch')::uuid;
   after_seq:=(p_cursor->>'created_seq')::bigint; after_id:=(p_cursor->>'id')::uuid; after_kind:=p_cursor->>'kind';
   cursor_high:=(p_cursor->>'through')::bigint;
  exception when numeric_value_out_of_range or invalid_text_representation then raise exception 'invalid_library_cursor'; end;
  if after_seq<1 or after_seq>cursor_high then raise exception 'invalid_library_cursor'; end if;
  -- After a dataset replacement, a valid old cursor may be above this dataset's
  -- new highwater. Its epoch requires resync before comparing those sequences.
  if cursor_epoch<>epoch then raise exception 'library_resync_required'; end if;
  if cursor_high>high then raise exception 'invalid_library_cursor'; end if;
  high:=cursor_high;
  if not exists(select 1 from app_private.library_v4_entries
   where account_id=a and kind=after_kind and id=after_id and created_seq=after_seq)
  then raise exception 'invalid_library_cursor'; end if;
 end if;
 if high<floor then raise exception 'library_resync_required'; end if;
 with candidates as materialized (
  select created_seq,id,kind,entry from app_private.library_v4_entries
  where account_id=a and created_seq<=high and (created_seq,id,kind)>(after_seq,after_id,after_kind)
  order by created_seq,id,kind limit p_limit
 ), sized as (
  select *,sum(octet_length(entry::text)+2) over(order by created_seq,id,kind) bytes from candidates
 ), selected as materialized (select * from sized where bytes<=1046528), last_row as (
  select created_seq,id,kind from selected order by created_seq desc,id desc,kind desc limit 1
 ) select jsonb_build_object('format',4,'dataset_epoch',epoch,'account_id',a,'baseline_cursor',high,'retained_after',floor,
  'entries',coalesce((select jsonb_agg(entry order by created_seq,id,kind) from selected),'[]'::jsonb),
  'next_cursor',(select jsonb_build_object('format',4,'dataset_epoch',epoch,'account_id',a,'through',high,
   'created_seq',created_seq,'id',id,'kind',kind) from last_row),
  'has_more',exists(select 1 from app_private.library_v4_entries e where e.account_id=a and e.created_seq<=high
   and (e.created_seq,e.id,e.kind)>coalesce((select row(created_seq,id,kind) from last_row),row(after_seq,after_id,after_kind)))) into result;
 return result;
end $$;

create function app_private.library_v4_delta(a uuid,p_dataset_epoch uuid,p_after bigint,p_through bigint,p_limit integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare epoch uuid; high bigint; floor bigint; result jsonb;
begin
 select dataset_epoch into strict epoch from app_private.library_v4_config where singleton;
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_dataset_epoch is null or p_after is null or p_after<0 or p_limit is null or p_limit not between 1 and 100
  or p_through<p_after then raise exception 'invalid_library_cursor'; end if;
 if p_dataset_epoch<>epoch then raise exception 'library_resync_required'; end if;
 if p_after>high or p_through>high then raise exception 'invalid_library_cursor'; end if;
 if p_after<floor then raise exception 'library_resync_required'; end if;
 high:=coalesce(p_through,high);
 -- LIMIT the original journal first. Expanding/compacting every retained batch
 -- before limiting would repeat whole-history work on each small delta page.
 with candidates as materialized (
  select seq,entries from app_private.library_changes where account_id=a and seq>p_after and seq<=high order by seq limit p_limit
 ), compact as materialized (
  select c.seq,(select jsonb_agg(x.value-'metadata' order by x.ordinality)
   from jsonb_array_elements(c.entries) with ordinality x) entries from candidates c
 ), sized as (select *,sum(octet_length(entries::text)+128) over(order by seq) bytes from compact),
 selected as materialized (select seq,entries from sized where bytes<=1046528),
 page as (select coalesce(jsonb_agg(jsonb_build_object('seq',seq,'entries',entries) order by seq),'[]'::jsonb) changes,coalesce(max(seq),p_after) last from selected)
 select jsonb_build_object('format',4,'dataset_epoch',epoch,'account_id',a,'through',high,'retained_after',floor,'changes',changes,
  'next_cursor',case when exists(select 1 from app_private.library_changes where account_id=a and seq>page.last and seq<=high) then page.last else high end,
  'has_more',exists(select 1 from app_private.library_changes where account_id=a and seq>page.last and seq<=high)) into result from page;
 return result;
end $$;

create function app_private.library_v4_metadata(a uuid,p_dataset_epoch uuid,p_metadata_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare epoch uuid; result jsonb;
begin
 select dataset_epoch into strict epoch from app_private.library_v4_config where singleton;
 if p_dataset_epoch is distinct from epoch then raise exception 'library_resync_required'; end if;
 if p_metadata_ids is null or coalesce(array_ndims(p_metadata_ids),1)<>1 or cardinality(p_metadata_ids)>24
  or exists(select 1 from unnest(p_metadata_ids) id where id is null)
  or (select count(distinct id) from unnest(p_metadata_ids) id)<>cardinality(p_metadata_ids)
 then raise exception 'invalid_library_metadata_request'; end if;
 -- Check the entire bounded request before returning any record. Missing and
 -- unauthorized UUIDs have the same failure, regardless of catalog existence.
 -- Removed rows/hidden mappings deliberately retain authorization until their
 -- account is deleted; no new metadata authority comes from a global UUID.
 if exists(select 1 from unnest(p_metadata_ids) requested(id)
  where not exists(select 1 from app_private.library_v4_entries e where e.account_id=a and e.metadata_id=requested.id)
   or not exists(select 1 from app_private.catalog_metadata m where m.id=requested.id))
 then raise exception 'library_metadata_unavailable' using errcode='42501'; end if;
 select jsonb_build_object('format',4,'dataset_epoch',epoch,'account_id',a,'records',coalesce(jsonb_agg(
  jsonb_build_object('metadata_id',m.id,'version_id',m.version_id,
   'source',case when m.source_id like 'openalex:%' then 'web' else 'arxiv' end,
   'source_id',m.source_id,'source_revision',m.source_revision,'metadata',m.metadata,'recorded_at',m.recorded_at)
  order by requested.ordinality),'[]'::jsonb)) into result
 from unnest(p_metadata_ids) with ordinality requested(id,ordinality) join app_private.catalog_metadata m on m.id=requested.id;
 -- The immutable UUID/provenance identifies this record. catalog_metadata's
 -- internal jsonb hash is NOT a hash of serialized wire bytes and is not sent.
 return result;
end $$;

-- A reader protects the account BEFORE touching rate/transfer counters. KEY
-- SHARE is compatible with legacy writers' NO KEY UPDATE, but blocks account
-- deletion's FOR UPDATE. A read queued behind deletion rechecks closed_at after
-- obtaining the lock and cannot recreate deleted counters. Using NO KEY UPDATE
-- after the rate windows would introduce a rate/account cycle with deletion.
create function app_private.library_v4_read_account(a uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from app_private.accounts where id=a and closed_at is null for key share;
 if not found then raise exception 'account_unavailable' using errcode='42501'; end if;
end $$;

create function public.v4_library_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_v4_baseline(a,p_cursor,p_limit);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;
create function public.v4_library_changes(p_dataset_epoch uuid,p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_v4_delta(a,p_dataset_epoch,p_after,p_through,p_limit);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;
create function public.v4_library_metadata(p_dataset_epoch uuid,p_metadata_ids uuid[]) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_v4_metadata(a,p_dataset_epoch,p_metadata_ids);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

alter table app_private.library_v4_config enable row level security;
alter table app_private.library_v4_entries enable row level security;
revoke all on app_private.library_v4_config,app_private.library_v4_entries from public,anon,authenticated,service_role;
revoke all on function app_private.library_v4_project_entry(uuid,jsonb),app_private.library_v4_project_change(),
 app_private.library_v4_baseline(uuid,jsonb,integer),app_private.library_v4_delta(uuid,uuid,bigint,bigint,integer),
 app_private.library_v4_metadata(uuid,uuid,uuid[]),app_private.library_v4_read_account(uuid) from public,anon,authenticated,service_role;
revoke all on function public.v4_library_page(jsonb,integer),public.v4_library_changes(uuid,bigint,bigint,integer),
 public.v4_library_metadata(uuid,uuid[]) from public,anon,authenticated,service_role;
grant execute on function public.v4_library_page(jsonb,integer),public.v4_library_changes(uuid,bigint,bigint,integer),
 public.v4_library_metadata(uuid,uuid[]) to authenticated;
notify pgrst,'reload schema';
commit;
