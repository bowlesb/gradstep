-- Candidate only. Assign the final migration number during reviewed promotion.
-- This removes the pre-035 service-role descriptor entry point; current
-- worker_reader_delivery_create retains its SECURITY DEFINER internal call.
-- No policy, quota, object, URL, function body or credential is changed here.
--
-- This ACL change alone is NOT the bounded-only cutover. After the dual-mode
-- canary, retain asset enforcement and set delivery mode=bounded separately.
-- The fence time is the later commit of that policy and this ACL change.
-- Drain all pre-fence Edge issuers for 400s, then allow their last possible
-- 900s signed token to expire before scoped CDN purge and retirement checks.
-- Privilege revocation cannot recall a descriptor already returned to an issuer.
begin;
set local lock_timeout='15s';

do $$
declare guarded record; legacy record;
begin
 select proowner,prosecdef into strict guarded from pg_proc
  where oid='public.worker_reader_delivery_create(uuid,uuid,bytea,text)'::regprocedure;
 select proowner,prosecdef into strict legacy from pg_proc
  where oid='public.worker_reader_descriptor(uuid,uuid)'::regprocedure;
 if not guarded.prosecdef or not legacy.prosecdef or guarded.proowner<>legacy.proowner then
  raise exception 'reader_issuer_owner_review_required';
 end if;
end $$;

revoke all on function public.worker_reader_descriptor(uuid,uuid)
 from public,anon,authenticated,service_role;

do $$
declare role_name text; owner_name name;
begin
 foreach role_name in array array['anon','authenticated','service_role'] loop
  if has_function_privilege(role_name,'public.worker_reader_descriptor(uuid,uuid)','EXECUTE') then
   raise exception 'reader_issuer_fence_incomplete';
  end if;
 end loop;
 select pg_get_userbyid(proowner) into strict owner_name from pg_proc
  where oid='public.worker_reader_delivery_create(uuid,uuid,bytea,text)'::regprocedure;
 if not has_function_privilege(owner_name,'public.worker_reader_descriptor(uuid,uuid)','EXECUTE')
  or not has_function_privilege('service_role','public.worker_reader_delivery_create(uuid,uuid,bytea,text)','EXECUTE') then
  raise exception 'reader_guarded_issuer_unavailable';
 end if;
end $$;

notify pgrst,'reload schema';
commit;
