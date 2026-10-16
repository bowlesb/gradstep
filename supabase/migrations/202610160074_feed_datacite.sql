-- The Feed's shared pool from DataCite instead of arXiv's RSS (owner decision 2026-10-16; docs/architecture/
-- ARXIV_DEVICE_ONLY.md §5.5, rollout step 4): one switch, `feed_source`, leaving today's RSS in place until it changes.
--   'arxiv_rss' (default): the `arxiv-ml` source row and arXiv's combined RSS, as before.
--   'datacite': the `datacite-ml` source row; feed-refresh reads DataCite's arXiv records for the pool's categories
--     (once for everyone), and discover's live chip fallback reads DataCite too. The `arxiv-ml` row stays for audit.
-- Pool freshness already reads the newest success across sources (migration 046), so either row serves.
begin;
set local lock_timeout='15s';

alter table app_private.pipeline_policy add column feed_source text not null default 'arxiv_rss'
 check (feed_source in ('arxiv_rss','datacite'));

-- The source row the active switch uses.
create function app_private.feed_active_source() returns text language sql stable security definer set search_path='' as $$
 select case coalesce((select feed_source from app_private.pipeline_policy where singleton),'arxiv_rss')
  when 'datacite' then 'datacite-ml' else 'arxiv-ml' end
$$;

-- Migration 043's claim, on the active source row, telling the function which source it is ('kind').
create or replace function public.worker_feed_refresh_claim() returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.feed_policy; s app_private.feed_sources; claim uuid:=gen_random_uuid(); source text:=app_private.feed_active_source();
begin
 select * into strict pol from app_private.feed_policy where singleton;
 if not pol.refresh_enabled then return null; end if;
 insert into app_private.feed_sources(name,categories) values(source,pol.categories) on conflict(name) do nothing;
 select * into strict s from app_private.feed_sources where name=source for update;
 if s.categories is distinct from pol.categories then
  update app_private.feed_sources set categories=pol.categories,etag=null,last_modified=null,next_check_at=now()
   where name=s.name returning * into s;
 end if;
 if s.next_check_at>now() or (s.lease_until is not null and s.lease_until>now()) then return null; end if;
 update app_private.feed_sources set claim_id=claim,lease_until=now()+make_interval(secs=>pol.lease_seconds),last_attempt_at=now()
  where name=s.name;
 return jsonb_build_object('claim_id',claim,'source',s.name,'kind',case s.name when 'datacite-ml' then 'datacite' else 'arxiv_rss' end,
  'categories',to_jsonb(s.categories),'etag',s.etag,'last_modified',s.last_modified,'max_items',pol.max_items);
end $$;

-- Migration 043's cron wake-up, on the active source row.
create or replace function app_private.feed_refresh_kick() returns boolean language plpgsql security definer set search_path='' as $$
declare due boolean; url text; secret text;
begin
 select p.refresh_enabled and coalesce((select s.next_check_at<=now() and (s.lease_until is null or s.lease_until<=now())
   from app_private.feed_sources s where s.name=app_private.feed_active_source()),true) into due from app_private.feed_policy p where p.singleton;
 if not coalesce(due,false) or to_regnamespace('net') is null or to_regnamespace('vault') is null then return false; end if;
 begin
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into url using 'science_reader_feed_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into secret using 'science_reader_feed_secret';
  if url is null or secret is null then return false; end if;
  execute 'select net.http_post(url:=$1,body:=$2,headers:=$3,timeout_milliseconds:=10000)'
   using url,'{"reason":"cron"}'::jsonb,jsonb_build_object('content-type','application/json','x-feed-secret',secret);
  return true;
 exception when others then return false;
 end;
end $$;

-- Migration 072's view of the switches, with the Feed's source (discover's live chip fallback reads it).
create or replace function public.worker_search_policy() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('openalex',coalesce((select openalex_enabled from app_private.pipeline_policy where singleton),true),
  'device_search',coalesce((select device_search_enabled from app_private.pipeline_policy where singleton),false),
  'feed_source',coalesce((select feed_source from app_private.pipeline_policy where singleton),'arxiv_rss'))
$$;

revoke all on function app_private.feed_active_source(),app_private.feed_refresh_kick() from public,anon,authenticated,service_role;
revoke all on function public.worker_feed_refresh_claim(),public.worker_search_policy() from public,anon,authenticated,service_role;
grant execute on function public.worker_feed_refresh_claim(),public.worker_search_policy() to service_role;
notify pgrst,'reload schema';
commit;
