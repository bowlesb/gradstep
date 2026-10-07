-- Self-healing downloads (migration 027): automatic retries 15 min / 2 h / 12 h for causes that can
-- change, none for refusals that cannot, the reader's Retry kept; healing imports whose paper moved
-- on; one retry per deploy; honest import entries (019's JSON unchanged unless a retry is scheduled).
begin;
-- This file sorts before test_invariants.sql, which defines the shared helpers: define them here,
-- inside this transaction (rolled back at the end).
create schema test;
create function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create function test.reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin
 begin execute statement;
 exception when others then
   if position(expected in sqlerrm)=0 then raise exception 'Unexpected rejection: % (wanted %)',sqlerrm,expected; end if;
   rejected:=true;
 end;
 if not rejected then raise exception 'Expected rejection: %',expected; end if;
end $$;
grant usage on schema test to anon,authenticated,service_role;
grant execute on all functions in schema test to anon,authenticated,service_role;

-- Worker steps used below. Each claim must pick the expected paper.
create function test.claim(p uuid) returns jsonb language plpgsql as $$
declare e jsonb;
begin
 e:=public.worker_pipeline_claim(gen_random_uuid());
 if e is null or (e->>'id')::uuid is distinct from p then raise exception 'expected to claim %, got %',p,coalesce(e->>'id','nothing'); end if;
 return e;
end $$;
create function test.sync(p uuid) returns void language plpgsql as $$
declare e jsonb:=test.claim(p);
begin
 perform public.worker_pipeline_sync_imports(p,(e->>'claim_id')::uuid,(e->>'generation')::bigint);
 perform public.worker_pipeline_release(p,(e->>'claim_id')::uuid,(e->>'generation')::bigint);
end $$;
-- An eligible (CC BY) arXiv paper through metadata to download.
create function test.to_download(src text) returns uuid language plpgsql as $$
declare p uuid; e jsonb;
begin
 select id into strict p from app_private.pipeline_papers where owner_id is null and source_id=src and requested_revision=0;
 e:=test.claim(p);
 perform public.worker_pipeline_metadata(p,(e->>'claim_id')::uuid,(e->>'generation')::bigint,1,
  jsonb_build_object('title','Paper '||src,'authors',jsonb_build_array('A. Author'),'categories',jsonb_build_array('cs.LG')),
  true,'https://creativecommons.org/licenses/by/4.0/',
  jsonb_build_object('source_id',src,'source_revision',1,'source_url','https://arxiv.org/abs/'||src||'v1',
   'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('e',64),'observed_at','2026-10-05T05:00:00Z'));
 perform public.worker_pipeline_sync_imports(p,(e->>'claim_id')::uuid,(e->>'generation')::bigint);
 perform public.worker_pipeline_release(p,(e->>'claim_id')::uuid,(e->>'generation')::bigint);
 return p;
end $$;
-- The download stage fails as processPaper fails it; the next claim tells the readers.
create function test.fail(p uuid,code text) returns void language plpgsql as $$
declare e jsonb:=test.claim(p);
begin
 if e->>'stage'<>'download' then raise exception 'expected the download stage, got %',e->>'stage'; end if;
 perform public.worker_pipeline_sync_imports(p,(e->>'claim_id')::uuid,(e->>'generation')::bigint);
 perform public.worker_pipeline_defer(p,(e->>'claim_id')::uuid,(e->>'generation')::bigint,0,code,true,'download');
 perform test.sync(p);
end $$;
create function test.entry(a uuid,i uuid) returns jsonb language sql as $$ select app_private.library_import_entry(a,i) $$;
create function test.due(p uuid) returns void language sql as $$
 update app_private.pipeline_papers set auto_retry_at=clock_timestamp()-interval '1 second' where id=p
$$;
-- 019's import entry, verbatim: every entry without a scheduled retry must equal it.
create function pg_temp.entry_019(a uuid,p_id uuid) returns jsonb language sql stable as $$
 select jsonb_build_object('kind','import','id',i.id,'created_seq',i.created_seq,'state_seq',i.state_seq,'intent_revision',i.intent_revision,
  'visible',i.desired_present and i.phase<>'ready','phase',i.phase,'source',case when i.source_id like 'openalex:%' then 'web' else 'arxiv' end,'source_id',i.source_id,
  'requested_revision',i.requested_revision,'source_revision',cm.source_revision,'metadata_id',cm.id,'version_id',cm.version_id,
  'metadata',cm.metadata,'metadata_recorded_at',cm.recorded_at,
  'source_url',case when i.source_id like 'openalex:%' then 'https://openalex.org/works/'||substr(i.source_id,10)
   else 'https://arxiv.org/abs/'||i.source_id||coalesce('v'||coalesce(cm.source_revision,i.requested_revision),'') end,
  'document_id',i.document_id,'library_item_id',i.library_item_id,
  'error_code',i.error_code,'retryable',i.retryable,
  'progress',case when i.phase in ('accepted','resolving','acquiring') then i.progress end)
 from app_private.import_requests i left join app_private.catalog_metadata cm on cm.id=i.metadata_id
 where i.account_id=a and i.id=p_id
$$;

insert into auth.users values('27000000-0000-0000-0000-00000000000a'),('27000000-0000-0000-0000-00000000000b'),('27000000-0000-0000-0000-00000000000c'),
 ('27000000-0000-0000-0000-00000000000d'),('27000000-0000-0000-0000-00000000000e'),('27000000-0000-0000-0000-00000000000f');
\set A '27000000-0000-0000-0000-00000000000a'
\set B '27000000-0000-0000-0000-00000000000b'
\set C '27000000-0000-0000-0000-00000000000c'
\set D '27000000-0000-0000-0000-00000000000d'
\set E '27000000-0000-0000-0000-00000000000e'
\set F '27000000-0000-0000-0000-00000000000f'
\set IA '27000000-0000-0000-0000-0000000000a1'
\set IB '27000000-0000-0000-0000-0000000000b1'
\set IC '27000000-0000-0000-0000-0000000000c1'
\set ID '27000000-0000-0000-0000-0000000000d1'
\set IE '27000000-0000-0000-0000-0000000000e1'

-- Workers only; nothing happens while the pipeline is off.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject('select public.worker_pipeline_auto_retry()','permission denied');
select test.reject($q$select public.worker_pipeline_retry_failed('deploy-x')$q$,'permission denied');
reset role;
set role anon;
select test.reject('select public.worker_pipeline_auto_retry()','permission denied');
reset role;
set role service_role;
select test.assert(not (public.worker_pipeline_auto_retry()->>'swept')::boolean,'a disabled pipeline sweeps nothing');
select test.assert(not (public.worker_pipeline_retry_failed('deploy-x')->>'enabled')::boolean,'a disabled pipeline retries nothing after a deploy');
select test.reject('select public.worker_pipeline_auto_retry(-1)','invalid_auto_retry_request');
select test.reject($q$select public.worker_pipeline_retry_failed('bad label!')$q$,'invalid_retry_request');
select public.worker_set_pipeline_enabled(true);
reset role;

-- 1. The automatic retry ladder: 15 min, 2 h, 12 h for causes that can change; then the cause.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_begin_import(:'IA','2305.18290',0);
reset role;
select test.to_download('2305.18290') as p \gset
select test.fail(:'p','source_unavailable');
select test.assert((select stage='failed' and auto_retries=0 and auto_retry_at between now()+interval '14 minutes' and now()+interval '16 minutes'
 from app_private.pipeline_papers where id=:'p'),'a host that was unreachable is retried in 15 minutes');
select test.entry(:'A',:'IA') as e1 \gset
select test.assert(:'e1'::jsonb->>'phase'='failed' and :'e1'::jsonb->>'error_code'='download_retrying' and (:'e1'::jsonb->>'retryable')::boolean
 and (:'e1'::jsonb->>'auto_retry_at')::timestamptz=(select auto_retry_at from app_private.pipeline_papers where id=:'p'),
 'the reader sees "retrying", when, and keeps Retry');
select test.assert((:'e1'::jsonb-'auto_retry_at')=pg_temp.entry_019(:'A',:'IA'),'otherwise the entry is 019''s');
select test.assert((public.worker_pipeline_auto_retry()->>'retried')::int=0,'nothing is due yet');
select test.due(:'p');
select test.assert(not (public.worker_pipeline_auto_retry(20)->>'swept')::boolean,'workers sweep at most every 20 s');
select (test.entry(:'A',:'IA')->>'state_seq')::bigint as seq_before \gset
select public.worker_pipeline_auto_retry() as swept \gset
select test.assert((:'swept'::jsonb->>'retried')::int=1 and (:'swept'::jsonb->>'healed')::int=0,'the due retry ran');
select test.entry(:'A',:'IA') as e2 \gset
select test.assert(:'e2'::jsonb->>'phase'='acquiring' and :'e2'::jsonb->'error_code'='null'::jsonb and not (:'e2'::jsonb->>'retryable')::boolean
 and :'e2'::jsonb->>'progress'='downloading' and not (:'e2'::jsonb ? 'auto_retry_at') and :'e2'::jsonb=pg_temp.entry_019(:'A',:'IA'),
 'the import is downloading again');
select test.assert((:'e2'::jsonb->>'intent_revision')::int=1 and (:'e2'::jsonb->>'state_seq')::bigint>:'seq_before'::bigint,
 'a worker checkpoint: new state_seq, intent revision unchanged (the reader''s Cancel still applies)');
select test.assert(exists(select 1 from app_private.library_changes where account_id=:'A' and seq=(:'e2'::jsonb->>'state_seq')::bigint),'the change syncs');
select test.assert((select auto_retries=1 and auto_retry_at is null from app_private.pipeline_papers where id=:'p'),'counted once');
select test.assert((select retry_requested from app_private.pipeline_imports where import_id=:'IA'),'the next claim resumes the paper');
select test.fail(:'p','source_blocked');
select test.assert((select auto_retry_at between now()+interval '119 minutes' and now()+interval '121 minutes' from app_private.pipeline_papers where id=:'p'),
 'second retry after 2 hours');
select test.due(:'p');
select public.worker_pipeline_auto_retry();
select test.fail(:'p','not_pdf');
select test.assert((select auto_retries=2 and auto_retry_at between now()+interval '719 minutes' and now()+interval '721 minutes' from app_private.pipeline_papers where id=:'p'),
 'third retry after 12 hours');
select test.due(:'p');
select public.worker_pipeline_auto_retry();
select test.fail(:'p','download_failed');
select test.assert((select auto_retries=3 and auto_retry_at is null from app_private.pipeline_papers where id=:'p'),'at most three automatic retries');
select test.entry(:'A',:'IA') as e3 \gset
select test.assert(:'e3'::jsonb->>'error_code'='download_failed' and (:'e3'::jsonb->>'retryable')::boolean and not (:'e3'::jsonb ? 'auto_retry_at')
 and :'e3'::jsonb=pg_temp.entry_019(:'A',:'IA'),'then the cause, with Retry');
select test.assert((public.worker_pipeline_auto_retry()->>'retried')::int=0,'an exhausted paper is left alone');

-- 2. Healing: another reader's import resumes the paper; the failed import follows it, and a
-- successful download resets the ladder.
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select public.v2_begin_import(:'IB','2305.18290',0);
reset role;
select test.claim(:'p') as e \gset
select test.assert(:'e'::jsonb->>'stage'='download','a new reader resumes the failed paper');
select public.worker_pipeline_release(:'p',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select public.worker_pipeline_auto_retry() as healed \gset
select test.assert((:'healed'::jsonb->>'healed')::int=1 and test.entry(:'A',:'IA')->>'phase'='acquiring','the failed import follows its paper');
select test.claim(:'p') as e \gset
select test.assert(public.worker_pipeline_original(:'p',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint,('\x'||repeat('27',32))::bytea,500000,9,
 'originals/'||repeat('27',32)||'.pdf')->>'stage'='ocr_fund','downloaded');
select test.assert(public.worker_pipeline_sync_imports(:'p',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint)=2,'both readers see it');
select public.worker_pipeline_release(:'p',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select test.assert((select auto_retries=0 and auto_retry_at is null from app_private.pipeline_papers where id=:'p'),'a successful download resets the ladder');
select test.assert(test.entry(:'A',:'IA')->>'progress'='converting' and test.entry(:'B',:'IB')->>'progress'='converting','both converting');
update app_private.pipeline_papers set next_attempt_at=now()+interval '1 day' where id=:'p';

-- 3. Refusals that cannot change: no automatic retry, Retry kept; a deploy retries once per label.
set role authenticated;
select set_config('request.jwt.claim.sub',:'C',false);
select public.v2_begin_import(:'IC','2006.11239',0);
reset role;
select test.to_download('2006.11239') as p2 \gset
select test.fail(:'p2','pdf_restricted');
select test.assert((select auto_retry_at is null from app_private.pipeline_papers where id=:'p2'),'a paywall is not retried automatically');
select test.assert(test.entry(:'C',:'IC')->>'error_code'='pdf_restricted' and (test.entry(:'C',:'IC')->>'retryable')::boolean
 and test.entry(:'C',:'IC')=pg_temp.entry_019(:'C',:'IC'),'the reader is told it needs a sign-in, and keeps Retry');
set role authenticated;
select set_config('request.jwt.claim.sub',:'C',false);
select public.v2_retry_import('27000000-0000-0000-0000-0000000000c2',:'IC',1);
reset role;
select test.fail(:'p2','too_large');
select test.assert((select auto_retry_at is null from app_private.pipeline_papers where id=:'p2') and test.entry(:'C',:'IC')->>'error_code'='too_large',
 'too large: no automatic retry');
select public.worker_pipeline_retry_failed('deploy-a') as d1 \gset
select test.assert(test.entry(:'C',:'IC')->>'phase'='failed' and (select deploy_retry is null from app_private.pipeline_papers where id=:'p2'),
 'a deploy does not retry a size limit');
set role authenticated;
select set_config('request.jwt.claim.sub',:'C',false);
select public.v2_retry_import('27000000-0000-0000-0000-0000000000c3',:'IC',2);
reset role;
select test.fail(:'p2','pdf_restricted');
set role service_role;
select public.worker_pipeline_retry_failed('deploy-a') as d2 \gset
reset role;
select test.assert((:'d2'::jsonb->>'retried')::int>=1 and test.entry(:'C',:'IC')->>'phase'='acquiring'
 and (test.entry(:'C',:'IC')->>'intent_revision')::int=3,'after a deploy, even a paywall is tried once more (it may have been our bug)');
select test.assert((select deploy_retry='deploy-a' and auto_retries=0 from app_private.pipeline_papers where id=:'p2'),'not counted as an automatic retry');
select test.fail(:'p2','pdf_restricted');
select public.worker_pipeline_retry_failed('deploy-a');
select test.assert(test.entry(:'C',:'IC')->>'phase'='failed','once per deploy');
select public.worker_pipeline_retry_failed('deploy-b');
select test.assert(test.entry(:'C',:'IC')->>'phase'='acquiring','and once more after the next deploy');
select test.fail(:'p2','pdf_restricted');

-- 4. Cancelled while waiting: the retry is dropped, nobody's import moves.
set role authenticated;
select set_config('request.jwt.claim.sub',:'D',false);
select public.v2_begin_import(:'ID','1706.03762',0);
reset role;
select test.to_download('1706.03762') as p3 \gset
select test.fail(:'p3','rate_limited');
select test.assert(test.entry(:'D',:'ID')->>'error_code'='download_retrying','retrying');
-- The reader need not wait: Retry now resumes the paper and the schedule goes with it.
set role authenticated;
select set_config('request.jwt.claim.sub',:'D',false);
select public.v2_retry_import('27000000-0000-0000-0000-0000000000d3',:'ID',1);
reset role;
select test.claim(:'p3') as e \gset
select test.assert(:'e'::jsonb->>'stage'='download' and (select auto_retry_at is null and auto_retries=0 from app_private.pipeline_papers where id=:'p3'),
 'a reader''s Retry runs at once');
select public.worker_pipeline_release(:'p3',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select test.fail(:'p3','rate_limited');
select test.assert((select auto_retries=0 and auto_retry_at between now()+interval '14 minutes' and now()+interval '16 minutes' from app_private.pipeline_papers where id=:'p3'),
 'and does not use up an automatic retry');
set role authenticated;
select set_config('request.jwt.claim.sub',:'D',false);
select public.v2_cancel_import('27000000-0000-0000-0000-0000000000d2',:'ID',2);
reset role;
select test.due(:'p3');
select public.worker_pipeline_auto_retry();
select test.assert((select auto_retry_at is null and auto_retries=0 and stage='failed' from app_private.pipeline_papers where id=:'p3')
 and test.entry(:'D',:'ID')->>'phase'='cancelled' and not (test.entry(:'D',:'ID') ? 'auto_retry_at'),'nobody waits: the schedule is dropped');

-- 5. A reader at the active-import limit waits 15 minutes more.
set role authenticated;
select set_config('request.jwt.claim.sub',:'E',false);
select public.v2_begin_import(:'IE','2106.09685',0);
reset role;
select test.to_download('2106.09685') as p4 \gset
select test.fail(:'p4','source_unavailable');
set role authenticated;
select set_config('request.jwt.claim.sub',:'E',false);
select public.v2_begin_import('27000000-0000-0000-0000-0000000000e2','2203.02155',0);
reset role;
update app_private.pipeline_imports set next_sync_at=now()+interval '1 day' where import_id='27000000-0000-0000-0000-0000000000e2';
update app_private.pipeline_papers set next_attempt_at=now()+interval '1 day' where source_id='2203.02155';
update app_private.library_policy set account_active_imports=1;
select test.due(:'p4');
select public.worker_pipeline_auto_retry() as limited \gset
select test.assert((:'limited'::jsonb->>'postponed')::int=1 and (select auto_retries=0 and auto_retry_at between now()+interval '14 minutes' and now()+interval '16 minutes'
 from app_private.pipeline_papers where id=:'p4') and test.entry(:'E',:'IE')->>'error_code'='download_retrying','postponed, not counted');
update app_private.library_policy set account_active_imports=10;
select test.due(:'p4');
select public.worker_pipeline_auto_retry() as roomy \gset
select test.assert((:'roomy'::jsonb->>'retried')::int=1 and test.entry(:'E',:'IE')->>'phase'='acquiring','retried once there is room');

-- 6. A worker that keeps dying in the download stage (022's loop breaker) is retried too.
set role authenticated;
select set_config('request.jwt.claim.sub',:'F',false);
select public.v2_begin_import('27000000-0000-0000-0000-0000000000f1','2310.06825',0);
reset role;
update app_private.pipeline_papers set next_attempt_at=now()+interval '1 day' where id=:'p4';
update app_private.pipeline_imports set next_sync_at=now()+interval '1 day',retry_requested=false where paper_id=:'p4';
select test.to_download('2310.06825') as p6 \gset
update app_private.pipeline_papers set claim_id=gen_random_uuid(),lease_until=clock_timestamp()-interval '1 second',stage_crashes=2 where id=:'p6';
select app_private.pipeline_sweep_crashes();
select test.assert((select stage='failed' and error_code='download_failed' and resume_stage='download'
 and auto_retry_at between now()+interval '14 minutes' and now()+interval '16 minutes' from app_private.pipeline_papers where id=:'p6'),
 'a crash loop at download is retried in 15 minutes');
select test.sync(:'p6');
select test.assert(test.entry(:'F','27000000-0000-0000-0000-0000000000f1')->>'error_code'='download_retrying'
 and test.entry(:'F','27000000-0000-0000-0000-0000000000f1') ? 'auto_retry_at','its reader sees the retry coming');

-- 7. Entries: the new key only while a failed import waits for its retry; otherwise 019's JSON.
select test.assert(not exists(select 1 from app_private.import_requests i
 where (app_private.library_import_entry(i.account_id,i.id)-'auto_retry_at') is distinct from pg_temp.entry_019(i.account_id,i.id)
  or (app_private.library_import_entry(i.account_id,i.id) ? 'auto_retry_at') is distinct from (i.phase='failed' and i.auto_retry_at is not null)),
 'every entry is 019''s, plus auto_retry_at only while a retry is scheduled');
select test.assert(exists(select 1 from app_private.import_requests where phase='failed' and auto_retry_at is not null),'the check above covered a scheduled retry');
select test.reject($q$update app_private.pipeline_papers set auto_retry_at=now() where stage<>'failed'$q$,'pipeline_auto_retry_failed');
rollback;
