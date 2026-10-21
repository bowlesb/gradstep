-- Real admission/deletion/ACL schedules; no provider or email transport.
begin;
do $$ begin
 if exists(select 1 from pg_tables where schemaname='app_private' and not rowsecurity) then
  raise exception 'Private table missing RLS';
 end if;
end $$;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
grant usage on schema test to anon,authenticated,service_role,supabase_auth_admin;
grant execute on function test.assert(boolean,text) to anon,authenticated,service_role,supabase_auth_admin;
\set OWN '91000000-0000-0000-0000-000000000001'
\set A '91000000-0000-0000-0000-000000000002'
\set B '91000000-0000-0000-0000-000000000003'
insert into auth.users(id,email,email_confirmed_at) values
 (:'OWN','owner-91@example.invalid',now()),(:'A','tester-91@example.invalid',now());
insert into app_private.app_roles(account_id,role) values(:'OWN','owner');
insert into auth.identities(user_id,provider,identity_data) values
 (:'A','apple','{"email":"relay-91@privaterelay.appleid.com","email_verified":true}'),
 (:'A','google','{"email":"unverified-91@example.invalid","email_verified":false}');

set role supabase_auth_admin;
select test.assert(public.hook_beta_before_user_created('{"user":{"email":"stranger@example.invalid"}}')#>>'{error,message}'='beta_invitation_required','unknown denied');
select test.assert(public.hook_beta_before_user_created('{"user":{"email":42}}') ? 'error','malformed denied');
select test.assert(public.hook_beta_before_user_created('{}') ? 'error','missing identity denied');
reset role;

set role service_role;
select public.worker_admin_admit_email(:'OWN','tester-91@example.invalid');
reset role;
set role supabase_auth_admin;
select test.assert(public.hook_beta_before_user_created('{"user":{"email":" TESTER-91@EXAMPLE.INVALID "}}')='{}','admitted exact normalized email');
select test.assert(public.hook_beta_before_user_created('{"user":{"email":"tester-91@example.invalid","is_anonymous":true}}') ? 'error','no anonymous admission');
reset role;

-- Actual deletion closes the old account and removes the login and provider identities.
set role service_role;
select public.worker_delete_account_begin(:'A');
select public.worker_delete_account_finish(:'A');
reset role;
delete from auth.users where id=:'A';
select test.assert(not exists(select 1 from auth.identities where user_id=:'A'),'provider identity erased');
select test.assert(exists(select 1 from app_private.accounts where id=:'A' and closed_at is not null),'old account remains closed');
set role supabase_auth_admin;
select test.assert(public.hook_beta_before_user_created('{"user":{"email":"tester-91@example.invalid"}}')='{}','return allowed after deletion');
-- Since migration 127 (review A21) deletion invites only addresses already admitted; a later-linked identity is not.
select test.assert(public.hook_beta_before_user_created('{"user":{"email":"relay-91@privaterelay.appleid.com"}}') ? 'error','a linked identity is not invited by deletion (127)');
select test.assert(public.hook_beta_before_user_created('{"user":{"email":"unverified-91@example.invalid"}}') ? 'error','unverified linked address never admitted');
reset role;
insert into auth.users(id,email,email_confirmed_at) values(:'B','tester-91@example.invalid',now());
select test.assert(exists(select 1 from app_private.accounts where id=:'B' and closed_at is null),'fresh account');
select test.assert(not exists(select 1 from app_private.credit_buckets where account_id=:'B'),'no old credits restored');
select test.assert(not exists(select 1 from app_private.app_roles where account_id=:'B'),'no old roles restored');

set role service_role;
select gen_random_uuid() as disable_request, gen_random_uuid() as enable_request \gset
select public.worker_admin_set_sign_in(:'OWN',:'disable_request',:'B',true,'Tester left beta');
select public.worker_admin_set_sign_in(:'OWN',:'enable_request',:'B',false,'Tester returned');
select public.worker_admin_set_sign_in(:'OWN',:'disable_request',:'B',true,'Retry old disable');
reset role;
set role supabase_auth_admin;
select test.assert(public.hook_beta_before_user_created('{"user":{"email":"tester-91@example.invalid"}}')='{}','old disable replay cannot undo current enable');
reset role;
set role service_role;
select public.worker_admin_set_sign_in(:'OWN',gen_random_uuid(),:'B',true,'Tester left beta again');
select public.worker_admin_set_sign_in(:'OWN',:'enable_request',:'B',false,'Retry old enable');
reset role;
set role supabase_auth_admin;
select test.assert(public.hook_beta_before_user_created('{"user":{"email":"tester-91@example.invalid"}}') ? 'error','explicit revocation blocks recreation');
reset role;
set role service_role;
select public.worker_delete_account_begin(:'B');
select public.worker_delete_account_finish(:'B');
reset role;
delete from auth.users where id=:'B';
set role supabase_auth_admin;
select test.assert(public.hook_beta_before_user_created('{"user":{"email":"tester-91@example.invalid"}}') ? 'error','deletion never undoes revocation');
reset role;

select test.assert(not has_table_privilege('anon','app_private.beta_admissions','select')
 and not has_table_privilege('authenticated','app_private.beta_admissions','select')
 and not has_table_privilege('service_role','app_private.beta_admissions','insert'),'table private');
select test.assert(not has_function_privilege('anon','public.hook_beta_before_user_created(jsonb)','execute')
 and not has_function_privilege('authenticated','public.hook_beta_before_user_created(jsonb)','execute')
 and not has_function_privilege('service_role','public.hook_beta_before_user_created(jsonb)','execute'),'hook Auth-only');
select test.assert(not has_function_privilege('authenticated','public.worker_admin_admit_email(uuid,text)','execute'),'customer cannot admit');
set role service_role;
do $$ begin
 perform public.worker_admin_admit_email('91000000-0000-0000-0000-000000000003','stranger@example.invalid');
 raise exception 'nonowner admitted';
exception when others then if sqlerrm='nonowner admitted' then raise; end if; end $$;
reset role;
rollback;
