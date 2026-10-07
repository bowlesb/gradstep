-- Bounded, content-free diagnostics for authenticated store-sync attempts.
-- Does not grant credits or change the financial transaction ledger.
-- Requires the complete ordered migration prefix; see PURCHASES.md.
begin;
set local lock_timeout='15s';

create table app_private.store_verification_policy (
 singleton boolean primary key default true check(singleton),
 retention_days integer not null check(retention_days between 1 and 30),
 account_rows integer not null check(account_rows between 1 and 2048),
 environment_rows integer not null check(environment_rows between 1 and 50000)
);
insert into app_private.store_verification_policy values(true,30,2048,50000);
alter table app_private.store_verification_policy enable row level security;
insert into app_private.api_rate_rules values('store-verification',3600,50,1000);

create table app_private.store_verification_observations (
 id uuid primary key,
 account_id uuid not null references app_private.accounts(id),
 submission_sha256 bytea not null check(octet_length(submission_sha256)=32),
 admitted_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null,
 finished_at timestamptz,
 outcome text not null default 'started' check(outcome in ('started','recorded','updated','already_recorded',
  'linked_to_another_account','account_closed','unknown_product','unsupported','unattributed',
  'invalid','environment_unavailable','verification_unavailable','recording_unavailable')),
 stage text check(stage in ('input','environment','certificate_chain','revocation','signature_or_payload',
  'application','transaction_fields','recording','admission','deferred')),
 apple_status text check(apple_status in ('verification_failure','retryable_verification_failure','invalid_app_identifier',
  'invalid_environment','invalid_chain_length','invalid_certificate','failure')),
 transport_code text check(transport_code in ('timeout','dns','connection','tls','network','runtime','other')),
 check((outcome='started')=(finished_at is null)),
 check(expires_at>admitted_at and expires_at<=admitted_at+interval '30 days'),
 check(finished_at is null or finished_at>=admitted_at)
);
alter table app_private.store_verification_observations enable row level security;
create index store_verification_account on app_private.store_verification_observations(account_id,submission_sha256,admitted_at desc,id desc);
create index store_verification_expiry on app_private.store_verification_observations(expires_at,id);

-- Caller holds the policy lock. Cleanup never locks accounts. Account closure
-- deletes observations without taking the policy lock, so it cannot deadlock
-- against admission's account -> policy order.
create function app_private.prune_store_verifications(p_limit integer) returns integer
language plpgsql security definer set search_path='' as $$
declare removed integer;
begin
 if p_limit is null or p_limit not between 1 and 50000 then raise exception 'invalid_limit'; end if;
 with expired as (
  select id from app_private.store_verification_observations where expires_at<=clock_timestamp()
  order by expires_at,id limit p_limit for update skip locked
 ) delete from app_private.store_verification_observations o using expired e where o.id=e.id;
 get diagnostics removed=row_count;
 return removed;
end $$;

create function public.worker_prune_store_verifications(p_limit integer default 50000) returns integer
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from app_private.store_verification_policy where singleton for update;
 return app_private.prune_store_verifications(p_limit);
end $$;

create function app_private.delete_account_store_verifications() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.closed_at is not null then
  delete from app_private.store_verification_observations where account_id=new.id;
 end if;
 return new;
end $$;
create trigger account_delete_store_verifications after update of closed_at on app_private.accounts
 for each row when (new.closed_at is not null) execute function app_private.delete_account_store_verifications();

create function public.worker_store_verification_begin(p_account_id uuid,p_attempt_id uuid,p_submission_sha256 bytea)
returns jsonb language plpgsql security definer set search_path='' as $$
declare policy app_private.store_verification_policy; prior app_private.store_verification_observations; stamp timestamptz;
begin
 if p_account_id is null or p_attempt_id is null or p_submission_sha256 is null or octet_length(p_submission_sha256)<>32 then
  raise exception 'invalid_store_observation';
 end if;
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null for update;
 if not found then return jsonb_build_object('granted',false,'reason','account_unavailable'); end if;
 select * into policy from app_private.store_verification_policy where singleton for update;
 select * into prior from app_private.store_verification_observations where id=p_attempt_id;
 if found then
  if prior.account_id<>p_account_id or prior.submission_sha256<>p_submission_sha256 then raise exception 'store_observation_conflict'; end if;
  return jsonb_build_object('granted',false,'reason','attempt_replayed');
 end if;
 perform app_private.prune_store_verifications(500);
 if (select count(*) from app_private.store_verification_observations)>=policy.environment_rows
  or (select count(*) from app_private.store_verification_observations where account_id=p_account_id)>=policy.account_rows then
  return jsonb_build_object('granted',false,'reason','observation_capacity');
 end if;
 begin
  perform public.worker_consume_request(p_account_id,'store-verification');
 exception when raise_exception then
  if sqlerrm='request_rate_limit' then return jsonb_build_object('granted',false,'reason','verification_rate'); end if;
  raise;
 end;
 stamp:=clock_timestamp();
 insert into app_private.store_verification_observations(id,account_id,submission_sha256,admitted_at,expires_at)
 values(p_attempt_id,p_account_id,p_submission_sha256,stamp,stamp+make_interval(days=>policy.retention_days));
 return jsonb_build_object('granted',true);
end $$;

create function public.worker_store_verification_finish(p_account_id uuid,p_attempt_id uuid,p_outcome text,p_stage text default null,
 p_apple_status text default null,p_transport_code text default null) returns void
language plpgsql security definer set search_path='' as $$
declare prior app_private.store_verification_observations;
begin
 if p_account_id is null or p_attempt_id is null or p_outcome is null or p_outcome='started' then raise exception 'invalid_store_observation'; end if;
 select * into prior from app_private.store_verification_observations where id=p_attempt_id and account_id=p_account_id for update;
 if not found then
  -- Closure/retention can remove a diagnostic while verification is in flight.
  -- This never turns its eventual transaction outcome into a second grant.
  if exists(select 1 from app_private.accounts where id=p_account_id and closed_at is not null) then return; end if;
  raise exception 'store_observation_unavailable';
 end if;
 if prior.outcome<>'started' then
  if prior.outcome is distinct from p_outcome or prior.stage is distinct from p_stage
   or prior.apple_status is distinct from p_apple_status or prior.transport_code is distinct from p_transport_code then
   raise exception 'store_observation_conflict';
  end if;
  return;
 end if;
 update app_private.store_verification_observations set outcome=p_outcome,stage=p_stage,apple_status=p_apple_status,
  transport_code=p_transport_code,finished_at=clock_timestamp() where id=p_attempt_id;
end $$;

-- Local fixtures do not provide pg_cron. Hosted absence is exposed by readiness
-- and must fail the purchase deployment gate, rather than silently pretending a
-- retention schedule exists. This job runs SQL only; it wakes no external worker.
do $$ begin
 if to_regprocedure('cron.schedule(text,text,text)') is not null then
  execute $q$select cron.schedule('science-reader-purchase-observations','17 * * * *',
   'select public.worker_prune_store_verifications(50000)')$q$;
 end if;
end $$;

create function public.worker_store_verification_readiness() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare cleanup jsonb;
begin
 if to_regclass('cron.job') is not null then
  execute $q$select jsonb_build_object('active',active,'schedule',schedule,
   'expected_command',command='select public.worker_prune_store_verifications(50000)')
   from cron.job where jobname='science-reader-purchase-observations'$q$ into cleanup;
 end if;
 return jsonb_build_object('cleanup',coalesce(cleanup,jsonb_build_object('active',false,'schedule',null,'expected_command',false)),
  'retained',(select count(*) from app_private.store_verification_observations),
  'policy',(select to_jsonb(p)-'singleton' from app_private.store_verification_policy p where singleton));
end $$;

create function public.v1_admin_store_verifications(p_filter text default 'unconfirmed',p_reference text default null,p_limit integer default 100)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_filter is null or p_filter not in ('unconfirmed','refused','confirmed','all') or p_limit is null or p_limit not between 1 and 200
  or (p_reference is not null and p_reference !~ '^[0-9a-f]{12,64}$') then raise exception 'invalid_store_observation_query'; end if;
 with retained as (
  select * from app_private.store_verification_observations
  where expires_at>now() and (p_reference is null or encode(submission_sha256,'hex') like p_reference||'%')
 ), grouped as (
  select account_id,submission_sha256,count(*) as attempts,min(admitted_at) as first_at,
   bool_or(outcome in ('recorded','updated','already_recorded')) as confirmed from retained group by account_id,submission_sha256
 ), latest as (
  select distinct on (o.account_id,o.submission_sha256) o.*,g.attempts,g.first_at,
   case when g.confirmed then 'confirmed'
    when o.outcome='started' and o.admitted_at<now()-interval '10 minutes' then 'interrupted'
    when o.outcome='started' then 'verifying'
    when o.outcome in ('verification_unavailable','recording_unavailable') then 'pending'
    else 'refused' end as state
  from retained o join grouped g using(account_id,submission_sha256)
  order by o.account_id,o.submission_sha256,o.admitted_at desc,o.id desc
 ), matched as (
  select * from latest where p_filter='all' or state=p_filter
   or (p_filter='unconfirmed' and state in ('verifying','interrupted','pending'))
 ), page as (select * from matched order by admitted_at desc,id desc limit p_limit)
 select jsonb_build_object('generated_at',now(),'matched',(select count(*) from matched),
  'counts',(select coalesce(jsonb_object_agg(state,n),'{}'::jsonb) from (select state,count(*) n from latest group by state) s),
  'readiness',public.worker_store_verification_readiness(),
  'submissions',coalesce(jsonb_agg(jsonb_build_object('account_id',p.account_id,'reference',encode(p.submission_sha256,'hex'),
   'first_at',p.first_at,'last_at',p.admitted_at,'finished_at',p.finished_at,'attempts',p.attempts,'state',p.state,
   'outcome',p.outcome,'stage',p.stage,'apple_status',p.apple_status,'transport_code',p.transport_code)
   order by p.admitted_at desc,p.id desc),'[]'::jsonb)) into result from page p;
 return result;
end $$;

create function public.v1_admin_store_verification_attempts(p_account_id uuid,p_reference text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_account_id is null or p_reference is null or p_reference !~ '^[0-9a-f]{64}$' then raise exception 'invalid_store_observation_query'; end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.admitted_at desc,o.id desc),'[]'::jsonb) into result from (
  select id,admitted_at,finished_at,outcome,stage,apple_status,transport_code from app_private.store_verification_observations
  where account_id=p_account_id and submission_sha256=decode(p_reference,'hex') and expires_at>now()
  order by admitted_at desc,id desc limit 50
 ) o;
 return result;
end $$;

revoke all on function app_private.prune_store_verifications(integer) from public,anon,authenticated;
revoke all on function app_private.delete_account_store_verifications() from public,anon,authenticated;
revoke all on function public.worker_prune_store_verifications(integer) from public,anon,authenticated;
revoke all on function public.worker_store_verification_begin(uuid,uuid,bytea) from public,anon,authenticated;
revoke all on function public.worker_store_verification_finish(uuid,uuid,text,text,text,text) from public,anon,authenticated;
revoke all on function public.worker_store_verification_readiness() from public,anon,authenticated;
grant execute on function public.worker_prune_store_verifications(integer) to service_role;
grant execute on function public.worker_store_verification_begin(uuid,uuid,bytea) to service_role;
grant execute on function public.worker_store_verification_finish(uuid,uuid,text,text,text,text) to service_role;
grant execute on function public.worker_store_verification_readiness() to service_role;
revoke all on function public.v1_admin_store_verifications(text,text,integer) from public,anon;
revoke all on function public.v1_admin_store_verification_attempts(uuid,text) from public,anon;
grant execute on function public.v1_admin_store_verifications(text,text,integer) to authenticated;
grant execute on function public.v1_admin_store_verification_attempts(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
