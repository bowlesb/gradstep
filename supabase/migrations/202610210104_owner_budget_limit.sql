-- 0104: The operator's budget command is owner-attributed, audited, UTC, carries to later months and never touches the
-- pause switch (review A11, 2026-10-21; design: docs/architecture/SPENDING_CONTROLS.md "Operator budget command").
-- Before: scripts/pipeline-ops.py budget called worker_set_platform_budget (no actor, no audit row) with p_enabled from a
-- flag, so changing a limit silently resumed a tripwire-paused month; the Mac's local date chose the month; next month
-- kept the old limit. No limit is changed by this migration; the schema ceiling ($50 a month, migration 068) is unchanged.
begin;
set local lock_timeout='15s';

create function public.worker_owner_set_budget_limit(p_actor_id uuid,p_request_id uuid,p_limit_microusd bigint,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare this_month date:=date_trunc('month',now() at time zone 'UTC')::date; prior app_private.admin_audit_events; before bigint; periods text[];
begin
 perform app_private.require_owner_account(p_actor_id);
 if p_request_id is null or p_limit_microusd is null or p_limit_microusd<0 or p_reason is null or length(btrim(p_reason)) not between 3 and 500
 then raise exception 'invalid_budget'; end if;
 select * into prior from app_private.admin_audit_events where id=p_request_id;
 if found then
  if prior.action<>'platform_budget_limit' or prior.actor_id<>p_actor_id or (prior.details->>'limit_microusd')::bigint<>p_limit_microusd
  then raise exception 'request_id_conflict'; end if;
  return jsonb_build_object('replayed',true,'limit_microusd',p_limit_microusd,'periods',prior.details->'periods');
 end if;
 select limit_microusd into before from app_private.platform_budgets where period=this_month for update;
 if not found then raise exception 'budget_not_configured'; end if;
 -- The pause switch is never changed here (an owner resumes on the admin site); the schema ceiling still applies.
 with changed as (update app_private.platform_budgets set limit_microusd=p_limit_microusd where period>=this_month returning period)
 select array_agg(period::text order by period) into periods from changed;
 insert into app_private.admin_audit_events(id,actor_id,action,target_id,reason,details)
 values(p_request_id,p_actor_id,'platform_budget_limit',this_month::text,btrim(p_reason),
  jsonb_build_object('limit_microusd',p_limit_microusd,'before_microusd',before,'periods',to_jsonb(periods)));
 return jsonb_build_object('replayed',false,'limit_microusd',p_limit_microusd,'before_microusd',before,'periods',to_jsonb(periods));
end $$;
revoke all on function public.worker_owner_set_budget_limit(uuid,uuid,bigint,text) from public,anon,authenticated;
grant execute on function public.worker_owner_set_budget_limit(uuid,uuid,bigint,text) to service_role;

-- The unaudited setter keeps its service grant (fixtures and provisioning set budgets with it); no operator tool
-- uses it any more (scripts/pipeline-ops.py budget calls the function above).

notify pgrst,'reload schema';
commit;
