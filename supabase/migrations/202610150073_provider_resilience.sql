-- Resilience, server side (docs/architecture/RESILIENCE.md, owner 2026-10-15: "I don't want the entire app to break if a
-- response starts failing"). Four parts, none of them touching charges:
--   1. Provider health: per hour, per provider, per route, per outcome class, counts only (never content, never who),
--      written by a never-failing RPC that also keeps a circuit breaker per provider.
--   2. Fault injection for drills: rows that make a provider look throttled/overloaded/failing to ONE test account
--      (@example.invalid / @example.test), set by an owner or the drill script, every row kept as the record.
--   3. Podcasts requeue on a transient refusal (a 429: never processed, never billed) instead of failing for good.
--   4. The owner's Health tab gains provider errors, breaker state and an hourly table.
begin;

-- ---------------------------------------------------------------------------
-- 1. Provider health and breakers
-- ---------------------------------------------------------------------------
create table app_private.provider_health_hours (
  hour timestamptz not null,
  provider text not null check (provider ~ '^[a-z][a-z0-9_]{0,31}$'),
  route text not null check (route ~ '^[a-z][a-z0-9_]{0,31}$'),
  outcome text not null check (outcome in ('ok','throttled','overloaded','server_error','timeout','transport','rejected','breaker_open')),
  calls integer not null default 0 check (calls >= 0),
  latency_ms_total bigint not null default 0 check (latency_ms_total >= 0),
  latency_ms_max integer not null default 0 check (latency_ms_max >= 0),
  retry_after_max_s integer check (retry_after_max_s between 0 and 86400),
  primary key (hour, provider, route, outcome)
);
alter table app_private.provider_health_hours enable row level security;
revoke all on app_private.provider_health_hours from public, anon, authenticated;

-- One row per provider, shared by every function instance and worker thread, so a provider's outage is discovered
-- once, not by each instance. Open after 5 failures (throttled, overloaded, 5xx, timeout, transport) each within 60 s
-- of the last; cool off 30 s, doubling per reopening to 5 min; after the cool-off one call is let through (half open):
-- success closes, failure reopens for longer.
create table app_private.provider_breakers (
  provider text primary key check (provider ~ '^[a-z][a-z0-9_]{0,31}$'),
  state text not null default 'closed' check (state in ('closed','open')),
  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  last_failure_at timestamptz,
  opened_at timestamptz,
  reopen_at timestamptz,
  open_count integer not null default 0 check (open_count >= 0),
  updated_at timestamptz not null default now(),
  check ((state = 'open') = (reopen_at is not null))
);
alter table app_private.provider_breakers enable row level security;
revoke all on app_private.provider_breakers from public, anon, authenticated;

create function app_private.provider_breaker_view(b app_private.provider_breakers) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object('provider', b.provider,
  'state', case when b.state = 'open' and b.reopen_at <= now() then 'half_open' else coalesce(b.state, 'closed') end,
  'reopen_at', b.reopen_at)
$$;

-- Records one provider call and returns that provider's breaker. Never raises: telemetry must not fail a request.
-- A fault drill's synthetic answer (p_drill) is counted under the route `drill`, apart from real traffic, and never
-- moves the breaker: a drill on one test account must not pause a provider for everyone.
create function public.worker_provider_health(p_provider text, p_route text, p_outcome text, p_latency_ms integer default 0,
  p_retry_after_s integer default null, p_drill boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare h timestamptz := date_trunc('hour', now()); b app_private.provider_breakers; cool integer; latency integer; kept_route text;
begin
 begin
  if p_provider is null or p_provider !~ '^[a-z][a-z0-9_]{0,31}$' or p_route is null or p_route !~ '^[a-z][a-z0-9_]{0,31}$'
   or p_outcome is null or p_outcome not in ('ok','throttled','overloaded','server_error','timeout','transport','rejected','breaker_open')
  then return null; end if;
  kept_route := case when coalesce(p_drill, false) then 'drill' else p_route end;
  latency := least(greatest(coalesce(p_latency_ms, 0), 0), 86400000);
  insert into app_private.provider_health_hours as t (hour, provider, route, outcome, calls, latency_ms_total, latency_ms_max, retry_after_max_s)
  values (h, p_provider, kept_route, p_outcome, 1, latency, latency, case when p_retry_after_s between 0 and 86400 then p_retry_after_s end)
  on conflict (hour, provider, route, outcome) do update set calls = t.calls + 1,
   latency_ms_total = t.latency_ms_total + excluded.latency_ms_total,
   latency_ms_max = greatest(t.latency_ms_max, excluded.latency_ms_max),
   retry_after_max_s = greatest(t.retry_after_max_s, excluded.retry_after_max_s);
  -- 90 days kept: the first call recorded in a new hour clears what is older.
  if (select count(*) from app_private.provider_health_hours where hour = h) = 1 then
   delete from app_private.provider_health_hours where hour < h - interval '90 days';
  end if;

  -- A client error (rejected) says nothing about the provider's health; a failed-fast call is the breaker's own doing;
  -- a drill is ours.
  if p_outcome in ('rejected', 'breaker_open') or coalesce(p_drill, false) then
   select * into b from app_private.provider_breakers where provider = p_provider;
   return case when found then app_private.provider_breaker_view(b) else jsonb_build_object('provider', p_provider, 'state', 'closed', 'reopen_at', null) end;
  end if;
  if p_outcome = 'ok' then
   select * into b from app_private.provider_breakers where provider = p_provider;
   if not found then return jsonb_build_object('provider', p_provider, 'state', 'closed', 'reopen_at', null); end if;
   if b.state = 'closed' and b.consecutive_failures = 0 then return app_private.provider_breaker_view(b); end if;
   update app_private.provider_breakers set state = 'closed', consecutive_failures = 0, open_count = 0, reopen_at = null, updated_at = now()
    where provider = p_provider returning * into b;
   return app_private.provider_breaker_view(b);
  end if;

  insert into app_private.provider_breakers(provider) values (p_provider) on conflict do nothing;
  select * into b from app_private.provider_breakers where provider = p_provider for update;
  if b.state = 'closed' then
   b.consecutive_failures := case when b.last_failure_at > now() - interval '60 seconds' then b.consecutive_failures + 1 else 1 end;
   if b.consecutive_failures >= 5 then
    cool := least(300, 30 * power(2, least(b.open_count, 4))::integer);
    b.state := 'open'; b.opened_at := now(); b.reopen_at := now() + make_interval(secs => cool); b.open_count := b.open_count + 1;
   end if;
  elsif b.reopen_at <= now() then
   -- The half-open probe failed: open again, for longer.
   cool := least(300, 30 * power(2, least(b.open_count, 4))::integer);
   b.opened_at := now(); b.reopen_at := now() + make_interval(secs => cool); b.open_count := b.open_count + 1;
  end if;  -- Open and still cooling off: a call already in flight failing changes nothing.
  update app_private.provider_breakers set state = b.state, consecutive_failures = b.consecutive_failures, last_failure_at = now(),
   opened_at = b.opened_at, reopen_at = b.reopen_at, open_count = b.open_count, updated_at = now()
   where provider = p_provider returning * into b;
  return app_private.provider_breaker_view(b);
 exception when others then return null;
 end;
end $$;

-- What a drill reads back (scripts/fault-drill.mjs): the last minutes' counts by provider, route and outcome.
create function public.worker_provider_health_recent(p_minutes integer default 10) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('hour', hour, 'provider', provider, 'route', route, 'outcome', outcome, 'calls', calls,
   'retry_after_max_s', retry_after_max_s) order by hour desc, provider, route, outcome), '[]'::jsonb)
 from app_private.provider_health_hours where hour >= date_trunc('hour', now() - make_interval(mins => least(greatest(coalesce(p_minutes, 10), 1), 1440)))
$$;

-- The current breakers (an instance asks once at start; afterwards each recorded call returns its provider's).
create function public.worker_provider_breakers() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(app_private.provider_breaker_view(b) order by b.provider), '[]'::jsonb) from app_private.provider_breakers b
 where b.state <> 'closed'
$$;

-- ---------------------------------------------------------------------------
-- 2. Fault injection (drills): one test account, a bounded time, every row kept
-- ---------------------------------------------------------------------------
create table app_private.fault_injection (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references app_private.accounts(id),
  provider text not null check (provider ~ '^[a-z][a-z0-9_]{0,31}$'),
  route text check (route is null or route ~ '^[a-z][a-z0-9_]{0,31}$'),
  mode text not null check (mode in ('throttle','overload','error','timeout','malformed')),
  rate numeric not null default 1 check (rate > 0 and rate <= 1),
  until timestamptz not null,
  set_by text not null check (set_by in ('operator','script')),
  actor_id uuid references app_private.accounts(id),
  reason text not null check (length(reason) between 3 and 500),
  cleared_at timestamptz,
  created_at timestamptz not null default now(),
  check (until <= created_at + interval '1 hour'),
  check ((set_by = 'operator') = (actor_id is not null))
);
alter table app_private.fault_injection enable row level security;
revoke all on app_private.fault_injection from public, anon, authenticated;
create index fault_injection_active on app_private.fault_injection(account_id, until) where cleared_at is null;

-- Only Auth addresses reserved for tests, on an open account. A real reader can never be the target.
create function app_private.is_test_account(p_account uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.users u join app_private.accounts a on a.id = u.id
  where u.id = p_account and a.closed_at is null and lower(u.email) ~ '@example\.(invalid|test)$')
$$;

create function app_private.fault_injection_set(p_account uuid, p_provider text, p_route text, p_mode text, p_rate numeric,
  p_minutes integer, p_reason text, p_set_by text, p_actor uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare f app_private.fault_injection;
begin
 if not app_private.is_test_account(p_account) then raise exception 'fault_target_not_test_account' using errcode = '42501'; end if;
 if p_minutes is null or p_minutes not between 1 and 60 then raise exception 'invalid_fault'; end if;
 insert into app_private.fault_injection(account_id, provider, route, mode, rate, until, set_by, actor_id, reason)
 values (p_account, p_provider, p_route, p_mode, coalesce(p_rate, 1), now() + make_interval(mins => p_minutes), p_set_by, p_actor, p_reason)
 returning * into f;
 return jsonb_build_object('id', f.id, 'until', f.until);
end $$;

-- The owner, signed in with MFA (audited in admin_audit_events too).
create function public.v1_admin_fault_injection_set(p_account uuid, p_provider text, p_route text, p_mode text, p_rate numeric,
  p_minutes integer, p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; a uuid;
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode = '42501'; end if;
 a := app_private.require_actor();
 result := app_private.fault_injection_set(p_account, p_provider, p_route, p_mode, p_rate, p_minutes, p_reason, 'operator', a);
 insert into app_private.admin_audit_events(actor_id, action, target_id, reason, details)
 values (a, 'fault_injection_set', p_account::text, p_reason, jsonb_build_object('provider', p_provider, 'route', p_route, 'mode', p_mode, 'minutes', p_minutes));
 return result;
end $$;

-- The drill script (service role, staging): the same rule, recorded in the row itself.
create function public.worker_fault_injection_set(p_account uuid, p_provider text, p_route text, p_mode text, p_rate numeric,
  p_minutes integer, p_reason text) returns jsonb
language sql security definer set search_path='' as $$
 select app_private.fault_injection_set(p_account, p_provider, p_route, p_mode, p_rate, p_minutes, p_reason, 'script', null)
$$;

create function public.worker_fault_injection_clear(p_account uuid) returns integer
language sql security definer set search_path='' as $$
 with cleared as (update app_private.fault_injection set cleared_at = now() where account_id = p_account and cleared_at is null returning 1)
 select count(*)::integer from cleared
$$;

-- What a function asks before a provider call (only where FAULT_INJECTION=on): the account's active faults, checked
-- again here against the test-account rule.
create function public.worker_fault_injection_active(p_account uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select case when not app_private.is_test_account(p_account) then '[]'::jsonb else coalesce((
  select jsonb_agg(jsonb_build_object('provider', f.provider, 'route', f.route, 'mode', f.mode, 'rate', f.rate, 'until', f.until) order by f.created_at)
  from app_private.fault_injection f where f.account_id = p_account and f.cleared_at is null and f.until > now()), '[]'::jsonb) end
$$;

-- ---------------------------------------------------------------------------
-- 3. Podcasts: a transient refusal requeues the job
-- ---------------------------------------------------------------------------
alter table app_private.podcast_jobs
 add column retry_at timestamptz,
 add column transient_retries smallint not null default 0 check (transient_retries between 0 and 10);

-- A provider answered 429 (too many requests: refused before any processing, never billed) to every refused call of
-- this job. The refused attempts are unlinked from the job (their provider_attempts rows stay, at zero cost, as the
-- record), the job parks where it can safely continue (podcast_resume_state: nothing paid is ever re-bought) and waits
-- 1, 5, 15, then 60 minutes (±20 %). An unknown outcome (a 5xx or a timeout may have been processed and billed) is not
-- requeued: re-sending could pay twice. Neither is a job whose paid work can't be kept. The caller then fails the job.
create function public.worker_podcast_requeue(p_job uuid, p_claim uuid, p_generation bigint, p_failure text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; resume text; backoff integer[] := array[60, 300, 900, 3600]; wait numeric; refused jsonb;
begin
 if p_failure is null or p_failure not in ('script_rejected', 'speech_rejected') then raise exception 'invalid_podcast_failure'; end if;
 j := app_private.podcast_fenced(p_job, p_claim, p_generation);
 if j.cancel_requested then
  j := app_private.podcast_settle(j, 'canceled', 'canceled_by_owner');
  return jsonb_build_object('requeued', false, 'state', j.state, 'canceled', true);
 end if;
 if exists(select 1 from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id = ja.attempt_id
  where ja.job_id = j.id and pa.state = 'admitted') then raise exception 'invalid_podcast_stage'; end if;
 if exists(select 1 from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id = ja.attempt_id
  where ja.job_id = j.id and pa.state = 'unknown') then return jsonb_build_object('requeued', false, 'reason', 'outcome_unknown'); end if;
 select jsonb_agg(jsonb_build_object('route', ja.route, 'ordinal', ja.ordinal, 'attempt_id', ja.attempt_id, 'failure', pa.failure_code)) into refused
  from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id = ja.attempt_id
  where ja.job_id = j.id and pa.state = 'rejected';
 if refused is null or exists(select 1 from jsonb_array_elements(refused) as r(item) where r.item->>'failure' is distinct from 'http_429') then
  return jsonb_build_object('requeued', false, 'reason', 'not_transient');
 end if;
 if j.transient_retries >= cardinality(backoff) then return jsonb_build_object('requeued', false, 'reason', 'retries_exhausted'); end if;
 begin
  delete from app_private.podcast_job_attempts ja using app_private.provider_attempts pa
   where ja.job_id = j.id and pa.id = ja.attempt_id and pa.state = 'rejected' and pa.failure_code = 'http_429';
  if not exists(select 1 from app_private.podcast_job_attempts where job_id = j.id and route = 'podcast_speech') then
   update app_private.podcast_jobs set speech_calls = null where id = j.id;
  end if;
  select * into j from app_private.podcast_jobs where id = j.id;
  resume := app_private.podcast_resume_state(j);
  if resume is null then raise exception 'podcast_not_resumable'; end if;
 exception when raise_exception then
  -- Undone (the block is a savepoint): the job fails as it did before.
  return jsonb_build_object('requeued', false, 'reason', 'not_resumable');
 end;
 perform app_private.podcast_event(j.id, 'transient_refusal', jsonb_build_object('failure', p_failure, 'attempts', refused));
 j := app_private.podcast_park(j, resume, 'provider_busy');
 wait := backoff[j.transient_retries + 1] * (0.8 + random() * 0.4);
 update app_private.podcast_jobs set retry_at = clock_timestamp() + make_interval(secs => wait), transient_retries = transient_retries + 1
  where id = j.id returning * into j;
 perform app_private.podcast_event(j.id, 'retry_scheduled', jsonb_build_object('retry_at', j.retry_at, 'retry', j.transient_retries));
 return jsonb_build_object('requeued', true, 'state', j.state, 'retry_at', j.retry_at, 'retry', j.transient_retries);
end $$;

-- As migration 066, skipping a job until its retry time.
create or replace function public.worker_podcast_claim(p_claim_id uuid,p_generated boolean default true) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.podcast_policy; candidate uuid; j app_private.podcast_jobs; spec jsonb; src app_private.podcast_sources;
 dev app_private.podcast_device_sources; t app_private.stored_objects; meta jsonb; resumed boolean; resume jsonb; source_doc uuid; norm text;
begin
 if p_claim_id is null then raise exception 'invalid_podcast_claim'; end if;
 select * into strict pol from app_private.podcast_policy where singleton;
 -- Queued work, or a staged job parked after a checkpoint (oldest first, so work in flight finishes first); a job
 -- requeued after a transient refusal waits for its retry time (migration 073).
 select x.id into candidate from app_private.podcast_jobs x where x.claim_id is null
  and (x.state='queued' or (x.state in ('checking','synthesizing') and exists(select 1 from app_private.podcast_job_checkpoints c where c.job_id=x.id)))
  and (x.retry_at is null or x.retry_at<=clock_timestamp())
  and ((x.funding_kind='customer' and pol.generation_enabled) or (x.funding_kind='platform_seed' and pol.seed_enabled) or (x.funding_kind='fixture' and pol.fixtures_enabled))
  and (x.origin='fixture' or coalesce(p_generated,false))
  order by x.created_at,x.id limit 1;
 if candidate is null then return jsonb_build_object('claimed',false); end if;
 j:=app_private.podcast_lock_job(candidate);
 if j.claim_id is not null or j.finished_at is not null or j.state not in ('queued','checking','synthesizing')
  or (j.retry_at is not null and j.retry_at>clock_timestamp()) then return jsonb_build_object('claimed',false,'more',true); end if;
 resumed:=j.state<>'queued';
 -- A scan in progress would refuse this job's uploads after its paid calls.
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton for share) then
  return jsonb_build_object('claimed',false,'reason','asset_inventory_reconciling');
 end if;
 if j.epoch<>(select epoch from app_private.podcast_policy where singleton) then
  j:=app_private.podcast_settle(j,'failed','podcast_epoch_changed'); return jsonb_build_object('claimed',false,'more',true);
 end if;
 if j.cancel_requested then j:=app_private.podcast_settle(j,'canceled','canceled_by_owner'); return jsonb_build_object('claimed',false,'more',true); end if;
 if exists(select 1 from app_private.podcast_episode_keys k where k.id=j.episode_id and k.scope='shared')
  and not app_private.podcast_rights_current(j.episode_id,j.rights_revision) then
  j:=app_private.podcast_settle(j,'failed','rights_changed'); return jsonb_build_object('claimed',false,'more',true);
 end if;
 if j.operation_id is not null and not exists(select 1 from app_private.accounts where id=j.operation_account_id and closed_at is null and not spending_suspended) then
  j:=app_private.podcast_settle(j,'failed','account_unavailable'); return jsonb_build_object('claimed',false,'more',true);
 end if;
 select * into src from app_private.podcast_sources where episode_id=j.episode_id and ordinal=0;
 if found then
  select * into t from app_private.stored_objects where id=src.text_object_id and state='verified' and sha256=src.text_sha256 and byte_count=src.text_bytes;
  source_doc:=src.document_id; norm:=src.normalization_version;
  select jsonb_build_object('title',left(cm.metadata->>'title',500),'authors',cm.metadata->'authors') into meta
   from app_private.catalog_metadata cm where cm.id=src.metadata_id;
 else
  select * into dev from app_private.podcast_device_sources where episode_id=j.episode_id;
  if not found then j:=app_private.podcast_settle(j,'failed','source_unavailable'); return jsonb_build_object('claimed',false,'more',true); end if;
  select * into t from app_private.stored_objects where id=dev.text_object_id and state='verified' and sha256=dev.text_sha256 and byte_count=dev.text_bytes;
  source_doc:=dev.membership_id; norm:=dev.normalization_version;
  meta:=jsonb_build_object('title',dev.title,'authors',dev.authors);
 end if;
 if t.id is null then j:=app_private.podcast_settle(j,'failed','source_unavailable'); return jsonb_build_object('claimed',false,'more',true); end if;
 if resumed then
  -- Only the exact stage its checkpoint covers; anything else already ended the job.
  if app_private.podcast_resume_state(j) is distinct from j.state then
   j:=app_private.podcast_settle(j,'failed','checkpoint_unavailable'); return jsonb_build_object('claimed',false,'more',true);
  end if;
  select jsonb_build_object('stage',case when j.state='checking' then 'review' else 'speech' end,'document',c.document) into strict resume
   from app_private.podcast_job_checkpoints c where c.job_id=j.id and c.stage=case when j.state='checking' then 'draft' else 'script' end;
 end if;
 update app_private.podcast_jobs set claim_id=p_claim_id,claim_generation=claim_generation+1,lease_until=clock_timestamp()+interval '15 minutes',
  state=case when resumed then j.state else 'scripting' end,stage_entered_at=clock_timestamp() where id=j.id returning * into j;
 perform app_private.podcast_event(j.id,'claimed',jsonb_build_object('claim_id',p_claim_id,'generation',j.claim_generation,'resumed',resumed));
 spec:=app_private.podcast_job_spec(j);
 return jsonb_build_object('claimed',true,'job_id',j.id,'claim_id',p_claim_id,'generation',j.claim_generation,'origin',j.origin,
  'funding_kind',j.funding_kind,'scope',(select scope from app_private.podcast_episode_keys where id=j.episode_id),
  'owner_id',(select owner_id from app_private.podcast_episode_keys where id=j.episode_id),'episode_id',j.episode_id,
  'lease_until',j.lease_until,'spec',spec,'metadata',meta,'resume',resume,
  'source',jsonb_build_object('document_id',source_doc,'bucket',t.bucket,'path',t.path,'sha256',encode(t.sha256,'hex'),'bytes',t.byte_count,
   'normalization_version',norm));
end $$;

-- As migration 048, counting only work that may be claimed now.
create or replace function public.worker_podcast_kick_due() returns jsonb
language plpgsql security definer set search_path='' as $$
declare due integer;
begin
 select count(*) into due from app_private.podcast_jobs where finished_at is null
  and ((claim_id is null and state in ('queued','checking','synthesizing') and (retry_at is null or retry_at<=clock_timestamp()))
   or (claim_id is not null and lease_until<=clock_timestamp()));
 if due>0 then perform app_private.podcast_kick(); end if;
 return jsonb_build_object('due',due);
end $$;

-- What the minute schedule asks: wake the worker only for requeued jobs whose time has come (in the last hour), so an
-- unclaimable queue (credentials missing, generation off) never keeps the worker busy.
create function public.worker_podcast_kick_retries() returns jsonb
language plpgsql security definer set search_path='' as $$
declare due integer;
begin
 select count(*) into due from app_private.podcast_jobs where finished_at is null and claim_id is null
  and state in ('queued','checking','synthesizing') and retry_at between clock_timestamp() - interval '1 hour' and clock_timestamp();
 if due > 0 then perform app_private.podcast_kick(); end if;
 return jsonb_build_object('due', due);
end $$;

do $do$
begin
 if to_regprocedure('cron.schedule(text,text,text)') is not null then
  perform cron.schedule('science-reader-podcast-retries', '* * * * *', 'select public.worker_podcast_kick_retries()');
 end if;
end $do$;

-- ---------------------------------------------------------------------------
-- 4. The owner's Health tab: provider errors and breakers; an hourly table for Reliability
-- ---------------------------------------------------------------------------
alter function public.v1_admin_health(integer) rename to admin_health_before_073;
alter function public.admin_health_before_073(integer) set schema app_private;
revoke all on function app_private.admin_health_before_073(integer) from public, anon, authenticated;

-- Failed = overloaded, server errors, timeouts and transport failures; throttled = 429s; rejected (other 4xx) and
-- failed-fast calls are counted apart.
create function public.v1_admin_health(p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare base jsonb; today date := (now() at time zone 'UTC')::date; since date;
begin
 base := app_private.admin_health_before_073(p_days);
 since := today - (p_days - 1);
 return base || jsonb_build_object('providers', jsonb_build_object(
  'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'by_provider', coalesce((
     select jsonb_object_agg(provider, jsonb_build_object('calls', calls, 'failed', failed, 'throttled', throttled, 'breaker_open', fast))
     from (select provider, sum(calls) calls,
       coalesce(sum(calls) filter (where outcome in ('overloaded','server_error','timeout','transport')), 0) failed,
       coalesce(sum(calls) filter (where outcome = 'throttled'), 0) throttled,
       coalesce(sum(calls) filter (where outcome = 'breaker_open'), 0) fast
      from app_private.provider_health_hours where (hour at time zone 'UTC')::date = d.day and route <> 'drill' group by provider) p), '{}'::jsonb)) order by d.day), '[]'::jsonb)
   from (select generate_series(since, today, interval '1 day')::date as day) d),
  'last_hour', (select coalesce(jsonb_agg(jsonb_build_object('provider', provider, 'calls', calls, 'failed', failed, 'throttled', throttled,
     'breaker_open', fast, 'latency_ms_avg', case when ok > 0 then ok_latency / ok end) order by provider), '[]'::jsonb)
   from (select provider, sum(calls) calls,
     coalesce(sum(calls) filter (where outcome in ('overloaded','server_error','timeout','transport')), 0) failed,
     coalesce(sum(calls) filter (where outcome = 'throttled'), 0) throttled,
     coalesce(sum(calls) filter (where outcome = 'breaker_open'), 0) fast,
     coalesce(sum(calls) filter (where outcome = 'ok'), 0) ok,
     coalesce(sum(latency_ms_total) filter (where outcome = 'ok'), 0) ok_latency
    from app_private.provider_health_hours where hour >= date_trunc('hour', now()) - interval '1 hour' and route <> 'drill' group by provider) x),
  'breakers', (select coalesce(jsonb_agg(app_private.provider_breaker_view(b) order by b.provider), '[]'::jsonb)
   from app_private.provider_breakers b where b.state <> 'closed')));
end $$;
revoke all on function public.v1_admin_health(integer) from public, anon;
grant execute on function public.v1_admin_health(integer) to authenticated;

create function public.v1_admin_provider_hours(p_hours integer default 48) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode = '42501'; end if;
 if p_hours is null or p_hours not between 1 and 168 then raise exception 'invalid_metrics_window'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('hour', hour, 'provider', provider, 'calls', calls, 'ok', ok, 'throttled', throttled,
   'failed', failed, 'rejected', rejected, 'breaker_open', fast, 'latency_ms_avg', case when ok > 0 then ok_latency / ok end,
   'latency_ms_max', latency_max, 'retry_after_max_s', retry_max) order by hour desc, provider), '[]'::jsonb)
  from (select hour, provider, sum(calls) calls,
    coalesce(sum(calls) filter (where outcome = 'ok'), 0) ok,
    coalesce(sum(calls) filter (where outcome = 'throttled'), 0) throttled,
    coalesce(sum(calls) filter (where outcome in ('overloaded','server_error','timeout','transport')), 0) failed,
    coalesce(sum(calls) filter (where outcome = 'rejected'), 0) rejected,
    coalesce(sum(calls) filter (where outcome = 'breaker_open'), 0) fast,
    coalesce(sum(latency_ms_total) filter (where outcome = 'ok'), 0) ok_latency,
    max(latency_ms_max) latency_max, max(retry_after_max_s) retry_max
   from app_private.provider_health_hours where hour >= date_trunc('hour', now()) - make_interval(hours => p_hours - 1) and route <> 'drill'
   group by hour, provider) x);
end $$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function app_private.provider_breaker_view(app_private.provider_breakers) from public, anon, authenticated;
revoke all on function app_private.is_test_account(uuid) from public, anon, authenticated;
revoke all on function app_private.fault_injection_set(uuid,text,text,text,numeric,integer,text,text,uuid) from public, anon, authenticated;
revoke all on function public.worker_provider_health(text,text,text,integer,integer,boolean) from public, anon, authenticated;
revoke all on function public.worker_provider_health_recent(integer) from public, anon, authenticated;
revoke all on function public.worker_provider_breakers() from public, anon, authenticated;
revoke all on function public.worker_fault_injection_set(uuid,text,text,text,numeric,integer,text) from public, anon, authenticated;
revoke all on function public.worker_fault_injection_clear(uuid) from public, anon, authenticated;
revoke all on function public.worker_fault_injection_active(uuid) from public, anon, authenticated;
revoke all on function public.worker_podcast_requeue(uuid,uuid,bigint,text) from public, anon, authenticated;
revoke all on function public.worker_podcast_kick_retries() from public, anon, authenticated;
grant execute on function public.worker_provider_health(text,text,text,integer,integer,boolean) to service_role;
grant execute on function public.worker_provider_health_recent(integer) to service_role;
grant execute on function public.worker_provider_breakers() to service_role;
grant execute on function public.worker_fault_injection_set(uuid,text,text,text,numeric,integer,text) to service_role;
grant execute on function public.worker_fault_injection_clear(uuid) to service_role;
grant execute on function public.worker_fault_injection_active(uuid) to service_role;
grant execute on function public.worker_podcast_requeue(uuid,uuid,bigint,text) to service_role;
grant execute on function public.worker_podcast_kick_retries() to service_role;
revoke all on function public.v1_admin_fault_injection_set(uuid,text,text,text,numeric,integer,text) from public, anon;
grant execute on function public.v1_admin_fault_injection_set(uuid,text,text,text,numeric,integer,text) to authenticated;
revoke all on function public.v1_admin_provider_hours(integer) from public, anon;
grant execute on function public.v1_admin_provider_hours(integer) to authenticated;
notify pgrst, 'reload schema';
commit;
