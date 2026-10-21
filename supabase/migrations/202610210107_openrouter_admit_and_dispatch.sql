-- 0107: Admission and dispatch of an OpenRouter request in one round trip (review C6, 2026-10-21; design:
-- docs/architecture/PROVIDER_SPENDING.md "One round trip to admit and dispatch").
-- Before: every OpenRouter request made two sequential database calls before its POST (worker_provider_attempt_begin,
-- then worker_openrouter_dispatch). Now worker_openrouter_admit runs both in one transaction with the same checks and
-- the same closed metadata; a refused admission dispatches nothing, and a dispatch that fails its checks rolls the whole
-- admission back (nothing is sent). The two separate functions are unchanged for every other caller.
begin;
set local lock_timeout='15s';

create function public.worker_openrouter_admit(p_account_id uuid,p_operation_id uuid,p_attempt_id uuid,p_route text,p_model text,
 p_request_sha256 bytea,p_ceiling_microusd bigint,p_reserved_units jsonb,p_metadata jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare admission jsonb;
begin
 admission:=public.worker_provider_attempt_begin(p_account_id,p_operation_id,p_attempt_id,'openrouter',p_route,p_model,p_request_sha256,
  p_ceiling_microusd,p_reserved_units);
 if not coalesce((admission->>'granted')::boolean,false) then return admission||jsonb_build_object('dispatched',false); end if;
 return admission||jsonb_build_object('dispatched',public.worker_openrouter_dispatch(p_account_id,p_operation_id,p_attempt_id,p_metadata));
end $$;
revoke all on function public.worker_openrouter_admit(uuid,uuid,uuid,text,text,bytea,bigint,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.worker_openrouter_admit(uuid,uuid,uuid,text,text,bytea,bigint,jsonb,jsonb) to service_role;

notify pgrst,'reload schema';
commit;
