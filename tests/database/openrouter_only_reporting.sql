-- 0140 (owner 2026-10-21, OpenRouter exclusively): the budget check fails only on unresolved OpenRouter attempts; attempts
-- of retired direct providers are named as legacy, by provider, with the ceilings they still hold (never dropped);
-- Tavily's searches are counted apart; Health's cache figure reads OpenRouter usage. Synthetic local SQL.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set A '14000000-0000-4000-8000-00000000000a'
\set OWN '14000000-0000-4000-8000-0000000000ff'
\set O '14000000-0000-4000-8001-000000000001'
\set K '14000000-0000-4000-8002-000000000001'
\set U '14000000-0000-4000-8002-000000000002'
\set L '14000000-0000-4000-8002-000000000003'
\set S '14000000-0000-4000-8002-000000000004'
\set M '{"transport_model":"anthropic/claude-sonnet-5.5","endpoint":"google-vertex/us","feature":"chat","caller":"chat"}'
insert into auth.users(id,email,email_confirmed_at) values(:'A','reporting-140@gradstep.test.org',now()),(:'OWN','owner-140@gradstep.test.org',now());
insert into app_private.app_roles(account_id,role) values(:'OWN','owner');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','reporting-140',1000,now()-interval '1 day',null,'Reporting fixture');

-- What the checks said before this fixture's rows (other fixtures in the phase may have left their own).
set role service_role;
select (public.worker_budget_health()->>'unknown_openrouter_attempts_over_1h')::integer as or_before,
 (public.worker_budget_health()->>'unknown_attempts_over_1h')::integer as all_before,
 (public.worker_budget_health()->'reconciliation'->>'other_providers')::integer as legacy_before,
 coalesce((public.worker_budget_health()->'reconciliation'->'legacy'->'by_provider'->>'anthropic')::integer,0) as anthropic_before,
 (public.worker_budget_health()->'reconciliation'->'legacy'->>'held_microusd')::bigint as legacy_held_before,
 (public.worker_budget_health()->'reconciliation'->>'search_unresolved')::integer as search_before \gset
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub',:'OWN',false);
select set_config('request.jwt.claim.aal','aal2',false);
select (public.v1_admin_health(30)->'money'->'chat_cache'->>'read_tokens')::bigint as cache_before \gset
reset role;

set role service_role;
select public.worker_reserve_operation(:'A',:'O','chat',sha256('reporting140'),'beta-credits-v1',100,900000);
-- K: an OpenRouter answer that finished, with cache use. U: one whose result is unknown.
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',:'K','openrouter','chat','anthropic/claude-sonnet-5.5',sha256('k'),300000,'{"output_tokens":2000}')->>'granted')::boolean,'K admitted');
select test.assert(public.worker_openrouter_dispatch(:'A',:'O',:'K',:'M'),'K dispatched');
select public.worker_provider_attempt_finish(:'A',:'O',:'K','succeeded','gen-140k',4800,
 '{"input_tokens":100,"cache_read_tokens":900,"cache_write_5m_tokens":50,"output_tokens":300}',null);
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',:'U','openrouter','chat','anthropic/claude-sonnet-5.5',sha256('u'),300000,'{"output_tokens":2000}')->>'granted')::boolean,'U admitted');
select test.assert(public.worker_openrouter_dispatch(:'A',:'O',:'U',:'M'),'U dispatched');
select public.worker_provider_attempt_finish(:'A',:'O',:'U','unknown','gen-140u',null,'{}','aborted');
reset role;
update app_private.provider_attempts set created_at=now()-interval '2 hours' where id=:'U';
-- L: a direct Anthropic attempt from before 2026-10-18 (history), still unresolved. S: a Tavily search, unresolved.
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,state,pricing_snapshot,created_at)
values(:'L',:'A',:'O','anthropic','chat','claude-sonnet-5-5',sha256('l'),138,'{"output_tokens":10}','unknown','{}',now()-interval '4 days'),
 (:'S',:'A',:'O','tavily','chat_search','search-basic',sha256('s'),0,'{"credits":1}','unknown','{}',now()-interval '2 hours');
-- A legacy usage record with cache tokens: not OpenRouter, so not in Health's cache figure.
insert into app_private.provider_usage_events(account_id,operation_id,provider,provider_event_id,model,units,estimated_microusd)
values(:'A',:'O','anthropic','msg_legacy_140','claude-sonnet-5-5','{"input_tokens":1,"cache_read_tokens":50000}',100);

set role service_role;
select test.assert((public.worker_budget_health()->>'unknown_openrouter_attempts_over_1h')::integer=:or_before+1,
 'the budget check counts the unresolved OpenRouter attempt');
select test.assert((public.worker_budget_health()->>'unknown_attempts_over_1h')::integer=:all_before+3,
 'the older all-provider field (for older checks) still counts all three');
select test.assert((public.worker_budget_health()->'reconciliation'->>'other_providers')::integer=:legacy_before+1,
 'only the retired direct provider is legacy; Tavily is not');
select test.assert((public.worker_budget_health()->'reconciliation'->'legacy'->'by_provider'->>'anthropic')::integer=:anthropic_before+1,
 'legacy is named by provider');
select test.assert((public.worker_budget_health()->'reconciliation'->'legacy'->>'held_microusd')::bigint=:legacy_held_before+138,
 'with the ceiling it still holds (not dropped)');
select test.assert((public.worker_budget_health()->'reconciliation'->>'search_unresolved')::integer=:search_before+1,'Tavily is counted apart');
select test.assert(public.worker_budget_health()->'reconciliation' ? 'manual_held_microusd','the held total is still reported');
reset role;
select test.assert(app_private.legacy_provider('anthropic') and app_private.legacy_provider('deepseek') and app_private.legacy_provider('google')
 and app_private.legacy_provider('mathpix') and not app_private.legacy_provider('openrouter') and not app_private.legacy_provider('tavily'),'legacy providers');

-- Health: the cache figure is OpenRouter's (the legacy record's 50,000 cached tokens are not in it).
set role authenticated;
select set_config('request.jwt.claim.sub',:'OWN',false);
select set_config('request.jwt.claim.aal','aal2',false);
select test.assert((public.v1_admin_health(30)->'money'->'chat_cache'->>'read_tokens')::bigint=:cache_before+900,'OpenRouter cache reads');
select test.assert(public.v1_admin_health(30) ? 'reconciliation' and public.v1_admin_health(30) ? 'account_deletions','the earlier fields remain');
select set_config('request.jwt.claim.aal','aal1',false);
do $$ begin perform public.v1_admin_health(30); raise exception 'did_not_reject';
exception when others then if sqlerrm<>'owner_mfa_required' then raise exception 'expected owner_mfa_required, got %',sqlerrm; end if; end $$;
reset role;
select test.assert(not has_function_privilege('anon','public.v1_admin_health(integer)','execute'),'never anonymous');
select test.assert(not has_function_privilege('authenticated','app_private.admin_health_before_0140(integer)','execute'),'the wrapped function is private');
rollback;
