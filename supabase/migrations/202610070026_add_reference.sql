-- Direct "Add to library" on a bibliography entry (owner, 2026-10-06: "if you click on a reference,
-- and ask for Add the reference, no chat is needed, it should just get queued … extremely reliable").
-- The add-reference function identifies the paper without a model and queues it with the
-- caller's own import; this migration adds its rate limit and an outcome record. Additive.
begin;
set local lock_timeout='15s';

insert into app_private.api_rate_rules values('add-reference',3600,120,2000) on conflict(route) do nothing;

-- Outcomes of direct adds join the reliability events (no account ids; the entry text is never stored).
alter table app_private.pipeline_events drop constraint pipeline_events_kind_check;
alter table app_private.pipeline_events add constraint pipeline_events_kind_check check(kind in ('stage','crash','import','reference'));

create function public.worker_record_reference_event(p_result text,p_route text,p_source_id text,p_duration_ms bigint) returns void
language plpgsql security definer set search_path='' as $$
begin
 if p_result !~ '^[a-z_]{1,32}$' or p_route !~ '^[a-z_]{1,32}$' or (p_source_id is not null and length(p_source_id)>200)
  or p_duration_ms is null or p_duration_ms<0 then raise exception 'invalid_reference_event'; end if;
 insert into app_private.pipeline_events(kind,source_id,phase,error_code,duration_ms) values('reference',p_source_id,p_result,p_route,p_duration_ms);
end $$;
revoke all on function public.worker_record_reference_event(text,text,text,bigint) from public,anon,authenticated;
grant execute on function public.worker_record_reference_event(text,text,text,bigint) to service_role;
notify pgrst,'reload schema';
commit;
