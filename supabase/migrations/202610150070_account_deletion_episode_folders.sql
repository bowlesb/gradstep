-- Account deletion sweeps the account's own episode folders (privacy audit 2026-10-15). Private episode audio
-- (podcast-assets/private/<account>/) and the paper text a device sent for an episode
-- (private-content/podcast-sources/<account>/) were removed only through their registered storage records, so an
-- object written without one (a registration that failed after the write) outlived the account. The deletion plan
-- now lists both folders; the edge function's allow-list accepts exactly these two prefixes for the account.
begin;
alter function public.worker_delete_account_begin(uuid) rename to delete_account_begin_before_070;
alter function public.delete_account_begin_before_070(uuid) set schema app_private;
create function public.worker_delete_account_begin(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=app_private.delete_account_begin_before_070(p_account_id);
 if result ? 'blocked' then return result; end if;
 return jsonb_set(result,'{prefixes}',coalesce(result->'prefixes','[]'::jsonb)||jsonb_build_array(
  jsonb_build_object('bucket','podcast-assets','prefix','private/'||p_account_id::text||'/'),
  jsonb_build_object('bucket','private-content','prefix','podcast-sources/'||p_account_id::text||'/')));
end $$;
revoke all on function app_private.delete_account_begin_before_070(uuid) from public,anon,authenticated,service_role;
revoke all on function public.worker_delete_account_begin(uuid) from public,anon,authenticated,service_role;
grant execute on function public.worker_delete_account_begin(uuid) to service_role;
commit;
