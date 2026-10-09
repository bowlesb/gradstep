-- Podcast checker reports (docs/architecture/PAPER_PODCASTS.md, "Seed pilot fix 2: checker v3").
-- Both staging seed jobs on worker revision 00014 failed `script_evidence_rejected` and nothing
-- recorded which rule failed: job events held only the failure code. The worker now records, for
-- every checker outcome (accepted, degraded or rejected, including invalid review corrections and
-- scripts too long for speech), a bounded report as a `checked` job event, written in the same job's
-- event log immediately before its `settled` event or before speech is bought.
--
-- A report holds counts, reason codes, segment and chapter ids and character offsets only. The
-- database enforces that it cannot carry paper or script text: every key is a short identifier, every
-- string value a short lower-case code, arrays and nesting are bounded, and the whole object fits the
-- existing 2,048-byte event bound. Writing requires the job's current fenced claim (the same fence as
-- every other worker call), so only the worker running the job can record. Nothing in 048 or 049 is
-- changed; the deployed worker (which never calls these functions) keeps working before and after.
begin;

-- Counts, codes, ids and offsets: no free text can pass.
create function app_private.podcast_report_valid(p jsonb,p_depth integer default 0) returns boolean
language plpgsql immutable set search_path='' as $$
declare k text; v jsonb;
begin
 if p is null or p_depth>4 then return false; end if;
 case jsonb_typeof(p)
  when 'object' then
   for k,v in select key,value from jsonb_each(p) loop
    if k !~ '^[a-z][a-z0-9_]{0,31}$' or not app_private.podcast_report_valid(v,p_depth+1) then return false; end if;
   end loop;
   return true;
  when 'array' then
   if jsonb_array_length(p)>50 then return false; end if;
   for v in select value from jsonb_array_elements(p) loop
    if not app_private.podcast_report_valid(v,p_depth+1) then return false; end if;
   end loop;
   return true;
  when 'string' then return (p#>>'{}') ~ '^[a-z0-9][a-z0-9_:.-]{0,63}$';
  when 'number' then return true;
  when 'boolean' then return true;
  else return false;
 end case;
end $$;

-- The worker's checker report for its fenced job (event kind `checked`).
create function public.worker_podcast_checked(p_job uuid,p_claim uuid,p_generation bigint,p_report jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs;
begin
 if p_report is null or jsonb_typeof(p_report)<>'object' or octet_length(p_report::text)>2048
  or not app_private.podcast_report_valid(p_report) then raise exception 'invalid_podcast_report'; end if;
 j:=app_private.podcast_fenced(p_job,p_claim,p_generation);
 perform app_private.podcast_event(j.id,'checked',p_report);
 return jsonb_build_object('recorded',true);
end $$;

-- Read-only operator view of one job's event log (stage, claim, attempt, checker and settlement records;
-- never content), for `podcast-ops.py events --job <id>`.
create function public.worker_podcast_job_events(p_job uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('job_id',j.id,'state',j.state,'failure',j.failure_code,
  'events',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'kind',e.kind,'details',e.details,'at',e.created_at) order by e.id)
   from app_private.podcast_job_events e where e.job_id=j.id),'[]'::jsonb))
 from app_private.podcast_jobs j where j.id=p_job
$$;

revoke all on function app_private.podcast_report_valid(jsonb,integer) from public,anon,authenticated,service_role;
revoke all on function public.worker_podcast_checked(uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.worker_podcast_job_events(uuid) from public,anon,authenticated,service_role;
grant execute on function public.worker_podcast_checked(uuid,uuid,bigint,jsonb) to service_role;
grant execute on function public.worker_podcast_job_events(uuid) to service_role;

notify pgrst,'reload schema';
commit;
