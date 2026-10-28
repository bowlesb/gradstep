-- 0163: A fallback after a silent attempt fits the reader's hold: the silent attempt's ceiling moves out of the operation's
-- hold into Gradstep's own room (JUDGMENT_LOG 55; design: docs/architecture/CHAT.md "A fallback when the chosen model fails
-- before writing" and PROVIDER_SPENDING.md "A silent attempt carried by Gradstep").
-- Staging, 2026-10-28 14:12 and 14:14 UTC: a paper explainer on Gemini 3.8 Flash sent nothing for 25 s (attempt `unknown`,
-- ceiling 132,872 µ$), the stream said "Switching to Claude Haiku 5.5…", and Haiku's admission was `denied`
-- (`operation_ceiling`): its 149,531 µ$ ceiling did not fit the 149,531 µ$ hold beside the silent attempt's unresolved
-- ceiling. The reader got `provider_unavailable`. Every action without a search allowance (the paper, figure and equation
-- explainers, Go deeper, Study, answers without search) had no room, so after a silent model the fallback never ran.
-- The project's rule already is that a silent attempt's unresolved ceiling is Gradstep's liability, never the reader's. Now
-- `worker_openrouter_admit_fallback` admits a fallback's first request in one transaction with that rule applied:
--  * when the attempt it follows is silent (OpenRouter, chat, `unknown`, dispatched, no first output and no receipt:
--    0162's `openrouter_no_output`) and its operation is open, the operation's provider ceiling grows by exactly that
--    attempt's ceiling and the month's reservation with it ("carried"); the reader's credit hold (`credit_ceiling`, what the
--    quote showed) never changes, so the fallback, its searches, the title and the suggestions find the same room as after
--    a refusal that cost nothing. A `carried` event on the silent attempt records the amount and the fallback's attempt;
--  * the carried amount is still counted against the month: refused when the month's limit, the free AI pool (for an
--    operation free credits pay) or an account's testing cap could not take it (`carry_refused`); the fallback is then
--    admitted exactly as before (the database's own bound decides; usually `operation_ceiling`);
--  * nothing is carried for a refusal that cost nothing (`rejected`, as a 429 or 503), an attempt whose output arrived, a
--    replayed admission, a settled operation or an attempt carried before; a fallback that is then not admitted for any
--    other reason (paused, a lapsed price card, capacity) carries nothing either (undone in the same transaction).
-- Settlement, reconciliation, 0160's usage reporting and 0162's assumed zero are unchanged: the silent attempt keeps its
-- row, ceiling and failure; at settlement its ceiling is the operation's unresolved liability as before, released when it
-- is reconciled or assumed zero; the operation's ceiling (its quote's plus the carried amount) still bounds everything it
-- may spend, so no overrun is reported. A replayed reservation of a carried operation is compared with the ceiling it was
-- reserved at (the quote's), so it is still `replayed`, never a conflict.
-- Apply before deploying `chat` (its fallback calls the new function; without it the fallback is not sent, as before).
begin;
set local lock_timeout='15s';

alter table app_private.provider_attempt_events drop constraint provider_attempt_events_state_check;
alter table app_private.provider_attempt_events add constraint provider_attempt_events_state_check
 check(state in ('admitted','succeeded','rejected','unknown','denied','reconciled','provider_identified','dispatched','receipt','carried'));

-- What Gradstep carries for an operation: the ceilings of its silent attempts moved out of the reader's hold.
create function app_private.operation_carried_microusd(p_account_id uuid,p_operation_id uuid) returns bigint
language sql stable security definer set search_path='' as $$
 select coalesce(sum((e.details->>'carried_microusd')::bigint),0)::bigint from app_private.provider_attempts a
 join app_private.provider_attempt_events e on e.attempt_id=a.id and e.state='carried'
 where a.account_id=p_account_id and a.operation_id=p_operation_id
$$;

-- A fallback's first request (chat-fallback.ts): `p_after_attempt_id` is the chosen model's attempt it follows. As
-- worker_openrouter_admit (0107: admitted and dispatched in one transaction), with the silent attempt carried first.
create function public.worker_openrouter_admit_fallback(p_account_id uuid,p_operation_id uuid,p_attempt_id uuid,p_route text,p_model text,
 p_request_sha256 bytea,p_ceiling_microusd bigint,p_reserved_units jsonb,p_metadata jsonb,p_after_attempt_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare op app_private.metered_operations; s app_private.provider_attempts; b app_private.platform_budgets; c app_private.ai_controls;
 t app_private.testing_allowances; carry bigint:=0; refused text; admission jsonb;
begin
 if p_attempt_id is null or p_after_attempt_id is null or p_after_attempt_id=p_attempt_id then raise exception 'invalid_provider_attempt'; end if;
 -- The same lock order as every money path (budget, account, policy, operation).
 op:=app_private.provider_lock_operation(p_account_id,p_operation_id);
 select * into s from app_private.provider_attempts where id=p_after_attempt_id and account_id=p_account_id and operation_id=p_operation_id for update;
 if not found then raise exception 'invalid_provider_attempt'; end if;
 if not exists(select 1 from app_private.provider_attempts where id=p_attempt_id) and op.state in ('reserved','submitted')
  and s.provider='openrouter' and s.route='chat' and s.state='unknown' and s.dispatched_at is not null and s.ceiling_microusd>0
  and app_private.openrouter_no_output(s.transport_metadata->>'caller',s.actual_units,s.receipt_metadata,s.failure_code)
  and not exists(select 1 from app_private.provider_attempt_events e where e.attempt_id=s.id and e.state='carried') then
  select * into strict b from app_private.platform_budgets where period=op.period;
  select * into c from app_private.ai_controls;
  select * into t from app_private.testing_allowances where account_id=p_account_id and enabled;
  refused:=case
   when b.spent_microusd+b.reserved_microusd+s.ceiling_microusd>b.limit_microusd then 'platform_budget_exhausted'
   when op.free_funded and c.id is not null and app_private.free_pool_used()+s.ceiling_microusd>c.free_pool_microusd then 'free_pool_exhausted'
   when t.account_id is not null and t.monthly_cap_microusd is not null
    and app_private.account_month_spend(p_account_id)+s.ceiling_microusd>t.monthly_cap_microusd then 'testing_cap_reached' end;
  if refused is null then
   carry:=s.ceiling_microusd;
   update app_private.metered_operations set spend_ceiling_microusd=spend_ceiling_microusd+carry where account_id=p_account_id and id=p_operation_id;
   update app_private.platform_budgets set reserved_microusd=reserved_microusd+carry where period=op.period;
  end if;
 end if;
 admission:=public.worker_openrouter_admit(p_account_id,p_operation_id,p_attempt_id,p_route,p_model,p_request_sha256,p_ceiling_microusd,
  p_reserved_units,p_metadata);
 if carry>0 then
  if coalesce((admission->>'granted')::boolean,false) then
   insert into app_private.provider_attempt_events(attempt_id,state,details) values(s.id,'carried',jsonb_build_object('carried_microusd',carry,
    'fallback_attempt_id',p_attempt_id,'spend_ceiling_before',op.spend_ceiling_microusd,'spend_ceiling_after',op.spend_ceiling_microusd+carry));
  else
   update app_private.metered_operations set spend_ceiling_microusd=spend_ceiling_microusd-carry where account_id=p_account_id and id=p_operation_id;
   update app_private.platform_budgets set reserved_microusd=reserved_microusd-carry where period=op.period;
   carry:=0;
  end if;
 end if;
 return admission||jsonb_build_object('carried_microusd',carry)||case when refused is null then '{}'::jsonb else jsonb_build_object('carry_refused',refused) end;
end $$;

-- A replayed chat reservation is compared with what was reserved (the quote's ceiling), not with the carried one. A new
-- operation carries nothing, so its reservation is unchanged.
alter function public.worker_reserve_chat(uuid,uuid,bytea,text,bigint,bigint,jsonb) rename to reserve_chat_before_0163;
alter function public.reserve_chat_before_0163(uuid,uuid,bytea,text,bigint,bigint,jsonb) set schema app_private;
revoke all on function app_private.reserve_chat_before_0163(uuid,uuid,bytea,text,bigint,bigint,jsonb) from public,anon,authenticated,service_role;
create function public.worker_reserve_chat(p_account_id uuid,p_id uuid,p_request_sha256 bytea,p_rate_version text,
 p_credits bigint,p_microusd bigint,p_quote jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 return app_private.reserve_chat_before_0163(p_account_id,p_id,p_request_sha256,p_rate_version,p_credits,
  p_microusd+app_private.operation_carried_microusd(p_account_id,p_id),p_quote);
end $$;

revoke all on function app_private.operation_carried_microusd(uuid,uuid) from public,anon,authenticated;
revoke all on function public.worker_openrouter_admit_fallback(uuid,uuid,uuid,text,text,bytea,bigint,jsonb,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.worker_openrouter_admit_fallback(uuid,uuid,uuid,text,text,bytea,bigint,jsonb,jsonb,uuid) to service_role;
revoke all on function public.worker_reserve_chat(uuid,uuid,bytea,text,bigint,bigint,jsonb) from public,anon,authenticated;
grant execute on function public.worker_reserve_chat(uuid,uuid,bytea,text,bigint,bigint,jsonb) to service_role;

notify pgrst,'reload schema';
commit;
