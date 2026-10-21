-- 0106 (review A13): a scope's failures open only that scope's breaker; callers without a scope keep the provider's own.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
set role service_role;
select public.worker_provider_health(p_provider=>'openrouter',p_route=>'chat',p_outcome=>'server_error',p_scope=>'chat_deepinfra') from generate_series(1,5);
select test.assert(public.worker_provider_health(p_provider=>'openrouter',p_route=>'chat',p_outcome=>'ok',p_scope=>'chat_vertex')->>'state'='closed',
 'Vertex chat stays closed');
select test.assert(public.worker_provider_breakers()->0->>'scope'='chat_deepinfra' and jsonb_array_length(public.worker_provider_breakers())=1,
 'only DeepInfra chat is open, listed with its scope');
-- A caller from before the scope (the 073 named arguments) records against the provider's own breaker.
select test.assert(public.worker_provider_health(p_provider=>'tavily',p_route=>'chat',p_outcome=>'ok',p_latency_ms=>5,p_retry_after_s=>null,p_drill=>false)->>'scope'='',
 'unscoped calls still work');
select test.assert(public.worker_provider_health(p_provider=>'openrouter',p_route=>'chat',p_outcome=>'ok',p_scope=>'Bad Scope!') is null,'an invalid scope is ignored, never an error');
reset role;
select test.assert((select state='open' from app_private.provider_breakers where provider='openrouter' and scope='chat_deepinfra'),'DeepInfra chat opened');
select test.assert(not exists(select 1 from app_private.provider_breakers where provider='openrouter' and scope in ('','chat_vertex') and state='open'),
 'neither the provider nor Vertex chat is open');
select test.assert((select sum(calls)=6 from app_private.provider_health_hours where provider='openrouter' and route='chat'),'health hours still count per provider and route');
select test.assert(not has_function_privilege('authenticated','public.worker_provider_health(text,text,text,integer,integer,boolean,text)','execute'),'service only');
rollback;
