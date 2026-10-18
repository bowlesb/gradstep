-- 090: Unclaimed metadata with no interested import is idle, not a stuck download.
-- PIPELINE_RELIABILITY.md: preserve alerts for interested readers and every claimed row.
begin;
set local lock_timeout='15s';
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
  idle_metadata as (select id from app_private.pipeline_papers where stage='metadata' and claim_id is null and not app_private.pipeline_interest(id)),
  working as (select pp.* from app_private.pipeline_papers pp where pp.stage not in ('done','failed','source_only','needs_credits')
   and pp.id not in (select id from resting) and pp.id not in (select id from idle_metadata)),
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
   'resting_split',(select count(*) from resting),'resting_metadata',(select count(*) from idle_metadata),
   'uncertain_ocr',(select count(*) from app_private.ocr_attempts where state='uncertain'),
   -- Unchanged for an hour (progress_at moves with every state change of an active import, including a
   -- restart by Retry, an automatic retry or a credit resume), unless its paper is deliberately waiting.
   'stale_imports',(select count(*) from app_private.import_requests i where i.desired_present and i.phase in ('accepted','resolving','acquiring')
     and coalesce(i.progress_at,i.created_at)<now()-interval '60 minutes'
     and not exists(select 1 from app_private.pipeline_imports pi join waiting w on w.id=pi.paper_id where (pi.account_id,pi.import_id)=(i.account_id,i.id))),
   -- Self-healing (041): retryable failures someone waits for must have a schedule, and schedules must run.
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
notify pgrst, 'reload schema';
commit;
