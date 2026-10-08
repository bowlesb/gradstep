-- Self-healing imports (migration 041; owner feedback build 17): bounded automatic retries for metadata and
-- render failures (downloads keep 027's), none for paid stages or permanent refusals; every retryable failure
-- someone waits for gets a schedule; papers silently stalled in a non-paid stage for 6 h fail with their reason
-- and follow the same retries; a scheduled non-download retry keeps its own reason. Real RPCs throughout.
begin;
update app_private.pipeline_papers set lease_until=now()+interval '1 day',claim_id=coalesce(claim_id,gen_random_uuid());
create function test.sh_claim(p uuid) returns jsonb language plpgsql as $$
declare e jsonb;
begin
 update app_private.pipeline_papers set next_attempt_at=now()-interval '10 years' where id=p;
 e:=public.worker_pipeline_claim(gen_random_uuid());
 if e is null or (e->>'id')::uuid is distinct from p then raise exception 'expected to claim %, got %',p,coalesce(e->>'id','nothing'); end if;
 return e;
end $$;
-- As processPaper fails a stage after its tries: defer with p_fail, then the next claim tells the readers.
create function test.sh_fail(p uuid,code text,resume text) returns void language plpgsql as $$
declare e jsonb:=test.sh_claim(p);
begin
 perform public.worker_pipeline_defer(p,(e->>'claim_id')::uuid,(e->>'generation')::bigint,0,code,true,resume);
 e:=test.sh_claim(p);
 perform public.worker_pipeline_sync_imports(p,(e->>'claim_id')::uuid,(e->>'generation')::bigint);
 perform public.worker_pipeline_release(p,(e->>'claim_id')::uuid,(e->>'generation')::bigint);
end $$;
create function test.sh_minutes(p uuid) returns integer language sql as $$
 select round(extract(epoch from auto_retry_at-clock_timestamp())/60)::integer from app_private.pipeline_papers where id=p
$$;

insert into auth.users values('43000000-0000-0000-0000-00000000000a'),('43000000-0000-0000-0000-00000000000b');
\set A '43000000-0000-0000-0000-00000000000a'
\set B '43000000-0000-0000-0000-00000000000b'

-- Workers only; nothing while the pipeline is off.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject('select public.worker_pipeline_heal()','permission denied');
reset role;
set role anon;
select test.reject('select public.worker_pipeline_heal()','permission denied');
reset role;
select public.worker_set_pipeline_enabled(false);
select test.assert(not (public.worker_pipeline_heal()->>'swept')::boolean,'a disabled pipeline heals nothing');
select test.reject('select public.worker_pipeline_heal(0,0)','invalid_heal_request');
select public.worker_set_pipeline_enabled(true);
update app_private.pipeline_policy set heal_swept_at='-infinity',auto_retry_swept_at='-infinity';

-- The ladders: metadata and render six times over about 23 h; downloads as 027; paid stages and refusals never.
select test.assert(array(select extract(epoch from app_private.pipeline_auto_retry_delay('metadata','metadata_unavailable',n))/60 from generate_series(0,6) n)
 ='{10,30,60,180,360,720,NULL}'::numeric[],'metadata: 10 min, 30 min, 1 h, 3 h, 6 h, 12 h, then none');
select test.assert(app_private.pipeline_auto_retry_delay('render','conversion_failed',5)=interval '12 hours'
 and app_private.pipeline_auto_retry_delay('render','conversion_failed',6) is null,'render: the same six');
select test.assert(app_private.pipeline_auto_retry_delay('download','source_blocked',2)=interval '12 hours'
 and app_private.pipeline_auto_retry_delay('download','source_blocked',3) is null,'downloads keep 027''s three');
select test.assert(app_private.pipeline_auto_retry_delay('ocr_fund','download_failed',0) is null,'paid stages: the reader retries');
select test.assert(app_private.pipeline_auto_retry_delay('download','too_large',0) is null and app_private.pipeline_auto_retry_delay('download','pdf_restricted',0) is null
 and app_private.pipeline_auto_retry_delay(null,'metadata_unavailable',0) is null and app_private.pipeline_auto_retry_delay('render','pdf_invalid',0) is null,
 'refusals and permanent failures: never');

-- 1. Details unavailable (2610.07426 on staging): retried automatically, with its own reason meanwhile.
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_begin_import('43000000-0000-0000-0000-0000000000a1','2501.10001',0);
select paper_id as p from app_private.pipeline_imports where account_id=:'A' and import_id='43000000-0000-0000-0000-0000000000a1' \gset
select test.sh_fail(:'p','metadata_unavailable','metadata');
select test.assert((select stage='failed' and auto_retries=0 from app_private.pipeline_papers where id=:'p') and test.sh_minutes(:'p')=10,'first retry in 10 minutes');
select test.assert((select phase='failed' and error_code='metadata_unavailable' and retryable and auto_retry_at is not null
 from app_private.import_requests where account_id=:'A' and id='43000000-0000-0000-0000-0000000000a1'),'the reader sees its own reason (not "couldn''t download") and keeps Retry');
select test.assert(app_private.library_import_entry(:'A','43000000-0000-0000-0000-0000000000a1')->>'error_code'='metadata_unavailable'
 and app_private.library_import_entry(:'A','43000000-0000-0000-0000-0000000000a1') ? 'auto_retry_at','the entry carries the schedule');
update app_private.pipeline_papers set auto_retry_at=clock_timestamp()-interval '1 second' where id=:'p';
select test.assert((public.worker_pipeline_auto_retry(0,100)->>'retried')::integer>=1,'due: retried by the sweep');
select test.assert((select phase from app_private.import_requests where account_id=:'A' and id='43000000-0000-0000-0000-0000000000a1')='accepted'
 and (select intent_revision=1 from app_private.import_requests where account_id=:'A' and id='43000000-0000-0000-0000-0000000000a1'),'restarted like Retry, intent unchanged');
select test.assert((select auto_retries=1 and auto_retry_at is null from app_private.pipeline_papers where id=:'p'),'one automatic retry counted');
select test.assert(test.sh_claim(:'p')->>'stage'='metadata','the paper resumes finding its details');
update app_private.pipeline_papers set claim_id=null,lease_until=null where id=:'p';
select test.sh_fail(:'p','metadata_unavailable','metadata');
select test.assert(test.sh_minutes(:'p')=30,'second retry in 30 minutes');
-- Success resets the count for the next stage.
update app_private.pipeline_papers set auto_retry_at=clock_timestamp()-interval '1 second' where id=:'p';
select public.worker_pipeline_auto_retry(0,100);
select test.sh_claim(:'p') as e \gset
select public.worker_pipeline_metadata(:'p',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint,1,
 '{"title":"Healed","authors":[],"categories":["cs.LG"]}',true,'https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2501.10001','source_revision',1,'source_url','https://arxiv.org/abs/2501.10001v1','license_uri','https://creativecommons.org/licenses/by/4.0/',
  'evidence_sha256',repeat('e',64),'observed_at','2026-10-05T05:00:00Z'));
select public.worker_pipeline_release(:'p',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select test.assert((select stage='download' and auto_retries=0 from app_private.pipeline_papers where id=:'p'),'details found: the next stage starts its back-off afresh');

-- 2. After six automatic retries the failure stays, with its reason and Retry; nothing is deleted.
update app_private.pipeline_papers set stage='metadata' where id=:'p';
update app_private.pipeline_papers set auto_retries=6 where id=:'p';
update app_private.pipeline_papers set claim_id=null,lease_until=null where id=:'p';
select test.sh_fail(:'p','metadata_unavailable','metadata');
select test.assert((select auto_retry_at is null from app_private.pipeline_papers where id=:'p'),'exhausted: no further automatic retry');
select test.assert((select phase='failed' and retryable and desired_present and auto_retry_at is null from app_private.import_requests
 where account_id=:'A' and id='43000000-0000-0000-0000-0000000000a1'),'still in the library with Retry');

-- 3. Unscheduled failures (from before 041, or any path around the trigger) are scheduled by the heal sweep.
update app_private.pipeline_papers set auto_retries=0 where id=:'p';
select test.assert(public.worker_pipeline_heal(0)->>'swept'='true','swept');
select test.assert((select auto_retry_at<=clock_timestamp() from app_private.pipeline_papers where id=:'p'),'an unscheduled retryable failure is due at once');
-- Not when nobody waits for it.
update app_private.pipeline_papers set auto_retry_at=null where id=:'p';
select public.v2_cancel_import('43000000-0000-0000-0000-0000000000a9','43000000-0000-0000-0000-0000000000a1',1);
select public.worker_pipeline_heal(0);
select test.assert((select auto_retry_at is null from app_private.pipeline_papers where id=:'p'),'cancelled: nothing scheduled');

-- 4. Render failures (stored OCR, nothing charged) are scheduled; paid-stage failures are not.
select set_config('request.jwt.claim.sub',:'B',false);
select public.v2_begin_import('43000000-0000-0000-0000-0000000000b1','2501.10002',0);
select paper_id as r from app_private.pipeline_imports where account_id=:'B' and import_id='43000000-0000-0000-0000-0000000000b1' \gset
update app_private.pipeline_papers set stage='render' where id=:'r';
select test.sh_fail(:'r','conversion_failed','render');
select test.assert(test.sh_minutes(:'r')=10,'a failed re-render is retried in 10 minutes');
select test.assert((select error_code='conversion_failed' from app_private.import_requests where account_id=:'B' and id='43000000-0000-0000-0000-0000000000b1'),
 'shown as a conversion failure, not a download');
update app_private.pipeline_papers set stage='ocr_fund',resume_stage=null,error_code=null where id=:'r';
select app_private.pipeline_set_stage(:'r','failed','download_failed','ocr_fund');
select test.assert((select auto_retry_at is null from app_private.pipeline_papers where id=:'r'),'paid stage: no automatic retry');
select public.worker_pipeline_heal(0);
select test.assert((select auto_retry_at is null from app_private.pipeline_papers where id=:'r'),'and the heal sweep does not add one');

-- 5. A paper silently stalled for 6 h in a non-paid stage while someone waits fails with its reason and retries.
update app_private.pipeline_papers set stage='download',error_code=null,resume_stage=null,claim_id=null,lease_until=null where id=:'r';
select public.v2_retry_import('43000000-0000-0000-0000-0000000000b2','43000000-0000-0000-0000-0000000000b1',1);
-- (The restart was claimed long ago: the paper has sat in download since.)
update app_private.pipeline_imports set retry_requested=false where paper_id=:'r';
update app_private.pipeline_papers set stage_entered_at=clock_timestamp()-interval '7 hours',next_attempt_at=clock_timestamp()+interval '1 hour' where id=:'r';
-- Deliberate waits are left alone: a budget pause, a full store, a claim in progress, nobody waiting, or not long enough.
update app_private.pipeline_papers set error_code='service_paused' where id=:'r';
select test.assert((public.worker_pipeline_heal(0)->>'stalled')::integer=0,'a budget pause waits');
update app_private.pipeline_papers set error_code=null,claim_id=gen_random_uuid(),lease_until=clock_timestamp()+interval '1 minute' where id=:'r';
select test.assert((public.worker_pipeline_heal(0)->>'stalled')::integer=0,'a claimed paper is the worker''s');
update app_private.pipeline_papers set claim_id=null,lease_until=null,stage_entered_at=clock_timestamp()-interval '5 hours' where id=:'r';
select test.assert((public.worker_pipeline_heal(0)->>'stalled')::integer=0,'5 h is not stalled yet');
update app_private.pipeline_papers set stage_entered_at=clock_timestamp()-interval '7 hours' where id=:'r';
select test.assert(not (public.worker_pipeline_heal(3600)->>'swept')::boolean,'throttled');
select test.assert((public.worker_pipeline_heal(0)->>'stalled')::integer=1,'stalled for 7 h: failed');
select test.assert((select stage='failed' and error_code='download_failed' and resume_stage='download' from app_private.pipeline_papers where id=:'r')
 and test.sh_minutes(:'r')=15,'with its reason, resumable, on the download ladder');
select test.assert(exists(select 1 from app_private.pipeline_events where paper_id=:'r' and kind='stage' and stage='download' and error_code='download_failed'),
 'recorded for the reliability metrics');
-- The readers are told at the next claim (a pending projection makes the paper claimable).
select test.sh_claim(:'r') as e \gset
select public.worker_pipeline_sync_imports(:'r',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select test.assert((select phase='failed' and error_code='download_retrying' from app_private.import_requests where account_id=:'B' and id='43000000-0000-0000-0000-0000000000b1'),
 'a scheduled download retry reads as before');

-- 6. A budget (or active-operation) pause at funding is shown as waiting at once, and is not "stuck".
insert into auth.users values('43000000-0000-0000-0000-00000000000c');
select set_config('request.jwt.claim.sub','43000000-0000-0000-0000-00000000000c',false);
select public.v2_begin_import('43000000-0000-0000-0000-0000000000c1','2501.10003',0);
select paper_id as f from app_private.pipeline_imports where account_id='43000000-0000-0000-0000-00000000000c' and import_id='43000000-0000-0000-0000-0000000000c1' \gset
-- Resumed an hour after it was created (a credit resume): its last change is now, not its creation.
update app_private.import_requests set created_at=now()-interval '3 hours' where id='43000000-0000-0000-0000-0000000000c1';
update app_private.pipeline_papers set stage='ocr_fund',page_count=13 where id=:'f';
select test.sh_claim(:'f') as e \gset
select public.worker_pipeline_sync_imports(:'f',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select test.assert((select progress_detail->>'step'='reading_equations' and progress_at>clock_timestamp()-interval '5 seconds' from app_private.import_requests
 where id='43000000-0000-0000-0000-0000000000c1'),'funding starts: reading equations, projected a moment ago');
-- worker_pipeline_fund found the budget paused: the paper waits 5 min with service_paused (034), then the worker projects.
update app_private.pipeline_papers set next_attempt_at=clock_timestamp()+interval '5 minutes',error_code='service_paused' where id=:'f';
select public.worker_pipeline_release(:'f',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select test.assert(public.worker_pipeline_project_progress(:'f')=1,'the wait is told at once, inside the 5 s progress throttle');
select test.assert((select progress_detail->>'step'='waiting' and (progress_detail->>'delayed')::boolean and not progress_detail ? 'eta_seconds'
 from app_private.import_requests where id='43000000-0000-0000-0000-0000000000c1'),'Waiting to continue, no count-down');
select test.assert(public.worker_pipeline_project_progress(:'f')=0,'one write per transition');
select public.worker_workflow_snapshot() as snap \gset
select test.assert((:'snap'::jsonb->'waiting'->>'papers')::integer>=1 and :'snap'::jsonb->'waiting'->'causes' ? 'service_paused','reported as deliberately waiting');
select test.assert(not exists(select 1 from jsonb_array_elements(:'snap'::jsonb->'stuck') x where x->>'source'='2501.10003'),'not stuck');
-- An hour without a change while not waiting is stale; the creation time alone is not.
select (:'snap'::jsonb->>'stale_imports')::integer as stale_before \gset
update app_private.pipeline_papers set error_code=null where id=:'f';
select test.assert((public.worker_workflow_snapshot()->>'stale_imports')::integer=:stale_before,'created 3 h ago but changed just now: not stale');
update app_private.import_requests set progress_at=now()-interval '2 hours' where id='43000000-0000-0000-0000-0000000000c1';
select test.assert((public.worker_workflow_snapshot()->>'stale_imports')::integer=:stale_before+1,'unchanged for 2 h: stale');
-- The self-healing health counters.
update app_private.pipeline_papers set stage='failed',error_code='metadata_unavailable',resume_stage='metadata' where id=:'p';
select public.worker_workflow_snapshot() as snap \gset
select test.assert((:'snap'::jsonb->>'overdue_retries')::integer=0,'nothing overdue');
update app_private.pipeline_papers set auto_retry_at=now()-interval '20 minutes' where id=:'r';
select test.assert((public.worker_workflow_snapshot()->>'overdue_retries')::integer=1,'a retry overdue by 20 min is reported');
select (public.worker_workflow_snapshot()->>'unscheduled_failures')::integer as unscheduled_before \gset
update app_private.pipeline_papers set auto_retry_at=null where id=:'r';
select test.assert((public.worker_workflow_snapshot()->>'unscheduled_failures')::integer=:unscheduled_before+1,'a retryable failure without a schedule is reported');
rollback;
