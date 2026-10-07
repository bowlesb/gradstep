-- Indexed current-library queries. See docs/architecture/LIBRARY_V4.md.
-- Additive, no customer switch or capacity increase. Query generations are
-- explicitly invalidated, not historical snapshots or replication cursors.
begin;
set local lock_timeout='15s';
lock table app_private.accounts in exclusive mode;
lock table app_private.library_v4_entries in share row exclusive mode;

create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;
-- An existing differently placed extension needs an explicit deployment review.
do $$ begin
 if (select extnamespace from pg_extension where extname='pg_trgm')<>'extensions'::regnamespace
 then raise exception 'library_search_extension_schema'; end if;
end $$;

create function app_private.library_search_normalize(p text) returns text
language sql immutable strict set search_path='' as $$
 select lower(normalize(p,NFKC) collate pg_catalog.pg_c_utf8) collate "C"
$$;
create function app_private.library_search_version() returns text
language sql stable set search_path='' as $$
 select 'nfkc-simple-lower-v1-pg'||(current_setting('server_version_num')::integer/10000)::text
  ||'-'||coalesce(pg_collation_actual_version('pg_catalog.pg_c_utf8'::regcollation),'unknown')
$$;
alter table app_private.library_v4_config add column search_version text;
update app_private.library_v4_config set search_version=app_private.library_search_version();
alter table app_private.library_v4_config alter column search_version set not null;
alter table app_private.library_sync_state add column query_revision bigint not null default 0 check(query_revision>=0);

-- Full text is stored once per immutable metadata ID. Normalization can expand
-- valid Unicode; do not reject existing canonical writes with a smaller cap.
create function app_private.library_query_category_tags(p_categories jsonb) returns text[]
language sql immutable set search_path='' as $$
 -- gradstep-tags-v1 category names; parity checked against the shared vocabulary.
 with names as (
  select '{"cs.LG":"Machine learning","stat.ML":"Machine learning","cs.CL":"Natural language processing","cs.CV":"Computer vision","eess.IV":"Computer vision","eess.AS":"Speech and audio","cs.SD":"Speech and audio","cs.RO":"Robotics","cs.IR":"Information retrieval","math.OC":"Optimization","cs.CR":"Security","cs.AI":"Artificial intelligence","cs.MA":"Multi-agent systems","cs.NE":"Evolutionary computation","q-bio.BM":"Molecular modeling","q-bio.GN":"Computational biology"}'::jsonb->>value name,ordinality n
  from jsonb_array_elements_text(p_categories) with ordinality
 ), first_names as (select name,min(n) n from names where name is not null group by name order by min(n) limit 3)
 select coalesce(array_agg(name order by n),'{}') from first_names
$$;
create table app_private.library_query_metadata (
 metadata_id uuid primary key references app_private.catalog_metadata(id),
 title_key text collate "C" not null,
 search_text text collate "C" not null,
 summary jsonb not null check(jsonb_typeof(summary)='object'),
 year_value integer,
 fallback_tags text[] not null
);
create index library_query_metadata_text on app_private.library_query_metadata using gin(search_text extensions.gin_trgm_ops);

create function app_private.library_query_metadata_project(m app_private.catalog_metadata) returns void
language plpgsql security definer set search_path='' as $$
declare authors jsonb; fields text[]; y integer;
begin
 select coalesce(jsonb_agg(x.value order by x.ordinality),'[]'::jsonb) into authors
 from jsonb_array_elements(m.metadata->'authors') with ordinality x where x.ordinality<=3;
 select array_agg(value order by position) into fields from (
  select m.metadata->>'title' value,0::bigint position
  union all select value,ordinality from jsonb_array_elements_text(m.metadata->'authors') with ordinality
  union all select m.metadata->>'abstract',1000
  union all select m.metadata->>'venue',1001
  union all select m.source_id,1002
  union all select m.source_id||'v'||m.source_revision::text,1003
  union all select value,2000+ordinality from jsonb_array_elements_text(m.metadata->'categories') with ordinality
 ) f;
 y:=case when m.metadata->>'published_at' ~ '^[0-9]{4}-' then left(m.metadata->>'published_at',4)::integer end;
 insert into app_private.library_query_metadata values(m.id,
  app_private.library_search_normalize(m.metadata->>'title'),
  app_private.library_search_normalize(array_to_string(fields,chr(10))),
  jsonb_build_object('title',m.metadata->'title','authors',authors,
   'author_count',jsonb_array_length(m.metadata->'authors'),'year',y,'venue',m.metadata->'venue'),y,
  app_private.library_query_category_tags(m.metadata->'categories'));
end $$;
create function app_private.library_query_metadata_trigger() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.library_query_metadata_project(new);
 return null;
end $$;
create trigger library_query_metadata_project after insert on app_private.catalog_metadata
 for each row execute function app_private.library_query_metadata_trigger();
-- Run the same projection for pre-existing immutable rows without rewriting them.
do $$ declare m app_private.catalog_metadata; begin
 for m in select * from app_private.catalog_metadata loop
  perform app_private.library_query_metadata_project(m);
 end loop;
end $$;

create function app_private.library_query_tags(e jsonb) returns text[]
language sql immutable set search_path='' as $$
 with candidates as (
  select value,ordinality n from jsonb_array_elements_text(coalesce(e->'tags','[]'::jsonb)) with ordinality c
  where not exists(select 1 from jsonb_array_elements_text(coalesce(e->'hidden_tags','[]'::jsonb)) h
   where lower(h.value collate pg_catalog.pg_c_utf8)=lower(c.value collate pg_catalog.pg_c_utf8))
  union all select value,1000+ordinality from jsonb_array_elements_text(coalesce(e->'user_tags','[]'::jsonb)) with ordinality
 ), unique_tags as (
  -- Tag identity is case-insensitive, not compatibility-normalized. NFKC is
  -- deliberately only for search; distinct ML / fullwidth ML labels survive.
  select distinct on (lower(value collate pg_catalog.pg_c_utf8)) value,n
  from candidates order by lower(value collate pg_catalog.pg_c_utf8),n
 ) select coalesce(array_agg(value order by n),'{}') from unique_tags
$$;

create table app_private.library_query_entries (
 account_id uuid not null references app_private.library_sync_state(account_id) on delete cascade,
 kind text not null check(kind in ('item','import')), id uuid not null,
 metadata_id uuid references app_private.library_query_metadata(metadata_id),
 created_seq bigint not null, visible boolean not null, archived boolean not null,
 source text, source_id text, library_item_id uuid,
 effective_tags text[] not null, tag_keys text[] not null,
 own_search text collate "C" not null,
 title_missing boolean not null, title_prefix text collate "C" not null,
 year_missing boolean not null, year_value integer not null,
 primary key(account_id,kind,id),
 foreign key(account_id,kind,id) references app_private.library_v4_entries(account_id,kind,id) on delete cascade
);
create index library_query_recent on app_private.library_query_entries(account_id,archived,created_seq,id,kind) where visible;
-- Prefix <=64 characters: safe for every valid multibyte title, even after NFKC.
-- The query orders by the FULL key inside each prefix; this is not truncation.
create index library_query_title on app_private.library_query_entries(account_id,archived,title_missing,title_prefix,id,kind) where visible;
create index library_query_year on app_private.library_query_entries(account_id,archived,year_missing,year_value,id,kind) where visible;
create index library_query_source on app_private.library_query_entries(account_id,source) where visible;
create index library_query_tags on app_private.library_query_entries using gin(tag_keys);
create index library_query_own_text on app_private.library_query_entries using gin(own_search extensions.gin_trgm_ops);

create function app_private.library_query_project(a uuid,k text,i uuid,m uuid,c bigint,e jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare tags text[]:=app_private.library_query_tags(e); keys text[]; meta app_private.library_query_metadata; changed integer; was_visible boolean;
begin
 select visible into was_visible from app_private.library_query_entries where account_id=a and kind=k and id=i;
 select * into meta from app_private.library_query_metadata where metadata_id=m;
 if m is not null and not found then raise exception 'library_query_metadata_missing'; end if;
 if cardinality(tags)=0 and m is not null then tags:=meta.fallback_tags; end if;
 select coalesce(array_agg(lower(t collate pg_catalog.pg_c_utf8) order by n),'{}') into keys from unnest(tags) with ordinality x(t,n);
 insert into app_private.library_query_entries values(a,k,i,m,c,(e->>'visible')::boolean,coalesce((e->>'archived')::boolean,false),
  e->>'source',e->>'source_id',(e->>'library_item_id')::uuid,tags,keys,
  app_private.library_search_normalize(coalesce(e->>'source_id','')||chr(10)||array_to_string(tags,chr(10))),
  m is null,coalesce(left(meta.title_key,64),''),meta.year_value is null,coalesce(meta.year_value,0))
 on conflict(account_id,kind,id) do update set metadata_id=excluded.metadata_id,created_seq=excluded.created_seq,
  visible=excluded.visible,archived=excluded.archived,source=excluded.source,source_id=excluded.source_id,
  library_item_id=excluded.library_item_id,effective_tags=excluded.effective_tags,tag_keys=excluded.tag_keys,
  own_search=excluded.own_search,title_missing=excluded.title_missing,title_prefix=excluded.title_prefix,
  year_missing=excluded.year_missing,year_value=excluded.year_value
 where (library_query_entries.metadata_id,library_query_entries.created_seq,library_query_entries.visible,
  library_query_entries.archived,library_query_entries.source,library_query_entries.source_id,
  library_query_entries.library_item_id,library_query_entries.effective_tags)
 is distinct from (excluded.metadata_id,excluded.created_seq,excluded.visible,excluded.archived,excluded.source,
  excluded.source_id,excluded.library_item_id,excluded.effective_tags);
 get diagnostics changed=row_count;
 if changed>0 and (coalesce(was_visible,false) or (e->>'visible')::boolean) then
  update app_private.library_sync_state set query_revision=query_revision+1 where account_id=a;
 end if;
end $$;
create function app_private.library_query_project_trigger() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.library_query_project(new.account_id,new.kind,new.id,new.metadata_id,new.created_seq,new.entry);
 return null;
end $$;
create trigger library_query_project after insert or update on app_private.library_v4_entries
 for each row execute function app_private.library_query_project_trigger();
do $$ declare e app_private.library_v4_entries; begin
 for e in select * from app_private.library_v4_entries order by account_id,created_seq,id,kind loop
  perform app_private.library_query_project(e.account_id,e.kind,e.id,e.metadata_id,e.created_seq,e.entry);
 end loop;
end $$;

-- Literal LIKE supports pg_trgm without granting SQL wildcard semantics.
create function app_private.library_query_pattern(p text) returns text
language sql immutable strict set search_path='' as $$
 select '%'||replace(replace(replace(p,chr(92),chr(92)||chr(92)),'%',chr(92)||'%'),'_',chr(92)||'_')||'%'
$$;

create function app_private.library_query_spec(p jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare q text; terms text[]; s text; d text; a text; src text; tag text;
begin
 if p is null or jsonb_typeof(p)<>'object' or octet_length(p::text)>4096
  or (p-'text'-'sort'-'direction'-'archive'-'source'-'tag')<>'{}'::jsonb
  or exists(select 1 from jsonb_each(p) where jsonb_typeof(value)<>'string') then raise exception 'invalid_library_query'; end if;
 q:=coalesce(p->>'text','');
 if octet_length(q)>512 then raise exception 'invalid_library_query'; end if;
 select coalesce(array_agg(t order by t collate "C"),'{}') into terms from (
  select distinct t from regexp_split_to_table(app_private.library_search_normalize(q) collate pg_catalog.pg_c_utf8,'[[:space:]]+') t where t<>''
 ) x;
 if cardinality(terms)>16 then raise exception 'invalid_library_query'; end if;
 s:=coalesce(p->>'sort','recent'); d:=coalesce(p->>'direction',case when s='title' then 'asc' else 'desc' end);
 a:=coalesce(p->>'archive','active'); src:=coalesce(p->>'source','all');
 if s not in ('recent','title','year') or d not in ('asc','desc') or a not in ('active','archived','all') or src not in ('all','arxiv','web')
 then raise exception 'invalid_library_query'; end if;
 if p ? 'tag' then
  if octet_length(p->>'tag') not between 1 and 120 then raise exception 'invalid_library_query'; end if;
  tag:=lower((p->>'tag') collate pg_catalog.pg_c_utf8);
 end if;
 return jsonb_build_object('terms',to_jsonb(terms),'sort',s,'direction',d,'archive',a,'source',src,'tag',tag);
end $$;

-- One STABLE call sees revision + candidate rows + current decoration together.
-- Continuations store only an anchor identity: the immutable query revision
-- binds its full ordering tuple, which is resolved and validated on the server.
create function app_private.library_query_page(a uuid,p_query jsonb,p_cursor jsonb,p_limit integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare spec jsonb:=app_private.library_query_spec(p_query); cfg app_private.library_v4_config; rev bigint;
 fingerprint text:=encode(sha256(convert_to(spec::text,'UTF8')),'hex');
 predicates text:='q.account_id=$1 and q.visible and not (q.kind=''import'' and q.library_item_id is not null and exists(select 1 from app_private.library_query_entries linked where linked.account_id=q.account_id and linked.kind=''item'' and linked.id=q.library_item_id and linked.visible))';
 order_by text; comparison text; key_expr text; key_arg text; missing_expr text; prefix_expr text; direction text:=spec->>'direction';
 patterns text[]; term text; j integer:=0; anchor record; result jsonb; after_kind text; after_id uuid;
 sql_text text; ordinal integer; small_library boolean:=false;
begin
 if p_limit is null or p_limit not between 1 and 50 then raise exception 'invalid_library_page'; end if;
 select * into strict cfg from app_private.library_v4_config;
 if cfg.search_version is distinct from app_private.library_search_version() then raise exception 'library_query_rebuild_required'; end if;
 select query_revision into strict rev from app_private.library_sync_state where account_id=a;
 if p_cursor is not null then
  if jsonb_typeof(p_cursor)<>'object' or octet_length(p_cursor::text)>2048
   or (p_cursor-'format'-'dataset_epoch'-'account_id'-'search_version'-'query_revision'-'query_sha256'-'kind'-'id')<>'{}'::jsonb
   or p_cursor->'format' is distinct from '4'::jsonb or p_cursor->>'account_id' is distinct from a::text
   or p_cursor->>'query_sha256' is distinct from fingerprint
   or jsonb_typeof(p_cursor->'query_revision') is distinct from 'number'
   or not coalesce(p_cursor->>'query_revision' ~ '^[0-9]{1,19}$',false)
   or (p_cursor->>'query_revision')::numeric>9223372036854775807
   or p_cursor->>'kind' not in ('item','import')
   or jsonb_typeof(p_cursor->'kind') is distinct from 'string'
   or not coalesce(p_cursor->>'id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
   then raise exception 'invalid_library_cursor'; end if;
  if p_cursor->>'dataset_epoch' is distinct from cfg.dataset_epoch::text
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
   select 1 from app_private.library_query_entries where account_id=a and visible limit 51
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
   ||predicates||' and q.kind=$3 and q.id=$4' into anchor using a,patterns,after_kind,after_id;
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
   ||jsonb_build_object(''tags'',to_jsonb(effective_tags)),''state'',e.entry) row
  from numbered q join app_private.library_v4_entries e using(account_id,kind,id) where n<=$8
 ), sized as (select *,sum(octet_length(row::text)+2) over(order by n) bytes from rendered),
 selected as materialized (select * from sized where bytes<=1044480),
 last_row as (select * from selected order by n desc limit 1)
 select jsonb_build_object(''rows'',coalesce((select jsonb_agg(row order by n) from selected),''[]''::jsonb),
  ''has_more'',exists(select 1 from numbered where n>coalesce((select n from last_row),0)),
  ''anchor'',(select jsonb_build_object(''kind'',kind,''id'',id) from last_row))';
 if after_id is null then
  execute sql_text into result using a,patterns,after_kind,after_id,false,''::text,null,p_limit;
 else
  execute sql_text into result using a,patterns,after_kind,after_id,anchor.missing,anchor.prefix,anchor.value,p_limit;
 end if;
 if result->'rows'='[]'::jsonb and (result->>'has_more')::boolean then raise exception 'library_page_too_large'; end if;
 return (result-'anchor')||jsonb_build_object('format',4,'account_id',a,'dataset_epoch',cfg.dataset_epoch,
  'search_version',cfg.search_version,'query_revision',rev,'query_sha256',fingerprint,
  'next_cursor',case when (result->>'has_more')::boolean then jsonb_build_object('format',4,'account_id',a,
   'dataset_epoch',cfg.dataset_epoch,'search_version',cfg.search_version,'query_revision',rev,'query_sha256',fingerprint)||(result->'anchor') end);
end $$;

create function public.v4_library_query(p_query jsonb default '{}'::jsonb,p_cursor jsonb default null,p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform app_private.library_v4_read_account(a);
 perform public.worker_consume_request(a,'library-read');
 result:=app_private.library_query_page(a,p_query,p_cursor,p_limit);
 perform app_private.consume_library_transfer(a,result);
 return result;
end $$;

alter table app_private.library_query_metadata enable row level security;
alter table app_private.library_query_entries enable row level security;
revoke all on app_private.library_query_metadata,app_private.library_query_entries from public,anon,authenticated,service_role;
revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
revoke all on function public.v4_library_query(jsonb,jsonb,integer) from public,anon,authenticated,service_role;
grant execute on function public.v4_library_query(jsonb,jsonb,integer) to authenticated;

-- Account rows survive deletion for billing; diagnose derived personal rows as
-- well as the legacy content, even if a future interrupted cleanup leaves them.
alter function public.worker_account_deletion_status(uuid) set schema app_private;
create function public.worker_account_deletion_status(p_account_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 with old as (select app_private.worker_account_deletion_status(p_account_id) value),
 derived as (select (select count(*) from app_private.library_v4_entries where account_id=p_account_id)
  +(select count(*) from app_private.library_query_entries where account_id=p_account_id) n)
 select old.value||jsonb_build_object('personal_rows',(old.value->>'personal_rows')::bigint+derived.n,
  'library_derived_rows',derived.n) from old,derived
$$;
alter function public.worker_account_deletions_pending(integer) set schema app_private;
create function public.worker_account_deletions_pending(p_limit integer default 5) returns uuid[]
language sql stable security definer set search_path='' as $$
 select coalesce(array_agg(id order by closed_at,id),'{}') from (
  select a.id,a.closed_at from app_private.accounts a
  where a.id=any(app_private.worker_account_deletions_pending(20))
   or (a.closed_at is not null and a.closed_at>now()-interval '30 days'
    and (exists(select 1 from app_private.library_v4_entries e where e.account_id=a.id)
     or exists(select 1 from app_private.library_query_entries q where q.account_id=a.id)))
  order by a.closed_at,a.id limit greatest(1,least(p_limit,20))
 ) pending
$$;
revoke all on function app_private.worker_account_deletion_status(uuid),app_private.worker_account_deletions_pending(integer)
 from public,anon,authenticated,service_role;
revoke all on function public.worker_account_deletion_status(uuid),public.worker_account_deletions_pending(integer)
 from public,anon,authenticated,service_role;
grant execute on function public.worker_account_deletion_status(uuid),public.worker_account_deletions_pending(integer) to service_role;
notify pgrst,'reload schema';
commit;
