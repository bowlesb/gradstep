-- Service health for the owner (docs/architecture/ADMIN_HEALTH.md): a daily rollup of which accounts used the service,
-- fed by the request limiter, and one owner-only read of aggregates for the admin's Health tab. Read-only towards
-- every existing table; the only new data is account_activity_days (an account id, a UTC day, route names).
begin;

create table app_private.account_activity_days (
  day date not null,
  account_id uuid not null,
  routes text[] not null default '{}',
  primary key (day, account_id)
);
alter table app_private.account_activity_days enable row level security;
revoke all on app_private.account_activity_days from public, anon, authenticated;
create index account_activity_days_account on app_private.account_activity_days (account_id);

-- One row per account per UTC day it used the service, with its routes. A row that already lists the route is not
-- rewritten; rows older than 400 days go once a day. Never fails the request it observes.
create function app_private.record_account_activity() returns trigger language plpgsql security definer set search_path='' as $$
declare d date; a uuid;
begin
 begin
  if new.scope_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return null; end if;
  a := new.scope_id::uuid; d := (new.window_start at time zone 'UTC')::date;
  if not exists (select 1 from app_private.accounts where id=a and closed_at is null) then return null; end if;
  insert into app_private.account_activity_days(day, account_id, routes) values (d, a, array[left(new.route, 64)])
  on conflict (day, account_id) do update set routes = app_private.account_activity_days.routes || excluded.routes
   where not (app_private.account_activity_days.routes @> excluded.routes) and cardinality(app_private.account_activity_days.routes) < 32;
  if not exists (select 1 from app_private.account_activity_days where day = d and account_id <> a) then
   delete from app_private.account_activity_days where day < d - 400;
  end if;
 exception when others then return null;
 end;
 return null;
end $$;
revoke all on function app_private.record_account_activity() from public, anon, authenticated;
create trigger api_rate_windows_activity after insert or update on app_private.api_rate_windows
 for each row execute function app_private.record_account_activity();

-- A closed account leaves no activity behind (account deletion closes it first).
create function app_private.forget_account_activity() returns trigger language plpgsql security definer set search_path='' as $$
begin
 delete from app_private.account_activity_days where account_id = new.id;
 return null;
end $$;
revoke all on function app_private.forget_account_activity() from public, anon, authenticated;
create trigger accounts_forget_activity after update of closed_at on app_private.accounts
 for each row when (new.closed_at is not null and old.closed_at is null) execute function app_private.forget_account_activity();

-- Backfill from what is already stored: the limiter's windows, synced events, paid operations and paper adds.
insert into app_private.account_activity_days(day, account_id, routes)
select day, account_id, array_agg(distinct route order by route) from (
  select (w.window_start at time zone 'UTC')::date as day, w.scope_id::uuid account_id, w.route from app_private.api_rate_windows w
   where w.scope_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  union all select (e.committed_at at time zone 'UTC')::date, e.account_id, 'sync-write' from app_private.sync_events e
  union all select (m.created_at at time zone 'UTC')::date, m.account_id, m.kind from app_private.metered_operations m
  union all select (r.created_at at time zone 'UTC')::date, r.account_id, 'import' from app_private.import_requests r
) x where exists (select 1 from app_private.accounts a where a.id = x.account_id and a.closed_at is null)
group by day, account_id
on conflict do nothing;

-- The owner's Health tab: daily series over the window (UTC days, zero-filled) and the window's headlines. Test
-- accounts (Auth addresses @example.invalid, @example.test) are left out of people and use; spending is everything.
create function public.v1_admin_health(p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare today date := (now() at time zone 'UTC')::date; since date; month_start date := date_trunc('month', now() at time zone 'UTC')::date;
 result jsonb;
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_days is null or p_days not between 1 and 180 then raise exception 'invalid_metrics_window'; end if;
 since := today - (p_days - 1);
 with real as (
   select a.id, (a.created_at at time zone 'UTC')::date created from app_private.accounts a join auth.users u on u.id = a.auth_user_id
   where a.closed_at is null and not (lower(coalesce(u.email, '')) like '%@example.invalid' or lower(coalesce(u.email, '')) like '%@example.test')),
 days as (select d::date as day from generate_series(since::timestamp, today::timestamp, interval '1 day') d),
 activity as (select ad.day, ad.account_id, ad.routes from app_private.account_activity_days ad join real r on r.id = ad.account_id
   where ad.day >= least(since, today - 29) - 6),
 imports as (select (i.created_at at time zone 'UTC')::date as day, i.phase, i.error_code from app_private.import_requests i join real r on r.id = i.account_id
   where i.created_at >= since),
 chats as (select (m.created_at at time zone 'UTC')::date as day, m.account_id, m.state from app_private.metered_operations m join real r on r.id = m.account_id
   where m.kind = 'chat' and m.created_at >= since),
 podcasts as (select (j.created_at at time zone 'UTC')::date as day, j.state, j.failure_code, j.origin from app_private.podcast_jobs j
   where j.created_at >= since and (j.operation_account_id is null or exists (select 1 from real r where r.id = j.operation_account_id))),
 usage as (select (e.created_at at time zone 'UTC')::date as day, e.provider, e.estimated_microusd, e.units from app_private.provider_usage_events e
   where e.created_at >= least(since, month_start)),
 credits as (select (l.created_at at time zone 'UTC')::date as day, l.kind, l.balance_delta from app_private.credit_ledger l join real r on r.id = l.account_id
   where l.created_at >= since)
 select jsonb_build_object(
  'generated_at', now(), 'since', since, 'today', today, 'days', p_days, 'month_start', month_start,
  'people', jsonb_build_object(
    'accounts', (select count(*) from real),
    'new_in_window', (select count(*) from real where created >= since),
    'active_7d', (select count(distinct account_id) from activity where day > today - 7),
    'active_30d', (select count(distinct account_id) from activity where day > today - 30),
    'returning_7d', (select count(distinct a.account_id) from activity a join real r on r.id = a.account_id where a.day > today - 7 and r.created <= today - 7),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day,
       'new', (select count(*) from real where created = d.day),
       'active', (select count(distinct account_id) from activity where day = d.day),
       'active_7d', (select count(distinct account_id) from activity where day between d.day - 6 and d.day)) order by d.day), '[]') from days d)),
  'use', jsonb_build_object(
    'papers_added', (select count(*) from imports),
    'chat_answers', (select count(*) from chats),
    'chatting_accounts', (select count(distinct account_id) from chats),
    'podcasts_started', (select count(*) from podcasts),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day,
       'papers', (select count(*) from imports where day = d.day),
       'chats', (select count(*) from chats where day = d.day),
       'chatting', (select count(distinct account_id) from chats where day = d.day),
       'podcasts', (select count(*) from podcasts where day = d.day)) order by d.day), '[]') from days d)),
  'reliability', jsonb_build_object(
    'papers_failed', (select count(*) from imports where phase in ('failed', 'membership_conflict')),
    'paper_failure_codes', (select coalesce(jsonb_object_agg(code, n), '{}') from (select coalesce(error_code, 'unknown') code, count(*) n from imports
       where phase in ('failed', 'membership_conflict') group by 1 order by 2 desc limit 8) f),
    'chats_unsettled', (select count(*) from chats where state <> 'settled'),
    'podcasts_ready', (select count(*) from podcasts where state = 'ready'),
    'podcasts_failed', (select count(*) from podcasts where state = 'failed'),
    'podcast_failure_codes', (select coalesce(jsonb_object_agg(code, n), '{}') from (select coalesce(failure_code, 'unknown') code, count(*) n from podcasts
       where state = 'failed' group by 1 order by 2 desc limit 8) f),
    'reports_open', (select count(*) from app_private.support_reports where status not in ('verified', 'closed')),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day,
       'papers_failed', (select count(*) from imports where day = d.day and phase in ('failed', 'membership_conflict')),
       'podcasts_failed', (select count(*) from podcasts where day = d.day and state = 'failed'),
       'reports', (select count(*) from app_private.support_reports s where (s.created_at at time zone 'UTC')::date = d.day)) order by d.day), '[]') from days d)),
  'money', jsonb_build_object(
    'month_to_date_microusd', (select coalesce(sum(estimated_microusd), 0) from usage where day >= month_start),
    'window_microusd', (select coalesce(sum(estimated_microusd), 0) from usage where day >= since),
    'by_provider', (select coalesce(jsonb_object_agg(provider, n), '{}') from (select provider, sum(estimated_microusd) n from usage where day >= since group by 1) p),
    'credits_consumed', (select coalesce(-sum(balance_delta), 0) from credits where kind = 'settle'),
    'credits_granted', (select coalesce(sum(balance_delta), 0) from credits where kind = 'grant'),
    'chat_cache', (select jsonb_build_object(
       'read_tokens', coalesce(sum((units->>'cache_read_tokens')::bigint), 0),
       'write_tokens', coalesce(sum(coalesce((units->>'cache_write_5m_tokens')::bigint, 0) + coalesce((units->>'cache_write_1h_tokens')::bigint, 0)), 0),
       'input_tokens', coalesce(sum((units->>'input_tokens')::bigint), 0))
       from usage where provider = 'anthropic' and day >= since and units ? 'cache_read_tokens'),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day,
       'microusd', (select coalesce(sum(estimated_microusd), 0) from usage where day = d.day),
       'by_provider', (select coalesce(jsonb_object_agg(provider, n), '{}') from (select provider, sum(estimated_microusd) n from usage where day = d.day group by 1) p),
       'credits_consumed', (select coalesce(-sum(balance_delta), 0) from credits where day = d.day and kind = 'settle')) order by d.day), '[]') from days d))
 ) into result;
 return result;
end $$;
revoke all on function public.v1_admin_health(integer) from public, anon;
grant execute on function public.v1_admin_health(integer) to authenticated;
notify pgrst, 'reload schema';
commit;
