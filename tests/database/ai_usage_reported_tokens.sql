-- 0160: Your AI usage counts only the tokens a provider reported. An attempt without a provider count (still running,
-- unknown with chat's hold estimate in its units, or units marked estimated) adds nothing to a row's, a part's or the
-- window's tokens and is flagged (`estimated`, `unreported_calls`, totals' `unreported_operations`); succeeded, rejected
-- and reconciled attempts count as before. Every key the apps and the browser decode is still there as a number. Credits
-- unchanged. Synthetic local SQL.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set R '16000000-0000-4000-8000-00000000000a'
\set ANSWER '16000000-0000-4000-8001-000000000001'
\set FAILED '16000000-0000-4000-8001-000000000002'
\set RECON '16000000-0000-4000-8001-000000000003'
\set EST '16000000-0000-4000-8001-000000000004'
\set RUNNING '16000000-0000-4000-8001-000000000005'
\set SEARCH '16000000-0000-4000-8001-000000000006'
insert into auth.users(id,email,email_confirmed_at) values(:'R','usage-reported-160@example.test',now());
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'R','adjustment','usage-160-r',1000,now()-interval '60 days',null,'Usage fixture');

-- The ledger as the chat path writes it (attempts inserted directly to fix their shapes).
create temporary table fixture(id uuid,op uuid,provider text,route text,model text,feature text,state text,actual bigint,units jsonb,age interval);
insert into fixture values
 -- A completed answer: its answer reported; its title call lost (unknown), its units the hold estimate (no estimated mark).
 ('16000000-0000-4000-8002-000000000001',:'ANSWER','openrouter','chat','anthropic/claude-sonnet-5.5','chat','succeeded',9000,
  '{"input_tokens":1000,"cache_read_tokens":30000,"cache_write_5m_tokens":200,"output_tokens":500,"web_searches":0,"attempts":1}','10 minutes'),
 ('16000000-0000-4000-8002-000000000002',:'ANSWER','openrouter','chat','anthropic/claude-haiku-5.5','topic_title','unknown',null,
  '{"input_tokens":2400,"cache_write_5m_tokens":0,"cache_write_1h_tokens":0,"cache_read_tokens":0,"output_tokens":64,"web_searches":0,"attempts":1}','10 minutes'),
 -- The TestFlight 92 case: Explain in Chat with no reply; unknown, the input estimated from its bytes, the whole allowance out.
 ('16000000-0000-4000-8002-000000000003',:'FAILED','openrouter','chat','gemini-3.8-flash','chat','unknown',null,
  '{"input_tokens":131878,"cache_write_5m_tokens":0,"cache_write_1h_tokens":0,"cache_read_tokens":0,"output_tokens":10000,"web_searches":0,"attempts":1}','9 minutes'),
 -- Lost, then reconciled from OpenRouter's generation record: the provider's own count.
 ('16000000-0000-4000-8002-000000000004',:'RECON','openrouter','chat','anthropic/claude-sonnet-5.5','chat','reconciled',4000,
  '{"input_tokens":2000,"cache_read_tokens":18000,"output_tokens":300}','8 minutes'),
 -- A rejected round (exactly zero) beside it.
 ('16000000-0000-4000-8002-000000000005',:'RECON','openrouter','chat','anthropic/claude-sonnet-5.5','chat','rejected',0,'{}','8 minutes'),
 -- Units Gradstep estimated, marked so.
 ('16000000-0000-4000-8002-000000000006',:'EST','openrouter','chat','gemini-3.8-flash','chat','succeeded',800,
  '{"input_tokens":5000,"output_tokens":300,"estimated":1}','7 minutes'),
 -- A search reported and one lost.
 ('16000000-0000-4000-8002-000000000007',:'SEARCH','tavily','chat_search','search-basic',null,'succeeded',0,'{"credits":1,"searches":1}','6 minutes'),
 ('16000000-0000-4000-8002-000000000008',:'SEARCH','tavily','chat_search','search-basic',null,'unknown',null,'{"credits":1,"searches":1}','6 minutes'),
 ('16000000-0000-4000-8002-000000000009',:'SEARCH','openrouter','chat','anthropic/claude-sonnet-5.5','chat','succeeded',3000,
  '{"input_tokens":700,"output_tokens":70}','6 minutes'),
 -- Still running.
 ('16000000-0000-4000-8002-00000000000a',:'RUNNING','openrouter','chat','anthropic/claude-sonnet-5.5','study','admitted',null,'{}','5 minutes');
set role service_role;
select public.worker_reserve_operation(:'R',:'ANSWER','chat',sha256('u160answer'),'beta-credits-v1',40,900000);
select public.worker_reserve_operation(:'R',:'FAILED','chat',sha256('u160failed'),'beta-credits-v1',20,900000);
select public.worker_reserve_operation(:'R',:'RECON','chat',sha256('u160recon'),'beta-credits-v1',20,900000);
reset role;
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,state,
 actual_microusd,actual_units,pricing_snapshot,created_at,transport_metadata)
select f.id,:'R',f.op,f.provider,f.route,f.model,sha256(convert_to(f.id::text,'UTF8')),100000,'{}',f.state,f.actual,f.units,'{}',now()-f.age,
 case when f.feature is null then '{}'::jsonb else jsonb_build_object('transport_model',f.model,'endpoint','google-vertex/us','feature',f.feature,'caller','chat') end
from fixture f where f.op in (:'ANSWER',:'FAILED',:'RECON');
set role service_role;
select public.worker_settle_chat(:'R',:'ANSWER',4,9000,'answer','completed',0);
select public.worker_settle_chat(:'R',:'FAILED',0,0,'answer','provider',0);
select public.worker_settle_chat(:'R',:'RECON',2,4000,'answer','completed',0);
select public.worker_reserve_operation(:'R',:'EST','chat',sha256('u160est'),'beta-credits-v1',20,900000);
select public.worker_reserve_operation(:'R',:'SEARCH','chat',sha256('u160search'),'beta-credits-v1',20,900000);
select public.worker_reserve_operation(:'R',:'RUNNING','chat',sha256('u160running'),'beta-credits-v1',30,900000);
reset role;
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,state,
 actual_microusd,actual_units,pricing_snapshot,created_at,transport_metadata)
select f.id,:'R',f.op,f.provider,f.route,f.model,sha256(convert_to(f.id::text,'UTF8')),100000,'{}',f.state,f.actual,f.units,'{}',now()-f.age,
 case when f.feature is null then '{}'::jsonb else jsonb_build_object('transport_model',f.model,'endpoint','google-vertex/us','feature',f.feature,'caller','chat') end
from fixture f where f.op in (:'EST',:'SEARCH',:'RUNNING');
set role service_role;
select public.worker_settle_chat(:'R',:'EST',1,800,'answer','stopped',0);
select public.worker_settle_chat(:'R',:'SEARCH',2,3000,'answer','completed',0);
reset role;
update app_private.metered_operations o set created_at=now()-f.age from (values
 (:'ANSWER'::uuid,interval '10 minutes'),(:'FAILED',interval '9 minutes'),(:'RECON',interval '8 minutes'),(:'EST',interval '7 minutes'),
 (:'SEARCH',interval '6 minutes'),(:'RUNNING',interval '5 minutes')) f(id,age) where o.id=f.id;
create temporary table before_units as select id,state,actual_microusd,actual_units from app_private.provider_attempts where account_id=:'R';

set role authenticated;
select set_config('request.jwt.claim.sub',:'R',false);
select public.v1_ai_usage(7) as w \gset
select public.v1_ai_usage(7,null,null,null,2) as p1 \gset
reset role;
create temporary table r as select :'w'::jsonb w,:'p1'::jsonb p1;
create temporary table rows7 as select x from r,jsonb_array_elements(r.w->'operations') x;
create temporary table parts7 as select x->>'id' op,p from rows7,jsonb_array_elements(x->'parts') p;

-- The failed question: none of its hold estimate is shown as used (0144 showed 131,878 in and 10,000 out); flagged.
select test.assert((select x->>'input_tokens'='0' and x->>'output_tokens'='0' from rows7 where x->>'id'=:'FAILED')
 and (select w->'totals'->>'input_tokens'='3700' and w->'totals'->>'output_tokens'='870' from r),'the hold estimate is not used');
select test.assert((select x->>'outcome'='failed' and x->>'input_tokens'='0' and x->>'output_tokens'='0' and x->>'cached_tokens'='0'
 and x->>'cache_write_tokens'='0' and (x->>'estimated')::boolean and (x->>'pending')::boolean and x->>'unreported_calls'='1' and x->>'calls'='1'
 and x->>'credits'='0' from rows7 where x->>'id'=:'FAILED'),'failed: no tokens from the hold estimate');
select test.assert((select p->>'input_tokens'='0' and p->>'output_tokens'='0' and (p->>'estimated')::boolean and (p->>'pending')::boolean
 and p->>'unreported_calls'='1' from parts7 where op=:'FAILED'),'failed: its part too');
-- A completed answer whose title call was lost: the answer's reported tokens only; the title flagged, still pending.
select test.assert((select x->>'input_tokens'='1000' and x->>'cache_write_tokens'='200' and x->>'cached_tokens'='30000' and x->>'output_tokens'='500'
 and (x->>'estimated')::boolean and x->>'unreported_calls'='1' and x->>'calls'='2' and x->>'credits'='4' and x->>'outcome'='completed'
 from rows7 where x->>'id'=:'ANSWER'),'answer: reported tokens only');
select test.assert((select jsonb_agg(p->>'part'||':'||(p->>'input_tokens')||':'||(p->>'output_tokens')||':'||(p->>'estimated')||':'||(p->>'pending')||':'||(p->>'unreported_calls'))
 from parts7 where op=:'ANSWER')='["answer:1000:500:false:false:0","title:0:0:true:true:1"]'::jsonb,'answer: its parts');
-- Reconciled from the provider's record counts; a rejected round adds exactly zero and is not unreported.
select test.assert((select x->>'input_tokens'='2000' and x->>'cached_tokens'='18000' and x->>'output_tokens'='300' and not (x->>'estimated')::boolean
 and not (x->>'pending')::boolean and x->>'unreported_calls'='0' and x->>'calls'='2' from rows7 where x->>'id'=:'RECON'),'reconciled counts');
-- Units marked estimated are not shown as used.
select test.assert((select x->>'input_tokens'='0' and x->>'output_tokens'='0' and (x->>'estimated')::boolean and not (x->>'pending')::boolean
 and x->>'unreported_calls'='1' and x->>'outcome'='stopped' and x->>'credits'='1' from rows7 where x->>'id'=:'EST'),'estimated units left out');
-- Searches: the reported one only.
select test.assert((select x->>'searches'='1' and x->>'input_tokens'='700' and x->>'unreported_calls'='1' and (x->>'estimated')::boolean
 from rows7 where x->>'id'=:'SEARCH'),'searches: reported only');
select test.assert((select p->>'searches'='1' and p->>'calls'='2' and p->>'unreported_calls'='1' from parts7 where op=:'SEARCH' and p->>'part'='web_search'),
 'search part');
-- Still running: held, nothing counted, flagged.
select test.assert((select x->>'outcome'='in_progress' and x->'credits'='null'::jsonb and x->>'credits_held'='30' and x->>'input_tokens'='0'
 and (x->>'pending')::boolean and (x->>'estimated')::boolean and x->>'unreported_calls'='1' from rows7 where x->>'id'=:'RUNNING'),'running');
-- The window's totals: only what providers reported; credits and holds as before.
select test.assert((select w->'totals'->>'operations'='6' and w->'totals'->>'input_tokens'='3700' and w->'totals'->>'cached_tokens'='48000'
 and w->'totals'->>'cache_write_tokens'='200' and w->'totals'->>'output_tokens'='870' and w->'totals'->>'searches'='1'
 and w->'totals'->>'audio_ms'='0' and w->'totals'->>'credits'='9' and w->'totals'->>'credits_held'='30'
 and w->'totals'->>'unreported_operations'='5' from r),'totals: reported tokens only');
-- The totals equal the sum of the rows (the apps' Day range adds the rows up on the device).
select test.assert((select (w->'totals'->>'input_tokens')::bigint=(select sum((x->>'input_tokens')::bigint) from rows7)
 and (w->'totals'->>'output_tokens')::bigint=(select sum((x->>'output_tokens')::bigint) from rows7)
 and (w->'totals'->>'cached_tokens')::bigint=(select sum((x->>'cached_tokens')::bigint) from rows7) from r),'totals are the rows'' sum');
-- Backward compatible: every key TestFlight 92 and the browser decode is present with its type; the fields are added.
select test.assert((select bool_and(jsonb_typeof(x->'input_tokens')='number' and jsonb_typeof(x->'cached_tokens')='number'
 and jsonb_typeof(x->'cache_write_tokens')='number' and jsonb_typeof(x->'output_tokens')='number' and jsonb_typeof(x->'searches')='number'
 and jsonb_typeof(x->'audio_ms')='number' and jsonb_typeof(x->'calls')='number' and jsonb_typeof(x->'credits_held')='number'
 and jsonb_typeof(x->'estimated')='boolean' and jsonb_typeof(x->'pending')='boolean' and jsonb_typeof(x->'parts')='array'
 and jsonb_typeof(x->'unreported_calls')='number') from rows7),'row keys');
select test.assert((select bool_and(jsonb_typeof(p->'input_tokens')='number' and jsonb_typeof(p->'cached_tokens')='number'
 and jsonb_typeof(p->'cache_write_tokens')='number' and jsonb_typeof(p->'output_tokens')='number' and jsonb_typeof(p->'searches')='number'
 and jsonb_typeof(p->'audio_ms')='number' and jsonb_typeof(p->'calls')='number' and jsonb_typeof(p->'model')='string'
 and jsonb_typeof(p->'estimated')='boolean' and jsonb_typeof(p->'pending')='boolean' and jsonb_typeof(p->'unreported_calls')='number') from parts7),'part keys');
select test.assert((select (select array_agg(k order by k) from jsonb_object_keys(w->'totals') k)
 =array['audio_ms','cache_write_tokens','cached_tokens','credits','credits_held','input_tokens','operations','output_tokens','searches','unreported_operations']
 from r),'totals keys');
select test.assert((select (select array_agg(k order by k) from jsonb_object_keys(w) k)
 =array['activities','activity','days','generated_at','limit','next','operations','since','totals'] from r),'page keys');
-- Pages still carry totals on the first page only and the same rows.
select test.assert((select jsonb_array_length(p1->'operations')=2 and p1->'totals'=w->'totals' and jsonb_typeof(p1->'next')='object' from r),'first page');
-- The rule itself.
select test.assert(app_private.usage_reported('succeeded','{"input_tokens":1}') and app_private.usage_reported('reconciled','{}')
 and app_private.usage_reported('rejected','{}') and not app_private.usage_reported('unknown','{"input_tokens":1}')
 and not app_private.usage_reported('admitted','{}') and not app_private.usage_reported('succeeded','{"estimated":1}')
 and app_private.usage_reported('succeeded','{"estimated":0}') and not app_private.usage_reported(null,'{}'),'reported: the provider''s own count');
select test.assert(not has_function_privilege('authenticated','app_private.usage_reported(text,jsonb)','execute')
 and not has_function_privilege('anon','app_private.usage_reported(text,jsonb)','execute')
 and not has_function_privilege('authenticated','app_private.usage_operations(uuid,timestamptz)','execute'),'helpers stay private');
select test.assert(has_function_privilege('authenticated','public.v1_ai_usage(integer,text,timestamptz,uuid,integer)','execute')
 and not has_function_privilege('anon','public.v1_ai_usage(integer,text,timestamptz,uuid,integer)','execute'),'the RPC''s reach is unchanged');

-- Read only: the attempts are as they were.
select test.assert((select count(*)=0 from before_units b join app_private.provider_attempts p on p.id=b.id
 where (p.state,p.actual_microusd,p.actual_units) is distinct from (b.state,b.actual_microusd,b.actual_units)),'read only');
rollback;
