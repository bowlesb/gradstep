-- Interest index rebuild schedule (migration 0153; docs/architecture/INTEREST_INDEX.md "Rebuild cadence"): due-based,
-- never a single missable slot. Due once the map is rebuild_days old; started in the weekend 06:00-10:00 UTC window, or
-- at any tick once due for 24 hours; failed or blocked builds back off 10 minutes, 1 hour, 6 hours; the kick's
-- heartbeat and an unanswered post reach Health. Synthetic local SQL.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.unit(i integer) returns text language sql as $$
 select '['||string_agg(case when g=i then '1' else '0' end,',' order by g)||']' from generate_series(1,384) g
$$;
create or replace function test.due(t text) returns boolean language sql as $$ select app_private.interest_rebuild_due_at(t::timestamptz) $$;

\set C1 '15300000-0000-4000-8001-000000000001'
\set C2 '15300000-0000-4000-8001-000000000002'
\set C3 '15300000-0000-4000-8001-000000000003'
\set C4 '15300000-0000-4000-8001-000000000004'
\set C5 '15300000-0000-4000-8001-000000000005'

select test.assert((select window_dows='{0,6}' and window_start_hour=6 and window_end_hour=10 and overdue_hours=24
 from app_private.interest_policy),'defaults: weekend 06:00-10:00 UTC, 24 hours');
select test.assert(not has_function_privilege('authenticated','public.worker_interest_rebuild_mark(uuid)','execute'),'readers cannot mark builds');
update app_private.interest_policy set enabled=true,min_corpus=100;

-- A corpus of 1,000 embedded pool papers and nothing pending.
insert into app_private.interest_papers(source_id,title,abstract,pool_announced_on,title_only,text_sha256,state,model_version,fingerprint,fp_q8,fp_seq,embedded_at)
select '2610.'||lpad(i::text,5,'0'),'Paper '||i,repeat('An abstract long enough. ',3),current_date-1,false,sha256(convert_to(i::text,'UTF8')),'embedded',
 'gte-small@17e1f34/onnx-fp32@5927d17/mean-l2/v1',test.unit(1+i%384)::extensions.halfvec(384),decode(repeat('00',388),'hex'),
 nextval('app_private.interest_fp_seq'),now()
from generate_series(1,1000) i;
select test.assert(test.due('2026-10-21 12:00+00'),'no map yet and nothing pending: due at once, any day');

-- Map v1 published Saturday 2026-10-03 07:30 UTC; growing corpus, so due 14 days later (Saturday 2026-10-17 07:30).
insert into app_private.interest_map_versions(kind,state,model_version,corpus_papers,published_at)
 values('cold','published','gte-small@17e1f34/onnx-fp32@5927d17/mean-l2/v1',3,'2026-10-03 07:30+00');
select test.assert(not test.due('2026-10-17 07:00+00'),'not yet 14 days old');
select test.assert(test.due('2026-10-17 07:40+00'),'due, inside the Saturday window');

-- A window missed because the worker was down: Saturday's window passes; Sunday's window or the 24-hour rule catch it.
select test.assert(not test.due('2026-10-17 11:00+00'),'after the window, under 24 hours: waits');
select test.assert(test.due('2026-10-18 06:05+00'),'Sunday''s window starts it (worker back)');
select test.assert(test.due('2026-10-18 07:31+00'),'24 hours overdue: due at any hour');
select test.assert(test.due('2026-10-19 15:00+00'),'still due on Monday afternoon: never skipped to the next cycle');

-- Due during a weekday: map published Wednesday 2026-10-07 12:00, due Wednesday 2026-10-21 12:00.
update app_private.interest_map_versions set published_at='2026-10-07 12:00+00';
select test.assert(not test.due('2026-10-21 13:00+00'),'weekday, under 24 hours overdue: waits for a window');
select test.assert(not test.due('2026-10-22 11:59+00'),'just under 24 hours: waits');
select test.assert(test.due('2026-10-22 12:00+00'),'24 hours overdue on a weekday: due at the next tick');

-- Weekly once the corpus reaches weekly_after_papers.
update app_private.interest_policy set weekly_after_papers=1000;
select test.assert(test.due('2026-10-14 12:00+00') is false and test.due('2026-10-15 12:00+00'),'weekly: due 7 days on, overdue a day later');
update app_private.interest_policy set weekly_after_papers=50000;

-- A build failing twice, then succeeding: back-off 10 minutes, then 1 hour; a published build resets it.
select public.worker_interest_claim(:'C1');
select public.worker_interest_rebuild_mark(:'C1');
select public.worker_interest_release(:'C1','failed','{"rebuild_failed":"database_error"}','database_error');
select test.assert((select rebuild_failures=1 and rebuild_retry_at between now()+interval '9 minutes' and now()+interval '11 minutes'
 and rebuild_last_error='database_error' and rebuild_running_since is null from app_private.interest_state),'first failure: 10 minutes');
select test.assert(not app_private.interest_rebuild_due_at(now()+interval '5 minutes'),'not due during the back-off');
select test.assert(app_private.interest_rebuild_due_at(now()+interval '11 minutes'),'due again after 10 minutes');
select public.worker_interest_claim(:'C2');
select public.worker_interest_rebuild_mark(:'C2');
select public.worker_interest_release(:'C2','finished','{"rebuild":{"published":false,"reason":"stability_gate"}}',null);
select test.assert((select rebuild_failures=2 and rebuild_retry_at between now()+interval '59 minutes' and now()+interval '61 minutes'
 and rebuild_last_error='stability_gate' from app_private.interest_state),'second failure (a blocked build counts): 1 hour');
select test.assert(app_private.interest_health()->'attention' @> '[{"kind":"interest_rebuild_retrying"}]','Health names the retries');
-- A run killed mid-build (its lease expires) counts too: 6 hours from the third failure on.
select public.worker_interest_claim(:'C3');
select public.worker_interest_rebuild_mark(:'C3');
update app_private.interest_state set lease_until=now()-interval '1 second';
select public.worker_interest_claim(:'C4');
select test.assert((select rebuild_failures=3 and rebuild_retry_at>now()+interval '5 hours' and rebuild_last_error='lease_expired'
 from app_private.interest_state),'expired lease mid-build: third failure, 6 hours');
select test.assert((select state='failed' and error_code='lease_expired' from app_private.interest_runs where id=:'C3'),'the killed run is failed');
-- A build that only embedded phrases (resumes next run) is neither a failure nor a success.
select public.worker_interest_release(:'C4','finished','{"rebuild":{"phase":"phrases","remaining":10}}',null);
select test.assert((select rebuild_failures=3 and rebuild_running_since is null from app_private.interest_state),'partial build: unchanged');
update app_private.interest_state set rebuild_retry_at=null;
select public.worker_interest_claim(:'C5');
select public.worker_interest_rebuild_mark(:'C5');
select public.worker_interest_release(:'C5','finished','{"rebuild":{"published":true,"version":2}}',null);
select test.assert((select rebuild_failures=0 and rebuild_retry_at is null and rebuild_last_error is null from app_private.interest_state),'success resets');

-- Heartbeat and an unanswered post.
update app_private.interest_state set last_tick_at=null,last_kick_at=null,last_run_at=now();
update app_private.interest_policy set updated_at=now()-interval '2 hours';
select test.assert(app_private.interest_health()->'attention' @> '[{"kind":"interest_kick_stalled"}]','no kick for an hour: stalled');
select app_private.interest_kick();
select test.assert((select last_tick_at>now()-interval '1 minute' from app_private.interest_state),'the kick writes its heartbeat');
select test.assert(not app_private.interest_health()->'attention' @> '[{"kind":"interest_kick_stalled"}]','heartbeat clears it');
update app_private.interest_state set last_kick_at=now()-interval '40 minutes',last_run_at=now()-interval '2 hours';
select test.assert(app_private.interest_health()->'attention' @> '[{"kind":"interest_worker_unreachable"}]','posted 40 minutes ago, no run: unreachable');
update app_private.interest_state set last_run_at=now()-interval '35 minutes';
select test.assert(not app_private.interest_health()->'attention' @> '[{"kind":"interest_worker_unreachable"}]','a run after the post clears it');
-- Map staleness uses rebuild_days + 2.
update app_private.interest_map_versions set published_at=now()-interval '15 days';
select test.assert(not app_private.interest_health()->'attention' @> '[{"kind":"interest_map_stale"}]','15 days: due, not yet stale');
update app_private.interest_map_versions set published_at=now()-interval '17 days';
select test.assert(app_private.interest_health()->'attention' @> '[{"kind":"interest_map_stale"}]','over 16 days: stale');
select test.assert((app_private.interest_health()#>>'{schedule,rebuild_days}')::int=14,'schedule reported');
rollback;
