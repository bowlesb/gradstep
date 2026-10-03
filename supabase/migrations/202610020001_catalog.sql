-- Initial schema: clean installation only. No legacy migration or destructive changes.
-- Internal tables are absent from PostgREST's exposed schemas. Client access uses
-- explicit versioned RPCs; RLS denies direct customer access as a second boundary.
begin;
create schema app_private;
revoke all on schema app_private from public, anon, authenticated;
alter default privileges in schema app_private revoke all on tables from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public;

create table app_private.accounts (
  id uuid primary key,
  auth_user_id uuid unique references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  check (closed_at is not null or auth_user_id is not null)
);
create table app_private.app_roles (
  account_id uuid not null references app_private.accounts(id),
  role text not null check (role in ('owner','support','tester')),
  granted_at timestamptz not null default now(),
  primary key(account_id,role)
);
create function app_private.actor() returns uuid language sql stable security definer
set search_path = '' as $$
  select id from app_private.accounts where auth_user_id = auth.uid() and closed_at is null
$$;
create function app_private.require_actor() returns uuid language plpgsql stable security definer
set search_path = '' as $$
declare a uuid := app_private.actor();
begin
  if a is null then raise exception 'authentication_required' using errcode='28000'; end if;
  return a;
end $$;
create function app_private.is_operator(required_role text default 'support') returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(auth.jwt()->>'aal' = 'aal2',false) and exists (
    select 1 from app_private.app_roles where account_id=app_private.actor()
    and role in ('owner',required_role)
  )
$$;
create function app_private.create_account() returns trigger language plpgsql security definer
set search_path = '' as $$
begin
  insert into app_private.accounts(id,auth_user_id) values(new.id,new.id);
  return new;
end $$;
create trigger science_reader_account after insert on auth.users for each row execute function app_private.create_account();

create table app_private.publications (
  id uuid primary key default gen_random_uuid(),
  title text not null check(length(title) between 1 and 2000),
  authors text[] not null default '{}',
  abstract text,
  venue text,
  publication_year smallint check(publication_year between 1800 and 2200),
  keywords text[] not null default '{}',
  created_at timestamptz not null default now(),
  search_text tsvector generated always as (
    to_tsvector('english',coalesce(title,'') || ' ' || coalesce(abstract,'') || ' ' || coalesce(venue,''))
  ) stored
);
create index publications_search on app_private.publications using gin(search_text);
create table app_private.publication_identifiers (
  namespace text not null check(namespace in ('doi','arxiv','semantic_scholar')),
  identifier text not null check(length(identifier) between 1 and 512),
  publication_id uuid not null references app_private.publications(id),
  verified_at timestamptz,
  provenance text not null,
  primary key(namespace,identifier)
);
create table app_private.publication_versions (
  id uuid primary key default gen_random_uuid(),
  publication_id uuid not null references app_private.publications(id),
  source text not null,
  revision text not null,
  published_at date,
  license_uri text,
  license_evidence jsonb not null default '{}',
  reuse_status text not null default 'unreviewed' check(reuse_status in ('unreviewed','approved','restricted')),
  unique(publication_id,source,revision)
);
create table app_private.documents (
  id uuid primary key default gen_random_uuid(),
  sha256 bytea not null check(octet_length(sha256)=32),
  scope text not null check(scope in ('shared_catalog','owner_private')),
  owner_id uuid references app_private.accounts(id),
  reuse_evidence jsonb,
  byte_count bigint not null check(byte_count between 1 and 33554432),
  page_count integer not null check(page_count between 1 and 250),
  created_at timestamptz not null default now(),
  check((scope='owner_private' and owner_id is not null and reuse_evidence is null)
     or (scope='shared_catalog' and owner_id is null and reuse_evidence is not null and reuse_evidence <> '{}'::jsonb))
);
create unique index shared_document_bytes on app_private.documents(sha256) where scope='shared_catalog';
create unique index private_document_bytes on app_private.documents(owner_id,sha256) where scope='owner_private';
create table app_private.version_documents (
  version_id uuid not null references app_private.publication_versions(id),
  document_id uuid not null references app_private.documents(id),
  primary key(version_id,document_id)
);
create table app_private.document_sources (
  document_id uuid not null references app_private.documents(id),
  source_id uuid primary key default gen_random_uuid(),
  canonical_url text not null check(canonical_url ~ '^https://[^/@]+/'),
  acquired_at timestamptz not null default now(),
  provenance jsonb not null
);
create table app_private.stored_objects (
  id uuid primary key default gen_random_uuid(),
  bucket text not null check(bucket in ('paper-assets','private-content','support')),
  path text not null unique check(path !~ '(^/|(^|/)\.\.(/|$))'),
  document_id uuid references app_private.documents(id),
  owner_id uuid references app_private.accounts(id),
  state text not null default 'pending' check(state in ('pending','verified','deleting','deleted')),
  sha256 bytea not null check(octet_length(sha256)=32),
  byte_count bigint not null check(byte_count between 1 and 134217728),
  media_type text not null,
  created_at timestamptz not null default now(),
  verified_at timestamptz,
  check((bucket='paper-assets' and document_id is not null and owner_id is null)
    or (bucket in ('private-content','support') and owner_id is not null and document_id is null)),
  check(state <> 'verified' or verified_at is not null)
);
create table app_private.ocr_runs (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references app_private.documents(id),
  provider text not null,
  options_sha256 bytea not null check(octet_length(options_sha256)=32),
  provider_job_id text,
  raw_bundle_object_id uuid references app_private.stored_objects(id),
  cleanup_requested_at timestamptz,
  cleanup_confirmed_at timestamptz,
  unique(document_id,provider,options_sha256),
  unique(provider,provider_job_id)
);
create table app_private.render_artifacts (
  id uuid primary key default gen_random_uuid(),
  ocr_run_id uuid not null references app_private.ocr_runs(id),
  renderer_version text not null,
  manifest_object_id uuid not null references app_private.stored_objects(id),
  ready_at timestamptz not null default now(),
  unique(ocr_run_id,renderer_version)
);
create table app_private.library_items (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references app_private.accounts(id),
  document_id uuid not null references app_private.documents(id),
  added_at timestamptz not null default now(),
  removed_at timestamptz,
  unique(account_id,document_id)
);
create index library_account_recent on app_private.library_items(account_id,added_at desc);

create function public.v1_account_context() returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('account_id',app_private.require_actor(),'protocol_version',1,
    'roles',coalesce((select jsonb_agg(role) from app_private.app_roles where account_id=app_private.actor()),'[]'::jsonb),
    'operator_verified',app_private.is_operator())
$$;
create function public.v1_library() returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.added_at desc),'[]'::jsonb) from (
    select li.id,li.document_id,li.added_at,d.scope,d.page_count,
      p.title,p.authors,p.abstract,p.publication_year,
      (select ra.id from app_private.render_artifacts ra join app_private.ocr_runs o on o.id=ra.ocr_run_id
        where o.document_id=d.id order by ra.ready_at desc limit 1) as artifact_id
    from app_private.library_items li join app_private.documents d on d.id=li.document_id
    left join lateral (select pv.publication_id from app_private.version_documents vd
      join app_private.publication_versions pv on pv.id=vd.version_id where vd.document_id=d.id limit 1) v on true
    left join app_private.publications p on p.id=v.publication_id
    where li.account_id=app_private.require_actor() and li.removed_at is null
    limit 500
  ) r
$$;
create function public.v1_set_library_item(p_document_id uuid,p_present boolean) returns uuid
language plpgsql security definer set search_path = '' as $$
declare a uuid := app_private.require_actor(); result uuid;
begin
  if p_present is null then raise exception 'invalid_presence'; end if;
  if not exists(select 1 from app_private.documents where id=p_document_id and (scope='shared_catalog' or owner_id=a)) then
    raise exception 'document_unavailable' using errcode='42501';
  end if;
  insert into app_private.library_items(account_id,document_id,removed_at)
    values(a,p_document_id,case when p_present then null else now() end)
    on conflict(account_id,document_id) do update set removed_at=excluded.removed_at
    returning id into result;
  return result;
end $$;

do $$ declare t record; begin
  for t in select tablename from pg_tables where schemaname='app_private' loop
    execute format('alter table app_private.%I enable row level security',t.tablename);
  end loop;
end $$;
revoke all on all functions in schema app_private from public,anon,authenticated;
revoke all on all functions in schema public from public,anon,authenticated;
grant execute on function public.v1_account_context(),public.v1_library(),public.v1_set_library_item(uuid,boolean) to authenticated;
commit;
