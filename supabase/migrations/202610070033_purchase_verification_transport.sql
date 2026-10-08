-- Independent of pending provider/upload changes (034+). An admitted start
-- permits exactly one private verifier request; it never grants app credits.
-- The initial channels are disabled. Operator CAS changes only their enabled
-- state, never a limit or usage counter. See PURCHASE_VERIFICATION_RUNTIME.md.
begin;
set local lock_timeout='15s';

create table app_private.store_verifier_policy (
 channel text primary key check(channel in ('app','notification')),
 policy_id text not null default 'app-store-sandbox-v1' check(policy_id='app-store-sandbox-v1'),
 enabled boolean not null default false,
 revision bigint not null default 1 check(revision between 1 and 2147483647),
 account_hour_limit integer,
 hour_limit integer not null,
 day_limit integer not null,
 month_limit integer not null,
 retained_limit integer not null,
 clock_floor timestamptz not null default clock_timestamp(),
 check((channel='app' and account_hour_limit is not null and account_hour_limit=50 and hour_limit=500 and day_limit=300 and month_limit=3000 and retained_limit=12000)
    or (channel='notification' and account_hour_limit is null and hour_limit=60 and day_limit=200 and month_limit=1000 and retained_limit=4000))
);
insert into app_private.store_verifier_policy(channel,account_hour_limit,hour_limit,day_limit,month_limit,retained_limit)
 values('app',50,500,300,3000,12000),('notification',null,60,200,1000,4000);
alter table app_private.store_verifier_policy enable row level security;

create table app_private.store_verifier_windows (
 channel text not null references app_private.store_verifier_policy(channel),
 unit text not null check(unit in ('hour','day','month')),
 period timestamptz not null,
 starts integer not null default 0 check(starts between 0 and 3000),
 denied bigint not null default 0 check(denied between 0 and 9007199254740991),
 primary key(channel,unit,period),
 check(period=date_trunc(unit,period at time zone 'UTC') at time zone 'UTC')
);
alter table app_private.store_verifier_windows enable row level security;

create table app_private.store_verifier_account_hours (
 account_id uuid not null references app_private.accounts(id),
 period timestamptz not null,
 starts integer not null check(starts between 1 and 50),
 primary key(account_id,period),
 check(period=date_trunc('hour',period at time zone 'UTC') at time zone 'UTC')
);
alter table app_private.store_verifier_account_hours enable row level security;
create index store_verifier_account_expiry on app_private.store_verifier_account_hours(period);

create table app_private.store_verifier_starts (
 id uuid primary key,
 channel text not null references app_private.store_verifier_policy(channel),
 account_id uuid references app_private.accounts(id),
 policy_id text not null check(policy_id='app-store-sandbox-v1'),
 payload_bytes integer not null check(payload_bytes between 20 and 64000),
 started_at timestamptz not null,
 expires_at timestamptz not null,
 outcome text not null default 'started' check(outcome in ('started','verified','invalid','environment_unavailable','verification_unavailable')),
 finished_at timestamptz,
 duration_ms integer check(duration_ms between 0 and 120000),
 check((channel='app')=(account_id is not null)),
 check(expires_at=started_at+interval '840 hours'),
 check((outcome='started')=(finished_at is null)),
 check((finished_at is null)=(duration_ms is null))
);
alter table app_private.store_verifier_starts enable row level security;
create index store_verifier_start_expiry on app_private.store_verifier_starts(channel,expires_at,id);
create index store_verifier_start_account on app_private.store_verifier_starts(account_id) where account_id is not null;

-- Timestamp comes from the UUID itself, never an independent field that could
-- refresh an old ID after pruning. PostgreSQL 17 has no native UUIDv7 parser.
create function app_private.store_verifier_attempt_time(p_attempt_id uuid) returns timestamptz
language plpgsql immutable set search_path='' as $$
declare value text:=p_attempt_id::text;
begin
 if value is null or value !~ '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
  raise exception 'invalid_store_verifier_attempt';
 end if;
 return to_timestamp((('x'||left(replace(value,'-',''),12))::bit(48)::bigint)::numeric/1000);
end $$;

-- Caller already holds the channel policy lock. Never acquires an account or
-- another channel lock, including when invoked by scheduled maintenance.
create function app_private.prune_store_verifier_channel(p_channel text,p_stamp timestamptz,p_limit integer) returns integer
language plpgsql security definer set search_path='' as $$
declare removed integer;
begin
 with expired as (
  select id from app_private.store_verifier_starts where channel=p_channel and expires_at<=p_stamp
  order by expires_at,id limit p_limit for update skip locked
 ) delete from app_private.store_verifier_starts s using expired e where s.id=e.id;
 get diagnostics removed=row_count;
 delete from app_private.store_verifier_windows where channel=p_channel and
  ((unit='hour' and period<p_stamp-interval '48 hours')
   or (unit='day' and period<(date_trunc('day',p_stamp at time zone 'UTC')-interval '90 days') at time zone 'UTC')
   or (unit='month' and period<(date_trunc('month',p_stamp at time zone 'UTC')-interval '2 months') at time zone 'UTC'));
 if p_channel='app' then
  delete from app_private.store_verifier_account_hours where period<p_stamp-interval '48 hours';
 end if;
 return removed;
end $$;

create function public.worker_start_store_verifier(p_channel text,p_account_id uuid,p_attempt_id uuid,p_payload_bytes integer,p_policy_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare policy app_private.store_verifier_policy; born timestamptz; stamp timestamptz; unit text; boundary timestamptz;
 reason text; inserted integer; account_used integer; windows jsonb:='{}';
begin
 if p_channel is null or p_channel not in ('app','notification') or (p_channel='app')<>(p_account_id is not null)
  or p_payload_bytes is null or p_payload_bytes not between 20 and 64000
  or p_policy_id is distinct from 'app-store-sandbox-v1' then raise exception 'invalid_store_verifier_request'; end if;
 born:=app_private.store_verifier_attempt_time(p_attempt_id);
 -- Lock order: real account -> channel policy -> attempts/windows. In
 -- particular, notification admission never locks a claimed Apple account.
 if p_channel='app' then
  perform 1 from app_private.accounts where id=p_account_id and closed_at is null for update;
  if not found then return jsonb_build_object('granted',false,'reason','account_unavailable'); end if;
 end if;
 select * into strict policy from app_private.store_verifier_policy where channel=p_channel for update;
 stamp:=clock_timestamp();
 -- A backwards wall clock must not reopen a pruned window or old attempt.
 if stamp<policy.clock_floor then return jsonb_build_object('granted',false,'reason','clock_unavailable'); end if;
 update app_private.store_verifier_policy set clock_floor=stamp where channel=p_channel;
 perform app_private.prune_store_verifier_channel(p_channel,stamp,1000);
 foreach unit in array array['hour','day','month'] loop
  boundary:=date_trunc(unit,stamp at time zone 'UTC') at time zone 'UTC';
  windows:=windows||jsonb_build_object(unit,boundary);
  insert into app_private.store_verifier_windows(channel,unit,period) values(p_channel,unit,boundary) on conflict do nothing;
 end loop;
 if born<stamp-interval '120 seconds' or born>stamp+interval '30 seconds' then reason:='attempt_expired';
 elsif exists(select 1 from app_private.store_verifier_starts where id=p_attempt_id) then reason:='attempt_replayed';
 elsif not policy.enabled then reason:='disabled';
 elsif (select count(*) from app_private.store_verifier_starts where channel=p_channel)>=policy.retained_limit then reason:='retention_capacity';
 elsif exists(select 1 from app_private.store_verifier_windows w where w.channel=p_channel and w.period=(windows->>w.unit)::timestamptz
  and w.starts>=case w.unit when 'hour' then policy.hour_limit when 'day' then policy.day_limit else policy.month_limit end) then reason:='channel_limit';
 elsif p_channel='app' then
  select starts into account_used from app_private.store_verifier_account_hours where account_id=p_account_id and period=(windows->>'hour')::timestamptz;
  if coalesce(account_used,0)>=policy.account_hour_limit then reason:='account_limit'; end if;
 end if;
 if reason is null then
  insert into app_private.store_verifier_starts(id,channel,account_id,policy_id,payload_bytes,started_at,expires_at)
   values(p_attempt_id,p_channel,p_account_id,policy.policy_id,p_payload_bytes,stamp,stamp+interval '840 hours') on conflict do nothing;
  get diagnostics inserted=row_count;
  -- Concurrent reuse across different channels/accounts must not mint a
  -- second send grant. No quota has been incremented yet.
  if inserted=0 then reason:='attempt_replayed'; end if;
 end if;
 if reason is not null then
  update app_private.store_verifier_windows w set denied=least(denied+1,9007199254740991)
   where w.channel=p_channel and w.period=(windows->>w.unit)::timestamptz;
  return jsonb_build_object('granted',false,'reason',reason);
 end if;
 update app_private.store_verifier_windows w set starts=starts+1
  where w.channel=p_channel and w.period=(windows->>w.unit)::timestamptz;
 if p_channel='app' then
  insert into app_private.store_verifier_account_hours(account_id,period,starts) values(p_account_id,(windows->>'hour')::timestamptz,1)
   on conflict(account_id,period) do update set starts=app_private.store_verifier_account_hours.starts+1;
 end if;
 return jsonb_build_object('granted',true,'attempt_id',p_attempt_id,'policy_id',policy.policy_id);
end $$;

-- Observations never release capacity or authorize another send. Missing or
-- late diagnostics cannot turn a verified financial result into a failed one.
create function public.worker_finish_store_verifier(p_attempt_id uuid,p_outcome text,p_duration_ms integer) returns boolean
language plpgsql security definer set search_path='' as $$
declare prior app_private.store_verifier_starts;
begin
 if p_attempt_id is null or p_outcome is null or p_outcome not in ('verified','invalid','environment_unavailable','verification_unavailable')
  or p_duration_ms is null or p_duration_ms not between 0 and 120000 then raise exception 'invalid_store_verifier_observation'; end if;
 select * into prior from app_private.store_verifier_starts where id=p_attempt_id for update;
 if not found then return false; end if;
 if prior.outcome<>'started' then
  if prior.outcome<>p_outcome or prior.duration_ms<>p_duration_ms then raise exception 'store_verifier_observation_conflict'; end if;
  return true;
 end if;
 update app_private.store_verifier_starts set outcome=p_outcome,duration_ms=p_duration_ms,finished_at=clock_timestamp() where id=p_attempt_id;
 return true;
end $$;

create function public.worker_set_store_verifier_enabled(p_channel text,p_expected_revision bigint,p_enabled boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare policy app_private.store_verifier_policy;
begin
 if p_channel is null or p_channel not in ('app','notification') or p_expected_revision is null or p_enabled is null then
  raise exception 'invalid_store_verifier_policy'; end if;
 select * into strict policy from app_private.store_verifier_policy where channel=p_channel for update;
 if policy.revision<>p_expected_revision then raise exception 'store_verifier_policy_conflict'; end if;
 if policy.enabled<>p_enabled then
  update app_private.store_verifier_policy set enabled=p_enabled,revision=revision+1 where channel=p_channel returning * into policy;
 end if;
 return jsonb_build_object('channel',policy.channel,'policy_id',policy.policy_id,'enabled',policy.enabled,'revision',policy.revision);
end $$;

create function public.worker_store_verifier_readiness() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('version',1,'migration','202610070033_purchase_verification_transport','policy_id','app-store-sandbox-v1',
  'channels',(select jsonb_agg(jsonb_build_object('channel',p.channel,'enabled',p.enabled,'revision',p.revision,
   'limits',jsonb_build_object('account_hour',p.account_hour_limit,'hour',p.hour_limit,'day',p.day_limit,'month',p.month_limit),
   'usage',(select jsonb_object_agg(u.unit,jsonb_build_object('period',u.period,'starts',coalesce(w.starts,0),'denied',coalesce(w.denied,0)))
    from (select unit,date_trunc(unit,greatest(now(),p.clock_floor) at time zone 'UTC') at time zone 'UTC' period
     from unnest(array['hour','day','month']) unit) u
    left join app_private.store_verifier_windows w on w.channel=p.channel and w.unit=u.unit and w.period=u.period)
   ) order by p.channel) from app_private.store_verifier_policy p));
$$;

create function public.worker_prune_store_verifier() returns integer
language plpgsql security definer set search_path='' as $$
declare policy app_private.store_verifier_policy; stamp timestamptz; removed integer:=0;
begin
 for policy in select * from app_private.store_verifier_policy order by channel for update loop
  stamp:=clock_timestamp();
  if stamp>=policy.clock_floor then
   update app_private.store_verifier_policy set clock_floor=stamp where channel=policy.channel;
   removed:=removed+app_private.prune_store_verifier_channel(policy.channel,stamp,16000);
  end if;
 end loop;
 return removed;
end $$;

create function public.v1_admin_store_verifier_usage() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 return public.worker_store_verifier_readiness()||jsonb_build_object('generated_at',now(),
  'windows',coalesce((select jsonb_agg(to_jsonb(w) order by w.channel,w.unit,w.period) from app_private.store_verifier_windows w
   where (unit='day' and period>=now()-interval '90 days') or unit='month'),'[]'::jsonb),
  'retained_observations',coalesce((select jsonb_agg(to_jsonb(g) order by channel,outcome) from
   (select channel,outcome,count(*) as attempts,coalesce(sum(duration_ms),0) as observed_duration_ms
    from app_private.store_verifier_starts where expires_at>now() group by channel,outcome) g),'[]'::jsonb));
end $$;

-- Admission also performs bounded cleanup; missed cron does not create an
-- unbounded table. It eventually fails closed at the retained row ceiling.
do $$ begin
 if to_regprocedure('cron.schedule(text,text,text)') is not null then
  execute $q$select cron.schedule('science-reader-store-verifier','23 * * * *','select public.worker_prune_store_verifier()')$q$;
 end if;
end $$;

revoke all on function app_private.store_verifier_attempt_time(uuid) from public,anon,authenticated;
revoke all on function app_private.prune_store_verifier_channel(text,timestamptz,integer) from public,anon,authenticated;
revoke all on function public.worker_start_store_verifier(text,uuid,uuid,integer,text) from public,anon,authenticated;
revoke all on function public.worker_finish_store_verifier(uuid,text,integer) from public,anon,authenticated;
revoke all on function public.worker_set_store_verifier_enabled(text,bigint,boolean) from public,anon,authenticated;
revoke all on function public.worker_store_verifier_readiness() from public,anon,authenticated;
revoke all on function public.worker_prune_store_verifier() from public,anon,authenticated;
grant execute on function public.worker_start_store_verifier(text,uuid,uuid,integer,text) to service_role;
grant execute on function public.worker_finish_store_verifier(uuid,text,integer) to service_role;
grant execute on function public.worker_set_store_verifier_enabled(text,bigint,boolean) to service_role;
grant execute on function public.worker_store_verifier_readiness() to service_role;
grant execute on function public.worker_prune_store_verifier() to service_role;
revoke all on function public.v1_admin_store_verifier_usage() from public,anon,service_role;
grant execute on function public.v1_admin_store_verifier_usage() to authenticated;
notify pgrst,'reload schema';
commit;
