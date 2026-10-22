-- 0144 (owner 2026-10-22): Your AI usage. A reader's own metered operations, newest first, one row per operation, with
-- its activity, outcome, credits and the tokens of each part; keyset pages; totals for the window; a second account
-- sees nothing of the first. Synthetic local SQL.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set A '14400000-0000-4000-8000-00000000000a'
\set B '14400000-0000-4000-8000-00000000000b'
\set E '14400000-0000-4000-8000-00000000000e'
\set CHAT '14400000-0000-4000-8001-000000000001'
\set FIG '14400000-0000-4000-8001-000000000002'
\set STOP '14400000-0000-4000-8001-000000000003'
\set EQ '14400000-0000-4000-8001-000000000004'
\set STUDY '14400000-0000-4000-8001-000000000005'
\set POD '14400000-0000-4000-8001-000000000006'
\set TAGS '14400000-0000-4000-8001-000000000007'
\set LOOKUP '14400000-0000-4000-8001-000000000008'
\set OLD '14400000-0000-4000-8001-000000000009'
\set REC '14400000-0000-4000-8001-00000000000a'
\set BCHAT '14400000-0000-4000-8001-0000000000b1'
insert into auth.users(id,email,email_confirmed_at) values(:'A','usage-a-144@example.test',now()),(:'B','usage-b-144@example.test',now()),
 (:'E','usage-empty-144@example.test',now());
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','usage-144-a',1000,now()-interval '60 days',null,'Usage fixture');
select public.worker_grant_credits(:'B','adjustment','usage-144-b',1000,now()-interval '60 days',null,'Usage fixture');

-- Access: signed-in readers only; helpers private; a bounded, validated query.
select test.assert(has_function_privilege('authenticated','public.v1_ai_usage(integer,text,timestamptz,uuid,integer)','execute'),'signed-in callers may ask');
select test.assert(not has_function_privilege('anon','public.v1_ai_usage(integer,text,timestamptz,uuid,integer)','execute'),'never anonymous');
select test.assert(not has_function_privilege('authenticated','app_private.usage_operations(uuid,timestamptz)','execute')
 and not has_function_privilege('authenticated','app_private.usage_parts(uuid,uuid)','execute')
 and not has_function_privilege('authenticated','app_private.usage_activity(text,text,text[],text[])','execute')
 and not has_function_privilege('authenticated','app_private.usage_part(text,text)','execute'),'helpers are private');
-- No caller-chosen account: the only uuid parameter is the cursor.
select test.assert((select count(*)=1 from pg_proc where proname='v1_ai_usage'
 and pronamespace='public'::regnamespace and prosecdef),'one security-definer function');
set role authenticated;
select set_config('request.jwt.claim.sub','',false);
select test.reject('select public.v1_ai_usage()','authentication_required');
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject('select public.v1_ai_usage(0)','invalid_usage_query');
select test.reject('select public.v1_ai_usage(367)','invalid_usage_query');
select test.reject('select public.v1_ai_usage(30,null,null,null,51)','invalid_usage_query');
select test.reject('select public.v1_ai_usage(30,''everything'')','invalid_usage_query');
select test.reject('select public.v1_ai_usage(30,null,now(),null)','invalid_usage_query');
select public.v1_ai_usage() as empty_a \gset
reset role;
select test.assert((:'empty_a'::jsonb->'operations')='[]'::jsonb and (:'empty_a'::jsonb->'totals'->>'operations')::int=0
 and (:'empty_a'::jsonb->'next')='null'::jsonb and (:'empty_a'::jsonb->'activities')='[]'::jsonb,'nothing yet');

-- The ledger, as the chat, podcast, recommend and tags paths write it (attempts inserted directly to fix their shapes).
-- At most three operations of an account are open at once, so each group is reserved, used and settled in turn.
create temporary table fixture(id uuid,account uuid,op uuid,provider text,route text,model text,feature text,state text,actual bigint,units jsonb,age interval);
insert into fixture values
 -- Paper or general chat: the answer, its title and suggestions (Haiku), one web search.
 ('14400000-0000-4000-8002-000000000001',:'A',:'CHAT','openrouter','chat','anthropic/claude-sonnet-5.5','chat','succeeded',9000,
  '{"input_tokens":900,"cache_read_tokens":20000,"cache_write_5m_tokens":100,"output_tokens":700,"attempts":1}','10 minutes'),
 ('14400000-0000-4000-8002-000000000002',:'A',:'CHAT','openrouter','chat','anthropic/claude-haiku-5.5','topic_title','succeeded',100,
  '{"input_tokens":200,"output_tokens":10}','10 minutes'),
 ('14400000-0000-4000-8002-000000000003',:'A',:'CHAT','openrouter','chat','anthropic/claude-haiku-5.5','suggest_follow_ups','succeeded',200,
  '{"input_tokens":400,"output_tokens":40}','10 minutes'),
 ('14400000-0000-4000-8002-000000000004',:'A',:'CHAT','tavily','chat_search','search-basic',null,'succeeded',0,'{"credits":1,"searches":1}','10 minutes'),
 ('14400000-0000-4000-8002-000000000005',:'A',:'CHAT','openrouter','chat','anthropic/claude-sonnet-5.5','chat','denied',null,'{}','10 minutes'),
 -- Figure explainer.
 ('14400000-0000-4000-8002-000000000006',:'A',:'FIG','openrouter','chat','anthropic/claude-sonnet-5.5','figure','succeeded',20000,
  '{"input_tokens":3000,"cache_read_tokens":40000,"output_tokens":1200}','9 minutes'),
 -- A stopped answer (charged for the part written), with an estimated usage.
 ('14400000-0000-4000-8002-000000000007',:'A',:'STOP','openrouter','chat','gemini-3.8-flash','chat','succeeded',800,
  '{"input_tokens":5000,"output_tokens":300,"estimated":1}','8 minutes'),
 -- An equation explainer the provider failed: not charged.
 ('14400000-0000-4000-8002-000000000008',:'A',:'EQ','openrouter','chat','deepseek/deepseek-v4.1-flash-1017','equation','rejected',0,'{}','7 minutes'),
 -- A Study turn still running.
 ('14400000-0000-4000-8002-000000000009',:'A',:'STUDY','openrouter','chat','anthropic/claude-sonnet-5.5','study','admitted',null,'{}','6 minutes'),
 -- A private podcast: script, review, audio.
 ('14400000-0000-4000-8002-00000000000a',:'A',:'POD','openrouter','podcast_script','anthropic/claude-sonnet-5.5','podcast_script','succeeded',90000,
  '{"input_tokens":30000,"output_tokens":5000}','5 minutes'),
 ('14400000-0000-4000-8002-00000000000b',:'A',:'POD','openrouter','podcast_review','anthropic/claude-sonnet-5.5','podcast_review','succeeded',30000,
  '{"input_tokens":8000,"output_tokens":600}','5 minutes'),
 ('14400000-0000-4000-8002-00000000000c',:'A',:'POD','openrouter','podcast_speech','gemini-3.8-flash-tts','podcast_speech','succeeded',150000,
  '{"text_input_tokens":4000,"audio_output_tokens":60000,"audio_ms":300000}','5 minutes'),
 -- Tags for a paper this reader added: paid by Gradstep.
 ('14400000-0000-4000-8002-00000000000d',:'A',:'TAGS','openrouter','catalog_tags','anthropic/claude-haiku-5.5','catalog_tags','succeeded',340,
  '{"input_tokens":1500,"output_tokens":60}','4 minutes'),
 -- Recommendations: one Haiku call; nothing added, so nothing charged.
 ('14400000-0000-4000-8002-00000000000e',:'A',:'REC','openrouter','chat','anthropic/claude-haiku-5.5','recommend','succeeded',900,
  '{"input_tokens":4000,"output_tokens":200}','3 minutes'),
 -- Forty days ago.
 ('14400000-0000-4000-8002-00000000000f',:'A',:'OLD','openrouter','chat','anthropic/claude-sonnet-5.5','chat','succeeded',5000,
  '{"input_tokens":100,"output_tokens":100}','40 days'),
 -- The other reader.
 ('14400000-0000-4000-8002-000000000010',:'B',:'BCHAT','openrouter','chat','anthropic/claude-sonnet-5.5','chat','succeeded',5000,
  '{"input_tokens":777,"output_tokens":77}','2 minutes');
set role service_role;
select public.worker_reserve_operation(:'A',:'CHAT','chat',sha256('u144chat'),'beta-credits-v1',40,900000);
select public.worker_reserve_operation(:'A',:'FIG','chat',sha256('u144fig'),'beta-credits-v1',20,900000);
select public.worker_reserve_operation(:'A',:'STOP','chat',sha256('u144stop'),'beta-credits-v1',20,900000);
reset role;
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,state,
 actual_microusd,actual_units,pricing_snapshot,created_at,transport_metadata)
select f.id,f.account,f.op,f.provider,f.route,f.model,sha256(convert_to(f.id::text,'UTF8')),100000,'{}',f.state,f.actual,f.units,'{}',now()-f.age,
 case when f.feature is null then '{}'::jsonb else jsonb_build_object('transport_model',f.model,'endpoint','google-vertex/us','feature',f.feature,'caller','chat') end
from fixture f where f.op in (:'CHAT',:'FIG',:'STOP');
set role service_role;
select public.worker_settle_chat(:'A',:'CHAT',4,9300,'answer','completed',0);
select public.worker_settle_chat(:'A',:'FIG',3,20000,'figure','completed',0);
select public.worker_settle_chat(:'A',:'STOP',1,800,'answer','stopped',0);
reset role;
set role service_role;
select public.worker_reserve_operation(:'A',:'EQ','chat',sha256('u144eq'),'beta-credits-v1',20,900000);
select public.worker_reserve_operation(:'A',:'POD','podcast',sha256('u144pod'),'beta-credits-v1',150,1000000);
select public.worker_reserve_operation(:'A',:'TAGS','metadata',sha256('u144tags'),'beta-credits-v1',0,10000);
reset role;
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,state,
 actual_microusd,actual_units,pricing_snapshot,created_at,transport_metadata)
select f.id,f.account,f.op,f.provider,f.route,f.model,sha256(convert_to(f.id::text,'UTF8')),100000,'{}',f.state,f.actual,f.units,'{}',now()-f.age,
 case when f.feature is null then '{}'::jsonb else jsonb_build_object('transport_model',f.model,'endpoint','google-vertex/us','feature',f.feature,'caller','chat') end
from fixture f where f.op in (:'EQ',:'POD',:'TAGS');
set role service_role;
select public.worker_settle_chat(:'A',:'EQ',0,0,'equation','provider',0);
select public.worker_settle_operation(:'A',:'POD',55,270000);
select public.worker_settle_operation(:'A',:'TAGS',0,340);
reset role;
set role service_role;
select public.worker_reserve_operation(:'A',:'LOOKUP','metadata',sha256('u144lookup'),'beta-credits-v1',0,0);
select public.worker_reserve_operation(:'A',:'OLD','chat',sha256('u144old'),'beta-credits-v1',20,900000);
select public.worker_reserve_operation(:'A',:'REC','recommend',sha256('u144rec'),'beta-credits-v1',1,20000);
reset role;
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,state,
 actual_microusd,actual_units,pricing_snapshot,created_at,transport_metadata)
select f.id,f.account,f.op,f.provider,f.route,f.model,sha256(convert_to(f.id::text,'UTF8')),100000,'{}',f.state,f.actual,f.units,'{}',now()-f.age,
 case when f.feature is null then '{}'::jsonb else jsonb_build_object('transport_model',f.model,'endpoint','google-vertex/us','feature',f.feature,'caller','chat') end
from fixture f where f.op in (:'LOOKUP',:'OLD',:'REC');
set role service_role;
select public.worker_settle_operation(:'A',:'LOOKUP',0,0);
select public.worker_settle_chat(:'A',:'OLD',2,5000,'answer','completed',0);
select public.worker_settle_operation(:'A',:'REC',0,900);
reset role;
set role service_role;
select public.worker_reserve_operation(:'A',:'STUDY','chat',sha256('u144study'),'beta-credits-v1',30,900000);
select public.worker_reserve_operation(:'B',:'BCHAT','chat',sha256('u144b'),'beta-credits-v1',20,900000);
reset role;
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,state,
 actual_microusd,actual_units,pricing_snapshot,created_at,transport_metadata)
select f.id,f.account,f.op,f.provider,f.route,f.model,sha256(convert_to(f.id::text,'UTF8')),100000,'{}',f.state,f.actual,f.units,'{}',now()-f.age,
 case when f.feature is null then '{}'::jsonb else jsonb_build_object('transport_model',f.model,'endpoint','google-vertex/us','feature',f.feature,'caller','chat') end
from fixture f where f.op in (:'STUDY',:'BCHAT');
set role service_role;
select public.worker_settle_chat(:'B',:'BCHAT',2,5000,'answer','completed',0);
reset role;
-- Times as the ledger would have them, for a fixed order.
update app_private.metered_operations o set created_at=now()-f.age from (values
 (:'CHAT'::uuid,interval '10 minutes'),(:'FIG',interval '9 minutes'),(:'STOP',interval '8 minutes'),(:'EQ',interval '7 minutes'),
 (:'STUDY',interval '6 minutes'),(:'POD',interval '5 minutes'),(:'TAGS',interval '4 minutes'),(:'LOOKUP',interval '3 minutes 30 seconds'),
 (:'REC',interval '3 minutes'),(:'OLD',interval '40 days'),(:'BCHAT',interval '2 minutes')) f(id,age) where o.id=f.id;
create temporary table before_counts as select (select count(*) from app_private.metered_operations) ops,(select count(*) from app_private.provider_attempts) atts,
 (select count(*) from app_private.credit_ledger) ledger;

-- Pure helpers.
select test.assert(app_private.usage_part('chat','topic_title')='title' and app_private.usage_part('chat','suggest_follow_ups')='suggestions'
 and app_private.usage_part('chat','update_study_map')='study_map' and app_private.usage_part('chat','figure')='answer'
 and app_private.usage_part('chat_search',null)='web_search' and app_private.usage_part('podcast_speech','podcast_speech')='podcast_audio'
 and app_private.usage_part('podcast_script_repair',null)='podcast_review' and app_private.usage_part('catalog_tags',null)='tags','parts');
select test.assert(app_private.usage_activity('chat','figure_detail','{}','{}')='figure_explainer'
 and app_private.usage_activity('chat',null,'{equation_background}','{chat}')='equation_explainer'
 and app_private.usage_activity('chat','answer','{chat,topic_title}','{chat}')='chat'
 and app_private.usage_activity('chat',null,'{update_study_map}','{chat}')='study'
 and app_private.usage_activity('chat','related','{}','{}')='related_papers' and app_private.usage_activity('chat','relevance','{}','{}')='why_it_matters'
 and app_private.usage_activity('chat','ingest','{}','{}')='add_paper' and app_private.usage_activity('chat','diagram_fix','{}','{}')='diagram_repair'
 and app_private.usage_activity('podcast',null,'{}','{}')='podcast' and app_private.usage_activity('recommend',null,'{}','{}')='recommendations'
 and app_private.usage_activity('metadata',null,'{}','{catalog_tags}')='tags' and app_private.usage_activity('metadata',null,'{}','{reference_lookup}')='paper_lookup'
 and app_private.usage_activity('ocr',null,'{}','{}')='paper_ocr' and app_private.usage_activity('nothing',null,'{}','{}')='other','activities');

set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v1_ai_usage(30) as a30 \gset
select public.v1_ai_usage(90) as a90 \gset
select public.v1_ai_usage(30,'chat') as achat \gset
select public.v1_ai_usage(30,null,null,null,3) as p1 \gset
select public.v1_ai_usage(30,null,(:'p1'::jsonb->'next'->>'created_at')::timestamptz,(:'p1'::jsonb->'next'->>'id')::uuid,3) as p2 \gset
select public.v1_ai_usage(30,null,(:'p2'::jsonb->'next'->>'created_at')::timestamptz,(:'p2'::jsonb->'next'->>'id')::uuid,3) as p3 \gset
select set_config('request.jwt.claim.sub',:'B',false);
select public.v1_ai_usage(366) as b \gset
select set_config('request.jwt.claim.sub',:'E',false);
select public.v1_ai_usage(366) as e \gset
reset role;
create temporary table r as select :'a30'::jsonb a30,:'a90'::jsonb a90,:'achat'::jsonb achat,:'p1'::jsonb p1,:'p2'::jsonb p2,:'p3'::jsonb p3,:'b'::jsonb b,:'e'::jsonb e;
create temporary table rows30 as select x,ord from r,jsonb_array_elements(r.a30->'operations') with ordinality e(x,ord);

-- Newest first; the free lookup that reached no provider and the 40-day-old answer are not in the last 30 days.
select test.assert((select array_agg(x->>'id' order by ord) from rows30)=array[:'REC',:'TAGS',:'POD',:'STUDY',:'EQ',:'STOP',:'FIG',:'CHAT'],'order and window');
select test.assert((select array_agg(x->>'activity' order by ord) from rows30)
 =array['recommendations','tags','podcast','study','equation_explainer','chat','figure_explainer','chat'],'activities');
select test.assert((select array_agg(x->>'outcome' order by ord) from rows30)
 =array['not_charged','free','completed','in_progress','failed','stopped','completed','completed'],'outcomes');
-- The answer: credits, the answering model, tokens summed over answer, title and suggestions; the search counted; the denied call ignored.
select test.assert((select x->>'credits'='4' and x->>'credits_held'='0' and x->>'model'='anthropic/claude-sonnet-5.5' and x->>'calls'='4'
 and x->>'input_tokens'='1500' and x->>'cached_tokens'='20000' and x->>'cache_write_tokens'='100' and x->>'output_tokens'='750'
 and x->>'searches'='1' and x->>'paid_by'='you' and x->>'ending'='completed' and x->>'action'='answer' and not (x->>'estimated')::boolean
 from rows30 where x->>'id'=:'CHAT'),'the answer row');
select test.assert((select jsonb_agg(p->>'part'||':'||(p->>'model')||':'||(p->>'output_tokens') order by o) from rows30,jsonb_array_elements(x->'parts') with ordinality q(p,o)
 where x->>'id'=:'CHAT')='["answer:anthropic/claude-sonnet-5.5:700","suggestions:anthropic/claude-haiku-5.5:40","title:anthropic/claude-haiku-5.5:10","web_search:search-basic:0"]'::jsonb,
 'the answer''s parts');
select test.assert((select (x->>'estimated')::boolean and x->>'credits'='1' and x->>'model'='gemini-3.8-flash' from rows30 where x->>'id'=:'STOP'),'stopped and estimated');
select test.assert((select x->>'credits'='0' and x->>'ending'='provider' and x->>'calls'='1' from rows30 where x->>'id'=:'EQ'),'failed: not charged');
select test.assert((select x->'credits'='null'::jsonb and x->>'credits_held'='30' and (x->>'pending')::boolean from rows30 where x->>'id'=:'STUDY'),'in progress: held, not charged');
select test.assert((select x->>'credits'='55' and x->>'input_tokens'='42000' and x->>'output_tokens'='65600' and x->>'audio_ms'='300000'
 and jsonb_array_length(x->'parts')=3 from rows30 where x->>'id'=:'POD'),'podcast: script, review and audio');
select test.assert((select x->>'paid_by'='gradstep' and x->>'credits'='0' from rows30 where x->>'id'=:'TAGS'),'tags paid by Gradstep');
-- Totals over the whole window; activities for the filter chips.
select test.assert((select a30->'totals'->>'operations'='8' and a30->'totals'->>'credits'='63' and a30->'totals'->>'credits_held'='30'
 and a30->'totals'->>'searches'='1' from r),'totals');
select test.assert((select jsonb_object_agg(x->>'activity',(x->>'operations')::int) from r,jsonb_array_elements(r.a30->'activities') x)
 ='{"chat":2,"figure_explainer":1,"equation_explainer":1,"study":1,"podcast":1,"tags":1,"recommendations":1}'::jsonb,'activities present');
select test.assert((select (a30->'activities'->0->>'activity')='podcast' from r),'activities by credits');
-- 90 days include the old answer.
select test.assert((select a90->'totals'->>'operations'='9' and a90->'totals'->>'credits'='65' from r),'a longer window');
-- The activity filter, with its own totals.
select test.assert((select (select array_agg(x->>'id') from jsonb_array_elements(achat->'operations') x)=array[:'STOP',:'CHAT']
 and achat->'totals'->>'credits'='5' and achat->>'activity'='chat' from r),'filtered');
-- Pages: three, no repeats, no gaps, totals only on the first.
select test.assert((select jsonb_array_length(p1->'operations')=3 and jsonb_array_length(p2->'operations')=3 and jsonb_array_length(p3->'operations')=2
 and p3->'next'='null'::jsonb and p1->'totals' is not null and p2->'totals'='null'::jsonb from r),'page sizes');
select test.assert((select array_agg(x->>'id' order by ord) from r,jsonb_array_elements((p1->'operations')||(p2->'operations')||(p3->'operations')) with ordinality e(x,ord))
 =(select array_agg(x->>'id' order by ord) from rows30),'pages cover the list in order');
-- The other reader sees only their own; an account with nothing sees nothing.
select test.assert((select jsonb_array_length(b->'operations')=1 and b->'operations'->0->>'id'=:'BCHAT' and b->'totals'->>'credits'='2'
 and b->'operations'->0->>'input_tokens'='777' from r),'B sees only B');
select test.assert((select not exists(select 1 from jsonb_array_elements(b->'operations') x where x->>'id'<>:'BCHAT') from r),'nothing of A');
select test.assert((select e->'operations'='[]'::jsonb and e->'totals'->>'operations'='0' from r),'an empty account');
-- Nothing in the reply names a paper, a prompt, a provider request or dollars.
select test.assert((select r.a30::text !~ '(microusd|provider_request|request_sha|transport|prompt|document|email)' from r),'no private or dollar fields');
-- Read only, apart from the request rate.
select test.assert((select ops=(select count(*) from app_private.metered_operations) and atts=(select count(*) from app_private.provider_attempts)
 and ledger=(select count(*) from app_private.credit_ledger) from before_counts),'read only');
select test.assert(exists(select 1 from app_private.api_rate_windows where route='account-usage' and scope_id=:'A'),'rate counted per account');
-- A closed account cannot read.
update app_private.accounts set closed_at=now() where id=:'E';
set role authenticated;
select set_config('request.jwt.claim.sub',:'E',false);
select test.reject('select public.v1_ai_usage()','authentication_required');
reset role;
rollback;
