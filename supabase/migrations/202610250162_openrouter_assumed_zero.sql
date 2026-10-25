-- 0162: An OpenRouter attempt that sent us no output and that OpenRouter still has no record of after the reconciler's 12
-- tries is settled at zero automatically, distinguishably and auditable, and corrected if a record turns up later
-- (JUDGMENT_LOG 21, owner 2026-10-25: "make a good judgment and keep a log"; design: docs/architecture/PROVIDER_SPENDING.md
-- "Assumed zero").
-- Before (0102): such an attempt kept its whole ceiling reserved as Gradstep's liability until an owner reconciled it by
-- hand (scripts/pipeline-ops.py). On staging three Gemini Flash attempts (silent or broken streams, 2026-10-24/25) held
-- $0.39 that way, and an OpenRouter attempt whose generation id was never issued could not be tried at all. The worker
-- also recorded every unreadable read (a 401 from an expired key, a 5xx, a timeout) as `not_found`.
-- Now, for exactly these attempts (`openrouter_zero_candidate`): OpenRouter, `unknown`, dispatched by chat's
-- admittedModelCalls (the only caller that records the model's first output, `first_data_ms`, migration 0161), finished
-- through its normal path (`attempts` among the units; not `transport_unknown`), no `first_data_ms`, no receipt, no read
-- that ever found a record (`record_seen`), its operation settled (the reader's charge is final), at most 30 days old:
--  * a read on or after the 12th try that OpenRouter answers 404 (or no generation id was ever issued: no record can be
--    read) settles it at 0 (`worker_openrouter_reconcile_absent`): state `reconciled`, actual 0, units {"estimated":1}
--    (0160's `usage_reported` keeps it unreported; Spending counts it as an estimate), the original failure code kept
--    (model health still counts the failure), the ceiling released from the month and the operation's liability, an
--    adjustment with evidence `openrouter-no-record:<generation id>` that keeps the ceiling as the released (assumed zero)
--    liability, and a `reconciled` event with `settled_reason: no_record_no_bytes`. The reader is never charged;
--  * the reconciler keeps reading such an attempt's record once a day until it is 30 days old; a late record corrects it
--    to the record's cost (`worker_openrouter_reconcile`, released 0, the cost added to the month), and one that does not
--    match is shown as a contradiction until an owner reconciles it by hand (which ends the daily reads);
--  * anything else (output arrived, a record ever seen, a read that was not a clean 404, another caller, an open
--    operation, an `admitted` attempt) keeps 0102's behaviour: 12 tries, then manual reconciliation.
-- Health (`reconciliation.assumed_zero`, in Admin › Health and `worker_budget_health`) and Spending (`assumed_zero`) show
-- the month's count and assumed ceilings, later corrections and contradictions, so an unexpected OpenRouter bill stands
-- out against them. Apply before deploying the pipeline worker (it calls the new function and reports `unreadable`).
begin;
set local lock_timeout='15s';

-- 1. The queue remembers whether any read found a record, and when an attempt was assumed zero. A read that is not a clean
-- 404 is `unreadable`, never `not_found`. Rows written before this migration with `mismatch` found a record.
alter table app_private.openrouter_reconcile_queue
 add column record_seen boolean not null default false,
 add column assumed_zero_at timestamptz;
alter table app_private.openrouter_reconcile_queue drop constraint openrouter_reconcile_queue_last_outcome_check;
alter table app_private.openrouter_reconcile_queue add constraint openrouter_reconcile_queue_last_outcome_check
 check(last_outcome in ('claimed','reconciled','resolved','not_found','mismatch','no_key','unreadable','assumed_zero'));
update app_private.openrouter_reconcile_queue set record_seen=true where last_outcome='mismatch';
-- The month's assumed-zero settlements, read by Health and Spending.
create index provider_attempt_adjustment_assumed_zero on app_private.provider_attempt_adjustments(created_at)
 where actor_id is null and evidence_reference like 'openrouter-no-record:%';

-- 2. No output recorded: an attempt finished by chat's admittedModelCalls (caller `chat`; `attempts` among its units, so not
-- the `transport_unknown` path that records none) without `first_data_ms` (the model's first output, recorded since 0161)
-- and without a receipt (a finished stream's or a generation record's). Attempts finished before `first_data_ms` was
-- recorded carry no evidence either way; for them, no receipt and no first-output record is taken as no output (JUDGMENT_LOG 21).
create function app_private.openrouter_no_output(p_caller text,p_units jsonb,p_receipt jsonb,p_failure text) returns boolean
language sql immutable set search_path='' as $$
 select coalesce(p_caller='chat' and jsonb_typeof(p_units->'attempts')='number' and not (p_units ? 'first_data_ms')
  and p_receipt='{}'::jsonb and p_failure is distinct from 'transport_unknown',false)
$$;
-- An attempt that may be assumed zero once OpenRouter confirms it has no record (the queue's own conditions apart).
create function app_private.openrouter_zero_candidate(p_provider text,p_state text,p_dispatched_at timestamptz,p_created_at timestamptz,
 p_metadata jsonb,p_units jsonb,p_receipt jsonb,p_failure text) returns boolean
language sql stable set search_path='' as $$
 select coalesce(p_provider='openrouter' and p_state='unknown' and p_dispatched_at is not null
  and p_created_at<now()-interval '2 minutes' and p_created_at>now()-interval '30 days'
  and app_private.openrouter_no_output(p_metadata->>'caller',p_units,p_receipt,p_failure),false)
$$;

-- An owner reconciled the attempt by hand after it was assumed zero: that evidence stands; the reconciler leaves it alone.
create function app_private.openrouter_owner_settled_since(p_attempt_id uuid,p_since timestamptz) returns boolean
language sql stable set search_path='' as $$
 select exists(select 1 from app_private.provider_attempt_adjustments j where j.attempt_id=p_attempt_id and j.actor_id is not null and j.created_at>=p_since)
$$;

-- 3. As 0102, plus: candidates without a generation id (no lookup; their tries keep the same schedule), candidates past
-- their 12th try (one read a day until a clean 404 settles them or they are 30 days old) and assumed-zero attempts (one read
-- a day for a late record until 30 days old). Each claim says its try, whether a clean 404 now settles it (`final`) and
-- whether it was assumed zero. Back-off as before, capped at a day.
create or replace function public.worker_openrouter_reconcile_claim(p_limit integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare items jsonb;
begin
 if p_limit is null or p_limit not between 1 and 50 then raise exception 'invalid_limit'; end if;
 with open_attempts as (
  select a.id,a.account_id,a.operation_id,a.provider_request_id,a.transport_metadata,a.state,coalesce(q.next_at,a.created_at) due_at,
   app_private.openrouter_zero_candidate(a.provider,a.state,a.dispatched_at,a.created_at,a.transport_metadata,a.actual_units,a.receipt_metadata,a.failure_code)
    and not coalesce(q.record_seen,false) candidate,
   app_private.openrouter_reconcilable(a.provider,a.dispatched_at,a.provider_request_id,a.state,a.created_at)
    and (q.attempt_id is null or (q.next_at<=now() and q.tries<12 and q.last_outcome<>'reconciled')) as tried,
   q.attempt_id is null or (q.next_at<=now() and q.tries<60 and (a.provider_request_id is null or q.tries>=12)) as zero_due
  from app_private.provider_attempts a
  left join app_private.openrouter_reconcile_queue q on q.attempt_id=a.id
  where a.state in ('unknown','admitted') and a.provider='openrouter'),
 due as (
  select o.id,o.account_id,o.operation_id,o.provider_request_id,o.transport_metadata,o.state,o.candidate,o.due_at
  from open_attempts o where o.tried or (o.candidate and o.zero_due)
  union all
  select a.id,a.account_id,a.operation_id,a.provider_request_id,a.transport_metadata,a.state,false,q.next_at
  from app_private.openrouter_reconcile_queue q join app_private.provider_attempts a on a.id=q.attempt_id
  where q.assumed_zero_at is not null and q.last_outcome<>'reconciled' and q.next_at<=now() and q.tries<60
   and a.state='reconciled' and a.provider='openrouter' and a.provider_request_id is not null and a.created_at>now()-interval '30 days'
   and not app_private.openrouter_owner_settled_since(a.id,q.assumed_zero_at)
  order by due_at,id limit p_limit),
 queued as (
  insert into app_private.openrouter_reconcile_queue as q(attempt_id,tries,next_at,last_outcome,updated_at)
  select id,1,now()+interval '5 minutes','claimed',now() from due
  on conflict(attempt_id) do update set tries=q.tries+1,next_at=now()+least(interval '24 hours',interval '5 minutes'*power(2,least(q.tries,10))),
   last_outcome='claimed',updated_at=now()
  returning q.attempt_id,q.tries)
 select coalesce(jsonb_agg(jsonb_build_object('attempt_id',d.id,'account_id',d.account_id,'operation_id',d.operation_id,
  'generation_id',d.provider_request_id,'transport_model',d.transport_metadata->>'transport_model','feature',d.transport_metadata->>'feature',
  'tries',k.tries,'final',d.candidate and k.tries>=12,'assumed_zero',d.state='reconciled') order by d.id),'[]'::jsonb) into items
 from due d join queued k on k.attempt_id=d.id;
 return items;
end $$;

-- 4. As 0102, plus `unreadable` (a read that was not a clean 404), and a mismatch is remembered: a record exists.
create or replace function public.worker_openrouter_reconcile_miss(p_attempt_id uuid,p_outcome text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_outcome is null or p_outcome not in ('not_found','mismatch','no_key','unreadable') then raise exception 'invalid_reconciliation'; end if;
 update app_private.openrouter_reconcile_queue set last_outcome=p_outcome,record_seen=record_seen or p_outcome='mismatch',updated_at=now()
 where attempt_id=p_attempt_id;
end $$;

-- 5. OpenRouter answered 404 (or no generation id was issued) on or after the 12th try: settle a candidate at zero. The
-- database decides; anything short of every condition records the read as `not_found` and changes nothing else.
create function public.worker_openrouter_reconcile_absent(p_attempt_id uuid,p_generation_id text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a app_private.provider_attempts; q app_private.openrouter_reconcile_queue; op app_private.metered_operations;
 adjustment uuid:=gen_random_uuid(); units jsonb:='{"estimated":1}'; evidence text; refused text;
begin
 if p_attempt_id is null then raise exception 'invalid_reconciliation'; end if;
 select * into a from app_private.provider_attempts where id=p_attempt_id;
 if not found then raise exception 'invalid_reconciliation'; end if;
 op:=app_private.provider_lock_operation(a.account_id,a.operation_id);
 select * into strict a from app_private.provider_attempts where id=p_attempt_id for update;
 if a.provider<>'openrouter' or a.dispatched_at is null or a.provider_request_id is distinct from p_generation_id then raise exception 'invalid_reconciliation'; end if;
 select * into q from app_private.openrouter_reconcile_queue where attempt_id=a.id for update;
 refused:=case
  when a.state<>'unknown' then 'not_unknown'
  when q.attempt_id is null or q.tries<12 then 'too_early'
  when q.record_seen then 'record_seen'
  when q.assumed_zero_at is not null then 'already_assumed'
  when not app_private.openrouter_zero_candidate(a.provider,a.state,a.dispatched_at,a.created_at,a.transport_metadata,a.actual_units,a.receipt_metadata,a.failure_code)
   then 'output_or_age'
  when op.state<>'settled' then 'operation_open' end;
 if refused is not null then
  if a.state='unknown' then
   update app_private.openrouter_reconcile_queue set last_outcome='not_found',updated_at=now() where attempt_id=a.id;
  end if;
  return jsonb_build_object('settled',false,'reason',refused);
 end if;
 evidence:='openrouter-no-record:'||coalesce(left(p_generation_id,230),'no-generation-id');
 -- The ceiling leaves the month's reservation and the operation's liability; nothing is spent; the failure code stays.
 perform app_private.provider_attempt_apply(a.id,'reconciled',null,0,units,a.failure_code);
 insert into app_private.provider_attempt_adjustments(id,attempt_id,actor_id,before_microusd,after_microusd,released_liability_microusd,units,evidence_reference,reason)
 values(adjustment,a.id,null,0,0,a.ceiling_microusd,units,evidence,'Automatic: assumed zero; no output received and no OpenRouter record after 12 tries');
 insert into app_private.provider_attempt_events(attempt_id,state,details) values(a.id,'reconciled',jsonb_build_object('adjustment_id',adjustment,
  'automatic',true,'actual_microusd',0,'units',units,'evidence_reference',evidence,'settled_reason','no_record_no_bytes',
  'assumed_zero_microusd',a.ceiling_microusd,'tries',q.tries));
 update app_private.openrouter_reconcile_queue set last_outcome='assumed_zero',assumed_zero_at=now(),next_at=now()+interval '24 hours',updated_at=now()
 where attempt_id=a.id;
 return jsonb_build_object('settled',true,'released_microusd',a.ceiling_microusd);
end $$;

-- 6. As 0102, plus the late record of an attempt assumed zero: corrected to the record's cost (nothing left to release;
-- the cost is added to the month), its failure code kept, audited as a correction.
create or replace function public.worker_openrouter_reconcile(p_attempt_id uuid,p_generation_id text,p_receipt jsonb,p_actual_microusd bigint,p_units jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a app_private.provider_attempts; op app_private.metered_operations; released bigint; usage_id uuid; adjustment uuid:=gen_random_uuid();
 evidence text; late boolean;
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
 late:=a.state='reconciled' and exists(select 1 from app_private.openrouter_reconcile_queue q
  where q.attempt_id=a.id and q.assumed_zero_at is not null and q.last_outcome<>'reconciled'
   and not app_private.openrouter_owner_settled_since(a.id,q.assumed_zero_at));
 if a.state not in ('unknown','admitted') and not late then
  update app_private.openrouter_reconcile_queue set last_outcome='resolved',updated_at=now() where attempt_id=a.id and last_outcome<>'reconciled';
  return jsonb_build_object('reconciled',false,'state',a.state);
 end if;
 -- The receipt: generation, provider and model checked as at dispatch (receipt_model_mismatch on another model).
 perform public.worker_openrouter_receipt(a.account_id,a.operation_id,a.id,p_receipt);
 released:=case when late then 0 else a.ceiling_microusd end;
 evidence:='openrouter-generation:'||left(p_generation_id,230);
 select id into usage_id from app_private.provider_usage_events where provider=a.provider and provider_event_id='attempt:'||a.id;
 perform app_private.provider_attempt_apply(a.id,'reconciled',null,p_actual_microusd,p_units,case when late then a.failure_code end);
 insert into app_private.provider_attempt_adjustments(id,attempt_id,actor_id,before_microusd,after_microusd,released_liability_microusd,units,evidence_reference,reason)
 values(adjustment,a.id,null,coalesce(a.actual_microusd,0),p_actual_microusd,released,p_units,evidence,
  case when late then 'Automatic: a late OpenRouter record corrects an assumed zero' else 'Automatic: OpenRouter generation record' end);
 if usage_id is not null then
  insert into app_private.provider_reconciliations(usage_event_id,invoice_reference,adjustment_microusd)
  values(usage_id,'attempt-adjustment:'||adjustment,p_actual_microusd-coalesce(a.actual_microusd,0));
 end if;
 insert into app_private.provider_attempt_events(attempt_id,state,details) values(a.id,'reconciled',jsonb_build_object('adjustment_id',adjustment,
  'automatic',true,'actual_microusd',p_actual_microusd,'units',p_units,'evidence_reference',evidence)
  ||case when late then jsonb_build_object('corrects','no_record_no_bytes') else '{}'::jsonb end);
 update app_private.openrouter_reconcile_queue set last_outcome='reconciled',updated_at=now() where attempt_id=a.id;
 return jsonb_build_object('reconciled',true,'released_microusd',released,'actual_microusd',p_actual_microusd)
  ||case when late then jsonb_build_object('corrected',true) else '{}'::jsonb end;
end $$;

-- 7. As 0140, with candidates counted as automatic (not manual) while they can still settle, and the month's assumed zeros.
create or replace function app_private.openrouter_reconcile_health() returns jsonb
language sql stable security definer set search_path='' as $$
 with u as (select a.*,q.tries,q.last_outcome,
   app_private.openrouter_zero_candidate(a.provider,a.state,a.dispatched_at,a.created_at,a.transport_metadata,a.actual_units,a.receipt_metadata,a.failure_code)
    and not coalesce(q.record_seen,false) and coalesce(q.tries,0)<60 zero
  from app_private.provider_attempts a
  left join app_private.openrouter_reconcile_queue q on q.attempt_id=a.id
  where a.state='unknown' or (a.state='admitted' and a.created_at<now()-interval '1 hour')),
 v as (select u.*,u.zero or (app_private.openrouter_reconcilable(u.provider,u.dispatched_at,u.provider_request_id,u.state,u.created_at)
   and coalesce(u.tries,0)<12) auto from u),
 m as (select date_trunc('month',now() at time zone 'UTC') at time zone 'UTC' since),
 z as (select j.attempt_id,j.released_liability_microusd ceiling,p.actual_microusd,p.receipt_metadata<>'{}'::jsonb corrected
  from app_private.provider_attempt_adjustments j cross join m join app_private.provider_attempts p on p.id=j.attempt_id
  where j.actor_id is null and j.evidence_reference like 'openrouter-no-record:%' and j.created_at>=m.since),
 w as (select q.record_seen,p.provider_request_id is not null and p.created_at>now()-interval '30 days' and q.tries<60 checking
  from app_private.openrouter_reconcile_queue q join app_private.provider_attempts p on p.id=q.attempt_id
  where q.assumed_zero_at is not null and q.last_outcome<>'reconciled' and p.state='reconciled' and p.receipt_metadata='{}'::jsonb
   and not app_private.openrouter_owner_settled_since(p.id,q.assumed_zero_at))
 select jsonb_build_object(
  'automatic_pending',(select count(*) from v where v.auto),
  'gave_up',(select count(*) from v where coalesce(v.tries,0)>=12 and not v.auto),
  'without_generation',(select count(*) from v where v.provider='openrouter' and v.provider_request_id is null and v.created_at<now()-interval '1 hour'
   and not v.auto and coalesce(v.tries,0)<12),
  -- Retired direct providers only (anthropic, deepseek, google, mathpix): legacy history an owner settles with evidence.
  'other_providers',(select count(*) from v where app_private.legacy_provider(v.provider) and v.created_at<now()-interval '1 hour'),
  'legacy',(select jsonb_build_object('attempts',count(*),'held_microusd',coalesce(sum(v.ceiling_microusd),0),'oldest_at',min(v.created_at),
    'by_provider',coalesce((select jsonb_object_agg(x.provider,x.n order by x.provider) from (select y.provider,count(*) n from v y
     where app_private.legacy_provider(y.provider) group by y.provider) x),'{}'::jsonb))
   from v where app_private.legacy_provider(v.provider)),
  -- Tavily's prepaid searches (no dollar ceiling): neither OpenRouter nor legacy.
  'search_unresolved',(select count(*) from v where v.provider='tavily' and v.created_at<now()-interval '1 hour'),
  'manual_held_microusd',(select coalesce(sum(v.ceiling_microusd),0) from v where v.created_at<now()-interval '1 hour' and not v.auto
   and (coalesce(v.tries,0)>=12 or v.provider<>'openrouter' or v.provider_request_id is null)),
  'reconciled_24h',(select count(*) from app_private.provider_attempt_adjustments j where j.actor_id is null and j.created_at>now()-interval '24 hours'
   and j.evidence_reference like 'openrouter-generation:%'),
  -- 0162: settled at zero this UTC month (no output, no OpenRouter record after 12 tries) with the ceilings assumed zero;
  -- how many of them a late record has since corrected and at what cost; how many are still read daily for a late record,
  -- and how many of those a read found a record for that does not match (an owner reconciles them by hand).
  'assumed_zero',jsonb_build_object('month_start',(select since from m),'attempts',(select count(*) from z),
   'ceiling_microusd',(select coalesce(sum(z.ceiling),0) from z),'corrected',(select count(*) from z where z.corrected),
   'corrected_microusd',(select coalesce(sum(z.actual_microusd) filter(where z.corrected),0) from z),
   'checking',(select count(*) from w where w.checking),'contradicted',(select count(*) from w where w.record_seen)))
$$;

-- 8. Spending (the owner's window, optionally one account): the attempts assumed zero in the window, their ceilings, and
-- those a late record corrected (at the record's cost). The earlier function checks the owner, MFA and the rate first.
alter function public.v1_admin_spending(integer,uuid) rename to admin_spending_before_0162;
alter function public.admin_spending_before_0162(integer,uuid) set schema app_private;
revoke all on function app_private.admin_spending_before_0162(integer,uuid) from public,anon,authenticated;
create function public.v1_admin_spending(p_days integer default 30,p_account_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb; since timestamptz;
begin
 base:=app_private.admin_spending_before_0162(p_days,p_account_id);
 since:=(base->>'since')::timestamptz;
 return base||jsonb_build_object('assumed_zero',(select jsonb_build_object('attempts',count(*),'ceiling_microusd',coalesce(sum(j.released_liability_microusd),0),
   'corrected',count(*) filter(where p.receipt_metadata<>'{}'::jsonb),
   'corrected_microusd',coalesce(sum(p.actual_microusd) filter(where p.receipt_metadata<>'{}'::jsonb),0))
  from app_private.provider_attempt_adjustments j join app_private.provider_attempts p on p.id=j.attempt_id
  where j.actor_id is null and j.evidence_reference like 'openrouter-no-record:%' and j.created_at>=since
   and (p_account_id is null or p.account_id=p_account_id)));
end $$;

revoke all on function app_private.openrouter_no_output(text,jsonb,jsonb,text),app_private.openrouter_owner_settled_since(uuid,timestamptz),
 app_private.openrouter_zero_candidate(text,text,timestamptz,timestamptz,jsonb,jsonb,jsonb,text) from public,anon,authenticated;
revoke all on function public.worker_openrouter_reconcile_absent(uuid,text) from public,anon,authenticated;
grant execute on function public.worker_openrouter_reconcile_absent(uuid,text) to service_role;
revoke all on function public.v1_admin_spending(integer,uuid) from public,anon;
grant execute on function public.v1_admin_spending(integer,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
