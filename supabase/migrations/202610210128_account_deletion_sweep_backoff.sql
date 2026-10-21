-- 128: The account-deletion sweep retries with back-off and reports a stall (review A22, 2026-10-21;
-- docs/architecture/PRIVACY_AND_SYNC.md "The sweep retries with back-off"). The sweep took the oldest pending accounts by
-- closed_at on every run, so an account that cannot finish (more than 20,000 objects, an unresolved uncertain write)
-- held a slot forever and starved the rest; and worker_account_deletions_pending stopped listing an account 30 days
-- after it closed, silently, with personal rows or files left. Additive:
--  1. app_private.account_deletion_sweeps: attempts, last attempt and outcome, and the next allowed attempt per account;
--  2. worker_account_deletion_attempt: the sweep's report of each outcome (back-off 5 min x 2^attempts, at most a day);
--  3. app_private.account_deletion_unfinished: one predicate for "still holds personal rows, a login or files";
--  4. worker_account_deletions_pending (wrapping 095's): unfinished closed accounts past their back-off, never-tried
--     first, then the least recently tried; no 30-day cut-off; the earlier function's own list is kept as an input;
--  5. v1_admin_health.account_deletions: unfinished / retrying / stalled (over 30 days) counts for Health > Attention.
begin;
set local lock_timeout='15s';

-- 1. One row per closed account the sweep has tried and not finished. Codes and times only.
create table app_private.account_deletion_sweeps (
 account_id uuid primary key references app_private.accounts(id),
 attempts integer not null default 0 check(attempts between 0 and 1000000),
 last_attempt_at timestamptz,
 next_attempt_at timestamptz,
 last_step text check(last_step is null or last_step in ('begin','files','finish','login')),
 last_code text check(last_code is null or last_code in ('deletion_scan_incomplete','deletion_unverified','asset_write_uncertain','account_busy','begin_failed'))
);
create index account_deletion_sweeps_next on app_private.account_deletion_sweeps(next_attempt_at);
alter table app_private.account_deletion_sweeps enable row level security;
revoke all on app_private.account_deletion_sweeps from public,anon,authenticated,service_role;

-- 3. Unfinished: the conditions of migrations 017, 032 and 095 (note images) and the device-source records of 125.
-- Add new ones here.
create function app_private.account_deletion_unfinished(a uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.accounts x where x.id=a and x.auth_user_id is not null)
  or exists(select 1 from app_private.keyrings k where k.account_id=a)
  or exists(select 1 from app_private.library_items l where l.account_id=a)
  or exists(select 1 from app_private.import_requests i where i.account_id=a)
  or exists(select 1 from app_private.support_reports r where r.account_id=a)
  or exists(select 1 from app_private.library_v4_entries e where e.account_id=a)
  or exists(select 1 from app_private.library_query_entries q where q.account_id=a)
  or exists(select 1 from app_private.podcast_device_sources d where d.owner_id=a)
  or exists(select 1 from app_private.note_assets n where n.account_id=a)
  or exists(select 1 from app_private.account_deletion_objects(a) o where o.state in ('pending','verified','deleting'))
$$;

-- 2. The sweep's report. A completed deletion clears the row; a failure backs off.
create function public.worker_account_deletion_attempt(p_account_id uuid,p_complete boolean,p_step text default null,p_code text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s app_private.account_deletion_sweeps;
begin
 if p_account_id is null or p_complete is null or (p_step is not null and p_step not in ('begin','files','finish','login'))
  or (p_code is not null and p_code not in ('deletion_scan_incomplete','deletion_unverified','asset_write_uncertain','account_busy','begin_failed'))
  or (p_complete and (p_step is not null or p_code is not null)) then raise exception 'invalid_deletion_attempt'; end if;
 if not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is not null) then raise exception 'account_not_closed'; end if;
 if p_complete then
  delete from app_private.account_deletion_sweeps where account_id=p_account_id;
  return jsonb_build_object('complete',true);
 end if;
 insert into app_private.account_deletion_sweeps(account_id) values(p_account_id) on conflict do nothing;
 update app_private.account_deletion_sweeps set attempts=attempts+1,last_attempt_at=now(),
  next_attempt_at=now()+least(interval '24 hours',interval '5 minutes'*power(2,least(attempts,9))),last_step=p_step,last_code=p_code
  where account_id=p_account_id returning * into s;
 return jsonb_build_object('complete',false,'attempts',s.attempts,'next_attempt_at',s.next_attempt_at);
end $$;

-- 4. What the sweep takes next.
alter function public.worker_account_deletions_pending(integer) rename to account_deletions_pending_before_128;
alter function public.account_deletions_pending_before_128(integer) set schema app_private;
create function public.worker_account_deletions_pending(p_limit integer default 5) returns uuid[]
language sql stable security definer set search_path='' as $$
 with earlier as (select unnest(app_private.account_deletions_pending_before_128(20)) id),
 due as (
  select a.id,a.closed_at,s.last_attempt_at from app_private.accounts a
  left join app_private.account_deletion_sweeps s on s.account_id=a.id
  where a.closed_at is not null and (s.next_attempt_at is null or s.next_attempt_at<=now())
   and (a.id in (select id from earlier) or app_private.account_deletion_unfinished(a.id))
  order by s.last_attempt_at nulls first,a.closed_at,a.id
  limit greatest(1,least(coalesce(p_limit,5),20)))
 select coalesce(array_agg(id order by last_attempt_at nulls first,closed_at,id),'{}') from due
$$;

-- 5. The owner's Health: unfinished deletions, the ones being retried, and the stalled ones (over 30 days).
create function app_private.account_deletion_health() returns jsonb
language sql stable security definer set search_path='' as $$
 with u as (select a.id,a.closed_at,s.attempts,s.last_code from app_private.accounts a
   left join app_private.account_deletion_sweeps s on s.account_id=a.id
   where a.closed_at is not null and app_private.account_deletion_unfinished(a.id))
 select jsonb_build_object('unfinished',(select count(*) from u),
  'retrying',(select count(*) from u where coalesce(attempts,0)>0),
  'stalled',(select count(*) from u where closed_at<now()-interval '30 days'),
  'oldest_closed_at',(select min(closed_at) from u),
  'top_code',(select last_code from u where last_code is not null group by last_code order by count(*) desc,last_code limit 1))
$$;
alter function public.v1_admin_health(integer) rename to admin_health_before_128;
alter function public.admin_health_before_128(integer) set schema app_private;
revoke all on function app_private.admin_health_before_128(integer) from public,anon,authenticated;
create function public.v1_admin_health(p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 -- The earlier function checks the owner with MFA and the window before anything is read.
 return app_private.admin_health_before_128(p_days)||jsonb_build_object('account_deletions',app_private.account_deletion_health());
end $$;
revoke all on function public.v1_admin_health(integer) from public,anon;
grant execute on function public.v1_admin_health(integer) to authenticated;

revoke all on function app_private.account_deletion_unfinished(uuid),app_private.account_deletion_health(),
 app_private.account_deletions_pending_before_128(integer) from public,anon,authenticated,service_role;
revoke all on function public.worker_account_deletion_attempt(uuid,boolean,text,text),public.worker_account_deletions_pending(integer)
 from public,anon,authenticated,service_role;
grant execute on function public.worker_account_deletion_attempt(uuid,boolean,text,text),public.worker_account_deletions_pending(integer) to service_role;
notify pgrst,'reload schema';
commit;
