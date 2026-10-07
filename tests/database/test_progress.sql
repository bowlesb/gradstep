-- Import progress (migration 029): an active import's entry carries the reader's step, percent and time left,
-- stamped with each new state_seq (so the JSON at a state_seq never changes); worker reports are projected at
-- most every 5 s, only with news, within the per-account progress rate; the percent never goes backwards in
-- an attempt; entries without a detail keep their exact JSON.
begin;
insert into auth.users values('30300000-0000-0000-0000-00000000000a'),('30300000-0000-0000-0000-00000000000b');
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits('30300000-0000-0000-0000-00000000000a','adjustment','progress-test-a',500,now()-interval '1 day',null,'Progress test grant');
select public.worker_set_pipeline_enabled(true);
reset role;

-- The entry a reader holds at its state_seq is the one in the journal at that seq.
create function pg_temp.journal_matches(a uuid,p_id uuid) returns boolean language sql as $$
 select exists(select 1 from app_private.library_changes c, jsonb_array_elements(c.entries) e
  where c.account_id=a and c.seq=(select state_seq from app_private.import_requests where account_id=a and id=p_id)
   and e->>'kind'='import' and e->>'id'=p_id::text and e=app_private.library_import_entry(a,p_id))
$$;
create function pg_temp.detail(p_id uuid) returns jsonb language sql as $$
 select app_private.library_import_entry(i.account_id,i.id)->'progress_detail' from app_private.import_requests i where i.id=p_id
$$;
create function pg_temp.seq(p_id uuid) returns bigint language sql as $$ select state_seq from app_private.import_requests where id=p_id $$;
-- Moves an import's last detail (and its paper's stage clock) back, as if time had passed.
create function pg_temp.later(p_seconds integer,p_paper uuid default null) returns void language sql as $$
 update app_private.import_requests set progress_at=progress_at-make_interval(secs=>p_seconds) where progress_at is not null;
 update app_private.pipeline_papers set stage_entered_at=stage_entered_at-make_interval(secs=>p_seconds) where id=p_paper;
$$;

-- Defaults until enough has been measured (fewer than 5 samples per stage).
delete from app_private.pipeline_events;
update app_private.pipeline_timing set computed_at='-infinity';
select test.assert(app_private.pipeline_timing_profile()=app_private.pipeline_timing_defaults(),'defaults until measured');

-- A new import: the first step, 0 %, an estimate for a typical paper (no pages yet).
set role authenticated;
select set_config('request.jwt.claim.sub','30300000-0000-0000-0000-00000000000a',false);
select public.v2_begin_import('30300000-0000-0000-0000-0000000000a1','2305.18290',0)->'entry' as e0 \gset
reset role;
select test.assert(:'e0'::jsonb->'progress_detail'->>'step'='finding' and (:'e0'::jsonb->'progress_detail'->>'percent')::int=0
 and (:'e0'::jsonb->'progress_detail'->>'eta_seconds')::int between 30 and 120 and not (:'e0'::jsonb->'progress_detail' ? 'pages')
 and not (:'e0'::jsonb->'progress_detail' ? 'delayed'),'new import: finding, 0 %, a typical estimate');
select test.assert(pg_temp.journal_matches('30300000-0000-0000-0000-00000000000a','30300000-0000-0000-0000-0000000000a1'),'journal holds the same entry');
select pg_temp.seq('30300000-0000-0000-0000-0000000000a1') as seq0 \gset

-- Customers cannot report progress.
set role authenticated;
select test.reject('select public.worker_pipeline_progress(gen_random_uuid(),gen_random_uuid(),1,1,2,null)','permission denied');
reset role;

-- Metadata: the stage change projects (library-write) with a recomputed detail.
set role service_role;
select gen_random_uuid() as claim \gset
select public.worker_pipeline_claim(:'claim') as entry \gset
select (:'entry'::jsonb->>'id') as paper,(:'entry'::jsonb->>'generation')::bigint as gen \gset
select public.worker_pipeline_metadata(:'paper',:'claim',:'gen',3,
 '{"title":"Direct Preference Optimization","authors":["Rafael Rafailov"],"abstract":"DPO","published_at":"2023-05-29","updated_at":"2024-07-29","categories":["cs.LG"],"venue":null}',
 true,'https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2305.18290','source_revision',3,'source_url','https://arxiv.org/abs/2305.18290v3','license_uri','https://creativecommons.org/licenses/by/4.0/',
  'evidence_sha256',repeat('e',64),'observed_at','2026-10-07T05:00:00Z'));
select public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen');
reset role;
select pg_temp.detail('30300000-0000-0000-0000-0000000000a1') as d1, pg_temp.seq('30300000-0000-0000-0000-0000000000a1') as seq1 \gset
select test.assert(:'d1'::jsonb->>'step'='downloading' and :seq1>:seq0 and (:'d1'::jsonb->>'percent')::int>0,'downloading, further along');
select test.assert(pg_temp.journal_matches('30300000-0000-0000-0000-00000000000a','30300000-0000-0000-0000-0000000000a1'),'journal: downloading');

-- Worker reports: fenced, validated, recorded; projected only 5 s after the last detail and only with news.
set role service_role;
select test.reject(format('select public.worker_pipeline_progress(%L,gen_random_uuid(),%s,null,27,null)',:'paper',:'gen'),'stale_pipeline_claim');
select test.reject(format('select public.worker_pipeline_progress(%L,%L,%s,30,27,null)',:'paper',:'claim',:'gen'),'invalid_progress');
select test.reject(format('select public.worker_pipeline_progress(%L,%L,%s,null,251,null)',:'paper',:'claim',:'gen'),'invalid_progress');
select test.reject(format('select public.worker_pipeline_progress(%L,%L,%s,null,null,0)',:'paper',:'claim',:'gen'),'invalid_progress');
select test.assert(public.worker_pipeline_progress(:'paper',:'claim',:'gen',null,27,3355443)=0,'within 5 s of the last detail: not projected');
reset role;
select test.assert((select stage='download' and pages=27 and bytes=3355443 from app_private.pipeline_observations where paper_id=:'paper'),'observation recorded');
select test.assert(pg_temp.seq('30300000-0000-0000-0000-0000000000a1')=:seq1,'no new state_seq while throttled');
select pg_temp.later(6);
set role service_role;
select test.assert(public.worker_pipeline_progress(:'paper',:'claim',:'gen',null,27,3355443)=1,'due, with news (size and pages): projected');
reset role;
select pg_temp.detail('30300000-0000-0000-0000-0000000000a1') as d2, pg_temp.seq('30300000-0000-0000-0000-0000000000a1') as seq2 \gset
select test.assert(:'d2'::jsonb->>'step'='downloading' and (:'d2'::jsonb->>'bytes')::bigint=3355443 and (:'d2'::jsonb->>'pages')::int=27
 and :seq2>:seq1 and (:'d2'::jsonb->>'percent')::int>=(:'d1'::jsonb->>'percent')::int,'the size and page count reach the reader');
select test.assert(pg_temp.journal_matches('30300000-0000-0000-0000-00000000000a','30300000-0000-0000-0000-0000000000a1'),'journal: size');
-- Time passes as estimated: the reader's own count-down is still right, so nothing is written.
select pg_temp.later(6,:'paper');
set role service_role;
select test.assert(public.worker_pipeline_progress(:'paper',:'claim',:'gen',null,27,3355443)=0,'no news: nothing written');
reset role;
select test.assert(pg_temp.seq('30300000-0000-0000-0000-0000000000a1')=:seq2,'state_seq unchanged without news');

-- Original, funding and submission: reading equations, with this paper's pages.
set role service_role;
select public.worker_pipeline_original(:'paper',:'claim',:'gen',('\x'||repeat('93',32))::bytea,3355443,27,'originals/'||repeat('93',32)||'.pdf');
select public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen');
select public.worker_pipeline_fund(:'paper',:'claim',:'gen',27,('\x'||repeat('1a',32))::bytea,('\x'||repeat('1b',32))::bytea);
select (public.worker_pipeline_begin_submit(:'paper',:'claim',:'gen')->>'attempt_id') as attempt \gset
select public.worker_pipeline_submitted(:'attempt','0e8c2a40-2d0c-4d0e-9a52-5d6f6f2b7c10');
select public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen');
reset role;
select pg_temp.detail('30300000-0000-0000-0000-0000000000a1') as d3 \gset
select test.assert(:'d3'::jsonb->>'step'='reading_equations' and (:'d3'::jsonb->>'pages')::int=27 and :'d3'::jsonb ? 'eta_seconds'
 and not (:'d3'::jsonb ? 'bytes') and (:'d3'::jsonb->>'percent')::int>=(:'d2'::jsonb->>'percent')::int,'reading equations: pages, an estimate, further along');
select test.assert(pg_temp.journal_matches('30300000-0000-0000-0000-00000000000a','30300000-0000-0000-0000-0000000000a1'),'journal: reading');

-- Another reader adds the same paper while it is being read: their first entry already shows that.
set role authenticated;
select set_config('request.jwt.claim.sub','30300000-0000-0000-0000-00000000000b',false);
select public.v2_begin_import('30300000-0000-0000-0000-0000000000b1','2305.18290',0)->'entry'->'progress_detail' as b0 \gset
reset role;
select test.assert(:'b0'::jsonb->>'step'='reading_equations' and (:'b0'::jsonb->>'pages')::int=27,'a paper already under way shows its step at once');

-- Provider page progress reaches both readers; the next report within 5 s does not.
select pg_temp.later(6,:'paper');
set role service_role;
select test.assert(public.worker_pipeline_progress(:'paper',:'claim',:'gen',10,27,null)=2,'page progress projected for both imports');
select test.assert(public.worker_pipeline_progress(:'paper',:'claim',:'gen',12,27,null)=0,'throttled within 5 s');
reset role;
select pg_temp.detail('30300000-0000-0000-0000-0000000000a1') as d4 \gset
select test.assert((:'d4'::jsonb->>'pages_done')::int=10 and (:'d4'::jsonb->>'percent')::int>=(:'d3'::jsonb->>'percent')::int,'page 10 of 27');
select test.assert(pg_temp.journal_matches('30300000-0000-0000-0000-00000000000a','30300000-0000-0000-0000-0000000000a1')
 and pg_temp.journal_matches('30300000-0000-0000-0000-00000000000b','30300000-0000-0000-0000-0000000000b1'),'journal: pages');

-- An account over its progress rate is skipped (never an error); others still get theirs.
insert into app_private.api_rate_windows values('library-progress','30300000-0000-0000-0000-00000000000a',
 to_timestamp(floor(extract(epoch from now())/3600)*3600),720) on conflict(route,scope_id,window_start) do update set used=720;
select pg_temp.later(6,:'paper');
set role service_role;
select test.assert(public.worker_pipeline_progress(:'paper',:'claim',:'gen',14,27,null)=1,'only the account within its rate is projected');
reset role;
select test.assert((pg_temp.detail('30300000-0000-0000-0000-0000000000a1')->>'pages_done')::int=10
 and (pg_temp.detail('30300000-0000-0000-0000-0000000000b1')->>'pages_done')::int=14,'rate-limited reader keeps the last detail');
select test.assert((select pages_done=14 from app_private.pipeline_observations where paper_id=:'paper'),'the observation is kept regardless');

-- Stage changes are not progress: they project through library writes even over the progress rate.
set role service_role;
select public.worker_pipeline_collected(:'paper',:'claim',:'gen',27,('\x'||repeat('6c',32))::bytea,4096);
select public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen');
reset role;
select pg_temp.detail('30300000-0000-0000-0000-0000000000a1') as d5 \gset
select test.assert(:'d5'::jsonb->>'step'='preparing' and (:'d5'::jsonb->>'percent')::int>=(:'d4'::jsonb->>'percent')::int
 and not (:'d5'::jsonb ? 'pages_done'),'preparing, over the progress rate');
delete from app_private.api_rate_windows where route='library-progress';

-- The percent never goes backwards in an attempt, even when the estimate grows (more pages than thought).
update app_private.pipeline_papers set page_count=200 where id=:'paper';
select pg_temp.later(6);
set role service_role;
select test.assert(public.worker_pipeline_progress(:'paper',:'claim',:'gen')>=1,'new page count is news');
reset role;
select pg_temp.detail('30300000-0000-0000-0000-0000000000a1') as d6 \gset
select test.assert((:'d6'::jsonb->>'pages')::int=80 and (:'d6'::jsonb->>'percent')::int=(:'d5'::jsonb->>'percent')::int
 and (select (app_private.import_progress_detail(i,null)->>'percent')::int<(:'d5'::jsonb->>'percent')::int from app_private.import_requests i
  where id='30300000-0000-0000-0000-0000000000a1'),'held at the previous percent (OCR cap: 80 pages)');
select test.assert(pg_temp.journal_matches('30300000-0000-0000-0000-00000000000a','30300000-0000-0000-0000-0000000000a1'),'journal: held');

-- Backing off after an error: no time estimate, `delayed` instead; a budget pause says it is waiting.
update app_private.pipeline_papers set failures=1 where id=:'paper';
select pg_temp.later(6);
set role service_role;
select test.assert(public.worker_pipeline_progress(:'paper',:'claim',:'gen')>=1,'delay is news');
reset role;
select test.assert(pg_temp.detail('30300000-0000-0000-0000-0000000000a1')->'delayed'='true'::jsonb
 and not (pg_temp.detail('30300000-0000-0000-0000-0000000000a1') ? 'eta_seconds'),'delayed: no estimate');
-- The same paper paused for the platform budget (row overridden in place): it says it is waiting.
select test.assert((select app_private.pipeline_estimate(jsonb_populate_record(p,'{"stage":"ocr_fund","error_code":"service_paused","failures":0}'))
 from app_private.pipeline_papers p where p.id=:'paper') @> '{"step":"waiting","delayed":true}','a budget pause is "waiting"');
select test.assert((select app_private.pipeline_estimate(jsonb_populate_record(p,'{"stage":"source_only"}')) from app_private.pipeline_papers p
 where p.id=:'paper') is null,'no estimate for a paper going nowhere');
update app_private.pipeline_papers set failures=0 where id=:'paper';

-- A retry is a new attempt: the floor starts again. Leaving the active phases clears the detail.
select app_private.library_next_seq('30300000-0000-0000-0000-00000000000a') as s \gset
update app_private.import_requests set phase='failed',error_code='conversion_failed',retryable=true,state_seq=:s where id='30300000-0000-0000-0000-0000000000a1';
select test.assert((select progress_detail is null and progress_at is null from app_private.import_requests where id='30300000-0000-0000-0000-0000000000a1')
 and app_private.library_import_entry('30300000-0000-0000-0000-00000000000a','30300000-0000-0000-0000-0000000000a1')
  =app_private.library_import_entry_base('30300000-0000-0000-0000-00000000000a','30300000-0000-0000-0000-0000000000a1'),'failed: no detail, the entry as before 031');
select (intent_revision) as rev from app_private.import_requests where id='30300000-0000-0000-0000-0000000000a1' \gset
set role authenticated;
select set_config('request.jwt.claim.sub','30300000-0000-0000-0000-00000000000a',false);
select public.v2_retry_import('30300000-0000-0000-0000-0000000000a2','30300000-0000-0000-0000-0000000000a1',:rev);
reset role;
select test.assert((pg_temp.detail('30300000-0000-0000-0000-0000000000a1')->>'percent')::int<(:'d6'::jsonb->>'percent')::int,'a retry starts its own percent');
select test.assert(pg_temp.journal_matches('30300000-0000-0000-0000-00000000000a','30300000-0000-0000-0000-0000000000a1'),'journal: retry');

-- Ready: the import leaves the library list with no detail; its entry is exactly what it was before 031.
update app_private.pipeline_papers set page_count=27 where id=:'paper';
set role service_role;
select public.worker_pipeline_published(:'paper',:'claim',:'gen',('\x'||repeat('7c',32))::bytea,2048,'timestep-mathpix-mathml-v1');
select test.assert(public.worker_pipeline_sync_imports(:'paper',:'claim',:'gen')=2,'both imports resolve');
select public.worker_pipeline_release(:'paper',:'claim',:'gen');
reset role;
select test.assert((select bool_and(phase='ready' and progress_detail is null) from app_private.import_requests
 where id in ('30300000-0000-0000-0000-0000000000a1','30300000-0000-0000-0000-0000000000b1')),'ready imports carry no detail');
select test.assert(app_private.library_import_entry(account_id,id)=app_private.library_import_entry_base(account_id,id)
 and not (app_private.library_import_entry(account_id,id) ? 'progress_detail'),'ready entry unchanged by 031')
 from app_private.import_requests where id in ('30300000-0000-0000-0000-0000000000a1','30300000-0000-0000-0000-0000000000b1');
select test.assert(app_private.library_import_entry('30300000-0000-0000-0000-00000000000a',gen_random_uuid()) is null,'no entry for an unknown import');

-- An active import with no stored detail (created before 031) keeps byte-identical JSON.
set role authenticated;
select public.v2_begin_import('30300000-0000-0000-0000-0000000000a3','1706.03762',0);
reset role;
update app_private.import_requests set progress_detail=null,progress_at=null where id='30300000-0000-0000-0000-0000000000a3';
select test.assert(app_private.library_import_entry('30300000-0000-0000-0000-00000000000a','30300000-0000-0000-0000-0000000000a3')::text
 =app_private.library_import_entry_base('30300000-0000-0000-0000-00000000000a','30300000-0000-0000-0000-0000000000a3')::text,'no detail: identical JSON');

-- News: what the reader would see change, against the reader's own count-down.
select test.assert(not app_private.import_progress_news('{"step":"finding","percent":10,"eta_seconds":40}',clock_timestamp(),'{"step":"finding","percent":10,"eta_seconds":40}'),'same: no news');
select test.assert(app_private.import_progress_news(null,null,'{"step":"finding","percent":0}'),'first detail is news');
select test.assert(not app_private.import_progress_news('{"step":"finding","percent":10}',clock_timestamp(),null),'no new detail: no news');
select test.assert(app_private.import_progress_news('{"step":"finding","percent":10,"eta_seconds":40}',clock_timestamp(),'{"step":"downloading","percent":10,"eta_seconds":40}'),'step');
select test.assert(app_private.import_progress_news('{"step":"reading_equations","percent":40,"pages":27,"pages_done":3,"eta_seconds":30}',clock_timestamp(),
 '{"step":"reading_equations","percent":40,"pages":27,"pages_done":4,"eta_seconds":30}'),'page');
select test.assert(app_private.import_progress_news('{"step":"downloading","percent":10,"eta_seconds":40}',clock_timestamp(),'{"step":"downloading","percent":10,"delayed":true}'),'delay');
select test.assert(not app_private.import_progress_news('{"step":"downloading","percent":40,"eta_seconds":60}',clock_timestamp()-interval '10 seconds',
 '{"step":"downloading","percent":50,"eta_seconds":50}'),'count-down on track (40 + 59 × 10/60 ≈ 50 %, 50 s): no news');
select test.assert(app_private.import_progress_news('{"step":"downloading","percent":40,"eta_seconds":60}',clock_timestamp()-interval '10 seconds',
 '{"step":"downloading","percent":50,"eta_seconds":75}'),'estimate drifted by 25 s: news');
select test.assert(app_private.import_progress_news('{"step":"downloading","percent":40,"eta_seconds":60}',clock_timestamp()-interval '10 seconds',
 '{"step":"downloading","percent":60,"eta_seconds":50}'),'percent ahead of the count-down by 10: news');

-- Measured stage times replace the defaults once there are 5 samples (this test's own paper adds one per
-- stage it went through); OCR and render scale per page.
insert into app_private.pipeline_events(kind,paper_id,stage,next_stage,duration_ms)
 select 'stage',:'paper'::uuid,'download','ocr_fund',20000 from generate_series(1,5)
 union all select 'stage',:'paper'::uuid,'ocr_wait','render',5000+27*1500 from generate_series(1,5)
 union all select 'stage',:'paper'::uuid,'render','done',999999 from generate_series(1,3)
 union all select 'stage',:'paper'::uuid,'metadata','failed',999999 from generate_series(1,9);
update app_private.pipeline_timing set computed_at='-infinity';
select app_private.pipeline_timing_profile() as prof \gset
select test.assert((:'prof'::jsonb->'download'->>'ms')::int=20000 and (:'prof'::jsonb->'ocr_wait'->>'per_page_ms')::int=1500
 and (:'prof'::jsonb->'render'->>'per_page_ms')::int=300 and (:'prof'::jsonb->'metadata'->>'ms')::int=5000,
 'measured medians (failures and stages under 5 samples keep defaults)');
select test.assert((select computed_at>now()-interval '1 minute' from app_private.pipeline_timing),'profile cached');
select test.assert(app_private.pipeline_timing_profile()=:'prof'::jsonb,'cached profile reused');
rollback;
