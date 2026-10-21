-- 127: Beta admission gaps (review A21, 2026-10-21; docs/architecture/NATIVE_AUTHENTICATION.md "Revocation and transfer
-- gaps"). Additive to 091/093:
--  1. worker_admin_revoke_email: an owner-checked, audited withdrawal of one address's invitation (no hand SQL);
--  2. the deletion trigger stops creating admissions, so an address that reached the login only later (an email change
--     or a linked identity) is never invited by deleting the account; admitted addresses already have rows that survive;
--  3. admitting refuses an address whose open account is spending_suspended (the database half of Disable sign-in,
--     committed before the Edge function's Auth ban), as well as an Auth ban.
begin;
set local lock_timeout='15s';

-- 1. Withdraw an invitation. Stops future account creation with the address; a current login is stopped with Disable
-- sign-in (the result says whether one exists). An address an open owner account signs in with is refused.
create function public.worker_admin_revoke_email(p_actor_id uuid,p_email text,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare k bytea; r text; prior app_private.beta_admissions; login boolean;
begin
 perform app_private.require_owner_account(p_actor_id);
 r:=app_private.admin_reason(p_reason);
 k:=app_private.beta_email_key(p_email);
 if k is null then raise exception 'invalid_email'; end if;
 if exists(select 1 from auth.users u join app_private.accounts a on a.auth_user_id=u.id
    join app_private.app_roles ro on ro.account_id=a.id and ro.role='owner'
    cross join lateral app_private.beta_user_emails(u.id) e where e.email_key=k and a.closed_at is null) then
  raise exception 'owner_cannot_be_disabled';
 end if;
 select * into prior from app_private.beta_admissions where email_sha256=k for update;
 login:=exists(select 1 from auth.users u join app_private.accounts a on a.auth_user_id=u.id
  cross join lateral app_private.beta_user_emails(u.id) e where e.email_key=k and a.closed_at is null);
 insert into app_private.beta_admissions(email_sha256,allowed,authority_account_id,reason)
 values(k,false,p_actor_id,'Private-beta invitation withdrawn from admin')
 on conflict(email_sha256) do update set allowed=false,authority_account_id=p_actor_id,reason=excluded.reason,updated_at=now();
 insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
 values(p_actor_id,'beta_revocation',encode(k,'hex'),r,jsonb_build_object('previously',case when prior.email_sha256 is null then 'none'
  when prior.allowed then 'allowed' else 'withdrawn' end,'existing_login',login));
 return jsonb_build_object('revoked',true,'previously',case when prior.email_sha256 is null then 'none' when prior.allowed then 'allowed' else 'withdrawn' end,
  'existing_login',login);
end $$;
revoke all on function public.worker_admin_revoke_email(uuid,text,text) from public,anon,authenticated;
grant execute on function public.worker_admin_revoke_email(uuid,text,text) to service_role;

-- 2. Deletion no longer creates admissions (every admitted address already has a row, which survives deletion).
drop trigger retain_beta_admission_before_delete on auth.users;
drop function app_private.retain_beta_admission();

-- 3. As 091, and a suspended open account counts as disabled too.
create or replace function public.worker_admin_admit_email(p_actor_id uuid,p_email text) returns void
language plpgsql security definer set search_path='' as $$
declare k bytea;
begin
 perform app_private.require_owner_account(p_actor_id);
 k:=app_private.beta_email_key(p_email);
 if k is null then raise exception 'invalid_email'; end if;
 -- Adding an existing disabled tester must not silently undo the owner's ban, including in the moment between the
 -- database's disable (spending_suspended) and the Auth ban the Edge function applies after it.
 if exists(select 1 from auth.users u cross join lateral app_private.beta_user_emails(u.id) e
    left join app_private.accounts a on a.auth_user_id=u.id
    where e.email_key=k and (u.banned_until>now() or (a.closed_at is null and a.spending_suspended))) then raise exception 'account_disabled'; end if;
 insert into app_private.beta_admissions(email_sha256,allowed,authority_account_id,reason)
 values(k,true,p_actor_id,'Private-beta tester admitted from admin')
 on conflict(email_sha256) do update set allowed=true,authority_account_id=p_actor_id,
  reason=excluded.reason,updated_at=now();
 insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
 values(p_actor_id,'beta_admission',encode(k,'hex'),'Private-beta invitation retained independently of account','{}');
end $$;
revoke all on function public.worker_admin_admit_email(uuid,text) from public,anon,authenticated;
grant execute on function public.worker_admin_admit_email(uuid,text) to service_role;
notify pgrst,'reload schema';
commit;
