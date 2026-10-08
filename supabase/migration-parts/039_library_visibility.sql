-- Integration fragment for pending039, after library_descriptor_ref is defined.
-- Fold into039 before deployment; this is not an independently deployable migration.
-- Canonical mutations keep one journal. Visibility is persisted per entry, never
-- inferred from missing source metadata after a removal, and never per whole batch.
lock table app_private.accounts in exclusive mode;
lock table app_private.library_policy,app_private.library_sync_state,app_private.library_items,
 app_private.import_requests,app_private.library_changes,app_private.library_v4_entries,
 app_private.library_query_entries in share row exclusive mode;

alter table app_private.library_v4_config add column upload_dataset_epoch uuid not null default gen_random_uuid();
alter table app_private.library_v4_config add constraint library_visibility_epochs_distinct check(dataset_epoch<>upload_dataset_epoch);
alter table app_private.library_v4_entries add column minimum_source_level smallint not null default 2 check(minimum_source_level between 2 and 4);
alter table app_private.library_query_entries add column minimum_source_level smallint not null default 2 check(minimum_source_level between 2 and 4);

create or replace function app_private.library_entry_level(p_entry jsonb) returns integer
language sql immutable set search_path='' as $$
 select coalesce((p_entry->>'minimum_source_level')::integer,
  case p_entry->>'source' when 'web' then 3 when 'upload' then 4 else 2 end)
$$;

-- A derived minimum is only a batch SEEK hint. The actual reader always filters
-- every entry, so a grouped public/upload change cannot leak the hidden member.
-- Generated storage backfills this hint without modifying historical entries.
create function app_private.library_change_level(e jsonb) returns smallint
language sql immutable set search_path='' as $$
 select min(app_private.library_entry_level(x.value))::smallint from jsonb_array_elements(e) x
$$;
alter table app_private.library_changes add column minimum_source_level smallint
 generated always as (app_private.library_change_level(entries)) stored not null
 check(minimum_source_level between 2 and 4);
create index library_changes_visibility on app_private.library_changes(account_id,minimum_source_level,seq);

-- Equality on each bounded capability range uses the same B-tree, even in a
-- generic prepared plan. At most three * p_limit candidates are merged. This
-- preserves installed full readers' nonempty-continuation contract without
-- expanding/scanning the JSON for every hidden upload on each page.
create function app_private.library_visible_changes(a uuid,p_after bigint,p_through bigint,p_limit integer,p_level integer)
returns table(seq bigint,entries jsonb) language sql stable security definer set search_path='' as $$
 with ids as materialized (
  select c.seq from (
   (select j.seq from app_private.library_changes j
    where j.account_id=a and j.minimum_source_level=2 and j.seq>p_after and j.seq<=p_through order by j.seq limit p_limit)
   union all
   (select j.seq from app_private.library_changes j
    where p_level>=3 and j.account_id=a and j.minimum_source_level=3 and j.seq>p_after and j.seq<=p_through order by j.seq limit p_limit)
   union all
   (select j.seq from app_private.library_changes j
    where p_level>=4 and j.account_id=a and j.minimum_source_level=4 and j.seq>p_after and j.seq<=p_through order by j.seq limit p_limit)
  ) c order by c.seq limit p_limit
 ) select j.seq,j.entries from ids join app_private.library_changes j on j.account_id=a and j.seq=ids.seq order by j.seq
$$;

create function app_private.library_stamp_entry(a uuid,e jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare prior app_private.library_v4_entries; level integer; src text:=e->>'source'; ref jsonb;
begin
 if e is null or jsonb_typeof(e) is distinct from 'object' or not coalesce(e->>'kind' in ('item','import'),false) then raise exception 'invalid_library_compact_entry'; end if;
 select * into prior from app_private.library_v4_entries where account_id=a and kind=e->>'kind' and id=(e->>'id')::uuid;
 level:=case when src is null then coalesce(prior.minimum_source_level,2)
  when src='arxiv' then 2 when src='web' then 3 when src='upload' then 4 end;
 if level is null or (prior.id is not null and src is not null and prior.minimum_source_level<>level)
  or (e ? 'minimum_source_level' and e->'minimum_source_level' is distinct from to_jsonb(level))
 then raise exception 'library_source_identity_conflict'; end if;
 -- An unchanged old envelope ref in an emitted event must not replace the
 -- current CAS result. Stamp from authority at commit; tombstones retain their pin.
 ref:=case when e->>'source_id' is not null then app_private.library_descriptor_ref(a,e->>'source_id')
  else prior.entry->'descriptor_ref' end;
 return (e-'descriptor_ref')||jsonb_build_object('minimum_source_level',level)
  ||case when ref is not null and ref<>'null'::jsonb then jsonb_build_object('descriptor_ref',ref) else '{}'::jsonb end;
end $$;

create function app_private.library_read_entry(e jsonb,p_level integer,p_compact boolean default false) returns jsonb
language sql immutable set search_path='' as $$
 select (e-'minimum_source_level')-case when p_level<4 then array['descriptor_ref'] else '{}'::text[] end
  -case when p_compact then array['metadata'] else '{}'::text[] end
$$;

create function app_private.library_stamp_change() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 select jsonb_agg(app_private.library_stamp_entry(new.account_id,x.value) order by x.ordinality) into new.entries
 from jsonb_array_elements(new.entries) with ordinality x;
 return new;
end $$;
create trigger library_stamp_change before insert on app_private.library_changes
 for each row execute function app_private.library_stamp_change();

-- Stamp BEFORE admission calculates encoded bytes. The trigger also protects
-- internal direct inserts; customer roles have no table access. The generated
-- encoded_bytes column continues to measure the actual persisted JSON.
create or replace function app_private.library_emit(a uuid,s bigint,e jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare p app_private.library_policy; bytes bigint;
begin
 if e is null or jsonb_typeof(e)<>'array' or jsonb_array_length(e) not between 1 and 4 then raise exception 'library_change_too_large'; end if;
 select jsonb_agg(app_private.library_stamp_entry(a,x.value) order by x.ordinality) into e from jsonb_array_elements(e) with ordinality x;
 bytes:=octet_length(e::text)+128;
 select * into strict p from app_private.library_policy;
 if bytes>131072 then raise exception 'library_change_too_large'; end if;
 if (select last_seq from app_private.library_sync_state where account_id=a)<>s then raise exception 'library_sequence_mismatch'; end if;
 if (select coalesce(sum(encoded_bytes),0) from app_private.library_changes where account_id=a)+bytes>p.account_journal_bytes
  or (select count(*) from app_private.library_changes where account_id=a)+1>p.account_journal_events then
  delete from app_private.library_changes where account_id=a;
  update app_private.library_sync_state set retained_after=s-1 where account_id=a;
 end if;
 if (select coalesce(sum(encoded_bytes),0) from app_private.library_changes)+bytes>p.environment_journal_bytes
  or (select count(*) from app_private.library_changes)+1>p.environment_journal_events then
  delete from app_private.library_changes;
  update app_private.library_sync_state set retained_after=case when account_id=a then s-1 else last_seq end;
 end if;
 insert into app_private.library_changes(account_id,seq,entries) values(a,s,e);
end $$;

create or replace function app_private.library_v4_project_entry(a uuid,e jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare compact jsonb:=app_private.library_stamp_entry(a,e)-'metadata'; previous app_private.library_v4_entries;
 k text:=e->>'kind'; entry_id uuid:=(e->>'id')::uuid;
 created bigint:=(e->>'created_seq')::bigint; state bigint:=(e->>'state_seq')::bigint;
 level integer:=app_private.library_entry_level(compact);
begin
 insert into app_private.library_v4_entries(account_id,kind,id,created_seq,state_seq,metadata_id,entry,minimum_source_level)
 values(a,k,entry_id,created,state,(e->>'metadata_id')::uuid,compact,level)
 on conflict(account_id,kind,id) do update
 set state_seq=excluded.state_seq,metadata_id=excluded.metadata_id,entry=excluded.entry
 where app_private.library_v4_entries.state_seq<excluded.state_seq
  and app_private.library_v4_entries.created_seq=excluded.created_seq
  and app_private.library_v4_entries.minimum_source_level=excluded.minimum_source_level;
 if not found then
  select * into strict previous from app_private.library_v4_entries where account_id=a and kind=k and id=entry_id;
  if previous.created_seq<>created or previous.minimum_source_level<>level then raise exception 'library_compact_identity_conflict'; end if;
  if previous.state_seq=state and previous.entry is distinct from compact then raise exception 'library_compact_state_conflict'; end if;
 end if;
end $$;

-- Backfill existing projections only; never rewrite the immutable journal.
-- No upload existed before039. Historical rows without an explicit level retain
-- the legacy arxiv/web classification; all new removal events persist their level.
alter table app_private.library_v4_entries disable trigger library_query_project;
update app_private.library_v4_entries set minimum_source_level=app_private.library_entry_level(entry);
update app_private.library_v4_entries set entry=app_private.library_stamp_entry(account_id,entry);
alter table app_private.library_v4_entries enable trigger library_query_project;

create or replace function app_private.library_query_project(a uuid,k text,i uuid,m uuid,c bigint,e jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare tags text[]:=app_private.library_query_tags(e); keys text[]; meta app_private.library_query_metadata; changed integer; was_visible boolean; level integer:=app_private.library_entry_level(e);
begin
 select visible into was_visible from app_private.library_query_entries where account_id=a and kind=k and id=i;
 select * into meta from app_private.library_query_metadata where metadata_id=m;
 if m is not null and not found then raise exception 'library_query_metadata_missing'; end if;
 if cardinality(tags)=0 and m is not null then tags:=meta.fallback_tags; end if;
 select coalesce(array_agg(lower(t collate pg_catalog.pg_c_utf8) order by n),'{}') into keys from unnest(tags) with ordinality x(t,n);
 insert into app_private.library_query_entries(account_id,kind,id,metadata_id,created_seq,visible,archived,source,source_id,library_item_id,
  effective_tags,tag_keys,own_search,title_missing,title_prefix,year_missing,year_value,minimum_source_level) values(a,k,i,m,c,(e->>'visible')::boolean,coalesce((e->>'archived')::boolean,false),
  e->>'source',e->>'source_id',(e->>'library_item_id')::uuid,tags,keys,
  app_private.library_search_normalize(coalesce(e->>'source_id','')||chr(10)||array_to_string(tags,chr(10))),
  m is null,coalesce(left(meta.title_key,64),''),meta.year_value is null,coalesce(meta.year_value,0),level)
 on conflict(account_id,kind,id) do update set metadata_id=excluded.metadata_id,created_seq=excluded.created_seq,
  visible=excluded.visible,archived=excluded.archived,source=excluded.source,source_id=excluded.source_id,
  library_item_id=excluded.library_item_id,effective_tags=excluded.effective_tags,tag_keys=excluded.tag_keys,
  own_search=excluded.own_search,title_missing=excluded.title_missing,title_prefix=excluded.title_prefix,
  year_missing=excluded.year_missing,year_value=excluded.year_value,minimum_source_level=excluded.minimum_source_level
 where (library_query_entries.metadata_id,library_query_entries.created_seq,library_query_entries.visible,
  library_query_entries.archived,library_query_entries.source,library_query_entries.source_id,
  library_query_entries.library_item_id,library_query_entries.effective_tags,library_query_entries.minimum_source_level)
 is distinct from (excluded.metadata_id,excluded.created_seq,excluded.visible,excluded.archived,excluded.source,
  excluded.source_id,excluded.library_item_id,excluded.effective_tags,excluded.minimum_source_level);
 get diagnostics changed=row_count;
 if changed>0 and (coalesce(was_visible,false) or (e->>'visible')::boolean) then
  update app_private.library_sync_state set query_revision=query_revision+1 where account_id=a;
 end if;
end $$;

create or replace function app_private.library_query_project_trigger() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.library_query_project(new.account_id,new.kind,new.id,new.metadata_id,new.created_seq,new.entry);
 if TG_OP='UPDATE' and old.entry->'descriptor_ref' is distinct from new.entry->'descriptor_ref' then
  -- An encrypted rename changes client-side ordering, including hidden mappings.
  update app_private.library_sync_state set query_revision=query_revision+1 where account_id=new.account_id;
 end if;
 return null;
end $$;

do $$ declare e app_private.library_v4_entries; begin
 for e in select * from app_private.library_v4_entries order by account_id,created_seq,id,kind loop
  perform app_private.library_query_project(e.account_id,e.kind,e.id,e.metadata_id,e.created_seq,e.entry);
 end loop;
end $$;
-- Current derived rows changed; reject pre-upgrade compact cache/cursor generations.
update app_private.library_v4_config set dataset_epoch=gen_random_uuid(),upload_dataset_epoch=gen_random_uuid();


create function app_private.library_compact_baseline_at(a uuid,p_cursor jsonb,p_limit integer,p_level integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare wire_format integer:=case when p_level=4 then 5 else 4 end; epoch uuid; high bigint; floor bigint; cursor_epoch uuid; cursor_high bigint;
 after_seq bigint:=0; after_id uuid:='00000000-0000-0000-0000-000000000000'; after_kind text:=''; result jsonb;
begin
 if p_level is null or p_level not in (3,4) or p_limit is null or p_limit not between 1 and 100 then raise exception 'invalid_library_page'; end if;
 select case when p_level=4 then upload_dataset_epoch else dataset_epoch end into strict epoch from app_private.library_v4_config where singleton;
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_cursor is not null then
  if jsonb_typeof(p_cursor) is distinct from 'object'
   or not (p_cursor ?& array['format','dataset_epoch','account_id','through','created_seq','id','kind'])
   or (p_cursor-array['format','dataset_epoch','account_id','through','created_seq','id','kind'])<>'{}'::jsonb
   or p_cursor->'format' is distinct from to_jsonb(wire_format) or p_cursor->'account_id' is distinct from to_jsonb(a)
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
   where account_id=a and kind=after_kind and id=after_id and created_seq=after_seq and minimum_source_level<=p_level)
  then raise exception 'invalid_library_cursor'; end if;
 end if;
 if high<floor then raise exception 'library_resync_required'; end if;
 with candidates as materialized (
  select created_seq,id,kind,app_private.library_read_entry(entry,p_level,true) entry from app_private.library_v4_entries
  where account_id=a and minimum_source_level<=p_level and created_seq<=high and (created_seq,id,kind)>(after_seq,after_id,after_kind)
  order by created_seq,id,kind limit p_limit
 ), sized as (
  select *,sum(octet_length(entry::text)+2) over(order by created_seq,id,kind) bytes from candidates
 ), selected as materialized (select * from sized where bytes<=1046528), last_row as (
  select created_seq,id,kind from selected order by created_seq desc,id desc,kind desc limit 1
 ) select jsonb_build_object('format',wire_format,'dataset_epoch',epoch,'account_id',a,'baseline_cursor',high,'retained_after',floor,
  'entries',coalesce((select jsonb_agg(entry order by created_seq,id,kind) from selected),'[]'::jsonb),
  'next_cursor',(select jsonb_build_object('format',wire_format,'dataset_epoch',epoch,'account_id',a,'through',high,
   'created_seq',created_seq,'id',id,'kind',kind) from last_row),
  'has_more',exists(select 1 from app_private.library_v4_entries e where e.account_id=a and e.minimum_source_level<=p_level and e.created_seq<=high
   and (e.created_seq,e.id,e.kind)>coalesce((select row(created_seq,id,kind) from last_row),row(after_seq,after_id,after_kind)))) into result;
 if result->'entries'='[]'::jsonb and (result->>'has_more')::boolean then raise exception 'library_page_too_large'; end if;
 return result;
end $$;

create function app_private.library_compact_delta_at(a uuid,p_dataset_epoch uuid,p_after bigint,p_through bigint,p_limit integer,p_level integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare wire_format integer:=case when p_level=4 then 5 else 4 end; epoch uuid; high bigint; floor bigint; result jsonb;
begin
 select case when p_level=4 then upload_dataset_epoch else dataset_epoch end into strict epoch from app_private.library_v4_config where singleton;
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_level is null or p_level not in (3,4) or p_dataset_epoch is null or p_after is null or p_after<0 or p_limit is null or p_limit not between 1 and 100
  or p_through<p_after then raise exception 'invalid_library_cursor'; end if;
 if p_dataset_epoch<>epoch then raise exception 'library_resync_required'; end if;
 if p_after>high or p_through>high then raise exception 'invalid_library_cursor'; end if;
 if p_after<floor then raise exception 'library_resync_required'; end if;
 high:=coalesce(p_through,high);
 -- Seek eligible batches before expanding JSON. The scan is bounded even when
 -- this account has a large hidden upload history between visible entries.
 with candidates as materialized (
  select * from app_private.library_visible_changes(a,p_after,high,p_limit+1,p_level)
 ), compact as materialized (
  select c.seq,(select coalesce(jsonb_agg(app_private.library_read_entry(x.value,p_level,true) order by x.ordinality),'[]'::jsonb)
   from jsonb_array_elements(c.entries) with ordinality x where app_private.library_entry_level(x.value)<=p_level) entries from candidates c order by c.seq limit p_limit
 ), sized as (select *,sum(octet_length(entries::text)+128) over(order by seq) bytes from compact),
 selected as materialized (select seq,entries from sized where bytes<=1046528),
 page as (select coalesce(jsonb_agg(jsonb_build_object('seq',seq,'entries',entries) order by seq) filter(where jsonb_array_length(entries)>0),'[]'::jsonb) changes,coalesce(max(seq),p_after) last from selected)
 select jsonb_build_object('format',wire_format,'dataset_epoch',epoch,'account_id',a,'through',high,'retained_after',floor,'changes',changes,
  'next_cursor',case when exists(select 1 from candidates where seq>page.last) then page.last else high end,
  'has_more',exists(select 1 from candidates where seq>page.last)) into result from page;
 return result;
end $$;

create function app_private.library_compact_metadata_at(a uuid,p_dataset_epoch uuid,p_metadata_ids uuid[],p_level integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare wire_format integer:=case when p_level=4 then 5 else 4 end; epoch uuid; result jsonb;
begin
 select case when p_level=4 then upload_dataset_epoch else dataset_epoch end into strict epoch from app_private.library_v4_config where singleton;
 if p_level is null or p_level not in (3,4) then raise exception 'invalid_library_metadata_request'; end if;
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
  where not exists(select 1 from app_private.library_v4_entries e where e.account_id=a and e.metadata_id=requested.id and e.minimum_source_level<=p_level)
   or not exists(select 1 from app_private.catalog_metadata m where m.id=requested.id and app_private.source_level(m.source_id)<=p_level))
 then raise exception 'library_metadata_unavailable' using errcode='42501'; end if;
 select jsonb_build_object('format',wire_format,'dataset_epoch',epoch,'account_id',a,'records',coalesce(jsonb_agg(
  jsonb_build_object('metadata_id',m.id,'version_id',m.version_id,
   'source',case when m.source_id like 'openalex:%' then 'web' when m.source_id like 'upload:%' then 'upload' else 'arxiv' end,
   'source_id',m.source_id,'source_revision',m.source_revision,'metadata',m.metadata,'recorded_at',m.recorded_at)
  order by requested.ordinality),'[]'::jsonb)) into result
 from unnest(p_metadata_ids) with ordinality requested(id,ordinality) join app_private.catalog_metadata m on m.id=requested.id;
 -- The immutable UUID/provenance identifies this record. catalog_metadata's
 -- internal jsonb hash is NOT a hash of serialized wire bytes and is not sent.
 return result;
end $$;

-- Full readers share the compact creation/visibility index, but render the
-- bounded page through the canonical builders. Old command acknowledgements
-- retain their exact pre-descriptor shape; v5 learns refs through observation.
create or replace function app_private.library_baseline_at(a uuid,p_cursor jsonb,p_limit integer,p_level integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare high bigint; floor bigint; cursor_high bigint; after_seq bigint:=0; epoch uuid; cursor_epoch uuid;
 after_id uuid:='00000000-0000-0000-0000-000000000000'; after_kind text:=''; result jsonb;
 cursor_keys text[]:=array['format','account_id','through','created_seq','id','kind'];
begin
 if p_limit is null or p_limit not between 1 and 100 or p_level is null or p_level not between 2 and 4 then raise exception 'invalid_library_page'; end if;
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_level=4 then
  cursor_keys:=cursor_keys||array['read_level','dataset_epoch'];
  select upload_dataset_epoch into strict epoch from app_private.library_v4_config;
 end if;
 if p_cursor is not null then
  if jsonb_typeof(p_cursor) is distinct from 'object' or not (p_cursor ?& cursor_keys)
   or (p_cursor-cursor_keys)<>'{}'::jsonb or p_cursor->'format' is distinct from '2'::jsonb
   or p_cursor->'account_id' is distinct from to_jsonb(a)
   or (p_level=4 and p_cursor->'read_level' is distinct from '4'::jsonb)
   or (p_level=4 and (jsonb_typeof(p_cursor->'dataset_epoch') is distinct from 'string'
    or not coalesce(p_cursor->>'dataset_epoch' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)))
   or jsonb_typeof(p_cursor->'through') is distinct from 'number' or not coalesce(p_cursor->>'through' ~ '^[0-9]{1,19}$',false)
   or jsonb_typeof(p_cursor->'created_seq') is distinct from 'number' or not coalesce(p_cursor->>'created_seq' ~ '^[0-9]{1,19}$',false)
   or jsonb_typeof(p_cursor->'id') is distinct from 'string'
   or not coalesce(p_cursor->>'id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
   or jsonb_typeof(p_cursor->'kind') is distinct from 'string' or p_cursor->>'kind' not in ('item','import')
  then raise exception 'invalid_library_cursor'; end if;
  begin
   cursor_high:=(p_cursor->>'through')::bigint; after_seq:=(p_cursor->>'created_seq')::bigint;
   after_id:=(p_cursor->>'id')::uuid; after_kind:=p_cursor->>'kind';
   if p_level=4 then cursor_epoch:=(p_cursor->>'dataset_epoch')::uuid; end if;
  exception when numeric_value_out_of_range or invalid_text_representation then raise exception 'invalid_library_cursor'; end;
  if p_level=4 and cursor_epoch<>epoch then raise exception 'library_resync_required'; end if;
  if cursor_high>high or after_seq<1 or after_seq>cursor_high then raise exception 'invalid_library_cursor'; end if;
  high:=cursor_high;
  if not exists(select 1 from app_private.library_v4_entries where account_id=a and kind=after_kind and id=after_id
   and created_seq=after_seq and minimum_source_level<=p_level) then raise exception 'invalid_library_cursor'; end if;
 end if;
 if high<floor then raise exception 'library_resync_required'; end if;
 with candidates as materialized (
  select created_seq,id,kind from app_private.library_v4_entries
  where account_id=a and minimum_source_level<=p_level and created_seq<=high
   and (created_seq,id,kind)>(after_seq,after_id,after_kind)
  order by created_seq,id,kind limit p_limit
 ), rendered as materialized (
  select created_seq,id,kind,app_private.library_read_entry(app_private.library_stamp_entry(a,
   case when kind='item' then app_private.library_item_entry(a,id) else app_private.library_import_entry(a,id) end),p_level) entry
  from candidates
 ), sized as (
  select *,sum(octet_length(entry::text)+2) over(order by created_seq,id,kind) bytes from rendered
 ), selected as materialized (select * from sized where bytes<=1046528), last_row as (
  select created_seq,id,kind from selected order by created_seq desc,id desc,kind desc limit 1
 ) select jsonb_build_object('format',2,'account_id',a,'baseline_cursor',high,'retained_after',floor,
  'entries',coalesce((select jsonb_agg(entry order by created_seq,id,kind) from selected),'[]'::jsonb),
  'next_cursor',(select jsonb_build_object('format',2,'account_id',a,'through',high,'created_seq',created_seq,'id',id,'kind',kind)
   ||case when p_level=4 then jsonb_build_object('read_level',4,'dataset_epoch',epoch) else '{}'::jsonb end from last_row),
  'has_more',exists(select 1 from app_private.library_v4_entries e where e.account_id=a and e.minimum_source_level<=p_level and e.created_seq<=high
   and (e.created_seq,e.id,e.kind)>coalesce((select row(created_seq,id,kind) from last_row),row(after_seq,after_id,after_kind)))) into result;
 if result->'entries'='[]'::jsonb and (result->>'has_more')::boolean then raise exception 'library_page_too_large'; end if;
 return result||case when p_level=4 then jsonb_build_object('dataset_epoch',epoch) else '{}'::jsonb end;
end $$;

create or replace function app_private.library_delta_at(a uuid,p_after bigint,p_through bigint,p_limit integer,p_level integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare high bigint; floor bigint; result jsonb;
begin
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_level is null or p_level not between 2 and 4 or p_after is null or p_after<0 or p_limit is null or p_limit not between 1 and 100
  or p_after>high or p_through>high or p_through<p_after then raise exception 'invalid_library_cursor'; end if;
 if p_after<floor then raise exception 'library_resync_required'; end if;
 high:=coalesce(p_through,high);
 -- Installed full decoders require a nonempty page and next_cursor equal to
 -- its last emitted batch when has_more=true. Indexed capability seeks preserve
 -- that contract without unbounded scans through hidden raw journal payloads.
 with candidates as materialized (
  select * from app_private.library_visible_changes(a,p_after,high,p_limit+1,p_level)
 ), rendered as materialized (
  select c.seq,(select coalesce(jsonb_agg(app_private.library_read_entry(x.value,p_level) order by x.ordinality),'[]'::jsonb)
   from jsonb_array_elements(c.entries) with ordinality x where app_private.library_entry_level(x.value)<=p_level) entries from candidates c order by c.seq limit p_limit
 ), sized as (select *,sum(octet_length(entries::text)+128) over(order by seq) bytes from rendered),
 selected as materialized (select seq,entries from sized where bytes<=1046528),
 page as (select coalesce(jsonb_agg(jsonb_build_object('seq',seq,'entries',entries) order by seq)
  filter(where jsonb_array_length(entries)>0),'[]'::jsonb) changes,coalesce(max(seq),p_after) last from selected)
 select jsonb_build_object('format',2,'account_id',a,'through',high,'retained_after',floor,'changes',changes,
  'next_cursor',case when exists(select 1 from candidates where seq>page.last) then page.last else high end,
  'has_more',exists(select 1 from candidates where seq>page.last)) into result from page;
 return result;
end $$;

create function app_private.library_query_page_at(a uuid,p_query jsonb,p_cursor jsonb,p_limit integer,p_level integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare wire_format integer:=case when p_level=4 then 5 else 4 end; epoch uuid; spec jsonb:=app_private.library_query_spec(p_query); cfg app_private.library_v4_config; rev bigint;
 fingerprint text:=encode(sha256(convert_to(spec::text,'UTF8')),'hex');
 predicates text:='q.account_id=$1 and q.minimum_source_level<=$9 and q.visible and not (q.kind=''import'' and q.library_item_id is not null and exists(select 1 from app_private.library_query_entries linked where linked.account_id=q.account_id and linked.kind=''item'' and linked.id=q.library_item_id and linked.minimum_source_level<=$9 and linked.visible))';
 order_by text; comparison text; key_expr text; key_arg text; missing_expr text; prefix_expr text; direction text:=spec->>'direction';
 patterns text[]; term text; j integer:=0; anchor record; result jsonb; after_kind text; after_id uuid;
 sql_text text; ordinal integer; small_library boolean:=false;
begin
 if p_level is null or p_level not in (3,4) or p_limit is null or p_limit not between 1 and 50 then raise exception 'invalid_library_page'; end if;
 if p_level<4 and spec->>'source'='upload' then raise exception 'invalid_library_query'; end if;
 select * into strict cfg from app_private.library_v4_config;
 epoch:=case when p_level=4 then cfg.upload_dataset_epoch else cfg.dataset_epoch end;
 if cfg.search_version is distinct from app_private.library_search_version() then raise exception 'library_query_rebuild_required'; end if;
 select query_revision into strict rev from app_private.library_sync_state where account_id=a;
 if p_cursor is not null then
  if jsonb_typeof(p_cursor)<>'object' or octet_length(p_cursor::text)>2048
   or (p_cursor-'format'-'dataset_epoch'-'account_id'-'search_version'-'query_revision'-'query_sha256'-'kind'-'id')<>'{}'::jsonb
   or p_cursor->'format' is distinct from to_jsonb(wire_format) or p_cursor->>'account_id' is distinct from a::text
   or p_cursor->>'query_sha256' is distinct from fingerprint
   or jsonb_typeof(p_cursor->'query_revision') is distinct from 'number'
   or not coalesce(p_cursor->>'query_revision' ~ '^[0-9]{1,19}$',false)
   or (p_cursor->>'query_revision')::numeric>9223372036854775807
   or p_cursor->>'kind' not in ('item','import')
   or jsonb_typeof(p_cursor->'kind') is distinct from 'string'
   or not coalesce(p_cursor->>'id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
   then raise exception 'invalid_library_cursor'; end if;
  if p_cursor->>'dataset_epoch' is distinct from epoch::text
   or p_cursor->>'search_version' is distinct from cfg.search_version
   or (p_cursor->>'query_revision')::bigint<>rev then raise exception 'library_query_restart_required'; end if;
  after_kind:=p_cursor->>'kind'; after_id:=(p_cursor->>'id')::uuid;
 end if;
 if spec->>'archive'<>'all' then predicates:=predicates||case when spec->>'archive'='archived' then ' and q.archived' else ' and not q.archived' end; end if;
 if spec->>'source'<>'all' then predicates:=predicates||' and q.source='||quote_literal(spec->>'source'); end if;
 if spec->>'tag' is not null then predicates:=predicates||' and q.tag_keys @> array['||quote_literal(spec->>'tag')||']::text[]'; end if;
 if jsonb_array_length(spec->'terms')>0 then
  -- A one-page account should not scan/hash the shared catalog for every term.
  -- Bound this decision itself at one more than the maximum page size. Larger
  -- libraries retain GIN metadata candidates; their selective searches benefit.
  select count(*)<=50 into small_library from (
   select 1 from app_private.library_query_entries where account_id=a and minimum_source_level<=p_level and visible limit 51
  ) bounded_account;
 end if;
 for term in select jsonb_array_elements_text(spec->'terms') loop
  j:=j+1; patterns:=array_append(patterns,app_private.library_query_pattern(term));
  if not small_library and term collate pg_catalog.pg_c_utf8 ~ '[[:alnum:]]{3}' then
   predicates:=predicates||format(' and (q.own_search like $2[%s] or q.metadata_id in (select sm.metadata_id from app_private.library_query_metadata sm where sm.search_text like $2[%s]))',j,j);
  else
   -- Small libraries and terms without useful trigrams stay on this account's
   -- joined metadata instead of scanning the shared catalog (still measured).
   predicates:=predicates||format(' and (q.own_search like $2[%s] or m.search_text like $2[%s])',j,j);
  end if;
 end loop;
 -- NULLs stay last for both directions. All ties use stable UUID + kind.
 missing_expr:=case spec->>'sort' when 'title' then 'q.title_missing' when 'year' then 'q.year_missing' else 'false' end;
 prefix_expr:=case spec->>'sort' when 'title' then 'q.title_prefix' else '''''::text collate "C"' end;
 key_expr:=case spec->>'sort' when 'title' then 'coalesce(m.title_key,'''') collate "C"' when 'year' then 'q.year_value' else 'q.created_seq' end;
 key_arg:=case when spec->>'sort'='title' then '$7::text collate "C"' else '$7::bigint' end;
 order_by:='missing asc,prefix '||direction||',value '||direction||',q.id '||direction||',q.kind '||direction;
 if after_id is not null then
  execute 'select '||missing_expr||' missing,'||prefix_expr||' prefix,('||key_expr||')::text value from app_private.library_query_entries q left join app_private.library_query_metadata m using(metadata_id) where '
   ||predicates||' and q.kind=$3 and q.id=$4' into anchor using a,patterns,after_kind,after_id,false,''::text,null::bigint,p_limit,p_level;
  get diagnostics ordinal=row_count;
  if ordinal<>1 then raise exception 'invalid_library_cursor'; end if;
  comparison:=case when direction='asc' then '>' else '<' end;
  -- missing=false always precedes missing=true, independent of direction.
  predicates:=predicates||format(' and ((%s)>$5 or ((%s)=$5 and (%s,%s,q.id,q.kind)%s($6,%s,$4,$3)))',
   missing_expr,missing_expr,prefix_expr,key_expr,comparison,key_arg);
  if spec->>'sort'='recent' then
   -- The generic tuple's constant prefix prevents a direct index seek. This
   -- equivalent typed guard lets the recent index start at the actual anchor.
   predicates:=predicates||format(' and (q.created_seq,q.id,q.kind)%s($7::bigint,$4,$3)',comparison);
  elsif spec->>'sort'='title' and direction='asc' then
   -- A coarse lower bound only; retain the strict FULL-title test above so
   -- colliding prefixes never truncate ordering or lose tied item/import IDs.
   predicates:=predicates||' and (q.title_missing,q.title_prefix)>=($5,$6)';
  end if;
 end if;
 sql_text:='with candidates as materialized (
  select q.*,m.summary,'||missing_expr||' missing,'||prefix_expr||' prefix,'||key_expr||' value
  from app_private.library_query_entries q left join app_private.library_query_metadata m using(metadata_id)
  where '||predicates||' order by '||order_by||' limit $8+1
 ), numbered as (select *,row_number() over(order by missing asc,prefix '||direction||',value '||direction||',id '||direction||',kind '||direction||') n from candidates),
 rendered as materialized (
  select n,kind,id,jsonb_build_object(''summary'',coalesce(summary,jsonb_build_object(''title'',null,''authors'',''[]''::jsonb,''author_count'',0,''year'',null,''venue'',null))
   ||jsonb_build_object(''tags'',to_jsonb(effective_tags)),''state'',app_private.library_read_entry(e.entry,$9,true)) row
  from numbered q join app_private.library_v4_entries e using(account_id,kind,id) where n<=$8
 ), sized as (select *,sum(octet_length(row::text)+2) over(order by n) bytes from rendered),
 selected as materialized (select * from sized where bytes<=1044480),
 last_row as (select * from selected order by n desc limit 1)
 select jsonb_build_object(''rows'',coalesce((select jsonb_agg(row order by n) from selected),''[]''::jsonb),
  ''has_more'',exists(select 1 from numbered where n>coalesce((select n from last_row),0)),
  ''anchor'',(select jsonb_build_object(''kind'',kind,''id'',id) from last_row))';
 if after_id is null then
  execute sql_text into result using a,patterns,after_kind,after_id,false,''::text,null,p_limit,p_level;
 else
  execute sql_text into result using a,patterns,after_kind,after_id,anchor.missing,anchor.prefix,anchor.value,p_limit,p_level;
 end if;
 if result->'rows'='[]'::jsonb and (result->>'has_more')::boolean then raise exception 'library_page_too_large'; end if;
 return (result-'anchor')||jsonb_build_object('format',wire_format,'account_id',a,'dataset_epoch',epoch,
  'search_version',cfg.search_version,'query_revision',rev,'query_sha256',fingerprint,
  'next_cursor',case when (result->>'has_more')::boolean then jsonb_build_object('format',wire_format,'account_id',a,
   'dataset_epoch',epoch,'search_version',cfg.search_version,'query_revision',rev,'query_sha256',fingerprint)||(result->'anchor') end);
end $$;

-- Existing compact/query RPC signatures stay unchanged. New v5 compact uses
-- wire format5; v5 full uses format2 plus read_level4 and the same upload epoch.
create or replace function app_private.library_v4_baseline(a uuid,p_cursor jsonb,p_limit integer) returns jsonb
language sql stable security definer set search_path='' as $$
 select app_private.library_compact_baseline_at(a,p_cursor,p_limit,3)
$$;
create or replace function app_private.library_v4_delta(a uuid,p_dataset_epoch uuid,p_after bigint,p_through bigint,p_limit integer) returns jsonb
language sql stable security definer set search_path='' as $$
 select app_private.library_compact_delta_at(a,p_dataset_epoch,p_after,p_through,p_limit,3)
$$;
create or replace function app_private.library_v4_metadata(a uuid,p_dataset_epoch uuid,p_metadata_ids uuid[]) returns jsonb
language sql stable security definer set search_path='' as $$
 select app_private.library_compact_metadata_at(a,p_dataset_epoch,p_metadata_ids,3)
$$;
create or replace function app_private.library_query_page(a uuid,p_query jsonb,p_cursor jsonb,p_limit integer) returns jsonb
language sql stable security definer set search_path='' as $$
 select app_private.library_query_page_at(a,p_query,p_cursor,p_limit,3)
$$;

create function app_private.library_upload_full_delta(a uuid,p_dataset_epoch uuid,p_after bigint,p_through bigint,p_limit integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare epoch uuid;
begin
 select upload_dataset_epoch into strict epoch from app_private.library_v4_config;
 if p_dataset_epoch is null then raise exception 'invalid_library_cursor'; end if;
 if p_dataset_epoch<>epoch then raise exception 'library_resync_required'; end if;
 return app_private.library_delta_at(a,p_after,p_through,p_limit,4)||jsonb_build_object('dataset_epoch',epoch);
end $$;

-- Never ship an epochless v5 overload: it would permit a restored highwater to
-- silently reuse stale rows. This signature existed only earlier in pending039.
drop function public.v5_library_changes(bigint,bigint,integer);

create or replace function public.v2_library_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_baseline_at(a,p_cursor,p_limit,2);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v2_library_changes(p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_delta_at(a,p_after,p_through,p_limit,2);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v3_library_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_baseline_at(a,p_cursor,p_limit,3);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v3_library_changes(p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_delta_at(a,p_after,p_through,p_limit,3);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v5_library_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_baseline_at(a,p_cursor,p_limit,4);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v5_library_changes(p_dataset_epoch uuid,p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_upload_full_delta(a,p_dataset_epoch,p_after,p_through,p_limit);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v5_library_compact_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_compact_baseline_at(a,p_cursor,p_limit,4);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v5_library_compact_changes(p_dataset_epoch uuid,p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_compact_delta_at(a,p_dataset_epoch,p_after,p_through,p_limit,4);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v5_library_metadata(p_dataset_epoch uuid,p_metadata_ids uuid[]) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_compact_metadata_at(a,p_dataset_epoch,p_metadata_ids,4);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

create or replace function public.v5_library_query(p_query jsonb default '{}'::jsonb,p_cursor jsonb default null,p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a); perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_query_page_at(a,p_query,p_cursor,p_limit,4);
 perform app_private.consume_library_transfer(a,result); return result;
end $$;

revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
revoke all on function public.v2_library_page(jsonb,integer) from public,anon,authenticated,service_role;
grant execute on function public.v2_library_page(jsonb,integer) to authenticated;
revoke all on function public.v2_library_changes(bigint,bigint,integer) from public,anon,authenticated,service_role;
grant execute on function public.v2_library_changes(bigint,bigint,integer) to authenticated;
revoke all on function public.v3_library_page(jsonb,integer) from public,anon,authenticated,service_role;
grant execute on function public.v3_library_page(jsonb,integer) to authenticated;
revoke all on function public.v3_library_changes(bigint,bigint,integer) from public,anon,authenticated,service_role;
grant execute on function public.v3_library_changes(bigint,bigint,integer) to authenticated;
revoke all on function public.v5_library_page(jsonb,integer) from public,anon,authenticated,service_role;
grant execute on function public.v5_library_page(jsonb,integer) to authenticated;
revoke all on function public.v5_library_changes(uuid,bigint,bigint,integer) from public,anon,authenticated,service_role;
grant execute on function public.v5_library_changes(uuid,bigint,bigint,integer) to authenticated;
revoke all on function public.v5_library_compact_page(jsonb,integer) from public,anon,authenticated,service_role;
grant execute on function public.v5_library_compact_page(jsonb,integer) to authenticated;
revoke all on function public.v5_library_compact_changes(uuid,bigint,bigint,integer) from public,anon,authenticated,service_role;
grant execute on function public.v5_library_compact_changes(uuid,bigint,bigint,integer) to authenticated;
revoke all on function public.v5_library_metadata(uuid,uuid[]) from public,anon,authenticated,service_role;
grant execute on function public.v5_library_metadata(uuid,uuid[]) to authenticated;
revoke all on function public.v5_library_query(jsonb,jsonb,integer) from public,anon,authenticated,service_role;
grant execute on function public.v5_library_query(jsonb,jsonb,integer) to authenticated;
