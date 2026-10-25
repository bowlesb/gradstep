-- 0159: The account-deletion sweep can list unfinished deletions again, and says when it cannot (2026-10-25;
-- docs/architecture/PRIVACY_AND_SYNC.md "The sweep lists in milliseconds and reports each listing").
--
-- Since 2026-10-12 14:01 UTC (intermittently since 2026-10-09 14:03) every call the worker made to
-- worker_account_deletions_pending was cancelled by the gateway's 8 s statement timeout (SQLSTATE 57014, HTTP 500), so
-- the sweep finished nothing. Cause: the wrappers of migrations 032 and 095 test `a.id=any(<earlier function>(20))`
-- inside their scan of every account, and PostgreSQL evaluates a function there once per row (a security-definer SQL
-- function is never inlined or hoisted). Migration 032 made the listing quadratic in accounts, 095 cubic: on staging
-- (883 accounts, 832 closed by the synthetic accounts of tests and checks) one call of 017's function took 200 ms, 032's
-- layer about 3 minutes (883 x 200 ms) and the whole listing about two days. Each lookup of an account's files scanned all of
-- stored_objects (no index on owner_id or document_id), which grows with every closed account.
--
-- Same lists, same order, same deletion steps; additive:
--  1. 032's and 095's wrappers read the list below them once per call (an initplan) instead of once per account row,
--     and 128's reads it once instead of twice (its `unnest` was also evaluated while planning);
--  2. indexes for the per-account lookups of the deletion predicate (stored_objects by owner and by document,
--     documents by owner, support_reports by account);
--  3. account_deletion_objects returns exactly the same rows as two index-backed arms (owned objects, then objects of
--     the account's private documents that are not also owned by it) instead of one scan with an OR;
--  4. the worker reports each listing (worker_account_deletion_sweep_report): when it last succeeded, consecutive
--     failures and their code, how long it took. account_deletion_health (Health) and the service-role
--     worker_account_deletion_health (the workflow check deletion.sweep) add it, and count unfinished deletions closed
--     more than an hour ago that the sweep has never tried. Counts, times and codes only.
begin;
set local lock_timeout='15s';

-- 1. Hoisted wrappers (bodies otherwise as in 032 and 095).
create or replace function app_private.account_deletions_pending_before_095(p_limit integer default 5) returns uuid[]
language sql stable security definer set search_path='' as $$
 select coalesce(array_agg(id order by closed_at,id),'{}') from (
  select a.id,a.closed_at from app_private.accounts a
  where a.id=any((select app_private.worker_account_deletions_pending(20))::uuid[])
   or (a.closed_at is not null and a.closed_at>now()-interval '30 days'
    and (exists(select 1 from app_private.library_v4_entries e where e.account_id=a.id)
     or exists(select 1 from app_private.library_query_entries q where q.account_id=a.id)))
  order by a.closed_at,a.id limit greatest(1,least(p_limit,20))
 ) pending
$$;
create or replace function app_private.account_deletions_pending_before_128(p_limit integer default 5) returns uuid[]
language sql stable security definer set search_path='' as $$
 select coalesce(array_agg(id order by closed_at,id),'{}') from (
  select a.id,a.closed_at from app_private.accounts a
  where a.id=any((select app_private.account_deletions_pending_before_095(20))::uuid[])
   or (a.closed_at is not null and a.closed_at>now()-interval '30 days'
    and exists(select 1 from app_private.note_assets n where n.account_id=a.id))
  order by a.closed_at,a.id limit greatest(1,least(p_limit,20))
 ) pending
$$;
-- 128's function, same list and order. Its `unnest(<earlier list>)` was evaluated twice per call, once while planning.
create or replace function public.worker_account_deletions_pending(p_limit integer default 5) returns uuid[]
language sql stable security definer set search_path='' as $$
 with due as (
  select a.id,a.closed_at,s.last_attempt_at from app_private.accounts a
  left join app_private.account_deletion_sweeps s on s.account_id=a.id
  where a.closed_at is not null and (s.next_attempt_at is null or s.next_attempt_at<=now())
   and (a.id=any((select app_private.account_deletions_pending_before_128(20))::uuid[]) or app_private.account_deletion_unfinished(a.id))
  order by s.last_attempt_at nulls first,a.closed_at,a.id
  limit greatest(1,least(coalesce(p_limit,5),20)))
 select coalesce(array_agg(id order by last_attempt_at nulls first,closed_at,id),'{}') from due
$$;

-- 2. Lookups by account. stored_objects holds either an owner or a document (its check), so both are partial.
create index if not exists stored_objects_owner on app_private.stored_objects(owner_id) where owner_id is not null;
create index if not exists stored_objects_document on app_private.stored_objects(document_id) where document_id is not null;
create index if not exists documents_owner on app_private.documents(owner_id) where owner_id is not null;
create index if not exists support_reports_account on app_private.support_reports(account_id);

-- 3. The same rows as 017's `owner_id=a or document_id in (the account's documents)`, each once.
create or replace function app_private.account_deletion_objects(a uuid) returns setof app_private.stored_objects
language sql stable security definer set search_path='' as $$
 select o.* from app_private.stored_objects o where o.owner_id=a
 union all
 select o.* from app_private.stored_objects o
 where o.document_id in (select d.id from app_private.documents d where d.owner_id=a) and o.owner_id is distinct from a
$$;

-- 4. The sweep's listing: one row, codes and times only.
create table app_private.account_deletion_sweep_runs (
 singleton boolean primary key default true check(singleton),
 last_ok_at timestamptz,
 last_failed_at timestamptz,
 failures_in_row integer not null default 0 check(failures_in_row between 0 and 1000000000),
 last_code text check(last_code is null or last_code ~ '^([0-9A-Z]{5}|list_failed)$'),
 last_listed integer check(last_listed between 0 and 20),
 last_ms integer check(last_ms between 0 and 86400000)
);
insert into app_private.account_deletion_sweep_runs(singleton) values(true);
alter table app_private.account_deletion_sweep_runs enable row level security;
revoke all on app_private.account_deletion_sweep_runs from public,anon,authenticated,service_role;

create function public.worker_account_deletion_sweep_report(p_ok boolean,p_listed integer default null,p_ms integer default null,p_code text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.account_deletion_sweep_runs;
begin
 if p_ok is null or (p_ok and (p_code is not null or p_listed is null)) or (not p_ok and (p_code is null or p_listed is not null))
  or (p_code is not null and p_code !~ '^([0-9A-Z]{5}|list_failed)$') or (p_listed is not null and p_listed not between 0 and 20)
  or (p_ms is not null and p_ms not between 0 and 86400000) then raise exception 'invalid_sweep_report'; end if;
 update app_private.account_deletion_sweep_runs set
  last_ok_at=case when p_ok then now() else last_ok_at end,
  last_failed_at=case when p_ok then last_failed_at else now() end,
  failures_in_row=case when p_ok then 0 else least(failures_in_row+1,1000000000) end,
  last_code=case when p_ok then last_code else p_code end,
  last_listed=case when p_ok then p_listed else last_listed end,
  last_ms=p_ms
 where singleton returning * into strict r;
 return jsonb_build_object('failures_in_row',r.failures_in_row);
end $$;

-- Health (migration 128's counts, unchanged) plus the listing and the deletions the sweep has never reached.
create or replace function app_private.account_deletion_health() returns jsonb
language sql stable security definer set search_path='' as $$
 with u as (select a.id,a.closed_at,s.attempts,s.last_code from app_private.accounts a
   left join app_private.account_deletion_sweeps s on s.account_id=a.id
   where a.closed_at is not null and app_private.account_deletion_unfinished(a.id))
 select jsonb_build_object('unfinished',(select count(*) from u),
  'retrying',(select count(*) from u where coalesce(attempts,0)>0),
  'stalled',(select count(*) from u where closed_at<now()-interval '30 days'),
  'oldest_closed_at',(select min(closed_at) from u),
  'top_code',(select last_code from u where last_code is not null group by last_code order by count(*) desc,last_code limit 1),
  'untried_over_1h',(select count(*) from u where attempts is null and closed_at<now()-interval '1 hour'),
  'sweep',(select jsonb_build_object('last_ok_at',last_ok_at,'last_failed_at',last_failed_at,'failures_in_row',failures_in_row,
    'last_code',last_code,'last_ms',last_ms) from app_private.account_deletion_sweep_runs where singleton))
$$;
create function public.worker_account_deletion_health() returns jsonb
language sql stable security definer set search_path='' as $$ select app_private.account_deletion_health() $$;

revoke all on function public.worker_account_deletion_sweep_report(boolean,integer,integer,text),public.worker_account_deletion_health()
 from public,anon,authenticated,service_role;
grant execute on function public.worker_account_deletion_sweep_report(boolean,integer,integer,text),public.worker_account_deletion_health() to service_role;
-- The replaced functions keep their owners and grants (create or replace).
notify pgrst,'reload schema';
commit;
