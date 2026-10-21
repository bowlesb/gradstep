-- 0102: Unresolved OpenRouter attempts are reconciled automatically from OpenRouter's generation records (review A6,
-- 2026-10-21; design: docs/architecture/PROVIDER_SPENDING.md "Automatic reconciliation").
-- Before: every Stop, mid-stream 5xx, timeout or dropped stream left its attempt `unknown` with the whole ceiling reserved
-- against the month until an owner ran scripts/pipeline-ops.py reconcile by hand; an outage or many Stops could reach
-- platform_budget_exhausted and pause AI for everyone. DECISIONS.md (2026-10-18) requires actual-cost reconciliation.
-- Now: the pipeline worker (every minute) claims a bounded batch of dispatched OpenRouter attempts that carry a
-- generation id and are past their in-flight time, reads each generation's record (a GET; it cannot buy anything), and
-- reconciles the attempt at the record's cost with the same evidence trail as an owner's reconciliation (actor: none;
-- evidence `openrouter-generation:<id>`). Each attempt is tried at most 12 times with back-off (5 minutes doubling to a
-- day); one that cannot be resolved this way (no generation id, no record, a mismatch) stays reserved and is named on
-- Health and in the budget check. Nothing is released without a record.
begin;
set local lock_timeout='15s';

create table app_private.openrouter_reconcile_queue (
 attempt_id uuid primary key references app_private.provider_attempts(id),
 tries smallint not null check(tries between 0 and 100),
 next_at timestamptz not null,
 last_outcome text not null check(last_outcome in ('claimed','reconciled','resolved','not_found','mismatch','no_key')),
 updated_at timestamptz not null default now()
);
create index openrouter_reconcile_due on app_private.openrouter_reconcile_queue(next_at) where last_outcome<>'reconciled';
alter table app_private.openrouter_reconcile_queue enable row level security;
revoke all on app_private.openrouter_reconcile_queue from public,anon,authenticated;

-- What the reconciler may try: dispatched OpenRouter attempts with a generation id, unknown (or admitted and abandoned
-- for an hour), older than two minutes (never one still streaming), at most 30 days old, not given up.
create function app_private.openrouter_reconcilable(p_provider text,p_dispatched_at timestamptz,p_request_id text,p_state text,p_created_at timestamptz) returns boolean
language sql stable security definer set search_path='' as $$
 select p_provider='openrouter' and p_dispatched_at is not null and p_request_id is not null
  and (p_state='unknown' or (p_state='admitted' and p_created_at<now()-interval '1 hour'))
  and p_created_at<now()-interval '2 minutes' and p_created_at>now()-interval '30 days'
$$;

create function public.worker_openrouter_reconcile_claim(p_limit integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare items jsonb;
begin
 if p_limit is null or p_limit not between 1 and 50 then raise exception 'invalid_limit'; end if;
 with due as (
  select a.id,a.account_id,a.operation_id,a.provider_request_id,a.transport_metadata from app_private.provider_attempts a
  left join app_private.openrouter_reconcile_queue q on q.attempt_id=a.id
  where a.state in ('unknown','admitted') and app_private.openrouter_reconcilable(a.provider,a.dispatched_at,a.provider_request_id,a.state,a.created_at)
   and (q.attempt_id is null or (q.next_at<=now() and q.tries<12 and q.last_outcome<>'reconciled'))
  order by coalesce(q.next_at,a.created_at),a.id limit p_limit),
 queued as (
  insert into app_private.openrouter_reconcile_queue as q(attempt_id,tries,next_at,last_outcome,updated_at)
  select id,1,now()+interval '5 minutes','claimed',now() from due
  on conflict(attempt_id) do update set tries=q.tries+1,next_at=now()+least(interval '24 hours',interval '5 minutes'*power(2,q.tries)),
   last_outcome='claimed',updated_at=now()
  returning attempt_id)
 select coalesce(jsonb_agg(jsonb_build_object('attempt_id',d.id,'account_id',d.account_id,'operation_id',d.operation_id,
  'generation_id',d.provider_request_id,'transport_model',d.transport_metadata->>'transport_model','feature',d.transport_metadata->>'feature')
  order by d.id),'[]'::jsonb) into items from due d where d.id in (select attempt_id from queued);
 return items;
end $$;

-- An attempt the reconciler could not resolve this time (the record is missing, does not match, or no key reads it).
create function public.worker_openrouter_reconcile_miss(p_attempt_id uuid,p_outcome text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_outcome is null or p_outcome not in ('not_found','mismatch','no_key') then raise exception 'invalid_reconciliation'; end if;
 update app_private.openrouter_reconcile_queue set last_outcome=p_outcome,updated_at=now() where attempt_id=p_attempt_id;
end $$;

-- Reconciles one attempt at its generation record's cost: the receipt (the same checks as the chat function's), the
-- attempt (provider_attempt_apply: the held ceiling is released and the cost recorded, an overrun recorded as an
-- anomaly), an adjustment and an event as an owner's reconciliation writes them, with no actor.
create function public.worker_openrouter_reconcile(p_attempt_id uuid,p_generation_id text,p_receipt jsonb,p_actual_microusd bigint,p_units jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a app_private.provider_attempts; op app_private.metered_operations; released bigint; usage_id uuid; adjustment uuid:=gen_random_uuid();
 evidence text;
begin
 if p_attempt_id is null or p_generation_id is null or p_actual_microusd is null or p_actual_microusd not between 0 and 30000000
  or not app_private.valid_provider_units(p_units) or p_receipt is null or jsonb_typeof(p_receipt)<>'object'
  or p_receipt->>'generation_id' is distinct from p_generation_id
  or jsonb_typeof(p_receipt->'total_cost_microusd') is distinct from 'number' or (p_receipt->>'total_cost_microusd')::numeric<>p_actual_microusd
 then raise exception 'invalid_reconciliation'; end if;
 select * into a from app_private.provider_attempts where id=p_attempt_id;
 if not found then raise exception 'invalid_reconciliation'; end if;
 op:=app_private.provider_lock_operation(a.account_id,a.operation_id);
 select * into strict a from app_private.provider_attempts where id=p_attempt_id for update;
 if a.provider<>'openrouter' or a.dispatched_at is null or a.provider_request_id is distinct from p_generation_id then raise exception 'invalid_reconciliation'; end if;
 if a.state not in ('unknown','admitted') then
  update app_private.openrouter_reconcile_queue set last_outcome='resolved',updated_at=now() where attempt_id=a.id and last_outcome<>'reconciled';
  return jsonb_build_object('reconciled',false,'state',a.state);
 end if;
 -- The receipt: generation, provider and model checked as at dispatch (receipt_model_mismatch on another model).
 perform public.worker_openrouter_receipt(a.account_id,a.operation_id,a.id,p_receipt);
 released:=a.ceiling_microusd;
 evidence:='openrouter-generation:'||left(p_generation_id,230);
 select id into usage_id from app_private.provider_usage_events where provider=a.provider and provider_event_id='attempt:'||a.id;
 perform app_private.provider_attempt_apply(a.id,'reconciled',null,p_actual_microusd,p_units,null);
 insert into app_private.provider_attempt_adjustments(id,attempt_id,actor_id,before_microusd,after_microusd,released_liability_microusd,units,evidence_reference,reason)
 values(adjustment,a.id,null,coalesce(a.actual_microusd,0),p_actual_microusd,released,p_units,evidence,'Automatic: OpenRouter generation record');
 if usage_id is not null then
  insert into app_private.provider_reconciliations(usage_event_id,invoice_reference,adjustment_microusd)
  values(usage_id,'attempt-adjustment:'||adjustment,p_actual_microusd-coalesce(a.actual_microusd,0));
 end if;
 insert into app_private.provider_attempt_events(attempt_id,state,details) values(a.id,'reconciled',jsonb_build_object('adjustment_id',adjustment,
  'automatic',true,'actual_microusd',p_actual_microusd,'units',p_units,'evidence_reference',evidence));
 update app_private.openrouter_reconcile_queue set last_outcome='reconciled',updated_at=now() where attempt_id=a.id;
 return jsonb_build_object('reconciled',true,'released_microusd',released,'actual_microusd',p_actual_microusd);
end $$;

-- What is still unresolved and why: claimable now, given up (12 tries), OpenRouter attempts without a generation id
-- (lost before the response headers), and older attempts of other providers (an owner reconciles them with evidence).
create function app_private.openrouter_reconcile_health() returns jsonb
language sql stable security definer set search_path='' as $$
 with u as (select a.*,q.tries,q.last_outcome from app_private.provider_attempts a
  left join app_private.openrouter_reconcile_queue q on q.attempt_id=a.id
  where a.state='unknown' or (a.state='admitted' and a.created_at<now()-interval '1 hour'))
 select jsonb_build_object(
  'automatic_pending',(select count(*) from u where app_private.openrouter_reconcilable(u.provider,u.dispatched_at,u.provider_request_id,u.state,u.created_at)
   and coalesce(u.tries,0)<12),
  'gave_up',(select count(*) from u where coalesce(u.tries,0)>=12),
  'without_generation',(select count(*) from u where u.provider='openrouter' and u.provider_request_id is null and u.created_at<now()-interval '1 hour'),
  'other_providers',(select count(*) from u where u.provider<>'openrouter' and u.created_at<now()-interval '1 hour'),
  'manual_held_microusd',(select coalesce(sum(u.ceiling_microusd),0) from u where u.created_at<now()-interval '1 hour'
   and (coalesce(u.tries,0)>=12 or u.provider<>'openrouter' or u.provider_request_id is null)),
  'reconciled_24h',(select count(*) from app_private.provider_attempt_adjustments j where j.actor_id is null and j.created_at>now()-interval '24 hours'
   and j.evidence_reference like 'openrouter-generation:%'))
$$;
revoke all on function app_private.openrouter_reconcilable(text,timestamptz,text,text,timestamptz),app_private.openrouter_reconcile_health() from public,anon,authenticated;

create or replace function app_private.budget_health_extra() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('attempt_capacity_eighty_percent',coalesce((app_private.provider_attempt_window()->>'eighty_percent')::boolean,false),
  'tariffs_expiring_within_42d',jsonb_array_length(app_private.openrouter_tariff_attention()->'expiring'),
  'soonest_tariff_expiry',app_private.openrouter_tariff_attention()->'soonest_valid_until',
  'reconciliation',app_private.openrouter_reconcile_health())
$$;
create or replace function app_private.admin_health_extra() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('tariffs',app_private.openrouter_tariff_attention(),'reconciliation',app_private.openrouter_reconcile_health())
$$;

revoke all on function public.worker_openrouter_reconcile_claim(integer),public.worker_openrouter_reconcile_miss(uuid,text),
 public.worker_openrouter_reconcile(uuid,text,jsonb,bigint,jsonb) from public,anon,authenticated;
grant execute on function public.worker_openrouter_reconcile_claim(integer),public.worker_openrouter_reconcile_miss(uuid,text),
 public.worker_openrouter_reconcile(uuid,text,jsonb,bigint,jsonb) to service_role;
notify pgrst,'reload schema';
commit;
