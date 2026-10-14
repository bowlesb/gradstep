-- Audit follow-ups (docs/reviews/COST_CREDITS_AND_SYNC_AUDIT_20261014.md). Additive and reversible; no row is deleted.
begin;
set local lock_timeout='15s';

-- 1. An older reader meeting a newer encrypted event (format 2) is told to update through a code every shipped
--    build already renders as "Update the app to sync this history", instead of one it shows as "try again".
create or replace function public.v2_pull_events(p_after bigint,p_limit integer default 200) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=public.v3_pull_events(p_after,p_limit);
 if exists(select 1 from jsonb_array_elements(result->'events') e where (e->>'format')::integer<>1)
 then raise exception 'sync_page_too_large'; end if;
 return result;
end $$;

-- 2. A chat hold whose invocation died is released without booking its whole ceiling as platform spend: the
--    attempts carry any real provider liability (migration 034); nothing else is known to have been spent.
create or replace function public.worker_expire_stale_chat_operations(p_older_than_minutes integer default 30) returns integer
language plpgsql security definer set search_path='' as $$
declare op record; n integer:=0;
begin
 if p_older_than_minutes is null or p_older_than_minutes<10 then raise exception 'invalid_age'; end if;
 for op in select account_id,id from app_private.metered_operations
  where kind='chat' and state<>'settled' and created_at<now()-make_interval(mins=>p_older_than_minutes)
  order by created_at limit 50 loop
  begin
   perform public.worker_settle_operation(op.account_id,op.id,0,0);
   n:=n+1;
  exception when others then null;
  end;
 end loop;
 return n;
end $$;

-- 3. Budget periods are never missing: this month's row (from the latest earlier one) and next month's (from this
--    month's) are created with the same limit and the same work switch. The limit is never raised here; only
--    scripts/pipeline-ops.py budget changes it, by the owner.
create function public.worker_ensure_platform_budget() returns jsonb language plpgsql security definer set search_path='' as $$
declare this_month date:=date_trunc('month',now() at time zone 'UTC')::date; next_month date:=(this_month+interval '1 month')::date; created text[]:='{}';
begin
 if not exists(select 1 from app_private.platform_budgets where period=this_month) then
  insert into app_private.platform_budgets(period,limit_microusd,work_enabled)
   select this_month,limit_microusd,work_enabled from app_private.platform_budgets where period<this_month order by period desc limit 1;
  if found then created:=created||this_month::text; end if;
 end if;
 if not exists(select 1 from app_private.platform_budgets where period=next_month) then
  insert into app_private.platform_budgets(period,limit_microusd,work_enabled)
   select next_month,limit_microusd,work_enabled from app_private.platform_budgets where period=this_month;
  if found then created:=created||next_month::text; end if;
 end if;
 return jsonb_build_object('created',to_jsonb(created));
end $$;

-- 4. One readback for the scheduled workflow check (alerts by email): the period, what is spent and reserved, the
--    work switch, attempts left unknown for over an hour, holds open for over an hour, and whether next month exists.
create function public.worker_budget_health() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce((select jsonb_build_object('period',b.period,'limit_microusd',b.limit_microusd,'spent_microusd',b.spent_microusd,
   'reserved_microusd',b.reserved_microusd,'work_enabled',b.work_enabled,
   'next_period_exists',exists(select 1 from app_private.platform_budgets n where n.period=(b.period+interval '1 month')::date),
   'unknown_attempts_over_1h',(select count(*) from app_private.provider_attempts a where a.state='unknown' and a.created_at<now()-interval '1 hour'),
   'open_operations_over_1h',(select count(*) from app_private.metered_operations o where o.state<>'settled' and o.created_at<now()-interval '1 hour'))
  from app_private.platform_budgets b where b.period=date_trunc('month',now() at time zone 'UTC')::date),
  jsonb_build_object('period',null,'missing',true))
$$;

revoke all on function public.worker_ensure_platform_budget(),public.worker_budget_health() from public,anon,authenticated,service_role;
grant execute on function public.worker_ensure_platform_budget(),public.worker_budget_health() to service_role;

do $cron$
begin
 if to_regprocedure('cron.schedule(text,text,text)') is not null then
  execute $q$select cron.schedule('science-reader-budget-period','7 3 * * *','select public.worker_ensure_platform_budget()')$q$;
 end if;
end $cron$;
select public.worker_ensure_platform_budget();
notify pgrst,'reload schema';
commit;
