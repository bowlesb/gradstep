-- 0141 (owner 2026-10-21): per-account AI cost from our own ledger, this UTC month and the last 30 UTC days, by feature
-- and by model, with totals; legacy direct-provider attempts stay in it, marked; owner with MFA only. Synthetic local SQL.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set A '14100000-0000-4000-8000-00000000000a'
\set B '14100000-0000-4000-8000-00000000000b'
\set C '14100000-0000-4000-8000-00000000000c'
\set OWN '14100000-0000-4000-8000-0000000000ff'
\set OA '14100000-0000-4000-8001-00000000000a'
\set OB '14100000-0000-4000-8001-00000000000b'
insert into auth.users(id,email,email_confirmed_at) values(:'A','reader-a-141@gradstep.test.org',now()),(:'B','reader-b-141@example.test',now()),
 (:'C','customer-141@gradstep.test.org',now()),(:'OWN','owner-141@gradstep.test.org',now());
insert into app_private.app_roles(account_id,role) values(:'OWN','owner');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','costs-141-a',1000,now()-interval '1 day',null,'Cost fixture');
select public.worker_grant_credits(:'B','adjustment','costs-141-b',1000,now()-interval '1 day',null,'Cost fixture');

-- Access: owner with MFA only; never anonymous; a bounded page.
select test.assert(has_function_privilege('authenticated','public.v1_admin_account_costs(integer)','execute'),'signed-in callers may ask');
select test.assert(not has_function_privilege('anon','public.v1_admin_account_costs(integer)','execute'),'never anonymous');
select test.assert(not has_function_privilege('authenticated','app_private.cost_feature(text,text)','execute'),'helpers are private');
set role authenticated;
select set_config('request.jwt.claim.sub',:'C',false);
select set_config('request.jwt.claim.aal','aal2',false);
select test.reject('select public.v1_admin_account_costs(50)','owner_mfa_required');
select set_config('request.jwt.claim.sub',:'OWN',false);
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject('select public.v1_admin_account_costs(50)','owner_mfa_required');
select set_config('request.jwt.claim.aal','aal2',false);
select test.reject('select public.v1_admin_account_costs(0)','invalid_costs_query');
select test.reject('select public.v1_admin_account_costs(501)','invalid_costs_query');
select public.v1_admin_account_costs(500) as before \gset
reset role;

-- The ledger rows (as the adapters and admission write them; inserted directly to fix their times and shapes).
set role service_role;
select public.worker_reserve_operation(:'A',:'OA','chat',sha256('costs141a'),'beta-credits-v1',100,900000);
select public.worker_reserve_operation(:'B',:'OB','chat',sha256('costs141b'),'beta-credits-v1',100,900000);
reset role;
create temporary table fixture(id uuid,account uuid,op uuid,provider text,route text,model text,feature text,state text,actual bigint,units jsonb,ceiling bigint,age interval);
insert into fixture values
 ('14100000-0000-4000-8002-000000000001',:'A',:'OA','openrouter','chat','anthropic/claude-sonnet-5.5','chat','succeeded',4800,'{"input_tokens":900,"output_tokens":300}',300000,'1 minute'),
 ('14100000-0000-4000-8002-000000000002',:'A',:'OA','openrouter','chat','gemini-3.8-flash','figure','succeeded',1000,'{}',100000,'1 minute'),
 ('14100000-0000-4000-8002-000000000003',:'A',:'OA','openrouter','chat','deepseek/deepseek-v4.1-flash-1017','equation','succeeded',700,'{}',100000,'1 minute'),
 ('14100000-0000-4000-8002-000000000004',:'A',:'OA','openrouter','chat','anthropic/claude-sonnet-5.5','chat','succeeded',300,'{"estimated":1}',100000,'1 minute'),
 ('14100000-0000-4000-8002-000000000005',:'A',:'OA','openrouter','chat','anthropic/claude-haiku-5.5','topic_title','unknown',null,'{}',50000,'1 minute'),
 ('14100000-0000-4000-8002-000000000006',:'A',:'OA','tavily','chat_search','search-basic',null,'succeeded',0,'{"credits":1,"searches":1}',0,'1 minute'),
 ('14100000-0000-4000-8002-000000000007',:'A',:'OA','anthropic','chat','claude-sonnet-5-5',null,'succeeded',138,'{}',138,'2 minutes'),
 ('14100000-0000-4000-8002-000000000008',:'A',:'OA','openrouter','chat','anthropic/claude-sonnet-5.5','chat','succeeded',9999,'{}',100000,'40 days'),
 ('14100000-0000-4000-8002-000000000009',:'A',:'OA','openrouter','chat','anthropic/claude-sonnet-5.5','chat','denied',null,'{}',100000,'1 minute'),
 ('14100000-0000-4000-8002-00000000000a',:'B',:'OB','openrouter','catalog_tags','anthropic/claude-haiku-5.5','catalog_tags','succeeded',341,'{}',10000,'1 minute'),
 ('14100000-0000-4000-8002-00000000000b',:'B',:'OB','openrouter','podcast_script','anthropic/claude-sonnet-5.5','podcast_script','succeeded',51200,'{}',300000,'1 minute');
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,state,
 actual_microusd,actual_units,pricing_snapshot,created_at,transport_metadata)
select f.id,f.account,f.op,f.provider,f.route,f.model,sha256(convert_to(f.id::text,'UTF8')),f.ceiling,'{}',f.state,f.actual,f.units,'{}',now()-f.age,
 case when f.feature is null then '{}'::jsonb else jsonb_build_object('transport_model',f.model,'endpoint','google-vertex/us','feature',f.feature,'caller','chat') end
from fixture f;
set role service_role;
select public.worker_settle_operation(:'A',:'OA',3,7000);
reset role;

select test.assert(app_private.cost_feature('chat','equation_background')='equation_explainer' and app_private.cost_feature('chat','figure_detail')='figure_explainer'
 and app_private.cost_feature('chat','suggest_follow_ups')='chat' and app_private.cost_feature('chat',null)='chat'
 and app_private.cost_feature('podcast_speech','podcast_speech')='podcasts' and app_private.cost_feature('ingest_lookup',null)='search'
 and app_private.cost_feature('catalog_tags','catalog_tags')='tags','features');

set role authenticated;
select set_config('request.jwt.claim.sub',:'OWN',false);
select set_config('request.jwt.claim.aal','aal2',false);
select public.v1_admin_account_costs(500) as costs \gset
select public.v1_admin_account_costs(1) as first \gset
reset role;
create temporary table r as select :'costs'::jsonb j, :'before'::jsonb b, :'first'::jsonb page;
create temporary table a as select x from r,jsonb_array_elements(r.j->'accounts') x where x->>'account_id'=:'A';
create temporary table bb as select x from r,jsonb_array_elements(r.j->'accounts') x where x->>'account_id'=:'B';
-- Reader A, this month and the last 30 days alike (the 40-day-old attempt is in neither; a denied one costs nothing).
select test.assert((select x->'month'='{"cost_microusd":6938,"reported_microusd":6638,"estimated_microusd":300,"held_microusd":50000,"attempts":7,
 "searches":1,"search_list_microusd":8000,"legacy_microusd":138,"credits_charged":3}'::jsonb from a),'A this month');
select test.assert((select x->'last_30_days'=x->'month' from a),'A: the last 30 days are the same');
select test.assert((select x->>'email'='reader-a-141@gradstep.test.org' and not (x->>'synthetic')::boolean and not (x->>'test')::boolean
 and not (x->>'closed')::boolean from a),'the email the Accounts tab shows, and the account labels');
select test.assert((select jsonb_object_agg(f->>'feature',(f->'month'->>'cost_microusd')::bigint) from a,jsonb_array_elements(a.x->'by_feature') f)
 ='{"chat":5238,"figure_explainer":1000,"equation_explainer":700,"search":0}'::jsonb,'A by feature (titles are chat; legacy direct chat is chat)');
select test.assert((select (f->'month'->>'held_microusd')::bigint=50000 and (f->'month'->>'legacy_microusd')::bigint=138
 from a,jsonb_array_elements(a.x->'by_feature') f where f->>'feature'='chat'),'chat holds the unresolved title and the legacy cost');
select test.assert((select (f->'month'->>'searches')::integer=1 and (f->'month'->>'search_list_microusd')::integer=8000
 from a,jsonb_array_elements(a.x->'by_feature') f where f->>'feature'='search'),'searches are prepaid: counted, valued, not costed');
select test.assert((select jsonb_object_agg(m->>'provider'||':'||(m->>'model'),(m->'month'->>'cost_microusd')::bigint) from a,jsonb_array_elements(a.x->'by_model') m)
 ='{"openrouter:anthropic/claude-sonnet-5.5":5100,"openrouter:gemini-3.8-flash":1000,"openrouter:deepseek/deepseek-v4.1-flash-1017":700,
   "openrouter:anthropic/claude-haiku-5.5":0,"tavily:search-basic":0,"anthropic:claude-sonnet-5-5":138}'::jsonb,'A by model');
select test.assert((select (m->>'legacy')::boolean from a,jsonb_array_elements(a.x->'by_model') m where m->>'provider'='anthropic')
 and (select not (m->>'legacy')::boolean from a,jsonb_array_elements(a.x->'by_model') m where m->>'model'='gemini-3.8-flash'),'legacy marked per model');
-- Reader B: tags and podcasts; a test address is labelled.
select test.assert((select (x->'month'->>'cost_microusd')::bigint=51541 and (x->'month'->>'credits_charged')::bigint=0 and (x->>'test')::boolean from bb),'B');
select test.assert((select jsonb_object_agg(f->>'feature',(f->'last_30_days'->>'cost_microusd')::bigint) from bb,jsonb_array_elements(bb.x->'by_feature') f)
 ='{"podcasts":51200,"tags":341}'::jsonb,'B by feature');
-- Order: by the last 30 days' cost and held ceilings (A: 6,938 + 50,000 held; B: 51,541).
select test.assert((select (select ord from jsonb_array_elements(r.j->'accounts') with ordinality e(x,ord) where x->>'account_id'=:'A')
 <(select ord from jsonb_array_elements(r.j->'accounts') with ordinality e(x,ord) where x->>'account_id'=:'B') from r),'A first');
-- Totals grow by exactly this fixture (whatever other fixtures left).
select test.assert((select (j->'totals'->'month'->>'cost_microusd')::bigint-(b->'totals'->'month'->>'cost_microusd')::bigint=6938+51541 from r),'month total');
select test.assert((select (j->'totals'->'last_30_days'->>'held_microusd')::bigint-(b->'totals'->'last_30_days'->>'held_microusd')::bigint=50000 from r),'held total');
select test.assert((select (j->'totals'->'last_30_days'->>'legacy_microusd')::bigint-(b->'totals'->'last_30_days'->>'legacy_microusd')::bigint=138 from r),'legacy total');
select test.assert((select exists(select 1 from jsonb_array_elements(j->'totals'->'by_feature') f where f->>'feature'='podcasts')
 and exists(select 1 from jsonb_array_elements(j->'totals'->'by_model') m where m->>'model'='gemini-3.8-flash') from r),'totals by feature and model');
-- A page of one: the costliest account, and the page says it is truncated.
select test.assert((select jsonb_array_length(page->'accounts')=1 and (page->>'truncated')::boolean and (page->>'limit')::integer=1 from r),'bounded page');
-- Nothing changed in the ledger by reading it.
select test.assert((select count(*)=11 from app_private.provider_attempts where id in (select id from fixture)),'read only');
rollback;
