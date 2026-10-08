-- Waiting for a busy source is shown as waiting (migration 040; owner feedback build 16 #10): a paper the worker
-- deferred because arXiv (or another source) throttled it reports step `waiting`, `delayed` and `source_busy`
-- with no count-down, and worker_pipeline_project_progress tells its readers as the wait starts.
begin;
update app_private.pipeline_papers set lease_until=now()+interval '1 day',claim_id=coalesce(claim_id,gen_random_uuid());
insert into auth.users values('41000000-0000-0000-0000-00000000000a');
\set W '41000000-0000-0000-0000-00000000000a'
\set IW '41000000-0000-0000-0000-0000000000a1'

set role authenticated;
select set_config('request.jwt.claim.sub',:'W',false);
select test.reject($q$select public.worker_pipeline_project_progress('41000000-0000-0000-0000-0000000000ff')$q$,'permission denied');
select public.v2_begin_import(:'IW','2501.00009',0);
reset role;
select test.reject('select public.worker_pipeline_project_progress(null)','invalid_progress');
select public.worker_set_pipeline_enabled(true);
select paper_id as p from app_private.pipeline_imports where account_id=:'W' and import_id=:'IW' \gset
select test.assert((select progress_detail->>'step'='finding' and progress_detail ? 'eta_seconds' from app_private.import_requests where account_id=:'W' and id=:'IW'),
 'a new import is finding the paper, with an estimate');

-- The worker's metadata request was throttled: it defers the paper (as processPaper does) and projects at once.
update app_private.pipeline_papers set next_attempt_at=now()-interval '10 years' where id=:'p';
select public.worker_pipeline_claim(gen_random_uuid()) as e \gset
select test.assert((:'e'::jsonb->>'id')::uuid=:'p','claimed');
select public.worker_pipeline_defer(:'p',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint,30,'rate_limited',false,null);
select test.assert((select app_private.pipeline_estimate(pp) from app_private.pipeline_papers pp where id=:'p')
 =jsonb_build_object('step','waiting','percent',0,'delayed',true,'reason','source_busy'),'a throttled paper waits, without a count-down');
update app_private.import_requests set progress_at=progress_at-interval '10 seconds' where account_id=:'W' and id=:'IW';
select state_seq as before_seq from app_private.import_requests where account_id=:'W' and id=:'IW' \gset
select test.assert(public.worker_pipeline_project_progress(:'p')=1,'the reader is told as the wait starts');
select test.assert((select progress_detail->>'step'='waiting' and (progress_detail->>'delayed')::boolean and progress_detail->>'reason'='source_busy'
 and not progress_detail ? 'eta_seconds' and state_seq>:before_seq from app_private.import_requests where account_id=:'W' and id=:'IW'),'projected with a new state_seq');
select test.assert(app_private.library_import_entry(:'W',:'IW')->'progress_detail'->>'step'='waiting','the entry carries the wait');
select test.assert(public.worker_pipeline_project_progress(:'p')=0,'no repeat within 5 s');
update app_private.import_requests set progress_at=progress_at-interval '10 seconds' where account_id=:'W' and id=:'IW';
select test.assert(public.worker_pipeline_project_progress(:'p')=0,'no news, no write');

-- Due again: finding (still flagged slow after a failure), no longer waiting.
update app_private.pipeline_papers set next_attempt_at=now()-interval '1 second' where id=:'p';
select test.assert((select app_private.pipeline_estimate(pp)->>'step'='finding' and not app_private.pipeline_estimate(pp) ? 'reason'
 from app_private.pipeline_papers pp where id=:'p'),'once due, the paper is finding again');
-- Other deferrals are not a busy source: an arXiv queue wait, or a failure that is not throttling.
update app_private.pipeline_papers set next_attempt_at=now()+interval '30 seconds',error_code=null where id=:'p';
select test.assert((select app_private.pipeline_estimate(pp)->>'step'='finding' from app_private.pipeline_papers pp where id=:'p'),'a queue wait is still finding');
update app_private.pipeline_papers set error_code='transient_failure' where id=:'p';
select test.assert((select app_private.pipeline_estimate(pp)->>'step'='finding' from app_private.pipeline_papers pp where id=:'p'),'another error is still finding');
-- A download host that is unreachable waits the same way; paid stages never do.
update app_private.pipeline_papers set stage='download',error_code='source_unavailable' where id=:'p';
select test.assert((select app_private.pipeline_estimate(pp)->>'step'='waiting' from app_private.pipeline_papers pp where id=:'p'),'an unreachable download host waits');
update app_private.pipeline_papers set stage='ocr_wait',error_code='rate_limited' where id=:'p';
select test.assert((select app_private.pipeline_estimate(pp)->>'step'='reading_equations' from app_private.pipeline_papers pp where id=:'p'),'provider stages keep their step');
rollback;
