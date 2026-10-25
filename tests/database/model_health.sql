-- 0161: model health over the last 24 hours (calls, answered share, failures by code, p90 time to first output) with its
-- attention items; `first_data_ms` accepted in a finished attempt's units; and Your AI usage naming the fallback that wrote
-- an answer rather than the chosen model that failed before it. Synthetic local SQL.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set R '16100000-0000-4000-8000-00000000000a'
\set FELL '16100000-0000-4000-8001-000000000001'
\set BULK '16100000-0000-4000-8001-000000000002'
insert into auth.users(id,email,email_confirmed_at) values(:'R','model-health-161@example.test',now());
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'R','adjustment','model-health-161-r',1000,now()-interval '60 days',null,'Model health fixture');

-- The validator: first_data_ms is a provider unit like the others (a whole number); nothing else new is accepted.
select test.assert(app_private.valid_provider_units('{"input_tokens":10,"output_tokens":2,"first_data_ms":2450}'),'first_data_ms accepted');
select test.assert(not app_private.valid_provider_units('{"first_data_ms":-1}'),'negative refused');
select test.assert(not app_private.valid_provider_units('{"first_data_ms":"fast"}'),'text refused');
select test.assert(not app_private.valid_provider_units('{"first_text_ms":10}'),'an unknown unit still refused');

set role service_role;
select public.worker_reserve_operation(:'R',:'FELL','chat',sha256('m161fell'),'beta-credits-v1',40,900000);
select public.worker_reserve_operation(:'R',:'BULK','chat',sha256('m161bulk'),'beta-credits-v1',40,900000);
reset role;

-- The fallback: Flash refused 429 before writing (exactly zero), then Haiku wrote the answer.
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,state,
 actual_microusd,actual_units,failure_code,pricing_snapshot,created_at,dispatched_at,finished_at,transport_metadata) values
 ('16100000-0000-4000-8002-000000000001',:'R',:'FELL','openrouter','chat','gemini-3.8-flash',sha256('a1'),100000,'{}','rejected',0,'{}','provider_error','{}',
  now()-interval '10 minutes',now()-interval '10 minutes',now()-interval '10 minutes'+interval '2 seconds',
  '{"transport_model":"google/gemini-3.8-flash","endpoint":"google-vertex/us","feature":"figure","caller":"chat"}'),
 ('16100000-0000-4000-8002-000000000002',:'R',:'FELL','openrouter','chat','anthropic/claude-haiku-5.5',sha256('a2'),100000,'{}','succeeded',1500,
  '{"input_tokens":2300,"cache_read_tokens":49000,"output_tokens":1200,"first_data_ms":1800}',null,'{}',
  now()-interval '10 minutes'+interval '2 seconds',now()-interval '10 minutes'+interval '2 seconds',now()-interval '10 minutes'+interval '9 seconds',
  '{"transport_model":"anthropic/claude-haiku-5.5","endpoint":"google-vertex/us","feature":"figure","caller":"chat"}');

-- Twenty more Flash calls in the window: 14 answered (first output 2–34 s), 3 refused 429, a stall (unknown), one the
-- reader left (not the model's) and one refused for the balance (not the model's). Haiku: 12 answered, quick.
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,state,
 actual_microusd,actual_units,failure_code,pricing_snapshot,created_at,dispatched_at,finished_at,transport_metadata)
select ('16100000-0000-4000-8003-'||lpad(n::text,12,'0'))::uuid,:'R',:'BULK','openrouter','chat',m,sha256(convert_to('b'||n,'UTF8')),100000,'{}',st,
 case when st='succeeded' then 5000 when st='rejected' then 0 end,
 case when st='succeeded' then jsonb_build_object('output_tokens',500,'first_data_ms',fd) else '{}'::jsonb end,fc,'{}',
 now()-interval '1 hour',now()-interval '1 hour',now()-interval '1 hour'+make_interval(secs=>coalesce(fd,0)/1000.0+5),
 jsonb_build_object('transport_model',m,'endpoint','google-vertex/us','feature','chat','caller','chat')
from (values
 (1,'gemini-3.8-flash','succeeded',null,2000),(2,'gemini-3.8-flash','succeeded',null,3000),(3,'gemini-3.8-flash','succeeded',null,4000),
 (4,'gemini-3.8-flash','succeeded',null,5000),(5,'gemini-3.8-flash','succeeded',null,6000),(6,'gemini-3.8-flash','succeeded',null,7000),
 (7,'gemini-3.8-flash','succeeded',null,8000),(8,'gemini-3.8-flash','succeeded',null,9000),(9,'gemini-3.8-flash','succeeded',null,11000),
 (10,'gemini-3.8-flash','succeeded',null,12000),(11,'gemini-3.8-flash','succeeded',null,18900),(12,'gemini-3.8-flash','succeeded',null,24000),
 (13,'gemini-3.8-flash','succeeded',null,30000),(14,'gemini-3.8-flash','succeeded',null,34000),
 (15,'gemini-3.8-flash','rejected','provider_error',null),(16,'gemini-3.8-flash','rejected','provider_error',null),
 (17,'gemini-3.8-flash','rejected','provider_error',null),(18,'gemini-3.8-flash','unknown','provider_error',null),
 (19,'gemini-3.8-flash','unknown','aborted',null),(20,'gemini-3.8-flash','rejected','provider_billing',null),
 (21,'anthropic/claude-haiku-5.5','succeeded',null,900),(22,'anthropic/claude-haiku-5.5','succeeded',null,1000),
 (23,'anthropic/claude-haiku-5.5','succeeded',null,1100),(24,'anthropic/claude-haiku-5.5','succeeded',null,1200),
 (25,'anthropic/claude-haiku-5.5','succeeded',null,1300),(26,'anthropic/claude-haiku-5.5','succeeded',null,1400),
 (27,'anthropic/claude-haiku-5.5','succeeded',null,1500),(28,'anthropic/claude-haiku-5.5','succeeded',null,1600),
 (29,'anthropic/claude-haiku-5.5','succeeded',null,1700),(30,'anthropic/claude-haiku-5.5','succeeded',null,1800),
 (31,'anthropic/claude-haiku-5.5','succeeded',null,2000),(32,'anthropic/claude-haiku-5.5','succeeded',null,2600)) v(n,m,st,fc,fd);
-- Outside the window, a day and a half ago: not counted.
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,state,
 actual_microusd,actual_units,failure_code,pricing_snapshot,created_at,transport_metadata)
select ('16100000-0000-4000-8004-'||lpad(n::text,12,'0'))::uuid,:'R',:'BULK','openrouter','chat','deepseek/deepseek-v4.1-flash-1017',
 sha256(convert_to('c'||n,'UTF8')),100000,'{}','rejected',0,'{}','provider_error','{}',now()-interval '36 hours','{}'
from generate_series(1,12) n;

select app_private.model_health(24) h \gset
create temporary table h as select :'h'::jsonb h;
create temporary table hm as select x from h,jsonb_array_elements(h->'models') x;
select test.assert((select h->'thresholds'='{"min_calls":10,"success_rate":0.90,"p90_first_data_ms":20000}'::jsonb and h->>'window_hours'='24' from h),'thresholds');
-- Flash: 19 calls are the model's (14 answered; 3 refused 429, the stall and the 429 before the fallback failed); the one the
-- reader left and the balance refusal are counted apart.
select test.assert((select x->>'calls'='19' and x->>'answered'='14' and x->>'failed'='5' and x->>'other'='2' and x->>'success_rate'='0.7368'
 and x->'failures'='{"aborted":1,"provider_billing":1,"provider_error":5}'::jsonb and x->>'timed'='14'
 from hm where x->>'model'='gemini-3.8-flash'),'flash counts');
select test.assert((select x->>'p90_first_data_ms'='30000' and x->>'p50_first_data_ms'='8000' from hm where x->>'model'='gemini-3.8-flash'),'flash p50/p90 first data');
select test.assert((select x->>'calls'='13' and x->>'answered'='13' and x->>'failed'='0' and x->>'success_rate'='1.0000' and x->>'timed'='13'
 and x->>'p90_first_data_ms'='2000' and x->'failures'='{}'::jsonb from hm where x->>'model'='anthropic/claude-haiku-5.5'),'haiku counts');
select test.assert((select count(*)=0 from hm where x->>'model' like 'deepseek/%'),'outside the window: not counted');
-- Attention: Flash under 90 % and slow to start; Haiku neither.
select test.assert((select jsonb_agg(a->>'kind'||':'||(a->>'model') order by a->>'kind') from h,jsonb_array_elements(h->'attention') a)
 ='["model_slow_start:gemini-3.8-flash","model_success_rate:gemini-3.8-flash"]'::jsonb,'attention items');
-- Under ten calls: no verdict, however they went.
select test.assert((select jsonb_array_length(app_private.model_health(1)->'attention')=0),'one hour: the 10-minute calls are too few for a verdict');
-- Health carries it; the worker's reader is the service role's only.
select test.assert((select app_private.admin_health_extra()->'models'->'thresholds'->>'min_calls'='10'),'Health extras carry models');
select test.assert(has_function_privilege('service_role','public.worker_model_health(integer)','execute')
 and not has_function_privilege('authenticated','public.worker_model_health(integer)','execute')
 and not has_function_privilege('anon','public.worker_model_health(integer)','execute'),'worker_model_health grants');

-- Your AI usage: the answer whose chosen model failed before writing is named by the fallback that wrote it.
set role service_role;
select public.worker_settle_chat(:'R',:'FELL',1,1500,'figure','completed',0);
reset role;
update app_private.metered_operations set created_at=now()-interval '10 minutes' where id=:'FELL';
set role authenticated;
select set_config('request.jwt.claim.sub',:'R',false);
select public.v1_ai_usage(7) as w \gset
reset role;
select test.assert((select x->>'model'='anthropic/claude-haiku-5.5' and x->>'calls'='2' and x->>'output_tokens'='1200' and x->>'outcome'='completed'
 from jsonb_array_elements(:'w'::jsonb->'operations') x where x->>'id'=:'FELL'),'the fallback that answered names the row');
select test.assert((select jsonb_agg(p->>'model' order by p->>'model') from jsonb_array_elements(:'w'::jsonb->'operations') x,jsonb_array_elements(x->'parts') p
 where x->>'id'=:'FELL')='["anthropic/claude-haiku-5.5","gemini-3.8-flash"]'::jsonb,'both calls are its parts');
rollback;
