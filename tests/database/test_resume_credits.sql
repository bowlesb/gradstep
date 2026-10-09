-- Imports waiting on credits resume by themselves (migration 040; owner feedback build 16 #1): oldest first,
-- as far as the balance allows, through the reader's retry path and the unchanged funding (one reservation per
-- paper), never for suspended accounts, idempotent, throttled, workers only. Real RPCs throughout.
begin;
-- Only this file's papers are claimable here (rolled back at the end).
update app_private.pipeline_papers set lease_until=now()+interval '1 day',claim_id=coalesce(claim_id,gen_random_uuid());

create function test.cr_claim(p uuid) returns jsonb language plpgsql as $$
declare e jsonb;
begin
 -- Several papers can be due at once (restarted ones wait for a claim): take this one first.
 update app_private.pipeline_papers set next_attempt_at=now()-interval '10 years' where id=p;
 e:=public.worker_pipeline_claim(gen_random_uuid());
 if e is null or (e->>'id')::uuid is distinct from p then raise exception 'expected to claim %, got %',p,coalesce(e->>'id','nothing'); end if;
 return e;
end $$;
-- A shared CC BY paper taken to funding, where its only interested account(s) cannot pay: needs_credits.
create function test.cr_needs_credits(a uuid,i uuid,src text,pages integer,bytes_hex text,age interval) returns uuid language plpgsql as $$
declare p uuid; e jsonb; c uuid; g bigint;
begin
 perform set_config('request.jwt.claim.sub',a::text,true);
 perform public.v2_begin_import(i,src,0);
 update app_private.import_requests set created_at=now()-age where account_id=a and id=i;
 select paper_id into strict p from app_private.pipeline_imports where account_id=a and import_id=i;
 e:=test.cr_claim(p); c:=(e->>'claim_id')::uuid; g:=(e->>'generation')::bigint;
 perform public.worker_pipeline_metadata(p,c,g,1,jsonb_build_object('title','Paper '||src,'authors',jsonb_build_array('A. Author'),'categories',jsonb_build_array('cs.LG')),
  true,'https://creativecommons.org/licenses/by/4.0/',
  jsonb_build_object('source_id',src,'source_revision',1,'source_url','https://arxiv.org/abs/'||src||'v1','license_uri','https://creativecommons.org/licenses/by/4.0/',
   'evidence_sha256',repeat('e',64),'observed_at','2026-10-05T05:00:00Z'));
 perform public.worker_pipeline_original(p,c,g,('\x'||repeat(bytes_hex,32))::bytea,1000000,pages,'originals/'||repeat(bytes_hex,32)||'.pdf');
 if public.worker_pipeline_fund(p,c,g,pages,('\x'||repeat(bytes_hex,32))::bytea,('\x'||repeat(bytes_hex,32))::bytea)->>'funding'<>'needs_credits' then
  raise exception 'expected % to need credits',src; end if;
 perform public.worker_pipeline_sync_imports(p,c,g);
 perform public.worker_pipeline_release(p,c,g);
 return p;
end $$;
-- The next claim resumes the paper at funding; fund it as the worker would.
create function test.cr_fund(p uuid,pages integer,bytes_hex text) returns text language plpgsql as $$
declare e jsonb:=test.cr_claim(p); c uuid:=(e->>'claim_id')::uuid; g bigint:=(e->>'generation')::bigint; r text;
begin
 if e->>'stage'<>'ocr_fund' then raise exception 'expected % to resume at funding, got %',p,e->>'stage'; end if;
 r:=public.worker_pipeline_fund(p,c,g,pages,('\x'||repeat(bytes_hex,32))::bytea,('\x'||repeat(bytes_hex,32))::bytea)->>'funding';
 perform public.worker_pipeline_sync_imports(p,c,g);
 perform public.worker_pipeline_release(p,c,g);
 return r;
end $$;
create function test.cr_phase(a uuid,i uuid) returns text language sql as $$
 select phase||coalesce(':'||error_code,'') from app_private.import_requests where account_id=a and id=i
$$;
create function test.cr_resume() returns jsonb language sql as $$ select public.worker_pipeline_resume_credits(0,100) $$;

insert into auth.users values('40000000-0000-0000-0000-00000000000a'),('40000000-0000-0000-0000-00000000000b'),
 ('40000000-0000-0000-0000-00000000000c'),('40000000-0000-0000-0000-00000000000d'),('40000000-0000-0000-0000-00000000000e'),
 ('40000000-0000-0000-0000-00000000000f');
\set A '40000000-0000-0000-0000-00000000000a'
\set B '40000000-0000-0000-0000-00000000000b'
\set C '40000000-0000-0000-0000-00000000000c'
\set D '40000000-0000-0000-0000-00000000000d'
\set E '40000000-0000-0000-0000-00000000000e'
\set F '40000000-0000-0000-0000-00000000000f'

-- Workers only.
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject('select public.worker_pipeline_resume_credits()','permission denied');
reset role;
set role anon;
select test.reject('select public.worker_pipeline_resume_credits()','permission denied');
reset role;
set role service_role;
select public.worker_set_pipeline_enabled(false);
select test.assert(not (public.worker_pipeline_resume_credits()->>'swept')::boolean,'a disabled pipeline resumes nothing');
select test.reject('select public.worker_pipeline_resume_credits(-1)','invalid_resume_request');
select test.reject('select public.worker_pipeline_resume_credits(0,0)','invalid_resume_request');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_set_pipeline_enabled(true);
reset role;
update app_private.pipeline_policy set credit_resume_swept_at='-infinity';
select test.assert(exists(select 1 from pg_trigger where tgname='credit_resume_kick' and tgrelid='app_private.credit_buckets'::regclass),'balance increases wake the worker');

-- Below, the session runs worker RPCs as the owner role and customer RPCs with the reader's JWT subject.
-- 1. Three imports by A wait on credits: 36 pages (oldest), 10 pages, 5 pages (newest). One credit per page.
select test.cr_needs_credits(:'A','40000000-0000-0000-0000-0000000000a1','2312.00752',36,'a1','3 hours') as p1 \gset
select test.cr_needs_credits(:'A','40000000-0000-0000-0000-0000000000a2','2305.18290',10,'a2','2 hours') as p2 \gset
select test.cr_needs_credits(:'A','40000000-0000-0000-0000-0000000000a3','2006.11239',5,'a3','1 hour') as p3 \gset
select test.assert(test.cr_phase(:'A','40000000-0000-0000-0000-0000000000a1')='failed:insufficient_credits','the oldest import waits on credits');
select test.assert((select count(*) from app_private.pipeline_papers where id in (:'p1',:'p2',:'p3') and stage='needs_credits')=3,'three papers need credits');
select test.assert(not (test.cr_resume()->>'swept')::boolean,'no balance, nothing to resume (and no locks taken)');

-- 2. An owner grant of 12 credits: the oldest (36) does not fit, the next (10) does, the newest (5) no longer does.
select public.worker_grant_credits(:'A','adjustment','credit-resume-a-1',12,now()-interval '1 minute',null,'Credit resume test');
select test.cr_resume() as r \gset
select test.assert((:'r'::jsonb->>'resumed')::integer=1 and (:'r'::jsonb->>'unaffordable')::integer=2,'one import fits the balance: '||:'r');
select test.assert(test.cr_phase(:'A','40000000-0000-0000-0000-0000000000a1')='failed:insufficient_credits','36 pages do not fit 12 credits');
select test.assert(test.cr_phase(:'A','40000000-0000-0000-0000-0000000000a2')='acquiring','10 pages fit: restarted like the reader''s Retry');
select test.assert(test.cr_phase(:'A','40000000-0000-0000-0000-0000000000a3')='failed:insufficient_credits','5 more pages exceed the 2 credits left');
select test.assert((select intent_revision=1 from app_private.import_requests where account_id=:'A' and id='40000000-0000-0000-0000-0000000000a2'),
 'a worker restart keeps the reader''s intent revision');
select test.assert((select retry_requested from app_private.pipeline_imports where account_id=:'A' and import_id='40000000-0000-0000-0000-0000000000a2'),
 'the next claim resumes the paper');
-- Idempotent: the restarted import's need counts against the balance until it is funded.
select test.assert((test.cr_resume()->>'resumed')::integer=0,'a second sweep restarts nothing more');
select test.assert(not exists(select 1 from app_private.metered_operations where account_id=:'A'),'restarting reserves nothing');

-- 3. The claim resumes funding; exactly one reservation for the restarted paper.
select test.assert(test.cr_fund(:'p2',10,'a2')='funded','the restarted paper is funded');
select test.assert((select count(*) from app_private.metered_operations where account_id=:'A')=1,'one reservation');
select test.assert((select sum(reserved) from app_private.credit_buckets where account_id=:'A')=10,'10 credits held');
select test.assert((test.cr_resume()->>'resumed')::integer=0,'2 credits left cover nothing');

-- 4. A purchase-sized grant: oldest first, then the next that still fits.
select public.worker_grant_credits(:'A','adjustment','credit-resume-a-2',40,now()-interval '1 minute',null,'Credit resume test');
select test.cr_resume() as r \gset
select test.assert((:'r'::jsonb->>'resumed')::integer=2,'both remaining imports fit 42 credits: '||:'r');
select test.assert(test.cr_phase(:'A','40000000-0000-0000-0000-0000000000a1')='acquiring' and test.cr_phase(:'A','40000000-0000-0000-0000-0000000000a3')='acquiring','both restarted');
select test.assert(test.cr_fund(:'p1',36,'a1')='funded' and test.cr_fund(:'p3',5,'a3')='funded','both funded');
select test.assert((select count(*) from app_private.metered_operations where account_id=:'A')=3,'one reservation per paper, no double charge');
select test.assert((select sum(reserved) from app_private.credit_buckets where account_id=:'A')=51,'51 of 52 credits held');
select test.assert((test.cr_resume()->>'resumed')::integer=0,'nothing waits any more');

-- 5. A suspended account is never restarted (funding would refuse it and loop); a closed one neither.
select test.cr_needs_credits(:'B','40000000-0000-0000-0000-0000000000b1','2201.11903',4,'b1','1 hour') as pb \gset
select public.worker_grant_credits(:'B','adjustment','credit-resume-b',50,now()-interval '1 minute',null,'Credit resume test');
update app_private.accounts set spending_suspended=true where id=:'B';
select test.assert((test.cr_resume()->>'resumed')::integer=0,'suspended: nothing restarted');
select test.assert(test.cr_phase(:'B','40000000-0000-0000-0000-0000000000b1')='failed:insufficient_credits','the suspended reader keeps Retry');
update app_private.accounts set spending_suspended=false where id=:'B';
select test.assert((test.cr_resume()->>'resumed')::integer=1,'re-enabled: restarted');

-- 6. Throttle: a sweep within the interval does nothing.
select test.cr_needs_credits(:'C','40000000-0000-0000-0000-0000000000c1','2204.02311',3,'c1','1 hour') as pc \gset
select public.worker_grant_credits(:'C','adjustment','credit-resume-c',3,now()-interval '1 minute',null,'Credit resume test');
select test.assert(not (public.worker_pipeline_resume_credits(3600)->>'swept')::boolean,'swept a moment ago: skipped');
select test.assert(test.cr_phase(:'C','40000000-0000-0000-0000-0000000000c1')='failed:insufficient_credits','still waiting after a throttled sweep');

-- 7. At the account's active-import limit: postponed (still failed), restarted once a slot frees.
select set_config('request.jwt.claim.sub',:'C',false);
select public.v2_begin_import('40000000-0000-0000-0000-0000000000c9','2204.02312',0);
update app_private.library_policy set account_active_imports=1;
select test.cr_resume() as r \gset
select test.assert((:'r'::jsonb->>'limited')::integer=1 and (:'r'::jsonb->>'resumed')::integer=0,'limited: '||:'r');
select test.assert(test.cr_phase(:'C','40000000-0000-0000-0000-0000000000c1')='failed:insufficient_credits','a limited restart leaves the import as it was');
update app_private.library_policy set account_active_imports=100;
select test.assert((test.cr_resume()->>'resumed')::integer=1,'restarted once a slot is free');

-- 8. A shared paper two readers wait on: the one who gets credits restarts and pays; the other follows it, free.
select test.cr_needs_credits(:'D','40000000-0000-0000-0000-0000000000d1','2106.09685',6,'d1','2 hours') as pd \gset
select set_config('request.jwt.claim.sub',:'E',false);
select public.v2_begin_import('40000000-0000-0000-0000-0000000000e1','2106.09685',0);
select test.assert((select stage='needs_credits' from app_private.pipeline_papers where id=:'pd'),'still waiting');
select test.cr_claim(:'pd') as e \gset
select test.assert(public.worker_pipeline_fund(:'pd',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint,6,('\x'||repeat('d1',32))::bytea,('\x'||repeat('d1',32))::bytea)->>'funding'='needs_credits','neither can pay');
select public.worker_pipeline_sync_imports(:'pd',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select public.worker_pipeline_release(:'pd',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select test.assert(test.cr_phase(:'E','40000000-0000-0000-0000-0000000000e1')='failed:insufficient_credits','the later reader waits too');
select public.worker_grant_credits(:'E','adjustment','credit-resume-e',6,now()-interval '1 minute',null,'Credit resume test');
select test.assert((test.cr_resume()->>'resumed')::integer=1,'the reader with credits restarts');
select test.assert(test.cr_phase(:'D','40000000-0000-0000-0000-0000000000d1')='failed:insufficient_credits','the other still waits');
select test.assert(test.cr_fund(:'pd',6,'d1')='funded','funded');
select test.assert(exists(select 1 from app_private.metered_operations where account_id=:'E') and not exists(select 1 from app_private.metered_operations where account_id=:'D'),
 'the reader who restarted pays; the other is not charged');
select public.worker_pipeline_auto_retry(0,100);
select test.assert(test.cr_phase(:'D','40000000-0000-0000-0000-0000000000d1')='acquiring','the other import heals and follows the funded paper');

-- 9. A private download waiting for its owner's first credit (016) restarts on one credit.
select set_config('request.jwt.claim.sub',:'F',false);
select public.v2_begin_import('40000000-0000-0000-0000-0000000000f1','2302.13971',0);
select paper_id as shared_f from app_private.pipeline_imports where account_id=:'F' and import_id='40000000-0000-0000-0000-0000000000f1' \gset
select test.cr_claim(:'shared_f') as e \gset
select public.worker_pipeline_metadata(:'shared_f',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint,1,
 '{"title":"LLaMA","authors":[],"categories":["cs.CL"]}',false,'http://arxiv.org/licenses/nonexclusive-distrib/1.0/',jsonb_build_object('private_permission','fixture-approved'));
select public.worker_pipeline_release(:'shared_f',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select test.cr_claim(:'shared_f') as e \gset
select public.worker_pipeline_split_private(:'shared_f',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select public.worker_pipeline_release(:'shared_f',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select paper_id as private_f from app_private.pipeline_imports where account_id=:'F' and import_id='40000000-0000-0000-0000-0000000000f1' \gset
select test.assert((select owner_id=:'F' from app_private.pipeline_papers where id=:'private_f'),'F converts privately');
select test.cr_claim(:'private_f') as e \gset
select test.assert(public.worker_pipeline_admit_download(:'private_f',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint)->>'reason'='needs_credits','no credits, no download');
select public.worker_pipeline_sync_imports(:'private_f',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select public.worker_pipeline_release(:'private_f',(:'e'::jsonb->>'claim_id')::uuid,(:'e'::jsonb->>'generation')::bigint);
select test.assert(test.cr_phase(:'F','40000000-0000-0000-0000-0000000000f1')='failed:insufficient_credits','waiting for a credit to download');
select test.assert((test.cr_resume()->>'resumed')::integer=0,'no credit: the download keeps waiting');
select public.worker_grant_credits(:'F','adjustment','credit-resume-f',1,now()-interval '1 minute',null,'Credit resume test');
select test.assert((test.cr_resume()->>'resumed')::integer=1,'one credit admits a private download again');
select test.assert(test.cr_claim(:'private_f')->>'stage'='download','the private paper resumes at download');
rollback;
