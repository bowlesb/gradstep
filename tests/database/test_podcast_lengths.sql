-- Paper podcast lengths (migration 048): Short, 5, 10 and 20 minute profiles with
-- their own provider ceilings and credit maximums, the policy allowlist, quotes per
-- length (each length its own work key), and staged ten/twenty-minute jobs: draft
-- and script checkpoints, resumable claims and recovery, yields, chunked speech
-- grants (all or nothing), cancellation and closing of parked jobs. Synthetic local
-- SQL with explicit provider receipts; nothing leaves the machine.
begin;
create schema if not exists test;
grant usage on schema test to anon,authenticated,service_role;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin begin execute statement; exception when others then
 if position(expected in sqlerrm)=0 then raise exception 'Unexpected rejection: % (wanted %)',sqlerrm,expected; end if; rejected:=true; end;
 if not rejected then raise exception 'Expected rejection: %',expected; end if; end $$;
grant execute on all functions in schema test to anon,authenticated,service_role;

\set O '46000000-0000-0000-0000-00000000000f'
\set A '46000000-0000-0000-0000-00000000000a'
\set B '46000000-0000-0000-0000-00000000000b'
insert into auth.users(id) values(:'O'),(:'A'),(:'B');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
select coalesce(spent_microusd,0) as spent0,coalesce(reserved_microusd,0) as reserved0 from app_private.platform_budgets where period=:'month' \gset
select public.worker_grant_credits(:'A','adjustment','podcast-a',1000,now()-interval '1 day',null,'Podcast fixture');
select public.worker_grant_credits(:'B','adjustment','podcast-b',1000,now()-interval '1 day',null,'Podcast fixture');

-- A converted CC BY paper in A's library (the asset-accounting fixture path).
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0 where singleton;
select public.worker_set_pipeline_enabled(true);
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_begin_import('46000000-0000-0000-0001-000000000001','2410.04601',0);
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'id') as paper,(:'entry'::jsonb->>'generation')::bigint as gen \gset
select public.worker_pipeline_metadata(:'paper',:'claim',:'gen',1,
 '{"title":"Podcast fixture paper","authors":["Ada Fixture","Bo Example"],"abstract":"Testing","published_at":"2024-10-01","categories":["cs.LG"]}',
 true,'https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2410.04601','source_revision',1,'source_url','https://arxiv.org/abs/2410.04601v1',
 'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('a',64),'observed_at','2026-10-07T05:00:00Z'));
select test.assert((public.worker_pipeline_admit_download(:'paper',:'claim',:'gen')->>'admitted')::boolean,'paper admitted');
create or replace function test.complete_plan(p uuid,c uuid,g bigint,k text,objects jsonb,pages integer default null) returns jsonb language plpgsql as $$
declare plan jsonb; row jsonb; upload uuid:=gen_random_uuid(); write uuid;
begin
 plan:=public.worker_pipeline_asset_plan(p,c,g,upload,k,objects,pages);
 for row in select value from jsonb_array_elements(plan->'objects') loop
  if not (row->>'verified')::boolean then
   write:=gen_random_uuid();
   perform test.assert((public.worker_pipeline_asset_write(p,c,g,upload,(row->>'id')::uuid,write)->>'write')::boolean,'fixture paper write');
   perform public.worker_pipeline_asset_written(write,true);
  end if;
 end loop;
 return plan;
end $$;
select test.complete_plan(:'paper',:'claim',:'gen','original',jsonb_build_array(jsonb_build_object('path','originals/'||repeat('5',64)||'.pdf','sha256',repeat('5',64),'bytes',1000,'media_type','application/pdf')),2);
select public.worker_pipeline_original(:'paper',:'claim',:'gen',decode(repeat('5',64),'hex'),1000,2,'originals/'||repeat('5',64)||'.pdf');
select public.worker_pipeline_admit_processing(:'paper',:'claim',:'gen');
select public.worker_pipeline_fund(:'paper',:'claim',:'gen',2,decode(repeat('6',64),'hex'),decode(repeat('7',64),'hex'));
select public.worker_pipeline_begin_submit(:'paper',:'claim',:'gen')->>'attempt_id' as ocr_attempt \gset
select public.worker_pipeline_submitted(:'ocr_attempt','podcast-fixture-job');
select test.complete_plan(:'paper',:'claim',:'gen','raw',jsonb_build_array(
 jsonb_build_object('path','raw/'||repeat('8',64)||'/manifest.json','sha256',repeat('8',64),'bytes',100,'media_type','application/json'),
 jsonb_build_object('path','raw/'||repeat('8',64)||'/standalone.mmd','sha256',repeat('9',64),'bytes',5000,'media_type','text/plain; charset=utf-8'),
 jsonb_build_object('path','raw/'||repeat('8',64)||'/output.mmd.zip','sha256',repeat('b',64),'bytes',100,'media_type','application/zip'),
 jsonb_build_object('path','raw/'||repeat('8',64)||'/lines.json','sha256',repeat('c',64),'bytes',100,'media_type','application/json')));
select public.worker_pipeline_collected(:'paper',:'claim',:'gen',2,decode(repeat('8',64),'hex'),100);
select test.complete_plan(:'paper',:'claim',:'gen','reader',jsonb_build_array(
 jsonb_build_object('path','reader/'||repeat('d',64)||'/manifest.json','sha256',repeat('d',64),'bytes',100,'media_type','application/json'),
 jsonb_build_object('path','reader/'||repeat('d',64)||'/index.html','sha256',repeat('e',64),'bytes',200,'media_type','text/html; charset=utf-8'),
 jsonb_build_object('path','reader/'||repeat('d',64)||'/index.json','sha256',repeat('f',64),'bytes',100,'media_type','application/json')));
select public.worker_pipeline_published(:'paper',:'claim',:'gen',decode(repeat('d',64),'hex'),100,'timestep-mathpix-mathml-v1');
select public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen');
select id as item,document_id as doc,approval_id as approval from app_private.library_items where account_id=:'A' \gset
select test.assert(:'approval' is not null and (select license_uri from app_private.catalog_asset_approvals where id=:'approval')='https://creativecommons.org/licenses/by/4.0/','CC BY approval pinned');

-- Dark by default: no catalog, delivery, generation, seed or fixtures.
select test.assert((select not (catalog_enabled or delivery_enabled or generation_enabled or seed_enabled or fixtures_enabled) from app_private.podcast_policy),'every podcast switch starts off');
select test.assert(not exists(select 1 from app_private.podcast_seed_periods),'no seed allowance exists until configured');

-- ---------------------------------------------------------------------------
-- Profiles: the five-minute v1 profile unchanged; three more, each ceiling the
-- sum of its calls at full caps (list prices), rounded up to the next 10 credits.
-- ---------------------------------------------------------------------------
select test.assert((select spec->>'ceiling_microusd'='723104' and spec->>'max_credits'='150' and spec->>'hold_microusd'='750000'
 and not spec ? 'staged' and not (spec->'speech') ? 'max_calls' and spec_sha256=sha256(convert_to(spec::text,'UTF8'))
 from app_private.podcast_profiles where id='podcast-5min-v1' and version=1),'five-minute profile unchanged');
create temporary table expected(id text,script bigint,review bigint,speech bigint,total bigint,credits integer,hold bigint,calls integer,audio bigint,
 target integer,max_s integer,staged boolean) on commit drop;
insert into expected values
 ('podcast-short-v1',192000,194400,156692,543092,110,550000,1,8250,150,330,false),
 ('podcast-10min-v1',280000,286000,510576,1076576,220,1100000,3,27000,600,1080,true),
 ('podcast-20min-v1',388000,397600,967152,1752752,360,1800000,6,51000,1200,2040,true);
select test.assert((select count(*)=3 from expected e join app_private.podcast_profiles p on p.id=e.id and p.version=1
 where (p.spec->'script'->'calls'->0->>'ceiling_microusd')::bigint=e.script
  and (p.spec->'script'->'calls'->1->>'ceiling_microusd')::bigint=e.review
  and (p.spec->'speech'->>'ceiling_microusd')::bigint=e.speech
  and (p.spec->>'ceiling_microusd')::bigint=e.total and (p.spec->>'max_credits')::integer=e.credits and (p.spec->>'hold_microusd')::bigint=e.hold
  and (p.spec->'speech'->>'max_calls')::integer=e.calls and (p.spec->'speech'->>'max_audio_tokens')::bigint=e.audio
  and (p.spec->>'target_seconds')::integer=e.target and (p.spec->>'max_seconds')::integer=e.max_s and (p.spec->>'staged')::boolean=e.staged
  and p.spec_sha256=sha256(convert_to(p.spec::text,'UTF8'))),'each new profile states its own ceiling, credit maximum and speech plan');
-- The method, recomputed: script/review at full input and output caps ($2/M in, $10/M out); each speech call
-- 8,192 input tokens at $1/M plus the audio budget at $18/M; credits = ceil(total / $0.05) x 10.
select test.assert((select bool_and(
   (c0->>'ceiling_microusd')::bigint=(c0->>'max_input_tokens')::bigint*2+(c0->>'max_output_tokens')::bigint*10
   and (c1->>'ceiling_microusd')::bigint=(c1->>'max_input_tokens')::bigint*2+(c1->>'max_output_tokens')::bigint*10
   and (c1->>'max_input_tokens')::bigint>=(c0->>'max_input_tokens')::bigint+(c0->>'max_output_tokens')::bigint+1000
   and (p.spec->'speech'->>'ceiling_microusd')::bigint=(p.spec->'speech'->>'max_calls')::bigint*8192+(p.spec->'speech'->>'max_audio_tokens')::bigint*18
   and (p.spec->'speech'->>'max_audio_tokens')::bigint<=(p.spec->>'max_seconds')::bigint*25
   and (p.spec->'speech'->>'max_output_tokens')::bigint<=16384 and (p.spec->'speech'->>'max_input_tokens')::bigint=8192
   and (p.spec->>'max_credits')::bigint=ceil((p.spec->>'ceiling_microusd')::numeric/50000)*10)
 from app_private.podcast_profiles p cross join lateral (select p.spec->'script'->'calls'->0 c0,p.spec->'script'->'calls'->1 c1) c where p.id<>'podcast-5min-v1' and p.version=1),
 'ceilings follow the five-minute method exactly');
select test.reject($$update app_private.podcast_profiles set spec=spec||'{"max_credits":1}' where id='podcast-20min-v1'$$,'immutable_record_requires_compensating_entry');

-- The allowlist offers all four for private generation, shortest first.
select test.assert((select allowed_profiles=array['podcast-short-v1:1','podcast-5min-v1:1','podcast-10min-v1:1','podcast-20min-v1:1'] from app_private.podcast_policy),
 'all four lengths allowlisted');
select test.assert((select jsonb_agg(e->>'label' order by n)=jsonb_build_array('Short','5 min','10 min','20 min')
  and jsonb_agg((e->>'max_credits')::integer order by n)=jsonb_build_array(110,150,220,360)
  and jsonb_agg((e->>'target_seconds')::integer order by n)=jsonb_build_array(150,300,600,1200)
 from jsonb_array_elements(app_private.podcast_lengths()) with ordinality x(e,n)),'lengths listed with their own maximums');
select test.reject($$update app_private.podcast_policy set allowed_profiles=array['podcast-40min-v1:1']$$,'invalid_podcast_policy');
select test.reject($$update app_private.podcast_policy set allowed_profiles=array['podcast-5min-v1:1','podcast-5min-v1:1']$$,'invalid_podcast_policy');
select test.reject(format('select public.worker_podcast_policy_set(%L,gen_random_uuid(),%L,%L)',:'O','{"allowed_profiles":"podcast-5min-v1:1"}','Bad shape'),'invalid_podcast_policy');
select test.reject(format('select public.worker_podcast_policy_set(%L,gen_random_uuid(),%L,%L)',:'O','{"allowed_profiles":["podcast-9min-v1:1"]}','Unknown'),'invalid_podcast_policy');
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),
 '{"catalog_enabled":true,"delivery_enabled":true,"generation_enabled":true,"seed_enabled":true,"allowed_profiles":["podcast-5min-v1:1","podcast-10min-v1:1"]}','Two lengths only');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert(jsonb_array_length(public.v1_podcast_capabilities()->'lengths')=2,'capabilities list only the offered lengths');
select test.reject(format('select public.v1_podcast_quote(%L,gen_random_uuid(),%L)',:'item','podcast-short-v1'),'podcast_profile_unavailable');
select test.reject(format('select public.v1_podcast_quote(%L,gen_random_uuid(),%L)',:'item','Nope!'),'podcast_profile_unavailable');
reset role;
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),
 '{"allowed_profiles":["podcast-short-v1:1","podcast-5min-v1:1","podcast-10min-v1:1","podcast-20min-v1:1"]}','All four lengths');

-- Seeds stay the approved five-minute episodes (Decision 2).
select public.worker_podcast_seed_period(:'O',gen_random_uuid(),:'month',2000000,true,'owner-decision-20261008');
update app_private.podcast_policy set profile_id='podcast-10min-v1';
select test.reject(format('select public.worker_podcast_seed_admit(%L,gen_random_uuid(),%L,%L)',:'O',:'approval','Not a five-minute seed'),'seed_profile_unavailable');
update app_private.podcast_policy set profile_id='podcast-5min-v1';

-- ---------------------------------------------------------------------------
-- Quotes per length: each length is its own work key and its own maximum.
-- ---------------------------------------------------------------------------
-- This suite quotes far more than a reader would in an hour (20 quote/start/cancel calls per account).
update app_private.api_rate_rules set account_limit=1000,environment_limit=10000 where route='podcast-generate';
create or replace function test.podcast_attempt(j uuid,c uuid,g bigint,route text,cost bigint) returns uuid language plpgsql as $$
declare attempt uuid:=gen_random_uuid(); admission jsonb;
begin
 admission:=public.worker_podcast_attempt_begin(j,c,g,attempt,route,sha256(convert_to(route||attempt::text,'UTF8')));
 perform test.assert((admission->>'granted')::boolean,'grant '||route||' '||coalesce(admission->>'reason',''));
 perform public.worker_provider_attempt_finish((admission->>'account_id')::uuid,(admission->>'operation_id')::uuid,attempt,'succeeded','req_'||left(attempt::text,8),cost,
  '{"input_tokens":20000,"output_tokens":3000}'::jsonb,null);
 return attempt;
end $$;
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
\set RT1 '46000000-0000-0000-00b0-000000000001'
select (public.v1_credit_balance()->>'reserved')::integer as held0 \gset
select public.v1_podcast_quote(:'item',:'RT1','podcast-10min-v1') as qt \gset
select test.assert((:'qt'::jsonb->'quote'->>'max_credits')::integer=220 and (:'qt'::jsonb->'quote'->>'profile')='podcast-10min-v1'
 and (:'qt'::jsonb->'quote'->>'label')='10 min' and (:'qt'::jsonb->'quote'->>'target_seconds')::integer=600
 and (:'qt'::jsonb->'quote'->>'estimate') like 'Estimate%maximum 220 credits','ten-minute quote carries its own maximum');
select test.assert(jsonb_array_length(:'qt'::jsonb->'options')=4 and (:'qt'::jsonb->'options'->3->>'max_credits')::integer=360,'quote lists every offered length');
select test.assert(public.v1_podcast_quote(:'item',:'RT1','podcast-10min-v1')->'quote'->>'id'=:'qt'::jsonb->'quote'->>'id','quote replay');
select test.reject(format('select public.v1_podcast_quote(%L,%L,%L)',:'item',:'RT1','podcast-20min-v1'),'podcast_request_conflict');
select test.assert((public.v1_podcast_quote(:'item',gen_random_uuid())->'quote'->>'max_credits')::integer=150,'no length means five minutes (older clients)');
select test.assert((public.v1_podcast_quote(:'item',gen_random_uuid(),'podcast-short-v1')->'quote'->>'max_credits')::integer=110,'short maximum');
select public.v1_podcast_start((:'qt'::jsonb->'quote'->>'id')::uuid,:'RT1','podcast-private-v1') as st \gset
select test.assert((:'st'::jsonb->'job'->>'held_credits')::integer=220 and (:'st'::jsonb->'job'->>'profile')='podcast-10min-v1','one 220-credit hold for ten minutes');
select test.assert((public.v1_credit_balance()->>'reserved')::integer=:'held0'::integer+220,'customer hold');
-- Another length of the same paper is new work, not a join (and one active private job per account).
select public.v1_podcast_quote(:'item','46000000-0000-0000-00b0-000000000002','podcast-5min-v1') as q5 \gset
select test.assert(:'q5'::jsonb ? 'quote','a different length quotes separately');
select test.reject(format('select public.v1_podcast_start(%L,%L,%L)',:'q5'::jsonb->'quote'->>'id','46000000-0000-0000-00b0-000000000002','podcast-private-v1'),'active_generation_limit');
select test.assert(public.v1_podcast_quote(:'item',gen_random_uuid(),'podcast-10min-v1')->'join'->>'request_id'=:'RT1','same length joins the running job');
reset role;
select id as jt,operation_id as opt from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select test.assert((select spend_ceiling_microusd=1100000 and credit_ceiling=220 from app_private.metered_operations where id=:'opt'),'operation ceiling is the ten-minute hold');
select test.assert((select k.profile_id='podcast-10min-v1' from app_private.podcast_jobs j join app_private.podcast_episode_keys k on k.id=j.episode_id where j.id=:'jt'),'job bound to the ten-minute work key');
select test.assert((select bytes=12582912+4194304+262144 from app_private.podcast_asset_holds where job_id=:'jt'),'ten-minute storage hold');

-- ---------------------------------------------------------------------------
-- Staged job: draft checkpoint, resume at review, script checkpoint, chunked speech.
-- ---------------------------------------------------------------------------
select gen_random_uuid() as c1 \gset
select public.worker_podcast_claim(:'c1') as claim1 \gset
select (:'claim1'::jsonb->>'generation')::bigint as g1 \gset
select test.assert((:'claim1'::jsonb->>'job_id')=:'jt' and :'claim1'::jsonb->'resume'='null'::jsonb and (:'claim1'::jsonb->'spec'->>'staged')::boolean,'fresh staged claim');
select test.reject(format('select public.worker_podcast_checkpoint(%L,%L,%s,%L,%L)',:'jt',:'c1',:'g1','draft','{"format":1}'),'invalid_podcast_stage');
select test.podcast_attempt(:'jt',:'c1',:'g1','podcast_script',190000) as tscript \gset
select test.assert((select ceiling_microusd=280000 and reserved_units='{"input_tokens":80000,"output_tokens":12000}'::jsonb
 and pricing_snapshot->>'profile'='podcast-10min-v1:1' from app_private.provider_attempts where id=:'tscript'),'ten-minute draft ceiling');
select test.reject(format('select public.worker_podcast_checkpoint(%L,%L,%s,%L,%L)',:'jt',:'c1',:'g1','script','{"format":1}'),'invalid_podcast_stage');
select test.reject(format('select public.worker_podcast_checkpoint(%L,%L,%s,%L,%L)',:'jt',:'c1',:'g1','draft','[1]'),'invalid_podcast_checkpoint');
select test.assert((public.worker_podcast_checkpoint(:'jt',:'c1',:'g1','draft','{"format":1,"draft":{"title":"T"},"draft_sha256":"aa"}')->>'state')='checking','draft checkpoint parks at checking');
select test.assert((select state='checking' and claim_id is null and lease_until is null from app_private.podcast_jobs where id=:'jt'),'claim released');
select test.reject('update app_private.podcast_job_checkpoints set stage=stage','immutable_record_requires_compensating_entry');
select test.reject(format('select public.worker_podcast_attempt_begin(%L,%L,%s,gen_random_uuid(),%L,sha256(%L))',:'jt',:'c1',:'g1','podcast_review','stale'),'stale_podcast_claim');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert((public.v1_podcast_status(:'RT1')->'job'->>'state')='checking','status shows the parked stage');
reset role;
select test.assert((public.worker_podcast_kick_due()->>'due')::integer>=1,'a parked job is due for a worker');
select gen_random_uuid() as c2 \gset
select public.worker_podcast_claim(:'c2') as claim2 \gset
select (:'claim2'::jsonb->>'generation')::bigint as g2 \gset
select test.assert((:'claim2'::jsonb->'resume'->>'stage')='review' and (:'claim2'::jsonb->'resume'->'document'->'draft'->>'title')='T'
 and :'g2'::bigint=:'g1'::bigint+1,'resumed at the review with the stored draft');
select test.assert((select state='checking' from app_private.podcast_jobs where id=:'jt'),'resumed claim keeps its stage');
select test.assert((public.worker_podcast_attempt_begin(:'jt',:'c2',:'g2',gen_random_uuid(),'podcast_script',sha256('again'))->>'reason')='route_used','the draft is never bought twice');
-- A request without time for the review hands the job back where it was.
select test.assert((public.worker_podcast_yield(:'jt',:'c2',:'g2')->>'state')='checking','yield keeps the checkpointed stage');
select gen_random_uuid() as c3 \gset
select (public.worker_podcast_claim(:'c3')->>'generation')::bigint as g3 \gset
select test.podcast_attempt(:'jt',:'c3',:'g3','podcast_review',200000) as treview \gset
select test.assert((select ceiling_microusd=286000 and reserved_units='{"input_tokens":93000,"output_tokens":10000}'::jsonb from app_private.provider_attempts where id=:'treview'),
 'review input cap covers the paper plus the draft');
select test.reject(format('select public.worker_podcast_yield(%L,%L,%s)',:'jt',:'c3',:'g3'),'invalid_podcast_stage');
select test.assert((public.worker_podcast_checkpoint(:'jt',:'c3',:'g3','script','{"format":1,"final":{"title":"T"}}')->>'state')='synthesizing','script checkpoint parks at synthesizing');
select gen_random_uuid() as c4 \gset
select public.worker_podcast_claim(:'c4') as claim4 \gset
select test.assert((:'claim4'::jsonb->'resume'->>'stage')='speech' and (:'claim4'::jsonb->'resume'->'document'->'final'->>'title')='T','resumed at speech');
-- Lease expiry while parked work had no paid call in flight: back to its checkpoint, nothing lost.
update app_private.podcast_jobs set lease_until=clock_timestamp()-interval '1 second' where id=:'jt';
select test.assert((public.worker_podcast_recover()->>'state')='synthesizing','expired resumed claim returns to its checkpoint');
select test.assert(exists(select 1 from app_private.podcast_job_events where job_id=:'jt' and kind='parked' and details->>'reason'='lease_expired_after_checkpoint'),'recorded');
select gen_random_uuid() as c5 \gset
select (public.worker_podcast_claim(:'c5')->>'generation')::bigint as g5 \gset

-- Speech chunks: all granted together within the profile's calls and audio budget.
create or replace function test.chunks(n integer,audio bigint) returns jsonb language sql as $$
 select jsonb_agg(jsonb_build_object('attempt_id',gen_random_uuid(),'request_sha256',encode(sha256(convert_to('chunk'||i,'UTF8')),'hex'),'audio_tokens',audio))
 from generate_series(1,n) i
$$;
select test.reject(format('select public.worker_podcast_speech_begin(%L,%L,%s,%L)',:'jt',:'c5',:'g5',test.chunks(4,5000)),'invalid_provider_attempt');
select test.reject(format('select public.worker_podcast_speech_begin(%L,%L,%s,%L)',:'jt',:'c5',:'g5',test.chunks(2,14000)),'invalid_provider_attempt');
select test.reject(format('select public.worker_podcast_speech_begin(%L,%L,%s,%L)',:'jt',:'c5',:'g5',test.chunks(1,16385)),'invalid_provider_attempt');
select test.chunks(2,13000) as chunks \gset
select public.worker_podcast_speech_begin(:'jt',:'c5',:'g5',:'chunks') as speech \gset
select test.assert((:'speech'::jsonb->>'granted')::boolean and jsonb_array_length(:'speech'::jsonb->'attempts')=2,'two chunks granted');
select test.assert((select count(*)=2 and bool_and(pa.ceiling_microusd=8192+13000*18 and pa.reserved_units='{"text_input_tokens":8192,"audio_output_tokens":13000}'::jsonb
 and pa.provider='google') from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id
 where ja.job_id=:'jt' and ja.route='podcast_speech'),'each chunk reserves 8,192 input tokens and its audio share');
select test.assert((select speech_calls=2 from app_private.podcast_jobs where id=:'jt'),'speech plan fixed at its first grant');
select test.assert((public.worker_podcast_speech_begin(:'jt',:'c5',:'g5',:'chunks')->>'reason')='attempt_replayed','lost acknowledgement never re-grants');
select test.assert((public.worker_podcast_speech_begin(:'jt',:'c5',:'g5',test.chunks(2,100))->>'reason')='route_used','one speech plan per job');
select public.worker_provider_attempt_finish(:'A',:'opt',(:'speech'::jsonb->'attempts'->0->>'attempt_id')::uuid,'succeeded','resp-1',120000,
 '{"text_input_tokens":2000,"audio_output_tokens":6600,"audio_ms":264000}',null);
select test.reject(format('select public.worker_podcast_advance(%L,%L,%s,%L)',:'jt',:'c5',:'g5','verifying'),'invalid_podcast_stage');
select public.worker_provider_attempt_finish(:'A',:'opt',(:'speech'::jsonb->'attempts'->1->>'attempt_id')::uuid,'succeeded','resp-2',125000,
 '{"text_input_tokens":2100,"audio_output_tokens":6900,"audio_ms":276000}',null);
select public.worker_podcast_advance(:'jt',:'c5',:'g5','verifying');
select public.worker_podcast_advance(:'jt',:'c5',:'g5','publishing');
select gen_random_uuid() as upload \gset
select public.worker_podcast_asset_plan(:'jt',:'c5',:'g5',:'upload',jsonb_build_array(
 jsonb_build_object('role','audio','path','private/'||:'A'||'/'||repeat('7',64)||'/audio.m4a','sha256',repeat('1',64),'bytes',4800000,'media_type','audio/mp4'),
 jsonb_build_object('role','transcript','path','private/'||:'A'||'/'||repeat('7',64)||'/transcript.json','sha256',repeat('2',64),'bytes',60000,'media_type','application/json'),
 jsonb_build_object('role','manifest','path','private/'||:'A'||'/'||repeat('7',64)||'/manifest.json','sha256',repeat('3',64),'bytes',2000,'media_type','application/json'))) as plan \gset
create or replace function test.write_plan(j uuid,c uuid,g bigint,upload uuid,plan jsonb) returns void language plpgsql as $$
declare row jsonb; w uuid;
begin
 for row in select value from jsonb_array_elements(plan->'objects') loop
  w:=gen_random_uuid();
  perform test.assert((public.worker_podcast_asset_write(j,c,g,upload,(row->>'id')::uuid,w)->>'write')::boolean,'write grant');
  perform public.worker_podcast_asset_written(w,true);
 end loop;
end $$;
select test.write_plan(:'jt',:'c5',:'g5',:'upload',:'plan');
select test.reject(format('select public.worker_podcast_publish(%L,%L,%s,%L,%L)',:'jt',:'c5',:'g5',:'upload',jsonb_build_object('script_sha256',repeat('4',64),
 'checker_version','podcast-checker-v1','segments',96,'chapters',8,'duration_ms',1081000,'manifest_sha256',repeat('3',64),'identity','{}'::jsonb)),'invalid_podcast_release');
select public.worker_podcast_publish(:'jt',:'c5',:'g5',:'upload',jsonb_build_object('script_sha256',repeat('4',64),'draft_sha256',repeat('5',64),
 'checker_version','podcast-checker-v1','segments',96,'chapters',8,'duration_ms',612000,'manifest_sha256',repeat('3',64),
 'identity',jsonb_build_object('profile','podcast-10min-v1:1','speech_calls',2))) as pub \gset
select (:'pub'::jsonb->'release'->>'release_id') as relt \gset
-- Known usage 190,000 + 200,000 + 120,000 + 125,000 = 635,000 micro-USD -> 127 credits of the 220 held.
select test.assert((:'pub'::jsonb->>'charged_credits')::integer=127 and (:'pub'::jsonb->'release'->>'profile')='podcast-10min-v1'
 and (:'pub'::jsonb->'release'->>'target_seconds')::integer=600 and (:'pub'::jsonb->'release'->>'label')='10 min','ten-minute release, actual usage charged');
select test.assert(not exists(select 1 from app_private.podcast_job_checkpoints where job_id=:'jt'),'checkpoints deleted when the job settles');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert((public.v1_credit_balance()->>'reserved')::integer=:'held0'::integer,'hold released');
select public.v1_podcast_paper(:'item') as paper \gset
select test.assert(jsonb_array_length(:'paper'::jsonb->'episodes')=1 and (:'paper'::jsonb->'episodes'->0->>'release_id')=:'relt'
 and (:'paper'::jsonb->'episode'->>'release_id')=:'relt','paper lists its ready lengths');
select test.assert(public.v1_podcast_quote(:'item',gen_random_uuid(),'podcast-10min-v1')->'reuse'->>'release_id'=:'relt','same length reuses at no charge');
select test.assert(public.v1_podcast_quote(:'item',gen_random_uuid(),'podcast-20min-v1') ? 'quote','another length is new work (offer play or generate)');
reset role;

-- ---------------------------------------------------------------------------
-- A refused chunk grant sends nothing: earlier grants in the same call close at zero.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
\set RT2 '46000000-0000-0000-00b0-000000000003'
select public.v1_podcast_quote(:'item',:'RT2','podcast-20min-v1')->'quote'->>'id' as q20 \gset
select test.assert((public.v1_podcast_start(:'q20',:'RT2','podcast-private-v1')->'job'->>'held_credits')::integer=360,'twenty-minute hold');
reset role;
select id as j20,operation_id as op20 from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select gen_random_uuid() as d1 \gset
select (public.worker_podcast_claim(:'d1')->>'generation')::bigint as e1 \gset
select test.podcast_attempt(:'j20',:'d1',:'e1','podcast_script',300000);
select public.worker_podcast_checkpoint(:'j20',:'d1',:'e1','draft','{"format":1}');
select gen_random_uuid() as d2 \gset
select (public.worker_podcast_claim(:'d2')->>'generation')::bigint as e2 \gset
select test.podcast_attempt(:'j20',:'d2',:'e2','podcast_review',310000);
select public.worker_podcast_checkpoint(:'j20',:'d2',:'e2','script','{"format":1}');
select gen_random_uuid() as d3 \gset
select (public.worker_podcast_claim(:'d3')->>'generation')::bigint as e3 \gset
-- Three attempts so far; capacity for exactly one more: the second chunk is denied.
update app_private.provider_spending_policy set operation_attempt_limit=3;
select public.worker_podcast_speech_begin(:'j20',:'d3',:'e3',test.chunks(4,12000)) as refused \gset
update app_private.provider_spending_policy set operation_attempt_limit=64;
select test.assert(not (:'refused'::jsonb->>'granted')::boolean and (:'refused'::jsonb->>'reason')='attempt_capacity','batch refused');
select test.assert((select state='failed' and failure_code='provider_admission_refused' from app_private.podcast_jobs where id=:'j20'),'job fails without speech spend');
select test.assert(not exists(select 1 from app_private.provider_attempts where account_id=:'A' and operation_id=:'op20' and state in ('admitted','unknown')),
 'no grant left open: nothing was sent');
select test.assert((select actual_microusd=610000 and provider_liability_microusd=0 from app_private.metered_operations where id=:'op20'),'only the recorded script usage is known');

-- ---------------------------------------------------------------------------
-- Parked jobs: cancel stops at once (recorded usage within the maximum); closing cancels them;
-- an unrecorded paid result is never resumed; a restore fences them.
-- ---------------------------------------------------------------------------
-- The failed twenty-minute job's 610,000 micro-USD is a platform loss against the $0.75 monthly allocation: one
-- more such failure pauses private generation (a long job can use most of it). Raised for the remaining scenarios.
select test.assert(app_private.podcast_customer_losses(:'month')=610000,'zero-charge known costs count against the allocation');
update app_private.podcast_policy set quality_allocation_microusd=5000000;
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
\set RT3 '46000000-0000-0000-00b0-000000000004'
select public.v1_podcast_start((public.v1_podcast_quote(:'item',:'RT3','podcast-20min-v1')->'quote'->>'id')::uuid,:'RT3','podcast-private-v1');
reset role;
select id as jp from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select gen_random_uuid() as f1 \gset
select (public.worker_podcast_claim(:'f1')->>'generation')::bigint as h1 \gset
select test.assert((public.worker_podcast_yield(:'jp',:'f1',:'h1')->>'state')='queued','no paid call yet: back in the queue');
select gen_random_uuid() as f2 \gset
select (public.worker_podcast_claim(:'f2')->>'generation')::bigint as h2 \gset
select test.podcast_attempt(:'jp',:'f2',:'h2','podcast_script',250001);
select public.worker_podcast_checkpoint(:'jp',:'f2',:'h2','draft','{"format":1}');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v1_podcast_cancel(:'RT3') as cp \gset
select test.assert((:'cp'::jsonb->'job'->>'state')='canceled' and (:'cp'::jsonb->'job'->>'charged_credits')::integer=51,'parked job canceled at once; 250,001 micro-USD charged as 51 credits');
reset role;
select test.assert(not exists(select 1 from app_private.podcast_job_checkpoints where job_id=:'jp'),'canceled job keeps no draft');

set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
\set RT4 '46000000-0000-0000-00b0-000000000005'
select public.v1_podcast_start((public.v1_podcast_quote(:'item',:'RT4','podcast-20min-v1')->'quote'->>'id')::uuid,:'RT4','podcast-private-v1');
reset role;
select id as jc from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select gen_random_uuid() as k1 \gset
select (public.worker_podcast_claim(:'k1')->>'generation')::bigint as l1 \gset
select test.podcast_attempt(:'jc',:'k1',:'l1','podcast_script',100000);
select public.worker_podcast_checkpoint(:'jc',:'k1',:'l1','draft','{"format":1}');
-- Crash after the review was paid but before its checkpoint: that result is lost, never bought again.
select gen_random_uuid() as k2 \gset
select (public.worker_podcast_claim(:'k2')->>'generation')::bigint as l2 \gset
select test.podcast_attempt(:'jc',:'k2',:'l2','podcast_review',100000);
update app_private.podcast_jobs set lease_until=clock_timestamp()-interval '1 second' where id=:'jc';
select test.assert((public.worker_podcast_recover()->>'state')='failed','an unrecorded stage ends the job');
select test.assert((select failure_code='worker_interrupted' and charged_credits=0 and platform_loss_microusd=200000 from app_private.podcast_jobs where id=:'jc'),
 'customer charged nothing; the platform keeps the loss');

set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
\set RT5 '46000000-0000-0000-00b0-000000000006'
select public.v1_podcast_start((public.v1_podcast_quote(:'item',:'RT5','podcast-20min-v1')->'quote'->>'id')::uuid,:'RT5','podcast-private-v1');
reset role;
select id as jx from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select gen_random_uuid() as m1 \gset
select (public.worker_podcast_claim(:'m1')->>'generation')::bigint as n1 \gset
select test.podcast_attempt(:'jx',:'m1',:'n1','podcast_script',100000);
select public.worker_podcast_checkpoint(:'jx',:'m1',:'n1','draft','{"format":1}');
-- A quoted length the operator withdraws cannot start; parked work is fenced by a restore.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v1_podcast_quote(:'item','46000000-0000-0000-00b0-000000000007','podcast-short-v1')->'quote'->>'id' as qs \gset
reset role;
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),'{"allowed_profiles":["podcast-5min-v1:1","podcast-10min-v1:1","podcast-20min-v1:1"]}','Short withdrawn');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject(format('select public.v1_podcast_start(%L,%L,%L)',:'qs','46000000-0000-0000-00b0-000000000007','podcast-private-v1'),'podcast_profile_unavailable');
reset role;
update app_private.podcast_policy set epoch=gen_random_uuid();
select test.assert((public.worker_podcast_claim(gen_random_uuid())->>'claimed')::boolean is false,'parked pre-restore job is not resumed');
select test.assert((select state='failed' and failure_code='podcast_epoch_changed' from app_private.podcast_jobs where id=:'jx'),'it fails closed');
select test.assert(not exists(select 1 from app_private.podcast_job_checkpoints where job_id=:'jx'),'and keeps no draft');

-- Account closing cancels parked work immediately.
update app_private.podcast_jobs set epoch=(select epoch from app_private.podcast_policy) where state not in ('ready','canceled','failed');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
\set RT6 '46000000-0000-0000-00b0-000000000008'
select public.v1_podcast_start((public.v1_podcast_quote(:'item',:'RT6','podcast-20min-v1')->'quote'->>'id')::uuid,:'RT6','podcast-private-v1');
reset role;
select id as jz from app_private.podcast_jobs where funding_kind='customer' and state='queued' \gset
select gen_random_uuid() as z1 \gset
select (public.worker_podcast_claim(:'z1')->>'generation')::bigint as y1 \gset
select test.podcast_attempt(:'jz',:'z1',:'y1','podcast_script',100000);
select public.worker_podcast_checkpoint(:'jz',:'z1',:'y1','draft','{"format":1}');
select test.assert(public.worker_podcast_account_closing(:'A')=jsonb_build_object('canceled',1,'running',0),'parked job canceled by account closing');
select test.assert((select state='canceled' and failure_code='owner_deleted' from app_private.podcast_jobs where id=:'jz'),'closed as the owner''s deletion');
rollback;
