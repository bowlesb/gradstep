-- Account deletion (migration 070): the plan lists the account's private episode folder and the folder of paper text
-- its devices sent for episodes, beside the earlier folders; a blocked plan still lists nothing. Synthetic local SQL.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;

\set D '70000000-0000-0000-0000-00000000000d'
insert into auth.users(id,email) values(:'D','deleting@gradstep.test.org');
update app_private.accounts set closed_at=now() where id=:'D';
create temp table plan as select public.worker_delete_account_begin(:'D') as p;
select test.assert(not ((select p from plan) ? 'blocked'),'nothing blocks this account''s deletion');
select test.assert((select p->'prefixes' from plan) @> jsonb_build_array(jsonb_build_object('bucket','podcast-assets','prefix','private/'||:'D'||'/')),'private episodes are swept');
select test.assert((select p->'prefixes' from plan) @> jsonb_build_array(jsonb_build_object('bucket','private-content','prefix','podcast-sources/'||:'D'||'/')),'episode source text is swept');
select test.assert((select p->'prefixes' from plan) @> jsonb_build_array(jsonb_build_object('bucket','paper-uploads','prefix',:'D'||'/')),'the earlier folders stay in the plan');
select test.assert(not exists(select 1 from jsonb_array_elements((select p->'prefixes' from plan)) e where e->>'prefix' in ('shared/','private/','podcast-sources/')),'never a shared or every-account folder');
select test.assert(not has_function_privilege('authenticated','public.worker_delete_account_begin(uuid)','execute'),'readers cannot call it');
rollback;
