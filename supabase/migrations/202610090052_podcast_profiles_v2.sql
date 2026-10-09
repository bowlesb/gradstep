-- Podcast profile v2: the speech provider ignores maxOutputTokens, so every
-- production speech chunk reserves the complete 16,384-token serving limit.
-- v1 rows remain immutable for existing episodes and jobs; the operator can
-- switch the policy pointer to these rows only after the matching clients are
-- available. See docs/architecture/PAPER_PODCASTS.md.
begin;

with profile_data(id,label,target_seconds,min_seconds,max_seconds,staged,duration,words,chapters,segments,
  check_words,check_chapters,check_segments,max_spoken,min_evidenced,draft_out,review_out,draft_window,review_window,
  speech_calls,total_microusd,max_credits,audio_bytes) as (values
  ('podcast-short-v1','Short',150,60,330,false,'about two and a half minutes','[330,420]'::jsonb,'[2,3]'::jsonb,'[8,20]'::jsonb,
   '[220,520]'::jsonb,'[2,5]'::jsonb,'[4,40]'::jsonb,3200,3,3200,2600,0,0,1,689504,140,4194304),
  ('podcast-5min-v1','5 min',300,120,660,false,'about five minutes','[650,800]'::jsonb,'[4,6]'::jsonb,'[16,28]'::jsonb,
   '[450,1000]'::jsonb,'[3,8]'::jsonb,'[8,80]'::jsonb,6000,5,6000,4000,0,0,1,737104,150,16777216),
  ('podcast-10min-v1','10 min',600,300,1080,true,'about ten minutes','[1350,1650]'::jsonb,'[6,8]'::jsonb,'[30,80]'::jsonb,
   '[900,2000]'::jsonb,'[4,12]'::jsonb,'[16,160]'::jsonb,12500,10,12000,10000,420,360,3,1475312,300,12582912),
  ('podcast-20min-v1','20 min',1200,600,2040,true,'about twenty minutes','[2700,3300]'::jsonb,'[8,12]'::jsonb,'[60,150]'::jsonb,
   '[1800,3800]'::jsonb,'[6,20]'::jsonb,'[30,300]'::jsonb,24000,18,22800,19000,680,600,6,2604224,530,20971520)
), specs as (
  select p.id, jsonb_build_object(
    'id',p.id,'version',2,'label',p.label,'language','en','target_seconds',p.target_seconds,
    'min_seconds',p.min_seconds,'max_seconds',p.max_seconds,'max_source_bytes',400000,'staged',p.staged,
    'shape',jsonb_build_object('duration',p.duration,'words',p.words,'chapters',p.chapters,'segments',p.segments),
    'checker',jsonb_build_object('words',p.check_words,'chapters',p.check_chapters,'segments',p.check_segments,
      'max_spoken_characters',p.max_spoken,'min_evidenced',p.min_evidenced),
    'script',jsonb_build_object('provider','anthropic','model','claude-sonnet-5-5',
      'rates_microusd_per_token',jsonb_build_object('input',2,'output',10),
      'calls',jsonb_build_array(
        jsonb_build_object('route','podcast_script','max_input_tokens',80000,'max_output_tokens',p.draft_out,
          'ceiling_microusd',80000*2+p.draft_out*10)||case when p.staged then jsonb_build_object('window_seconds',p.draft_window) else '{}'::jsonb end,
        jsonb_build_object('route','podcast_review','max_input_tokens',80000+p.draft_out+1000,'max_output_tokens',p.review_out,
          'ceiling_microusd',(80000+p.draft_out+1000)*2+p.review_out*10)||case when p.staged then jsonb_build_object('window_seconds',p.review_window) else '{}'::jsonb end)),
    'speech',jsonb_build_object('provider','google','route','podcast_speech','model','gemini-3.8-flash-tts','location','global',
      'max_input_tokens',8192,'max_output_tokens',16384,'serving_limit_tokens',16384,'max_calls',p.speech_calls,
      'max_audio_tokens',p.speech_calls*16384,'audio_tokens_per_second',25,
      'rates_microusd_per_token',jsonb_build_object('text_input',1,'audio_output',18),
      'ceiling_microusd',p.speech_calls*8192+(p.speech_calls*16384)*18,
      'voices',jsonb_build_object('explainer','Sadaltager','skeptic','Erinome'))
      ||case when p.staged then jsonb_build_object('window_seconds',420) else '{}'::jsonb end,
    'encoder',jsonb_build_object('codec','aac','container','m4a','channels',1,'sample_rate',24000,'bitrate_kbps',64,'loudness_lufs',-16),
    'ceiling_microusd',p.total_microusd,'hold_microusd',p.max_credits*5000,'max_credits',p.max_credits,'credit_microusd',5000,
    'storage',jsonb_build_object('bytes',p.audio_bytes+4194304+262144,'objects',3,'audio_bytes',p.audio_bytes,'transcript_bytes',4194304,'manifest_bytes',262144),
    'consent_version','podcast-private-v1') as spec
  from profile_data p
)
insert into app_private.podcast_profiles(id,version,spec,spec_sha256)
select id,2,spec,sha256(convert_to(spec::text,'UTF8')) from specs;

-- Validate the serving-limit arithmetic at migration time. `max_audio_tokens`
-- is now a grant ceiling, not an estimate of spoken duration; the actual WAV is
-- still bounded by max_seconds after generation.
do $$
begin
  if exists (
    select 1 from app_private.podcast_profiles p
    where p.version=2 and (
      (p.spec->'speech'->>'max_output_tokens')::bigint <> 16384
      or (p.spec->'speech'->>'serving_limit_tokens')::bigint <> 16384
      or (p.spec->'speech'->>'max_audio_tokens')::bigint <> (p.spec->'speech'->>'max_calls')::bigint * 16384
      or (p.spec->'speech'->>'ceiling_microusd')::bigint <>
        (p.spec->'speech'->>'max_calls')::bigint * 8192 + (p.spec->'speech'->>'max_audio_tokens')::bigint * 18
      or (p.spec->>'ceiling_microusd')::bigint <>
        (select sum((c->>'ceiling_microusd')::bigint) from jsonb_array_elements(p.spec->'script'->'calls') c)
        + (p.spec->'speech'->>'ceiling_microusd')::bigint
      or (p.spec->>'max_credits')::bigint <> ceil((p.spec->>'ceiling_microusd')::numeric / 50000) * 10
    )
  ) then raise exception 'podcast_profile_v2_arithmetic'; end if;
end $$;

-- Defense in depth for callers other than the worker: v2 grants below the
-- provider serving limit are invalid, even though the worker refuses them before
-- admission. v1 retains its historical proportional test contract.
create or replace function public.worker_podcast_speech_begin(p_job uuid,p_claim uuid,p_generation bigint,p_chunks jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; spec jsonb; refused jsonb; chunk jsonb; n integer; i integer:=0; total bigint:=0;
 granted jsonb:='[]'::jsonb; admission jsonb; prior_ids uuid[]; given uuid[]; g jsonb;
begin
 if p_chunks is null or jsonb_typeof(p_chunks)<>'array' or jsonb_array_length(p_chunks) not between 1 and 8 or octet_length(p_chunks::text)>4096
 then raise exception 'invalid_provider_attempt'; end if;
 j:=app_private.podcast_fenced(p_job,p_claim,p_generation);
 if j.origin<>'generated' then raise exception 'invalid_provider_route'; end if;
 select coalesce(array_agg((c->>'attempt_id')::uuid order by o),'{}') into given from jsonb_array_elements(p_chunks) with ordinality x(c,o);
 select coalesce(array_agg(attempt_id order by ordinal),'{}') into prior_ids from app_private.podcast_job_attempts where job_id=j.id and route='podcast_speech';
 if cardinality(prior_ids)>0 then
  return jsonb_build_object('granted',false,'reason',case when prior_ids=given then 'attempt_replayed' else 'route_used' end);
 end if;
 refused:=app_private.podcast_grant_gate(j,'podcast_speech');
 if refused is not null then return refused; end if;
 spec:=app_private.podcast_job_spec(j);
 n:=jsonb_array_length(p_chunks);
 if n>coalesce((spec->'speech'->>'max_calls')::integer,1) or (select count(distinct x) from unnest(given) x)<>n then raise exception 'invalid_provider_attempt'; end if;
 for chunk in select c from jsonb_array_elements(p_chunks) c loop
  if jsonb_typeof(chunk)<>'object' or chunk->>'attempt_id' !~ '^[0-9a-f-]{36}$' or chunk->>'request_sha256' !~ '^[0-9a-f]{64}$'
   or jsonb_typeof(chunk->'audio_tokens')<>'number' or (chunk->>'audio_tokens') !~ '^[1-9][0-9]{0,5}$'
   or (chunk->>'audio_tokens')::bigint>(spec->'speech'->>'max_output_tokens')::bigint
   or ((spec->'speech') ? 'serving_limit_tokens' and (chunk->>'audio_tokens')::bigint < (spec->'speech'->>'serving_limit_tokens')::bigint)
  then raise exception 'invalid_provider_attempt'; end if;
  total:=total+(chunk->>'audio_tokens')::bigint;
 end loop;
 if total>coalesce((spec->'speech'->>'max_audio_tokens')::bigint,(spec->'speech'->>'max_output_tokens')::bigint) then raise exception 'invalid_provider_attempt'; end if;
 update app_private.podcast_jobs set speech_calls=n,lease_until=clock_timestamp()+interval '15 minutes' where id=j.id returning * into j;
 for chunk in select c from jsonb_array_elements(p_chunks) c loop
  admission:=app_private.podcast_grant(j,spec,(chunk->>'attempt_id')::uuid,'podcast_speech',decode(chunk->>'request_sha256','hex'),i,(chunk->>'audio_tokens')::bigint);
  if not (admission->>'granted')::boolean then
   for g in select value from jsonb_array_elements(granted) loop
    perform public.worker_provider_attempt_finish((g->>'account_id')::uuid,(g->>'operation_id')::uuid,(g->>'attempt_id')::uuid,'rejected',null,0,'{}','speech_batch_refused');
   end loop;
   j:=app_private.podcast_settle(j,'failed','provider_admission_refused');
   return jsonb_build_object('granted',false,'reason',admission->'reason','ordinal',i);
  end if;
  granted:=granted||jsonb_build_array(admission);
  i:=i+1;
 end loop;
 return jsonb_build_object('granted',true,'attempts',granted);
end $$;

revoke all on function public.worker_podcast_speech_begin(uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.worker_podcast_speech_begin(uuid,uuid,bigint,jsonb) to service_role;

notify pgrst,'reload schema';
commit;
