-- Search without OpenAlex (owner decision, 2026-10-15; docs/architecture/ARXIV_DEVICE_ONLY.md §5.6, rollout step 4).
-- Two switches, both leaving today's behaviour in place until they are changed:
--   `device_search_enabled` (false): the reader capability `device_search` tells new apps and the browser to search
--     from the device (native: arXiv's API; browser: DataCite) instead of calling `discover?q=`.
--   `openalex_enabled` (true): the server's own search (older builds) and its DOI lookups still use OpenAlex; set false,
--     search asks DataCite and a DOI is named by Crossref.
-- Nothing is assigned to devices: the capability says only how a person's own search runs.
begin;
set local lock_timeout='15s';

alter table app_private.pipeline_policy add column device_search_enabled boolean not null default false;
alter table app_private.pipeline_policy add column openalex_enabled boolean not null default true;

-- The server functions' view of the switches (discover, add-paper, add-reference).
create function public.worker_search_policy() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('openalex',coalesce((select openalex_enabled from app_private.pipeline_policy where singleton),true),
  'device_search',coalesce((select device_search_enabled from app_private.pipeline_policy where singleton),false))
$$;

alter function public.v1_reader_capabilities() rename to reader_capabilities_before_072;
alter function public.reader_capabilities_before_072() set schema app_private;
create function public.v1_reader_capabilities() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 return app_private.reader_capabilities_before_072()||jsonb_build_object('device_search',jsonb_build_object(
  'enabled',coalesce((select device_search_enabled from app_private.pipeline_policy where singleton),false),
  'format','device-search-v1'));
end $$;

revoke all on function app_private.reader_capabilities_before_072() from public,anon,authenticated,service_role;
revoke all on function public.worker_search_policy(),public.v1_reader_capabilities() from public,anon,authenticated,service_role;
grant execute on function public.v1_reader_capabilities() to authenticated;
grant execute on function public.worker_search_policy() to service_role;
notify pgrst,'reload schema';
commit;
