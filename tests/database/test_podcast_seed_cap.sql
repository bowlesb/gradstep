-- Seed pilot cap (migration 051): the owner approved "Raise to $5 total" on 2026-10-08. A seed period may now
-- hold at most $5 (5,000,000 micro-USD); each admission still holds the five-minute profile's $0.75 and a period
-- still has at most two seed episodes. Replays the staging pilot's committed spend ($1.007 after five failed
-- jobs), shows what $2 and $5 admit from there, and checks both bounds, privileges and the episode cap.
-- Synthetic local SQL with explicit provider receipts; nothing leaves the machine.
begin;
create schema if not exists test;
grant usage on schema test to anon,authenticated,service_role;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin begin execute statement; exception when others then
 if position(expected in sqlerrm)=0 then raise exception 'Unexpected rejection: % (wanted %)',sqlerrm,expected; end if; rejected:=true; end;
 if not rejected then raise exception 'Expected rejection: %',expected; end if; end $$;
grant execute on all functions in schema test to anon,authenticated,service_role;

\set O '51000000-0000-0000-0000-00000000000f'
insert into auth.users(id) values(:'O');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
update app_private.paper_asset_policy set inventory_verified_at=clock_timestamp(),enforced=true,inventory_scope=3,inventory_discrepancies=0,reconciliation_id=null where singleton;
update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);

-- Converted CC BY catalog papers with their exact standalone text (direct fixture rows, as in test_podcast_seed_episodes).
create or replace function test.cap_paper(n integer) returns uuid language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid(); appr uuid:=gen_random_uuid();
 run uuid:=gen_random_uuid(); art uuid:=gen_random_uuid(); orig uuid:=gen_random_uuid(); rawm uuid:=gen_random_uuid(); txt uuid:=gen_random_uuid();
 readm uuid:=gen_random_uuid(); raw_digest text:=encode(sha256(convert_to('cap-raw'||n,'UTF8')),'hex'); reader_digest text:=encode(sha256(convert_to('cap-reader'||n,'UTF8')),'hex');
 metadata jsonb:=jsonb_build_object('title','Seed cap paper '||n,'authors',jsonb_build_array('C. Fixture'),'published_at','2025-01-02','categories',jsonb_build_array('cs.LG'));
begin
 insert into app_private.publications(id,title) values(pub,'Seed cap paper '||n);
 insert into app_private.publication_versions(id,publication_id,source,revision) values(ver,pub,'arxiv','1');
 insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
  values(doc,sha256(convert_to('cap-document'||n,'UTF8')),'shared_catalog','{"license":"CC-BY-4.0"}',1000,2);
 insert into app_private.version_documents values(ver,doc);
 insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values
  (orig,'paper-assets','originals/'||encode(sha256(convert_to('cap-original'||n,'UTF8')),'hex')||'.pdf',doc,'verified',sha256(convert_to('cap-original'||n,'UTF8')),1000,'application/pdf',now()),
  (rawm,'paper-assets','raw/'||raw_digest||'/manifest.json',doc,'verified',decode(raw_digest,'hex'),100,'application/json',now()),
  (txt,'paper-assets','raw/'||raw_digest||'/standalone.mmd',doc,'verified',sha256(convert_to('cap-text'||n,'UTF8')),5000,'text/plain',now()),
  (readm,'paper-assets','reader/'||reader_digest||'/manifest.json',doc,'verified',decode(reader_digest,'hex'),100,'application/json',now());
 insert into app_private.paper_asset_manifest_members values(rawm,txt,'standalone.mmd');
 insert into app_private.catalog_metadata(id,version_id,source_id,source_revision,metadata,metadata_sha256)
  values(meta,ver,'2501.5100'||n,1,metadata,sha256(convert_to(metadata::text,'UTF8')));
 insert into app_private.catalog_asset_approvals(id,version_id,document_id,metadata_id,original_object_id,license_uri,policy_version,evidence)
  values(appr,ver,doc,meta,orig,'https://creativecommons.org/licenses/by/4.0/','arxiv-reuse-v1','{}');
 insert into app_private.ocr_runs(id,document_id,provider,options_sha256,raw_bundle_object_id) values(run,doc,'mathpix',sha256(convert_to('cap-options'||n,'UTF8')),rawm);
 insert into app_private.render_artifacts(id,ocr_run_id,renderer_version,manifest_object_id) values(art,run,'podcast-cap-test-v1',readm);
 return appr;
end $$;
select test.cap_paper(1) as a1 \gset
select test.cap_paper(2) as a2 \gset
select test.cap_paper(3) as a3 \gset

-- One paid attempt with an explicit receipt, as the worker records it.
create or replace function test.cap_attempt(j uuid,c uuid,g bigint,route text,cost bigint) returns void language plpgsql as $$
declare attempt uuid:=gen_random_uuid(); admission jsonb;
begin
 admission:=public.worker_podcast_attempt_begin(j,c,g,attempt,route,sha256(convert_to(route||attempt::text,'UTF8')));
 perform test.assert((admission->>'granted')::boolean,'grant '||route||' '||coalesce(admission->>'reason',''));
 perform public.worker_provider_attempt_finish((admission->>'account_id')::uuid,(admission->>'operation_id')::uuid,attempt,'succeeded',
  'req_'||left(attempt::text,8),cost,'{"input_tokens":30000,"output_tokens":4000}'::jsonb,null);
end $$;
create or replace function test.cap_admit(approval uuid) returns jsonb language sql as $$
 select public.worker_podcast_seed_admit('51000000-0000-0000-0000-00000000000f'::uuid,gen_random_uuid(),approval,'CC BY 4.0 verified; no third-party exclusions found')
$$;
-- A seed job that bills its draft and review, then fails the checker (quality): its actual usage stays committed.
create or replace function test.cap_failed_seed(approval uuid,draft bigint,review bigint) returns void language plpgsql as $$
declare j uuid:=(test.cap_admit(approval)->>'id')::uuid; c uuid:=gen_random_uuid(); claim jsonb; g bigint;
begin
 claim:=public.worker_podcast_claim(c);
 perform test.assert((claim->>'job_id')::uuid=j,'claimed the intended seed job');
 g:=(claim->>'generation')::bigint;
 perform test.cap_attempt(j,c,g,'podcast_script',draft);
 perform public.worker_podcast_advance(j,c,g,'checking');
 perform test.cap_attempt(j,c,g,'podcast_review',review);
 perform test.assert((public.worker_podcast_fail(j,c,g,'script_evidence_rejected',true)->>'state')='failed','seed job failed (quality)');
end $$;
create or replace function test.cap_committed() returns bigint language sql as $$
 select app_private.podcast_seed_committed(date_trunc('month',now() at time zone 'UTC')::date)
$$;
create or replace function test.cap_period() returns app_private.podcast_seed_periods language sql as $$
 select * from app_private.podcast_seed_periods where period=date_trunc('month',now() at time zone 'UTC')::date
$$;

-- 051 keeps 048's privileges: security definer, empty search_path, the service role only.
select test.assert((select p.prosecdef and p.proconfig=array['search_path=""'] and has_function_privilege('service_role',p.oid,'execute')
 and not has_function_privilege('authenticated',p.oid,'execute') and not has_function_privilege('anon',p.oid,'execute')
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='worker_podcast_seed_period'),
 'seed period RPC: security definer, empty search_path, service role only');
select test.assert((select count(*)=1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='worker_podcast_seed_period'),
 'replaced in place, no overload');
-- One limit check on the table, now at $5; the episode check is unchanged.
select test.assert((select array_agg(pg_get_constraintdef(c.oid) order by c.conname) from pg_constraint c
 where c.conrelid='app_private.podcast_seed_periods'::regclass and c.contype='c' and pg_get_constraintdef(c.oid) like '%limit_microusd%')
 =array['CHECK (((limit_microusd >= 0) AND (limit_microusd <= 5000000)))'],'table check: at most $5');
select test.assert((select count(*)=1 from pg_constraint c where c.conrelid='app_private.podcast_seed_periods'::regclass and c.contype='c'
 and pg_get_constraintdef(c.oid)='CHECK (((max_episodes >= 0) AND (max_episodes <= 2)))'),'table check: at most two episodes, unchanged');

-- The pilot as on staging: the $2 period, five failed seed jobs, $1.007186 committed.
select public.worker_podcast_policy_set(:'O',gen_random_uuid(),'{"seed_enabled":true,"max_active_environment":3}','Seed pilot (051 test)');
select public.worker_podcast_seed_period(:'O',gen_random_uuid(),:'month',2000000,true,'owner-decision-20261008',2);
select test.cap_failed_seed(:'a1',107000,109000);
select test.cap_failed_seed(:'a2',109000,114000);
select test.cap_failed_seed(:'a1',107000,83000);
select test.cap_failed_seed(:'a2',105000,84000);
select test.cap_failed_seed(:'a1',107134,82052);
select test.assert(test.cap_committed()=1007186,'the pilot has committed $1.007186');
savepoint pilot;

-- At $2 one more $0.75 hold fits ($1.757186) and a second does not.
select test.assert((test.cap_admit(:'a1')->>'seed_committed_microusd')::bigint=1757186,'one hold within $2');
select test.reject(format('select test.cap_admit(%L)',:'a2'),'seed_allowance_exhausted');
rollback to savepoint pilot;

-- The owner's $5: accepted at exactly 5,000,000 (audited, replayable), the committed spend carried over.
\set P '51000000-0000-0000-0002-000000000005'
select public.worker_podcast_seed_period(:'O',:'P',:'month',5000000,true,'owner-decision-20261008-raise-to-5',2) as raised \gset
select test.assert((:'raised'::jsonb->>'limit_microusd')::bigint=5000000 and (:'raised'::jsonb->>'max_episodes')::integer=2
 and (:'raised'::jsonb->>'committed_microusd')::bigint=1007186 and not (:'raised'::jsonb->>'replayed')::boolean,'a $5 period is accepted');
select test.assert((public.worker_podcast_seed_period(:'O',:'P',:'month',5000000,true,'owner-decision-20261008-raise-to-5',2)->>'replayed')::boolean,'replay');
select test.assert((select changes->>'limit_microusd'='5000000' from app_private.podcast_policy_events where id=:'P'),'audited as a policy event');
-- $5.01 and anything over $5 are refused by the function and by the table.
select test.reject(format('select public.worker_podcast_seed_period(%L,gen_random_uuid(),%L,5010000,true,%L,2)',:'O',:'month','owner-decision-20261008'),'invalid_seed_period');
select test.reject(format('select public.worker_podcast_seed_period(%L,gen_random_uuid(),%L,5000001,true,%L,2)',:'O',:'month','owner-decision-20261008'),'invalid_seed_period');
select test.reject(format('update app_private.podcast_seed_periods set limit_microusd=5000001 where period=%L',:'month'),'podcast_seed_periods_limit_microusd_check');
select test.reject(format('select public.worker_podcast_seed_period(%L,gen_random_uuid(),%L,-1,true,%L,2)',:'O',:'month','owner-decision-20261008'),'invalid_seed_period');
-- Still at most two episodes per period.
select test.reject(format('select public.worker_podcast_seed_period(%L,gen_random_uuid(),%L,5000000,true,%L,3)',:'O',:'month','three-episodes'),'invalid_seed_period');
select test.reject(format('update app_private.podcast_seed_periods set max_episodes=3 where period=%L',:'month'),'podcast_seed_periods_max_episodes_check');
select test.assert((test.cap_period()).limit_microusd=5000000 and (test.cap_period()).max_episodes=2,'refusals left the period unchanged');

-- From $1.007186 committed, both seeds now fit at $0.75 each ($2.507186); a third is refused by the episode cap with dollars left.
select test.cap_admit(:'a1') as j1 \gset
select test.cap_admit(:'a2') as j2 \gset
select test.assert((:'j2'::jsonb->>'seed_committed_microusd')::bigint=2507186,'two holds within $5');
select test.assert((select bool_and(op.spend_ceiling_microusd=750000) from app_private.podcast_jobs j
 join app_private.metered_operations op on (op.account_id,op.id)=(j.operation_account_id,j.operation_id) where j.id in ((:'j1'::jsonb->>'id')::uuid,(:'j2'::jsonb->>'id')::uuid)),
 'each admission still holds at most $0.75');
select test.assert(app_private.podcast_seed_episodes(:'month')=2,'two seed episodes in flight');
select test.reject(format('select test.cap_admit(%L)',:'a3'),'seed_episode_limit');

rollback;
