-- Import reliability (migration 022): a dead worker's expired claim is a crash; crashes back off;
-- three in a stage without provider work fail the paper (retryable); provider stages never
-- auto-fail; stage changes reset counters and record events; owner-only metrics.
begin;
insert into auth.users values('22000000-0000-0000-0000-00000000000a'),('22000000-0000-0000-0000-00000000000b');
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_set_pipeline_enabled(true);
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub','22000000-0000-0000-0000-00000000000a',false);
select public.v2_begin_import('22000000-0000-0000-0000-0000000000a1','2305.18290',0)->'entry'->>'phase' as phase \gset
reset role;
select test.assert(exists(select 1 from app_private.pipeline_events where kind='import' and phase='accepted' and source_id like '2305.18290%'),
 'an accepted import is recorded');
select id as paper from app_private.pipeline_papers where source_id='2305.18290' \gset

-- A claim that dies: its lease expires while still claimed.
set role service_role;
select public.worker_pipeline_claim(gen_random_uuid())->>'stage' as stage \gset
select test.assert(:'stage'='metadata','claimed metadata');
reset role;
select test.assert((select stage_claims from app_private.pipeline_papers where id=:'paper')=1,'claims are counted per stage');
update app_private.pipeline_papers set lease_until=clock_timestamp()-interval '1 second' where id=:'paper';
set role service_role;
-- The import was never told about the stage, so the paper is claimed once more, but only to sync (not due).
select public.worker_pipeline_claim(gen_random_uuid()) as synced \gset
select test.assert(:'synced'::jsonb->>'due'='false','a crashed paper backs off: a sync-only claim does no stage work');
select public.worker_pipeline_sync_imports(:'paper',(:'synced'::jsonb->>'claim_id')::uuid,(:'synced'::jsonb->>'generation')::bigint);
select public.worker_pipeline_release(:'paper',(:'synced'::jsonb->>'claim_id')::uuid,(:'synced'::jsonb->>'generation')::bigint);
select test.assert(public.worker_pipeline_claim(gen_random_uuid()) is null,'nothing else is due');
reset role;
select test.assert((select stage_crashes=1 and claim_id is null and next_attempt_at>now()+interval '90 seconds' from app_private.pipeline_papers where id=:'paper'),
 'first crash: counted, released, 2 minutes back-off');
select test.assert((select count(*) from app_private.pipeline_events where kind='crash' and paper_id=:'paper')=1,'crash recorded');

-- Two more crashes in the same stage fail it, retryably, resuming that stage.
do $$ declare paper uuid:=(select id from app_private.pipeline_papers where source_id='2305.18290'); begin
 for n in 2..3 loop
  perform app_private.pipeline_sweep_crashes();
  update app_private.pipeline_papers set next_attempt_at=now()-interval '1 second' where id=paper;
  if public.worker_pipeline_claim(gen_random_uuid()) is null then raise exception 'expected a claim'; end if;
  update app_private.pipeline_papers set lease_until=clock_timestamp()-interval '1 second' where id=paper;
 end loop;
end $$;
set role service_role;
select public.worker_pipeline_claim(gen_random_uuid()) as reclaim \gset
reset role;
select test.assert((select stage='failed' and error_code='metadata_unavailable' and resume_stage='metadata' and stage_crashes=0
 from app_private.pipeline_papers where id=:'paper'),'third crash fails the stage with a retryable error');
select test.assert(exists(select 1 from app_private.pipeline_events where kind='stage' and paper_id=:'paper' and stage='metadata' and next_stage='failed'
 and error_code='metadata_unavailable' and claims>=3),'the stage exit is recorded with its claims');
select test.assert((:'reclaim'::jsonb->>'stage')='failed','the failed paper is claimed once to tell the import');

-- Provider stages only back off, capped at 30 minutes.
update app_private.pipeline_papers set stage='ocr_wait',error_code=null,resume_stage=null,claim_id=null,lease_until=null,next_attempt_at=now() where id=:'paper';
do $$ declare paper uuid:=(select id from app_private.pipeline_papers where source_id='2305.18290'); begin
 for n in 1..6 loop
  update app_private.pipeline_papers set claim_id=gen_random_uuid(),lease_until=clock_timestamp()-interval '1 second' where id=paper;
  perform app_private.pipeline_sweep_crashes();
 end loop;
end $$;
select test.assert((select stage='ocr_wait' and stage_crashes=6 and next_attempt_at<=now()+interval '30 minutes 5 seconds'
 and next_attempt_at>now()+interval '29 minutes' from app_private.pipeline_papers where id=:'paper'),'provider stages never auto-fail; back-off capped');

-- Metrics: owner with MFA only.
set role authenticated;
select set_config('request.jwt.claim.sub','22000000-0000-0000-0000-00000000000b',false);
select test.reject('select public.v1_admin_pipeline_metrics(30)','owner_mfa_required');
reset role;
insert into app_private.app_roles values('22000000-0000-0000-0000-00000000000b','owner',now());
set role authenticated;
select set_config('request.jwt.claim.aal','aal2',false);
select public.v1_admin_pipeline_metrics(7) as m \gset
select test.assert((:'m'::jsonb->'crashes'->>'metadata')::int=3 and (:'m'::jsonb->'crashes'->>'ocr_wait')::int=6,'crashes by stage');
select test.assert(exists(select 1 from jsonb_array_elements(:'m'::jsonb->'stages') s where s->>'stage'='metadata' and (s->>'failed')::int=1),'stage failures');
select test.assert((select (d->>'started')::int from jsonb_array_elements(:'m'::jsonb->'daily') d order by d->>'day' desc limit 1)>=1,'daily starts');
select test.assert(jsonb_array_length(:'m'::jsonb->'recent_failures')>=4,'recent failures listed');
select test.reject('select public.v1_admin_pipeline_metrics(0)','invalid_metrics_window');
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject('select public.v1_admin_pipeline_metrics(7)','owner_mfa_required');
reset role;
set role anon;
select test.reject('select public.v1_admin_pipeline_metrics(7)','permission denied');
reset role;
rollback;
