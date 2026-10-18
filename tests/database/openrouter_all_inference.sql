-- Exact dispatch authority, account attribution, audit privacy, successor podcast arithmetic.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(sql text,expected text) returns void language plpgsql as $$
begin execute sql; raise exception 'did_not_reject'; exception when others then
 if sqlerrm not like '%'||expected||'%' then raise exception 'Expected %, got %',expected,sqlerrm; end if; end $$;
grant usage on schema test to service_role,authenticated,anon;
grant execute on all functions in schema test to service_role,authenticated,anon;
\set A '89000000-0000-4000-8000-000000000001'
\set B '89000000-0000-4000-8000-000000000002'
\set O '89000000-0000-4000-8001-000000000001'
\set T '89000000-0000-4000-8002-000000000001'
\set D '89000000-0000-4000-8002-000000000002'
\set M '{"transport_model":"anthropic/claude-haiku-5.5","endpoint":"google-vertex/us","feature":"chat_title","caller":"chat"}'
insert into auth.users(id,email) values(:'A','router-89@gradstep.test.org'),(:'B','router-other-89@gradstep.test.org');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','router-89',1000,now()-interval '1 day',null,'OpenRouter fixture');
set role service_role;
select public.worker_reserve_operation(:'A',:'O','chat',sha256('router89'),'beta-credits-v1',40,200000);
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',:'T','openrouter','chat','anthropic/claude-haiku-5.5',sha256('title'),3000,'{"output_tokens":40}')->>'granted')::boolean,'admission is available');
select test.assert(not public.worker_openrouter_dispatch(:'B',:'O',:'T',:'M'),'another account cannot dispatch the attempt');
select test.reject(format('select public.worker_openrouter_dispatch(%L,%L,%L,%L)',:'A',:'O',:'T',(:'M'::jsonb||'{"prompt":"private"}')::text),'invalid_transport_metadata');
select test.reject(format('select public.worker_openrouter_dispatch(%L,%L,%L,%L)',:'A',:'O',:'T',jsonb_set(:'M'::jsonb,'{endpoint}','"anthropic"')::text),'transport_route_mismatch');
select test.assert(public.worker_openrouter_dispatch(:'A',:'O',:'T',:'M'),'first dispatch commits before send');
select test.assert(not public.worker_openrouter_dispatch(:'A',:'O',:'T',:'M'),'lost dispatch acknowledgement cannot authorize a second send');
select test.assert(public.worker_openrouter_receipt(:'A',:'O',:'T','{"generation_id":"gen-89","provider":"Google Vertex","model":"anthropic/claude-haiku-5.5","total_cost_microusd":200}'),'receipt recorded');
select test.assert(public.worker_openrouter_receipt(:'A',:'O',:'T','{"generation_id":"gen-89","provider":"Google Vertex","model":"anthropic/claude-haiku-5.5","total_cost_microusd":200}'),'same receipt replay-safe');
select test.reject(format('select public.worker_openrouter_receipt(%L,%L,%L,%L)',:'A',:'O',:'T','{"generation_id":"gen-89-other","provider":"Google Vertex","model":"anthropic/claude-haiku-5.5","total_cost_microusd":300}'),'receipt_conflict');
select public.worker_provider_attempt_finish(:'A',:'O',:'T','succeeded','gen-89',200,'{"input_tokens":100,"output_tokens":40}',null);
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',:'D','openrouter','chat','deepseek/deepseek-v4.1-flash-1017',sha256('deepseek'),20000,'{"input_tokens":1000,"output_tokens":1000}')->>'granted')::boolean,'pinned DeepSeek route admitted');
select test.assert(public.worker_openrouter_dispatch(:'A',:'O',:'D','{"transport_model":"deepseek/deepseek-v4.1-flash-1017","endpoint":"deepinfra/fp8","feature":"figure_detail","caller":"chat"}'),'DeepSeek attribution');
select public.worker_provider_attempt_finish(:'A',:'O',:'D','unknown',null,null,'{}','provider_transport');
select public.worker_settle_operation(:'A',:'O',0,200);
select test.reject(format('select public.worker_provider_attempt_begin(%L,%L,gen_random_uuid(),%L,%L,%L,sha256(%L),1000,%L)',:'A',:'O',provider,route,model,'direct','{}'),'invalid_provider_route')
 from (values ('anthropic','chat','claude-sonnet-5-5'),('deepseek','chat','deepseek-flash'),('google','podcast_speech','gemini-3.8-flash-tts'),('anthropic','catalog_tags','claude-haiku-4-5-20251001')) x(provider,route,model);
reset role;
select test.assert((select dispatched_at is not null and transport_metadata=:'M'::jsonb and receipt_metadata->>'generation_id'='gen-89' from app_private.provider_attempts where id=:'T'),'account-scoped dated dispatch and receipt retained');
select test.assert((select count(*)=1 from app_private.provider_attempt_events where attempt_id=:'T' and state='dispatched'),'one dispatch event');
select test.assert((select provider_liability_microusd=20000 from app_private.metered_operations where account_id=:'A' and id=:'O'),'uncertain request keeps full liability');
select test.assert((select count(*)=8 from app_private.podcast_profiles where version in (6,7) and spec->>'consent_version'='podcast-private-v3'),'both podcast writers use new explicit consent');
select test.assert(not exists(select 1 from app_private.podcast_profiles p where version in (6,7) and (
 (spec->>'ceiling_microusd')::bigint<>(select sum((c->>'ceiling_microusd')::bigint) from jsonb_array_elements(spec->'script'->'calls') c)+(spec->'speech'->>'ceiling_microusd')::bigint
 or (spec->>'hold_microusd')::bigint<(spec->>'ceiling_microusd')::bigint)), 'profile holds cover every script and speech call');
-- Existing tag finalization still calls its old Anthropic summary hook: it must not double-charge.
select count(*) as expenses_before from app_private.provider_usage_events where account_id=:'A' and operation_id=:'O' \gset
select public.worker_record_provider_usage(:'A',:'O','anthropic','legacy-tag-summary','anthropic/claude-haiku-5.5','{}',200);
select test.assert((select count(*)=:expenses_before from app_private.provider_usage_events where account_id=:'A' and operation_id=:'O'),'legacy summaries do not duplicate OpenRouter expenses');

-- Real device-source quote -> consent -> claim -> script/review/speech admission for both new writer profiles.
insert into app_private.app_roles(account_id,role) values(:'B','owner');
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);
select public.worker_grant_credits(:'A','adjustment','router-podcast-89',10000,now()-interval '1 day',null,'Router podcast fixture');
select public.worker_podcast_policy_set(:'B',gen_random_uuid(),'{"generation_enabled":true,"delivery_enabled":true,"profile_id":"podcast-short-v1","profile_version":7,"allowed_profiles":["podcast-short-v1:6","podcast-short-v1:7"]}','OpenRouter integration fixture');
create function test.router_episode(writer text) returns void language plpgsql as $$
declare a uuid:='89000000-0000-4000-8000-000000000001'; item uuid:=gen_random_uuid(); req uuid:=gen_random_uuid();
 cl uuid:=gen_random_uuid(); attempt uuid; quote jsonb; job jsonb; claim jsonb; admission jsonb; route text;
 jid uuid; gen bigint; digest text:=encode(sha256(convert_to('OpenRouter podcast source '||writer,'UTF8')),'hex');
begin
 perform public.worker_podcast_source_register(a,digest,25);
 perform set_config('request.jwt.claim.sub',a::text,true);
 quote:=public.v1_podcast_quote(item,req,'podcast-short-v1',writer,jsonb_build_object('source','arxiv','source_id','2610.16334','revision',1,
  'manifest_sha256',repeat('b',64),'text_sha256',digest,'title','Router integration','authors',jsonb_build_array('A. Reader')));
 perform test.assert(quote->'quote'->>'consent_version'='podcast-private-v3','new processor consent quoted');
 perform test.assert(quote->'quote'->'providers'->>0 like 'OpenRouter%','quote names OpenRouter');
 perform test.reject(format('select public.v1_podcast_start(%L,%L,%L)',quote->'quote'->>'id',req,'podcast-private-v2'),'consent_required');
 job:=public.v1_podcast_start((quote->'quote'->>'id')::uuid,req,'podcast-private-v3');
 claim:=public.worker_podcast_claim(cl,true); jid:=(claim->>'job_id')::uuid; gen:=(claim->>'generation')::bigint;
 perform test.assert(claim->>'claimed'='true','new profile job claimed');
 foreach route in array array['podcast_script','podcast_review'] loop
  if route='podcast_review' then perform public.worker_podcast_advance(jid,cl,gen,'checking'); end if;
  attempt:=gen_random_uuid();
  admission:=public.worker_podcast_attempt_begin(jid,cl,gen,attempt,route,sha256(convert_to(route,'UTF8')));
  perform test.assert(admission->>'granted'='true' and admission->>'provider'='openrouter','script call admitted through router');
  perform test.assert(public.worker_openrouter_dispatch((admission->>'account_id')::uuid,(admission->>'operation_id')::uuid,attempt,
   jsonb_build_object('transport_model',admission->>'model','endpoint',case writer when 'deepseek' then 'deepinfra/fp8' else 'google-vertex/us' end,
    'feature',route,'caller','podcast')),'script has account-scoped dispatch');
  perform public.worker_provider_attempt_finish((admission->>'account_id')::uuid,(admission->>'operation_id')::uuid,attempt,'succeeded','gen-'||attempt,200,'{"input_tokens":100,"output_tokens":10}',null);
 end loop;
 perform public.worker_podcast_advance(jid,cl,gen,'synthesizing');
 attempt:=gen_random_uuid();
 admission:=public.worker_podcast_speech_begin(jid,cl,gen,jsonb_build_array(jsonb_build_object('attempt_id',attempt,'request_sha256',repeat('a',64),'audio_tokens',16384)));
 perform test.assert(admission->>'granted'='true','speech batch admitted');
 select jsonb_build_object('account',account_id,'operation',operation_id) into admission from app_private.provider_attempts where id=attempt;
 perform test.assert(public.worker_openrouter_dispatch((admission->>'account')::uuid,(admission->>'operation')::uuid,attempt,
  '{"transport_model":"google/gemini-3.8-flash-tts","endpoint":"speech/zdr","feature":"podcast_speech","caller":"podcast"}'),'speech has account-scoped dispatch');
 perform public.worker_provider_attempt_finish((admission->>'account')::uuid,(admission->>'operation')::uuid,attempt,'succeeded','gen-'||attempt,905,'{"text_input_tokens":10,"audio_output_tokens":100}',null);
 perform public.worker_podcast_fail(jid,cl,gen,'quality_rejected',true);
 perform test.assert((select provider_liability_microusd=0 and actual_microusd=1305 from app_private.metered_operations
  where account_id=(admission->>'account')::uuid and id=(admission->>'operation')::uuid),'each exact cost settles once even if audio quality rejects delivery');
end $$;
select test.router_episode('deepseek');
select test.router_episode('anthropic');
set role authenticated;
select test.reject(format('select public.worker_openrouter_dispatch(%L,%L,%L,%L)',:'A',:'O',:'T',:'M'),'permission denied');
select test.reject(format('select public.v1_admin_spending_operation(%L,%L)',:'A',:'O'),'owner_mfa_required');
reset role;
rollback;
