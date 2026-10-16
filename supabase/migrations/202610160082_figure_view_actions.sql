-- 082: The figure view's two chat actions are settled and recorded like the equation view's (docs/architecture/
-- FIGURE_VIEW.md, "Server — as built"). `figure` (a walkthrough of one figure, part by part) and `figure_simpler` (one part
-- again, more simply) are ordinary paper-chat operations: held, answered and settled by the chat function, and their
-- ending recorded with the same rules (CHAT.md "When an answer stops early"). Migration 079 named every chat action in
-- app_private.chat_endings' check and in worker_settle_chat, so a figure-view settlement would be refused
-- (invalid_settlement) and left for the stale-hold sweep. Additive: the check gains the two names, worker_settle_chat's
-- body is migration 079's with them; no row is changed.
begin;

alter table app_private.chat_endings drop constraint chat_endings_action_check;
alter table app_private.chat_endings add constraint chat_endings_action_check check (action in
  ('answer','ingest','related','relevance','diagram_fix','study','equation','equation_background','figure','figure_simpler','unknown'));

create or replace function public.worker_settle_chat(p_account_id uuid, p_id uuid, p_actual_credits bigint, p_actual_microusd bigint,
  p_action text, p_ending text, p_absorbed_microusd bigint) returns void
language plpgsql security definer set search_path='' as $$
declare e app_private.chat_endings; is_charged boolean := p_ending in ('completed','stopped','left');
begin
 if p_action is null or p_action not in ('answer','ingest','related','relevance','diagram_fix','study','equation','equation_background','figure','figure_simpler')
  or p_ending is null or p_ending not in ('completed','stopped','left','provider','server','limit','connection','refusal')
  or p_absorbed_microusd is null or p_absorbed_microusd not between 0 and 1000000000
  or (not is_charged and p_actual_credits is distinct from 0) then raise exception 'invalid_settlement'; end if;
 if not exists (select 1 from app_private.metered_operations where account_id=p_account_id and id=p_id and kind='chat') then
  raise exception 'invalid_settlement';
 end if;
 perform public.worker_settle_operation(p_account_id, p_id, p_actual_credits, p_actual_microusd);
 select * into e from app_private.chat_endings where account_id=p_account_id and operation_id=p_id;
 if found then
  if (e.action, e.ending, e.credits, e.absorbed_microusd) is distinct from (p_action, p_ending, p_actual_credits, p_absorbed_microusd)
  then raise exception 'settlement_id_conflict'; end if;
  return;
 end if;
 insert into app_private.chat_endings(account_id, operation_id, action, ending, charged, credits, absorbed_microusd)
 values (p_account_id, p_id, p_action, p_ending, is_charged, p_actual_credits, p_absorbed_microusd);
end $$;

revoke all on function public.worker_settle_chat(uuid, uuid, bigint, bigint, text, text, bigint) from public, anon, authenticated;
grant execute on function public.worker_settle_chat(uuid, uuid, bigint, bigint, text, text, bigint) to service_role;
notify pgrst, 'reload schema';
commit;
