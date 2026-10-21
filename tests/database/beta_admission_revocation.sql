-- Review A21 (migration 127): an owner can withdraw an invitation (audited, never the owner's own address); deleting
-- an account no longer invites an address that reached the login only later (changed email, linked identity); an admit
-- during a disable (database suspended, Auth not yet banned) is refused. Synthetic local SQL, all migrations.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to anon,authenticated,service_role,supabase_auth_admin;
grant execute on all functions in schema test to anon,authenticated,service_role,supabase_auth_admin;
create function test.admitted(email text) returns boolean language sql as $$
 select public.hook_beta_before_user_created(jsonb_build_object('user',jsonb_build_object('email',email)))='{}'::jsonb $$;
grant execute on function test.admitted(text) to supabase_auth_admin;

\set OWN '12700000-0000-4000-8000-00000000000f'
\set A '12700000-0000-4000-8000-00000000000a'
\set B '12700000-0000-4000-8000-00000000000b'
insert into auth.users(id,email,email_confirmed_at) values(:'OWN','owner-127@example.invalid',now());
insert into app_private.app_roles(account_id,role) values(:'OWN','owner');

-- An admitted tester changes the login's email to someone else's address and links another person's Google identity,
-- then deletes the account: only the address the owner admitted returns.
set role service_role;
select public.worker_admin_admit_email(:'OWN','tester-127@example.invalid');
reset role;
insert into auth.users(id,email,email_confirmed_at) values(:'A','tester-127@example.invalid',now());
update auth.users set email='friend-127@example.invalid',email_confirmed_at=now() where id=:'A';
insert into auth.identities(user_id,provider,identity_data) values(:'A','google','{"email":"linked-127@example.invalid","email_verified":true}');
set role service_role;
select public.worker_delete_account_begin(:'A');
select public.worker_delete_account_finish(:'A');
reset role;
delete from auth.users where id=:'A';
set role supabase_auth_admin;
select test.assert(test.admitted('tester-127@example.invalid'),'the admitted address still returns after deletion');
select test.assert(not test.admitted('friend-127@example.invalid'),'a changed email is not invited by deleting the account');
select test.assert(not test.admitted('linked-127@example.invalid'),'a linked identity''s address is not invited by deleting the account');
reset role;
select test.assert(not exists(select 1 from pg_trigger where tgname='retain_beta_admission_before_delete'),'the deletion trigger is gone');

-- Withdraw an invitation: owner-checked, reasoned, audited; the hook then refuses; re-admitting is explicit.
set role service_role;
select test.reject(format('select public.worker_admin_revoke_email(%L,%L,%L)',:'A','tester-127@example.invalid','Left the beta'),'owner_required');
select test.reject(format('select public.worker_admin_revoke_email(%L,%L,%L)',:'OWN','tester-127@example.invalid','x'),'invalid_reason');
select test.reject(format('select public.worker_admin_revoke_email(%L,%L,%L)',:'OWN','not an address','Mistyped'),'invalid_email');
select test.reject(format('select public.worker_admin_revoke_email(%L,%L,%L)',:'OWN',' OWNER-127@example.invalid ','Lock myself out'),'owner_cannot_be_disabled');
select public.worker_admin_revoke_email(:'OWN',' TESTER-127@Example.Invalid ','Left the beta') as revoked \gset
reset role;
select test.assert((:'revoked'::jsonb->>'previously')='allowed' and (:'revoked'::jsonb->>'existing_login')='false','result says what changed and that no login uses it');
select test.assert((select count(*)=1 from app_private.admin_audit_events where action='beta_revocation' and actor_id=:'OWN'
 and target_id=encode(app_private.beta_email_key('tester-127@example.invalid'),'hex') and reason='Left the beta'),'revocation audited with the owner and reason');
select test.assert((select not allowed and authority_account_id=:'OWN' from app_private.beta_admissions where email_sha256=app_private.beta_email_key('tester-127@example.invalid')),'recorded as withdrawn');
set role supabase_auth_admin;
select test.assert(not test.admitted('tester-127@example.invalid'),'a withdrawn invitation creates no account');
reset role;
-- A mistyped address that was never admitted can be withdrawn too (recorded as withdrawn ahead of time).
set role service_role;
select test.assert(public.worker_admin_revoke_email(:'OWN','typo-127@example.invalid','Mistyped address')->>'previously'='none','an unknown address is recorded withdrawn');
select public.worker_admin_admit_email(:'OWN','tester-127@example.invalid');
reset role;
set role supabase_auth_admin;
select test.assert(test.admitted('tester-127@example.invalid'),'a later admit re-allows it');
reset role;

-- A current login: revoking says so (Disable sign-in stops the login itself).
insert into auth.users(id,email,email_confirmed_at) values(:'B','current-127@example.invalid',now());
set role service_role;
select test.assert((public.worker_admin_revoke_email(:'OWN','current-127@example.invalid','Stop future accounts')->>'existing_login')::boolean,'existing login reported');
-- Admitting during a disable: the database already suspended the account, Auth has not banned the login yet.
select public.worker_admin_admit_email(:'OWN','current-127@example.invalid');
reset role;
update app_private.accounts set spending_suspended=true where id=:'B';
set role service_role;
select test.reject(format('select public.worker_admin_admit_email(%L,%L)',:'OWN','current-127@example.invalid'),'account_disabled');
reset role;
update auth.users set banned_until=now()+interval '1 day' where id=:'B';
update app_private.accounts set spending_suspended=false where id=:'B';
set role service_role;
select test.reject(format('select public.worker_admin_admit_email(%L,%L)',:'OWN','current-127@example.invalid'),'account_disabled');
reset role;

select test.assert(not has_function_privilege('authenticated','public.worker_admin_revoke_email(uuid,text,text)','execute')
 and not has_function_privilege('anon','public.worker_admin_revoke_email(uuid,text,text)','execute')
 and has_function_privilege('service_role','public.worker_admin_revoke_email(uuid,text,text)','execute'),'service role only, after the Edge owner gate');
rollback;
