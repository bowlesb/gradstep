-- Local test-only Supabase Auth surface; not a migration and never deployed.
do $$ begin
 if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
 if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
 if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
 if not exists(select 1 from pg_roles where rolname='supabase_auth_admin') then create role supabase_auth_admin nologin; end if;
end $$;
create schema auth;
create table auth.users(id uuid primary key);
-- Columns the admin accounts list reads (GoTrue's names and types); id stays first so
-- fixtures can keep inserting bare IDs.
alter table auth.users add column email varchar(255), add column created_at timestamptz default now(),
 add column last_sign_in_at timestamptz, add column banned_until timestamptz, add column raw_app_meta_data jsonb;
alter table auth.users add column email_confirmed_at timestamptz;
create table auth.identities(id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users on delete cascade,
 provider text not null,identity_data jsonb not null);
create function auth.uid() returns uuid language sql stable as $$
 select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
create function auth.jwt() returns jsonb language sql stable as $$
 select jsonb_build_object('sub',auth.uid(),'aal',coalesce(nullif(current_setting('request.jwt.claim.aal',true),''),'aal1'))
$$;
grant usage on schema public,auth to anon,authenticated,service_role;
grant execute on all functions in schema auth to anon,authenticated,service_role;
-- Supabase's project defaults (review D5, 2026-10-21): the role that runs migrations grants every new object in
-- public to anon, authenticated and service_role (PUBLIC keeps PostgreSQL's global EXECUTE default too), so a function
-- whose migration forgets `revoke ... from public, anon, authenticated` is callable by them on a hosted project.
-- Emulated here so a forgotten revoke fails the privilege checks locally too (tests/database/default_privileges.sql).
alter default privileges in schema public grant all on tables to anon,authenticated,service_role;
alter default privileges in schema public grant all on sequences to anon,authenticated,service_role;
alter default privileges in schema public grant all on functions to anon,authenticated,service_role;
