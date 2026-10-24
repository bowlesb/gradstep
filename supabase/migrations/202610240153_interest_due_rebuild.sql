-- Interest index: the rebuild is due-based, never a single missable slot (docs/architecture/INTEREST_INDEX.md §2,
-- "Rebuild cadence"; lead's clarification 2026-10-24). A rebuild is due once the published map is rebuild_days old
-- (14 while the corpus is under weekly_after_papers, then 7). interest_kick (every 10 minutes) starts it in the preferred
-- quiet window (weekend, 06:00-10:00 UTC), or at the next tick whatever the time once it has been due for overdue_hours
-- (24). A failed or blocked build retries with back-off (10 minutes, 1 hour, then 6 hours). The kick writes a heartbeat;
-- Health names a stalled kick and a worker that never answers. Additive: 0152 is unchanged; its rebuild_dow and
-- rebuild_hour columns are superseded by the window below.
begin;
set local lock_timeout='15s';

alter table app_private.interest_policy
 add column window_dows smallint[] not null default '{0,6}' check(cardinality(window_dows) between 1 and 7 and window_dows <@ '{0,1,2,3,4,5,6}'),
 add column window_start_hour smallint not null default 6 check(window_start_hour between 0 and 23),
 add column window_end_hour smallint not null default 10 check(window_end_hour between 1 and 24),
 add column overdue_hours integer not null default 24 check(overdue_hours between 1 and 720);
alter table app_private.interest_state
 add column last_tick_at timestamptz,
 add column rebuild_running_since timestamptz,
 add column rebuild_failures integer not null default 0 check(rebuild_failures>=0),
 add column rebuild_retry_at timestamptz,
 add column rebuild_last_error text check(rebuild_last_error ~ '^[a-z_]{1,64}$');

-- Due at a given time (testable): forced, or no map yet with nothing pending, or the map is rebuild_days old and it is
-- the quiet window or it has been due for overdue_hours. Never while a failed build waits out its back-off.
create function app_private.interest_rebuild_due_at(p_now timestamptz) returns boolean
language plpgsql stable security definer set search_path='' as $$
declare pol app_private.interest_policy; st app_private.interest_state; last timestamptz; corpus integer; days integer;
 due_at timestamptz; local_ timestamp;
begin
 select * into pol from app_private.interest_policy where singleton;
 select * into st from app_private.interest_state where singleton;
 if st.rebuild_retry_at>p_now then return false; end if;
 if pol.force_rebuild then return true; end if;
 corpus:=app_private.interest_corpus_count();
 if corpus<pol.min_corpus then return false; end if;
 select published_at into last from app_private.interest_map_versions where state='published';
 if last is null then
  return not exists(select 1 from app_private.interest_papers where state='pending' and next_attempt_at<=p_now
   and pool_announced_on>=current_date-pol.corpus_days);
 end if;
 days:=case when corpus<pol.weekly_after_papers then pol.rebuild_days_growing else pol.rebuild_days end;
 due_at:=last+make_interval(days=>days);
 if p_now<due_at then return false; end if;
 if p_now>=due_at+make_interval(hours=>pol.overdue_hours) then return true; end if;
 local_:=p_now at time zone 'UTC';
 return extract(dow from local_)::smallint=any(pol.window_dows)
  and extract(hour from local_)>=pol.window_start_hour and extract(hour from local_)<pol.window_end_hour;
end $$;

create or replace function app_private.interest_rebuild_due() returns boolean language sql stable security definer set search_path='' as $$
 select app_private.interest_rebuild_due_at(now())
$$;

-- The worker marks the start of a build, so a run killed mid-build (timeout, crash) still counts as a failed attempt.
create function public.worker_interest_rebuild_mark(p_claim uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 perform app_private.interest_require_claim(p_claim);
 update app_private.interest_state set rebuild_running_since=now() where singleton;
end $$;

-- One failed build attempt: back off 10 minutes, then 1 hour, then 6 hours.
create function app_private.interest_rebuild_failed(p_error text) returns void language sql security definer set search_path='' as $$
 update app_private.interest_state set rebuild_failures=rebuild_failures+1,
  rebuild_retry_at=now()+case rebuild_failures when 0 then interval '10 minutes' when 1 then interval '1 hour' else interval '6 hours' end,
  rebuild_last_error=case when p_error ~ '^[a-z_]{1,64}$' then p_error else 'rebuild_failed' end,
  rebuild_running_since=null
 where singleton
$$;

create or replace function public.worker_interest_claim(p_claim uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare pol app_private.interest_policy; st app_private.interest_state; v integer;
begin
 select * into strict pol from app_private.interest_policy where singleton;
 if not pol.enabled then return jsonb_build_object('claimed',false,'reason','disabled'); end if;
 select * into strict st from app_private.interest_state where singleton for update;
 if st.claim_id is not null and st.lease_until>now() then return jsonb_build_object('claimed',false,'reason','busy'); end if;
 -- A run whose lease expired ended without releasing: record it as failed, and a build it had started as a failed attempt.
 if st.claim_id is not null then
  update app_private.interest_runs set state='failed',finished_at=now(),error_code='lease_expired' where id=st.claim_id and state='running';
  if st.rebuild_running_since is not null then perform app_private.interest_rebuild_failed('lease_expired'); end if;
 end if;
 update app_private.interest_state set claim_id=p_claim,lease_until=now()+make_interval(secs=>pol.lease_seconds),last_run_at=now() where singleton;
 insert into app_private.interest_runs(id) values(p_claim);
 v:=app_private.interest_published_version();
 return jsonb_build_object('claimed',true,
  'policy',to_jsonb(pol)-'singleton'-'updated_at',
  'map_version',v,
  'map_artifact',(select id from app_private.interest_artifacts where kind='map' and state='published' and map_version=v),
  'terms_artifact',(select id from app_private.interest_artifacts where kind='terms' and state='published' and map_version=v),
  'rebuild_due',app_private.interest_rebuild_due());
end $$;

-- Release also settles the build attempt: a failed build (rebuild_failed in the counts, or a build the stability gate
-- blocked) backs off; a published one resets the back-off. A build still embedding phrases ends neither way.
create or replace function public.worker_interest_release(p_claim uuid,p_state text,p_counts jsonb,p_error text) returns void
language plpgsql security definer set search_path='' as $$
declare mine boolean;
begin
 if p_state not in ('finished','failed') then raise exception 'invalid_interest_release'; end if;
 update app_private.interest_runs set state=p_state,finished_at=now(),counts=coalesce(p_counts,'{}'),
  error_code=case when p_error ~ '^[a-z_]{1,64}$' then p_error end where id=p_claim and state='running';
 mine:=exists(select 1 from app_private.interest_state where singleton and claim_id=p_claim);
 if mine then
  if p_counts ? 'rebuild_failed' then perform app_private.interest_rebuild_failed(p_counts->>'rebuild_failed');
  elsif p_counts#>>'{rebuild,published}'='false' then perform app_private.interest_rebuild_failed(coalesce(p_counts#>>'{rebuild,reason}','rebuild_blocked'));
  elsif p_counts#>>'{rebuild,published}'='true' then
   update app_private.interest_state set rebuild_failures=0,rebuild_retry_at=null,rebuild_last_error=null,rebuild_running_since=null where singleton;
  else update app_private.interest_state set rebuild_running_since=null where singleton;
  end if;
 end if;
 update app_private.interest_state set claim_id=null,lease_until=null where singleton and claim_id=p_claim;
 delete from app_private.interest_runs where started_at<now()-interval '90 days';
end $$;

-- The kick writes a heartbeat on every call while enabled, then posts when work is due (at most once in 2 minutes).
create or replace function app_private.interest_kick() returns boolean language plpgsql security definer set search_path='' as $$
declare url text; secret text; pol app_private.interest_policy; st app_private.interest_state; due boolean;
begin
 select * into pol from app_private.interest_policy where singleton;
 if not coalesce(pol.enabled,false) then return false; end if;
 update app_private.interest_state set last_tick_at=now() where singleton returning * into st;
 if st.lease_until>now() or st.last_kick_at>now()-interval '2 minutes' then return false; end if;
 due:=exists(select 1 from app_private.interest_papers where state='pending' and next_attempt_at<=now())
  or exists(select 1 from app_private.feed_papers f where not exists(select 1 from app_private.interest_papers p where p.source_id=f.source_id))
  or exists(select 1 from app_private.interest_papers p where p.state='embedded' and p.pool_announced_on is not null
   and p.fp_seq>coalesce((select max(fp_seq_to) from app_private.interest_artifacts where kind='shard'),0))
  or app_private.interest_rebuild_due();
 if not due then return false; end if;
 update app_private.interest_state set last_kick_at=now() where singleton;
 if to_regnamespace('net') is null or to_regnamespace('vault') is null then return false; end if;
 begin
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into url using 'science_reader_pipeline_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into secret using 'science_reader_pipeline_secret';
  if url is null or secret is null then return false; end if;
  execute 'select net.http_post(url:=$1,body:=$2,headers:=$3,timeout_milliseconds:=1000)'
   using rtrim(url,'/')||'/interest','{"reason":"interest"}'::jsonb,jsonb_build_object('content-type','application/json','x-pipeline-secret',secret);
 exception when others then return false;
 end;
 return true;
end $$;

create or replace function app_private.interest_health() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare pol app_private.interest_policy; mv app_private.interest_map_versions; v integer; result jsonb; attention jsonb:='[]';
 st app_private.interest_state; days integer;
 pending_old integer; failed_24h integer; embedded_24h integer; last_run app_private.interest_runs; failed_builds integer;
begin
 select * into pol from app_private.interest_policy where singleton;
 select * into st from app_private.interest_state where singleton;
 select * into mv from app_private.interest_map_versions where state='published';
 v:=mv.version;
 days:=case when app_private.interest_corpus_count()<pol.weekly_after_papers then pol.rebuild_days_growing else pol.rebuild_days end;
 -- The wake-up is alive (pg_cron runs interest_kick every 10 minutes; it writes last_tick_at).
 if pol.enabled and coalesce(st.last_tick_at,pol.updated_at)<now()-interval '1 hour' then
  attention:=attention||jsonb_build_object('kind','interest_kick_stalled','last_tick_at',st.last_tick_at); end if;
 -- The worker answers: a post 30 minutes ago with no run claimed since means pg_net or the worker is down.
 if pol.enabled and st.last_kick_at<now()-interval '30 minutes' and coalesce(st.last_run_at,'-infinity')<st.last_kick_at then
  attention:=attention||jsonb_build_object('kind','interest_worker_unreachable','posted_at',st.last_kick_at); end if;
 if st.rebuild_failures>=2 then attention:=attention||jsonb_build_object('kind','interest_rebuild_retrying',
  'failures',st.rebuild_failures,'retry_at',st.rebuild_retry_at,'error',st.rebuild_last_error); end if;
 select count(*) into pending_old from app_private.interest_papers where state='pending' and updated_at<now()-interval '24 hours';
 select count(*) filter(where state='failed' and updated_at>now()-interval '24 hours'),
  count(*) filter(where state='embedded' and embedded_at>now()-interval '24 hours') into failed_24h,embedded_24h from app_private.interest_papers;
 select * into last_run from app_private.interest_runs order by started_at desc limit 1;
 select count(*) into failed_builds from (select state from app_private.interest_map_versions order by version desc limit 2) x
  where state in ('failed','blocked');
 if pol.enabled and pending_old>=50 then attention:=attention||jsonb_build_object('kind','interest_backlog','papers',pending_old); end if;
 if pol.enabled and failed_24h>greatest(5,0.01*embedded_24h) then attention:=attention||jsonb_build_object('kind','interest_failures','papers',failed_24h); end if;
 if pol.enabled and v is not null and mv.published_at<now()-make_interval(days=>days+2) then attention:=attention||jsonb_build_object('kind','interest_map_stale','published_at',mv.published_at); end if;
 if failed_builds>=2 then attention:=attention||jsonb_build_object('kind','interest_rebuild_failed'); end if;
 if exists(select 1 from app_private.interest_map_versions where state='blocked' and version>coalesce(v,0)) then
  attention:=attention||jsonb_build_object('kind','interest_stability_blocked'); end if;
 if v is not null and (mv.stats#>>'{levels,3,kept_share}')::real<pol.gate_warn then
  attention:=attention||jsonb_build_object('kind','interest_stability_low','kept_share',(mv.stats#>>'{levels,3,kept_share}')::real); end if;
 if last_run.error_code='interest_model_mismatch' then attention:=attention||jsonb_build_object('kind','interest_model_mismatch'); end if;
 result:=jsonb_build_object(
  'enabled',pol.enabled,'serving',pol.serving,'model_version',pol.model_version,
  'schedule',jsonb_build_object('rebuild_days',days,'due_at',mv.published_at+make_interval(days=>days),
   'due_now',app_private.interest_rebuild_due(),'last_tick_at',st.last_tick_at,'last_post_at',st.last_kick_at,'last_run_at',st.last_run_at,
   'rebuild_failures',st.rebuild_failures,'rebuild_retry_at',st.rebuild_retry_at),
  'corpus',(select jsonb_build_object(
    'pool_in_window',count(*) filter(where pool_announced_on>=current_date-pol.corpus_days),
    'embedded',count(*) filter(where state='embedded'),'pending',count(*) filter(where state='pending'),
    'failed',count(*) filter(where state='failed'),'catalog',count(*) filter(where in_catalog and pool_announced_on is null),
    'catalog_embedded',count(*) filter(where in_catalog and pool_announced_on is null and state='embedded'),
    'oldest_pending',min(updated_at) filter(where state='pending'),'embedded_24h',embedded_24h,'failed_24h',failed_24h)
   from app_private.interest_papers),
  'last_run',case when last_run.id is not null then jsonb_build_object('started_at',last_run.started_at,'finished_at',last_run.finished_at,
   'state',last_run.state,'counts',last_run.counts,'error_code',last_run.error_code) end,
  'map',case when v is not null then jsonb_build_object('version',v,'kind',mv.kind,'published_at',mv.published_at,
   'corpus_papers',mv.corpus_papers,'stats',mv.stats,
   'nodes',(select jsonb_object_agg(level,c) from (select level,count(*) c from app_private.interest_node_versions where version=v group by level) x),
   'leaf_sizes',(select jsonb_build_object('min',min(size),'median',percentile_cont(0.5) within group(order by size),'max',max(size))
    from app_private.interest_node_versions where version=v and level=3)) end,
  'artifacts',(select jsonb_build_object(
    'map_bytes',max(bytes) filter(where kind='map' and map_version=v),'terms_bytes',max(bytes) filter(where kind='terms' and map_version=v),
    'shards',count(*) filter(where kind='shard' and state='published'),
    'shard_bytes',coalesce(sum(bytes) filter(where kind='shard' and state='published'),0))
   from app_private.interest_artifacts where state='published'),
  'term_vectors',(select count(*) from app_private.interest_term_vectors),
  'delivery',(select jsonb_build_object('requests_24h',coalesce(sum(w.used) filter(where w.scope_id='environment'),0),
    'accounts_24h',count(distinct w.scope_id) filter(where w.scope_id<>'environment'))
   from app_private.api_rate_windows w where w.route in ('interest-index','interest-library') and w.window_start>now()-interval '24 hours'),
  'attention',attention);
 return result;
end $$;


revoke all on function app_private.interest_rebuild_due_at(timestamptz),app_private.interest_rebuild_failed(text)
 from public,anon,authenticated,service_role;
revoke all on function public.worker_interest_rebuild_mark(uuid) from public,anon,authenticated;
grant execute on function public.worker_interest_rebuild_mark(uuid) to service_role;

notify pgrst,'reload schema';
commit;
