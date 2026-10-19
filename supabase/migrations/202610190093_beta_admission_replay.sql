-- Admission follows current sign-in permission, including on an old command replay.
-- The wrapped RPC returns current disabled state (034); its input is historical intent.
begin;
set local lock_timeout='15s';
create or replace function public.worker_admin_set_sign_in(p_actor_id uuid,p_request_id uuid,p_account_id uuid,p_disabled boolean,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=app_private.admin_set_sign_in_before_091(p_actor_id,p_request_id,p_account_id,p_disabled,p_reason);
 insert into app_private.beta_admissions(email_sha256,allowed,authority_account_id,reason)
 select e.email_key,not (result->>'disabled')::boolean,p_actor_id,'Admin sign-in permission changed'
 from app_private.beta_user_emails((result->>'auth_user_id')::uuid) e
 on conflict(email_sha256) do update set allowed=excluded.allowed,authority_account_id=p_actor_id,
  reason=excluded.reason,updated_at=now();
 return result;
end $$;
revoke all on function public.worker_admin_set_sign_in(uuid,uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.worker_admin_set_sign_in(uuid,uuid,uuid,boolean,text) to service_role;
notify pgrst,'reload schema';
commit;
