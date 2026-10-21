-- Migration 135 and the final grants (review D5). bootstrap.sql emulates Supabase's project defaults (every new object
-- in public granted to anon, authenticated and service_role), so these checks see what a hosted project would.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;

-- 1. No public function is executable by anon (directly or through PUBLIC).
select test.assert(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute')),
 'no public function is executable by anon: ' || coalesce((select string_agg(p.proname, ', ') from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute')), ''));

-- 2. authenticated reaches only versioned client RPCs and the owner's catalog promotion (which checks the owner itself).
select test.assert(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and has_function_privilege('authenticated', p.oid, 'execute')
   and p.proname !~ '^v[0-9]+_' and p.proname<>'admin_catalog_promote'),
 'authenticated executes only v*_ RPCs and admin_catalog_promote: ' || coalesce((select string_agg(p.proname, ', ') from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and has_function_privilege('authenticated', p.oid, 'execute')
   and p.proname !~ '^v[0-9]+_' and p.proname<>'admin_catalog_promote'), ''));
select test.assert(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname like 'worker\_%' and (has_function_privilege('authenticated', p.oid, 'execute')
   or has_function_privilege('anon', p.oid, 'execute'))), 'no worker function is reachable by a client role');

-- 3. The migrating role's defaults no longer grant anon or authenticated anything in public.
select test.assert(not exists(select 1 from pg_default_acl d, aclexplode(d.defaclacl) x
  where d.defaclrole=current_user::regrole and d.defaclnamespace='public'::regnamespace
   and x.grantee in ('anon'::regrole, 'authenticated'::regrole)), 'no default grant to anon or authenticated in public');
select test.assert(exists(select 1 from pg_default_acl d, aclexplode(d.defaclacl) x
  where d.defaclrole=current_user::regrole and d.defaclnamespace='public'::regnamespace and d.defaclobjtype='f'
   and x.grantee='service_role'::regrole and x.privilege_type='EXECUTE'), 'service_role keeps its default EXECUTE');

-- 4. PostgreSQL's global default lets PUBLIC execute a new function whatever a schema's defaults say (per-schema default
--    privileges cannot revoke a global one, so migration 001's `revoke execute ... from public` never applied). Every
--    migration therefore still revokes PUBLIC explicitly, and check 1 fails on one that forgets. What migration 135
--    changes: revoking PUBLIC is now enough; anon and authenticated keep no separate grant from Supabase's defaults.
create function public.test_forgotten_revoke() returns integer language sql as $$ select 1 $$;
create table public.test_forgotten_table(id integer);
select test.assert(has_function_privilege('anon', 'public.test_forgotten_revoke()', 'execute'),
 'PUBLIC still executes a new function until its migration revokes it (the global default; check 1 guards it)');
revoke all on function public.test_forgotten_revoke() from public;
select test.assert(not has_function_privilege('anon', 'public.test_forgotten_revoke()', 'execute')
 and not has_function_privilege('authenticated', 'public.test_forgotten_revoke()', 'execute'),
 'revoking PUBLIC alone closes a new function to the client roles (no anon/authenticated default grant)');
select test.assert(has_function_privilege('service_role', 'public.test_forgotten_revoke()', 'execute'), 'service_role still executes a new function');
select test.assert(not has_table_privilege('anon', 'public.test_forgotten_table', 'select')
 and not has_table_privilege('authenticated', 'public.test_forgotten_table', 'select'), 'a new public table is not granted to clients by default');
rollback;
