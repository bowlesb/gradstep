-- Personalized feed (migration 043): switches off by default, a fenced refresh claim with
-- backoff and pruning, strict pool upserts, For you inputs from server-visible signals only
-- (library, tags, imports in flight, feedback), pool-served category chips, feedback limits and
-- account-closure cleanup.
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

-- A shared catalog paper with metadata and an approval, ready to be added to a library.
create function test.paper(p_source text,p_title text,p_authors jsonb,p_categories jsonb) returns table(doc uuid,approval uuid) language plpgsql as $$
declare meta uuid; d uuid:=gen_random_uuid(); o uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); digest bytea:=decode(md5(p_source)||md5(p_source),'hex');
begin
 meta:=public.worker_record_arxiv_metadata(p_source,1,jsonb_build_object('title',p_title,'authors',p_authors,'categories',p_categories));
 insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values(d,digest,'shared_catalog','{"fixture":true}',1000,2);
 insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
  values(o,'paper-assets','test/feed/'||p_source||'.pdf',d,'verified',digest,1000,'application/pdf',now());
 perform public.worker_approve_arxiv_asset(a,meta,d,o,'https://creativecommons.org/licenses/by/4.0/',
  jsonb_build_object('source_id',p_source,'source_revision',1,'source_url','https://arxiv.org/abs/'||p_source||'v1',
   'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('a',64),'observed_at','2026-10-07T01:00:00Z'));
 return query select d,a;
end $$;
-- A pool item as the refresh function sends it.
create function test.item(p_source text,p_title text,p_authors jsonb,p_categories jsonb,p_topics jsonb,p_days_ago integer,
 p_abstract text default 'An abstract.',p_type text default 'new') returns jsonb language sql as $$
 select jsonb_build_object('source_id',p_source,'revision',1,'title',p_title,'authors',p_authors,'abstract',p_abstract,
  'categories',p_categories,'topics',p_topics,'announced_on',((now() at time zone 'UTC')::date-p_days_ago)::text,'announce_type',p_type)
$$;
create function test.ids(p jsonb) returns text[] language sql as $$
 select coalesce(array(select c->>'source_id' from jsonb_array_elements(p) c order by 1),'{}')
$$;

insert into auth.users values('44000000-0000-0000-0000-00000000000a'),('44000000-0000-0000-0000-00000000000b'),
 ('44000000-0000-0000-0000-00000000000c'),('44000000-0000-0000-0000-00000000000d'),('44000000-0000-0000-0000-00000000000e'),
 ('44000000-0000-0000-0000-00000000005f');
insert into app_private.app_roles(account_id,role) values('44000000-0000-0000-0000-00000000005f','tester');

-- Off by default: nothing is fetched, served or recorded.
select test.assert((select serving='off' and not refresh_enabled from app_private.feed_policy),'both switches start off');
select test.assert(public.worker_feed_refresh_claim() is null,'no claim while refresh is off');
select test.assert(not app_private.feed_refresh_kick(),'the cron kick does nothing while off (and without pg_net locally)');
select test.reject($q$select public.worker_feed_candidates('44000000-0000-0000-0000-00000000000a')$q$,'feed_unavailable');
select test.assert(public.worker_feed_category('44000000-0000-0000-0000-00000000000a','cs.LG')->>'serving'='false','chips stay live while off');

-- Grants: workers are service-only; feedback is for signed-in readers only.
set role anon;
select test.reject($q$select public.v1_feed_feedback('2610.00001','not_interested')$q$,'permission denied');
select test.reject($q$select public.worker_feed_refresh_claim()$q$,'permission denied');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','44000000-0000-0000-0000-00000000000a',false);
select test.reject($q$select public.worker_set_feed_policy('all',true)$q$,'permission denied');
select test.reject($q$select public.worker_feed_candidates('44000000-0000-0000-0000-00000000000a')$q$,'permission denied');
select test.reject($q$select public.worker_feed_upsert(gen_random_uuid(),'[]',(select 'feed-topics-v1'))$q$,'permission denied');
select test.reject($q$select public.v1_feed_feedback('2610.00001','not_interested')$q$,'feed_unavailable');
select test.reject($q$select * from app_private.feed_papers$q$,'permission denied');
reset role;
select test.reject($q$select public.worker_set_feed_policy('everyone',true)$q$,'invalid_feed_policy');

-- Refresh claim: one live claim at a time, fenced by its lease.
set role service_role;
select public.worker_set_feed_policy('off',true);
select public.worker_feed_refresh_claim() as claim \gset
select test.assert((:'claim'::jsonb->>'source')='arxiv-ml' and :'claim'::jsonb->'etag'='null'::jsonb
 and jsonb_array_length(:'claim'::jsonb->'categories')=12 and (:'claim'::jsonb->>'max_items')::integer=3000,'first claim');
select :'claim'::jsonb->>'claim_id' as c1 \gset
select test.assert(public.worker_feed_refresh_claim() is null,'a live claim excludes another');
select test.reject($q$select public.worker_feed_upsert(gen_random_uuid(),'[]','feed-topics-v1')$q$,'feed_claim_lost');

-- Strict items: unknown keys, bad identifiers, too many authors, out-of-range dates, duplicates.
select test.reject(format('select public.worker_feed_upsert(%L,%L,%L)',:'c1',
 jsonb_build_array(test.item('2610.0001x','T','[]','["cs.LG"]','[]',0)),'feed-topics-v1'),'invalid_feed_items');
select test.reject(format('select public.worker_feed_upsert(%L,%L,%L)',:'c1',
 jsonb_build_array(test.item('2610.00001','T','[]','["cs.LG"]','[]',0)||'{"url":"x"}'),'feed-topics-v1'),'invalid_feed_items');
select test.reject(format('select public.worker_feed_upsert(%L,%L,%L)',:'c1',
 jsonb_build_array(test.item('2610.00001','T',(select jsonb_agg('Author '||n) from generate_series(1,13) n),'["cs.LG"]','[]',0)),'feed-topics-v1'),'invalid_feed_items');
select test.reject(format('select public.worker_feed_upsert(%L,%L,%L)',:'c1',
 jsonb_build_array(test.item('2610.00001','T','[]','["cs.LG"]','[]',90)),'feed-topics-v1'),'invalid_feed_items');
select test.reject(format('select public.worker_feed_upsert(%L,%L,%L)',:'c1',
 jsonb_build_array(test.item('2610.00001','T','[]','["cs.LG"]','[]',0),test.item('2610.00001','T','[]','["cs.LG"]','[]',0)),'feed-topics-v1'),'invalid_feed_items');
select test.reject(format('select public.worker_feed_upsert(%L,%L,%L)',:'c1',
 jsonb_build_array(test.item('2610.00001','T','[]','["cs.LG"]','[1]',0)),'feed-topics-v1'),'invalid_feed_items');
select test.reject(format('select public.worker_feed_upsert(%L,%L,%L)',:'c1','[]','Feed Topics'),'invalid_feed_items');

-- The pool for the ranking fixtures below (days ago in the last argument but one).
select public.worker_feed_upsert(:'c1', jsonb_build_array(
 test.item('2610.00001','Diffusion for video','["Mei Lin","Jonas Weber"]','["cs.CV"]','["Diffusion models","Computer vision"]',1),
 test.item('2610.00002','A new Turing machine','["Bea Kim","Alan Turing"]','["cs.AI"]','[]',2),
 test.item('2610.00003','Scaling feedback','["Ola Nordmann"]','["cs.CL"]','[]',1,'We revisit RLHF for long answers.'),
 test.item('2610.00004','Parsing again','["Ivo Dimitrov"]','["cs.CL"]','[]',0),
 test.item('2610.00005','String theory note','["Pat Physicist"]','["hep-th"]','[]',0),
 test.item('2401.00001','Our own paper','["Ada Lovelace","Alan Turing"]','["cs.LG","cs.CL"]','["Diffusion models"]',1),
 test.item('2610.00007','Unwanted paper','["Nobody Special"]','["cs.CV"]','["Diffusion models"]',1),
 test.item('2610.00008','Old diffusion','["Mei Lin"]','["cs.CV"]','["Diffusion models"]',20),
 test.item('2410.99999','Being imported','["Mei Lin"]','["cs.CV"]','["Diffusion models"]',1),
 test.item('2610.00010','Routing experts','["Grace Hopper","Ken Thompson"]','["cs.LG"]','["Mixture of experts"]',3),
 test.item('2610.00011','Hopper again','["Grace Hopper"]','["cs.DC"]','[]',2),
 test.item('2610.00012','Sparse experts','["Lin Su"]','["cs.DC"]','["Mixture of experts"]',2)),'feed-topics-v1') as written \gset
select test.assert((:'written'::jsonb->>'inserted')::integer=12 and (:'written'::jsonb->>'updated')::integer=0,'twelve papers inserted');
-- Twenty-five papers that all mention widgets, so the own tag "widgets" is too common to match.
select public.worker_feed_upsert(:'c1',(select jsonb_agg(test.item(format('2610.%s',20000+n),'Widget '||n,'["W. Maker"]','["cs.SE"]','[]',1,
 'We study widgets at scale.')) from generate_series(1,25) n),'feed-topics-v1');
-- Seen again as a cross-list in another category, later: categories merge, the first sighting stays.
reset role;
select first_seen_at as seen from app_private.feed_papers where source_id='2610.00004' \gset
set role service_role;
select public.worker_feed_upsert(:'c1',jsonb_build_array(
 test.item('2610.00004','Parsing again','["Ivo Dimitrov"]','["cs.LG","cs.CL"]','["Machine learning"]',0,null,'cross')),'feed-topics-v1') as again \gset
select test.assert((:'again'::jsonb->>'updated')::integer=1,'an existing paper is updated');
reset role;
select test.assert((select categories='{cs.CL,cs.LG}' and announce_type='new' and first_seen_at=:'seen'::timestamptz
 and abstract='An abstract.' and topics='{"Machine learning"}' and author_keys='{"ivo dimitrov"}' from app_private.feed_papers where source_id='2610.00004'),
 'categories merge, new wins over cross, the abstract and first sighting are kept, author keys normalized');
-- An old row (outside retention) inserted directly, then pruned when the refresh finishes.
insert into app_private.feed_papers(source_id,revision,title,authors,author_keys,categories,announced_on,announce_type)
 values('2609.00001',1,'Ancient','{}','{}','{cs.LG}',(now() at time zone 'UTC')::date-45,'new');
set role service_role;
select public.worker_feed_refresh_finish(:'c1','updated','"etag-1"','Thu, 08 Oct 2026 04:31:42 GMT',38) as finished \gset
select test.assert((:'finished'::jsonb->>'pruned')::integer=1 and (:'finished'::jsonb->>'pool')::integer=37,'retention pruned the old row');
reset role;
select test.assert((select etag='"etag-1"' and failures=0 and last_status='updated' and last_items=38 and claim_id is null
 and next_check_at between now()+interval '119 minutes' and now()+interval '121 minutes' from app_private.feed_sources),'updated: next check in 2 h');
set role service_role;
select test.assert(public.worker_feed_refresh_claim() is null,'not due yet');
select test.reject(format('select public.worker_feed_refresh_finish(%L,%L,null,null,0)',:'c1','updated'),'feed_claim_lost');

-- Failures back off 15 min, then 30 min; a busy pacing slot retries in 10 min without counting. (Run as the
-- owner: the grants were checked above.)
reset role;
update app_private.feed_sources set next_check_at=now()-interval '1 minute';
select public.worker_feed_refresh_claim()->>'claim_id' as c2 \gset
select test.assert((select etag='"etag-1"' from app_private.feed_sources),'validators are kept for the conditional request');
select public.worker_feed_refresh_finish(:'c2','failed',null,null,null);
select test.assert((select failures=1 and etag='"etag-1"' and next_check_at between now()+interval '14 minutes' and now()+interval '16 minutes'
 from app_private.feed_sources),'first failure: 15 min');
update app_private.feed_sources set next_check_at=now()-interval '1 minute';
select public.worker_feed_refresh_claim()->>'claim_id' as c3 \gset
select public.worker_feed_refresh_finish(:'c3','failed',null,null,null);
select test.assert((select failures=2 and next_check_at between now()+interval '29 minutes' and now()+interval '31 minutes' from app_private.feed_sources),'second failure: 30 min');
update app_private.feed_sources set next_check_at=now()-interval '1 minute';
select public.worker_feed_refresh_claim()->>'claim_id' as c4 \gset
select public.worker_feed_refresh_finish(:'c4','busy',null,null,null);
select test.assert((select failures=2 and last_status='busy' and next_check_at between now()+interval '9 minutes' and now()+interval '11 minutes'
 from app_private.feed_sources),'busy: 10 min, not a failure');
-- An expired lease can be claimed again; the late worker's finish is fenced out.
update app_private.feed_sources set next_check_at=now()-interval '1 minute';
select public.worker_feed_refresh_claim()->>'claim_id' as c5 \gset
update app_private.feed_sources set lease_until=now()-interval '1 second';
select public.worker_feed_refresh_claim()->>'claim_id' as c6 \gset
select test.assert(:'c6'<>:'c5','an expired lease is claimable');
select test.reject(format('select public.worker_feed_refresh_finish(%L,%L,null,null,null)',:'c5','not_modified'),'feed_claim_lost');
select public.worker_feed_refresh_finish(:'c6','not_modified',null,null,null);
select test.assert((select failures=0 and etag='"etag-1"' and last_items=38 and last_status='not_modified' from app_private.feed_sources),
 'not modified: success, validators and counts kept');
-- A different category list changes the request, so the validators are dropped.
update app_private.feed_policy set categories='{cs.LG,cs.CL,cs.CV,cs.AI,stat.ML,cs.RO,cs.IR,cs.NE,cs.MA,cs.SD,eess.AS,eess.IV,cs.SE}';
select public.worker_feed_refresh_claim()->>'claim_id' as c7 \gset
select test.assert((select etag is null and last_modified is null and cardinality(categories)=13 from app_private.feed_sources),'category change resets validators');
select public.worker_feed_refresh_finish(:'c7','not_modified',null,null,null);
-- The row cap trims the oldest papers.
update app_private.feed_policy set max_rows=1000;
insert into app_private.feed_papers(source_id,revision,title,authors,author_keys,categories,announced_on,announce_type)
 select format('2609.%s',10000+n),1,'Filler','{}','{}','{cs.SE}',(now() at time zone 'UTC')::date-25,'new' from generate_series(1,970) n;
update app_private.feed_sources set next_check_at=now()-interval '1 minute';
select public.worker_feed_refresh_claim()->>'claim_id' as c8 \gset
select test.assert((public.worker_feed_refresh_finish(:'c8','not_modified',null,null,null)->>'pool')::integer=1000,'row cap');
select test.assert((select count(*) from app_private.feed_papers where source_id like '2609.1%')=963
 and exists(select 1 from app_private.feed_papers where source_id='2610.00001'),'the oldest went first');
delete from app_private.feed_papers where source_id like '2609.1%';
update app_private.feed_policy set max_rows=60000;

-- Reader A's library: one paper (tags: catalog minus hidden, plus own), one import in flight.
select doc as own_doc,approval as own_approval from test.paper('2401.00001','Our own paper','["Ada Lovelace","Alan Turing"]','["cs.LG","cs.CL"]') \gset
select doc as p1_doc,approval as p1_approval from test.paper('2610.00001','Diffusion for video','["Mei Lin","Jonas Weber"]','["cs.CV"]') \gset
select doc as p2_doc,approval as p2_approval from test.paper('2610.00002','A new Turing machine','["Bea Kim","Alan Turing"]','["cs.AI"]') \gset
set role authenticated;
select set_config('request.jwt.claim.sub','44000000-0000-0000-0000-00000000000a',false);
select public.v2_set_library_item(gen_random_uuid(),:'own_doc',true,0,:'own_approval');
reset role;
update app_private.library_items set catalog_tags='{"Diffusion models","Machine learning"}',user_tags='{RLHF,widgets,important}',hidden_tags='{"Machine learning"}'
 where account_id='44000000-0000-0000-0000-00000000000a';
select last_seq as cursor_a from app_private.library_sync_state where account_id='44000000-0000-0000-0000-00000000000a' \gset
set role authenticated;
select public.v2_begin_import(gen_random_uuid(),'2410.99999',:cursor_a);
reset role;
-- Three other readers added 2610.00001 this week; two added 2610.00002.
set role authenticated;
select set_config('request.jwt.claim.sub','44000000-0000-0000-0000-00000000000c',false);
select public.v2_set_library_item(gen_random_uuid(),:'p1_doc',true,0,:'p1_approval');
select public.v2_set_library_item(gen_random_uuid(),:'p2_doc',true,0,:'p2_approval');
select set_config('request.jwt.claim.sub','44000000-0000-0000-0000-00000000000d',false);
select public.v2_set_library_item(gen_random_uuid(),:'p1_doc',true,0,:'p1_approval');
select public.v2_set_library_item(gen_random_uuid(),:'p2_doc',true,0,:'p2_approval');
select set_config('request.jwt.claim.sub','44000000-0000-0000-0000-00000000000e',false);
select public.v2_set_library_item(gen_random_uuid(),:'p1_doc',true,0,:'p1_approval');
reset role;

-- Staff only: a tester is served, reader A is not.
set role service_role;
select public.worker_set_feed_policy('staff',true);
select test.reject($q$select public.worker_feed_candidates('44000000-0000-0000-0000-00000000000a')$q$,'feed_unavailable');
select test.assert(jsonb_array_length(public.worker_feed_candidates('44000000-0000-0000-0000-00000000005f')->'candidates')>0,'staff are served');
select public.worker_set_feed_policy('all',true);
reset role;

-- Feedback: validated, one row per paper, features snapshotted from the pool, clearable.
set role authenticated;
select set_config('request.jwt.claim.sub','44000000-0000-0000-0000-00000000000a',false);
select test.reject($q$select public.v1_feed_feedback('not-an-id','not_interested')$q$,'invalid_feed_feedback');
select test.reject($q$select public.v1_feed_feedback('2610.00007','hide')$q$,'invalid_feed_feedback');
select test.assert(public.v1_feed_feedback('2610.00007','more_like_this')->>'kind'='more_like_this','recorded');
select test.assert(public.v1_feed_feedback('2610.00007','not_interested')->>'kind'='not_interested','replaced, not duplicated');
select public.v1_feed_feedback('2610.00010','more_like_this');
select public.v1_feed_feedback('2610.00005','more_like_this');
select test.assert(public.v1_feed_feedback('2610.00005',null)->'kind'='null'::jsonb,'cleared');
select public.v1_feed_feedback('2601.00042','not_interested');
reset role;
select test.assert((select count(*) from app_private.feed_feedback where account_id='44000000-0000-0000-0000-00000000000a')=3,'three rows');
select test.assert((select title='Routing experts' and topics='{"Mixture of experts"}' and author_keys='{"grace hopper","ken thompson"}'
 from app_private.feed_feedback where source_id='2610.00010'),'features snapshotted');
select test.assert((select title is null and topics='{}' from app_private.feed_feedback where source_id='2601.00042'),'a paper outside the pool is still hidden');

-- For you inputs for reader A.
set role service_role;
select public.worker_feed_candidates('44000000-0000-0000-0000-00000000000a') as fy \gset
reset role;
select test.assert(test.ids(:'fy'::jsonb->'candidates') @> '{2610.00001,2610.00002,2610.00003,2610.00004,2610.00010,2610.00011,2610.00012}',
 'topic, author, own-tag phrase, category and More-like-this matches are candidates: '||array_to_string(test.ids(:'fy'::jsonb->'candidates'),','));
select test.assert(not test.ids(:'fy'::jsonb->'candidates') && '{2401.00001,2410.99999,2610.00007,2610.00008}',
 'library, in-flight, Not interested and out-of-window papers are excluded');
select test.assert(not test.ids(:'fy'::jsonb->'candidates') && '{2610.00005}','other fields are not offered to a reader with a profile');
select test.assert((select c->'matched_tags'='["RLHF"]'::jsonb from jsonb_array_elements(:'fy'::jsonb->'candidates') c where c->>'source_id'='2610.00003'),
 'an own tag matches as a phrase');
select test.assert(not exists(select 1 from jsonb_array_elements(:'fy'::jsonb->'candidates') c where c->'matched_tags' ? 'widgets'),
 'an own tag matching more than 2 % of the window is ignored');
select test.assert(not exists(select 1 from jsonb_array_elements(:'fy'::jsonb->'candidates') c where c->'matched_tags' ? 'important'),
 'organizational tags are not phrases');
select test.assert((select (c->>'readers')::integer=3 from jsonb_array_elements(:'fy'::jsonb->'candidates') c where c->>'source_id'='2610.00001'),
 'three other readers: reported');
select test.assert((select c->'readers'='null'::jsonb from jsonb_array_elements(:'fy'::jsonb->'candidates') c where c->>'source_id'='2610.00002'),
 'two readers: not reported');
select test.assert((select c->'author_keys'='["bea kim","alan turing"]'::jsonb and c->>'first_seen_at' is not null
 from jsonb_array_elements(:'fy'::jsonb->'candidates') c where c->>'source_id'='2610.00002'),'author keys aligned with authors');
select test.assert((select count(*) from jsonb_array_elements(:'fy'::jsonb->'profile'))=2,'profile: the library paper and the import in flight');
select test.assert((select p->>'title'='Our own paper' and p->'tags' @> '["Diffusion models","RLHF"]'::jsonb and not (p->'tags' ? 'Machine learning')
 and p->'own_tags'='["RLHF","widgets","important"]'::jsonb and p->'categories'='["cs.LG","cs.CL"]'::jsonb
 and p->'author_keys' @> '["ada lovelace","alan turing"]'::jsonb and not (p->>'pending')::boolean
 from jsonb_array_elements(:'fy'::jsonb->'profile') p where p->>'source_id'='2401.00001'),'profile paper: hidden catalog tags removed, own tags kept');
select test.assert((select (p->>'pending')::boolean from jsonb_array_elements(:'fy'::jsonb->'profile') p where p->>'source_id'='2410.99999'),'import in flight');
select test.assert(jsonb_array_length(:'fy'::jsonb->'feedback')=3 and (:'fy'::jsonb->>'pool')::integer=36
 and :'fy'::jsonb->>'seed' like '44000000-0000-0000-0000-00000000000a:%' and :'fy'::jsonb->>'refreshed_at' is not null,'feedback, pool size, seed, refresh time');

-- Cold start: no profile, so the newest papers in the pool's categories (not other fields).
set role service_role;
select public.worker_feed_candidates('44000000-0000-0000-0000-00000000000b') as cold \gset
reset role;
select test.assert(jsonb_array_length(:'cold'::jsonb->'profile')=0 and test.ids(:'cold'::jsonb->'candidates') @> '{2610.00001,2610.00004,2401.00001}'
 and not test.ids(:'cold'::jsonb->'candidates') && '{2610.00005,2610.00011}','cold start: newest in the pool categories');
select test.assert(:'cold'::jsonb->>'seed'<>:'fy'::jsonb->>'seed','the daily sample differs by account');

-- Category chips from the pool: newest first, Not interested removed; others fall back to live RSS.
set role service_role;
select public.worker_feed_category('44000000-0000-0000-0000-00000000000a','cs.CV') as chip \gset
select test.assert(:'chip'::jsonb->>'serving'='true' and test.ids(:'chip'::jsonb->'results')='{2410.99999,2610.00001,2610.00008}'
 and (select r->>'source_id' from jsonb_array_elements(:'chip'::jsonb->'results') with ordinality x(r,n) order by n limit 1) in ('2610.00001','2410.99999'),
 'cs.CV chip without the dismissed paper');
select test.assert(public.worker_feed_category('44000000-0000-0000-0000-00000000000a','hep-th')->'results'='null'::jsonb,'a category outside the pool');
select test.reject($q$select public.worker_feed_category('44000000-0000-0000-0000-00000000000a','cs.LG; drop',25)$q$,'invalid_feed_category');
reset role;
update app_private.feed_sources set last_success_at=now()-interval '4 days';
set role service_role;
select test.assert(public.worker_feed_category('44000000-0000-0000-0000-00000000000a','cs.CV')->'results'='null'::jsonb,'a stale pool falls back to live RSS');
reset role;
update app_private.feed_sources set last_success_at=now();

-- At most feedback_rows rows per reader: the oldest go.
update app_private.feed_policy set feedback_rows=10;
set role authenticated;
select set_config('request.jwt.claim.sub','44000000-0000-0000-0000-00000000000b',false);
select public.v1_feed_feedback(format('2610.%s',20000+n),'not_interested') from generate_series(1,12) n;
reset role;
select test.assert((select count(*) from app_private.feed_feedback where account_id='44000000-0000-0000-0000-00000000000b')=10,'ten kept');
select test.assert(exists(select 1 from app_private.api_rate_rules where route='feed-feedback' and account_limit=120),'feedback is rate limited');

-- Status for operations.
set role service_role;
select test.assert((public.worker_feed_status()->'pool'->>'rows')::integer=37 and public.worker_feed_status()->'policy'->>'serving'='all'
 and jsonb_array_length(public.worker_feed_status()->'sources')=1,'status');
reset role;

-- Eligibility covers the whole library/feedback, independently of the recent ranking profile.
-- Three hundred newer items must not make the older paper or dismissal eligible again.
savepoint large_library;
update app_private.library_items set added_at=now()-interval '20 days',archived_at=now()
 where account_id='44000000-0000-0000-0000-00000000000a';
insert into app_private.library_items(account_id,document_id,approval_id,added_at)
 select '44000000-0000-0000-0000-00000000000a',p.doc,p.approval,now()
 from generate_series(1,300) n cross join lateral test.paper(format('2610.%s',30000+n),'Recent paper','[]','["cs.LG"]') p;
update app_private.feed_feedback set created_at=now()-interval '20 days'
 where account_id='44000000-0000-0000-0000-00000000000a';
insert into app_private.feed_feedback(account_id,source_id,kind)
 select '44000000-0000-0000-0000-00000000000a',format('2610.%s',40000+n),'more_like_this'
 from generate_series(1,300) n;
-- A failed import is no longer a ranking signal, but it still occupies a visible library row.
update app_private.import_requests set phase='failed',error_code='metadata_unavailable',retryable=true
 where account_id='44000000-0000-0000-0000-00000000000a' and source_id='2410.99999';
select public.worker_feed_candidates('44000000-0000-0000-0000-00000000000a') as large_fy \gset
select test.assert(jsonb_array_length(:'large_fy'::jsonb->'profile')=300
 and jsonb_array_length(:'large_fy'::jsonb->'feedback')=300,'ranking inputs remain bounded');
select test.assert(not test.ids(:'large_fy'::jsonb->'candidates') && '{2401.00001,2410.99999,2610.00007}',
 'old archived library paper, failed visible import and old dismissal stay excluded beyond profile caps');
rollback to large_library;

-- Closing an account forgets its Feed choices and stops serving it.
update app_private.accounts set closed_at=now() where id='44000000-0000-0000-0000-00000000000a';
select test.assert(not exists(select 1 from app_private.feed_feedback where account_id='44000000-0000-0000-0000-00000000000a'),'feedback deleted on closure');
select test.reject($q$select public.worker_feed_candidates('44000000-0000-0000-0000-00000000000a')$q$,'account_unavailable');
select test.assert((select count(*) from app_private.feed_feedback where account_id='44000000-0000-0000-0000-00000000000b')=10,'other readers keep theirs');
set role authenticated;
select set_config('request.jwt.claim.sub','44000000-0000-0000-0000-00000000000a',false);
select test.reject($q$select public.v1_feed_feedback('2610.00001','not_interested')$q$,'authentication_required');
reset role;
rollback;
