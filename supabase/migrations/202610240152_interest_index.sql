-- Interest index, step 2: the server layer for public papers (docs/architecture/INTEREST_INDEX.md).
-- gte-small fingerprints (pgvector halfvec) of every Feed pool paper and catalog paper with public metadata, a nested
-- topic map with stable append-only node IDs, term statistics, and immutable artifacts devices download. The server
-- never stores or receives a reader's interests: nothing here is per account. Additive; switched off by default
-- (enabled=false, serving='off'). Servers never contact arXiv: only metadata already in our tables is used.
begin;
set local lock_timeout='15s';

create schema if not exists extensions;
create extension if not exists vector with schema extensions;
do $$ begin
 if (select extnamespace from pg_extension where extname='vector')<>'extensions'::regnamespace
 then raise exception 'interest_vector_extension_schema'; end if;
end $$;

-- ---------- policy and run state ----------

create table app_private.interest_policy (
 singleton boolean primary key default true check(singleton),
 enabled boolean not null default false,
 serving text not null default 'off' check(serving in ('off','staff','all')),
 model_version text not null default 'gte-small@17e1f34/onnx-fp32@5927d17/mean-l2/v1' check(model_version ~ '^[a-z0-9@./_-]{1,96}$'),
 model_sha256 text not null default '398a29991324e0b383afa13375d681ced3079c83e097fb1ebd9290d7498523b3' check(model_sha256 ~ '^[0-9a-f]{64}$'),
 corpus_days integer not null default 180 check(corpus_days between 30 and 730),
 window_days integer not null default 14 check(window_days between 1 and 60),
 -- Owner's interim decision (2026-10-24): rebuild every two weeks until the corpus reaches weekly_after_papers, then weekly.
 rebuild_days_growing integer not null default 14 check(rebuild_days_growing between 1 and 60),
 rebuild_days integer not null default 7 check(rebuild_days between 1 and 60),
 weekly_after_papers integer not null default 50000 check(weekly_after_papers between 1000 and 1000000),
 rebuild_dow smallint not null default 0 check(rebuild_dow between 0 and 6),
 rebuild_hour smallint not null default 7 check(rebuild_hour between 0 and 23),
 min_corpus integer not null default 2000 check(min_corpus between 100 and 1000000),
 top_k integer not null default 20 check(top_k between 2 and 100),
 mid_size integer not null default 150 check(mid_size between 10 and 10000),
 leaf_size integer not null default 40 check(leaf_size between 5 and 1000),
 min_df integer not null default 3 check(min_df between 2 and 100),
 max_df_share real not null default 0.10 check(max_df_share > 0 and max_df_share <= 1),
 label_max_df_share real not null default 0.15 check(label_max_df_share > 0 and label_max_df_share <= 1),
 concept_min real not null default 0.02 check(concept_min between -1 and 1),
 keep_jaccard real not null default 0.5 check(keep_jaccard between 0 and 1),
 keep_cos real not null default 0.9 check(keep_cos between 0 and 1),
 drift_max real not null default 0.05 check(drift_max between 0 and 1),
 gate_warn real not null default 0.85 check(gate_warn between 0 and 1),
 gate_block real not null default 0.5 check(gate_block between 0 and 1),
 allow_low_stability boolean not null default false,
 force_rebuild boolean not null default false,
 max_corpus_rows integer not null default 150000 check(max_corpus_rows between 1000 and 1000000),
 max_terms integer not null default 500000 check(max_terms between 1000 and 5000000),
 artifact_max_bytes integer not null default 16777216 check(artifact_max_bytes between 65536 and 67108864),
 lease_seconds integer not null default 900 check(lease_seconds between 60 and 3600),
 updated_at timestamptz not null default now()
);
insert into app_private.interest_policy default values;

create table app_private.interest_state (
 singleton boolean primary key default true check(singleton),
 claim_id uuid, lease_until timestamptz,
 last_kick_at timestamptz, last_run_at timestamptz, last_shard_at timestamptz,
 check((claim_id is null)=(lease_until is null))
);
insert into app_private.interest_state default values;

create table app_private.interest_runs (
 id uuid primary key,
 started_at timestamptz not null default now(), finished_at timestamptz,
 state text not null default 'running' check(state in ('running','finished','failed')),
 counts jsonb not null default '{}' check(jsonb_typeof(counts)='object' and octet_length(counts::text)<=16384),
 error_code text check(error_code ~ '^[a-z_]{1,64}$')
);
create index interest_runs_recent on app_private.interest_runs(started_at desc);

-- ---------- fingerprints ----------

create sequence app_private.interest_fp_seq;
create table app_private.interest_papers (
 source_id text primary key check(char_length(source_id) between 1 and 128 and source_id not like 'upload:%'),
 title text not null check(char_length(title) between 1 and 2000),
 abstract text check(char_length(abstract)<=40000),
 categories text[] not null default '{}' check(cardinality(categories)<=12),
 pool_announced_on date,
 in_catalog boolean not null default false,
 title_only boolean not null,
 text_sha256 bytea not null check(octet_length(text_sha256)=32),
 state text not null default 'pending' check(state in ('pending','embedded','failed')),
 attempts integer not null default 0 check(attempts between 0 and 100),
 next_attempt_at timestamptz not null default now(),
 failure_code text check(failure_code ~ '^[a-z_]{1,64}$'),
 model_version text,
 fingerprint extensions.halfvec(384),
 fp_q8 bytea check(octet_length(fp_q8)=388),
 fp_seq bigint unique,
 embedded_at timestamptz,
 leaf_id bigint, leaf_map_version integer,
 terms text[] check(cardinality(terms)<=8),
 terms_version integer,
 updated_at timestamptz not null default now(),
 check((state='embedded')=(fingerprint is not null and fp_q8 is not null and fp_seq is not null and model_version is not null))
);
create index interest_papers_pending on app_private.interest_papers(next_attempt_at,pool_announced_on desc nulls last) where state='pending';
create index interest_papers_pool on app_private.interest_papers(pool_announced_on) where pool_announced_on is not null;
create index interest_papers_seq on app_private.interest_papers(fp_seq) where pool_announced_on is not null;

-- Phrase embeddings for the term layer, kept across versions (only new phrases are embedded).
create table app_private.interest_term_vectors (
 term text primary key check(char_length(term) between 1 and 200),
 model_version text not null,
 q8 bytea not null check(octet_length(q8)=388),
 created_at timestamptz not null default now()
);

-- ---------- map ----------

create table app_private.interest_map_versions (
 version integer primary key generated always as identity,
 kind text not null constraint interest_map_versions_kind check(kind in ('cold','warm')),
 state text not null default 'building' check(state in ('building','published','superseded','failed','blocked')),
 model_version text not null,
 corpus_papers integer not null check(corpus_papers>=0),
 params jsonb not null default '{}' check(jsonb_typeof(params)='object' and octet_length(params::text)<=16384),
 stats jsonb not null default '{}' check(jsonb_typeof(stats)='object' and octet_length(stats::text)<=65536),
 failure_code text check(failure_code ~ '^[a-z_]{1,64}$'),
 created_at timestamptz not null default now(), published_at timestamptz
);
create unique index interest_map_one_published on app_private.interest_map_versions(state) where state='published';

create sequence app_private.interest_node_id_seq;
-- Permanent node identities: born once, retired once with successors; the name slot stays empty until November.
create table app_private.interest_nodes (
 id bigint primary key,
 level smallint not null check(level between 1 and 3),
 born_version integer not null references app_private.interest_map_versions(version),
 birth_centroid extensions.halfvec(384) not null,
 retired_version integer references app_private.interest_map_versions(version),
 successors bigint[] check(cardinality(successors)<=64),
 successor_shares real[] check(cardinality(successor_shares)<=64),
 name text check(char_length(name) between 1 and 80),
 name_source text check(name_source in ('llm','operator')),
 named_version integer, named_centroid extensions.halfvec(384)
);

create table app_private.interest_node_versions (
 version integer not null references app_private.interest_map_versions(version),
 node_id bigint not null,
 parent_id bigint,
 level smallint not null check(level between 1 and 3),
 centroid extensions.halfvec(384) not null,
 size integer not null check(size>0),
 terms text[] not null default '{}' check(cardinality(terms)<=8),
 central_source_ids text[] not null default '{}' check(cardinality(central_source_ids)<=3),
 central_titles text[] not null default '{}' check(cardinality(central_titles)<=3),
 primary key(version,node_id)
);

-- Leaf assignments and per-paper terms of a version being built; applied at publication, then deleted.
create table app_private.interest_build_rows (
 version integer not null references app_private.interest_map_versions(version),
 source_id text not null,
 leaf_id bigint not null,
 terms text[] check(cardinality(terms)<=8),
 primary key(version,source_id)
);

-- ---------- artifacts devices download ----------

create table app_private.interest_artifacts (
 id uuid primary key default gen_random_uuid(),
 kind text not null constraint interest_artifacts_kind check(kind in ('map','terms','shard')),
 map_version integer references app_private.interest_map_versions(version),
 fp_seq_from bigint, fp_seq_to bigint, oldest_on date, newest_on date,
 papers integer check(papers>=0),
 sha256 bytea not null unique check(octet_length(sha256)=32),
 bytes integer not null check(bytes>0),
 content bytea,
 state text not null default 'published' check(state in ('staged','published','retired')),
 created_at timestamptz not null default now(), published_at timestamptz, retired_at timestamptz,
 check((state='retired') or (content is not null and octet_length(content)=bytes)),
 check((kind='shard')=(fp_seq_from is not null and fp_seq_to is not null))
);
create index interest_artifacts_live on app_private.interest_artifacts(kind,state);

alter table app_private.interest_policy enable row level security;
alter table app_private.interest_state enable row level security;
alter table app_private.interest_runs enable row level security;
alter table app_private.interest_papers enable row level security;
alter table app_private.interest_term_vectors enable row level security;
alter table app_private.interest_map_versions enable row level security;
alter table app_private.interest_nodes enable row level security;
alter table app_private.interest_node_versions enable row level security;
alter table app_private.interest_build_rows enable row level security;
alter table app_private.interest_artifacts enable row level security;

insert into app_private.api_rate_rules values('interest-index',3600,240,4000),('interest-library',3600,60,1000)
 on conflict(route) do nothing;

-- ---------- helpers ----------

-- The exact embedded text (docs/architecture/INTEREST_INDEX.md §1): whitespace runs collapsed, ends trimmed.
create function app_private.interest_text(p_title text,p_abstract text) returns text language sql immutable set search_path='' as $$
 select btrim(regexp_replace(coalesce(p_title,''),'\s+',' ','g'))||'. '||btrim(regexp_replace(coalesce(p_abstract,''),'\s+',' ','g'))
$$;

-- Base64 without PostgreSQL's line breaks every 76 characters.
create function app_private.interest_b64(b bytea) returns text language sql immutable set search_path='' as $$
 select translate(encode(b,'base64'),E'\n','')
$$;

create function app_private.interest_serves(a uuid) returns boolean language sql stable security definer set search_path='' as $$
 select case (select serving from app_private.interest_policy where singleton)
  when 'all' then true
  when 'staff' then exists(select 1 from app_private.app_roles where account_id=a)
  else false end
$$;

create function app_private.interest_require_claim(p_claim uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 perform 1 from app_private.interest_state where singleton and claim_id=p_claim and lease_until>now();
 if not found then raise exception 'interest_claim_lost'; end if;
end $$;

create function app_private.interest_published_version() returns integer language sql stable security definer set search_path='' as $$
 select version from app_private.interest_map_versions where state='published'
$$;

create function app_private.interest_corpus_count() returns integer language sql stable security definer set search_path='' as $$
 select count(*)::integer from app_private.interest_papers p, app_private.interest_policy pol
 where pol.singleton and p.state='embedded' and not p.title_only and p.pool_announced_on>=current_date-pol.corpus_days
$$;

-- Rebuild due: forced; no published map yet and enough papers with nothing pending; or the cadence has passed (every
-- two weeks while the corpus is under weekly_after_papers, then weekly) at the scheduled weekday and hour, or two days
-- late whatever the hour (a missed Sunday is not lost).
create function app_private.interest_rebuild_due() returns boolean language plpgsql stable security definer set search_path='' as $$
declare pol app_private.interest_policy; last timestamptz; corpus integer; days integer; pending integer;
begin
 select * into pol from app_private.interest_policy where singleton;
 if pol.force_rebuild then return true; end if;
 corpus:=app_private.interest_corpus_count();
 if corpus<pol.min_corpus then return false; end if;
 select count(*) into pending from app_private.interest_papers where state='pending' and next_attempt_at<=now()
  and pool_announced_on>=current_date-pol.corpus_days;
 select published_at into last from app_private.interest_map_versions where state='published';
 if last is null then return pending=0; end if;
 days:=case when corpus<pol.weekly_after_papers then pol.rebuild_days_growing else pol.rebuild_days end;
 if now()-last>=make_interval(days=>days)+interval '2 days' then return true; end if;
 return now()-last>=make_interval(days=>days)-interval '12 hours'
  and extract(dow from now() at time zone 'UTC')=pol.rebuild_dow and extract(hour from now() at time zone 'UTC')>=pol.rebuild_hour;
end $$;

-- ---------- worker RPCs (service role) ----------

create function public.worker_interest_claim(p_claim uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare pol app_private.interest_policy; st app_private.interest_state; v integer;
begin
 select * into strict pol from app_private.interest_policy where singleton;
 if not pol.enabled then return jsonb_build_object('claimed',false,'reason','disabled'); end if;
 select * into strict st from app_private.interest_state where singleton for update;
 if st.claim_id is not null and st.lease_until>now() then return jsonb_build_object('claimed',false,'reason','busy'); end if;
 -- A run whose lease expired ended without releasing: record it as failed.
 if st.claim_id is not null then
  update app_private.interest_runs set state='failed',finished_at=now(),error_code='lease_expired' where id=st.claim_id and state='running';
 end if;
 update app_private.interest_state set claim_id=p_claim,lease_until=now()+make_interval(secs=>pol.lease_seconds),last_run_at=now() where singleton;
 insert into app_private.interest_runs(id) values(p_claim);
 v:=app_private.interest_published_version();
 return jsonb_build_object('claimed',true,
  'policy',to_jsonb(pol)-'singleton'-'updated_at',
  'map_version',v,
  'map_artifact',(select id from app_private.interest_artifacts where kind='map' and state='published' and map_version=v),
  'terms_artifact',(select id from app_private.interest_artifacts where kind='terms' and state='published' and map_version=v),
  'rebuild_due',app_private.interest_rebuild_due());
end $$;

create function public.worker_interest_release(p_claim uuid,p_state text,p_counts jsonb,p_error text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_state not in ('finished','failed') then raise exception 'invalid_interest_release'; end if;
 update app_private.interest_runs set state=p_state,finished_at=now(),counts=coalesce(p_counts,'{}'),
  error_code=case when p_error ~ '^[a-z_]{1,64}$' then p_error end where id=p_claim and state='running';
 update app_private.interest_state set claim_id=null,lease_until=null where singleton and claim_id=p_claim;
 delete from app_private.interest_runs where started_at<now()-interval '90 days';
end $$;

-- Mirrors the Feed pool and the public catalog into interest_papers. Pool text wins for a paper in both; a changed text
-- is embedded again; pool-only rows older than corpus_days are pruned (catalog rows never are).
create function public.worker_interest_sync(p_claim uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare pol app_private.interest_policy; pool_n integer; catalog_n integer; pruned integer; flagged integer;
begin
 perform app_private.interest_require_claim(p_claim);
 select * into strict pol from app_private.interest_policy where singleton;
 with src as (
  select f.source_id,f.title,f.abstract,f.categories,f.announced_on,
   sha256(convert_to(app_private.interest_text(f.title,f.abstract),'UTF8')) sha,
   char_length(btrim(coalesce(f.abstract,'')))<50 title_only
  from app_private.feed_papers f left join app_private.interest_papers p on p.source_id=f.source_id
  where f.source_id not like 'upload:%' and (p.source_id is null or p.title is distinct from f.title
   or p.abstract is distinct from f.abstract or p.pool_announced_on is distinct from f.announced_on)
 ), up as (
  insert into app_private.interest_papers as p(source_id,title,abstract,categories,pool_announced_on,title_only,text_sha256)
  select source_id,title,abstract,categories,announced_on,title_only,sha from src
  on conflict(source_id) do update set title=excluded.title,abstract=excluded.abstract,categories=excluded.categories,
   pool_announced_on=excluded.pool_announced_on,title_only=excluded.title_only,updated_at=now(),
   text_sha256=excluded.text_sha256,
   state=case when p.text_sha256=excluded.text_sha256 then p.state else 'pending' end,
   attempts=case when p.text_sha256=excluded.text_sha256 then p.attempts else 0 end,
   next_attempt_at=case when p.text_sha256=excluded.text_sha256 then p.next_attempt_at else now() end,
   failure_code=case when p.text_sha256=excluded.text_sha256 then p.failure_code end,
   fingerprint=case when p.text_sha256=excluded.text_sha256 then p.fingerprint end,
   fp_q8=case when p.text_sha256=excluded.text_sha256 then p.fp_q8 end,
   fp_seq=case when p.text_sha256=excluded.text_sha256 then p.fp_seq end,
   model_version=case when p.text_sha256=excluded.text_sha256 then p.model_version end
  returning 1)
 select count(*) into pool_n from up;
 -- Catalog papers with public metadata: the latest record per source, never an upload or its placeholder, with an
 -- abstract of at least 50 characters; only where the pool has no row.
 with latest as (
  select distinct on (m.source_id) m.source_id,m.metadata->>'title' title,m.metadata->>'abstract' abstract,
   coalesce((select array_agg(c) from jsonb_array_elements_text(case when jsonb_typeof(m.metadata->'categories')='array'
    then m.metadata->'categories' else '[]' end) c),'{}') categories
  from app_private.catalog_metadata m
  where m.source_id not like 'upload:%'
  order by m.source_id,m.recorded_at desc,m.id
 ), src as (
  select l.source_id,left(l.title,2000) title,l.abstract,l.categories[1:12] categories,
   sha256(convert_to(app_private.interest_text(left(l.title,2000),l.abstract),'UTF8')) sha
  from latest l left join app_private.interest_papers p on p.source_id=l.source_id
  where l.title is not null and btrim(l.title)<>'' and l.title<>'Uploaded PDF' and char_length(btrim(coalesce(l.abstract,'')))>=50
   and char_length(l.abstract)<=40000
   and not exists(select 1 from app_private.feed_papers f where f.source_id=l.source_id)
   and (p.source_id is null or (p.pool_announced_on is null and (p.title is distinct from left(l.title,2000) or p.abstract is distinct from l.abstract)))
 ), up as (
  insert into app_private.interest_papers as p(source_id,title,abstract,categories,in_catalog,title_only,text_sha256)
  select source_id,title,abstract,categories,true,false,sha from src
  on conflict(source_id) do update set title=excluded.title,abstract=excluded.abstract,categories=excluded.categories,
   in_catalog=true,updated_at=now(),text_sha256=excluded.text_sha256,
   state=case when p.text_sha256=excluded.text_sha256 then p.state else 'pending' end,
   attempts=case when p.text_sha256=excluded.text_sha256 then p.attempts else 0 end,
   next_attempt_at=case when p.text_sha256=excluded.text_sha256 then p.next_attempt_at else now() end,
   fingerprint=case when p.text_sha256=excluded.text_sha256 then p.fingerprint end,
   fp_q8=case when p.text_sha256=excluded.text_sha256 then p.fp_q8 end,
   fp_seq=case when p.text_sha256=excluded.text_sha256 then p.fp_seq end,
   model_version=case when p.text_sha256=excluded.text_sha256 then p.model_version end
  returning 1)
 select count(*) into catalog_n from up;
 with f as (update app_private.interest_papers p set in_catalog=true
  where not p.in_catalog and exists(select 1 from app_private.catalog_metadata m where m.source_id=p.source_id) returning 1)
 select count(*) into flagged from f;
 with d as (delete from app_private.interest_papers where not in_catalog and pool_announced_on<current_date-pol.corpus_days returning 1)
 select count(*) into pruned from d;
 return jsonb_build_object('pool',pool_n,'catalog',catalog_n,'flagged',flagged,'pruned',pruned);
end $$;

-- Pending papers to embed (pool first, newest first). A claimed row waits 10 minutes before another run retries it.
create function public.worker_interest_embed_claim(p_claim uuid,p_limit integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform app_private.interest_require_claim(p_claim);
 if p_limit not between 1 and 256 then raise exception 'invalid_interest_limit'; end if;
 with picked as (
  select source_id from app_private.interest_papers where state='pending' and next_attempt_at<=now()
  order by (pool_announced_on is null),pool_announced_on desc,source_id limit p_limit for update skip locked
 ), touched as (
  update app_private.interest_papers p set attempts=p.attempts+1,next_attempt_at=now()+interval '10 minutes'
  from picked where p.source_id=picked.source_id
  returning p.source_id,p.title,p.abstract,p.text_sha256,p.title_only,p.pool_announced_on)
 select coalesce(jsonb_agg(jsonb_build_object('source_id',source_id,'title',title,'abstract',abstract,
  'text_sha256',encode(text_sha256,'hex'),'title_only',title_only,'pool_announced_on',pool_announced_on) order by source_id),'[]')
 into result from touched;
 return result;
end $$;

-- Stores fingerprints. A row whose text changed since it was claimed is skipped (it is pending again).
create function public.worker_interest_embed_store(p_claim uuid,p_rows jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.interest_policy; r jsonb; v extensions.halfvec; n real; stored integer:=0; skipped integer:=0; mv integer;
begin
 perform app_private.interest_require_claim(p_claim);
 select * into strict pol from app_private.interest_policy where singleton;
 if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)>256 then raise exception 'invalid_interest_rows'; end if;
 mv:=app_private.interest_published_version();
 for r in select * from jsonb_array_elements(p_rows) loop
  if r->>'model_version' is distinct from pol.model_version then raise exception 'interest_model_mismatch'; end if;
  v:=(r->>'fingerprint')::extensions.halfvec(384);
  n:=extensions.l2_norm(v);
  if n not between 0.99 and 1.01 then raise exception 'interest_fingerprint_norm'; end if;
  update app_private.interest_papers set state='embedded',fingerprint=v,fp_q8=decode(r->>'q8','base64'),
   fp_seq=nextval('app_private.interest_fp_seq'),model_version=pol.model_version,embedded_at=now(),failure_code=null,
   leaf_id=case when (r->>'map_version')::integer=mv then (r->>'leaf_id')::bigint end,
   leaf_map_version=case when (r->>'map_version')::integer=mv then mv end,
   terms=case when (r->>'map_version')::integer=mv and jsonb_typeof(r->'terms')='array'
    then array(select jsonb_array_elements_text(r->'terms'))::text[] end,
   terms_version=case when (r->>'map_version')::integer=mv and jsonb_typeof(r->'terms')='array' then mv end,
   updated_at=now()
  where source_id=r->>'source_id' and text_sha256=decode(r->>'text_sha256','hex');
  if found then stored:=stored+1; else skipped:=skipped+1; end if;
 end loop;
 return jsonb_build_object('stored',stored,'skipped',skipped);
end $$;

create function public.worker_interest_embed_fail(p_claim uuid,p_source_ids text[],p_code text) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.interest_require_claim(p_claim);
 update app_private.interest_papers set failure_code=case when p_code ~ '^[a-z_]{1,64}$' then p_code else 'embed_failed' end,
  state=case when attempts>=3 then 'failed' else state end
 where source_id=any(p_source_ids) and state='pending';
end $$;

-- The next shard: newly embedded pool papers. Due once nothing in the pool is waiting, or 30 minutes after the last one.
create function public.worker_interest_shard_due(p_claim uuid,p_max integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare after bigint; waiting boolean; last timestamptz; pol app_private.interest_policy; rows_ jsonb;
begin
 perform app_private.interest_require_claim(p_claim);
 select * into strict pol from app_private.interest_policy where singleton;
 select coalesce(max(fp_seq_to),0) into after from app_private.interest_artifacts where kind='shard';
 select last_shard_at into last from app_private.interest_state where singleton;
 waiting:=exists(select 1 from app_private.interest_papers where state='pending' and pool_announced_on is not null);
 select coalesce(jsonb_agg(jsonb_build_object('source_id',source_id,'announced_on',pool_announced_on,'q8',app_private.interest_b64(fp_q8),
  'fp_seq',fp_seq) order by fp_seq),'[]') into rows_
 from (select source_id,pool_announced_on,fp_q8,fp_seq from app_private.interest_papers
  where state='embedded' and pool_announced_on is not null and fp_seq>after and pool_announced_on>=current_date-pol.window_days
  order by fp_seq limit greatest(1,least(p_max,20000))) x;
 return jsonb_build_object('due',jsonb_array_length(rows_)>0 and (not waiting or last is null or now()-last>=interval '30 minutes'),
  'after',after,'rows',rows_);
end $$;

create function app_private.interest_check_artifact(p jsonb) returns bytea language plpgsql security definer set search_path='' as $$
declare content bytea:=decode(p->>'content','base64'); cap integer:=(select artifact_max_bytes from app_private.interest_policy where singleton);
begin
 if octet_length(content)>cap then raise exception 'interest_artifact_too_large'; end if;
 if encode(sha256(content),'hex') is distinct from p->>'sha256' then raise exception 'interest_artifact_digest'; end if;
 return content;
end $$;

create function public.worker_interest_shard_publish(p_claim uuid,p_shard jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare content bytea; result uuid; pol app_private.interest_policy;
begin
 perform app_private.interest_require_claim(p_claim);
 select * into strict pol from app_private.interest_policy where singleton;
 content:=app_private.interest_check_artifact(p_shard);
 if (p_shard->>'fp_seq_from')::bigint<=coalesce((select max(fp_seq_to) from app_private.interest_artifacts where kind='shard'),0)
 then raise exception 'interest_shard_overlap'; end if;
 insert into app_private.interest_artifacts(kind,fp_seq_from,fp_seq_to,oldest_on,newest_on,papers,sha256,bytes,content,state,published_at)
 values('shard',(p_shard->>'fp_seq_from')::bigint,(p_shard->>'fp_seq_to')::bigint,(p_shard->>'oldest_on')::date,
  (p_shard->>'newest_on')::date,(p_shard->>'papers')::integer,sha256(content),octet_length(content),content,'published',now())
 returning id into result;
 update app_private.interest_state set last_shard_at=now() where singleton;
 -- A shard whose newest paper left the window is retired (its bytes are dropped).
 update app_private.interest_artifacts set state='retired',retired_at=now(),content=null
 where kind='shard' and state='published' and newest_on<current_date-pol.window_days;
 return result;
end $$;

-- The build's corpus page: embedded papers in source order. in_map marks the papers the map and term statistics are
-- built from (pool papers inside corpus_days with an abstract); the rest (catalog papers, older pool papers) are only
-- assigned to leaves.
create function public.worker_interest_corpus_page(p_claim uuid,p_after text,p_limit integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.interest_policy; v integer:=app_private.interest_published_version(); result jsonb;
begin
 perform app_private.interest_require_claim(p_claim);
 select * into strict pol from app_private.interest_policy where singleton;
 if p_limit not between 1 and 5000 then raise exception 'invalid_interest_limit'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('source_id',source_id,'fp',app_private.interest_b64(extensions.halfvec_send(fingerprint)),
  'title',title,'abstract',abstract,'pool_announced_on',pool_announced_on,
  'in_map',not title_only and pool_announced_on>=current_date-pol.corpus_days,
  'leaf_id',case when leaf_map_version=v then leaf_id end) order by source_id),'[]') into result
 from (select * from app_private.interest_papers where state='embedded' and model_version=pol.model_version
  and source_id>coalesce(p_after,'') order by source_id limit p_limit) x;
 return result;
end $$;

create function public.worker_interest_previous_nodes(p_claim uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v integer:=app_private.interest_published_version(); result jsonb;
begin
 perform app_private.interest_require_claim(p_claim);
 select coalesce(jsonb_agg(jsonb_build_object('id',nv.node_id,'level',nv.level,'parent',nv.parent_id,
  'centroid',app_private.interest_b64(extensions.halfvec_send(nv.centroid)),'birth',app_private.interest_b64(extensions.halfvec_send(n.birth_centroid)))
  order by nv.level,nv.node_id),'[]') into result
 from app_private.interest_node_versions nv join app_private.interest_nodes n on n.id=nv.node_id where nv.version=v;
 return jsonb_build_object('version',v,'nodes',result,
  'retired',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'successors',successors,'shares',successor_shares) order by id),'[]')
   from app_private.interest_nodes where retired_version is not null and retired_version>coalesce(v,0)-26));
end $$;

create function public.worker_interest_term_vectors(p_claim uuid,p_terms text[]) returns jsonb
language plpgsql security definer set search_path='' as $$
declare mv text:=(select model_version from app_private.interest_policy where singleton); result jsonb;
begin
 perform app_private.interest_require_claim(p_claim);
 if cardinality(p_terms)>20000 then raise exception 'invalid_interest_terms'; end if;
 select coalesce(jsonb_object_agg(term,app_private.interest_b64(q8)),'{}') into result
 from app_private.interest_term_vectors where term=any(p_terms) and model_version=mv;
 return result;
end $$;

create function public.worker_interest_term_vectors_store(p_claim uuid,p_rows jsonb) returns integer
language plpgsql security definer set search_path='' as $$
declare mv text:=(select model_version from app_private.interest_policy where singleton); n integer;
begin
 perform app_private.interest_require_claim(p_claim);
 if jsonb_typeof(p_rows)<>'object' or (select count(*) from jsonb_object_keys(p_rows))>5000 then raise exception 'invalid_interest_terms'; end if;
 insert into app_private.interest_term_vectors(term,model_version,q8)
 select key,mv,decode(value#>>'{}','base64') from jsonb_each(p_rows)
 on conflict(term) do update set model_version=excluded.model_version,q8=excluded.q8,created_at=now();
 get diagnostics n=row_count;
 return n;
end $$;

create function public.worker_interest_node_ids(p_claim uuid,p_count integer) returns bigint[]
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.interest_require_claim(p_claim);
 if p_count not between 0 and 100000 then raise exception 'invalid_interest_count'; end if;
 return array(select nextval('app_private.interest_node_id_seq') from generate_series(1,p_count));
end $$;

create function public.worker_interest_build_begin(p_claim uuid,p_kind text,p_corpus integer,p_params jsonb,p_stats jsonb) returns integer
language plpgsql security definer set search_path='' as $$
declare v integer;
begin
 perform app_private.interest_require_claim(p_claim);
 -- An earlier build that never published is abandoned.
 delete from app_private.interest_build_rows where version in (select version from app_private.interest_map_versions where state='building');
 delete from app_private.interest_node_versions where version in (select version from app_private.interest_map_versions where state='building');
 delete from app_private.interest_artifacts where state='staged';
 update app_private.interest_map_versions set state='failed',failure_code='abandoned' where state='building';
 insert into app_private.interest_map_versions(kind,model_version,corpus_papers,params,stats)
 values(p_kind,(select model_version from app_private.interest_policy where singleton),p_corpus,coalesce(p_params,'{}'),coalesce(p_stats,'{}'))
 returning version into v;
 return v;
end $$;

create function public.worker_interest_build_nodes(p_claim uuid,p_version integer,p_nodes jsonb) returns integer
language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 perform app_private.interest_require_claim(p_claim);
 perform 1 from app_private.interest_map_versions where version=p_version and state='building';
 if not found then raise exception 'interest_build_unavailable'; end if;
 insert into app_private.interest_node_versions(version,node_id,parent_id,level,centroid,size,terms,central_source_ids,central_titles)
 select p_version,(x->>'id')::bigint,(x->>'parent')::bigint,(x->>'level')::smallint,(x->>'centroid')::extensions.halfvec(384),
  (x->>'size')::integer,array(select jsonb_array_elements_text(x->'terms')),array(select jsonb_array_elements_text(x->'central_source_ids')),
  array(select left(t,300) from jsonb_array_elements_text(x->'central_titles') t)
 from jsonb_array_elements(p_nodes) x;
 get diagnostics n=row_count;
 return n;
end $$;

create function public.worker_interest_build_rows(p_claim uuid,p_version integer,p_rows jsonb) returns integer
language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 perform app_private.interest_require_claim(p_claim);
 perform 1 from app_private.interest_map_versions where version=p_version and state='building';
 if not found then raise exception 'interest_build_unavailable'; end if;
 if jsonb_array_length(p_rows)>10000 then raise exception 'invalid_interest_rows'; end if;
 insert into app_private.interest_build_rows(version,source_id,leaf_id,terms)
 select p_version,x->>'source_id',(x->>'leaf_id')::bigint,
  case when jsonb_typeof(x->'terms')='array' then array(select jsonb_array_elements_text(x->'terms')) end
 from jsonb_array_elements(p_rows) x
 on conflict(version,source_id) do update set leaf_id=excluded.leaf_id,terms=excluded.terms;
 get diagnostics n=row_count;
 return n;
end $$;

-- Publication, in one transaction: the stability gate, new node identities, retirements with successors, leaf and
-- term assignments, the map and term artifacts, and the version switch. Node data of the last 4 versions is kept.
create function public.worker_interest_build_publish(p_claim uuid,p_version integer,p_retired jsonb,p_map jsonb,p_terms jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.interest_policy; mv app_private.interest_map_versions; previous integer; kept real;
 map_content bytea; terms_content bytea; r jsonb;
begin
 perform app_private.interest_require_claim(p_claim);
 select * into strict pol from app_private.interest_policy where singleton;
 select * into mv from app_private.interest_map_versions where version=p_version and state='building' for update;
 if not found then raise exception 'interest_build_unavailable'; end if;
 previous:=app_private.interest_published_version();
 kept:=(mv.stats#>>'{levels,3,kept_share}')::real;
 if previous is not null and kept is not null and kept<pol.gate_block and not pol.allow_low_stability then
  update app_private.interest_map_versions set state='blocked',failure_code='stability_gate' where version=p_version;
  delete from app_private.interest_build_rows where version=p_version;
  return jsonb_build_object('published',false,'reason','stability_gate','kept_share',kept);
 end if;
 map_content:=app_private.interest_check_artifact(p_map);
 terms_content:=app_private.interest_check_artifact(p_terms);
 -- New identities: every node of this version not yet known.
 insert into app_private.interest_nodes(id,level,born_version,birth_centroid)
 select nv.node_id,nv.level,p_version,nv.centroid from app_private.interest_node_versions nv
 where nv.version=p_version and not exists(select 1 from app_private.interest_nodes n where n.id=nv.node_id);
 for r in select * from jsonb_array_elements(coalesce(p_retired,'[]')) loop
  update app_private.interest_nodes set retired_version=p_version,
   successors=array(select jsonb_array_elements_text(r->'successors'))::bigint[],
   successor_shares=array(select jsonb_array_elements_text(r->'shares'))::real[]
  where id=(r->>'id')::bigint and retired_version is null;
 end loop;
 update app_private.interest_papers p set leaf_id=b.leaf_id,leaf_map_version=p_version,
  terms=coalesce(b.terms,p.terms),terms_version=case when b.terms is not null then p_version else p.terms_version end
 from app_private.interest_build_rows b where b.version=p_version and b.source_id=p.source_id;
 delete from app_private.interest_build_rows where version=p_version;
 update app_private.interest_artifacts set state='retired',retired_at=now(),content=null
  where kind in ('map','terms') and state='published' and map_version<=coalesce(previous,0)-2;
 insert into app_private.interest_artifacts(kind,map_version,sha256,bytes,content,state,published_at)
 values('map',p_version,sha256(map_content),octet_length(map_content),map_content,'published',now()),
  ('terms',p_version,sha256(terms_content),octet_length(terms_content),terms_content,'published',now())
 on conflict(sha256) do nothing;
 update app_private.interest_map_versions set state='superseded' where state='published';
 update app_private.interest_map_versions set state='published',published_at=now() where version=p_version;
 update app_private.interest_policy set force_rebuild=false where singleton;
 delete from app_private.interest_node_versions where version in (select version from app_private.interest_map_versions
  where state in ('superseded','failed','blocked') order by version desc offset 3);
 return jsonb_build_object('published',true,'version',p_version,'kept_share',kept);
end $$;

-- ---------- wake-up ----------

-- Posts /interest to the worker when enabled, no live lease exists and work is due; at most once in 2 minutes.
create function app_private.interest_kick() returns boolean language plpgsql security definer set search_path='' as $$
declare url text; secret text; pol app_private.interest_policy; st app_private.interest_state; due boolean;
begin
 select * into pol from app_private.interest_policy where singleton;
 if not coalesce(pol.enabled,false) then return false; end if;
 select * into st from app_private.interest_state where singleton;
 if st.lease_until>now() or st.last_kick_at>now()-interval '2 minutes' then return false; end if;
 due:=exists(select 1 from app_private.interest_papers where state='pending' and next_attempt_at<=now())
  or exists(select 1 from app_private.feed_papers f where not exists(select 1 from app_private.interest_papers p where p.source_id=f.source_id))
  or exists(select 1 from app_private.interest_papers p where p.state='embedded' and p.pool_announced_on is not null
   and p.fp_seq>coalesce((select max(fp_seq_to) from app_private.interest_artifacts where kind='shard'),0))
  or app_private.interest_rebuild_due();
 if not due then return false; end if;
 update app_private.interest_state set last_kick_at=now() where singleton;
 if to_regnamespace('net') is null or to_regnamespace('vault') is null then return false; end if;
 begin
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into url using 'science_reader_pipeline_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into secret using 'science_reader_pipeline_secret';
  if url is null or secret is null then return false; end if;
  execute 'select net.http_post(url:=$1,body:=$2,headers:=$3,timeout_milliseconds:=1000)'
   using rtrim(url,'/')||'/interest','{"reason":"interest"}'::jsonb,jsonb_build_object('content-type','application/json','x-pipeline-secret',secret);
 exception when others then return false;
 end;
 return true;
end $$;

-- The embedding hook on pool ingest: new Feed pool papers wake the worker (debounced by interest_kick).
create function app_private.interest_pool_ingest() returns trigger language plpgsql security definer set search_path='' as $$
begin
 -- Never let the wake-up affect the Feed's own write.
 begin perform app_private.interest_kick(); exception when others then null; end;
 return null;
end $$;
create trigger feed_papers_interest_ingest after insert on app_private.feed_papers
 for each statement execute function app_private.interest_pool_ingest();

do $$ begin
 if to_regprocedure('cron.schedule(text,text,text)') is not null then
  perform cron.schedule('science-reader-interest','*/10 * * * *','select app_private.interest_kick()');
 end if;
end $$;

-- ---------- operations ----------

create function public.worker_interest_set_policy(p_enabled boolean,p_serving text,p_force_rebuild boolean default null,
 p_allow_low_stability boolean default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if p_serving is not null and p_serving not in ('off','staff','all') then raise exception 'invalid_interest_serving'; end if;
 update app_private.interest_policy set enabled=coalesce(p_enabled,enabled),serving=coalesce(p_serving,serving),
  force_rebuild=coalesce(p_force_rebuild,force_rebuild),allow_low_stability=coalesce(p_allow_low_stability,allow_low_stability),
  updated_at=now() where singleton;
 return (select to_jsonb(p)-'singleton' from app_private.interest_policy p where singleton);
end $$;

create function app_private.interest_health() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare pol app_private.interest_policy; mv app_private.interest_map_versions; v integer; result jsonb; attention jsonb:='[]';
 pending_old integer; failed_24h integer; embedded_24h integer; last_run app_private.interest_runs; failed_builds integer;
begin
 select * into pol from app_private.interest_policy where singleton;
 select * into mv from app_private.interest_map_versions where state='published';
 v:=mv.version;
 select count(*) into pending_old from app_private.interest_papers where state='pending' and updated_at<now()-interval '24 hours';
 select count(*) filter(where state='failed' and updated_at>now()-interval '24 hours'),
  count(*) filter(where state='embedded' and embedded_at>now()-interval '24 hours') into failed_24h,embedded_24h from app_private.interest_papers;
 select * into last_run from app_private.interest_runs order by started_at desc limit 1;
 select count(*) into failed_builds from (select state from app_private.interest_map_versions order by version desc limit 2) x
  where state in ('failed','blocked');
 if pol.enabled and pending_old>=50 then attention:=attention||jsonb_build_object('kind','interest_backlog','papers',pending_old); end if;
 if pol.enabled and failed_24h>greatest(5,0.01*embedded_24h) then attention:=attention||jsonb_build_object('kind','interest_failures','papers',failed_24h); end if;
 if pol.enabled and v is not null and mv.published_at<now()-make_interval(days=>(case when mv.corpus_papers<pol.weekly_after_papers
  then pol.rebuild_days_growing else pol.rebuild_days end)+2) then attention:=attention||jsonb_build_object('kind','interest_map_stale','published_at',mv.published_at); end if;
 if failed_builds>=2 then attention:=attention||jsonb_build_object('kind','interest_rebuild_failed'); end if;
 if exists(select 1 from app_private.interest_map_versions where state='blocked' and version>coalesce(v,0)) then
  attention:=attention||jsonb_build_object('kind','interest_stability_blocked'); end if;
 if v is not null and (mv.stats#>>'{levels,3,kept_share}')::real<pol.gate_warn then
  attention:=attention||jsonb_build_object('kind','interest_stability_low','kept_share',(mv.stats#>>'{levels,3,kept_share}')::real); end if;
 if last_run.error_code='interest_model_mismatch' then attention:=attention||jsonb_build_object('kind','interest_model_mismatch'); end if;
 result:=jsonb_build_object(
  'enabled',pol.enabled,'serving',pol.serving,'model_version',pol.model_version,
  'corpus',(select jsonb_build_object(
    'pool_in_window',count(*) filter(where pool_announced_on>=current_date-pol.corpus_days),
    'embedded',count(*) filter(where state='embedded'),'pending',count(*) filter(where state='pending'),
    'failed',count(*) filter(where state='failed'),'catalog',count(*) filter(where in_catalog and pool_announced_on is null),
    'catalog_embedded',count(*) filter(where in_catalog and pool_announced_on is null and state='embedded'),
    'oldest_pending',min(updated_at) filter(where state='pending'),'embedded_24h',embedded_24h,'failed_24h',failed_24h)
   from app_private.interest_papers),
  'last_run',case when last_run.id is not null then jsonb_build_object('started_at',last_run.started_at,'finished_at',last_run.finished_at,
   'state',last_run.state,'counts',last_run.counts,'error_code',last_run.error_code) end,
  'map',case when v is not null then jsonb_build_object('version',v,'kind',mv.kind,'published_at',mv.published_at,
   'corpus_papers',mv.corpus_papers,'stats',mv.stats,
   'nodes',(select jsonb_object_agg(level,c) from (select level,count(*) c from app_private.interest_node_versions where version=v group by level) x),
   'leaf_sizes',(select jsonb_build_object('min',min(size),'median',percentile_cont(0.5) within group(order by size),'max',max(size))
    from app_private.interest_node_versions where version=v and level=3)) end,
  'artifacts',(select jsonb_build_object(
    'map_bytes',max(bytes) filter(where kind='map' and map_version=v),'terms_bytes',max(bytes) filter(where kind='terms' and map_version=v),
    'shards',count(*) filter(where kind='shard' and state='published'),
    'shard_bytes',coalesce(sum(bytes) filter(where kind='shard' and state='published'),0))
   from app_private.interest_artifacts where state='published'),
  'term_vectors',(select count(*) from app_private.interest_term_vectors),
  'delivery',(select jsonb_build_object('requests_24h',coalesce(sum(w.used) filter(where w.scope_id='environment'),0),
    'accounts_24h',count(distinct w.scope_id) filter(where w.scope_id<>'environment'))
   from app_private.api_rate_windows w where w.route in ('interest-index','interest-library') and w.window_start>now()-interval '24 hours'),
  'attention',attention);
 return result;
end $$;

create function public.worker_interest_status() returns jsonb language sql stable security definer set search_path='' as $$
 select app_private.interest_health()
$$;

create or replace function app_private.admin_health_extra() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('tariffs',app_private.openrouter_tariff_attention(),'reconciliation',app_private.openrouter_reconcile_health(),
  'recommendations',app_private.recommendation_health(),'interest_index',app_private.interest_health())
$$;

-- ---------- delivery (Edge function interest-index and the reader's RPC) ----------

create function app_private.interest_open_reader(a uuid,p_route text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform 1 from app_private.accounts where id=a and closed_at is null;
 if not found then raise exception 'account_unavailable' using errcode='42501'; end if;
 if not app_private.interest_serves(a) then raise exception 'interest_unavailable'; end if;
 perform public.worker_consume_request(a,p_route);
end $$;

-- The manifest: identical for every served reader (the map, term statistics and pool shards are public).
create function public.worker_interest_manifest(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.interest_policy; mv app_private.interest_map_versions;
begin
 perform app_private.interest_open_reader(p_account_id,'interest-index');
 select * into strict pol from app_private.interest_policy where singleton;
 select * into mv from app_private.interest_map_versions where state='published';
 return jsonb_build_object('format',1,
  'model',jsonb_build_object('version',pol.model_version,'dim',384,'text_recipe','collapse_ws(title) + ". " + collapse_ws(abstract)',
   'q8','f32le scale + 384 x i8'),
  'window_days',pol.window_days,
  'map',case when mv.version is not null then (select jsonb_build_object('version',mv.version,'built_at',mv.published_at,
   'artifact',jsonb_build_object('id',a.id,'sha256',encode(a.sha256,'hex'),'bytes',a.bytes))
   from app_private.interest_artifacts a where a.kind='map' and a.map_version=mv.version and a.state='published') end,
  'terms',case when mv.version is not null then (select jsonb_build_object('version',mv.version,
   'artifact',jsonb_build_object('id',a.id,'sha256',encode(a.sha256,'hex'),'bytes',a.bytes))
   from app_private.interest_artifacts a where a.kind='terms' and a.map_version=mv.version and a.state='published') end,
  'shards',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'sha256',encode(sha256,'hex'),'bytes',bytes,'papers',papers,
   'fp_seq_from',fp_seq_from,'fp_seq_to',fp_seq_to,'oldest_on',oldest_on,'newest_on',newest_on) order by fp_seq_from),'[]')
   from app_private.interest_artifacts where kind='shard' and state='published'));
end $$;

create function public.worker_interest_artifact(p_account_id uuid,p_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a app_private.interest_artifacts;
begin
 perform app_private.interest_open_reader(p_account_id,'interest-index');
 select * into a from app_private.interest_artifacts where id=p_id and state='published';
 if not found then raise exception 'interest_artifact_unavailable'; end if;
 return jsonb_build_object('id',a.id,'kind',a.kind,'sha256',encode(a.sha256,'hex'),'bytes',a.bytes,'content',app_private.interest_b64(a.content));
end $$;

-- The worker reads the published map and term statistics back (leaf assignment and top terms for new papers).
create function public.worker_interest_artifact_service(p_claim uuid,p_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a app_private.interest_artifacts;
begin
 perform app_private.interest_require_claim(p_claim);
 select * into a from app_private.interest_artifacts where id=p_id and state='published';
 if not found then raise exception 'interest_artifact_unavailable'; end if;
 return jsonb_build_object('id',a.id,'kind',a.kind,'sha256',encode(a.sha256,'hex'),'bytes',a.bytes,'content',app_private.interest_b64(a.content));
end $$;

-- Fingerprints of the caller's own public library papers (items and imports they have now). The paper set comes from
-- membership the server already holds; an ID outside it is silently omitted, so this never reveals whether another
-- reader has a paper. Uploads never appear.
create function public.v1_interest_library_fingerprints(p_source_ids text[] default null,p_after text default null,p_limit integer default 500)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); v integer:=app_private.interest_published_version();
 pol app_private.interest_policy; items jsonb; more boolean;
begin
 if p_limit is null or p_limit not between 1 and 500 or coalesce(cardinality(p_source_ids),0)>500 then raise exception 'invalid_interest_request'; end if;
 perform app_private.interest_open_reader(a,'interest-library');
 select * into strict pol from app_private.interest_policy where singleton;
 with mine as (
  select cm.source_id from app_private.library_items li
   join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
   join app_private.catalog_metadata cm on cm.id=ca.metadata_id
  where li.account_id=a and li.removed_at is null
  union
  select i.source_id from app_private.import_requests i where i.account_id=a and i.desired_present
 ), sel as (
  select source_id from mine where source_id not like 'upload:%' and (p_source_ids is null or source_id=any(p_source_ids))
   and source_id>coalesce(p_after,'') order by source_id limit p_limit+1
 ), page as (select source_id from sel order by source_id limit p_limit)
 select (select coalesce(jsonb_agg(case when p.state='embedded' and p.model_version=pol.model_version then
   jsonb_build_object('source_id',s.source_id,'q8',app_private.interest_b64(p.fp_q8),'leaf_id',case when p.leaf_map_version=v then p.leaf_id end,
    'terms',case when p.terms_version is not null then to_jsonb(p.terms) end)
   else jsonb_build_object('source_id',s.source_id,'pending',true) end order by s.source_id),'[]')
   from page s left join app_private.interest_papers p on p.source_id=s.source_id),
  (select count(*) from sel)>p_limit
 into items,more;
 return jsonb_build_object('model_version',pol.model_version,'map_version',v,'items',items,
  'next',case when more then (select max(x->>'source_id') from jsonb_array_elements(items) x) end);
end $$;

-- ---------- grants ----------

revoke all on function app_private.interest_text(text,text),app_private.interest_b64(bytea),app_private.interest_serves(uuid),app_private.interest_require_claim(uuid),
 app_private.interest_published_version(),app_private.interest_corpus_count(),app_private.interest_rebuild_due(),
 app_private.interest_check_artifact(jsonb),app_private.interest_kick(),app_private.interest_pool_ingest(),app_private.interest_health(),
 app_private.interest_open_reader(uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.worker_interest_claim(uuid),public.worker_interest_release(uuid,text,jsonb,text),
 public.worker_interest_sync(uuid),public.worker_interest_embed_claim(uuid,integer),public.worker_interest_embed_store(uuid,jsonb),
 public.worker_interest_embed_fail(uuid,text[],text),public.worker_interest_shard_due(uuid,integer),
 public.worker_interest_shard_publish(uuid,jsonb),public.worker_interest_corpus_page(uuid,text,integer),
 public.worker_interest_previous_nodes(uuid),public.worker_interest_term_vectors(uuid,text[]),
 public.worker_interest_term_vectors_store(uuid,jsonb),public.worker_interest_node_ids(uuid,integer),
 public.worker_interest_build_begin(uuid,text,integer,jsonb,jsonb),public.worker_interest_build_nodes(uuid,integer,jsonb),
 public.worker_interest_build_rows(uuid,integer,jsonb),public.worker_interest_build_publish(uuid,integer,jsonb,jsonb,jsonb),
 public.worker_interest_set_policy(boolean,text,boolean,boolean),public.worker_interest_status(),
 public.worker_interest_manifest(uuid),public.worker_interest_artifact(uuid,uuid),public.worker_interest_artifact_service(uuid,uuid),
 public.v1_interest_library_fingerprints(text[],text,integer) from public,anon,authenticated;
grant execute on function public.worker_interest_claim(uuid),public.worker_interest_release(uuid,text,jsonb,text),
 public.worker_interest_sync(uuid),public.worker_interest_embed_claim(uuid,integer),public.worker_interest_embed_store(uuid,jsonb),
 public.worker_interest_embed_fail(uuid,text[],text),public.worker_interest_shard_due(uuid,integer),
 public.worker_interest_shard_publish(uuid,jsonb),public.worker_interest_corpus_page(uuid,text,integer),
 public.worker_interest_previous_nodes(uuid),public.worker_interest_term_vectors(uuid,text[]),
 public.worker_interest_term_vectors_store(uuid,jsonb),public.worker_interest_node_ids(uuid,integer),
 public.worker_interest_build_begin(uuid,text,integer,jsonb,jsonb),public.worker_interest_build_nodes(uuid,integer,jsonb),
 public.worker_interest_build_rows(uuid,integer,jsonb),public.worker_interest_build_publish(uuid,integer,jsonb,jsonb,jsonb),
 public.worker_interest_set_policy(boolean,text,boolean,boolean),public.worker_interest_status(),
 public.worker_interest_manifest(uuid),public.worker_interest_artifact(uuid,uuid),public.worker_interest_artifact_service(uuid,uuid) to service_role;
grant execute on function public.v1_interest_library_fingerprints(text[],text,integer) to authenticated;

notify pgrst,'reload schema';
commit;
