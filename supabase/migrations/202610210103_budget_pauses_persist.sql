-- 0103: A pause holds across the month boundary, and test accounts cannot trip the pause for everyone (review A7,
-- 2026-10-21; design: docs/architecture/SPENDING_CONTROLS.md "Pauses across months").
-- Before: migration 060 creates next month's budget row on the first daily run of a month, copying the switch at that
-- moment; an owner's pause (v1_admin_pause_work) and the overrun tripwire changed only one month, so a pause on the 20th
-- was silently lifted at 00:00 UTC on the 1st. The tripwire also counted anomalies of test accounts (drills, fixtures),
-- so more than 5 drill overruns in an hour paused AI for every reader.
-- Now: pausing or resuming applies to the current month and every month already created after it (and a month created
-- later copies it, as before); the tripwire pauses the current and later months whatever the overrunning operation's own
-- month was; test-account anomalies are recorded and shown but never count toward the tripwire. No limit changes.
begin;
set local lock_timeout='15s';

-- As migration 079, without test accounts.
create or replace function app_private.anomalies_toward_tripwire() returns integer
language sql stable security definer set search_path='' as $$
 select count(distinct (b.account_id, b.operation_id))::integer from app_private.budget_anomalies b
 cross join app_private.paid_work_guard g
 where g.singleton and not b.test_account and b.created_at > greatest(now() - make_interval(mins => g.overrun_window_minutes),
  coalesce((select max(p.created_at) from app_private.budget_anomalies p where p.paused_month), '-infinity'::timestamptz))
$$;

-- As migration 079; the tripwire pauses this month and every later month already created.
create or replace function app_private.record_budget_anomaly(p_period date, p_account_id uuid, p_operation_id uuid, p_attempt_id uuid,
  p_kind text, p_ceiling bigint, p_observed bigint) returns void
language plpgsql security definer set search_path='' as $$
declare g app_private.paid_work_guard; new_id uuid; test boolean:=app_private.is_test_account(p_account_id);
begin
 update app_private.budget_anomalies set observed_microusd=greatest(observed_microusd, coalesce(p_observed, 0))
  where account_id=p_account_id and operation_id=p_operation_id and kind=p_kind and attempt_id is not distinct from p_attempt_id;
 if found then return; end if;
 insert into app_private.budget_anomalies(period, account_id, operation_id, attempt_id, kind, ceiling_microusd, observed_microusd, test_account)
 values (p_period, p_account_id, p_operation_id, p_attempt_id, p_kind, greatest(coalesce(p_ceiling, 0), 0), greatest(coalesce(p_observed, 0), 0), test)
 returning id into new_id;
 if test then return; end if;
 select * into strict g from app_private.paid_work_guard where singleton;
 if app_private.anomalies_toward_tripwire() > g.overrun_pause_after then
  update app_private.platform_budgets set work_enabled=false
   where period>=least(p_period,date_trunc('month',now() at time zone 'UTC')::date) and work_enabled;
  if found then update app_private.budget_anomalies set paused_month=true where id=new_id; end if;
 end if;
end $$;

-- As migration 004; the switch applies to this month and every later month already created.
create or replace function public.v1_admin_pause_work(p_paused boolean,p_reason text) returns void language plpgsql security definer set search_path = '' as $$
declare this_month date:=date_trunc('month',now() at time zone 'UTC')::date; periods text[];
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_paused is null then raise exception 'invalid_pause'; end if;
 if not exists(select 1 from app_private.platform_budgets where period=this_month) then raise exception 'budget_not_configured'; end if;
 with changed as (update app_private.platform_budgets set work_enabled=not p_paused where period>=this_month returning period)
 select array_agg(period::text order by period) into periods from changed;
 insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
 values(app_private.actor(),'set_work_paused',this_month::text,p_reason,jsonb_build_object('paused',p_paused,'periods',to_jsonb(periods)));
end $$;

notify pgrst,'reload schema';
commit;
