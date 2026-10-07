-- Owner-only account management for the private beta: the admin site's Accounts tab
-- (LEGACY_GAP_AUDIT "No way to invite or manage accounts"; decision in DECISIONS.md
-- "Admin accounts"). Additive: no existing function, table or row changes.
--
-- Read: v1_admin_accounts (owner with MFA, the same gate as every v1_admin_* function) lists
-- every account, closed ones and synthetic test logins included.
--
-- Changes go through the admin-accounts Edge function. It checks the caller with v1_admin_actor
-- (that same owner + MFA gate, evaluated on the caller's own token), then calls these
-- service-role functions with the owner's account ID, which they check again:
--   worker_admin_find_login     the account whose login has an email (adding is idempotent)
--   worker_admin_add_tester     audits the addition and grants starting credits once per account
--   worker_admin_grant_credits  an audited 'adjustment' grant of 1-2,000 credits, once per request ID
--   worker_admin_set_sign_in    audits a disable/enable before the function changes the Auth ban
-- Sign-up stays invite-only (disable_signup): the function creates logins with the Auth admin
-- API, and the existing auth.users trigger (migration 001) creates the account row, exactly as
-- for any other login. Nothing here sends email or deletes anything.
begin;
set local lock_timeout='15s';

-- The list reads these Auth columns; fail here, not at the first read, if they are unreadable.
do $$ begin
 perform u.id,u.email,u.last_sign_in_at,u.banned_until,u.raw_app_meta_data from auth.users u limit 1;
end $$;

insert into app_private.api_rate_rules values('admin-accounts',3600,120,600) on conflict(route) do nothing;

-- Disable/enable requests are idempotent per request ID (grants use the credit bucket's key).
create unique index admin_audit_request on app_private.admin_audit_events((details->>'request_id'))
 where details ? 'request_id';

-- The caller's account, if the caller is an owner signed in with MFA (the Edge function's gate).
create function public.v1_admin_actor() returns uuid language plpgsql stable security definer set search_path='' as $$
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 return app_private.actor();
end $$;

-- Service-side re-check of the account the Edge function acts for: an open owner account.
create function app_private.require_owner_account(p_actor uuid) returns void
language plpgsql stable security definer set search_path='' as $$
begin
 if p_actor is null or not exists(select 1 from app_private.accounts a join app_private.app_roles r on r.account_id=a.id
   where a.id=p_actor and a.closed_at is null and a.auth_user_id is not null and r.role='owner') then
  raise exception 'owner_required' using errcode='42501';
 end if;
end $$;

-- An audit reason: one line of 3-500 characters.
create function app_private.admin_reason(p_reason text) returns text language plpgsql immutable set search_path='' as $$
declare r text := btrim(p_reason);
begin
 if r is null or char_length(r) not between 3 and 500 or r ~ '[[:cntrl:]]' then raise exception 'invalid_reason'; end if;
 return r;
end $$;

-- closed: deleted (login gone); closing: deletion started, login not yet removed;
-- disabled: sign-in banned by an owner; otherwise active.
create function app_private.admin_account_status(p_closed_at timestamptz,p_auth_user_id uuid,p_banned_until timestamptz) returns text
language sql stable set search_path='' as $$
 select case when p_closed_at is not null and p_auth_user_id is null then 'closed'
  when p_closed_at is not null then 'closing'
  when p_banned_until>now() then 'disabled' else 'active' end
$$;

create function public.v1_admin_accounts(p_search text default null,p_sort text default 'created',p_ascending boolean default false,
 p_limit integer default 200) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare needle text := lower(btrim(coalesce(p_search,''))); result jsonb;
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_sort is null or p_sort not in ('created','last_sign_in') or p_ascending is null or p_limit is null or p_limit not between 1 and 500
  or char_length(needle)>254 then raise exception 'invalid_accounts_query'; end if;
 with matched as (
  select a.id,a.created_at,a.closed_at,a.auth_user_id,u.email,u.last_sign_in_at,u.banned_until,u.raw_app_meta_data
  from app_private.accounts a left join auth.users u on u.id=a.auth_user_id
  where needle='' or position(needle in lower(coalesce(u.email,'')))>0
 ), page as (
  select m.*,case when p_sort='created' then m.created_at else m.last_sign_in_at end as sort_at from matched m
  order by case when not p_ascending then case when p_sort='created' then m.created_at else m.last_sign_in_at end end desc nulls last,
   case when p_ascending then case when p_sort='created' then m.created_at else m.last_sign_in_at end end asc nulls last,
   m.id
  limit p_limit
 )
 select jsonb_build_object('generated_at',now(),'total',(select count(*) from app_private.accounts),'matched',(select count(*) from matched),
  'accounts',coalesce(jsonb_agg(jsonb_build_object(
   'id',p.id,
   'email',p.email,
   'synthetic',coalesce(lower(p.email) like '%@example.invalid',false),
   'created_at',p.created_at,
   'last_sign_in_at',p.last_sign_in_at,
   'providers',case when jsonb_typeof(p.raw_app_meta_data->'providers')='array' then p.raw_app_meta_data->'providers' else '[]'::jsonb end,
   'status',app_private.admin_account_status(p.closed_at,p.auth_user_id,p.banned_until),
   'roles',coalesce((select jsonb_agg(r.role order by r.role) from app_private.app_roles r where r.account_id=p.id),'[]'::jsonb),
   'plan',(select jsonb_build_object('plan',sp.plan,'environment',t.environment,'expires_at',t.expires_at)
     from app_private.store_transactions t join app_private.store_products sp using(product_id)
     where t.account_id=p.id and sp.kind='subscription' and t.revoked_at is null and t.expires_at>now() order by t.expires_at desc limit 1),
   'credits',(select jsonb_build_object(
     'available',coalesce(sum(b.balance-b.reserved) filter(where b.revoked_at is null and b.starts_at<=now() and (b.expires_at is null or b.expires_at>now())),0),
     'reserved',coalesce(sum(b.reserved),0)) from app_private.credit_buckets b where b.account_id=p.id),
   'library_items',(select count(*) from app_private.library_items li where li.account_id=p.id and li.removed_at is null))
   order by case when not p_ascending then p.sort_at end desc nulls last,case when p_ascending then p.sort_at end asc nulls last,p.id),'[]'::jsonb))
 into result from page p;
 return result;
end $$;

-- The open or closing account whose login has this email (Auth stores emails lowercased), or null.
create function public.worker_admin_find_login(p_email text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare e text := lower(btrim(p_email)); result jsonb;
begin
 if e is null or char_length(e) not between 3 and 254 or position('@' in e)<2 or e ~ '[[:space:][:cntrl:]]' then raise exception 'invalid_email'; end if;
 select jsonb_build_object('account_id',a.id,'closed',a.closed_at is not null) into result
 from auth.users u join app_private.accounts a on a.auth_user_id=u.id
 where lower(u.email)=e order by u.created_at,u.id limit 1;
 return result;
end $$;

-- After the function found or created the login: record the addition (once per account) and
-- grant starting credits (once per account; a later call reports the earlier grant).
create function public.worker_admin_add_tester(p_actor_id uuid,p_account_id uuid,p_created boolean,p_credits bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare acct app_private.accounts; start_key text := 'tester-start:'||p_account_id; b app_private.credit_buckets;
 granted bigint; bucket uuid; banned timestamptz;
begin
 perform app_private.require_owner_account(p_actor_id);
 if p_account_id is null or p_created is null or p_credits is null or p_credits not between 0 and 2000 then raise exception 'invalid_tester'; end if;
 select * into acct from app_private.accounts where id=p_account_id for update;
 if not found then raise exception 'account_unavailable'; end if;
 if acct.closed_at is not null or acct.auth_user_id is null then raise exception 'account_closed'; end if;
 if not exists(select 1 from app_private.admin_audit_events where action='add_tester' and target_id=p_account_id::text) then
  insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
  values(p_actor_id,'add_tester',p_account_id::text,'Private-beta tester added from the admin site',jsonb_build_object('login_created',p_created));
 end if;
 select u.banned_until into banned from auth.users u where u.id=acct.auth_user_id;
 select * into b from app_private.credit_buckets where source='adjustment' and external_key=start_key;
 if found then
  select l.balance_delta into granted from app_private.credit_ledger l where l.bucket_id=b.id and l.entry_key='grant';
  return jsonb_build_object('account_id',p_account_id,'status',app_private.admin_account_status(acct.closed_at,acct.auth_user_id,banned),
   'starting_credits',coalesce(granted,0),'starting_granted',false);
 end if;
 if p_credits>0 then
  bucket:=public.worker_grant_credits(p_account_id,'adjustment',start_key,p_credits,now(),null,'Private-beta tester starting credits');
  insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
  values(p_actor_id,'grant_credits',p_account_id::text,'Private-beta tester starting credits',
   jsonb_build_object('credits',p_credits,'bucket_id',bucket,'starting',true));
 end if;
 return jsonb_build_object('account_id',p_account_id,'status',app_private.admin_account_status(acct.closed_at,acct.auth_user_id,banned),
  'starting_credits',p_credits,'starting_granted',p_credits>0);
end $$;

-- An owner's credit grant: never-expiring 'adjustment' credits, at most 2,000 per grant, keyed
-- by the request ID so a retried request grants once. Grant and audit commit together.
create function public.worker_admin_grant_credits(p_actor_id uuid,p_request_id uuid,p_account_id uuid,p_credits bigint,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r text; acct app_private.accounts; grant_key text := 'admin:'||p_request_id; b app_private.credit_buckets; granted bigint; bucket uuid;
begin
 perform app_private.require_owner_account(p_actor_id);
 r:=app_private.admin_reason(p_reason);
 if p_request_id is null or p_account_id is null or p_credits is null or p_credits not between 1 and 2000 then raise exception 'invalid_grant'; end if;
 -- Same lock order as worker_grant_credits: account, then bucket.
 select * into acct from app_private.accounts where id=p_account_id for update;
 if not found then raise exception 'account_unavailable'; end if;
 select * into b from app_private.credit_buckets where source='adjustment' and external_key=grant_key;
 if found then
  select l.balance_delta into granted from app_private.credit_ledger l where l.bucket_id=b.id and l.entry_key='grant';
  if b.account_id<>p_account_id or granted is distinct from p_credits then raise exception 'request_id_conflict'; end if;
  return jsonb_build_object('bucket_id',b.id,'credits',granted,'replayed',true);
 end if;
 if acct.closed_at is not null then raise exception 'account_closed'; end if;
 bucket:=public.worker_grant_credits(p_account_id,'adjustment',grant_key,p_credits,now(),null,'Admin grant: '||r);
 insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
 values(p_actor_id,'grant_credits',p_account_id::text,r,jsonb_build_object('credits',p_credits,'bucket_id',bucket,'request_id',p_request_id));
 return jsonb_build_object('bucket_id',bucket,'credits',p_credits,'replayed',false);
end $$;

-- Records an owner's disable/enable of an account's sign-in and returns its login for the Auth
-- ban, which the Edge function applies after this commits (the audit records the request; the
-- list shows Auth's actual state). A repeated request ID returns the same login so the change
-- can be reapplied. Owners cannot be disabled here.
create function public.worker_admin_set_sign_in(p_actor_id uuid,p_request_id uuid,p_account_id uuid,p_disabled boolean,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r text; acct app_private.accounts; prior app_private.admin_audit_events; act text;
begin
 perform app_private.require_owner_account(p_actor_id);
 r:=app_private.admin_reason(p_reason);
 if p_request_id is null or p_account_id is null or p_disabled is null then raise exception 'invalid_sign_in_change'; end if;
 act:=case when p_disabled then 'disable_sign_in' else 'enable_sign_in' end;
 select * into acct from app_private.accounts where id=p_account_id for update;
 if not found then raise exception 'account_unavailable'; end if;
 select * into prior from app_private.admin_audit_events where details ? 'request_id' and details->>'request_id'=p_request_id::text;
 if found then
  if prior.action<>act or prior.target_id<>p_account_id::text then raise exception 'request_id_conflict'; end if;
 else
  if p_disabled and (p_account_id=p_actor_id or exists(select 1 from app_private.app_roles where account_id=p_account_id and role='owner')) then
   raise exception 'owner_cannot_be_disabled';
  end if;
  if acct.closed_at is not null or acct.auth_user_id is null then raise exception 'account_closed'; end if;
  insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
  values(p_actor_id,act,p_account_id::text,r,jsonb_build_object('request_id',p_request_id));
 end if;
 if acct.closed_at is not null or acct.auth_user_id is null then raise exception 'account_closed'; end if;
 return jsonb_build_object('auth_user_id',acct.auth_user_id,'disabled',p_disabled,'replayed',prior.id is not null);
end $$;

revoke all on function app_private.require_owner_account(uuid) from public,anon,authenticated;
revoke all on function app_private.admin_reason(text) from public,anon,authenticated;
revoke all on function app_private.admin_account_status(timestamptz,uuid,timestamptz) from public,anon,authenticated;
revoke all on function public.v1_admin_actor() from public,anon;
revoke all on function public.v1_admin_accounts(text,text,boolean,integer) from public,anon;
grant execute on function public.v1_admin_actor() to authenticated;
grant execute on function public.v1_admin_accounts(text,text,boolean,integer) to authenticated;
revoke all on function public.worker_admin_find_login(text) from public,anon,authenticated;
revoke all on function public.worker_admin_add_tester(uuid,uuid,boolean,bigint) from public,anon,authenticated;
revoke all on function public.worker_admin_grant_credits(uuid,uuid,uuid,bigint,text) from public,anon,authenticated;
revoke all on function public.worker_admin_set_sign_in(uuid,uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.worker_admin_find_login(text) to service_role;
grant execute on function public.worker_admin_add_tester(uuid,uuid,boolean,bigint) to service_role;
grant execute on function public.worker_admin_grant_credits(uuid,uuid,uuid,bigint,text) to service_role;
grant execute on function public.worker_admin_set_sign_in(uuid,uuid,uuid,boolean,text) to service_role;
notify pgrst,'reload schema';
commit;
