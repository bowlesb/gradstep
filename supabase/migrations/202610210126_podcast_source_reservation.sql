-- 126: A device's podcast source text is reserved before it is written (review A17, 2026-10-21;
-- docs/architecture/PAPER_PODCASTS.md "Reserved before written"). The Edge function uploaded the text and only then
-- registered it, so the quotas, a request limit and the podcast switch were applied after the object existed: a
-- refused registration left an object with no stored_objects row, and any tester could add storage while podcasts were
-- off. Additive: one rate rule and one service RPC, called before the upload; the existing registration
-- (migration 076) then turns the pending row verified. The day-old sweep (076) already schedules pending rows.
begin;
set local lock_timeout='15s';

insert into app_private.api_rate_rules values('podcast-source',3600,20,200) on conflict(route) do nothing;

create function public.worker_podcast_source_reserve(p_account uuid,p_sha256 text,p_bytes bigint,p_path text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o app_private.stored_objects; pol app_private.podcast_policy; used bigint; suspended boolean;
begin
 -- Only one upload's own path (<account>/<digest>/<uuid>.txt); the one-path-per-digest form is never reserved.
 if p_account is null or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' or p_bytes is null or p_bytes<1 or p_bytes>409600
  or p_path is null or not app_private.podcast_source_path(p_account,p_sha256,p_path)
  or p_path='podcast-sources/'||p_account::text||'/'||p_sha256||'.txt' then raise exception 'invalid_podcast_request'; end if;
 -- The account first (one reservation at a time per account), as every podcast write locks it.
 select spending_suspended into suspended from app_private.accounts where id=p_account and closed_at is null for update;
 if not found then raise exception 'account_unavailable'; end if;
 if suspended then raise exception 'spending_suspended'; end if;
 select * into o from app_private.stored_objects where path=p_path for update;
 if found then
  -- The same reservation again (a retried call): its own row, no second request counted.
  if o.bucket<>'private-content' or o.owner_id is distinct from p_account or o.sha256<>decode(p_sha256,'hex') or o.byte_count<>p_bytes
   or o.state not in ('pending','verified') then raise exception 'source_unavailable'; end if;
  return jsonb_build_object('object_id',o.id,'path',o.path,'bytes',o.byte_count,'state',o.state);
 end if;
 -- The quote's gate: nothing is stored for episodes that cannot be made.
 select * into strict pol from app_private.podcast_policy where singleton;
 if not pol.generation_enabled or not app_private.podcast_inventory_certified() then raise exception 'podcast_unavailable'; end if;
 perform public.worker_consume_request(p_account,'podcast-source');
 select coalesce(sum(byte_count),0) into used from app_private.stored_objects
  where bucket='private-content' and owner_id=p_account and path like 'podcast-sources/%' and state<>'deleted';
 if used+p_bytes>67108864 then raise exception 'storage_full'; end if;
 -- The overall quota, one reservation at a time (a transaction-scoped lock taken after the account's).
 perform pg_advisory_xact_lock(hashtextextended('gradstep.podcast-sources.quota',0));
 select coalesce(sum(byte_count),0) into used from app_private.stored_objects
  where bucket='private-content' and path like 'podcast-sources/%' and state<>'deleted';
 if used+p_bytes>2147483648 then raise exception 'storage_full'; end if;
 insert into app_private.stored_objects(bucket,path,owner_id,sha256,byte_count,media_type,state)
  values('private-content',p_path,p_account,decode(p_sha256,'hex'),p_bytes,'text/plain','pending') returning * into o;
 return jsonb_build_object('object_id',o.id,'path',o.path,'bytes',o.byte_count,'state',o.state);
end $$;
revoke all on function public.worker_podcast_source_reserve(uuid,text,bigint,text) from public,anon,authenticated;
grant execute on function public.worker_podcast_source_reserve(uuid,text,bigint,text) to service_role;
notify pgrst,'reload schema';
commit;
