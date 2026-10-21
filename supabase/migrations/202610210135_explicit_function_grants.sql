-- 135: Objects created in `public` after this migration get no default grant to anon or authenticated (review D5,
-- 2026-10-21; design: docs/architecture/DATA_MODEL.md "Query, evolution, and deletion rules").
-- Supabase's project defaults grant every new table, sequence and function in `public` to anon, authenticated and
-- service_role. Migration 001's `revoke execute on functions from public` is per-schema, which PostgreSQL cannot use to
-- remove the global PUBLIC default, so it never applied: every migration revokes PUBLIC, anon and authenticated itself
-- (tests/database/default_privileges.sql fails on a public function anon can execute). After this, revoking PUBLIC is
-- enough, and a new public table or sequence is not readable by the client roles unless a migration grants it.
-- Existing objects are unchanged (all already revoke anon explicitly); only the migrating role's defaults change.
-- service_role's defaults are unchanged.
begin;
set local lock_timeout='15s';
alter default privileges in schema public revoke all on functions from anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
commit;
