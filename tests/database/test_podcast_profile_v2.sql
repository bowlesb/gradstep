-- Podcast profile v2 contract: every speech chunk reserves Google's complete
-- serving limit because Gemini TTS ignores maxOutputTokens. Existing v1 rows and
-- the active policy remain untouched until the native client rollout is ready.
begin;
create schema if not exists test;
grant usage on schema test to anon,authenticated,service_role;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;

create temporary table expected(id text, total bigint, credits integer, calls integer, audio bigint, target integer) on commit drop;
insert into expected values
 ('podcast-short-v1',689504,140,1,16384,150),
 ('podcast-5min-v1',737104,150,1,16384,300),
 ('podcast-10min-v1',1475312,300,3,49152,600),
 ('podcast-20min-v1',2604224,530,6,98304,1200);

select test.assert((select count(*)=4 from expected e join app_private.podcast_profiles p on p.id=e.id and p.version=2
  where (p.spec->>'ceiling_microusd')::bigint=e.total
    and (p.spec->>'max_credits')::integer=e.credits
    and (p.spec->'speech'->>'max_calls')::integer=e.calls
    and (p.spec->'speech'->>'max_audio_tokens')::bigint=e.audio
    and (p.spec->>'target_seconds')::integer=e.target
    and (p.spec->'speech'->>'max_output_tokens')::integer=16384
    and (p.spec->'speech'->>'serving_limit_tokens')::integer=16384
    and p.spec_sha256=sha256(convert_to(p.spec::text,'UTF8'))),
  'all v2 profiles carry serving-limit grants and immutable digests');

select test.assert((select bool_and(
    (p.spec->'speech'->>'max_audio_tokens')::bigint=(p.spec->'speech'->>'max_calls')::bigint*16384
    and (p.spec->'speech'->>'ceiling_microusd')::bigint=(p.spec->'speech'->>'max_calls')::bigint*8192
      +(p.spec->'speech'->>'max_audio_tokens')::bigint*18
    and (p.spec->>'ceiling_microusd')::bigint=(select sum((c->>'ceiling_microusd')::bigint)
      from jsonb_array_elements(p.spec->'script'->'calls') c)+(p.spec->'speech'->>'ceiling_microusd')::bigint
    and (p.spec->>'max_credits')::bigint=ceil((p.spec->>'ceiling_microusd')::numeric/50000)*10)
  from app_private.podcast_profiles p where p.version=2), 'v2 ceilings recompute from provider caps');

select test.assert((select allowed_profiles=array['podcast-short-v1:1','podcast-5min-v1:1','podcast-10min-v1:1','podcast-20min-v1:1']
  and profile_id='podcast-5min-v1' and profile_version=1 from app_private.podcast_policy),
  'v2 is staged without silently switching the active client policy');

select test.assert((select pg_get_functiondef('public.worker_podcast_policy_set(uuid,uuid,jsonb,text)'::regprocedure)
  like '%profile_version%' and pg_get_functiondef('public.worker_podcast_policy_set(uuid,uuid,jsonb,text)'::regprocedure) like '%next_allowed%'),
  'the audited policy RPC can move the default pointer with its allow-list');
commit;
