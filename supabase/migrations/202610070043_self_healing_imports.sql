-- Self-healing imports (owner, build 17: "we need to build maintenance and this type of cleanup into general
-- use so these things are self cleaning or fixing but never just sitting there"). Additive over 022/027/034/039/040.
-- Design: docs/architecture/PIPELINE_RELIABILITY.md "Self-healing imports".
--
-- 1. Automatic retries beyond downloads. 027 retried failed downloads (15 min / 2 h / 12 h). A paper that fails
--    for a reason that can change at metadata (details unavailable after throttling, unreachable source, crash
--    loop) or at render (a re-render reuses the stored OCR: nothing is charged) is now retried 10 min, 30 min,
--    1 h, 3 h, 6 h and 12 h later: six tries over about 23 h. Downloads keep 027's ladder. Paid stages are never
--    retried automatically (an OCR failure may already have been billed; the reader's Retry stays), nor are
--    permanent refusals (no resume stage, too large, sign-in, not open, invalid). A retry is 027's: the import
--    moves back exactly as the reader's Retry does, so funding, credit checks and spending admission are the
--    normal ones for the paper the reader asked for.
-- 2. Nothing waits unscheduled. worker_pipeline_heal (the worker, before each claim, at most every minute)
--    schedules any retryable failure that has no schedule yet (failures from before this migration, e.g.
--    2610.07426 on staging, and any path that bypassed the trigger), and fails papers that have sat in a
--    non-paid stage for 6 hours while someone waits (a silent loop: repeated deferrals, a lost wakeup) with
--    the stage's own code, which then follows the same bounded retries. Budget pauses and a full paper store
--    are deliberate waits, shown as waiting, and are left alone; expired claims stay with 022's crash sweep.
-- 3. A scheduled retry reads as `download_retrying` only for downloads; other failures keep their own reason
--    (and the entry's `auto_retry_at`) instead of "Couldn't download yet".
--
-- A failure that exhausts its retries stays in the reader's library with its reason and actions (Retry when
-- retryable, supply the PDF when not open, Remove); nothing is deleted on the reader's behalf.
--
-- Lock order: the heal sweep takes paper rows (SKIP LOCKED, unclaimed only), then the policy throttle row,
-- like 027/034's sweeps after their account step; it takes no account, library, budget or purchase lock.
begin;
set local lock_timeout='15s';

alter table app_private.pipeline_policy add column heal_swept_at timestamptz not null default '-infinity';

-- When a failed paper is next retried automatically (null: not automatically).
create function app_private.pipeline_auto_retry_delay(p_resume text,p_error text,p_retries integer) returns interval
language sql immutable set search_path='' as $$
 select case
  when p_resume='download' and p_error in ('download_failed','source_unavailable','source_blocked','not_pdf','rate_limited') and p_retries<3
   then (array[interval '15 minutes',interval '2 hours',interval '12 hours'])[p_retries+1]
  when ((p_resume='metadata' and p_error in ('metadata_unavailable','rate_limited','source_unavailable'))
     or (p_resume='render' and p_error='conversion_failed')) and p_retries<6
   then (array[interval '10 minutes',interval '30 minutes',interval '1 hour',interval '3 hours',interval '6 hours',interval '12 hours'])[p_retries+1]
 end
$$;

-- 027's trigger function, generalized: the ladder above; leaving any non-paid stage forward (not to a failure
-- or a credit pause; a restart from `failed` is not "forward") starts the next failure's back-off afresh.
create or replace function app_private.pipeline_auto_retry_schedule() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.stage='failed' then
  new.auto_retry_at:=clock_timestamp()+app_private.pipeline_auto_retry_delay(new.resume_stage,new.error_code,new.auto_retries);
 else
  new.auto_retry_at:=null;
  if old.stage in ('metadata','private_split','download','render') and new.stage not in ('failed','needs_credits') then new.auto_retries:=0; end if;
 end if;
 return new;
end $$;

-- Failed papers someone still wants whose failure can be retried automatically but has no schedule.
create function app_private.pipeline_schedule_unscheduled(p_limit integer) returns integer
language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 update app_private.pipeline_papers pp set auto_retry_at=clock_timestamp()
  where pp.id in (select x.id from app_private.pipeline_papers x
   where x.stage='failed' and x.auto_retry_at is null
    and app_private.pipeline_auto_retry_delay(x.resume_stage,x.error_code,x.auto_retries) is not null
    and (x.lease_until is null or x.lease_until<=clock_timestamp())
    and exists(select 1 from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
     join app_private.accounts a on a.id=i.account_id and a.closed_at is null
     where pi.paper_id=x.id and i.phase='failed' and i.retryable and i.desired_present)
   order by x.updated_at,x.id limit p_limit for no key update skip locked);
 get diagnostics n=row_count;
 return n;
end $$;

-- The worker's maintenance sweep before each claim (p_min_interval_seconds throttles concurrent workers).
create function public.worker_pipeline_heal(p_min_interval_seconds integer default 0,p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path='' as $$
declare stalled uuid[]; paper uuid; st text; scheduled integer;
begin
 if p_min_interval_seconds is null or p_min_interval_seconds not between 0 and 3600 or p_limit is null or p_limit not between 1 and 100
 then raise exception 'invalid_heal_request'; end if;
 if not exists(select 1 from app_private.pipeline_policy where singleton and enabled
  and heal_swept_at<=clock_timestamp()-make_interval(secs=>p_min_interval_seconds))
 then return jsonb_build_object('swept',false,'scheduled',0,'stalled',0); end if;
 -- Paper rows first (claimed or locked ones are skipped), then the throttle row.
 select coalesce(array_agg(x.id order by x.id),'{}') into stalled from (
  select pp.id from app_private.pipeline_papers pp
  where pp.stage in ('metadata','private_split','download','render') and pp.stage_entered_at<clock_timestamp()-interval '6 hours'
   and (pp.lease_until is null or pp.lease_until<=clock_timestamp())
   and pp.error_code is distinct from 'service_paused' and pp.error_code is distinct from 'storage_full'
   and app_private.pipeline_interest(pp.id)
  order by pp.stage_entered_at,pp.id limit p_limit for no key update skip locked
 ) x;
 update app_private.pipeline_policy set heal_swept_at=clock_timestamp()
  where singleton and enabled and heal_swept_at<=clock_timestamp()-make_interval(secs=>p_min_interval_seconds);
 if not found then return jsonb_build_object('swept',false,'scheduled',0,'stalled',0); end if;
 foreach paper in array stalled loop
  select stage into st from app_private.pipeline_papers where id=paper;
  perform app_private.pipeline_set_stage(paper,'failed',
   case st when 'download' then 'download_failed' when 'render' then 'conversion_failed' else 'metadata_unavailable' end,
   case st when 'private_split' then 'metadata' else st end);
 end loop;
 scheduled:=app_private.pipeline_schedule_unscheduled(p_limit);
 return jsonb_build_object('swept',true,'scheduled',scheduled,'stalled',cardinality(stalled));
end $$;

-- 040's projection after a deferral, plus: the step turning to `waiting` is told at once. Otherwise a pause found
-- within 5 s of the stage's own projection (a budget pause at funding, a throttled first request) waited for the
-- next deferral while the reader's count-down ran on towards 99 %. One write per transition; later details keep
-- the 5 s throttle.
create function app_private.import_progress_waits(p_old jsonb,p_old_at timestamptz,p_new jsonb) returns boolean
language sql stable set search_path='' as $$
 select p_old_at is null or p_old_at<=clock_timestamp()-interval '5 seconds'
  or (p_new->>'step'='waiting' and p_old->>'step' is distinct from 'waiting')
$$;
create or replace function public.worker_pipeline_project_progress(p_paper_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare link record; imp app_private.import_requests; acct uuid; due uuid[]:='{}'; ready uuid[]:='{}'; s bigint; changed integer:=0; d jsonb;
begin
 if p_paper_id is null then raise exception 'invalid_progress'; end if;
 for link in select i.account_id,i.id,i.progress_detail,i.progress_at from app_private.pipeline_imports pi
  join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
  where pi.paper_id=p_paper_id and i.desired_present and i.phase in ('accepted','resolving','acquiring') order by i.account_id,i.id loop
  select * into imp from app_private.import_requests where account_id=link.account_id and id=link.id;
  d:=app_private.import_progress_detail(imp,link.progress_detail);
  if app_private.import_progress_waits(link.progress_detail,link.progress_at,d) and app_private.import_progress_news(link.progress_detail,link.progress_at,d)
   and not link.account_id=any(due) then due:=due||link.account_id; end if;
 end loop;
 foreach acct in array due loop
  begin
   perform public.worker_consume_request(acct,'library-progress');
   ready:=ready||acct;
  exception when others then null;
  end;
 end loop;
 if cardinality(ready)=0 then return 0; end if;
 perform 1 from app_private.accounts where id=any(ready) and closed_at is null order by id for no key update;
 for link in select pi.account_id,pi.import_id from app_private.pipeline_imports pi where pi.paper_id=p_paper_id and pi.account_id=any(ready)
  order by pi.account_id,pi.import_id loop
  begin
   perform app_private.lock_library_state(link.account_id);
   select * into imp from app_private.import_requests where account_id=link.account_id and id=link.import_id;
   d:=case when imp.desired_present and imp.phase in ('accepted','resolving','acquiring') then app_private.import_progress_detail(imp,imp.progress_detail) end;
   if d is not null and app_private.import_progress_waits(imp.progress_detail,imp.progress_at,d) and app_private.import_progress_news(imp.progress_detail,imp.progress_at,d) then
    s:=app_private.library_next_seq(imp.account_id);
    update app_private.import_requests set state_seq=s where account_id=imp.account_id and id=imp.id;
    perform app_private.library_emit(imp.account_id,s,jsonb_build_array(app_private.library_import_entry(imp.account_id,imp.id)));
    changed:=changed+1;
   end if;
  exception when others then null;
  end;
 end loop;
 return changed;
end $$;

-- 039's projection, verbatim except: a scheduled retry reads `download_retrying` only for a download.
create or replace function public.worker_pipeline_sync_imports(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns integer
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; link record; i app_private.import_requests; s bigint; changed integer:=0; target text; err text; retry boolean;
 acct uuid; ready uuid[]:='{}';
begin
 select * into p from app_private.pipeline_papers where id=p_paper_id;
 if not found or p.claim_id is distinct from p_claim_id or p.generation is distinct from p_generation or p.lease_until<=clock_timestamp()
 then raise exception 'stale_pipeline_claim'; end if;
 for acct in select distinct pi.account_id from app_private.pipeline_imports pi where pi.paper_id=p.id and pi.synced_revision<p.state_revision
  and pi.next_sync_at<=clock_timestamp() order by pi.account_id loop
  begin
   perform public.worker_consume_request(acct,'library-write');
   ready:=ready||acct;
  exception when others then
   update app_private.pipeline_imports set sync_failures=sync_failures+1,
    next_sync_at=clock_timestamp()+make_interval(secs=>least(3600,15*power(2,least(sync_failures,8))::integer))
    where paper_id=p.id and account_id=acct;
  end;
 end loop;
 perform 1 from app_private.accounts where id=any(ready) and closed_at is null order by id for no key update;
 for link in select pi.* from app_private.pipeline_imports pi where pi.paper_id=p.id and pi.synced_revision<p.state_revision
  and pi.account_id=any(ready) order by pi.account_id,pi.import_id loop
  begin
   select * into i from app_private.import_requests where account_id=link.account_id and id=link.import_id;
   if i.desired_present and i.phase in ('accepted','resolving','acquiring') then
    if p.stage='done' then
     perform public.worker_resolve_import(i.account_id,i.id,i.state_seq,i.intent_revision,p.approval_id,p.artifact_id);
    else
     target:=case when p.stage='metadata' then 'resolving'
      when p.stage in ('private_split','download','ocr_fund','ocr_submit','ocr_wait','ocr_uncertain','render') then 'acquiring'
      when p.stage='source_only' then 'source_only' else 'failed' end;
     err:=case when p.stage='source_only' then 'license_unverified' when p.stage='needs_credits' then 'insufficient_credits'
      when p.stage='failed' then case when p.auto_retry_at is not null and p.resume_stage='download' then 'download_retrying'
       when p.error_code in ('metadata_unavailable','download_failed','pdf_invalid','rate_limited','too_large','conversion_failed',
        'source_unavailable','source_blocked','not_pdf','pdf_restricted','not_open','upload_failed') then p.error_code
       when p.resume_stage='metadata' then 'metadata_unavailable' when p.resume_stage='download' then 'download_failed' else 'conversion_failed' end end;
     retry:=p.stage='needs_credits' or (p.stage='failed' and p.resume_stage is not null);
     perform app_private.lock_library_account(i.account_id); perform app_private.lock_library_state(i.account_id);
     select * into strict i from app_private.import_requests where account_id=link.account_id and id=link.import_id;
     if i.desired_present and i.phase in ('accepted','resolving','acquiring') then
      s:=app_private.library_next_seq(i.account_id);
      update app_private.import_requests set phase=target,metadata_id=coalesce(metadata_id,p.metadata_id),state_seq=s,
       error_code=err,retryable=coalesce(retry,false),progress=coalesce(app_private.pipeline_progress(p.stage),progress),
       auto_retry_at=case when target='failed' then p.auto_retry_at end
       where account_id=i.account_id and id=i.id;
      perform app_private.library_emit(i.account_id,s,jsonb_build_array(app_private.library_import_entry(i.account_id,i.id)));
     end if;
    end if;
    changed:=changed+1;
   end if;
   update app_private.pipeline_imports set synced_revision=p.state_revision,sync_failures=0 where account_id=link.account_id and import_id=link.import_id;
  exception when others then
   update app_private.pipeline_imports set sync_failures=sync_failures+1,
    next_sync_at=clock_timestamp()+make_interval(secs=>least(3600,15*power(2,least(sync_failures,8))::integer))
    where account_id=link.account_id and import_id=link.import_id;
  end;
 end loop;
 return changed;
end $$;

-- 024's snapshot for the workflow checks, plus: stuck work and stale imports are measured from their last change
-- and leave out deliberate waits (reported as `waiting`), and the self-healing sweeps' health.
create or replace function public.worker_workflow_snapshot() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare url text; secret_digest text; cron_state jsonb; calls jsonb;
begin
 if to_regnamespace('vault') is not null then
  execute $q$select (select decrypted_secret from vault.decrypted_secrets where name='science_reader_pipeline_url'),
   (select encode(sha256(convert_to(decrypted_secret,'UTF8')),'hex') from vault.decrypted_secrets where name='science_reader_pipeline_secret')$q$
   into url,secret_digest;
 end if;
 if to_regclass('cron.job') is not null then
  execute $q$select jsonb_build_object('active',active,'schedule',schedule) from cron.job where jobname='science-reader-pipeline'$q$ into cron_state;
 end if;
 if to_regclass('net._http_response') is not null then
  execute $q$select jsonb_build_object('ok',count(*) filter (where status_code between 200 and 299),
   'unauthorized',count(*) filter (where status_code in (401,403)),'missing',count(*) filter (where status_code=404),
   'server',count(*) filter (where status_code>=500),'timed_out',count(*) filter (where timed_out),
   'last_ok',max(created) filter (where status_code between 200 and 299)) from net._http_response where created>now()-interval '15 minutes'$q$ into calls;
 end if;
 return (with resting as (
   select pp.id from app_private.pipeline_papers pp where pp.owner_id is null and pp.stage='private_split'
    and not exists(select 1 from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
     where pi.paper_id=pp.id and i.desired_present and i.phase in ('accepted','resolving','acquiring'))),
  working as (select pp.* from app_private.pipeline_papers pp where pp.stage not in ('done','failed','source_only','needs_credits')
   and pp.id not in (select id from resting)),
  -- Deliberate waits, retried every few minutes and shown to readers as waiting: a budget pause, an account at its
  -- active-operation limit (both service_paused) or a full paper store. Reported apart from stuck work.
  waiting as (select * from working where error_code in ('service_paused','storage_full')),
  moving as (select * from working where id not in (select id from waiting))
  select jsonb_build_object(
   'pipeline_url',url,'pipeline_secret_sha256',secret_digest,'cron',cron_state,'worker_calls',calls,
   'pipeline_enabled',(select enabled from app_private.pipeline_policy),
   'budget',(select jsonb_build_object('work_enabled',work_enabled,'limit_microusd',limit_microusd,'spent_microusd',spent_microusd,'reserved_microusd',reserved_microusd)
     from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),
   'stuck',(select coalesce(jsonb_agg(jsonb_build_object('source',source_id,'private',owner_id is not null,'stage',stage,
     'minutes',floor(extract(epoch from (now()-stage_entered_at))/60),'claims',stage_claims,'crashes',stage_crashes) order by stage_entered_at),'[]'::jsonb)
     from moving where stage_entered_at<now()-interval '15 minutes'),
   'looping',(select coalesce(jsonb_agg(jsonb_build_object('source',source_id,'stage',stage,'claims',stage_claims,'crashes',stage_crashes)),'[]'::jsonb)
     from moving where stage_crashes>=2 or (stage<>'ocr_wait' and stage_claims>=30)),
   'waiting',(select jsonb_build_object('papers',count(*),'oldest_minutes',floor(extract(epoch from (now()-min(stage_entered_at)))/60),
     'causes',coalesce(jsonb_object_agg(error_code,1),'{}'::jsonb)) from waiting),
   'resting_split',(select count(*) from resting),
   'uncertain_ocr',(select count(*) from app_private.ocr_attempts where state='uncertain'),
   -- Unchanged for an hour (progress_at moves with every state change of an active import, including a
   -- restart by Retry, an automatic retry or a credit resume), unless its paper is deliberately waiting.
   'stale_imports',(select count(*) from app_private.import_requests i where i.desired_present and i.phase in ('accepted','resolving','acquiring')
     and coalesce(i.progress_at,i.created_at)<now()-interval '60 minutes'
     and not exists(select 1 from app_private.pipeline_imports pi join waiting w on w.id=pi.paper_id where (pi.account_id,pi.import_id)=(i.account_id,i.id))),
   -- Self-healing (043): retryable failures someone waits for must have a schedule, and schedules must run.
   'unscheduled_failures',(select count(*) from app_private.pipeline_papers pp where pp.stage='failed' and pp.auto_retry_at is null
     and app_private.pipeline_auto_retry_delay(pp.resume_stage,pp.error_code,pp.auto_retries) is not null
     and exists(select 1 from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
      where pi.paper_id=pp.id and i.phase='failed' and i.retryable and i.desired_present)),
   'overdue_retries',(select count(*) from app_private.pipeline_papers where stage='failed' and auto_retry_at<now()-interval '15 minutes'),
   'crashes_24h',(select coalesce(jsonb_object_agg(stage,n),'{}'::jsonb) from (select stage,count(*) n from app_private.pipeline_events
     where kind='crash' and at>now()-interval '24 hours' group by stage) c),
   'import_failures_24h',(select coalesce(jsonb_object_agg(cause,n),'{}'::jsonb) from (select coalesce(error_code,'unknown') cause,count(*) n
     from app_private.pipeline_events where kind='import' and phase='failed' and at>now()-interval '24 hours' group by 1) f)));
end $$;

-- Existing failures waiting without a schedule (before this migration only downloads had one) are due now.
select app_private.pipeline_schedule_unscheduled(1000);

revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
revoke all on function public.worker_pipeline_heal(integer,integer),public.worker_workflow_snapshot(),public.worker_pipeline_project_progress(uuid) from public,anon,authenticated;
grant execute on function public.worker_pipeline_heal(integer,integer),public.worker_workflow_snapshot(),public.worker_pipeline_project_progress(uuid) to service_role;
notify pgrst,'reload schema';
commit;
