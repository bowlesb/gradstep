-- DeepSeek profiles, version 5 (docs/architecture/PAPER_PODCASTS.md "DeepSeek script provider"). The third live seed
-- on 2026-10-14 (job 1e2c27d6) ended script_incomplete: DeepSeek's JSON is more verbose than Sonnet's and the draft
-- reached the 6,000-token output cap copied from the Sonnet profiles (an offline draft of a comparable paper used
-- 4,378). Version 5 copies version 4 with the draft and repair output caps raised by half, the review and repair input
-- caps following (they carry the draft), and every ceiling recomputed at the same peak rates. Version 4 stays for
-- its quotes and jobs; the policy pointer moves through the audited path, not here.
begin;
set local lock_timeout='15s';

insert into app_private.podcast_profiles(id,version,spec,spec_sha256)
select id,5,spec,sha256(convert_to(spec::text,'UTF8')) from (
 select v.id,
  jsonb_set(jsonb_set(jsonb_set(jsonb_set(v.spec,
   '{version}','5'::jsonb),
   '{script,calls}',s.calls),
   '{ceiling_microusd}',to_jsonb(c.total)),
   '{max_credits}',to_jsonb(c.credits))
  || jsonb_build_object('hold_microusd',c.credits*5000) as spec
 from app_private.podcast_profiles v
 cross join lateral (
  -- The draft's output cap ×1.5; the review reads the draft (+1,000 framing), the repair reads it twice over (+2,000).
  select (select (t.c->>'max_output_tokens')::bigint from jsonb_array_elements(v.spec->'script'->'calls') t(c) where t.c->>'route'='podcast_script') as draft_out) d
 cross join lateral (
  select jsonb_agg(
    (case t.c->>'route'
      when 'podcast_script' then t.c||jsonb_build_object('max_output_tokens',ceil(d.draft_out*1.5)::bigint)
      when 'podcast_review' then t.c||jsonb_build_object('max_input_tokens',80000+ceil(d.draft_out*1.5)::bigint+1000)
      when 'podcast_script_repair' then t.c||jsonb_build_object('max_input_tokens',80000+ceil(d.draft_out*1.5)::bigint+2000,'max_output_tokens',ceil(d.draft_out*1.5)::bigint)
      else t.c end)
    ||jsonb_build_object('ceiling_microusd',ceil(
      (case t.c->>'route'
        when 'podcast_script' then (t.c->>'max_input_tokens')::numeric*1.32+ceil(d.draft_out*1.5)*3.96
        when 'podcast_review' then (80000+ceil(d.draft_out*1.5)+1000)*1.32+(t.c->>'max_output_tokens')::numeric*3.96
        when 'podcast_script_repair' then (80000+ceil(d.draft_out*1.5)+2000)*1.32+ceil(d.draft_out*1.5)*3.96
        else (t.c->>'max_input_tokens')::numeric*1.32+(t.c->>'max_output_tokens')::numeric*3.96 end))::bigint)
    order by t.o) as calls,
   sum(ceil(
      (case t.c->>'route'
        when 'podcast_script' then (t.c->>'max_input_tokens')::numeric*1.32+ceil(d.draft_out*1.5)*3.96
        when 'podcast_review' then (80000+ceil(d.draft_out*1.5)+1000)*1.32+(t.c->>'max_output_tokens')::numeric*3.96
        when 'podcast_script_repair' then (80000+ceil(d.draft_out*1.5)+2000)*1.32+ceil(d.draft_out*1.5)*3.96
        else (t.c->>'max_input_tokens')::numeric*1.32+(t.c->>'max_output_tokens')::numeric*3.96 end))::bigint) as script_total
  from jsonb_array_elements(v.spec->'script'->'calls') with ordinality as t(c,o)) s
 cross join lateral (
  select s.script_total+(v.spec->'speech'->>'ceiling_microusd')::bigint as total,
   ceil((s.script_total+(v.spec->'speech'->>'ceiling_microusd')::bigint)::numeric/50000)*10 as credits) c
 where v.version=4 and v.id in ('podcast-short-v1','podcast-5min-v1','podcast-10min-v1','podcast-20min-v1')
  and not exists(select 1 from app_private.podcast_profiles x where x.id=v.id and x.version=5)
) x;

-- The stated totals are the sums of their parts; the caps grew as intended; everything else is version 4's.
do $$
begin
 if (select count(*) from app_private.podcast_profiles where version=5)<>4 then raise exception 'podcast_profile_v5_missing'; end if;
 if exists(select 1 from app_private.podcast_profiles p join app_private.podcast_profiles q on q.id=p.id and q.version=4 where p.version=5 and (
   p.spec->'script'->>'provider'<>'deepseek' or p.spec->'script'->>'model'<>'deepseek-v4-pro'
   or p.spec->>'consent_version'<>'podcast-private-v2'
   or (select count(*) from jsonb_array_elements(p.spec->'script'->'calls') c)<>3
   or exists(select 1 from jsonb_array_elements(p.spec->'script'->'calls') c
     where (c->>'ceiling_microusd')::bigint<>ceil((c->>'max_input_tokens')::numeric*1.32+(c->>'max_output_tokens')::numeric*3.96)::bigint)
   or (select (c->>'max_output_tokens')::numeric from jsonb_array_elements(p.spec->'script'->'calls') c where c->>'route'='podcast_script')
     <>ceil((select (c->>'max_output_tokens')::numeric from jsonb_array_elements(q.spec->'script'->'calls') c where c->>'route'='podcast_script')*1.5)
   or (p.spec->>'ceiling_microusd')::bigint<>(select sum((c->>'ceiling_microusd')::bigint) from jsonb_array_elements(p.spec->'script'->'calls') c)
     +(p.spec->'speech'->>'ceiling_microusd')::bigint
   or (p.spec->>'max_credits')::bigint<>ceil((p.spec->>'ceiling_microusd')::numeric/50000)*10
   or (p.spec->>'hold_microusd')::bigint<>(p.spec->>'max_credits')::bigint*5000
   or (p.spec->>'version')::integer<>5
   or p.spec-'version'-'script'-'ceiling_microusd'-'max_credits'-'hold_microusd'<>q.spec-'version'-'script'-'ceiling_microusd'-'max_credits'-'hold_microusd')) then
  raise exception 'podcast_profile_v5_arithmetic'; end if;
end $$;
commit;
