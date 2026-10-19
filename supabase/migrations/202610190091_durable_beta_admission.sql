-- An invitation is independent of a deletable account. See NATIVE_AUTHENTICATION.md.
-- Deploy this deny-by-default hook before enabling signup in Auth configuration.
begin;
set local lock_timeout='15s';

create table app_private.beta_admissions (
 email_sha256 bytea primary key check(octet_length(email_sha256)=32),
 allowed boolean not null,
 authority_account_id uuid,
 reason text not null check(char_length(reason) between 1 and 200),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table app_private.beta_admissions enable row level security;
revoke all on app_private.beta_admissions from public,anon,authenticated,service_role;

create function app_private.beta_email_key(p_email text) returns bytea
language sql immutable strict set search_path='' as $$
 select case when char_length(btrim(p_email)) between 3 and 254
  and btrim(p_email) ~ '^[^@[:space:][:cntrl:]]+@[^@[:space:][:cntrl:]]+$'
 then sha256(convert_to(lower(btrim(p_email)),'UTF8')) end
$$;

-- Identity data is written by Auth after provider verification, never raw_user_meta_data.
create function app_private.beta_user_emails(p_user_id uuid) returns table(email_key bytea)
language sql stable set search_path='' as $$
 select distinct k from (
  select app_private.beta_email_key(u.email) k from auth.users u
   where u.id=p_user_id and u.email_confirmed_at is not null
  union all
  select app_private.beta_email_key(i.identity_data->>'email') from auth.identities i
   where i.user_id=p_user_id and i.identity_data->>'email_verified'='true'
 ) emails where k is not null
$$;

-- Preserve existing beta access, including a disabled login's denial. This copies no user content.
insert into app_private.beta_admissions(email_sha256,allowed,reason)
 select e.email_key,bool_and(u.banned_until is null or u.banned_until<=now()),'Existing verified beta identity'
 from auth.users u cross join lateral app_private.beta_user_emails(u.id) e group by e.email_key;

create function app_private.retain_beta_admission() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into app_private.beta_admissions(email_sha256,allowed,authority_account_id,reason)
  select e.email_key,old.banned_until is null or old.banned_until<=now(),old.id,'Verified identity at account deletion'
  from app_private.beta_user_emails(old.id) e
  on conflict(email_sha256) do nothing; -- A revoked invitation never revives on deletion.
 return old;
end $$;
create trigger retain_beta_admission_before_delete before delete on auth.users
 for each row execute function app_private.retain_beta_admission();

create function public.hook_beta_before_user_created(event jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare k bytea;
begin
 if jsonb_typeof(event->'user'->'email')='string'
    and coalesce(event->'user'->>'is_anonymous','false')='false' then
  k:=app_private.beta_email_key(event->'user'->>'email');
 end if;
 if k is not null and exists(select 1 from app_private.beta_admissions where email_sha256=k and allowed) then
  return '{}'::jsonb;
 end if;
 return '{"error":{"http_code":403,"message":"beta_invitation_required"}}'::jsonb;
end $$;
revoke all on function public.hook_beta_before_user_created(jsonb) from public,anon,authenticated,service_role;
grant usage on schema public to supabase_auth_admin;
grant execute on function public.hook_beta_before_user_created(jsonb) to supabase_auth_admin;

-- Called only after the Edge function's owner/MFA gate, before Auth creates the login.
create function public.worker_admin_admit_email(p_actor_id uuid,p_email text) returns void
language plpgsql security definer set search_path='' as $$
declare k bytea;
begin
 perform app_private.require_owner_account(p_actor_id);
 k:=app_private.beta_email_key(p_email);
 if k is null then raise exception 'invalid_email'; end if;
 -- Adding an existing disabled tester must not silently undo the owner's ban.
 if exists(select 1 from auth.users u cross join lateral app_private.beta_user_emails(u.id) e
    where e.email_key=k and u.banned_until>now()) then raise exception 'account_disabled'; end if;
 insert into app_private.beta_admissions(email_sha256,allowed,authority_account_id,reason)
 values(k,true,p_actor_id,'Private-beta tester admitted from admin')
 on conflict(email_sha256) do update set allowed=true,authority_account_id=p_actor_id,
  reason=excluded.reason,updated_at=now();
 insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
 values(p_actor_id,'beta_admission',encode(k,'hex'),'Private-beta invitation retained independently of account','{}');
end $$;
revoke all on function public.worker_admin_admit_email(uuid,text) from public,anon,authenticated;
grant execute on function public.worker_admin_admit_email(uuid,text) to service_role;

alter function public.worker_admin_set_sign_in(uuid,uuid,uuid,boolean,text) rename to admin_set_sign_in_before_091;
alter function public.admin_set_sign_in_before_091(uuid,uuid,uuid,boolean,text) set schema app_private;
revoke all on function app_private.admin_set_sign_in_before_091(uuid,uuid,uuid,boolean,text) from public,anon,authenticated,service_role;
create function public.worker_admin_set_sign_in(p_actor_id uuid,p_request_id uuid,p_account_id uuid,p_disabled boolean,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=app_private.admin_set_sign_in_before_091(p_actor_id,p_request_id,p_account_id,p_disabled,p_reason);
 insert into app_private.beta_admissions(email_sha256,allowed,authority_account_id,reason)
 select e.email_key,not p_disabled,p_actor_id,'Admin sign-in permission changed'
 from app_private.beta_user_emails((result->>'auth_user_id')::uuid) e
 on conflict(email_sha256) do update set allowed=excluded.allowed,authority_account_id=p_actor_id,
  reason=excluded.reason,updated_at=now();
 return result;
end $$;
revoke all on function public.worker_admin_set_sign_in(uuid,uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.worker_admin_set_sign_in(uuid,uuid,uuid,boolean,text) to service_role;
revoke all on function app_private.beta_email_key(text),app_private.beta_user_emails(uuid),
 app_private.retain_beta_admission() from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
