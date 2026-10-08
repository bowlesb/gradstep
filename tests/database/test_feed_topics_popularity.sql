-- Feed topics and popularity (migration 046): Hugging Face upvotes recorded only under the pool
-- refresh's claim with bounded per-day planning, For you inputs v2 with per-topic counts for the
-- reader's own topics and combinations, one topic served, pool details and category chips v2.
begin;
-- Sorts before test_invariants.sql, which defines the shared helpers: define them here (rolled back).
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
create function test.paper(p_source text,p_title text,p_categories jsonb) returns table(doc uuid,approval uuid) language plpgsql as $$
declare meta uuid; d uuid:=gen_random_uuid(); o uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); digest bytea:=decode(md5(p_source)||md5(p_source),'hex');
begin
 meta:=public.worker_record_arxiv_metadata(p_source,1,jsonb_build_object('title',p_title,'authors','["Ada Lovelace"]'::jsonb,'categories',p_categories));
 insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values(d,digest,'shared_catalog','{"fixture":true}',1000,2);
 insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
  values(o,'paper-assets','test/feed48/'||p_source||'.pdf',d,'verified',digest,1000,'application/pdf',now());
 perform public.worker_approve_arxiv_asset(a,meta,d,o,'https://creativecommons.org/licenses/by/4.0/',
  jsonb_build_object('source_id',p_source,'source_revision',1,'source_url','https://arxiv.org/abs/'||p_source||'v1',
   'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('a',64),'observed_at','2026-10-07T01:00:00Z'));
 return query select d,a;
end $$;
create function test.item(p_source text,p_title text,p_topics jsonb,p_days_ago integer,p_abstract text default 'An abstract.') returns jsonb language sql as $$
 select jsonb_build_object('source_id',p_source,'revision',1,'title',p_title,'authors','["Grace Hopper"]'::jsonb,'abstract',p_abstract,
  'categories','["cs.CL","cs.LG"]'::jsonb,'topics',p_topics,'announced_on',((now() at time zone 'UTC')::date-p_days_ago)::text,'announce_type','new')
$$;
create function test.ids(p jsonb) returns text[] language sql as $$
 select coalesce(array(select c->>'source_id' from jsonb_array_elements(p) c order by 1),'{}')
$$;
create function test.day(p_days_ago integer) returns text language sql as $$
 select to_char((now() at time zone 'UTC')::date-p_days_ago,'YYYY-MM-DD')
$$;
create function test.compounds() returns jsonb language sql as $$
 select '[{"name":"RL for reasoning","all":["Reasoning"],"any":["Reinforcement learning","Policy optimization"]},
   {"name":"Byte-level models","all":["Tokenization","Efficient inference"],"any":[]}]'::jsonb
$$;

insert into auth.users values('48000000-0000-0000-0000-00000000000a'),('48000000-0000-0000-0000-00000000000b');

-- Defaults, grants and the switch.
select test.assert((select popularity_enabled from app_private.feed_policy),'popularity follows the refresh switch by default');
set role authenticated;
select set_config('request.jwt.claim.sub','48000000-0000-0000-0000-00000000000a',false);
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a')$q$,'permission denied');
select test.reject($q$select public.worker_feed_signal_plan(gen_random_uuid())$q$,'permission denied');
select test.reject($q$select public.worker_feed_signals_record(gen_random_uuid(),current_date,'ok','[]')$q$,'permission denied');
select test.reject($q$select public.worker_feed_details('{2610.00001}')$q$,'permission denied');
select test.reject($q$select public.worker_feed_category_v2('48000000-0000-0000-0000-00000000000a','cs.CL')$q$,'permission denied');
select test.reject($q$select public.worker_set_feed_popularity(false)$q$,'permission denied');
select test.reject($q$select * from app_private.feed_signal_days$q$,'permission denied');
reset role;
set role service_role;
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a')$q$,'feed_unavailable');
select test.assert(public.worker_feed_category_v2('48000000-0000-0000-0000-00000000000a','cs.CL')->>'serving'='false','chips stay live while off');
select test.reject($q$select public.worker_set_feed_popularity(null)$q$,'invalid_feed_policy');

-- The pool, written under a refresh claim.
select public.worker_set_feed_policy('off',true);
select public.worker_feed_refresh_claim()->>'claim_id' as c1 \gset
select public.worker_feed_upsert(:'c1',jsonb_build_array(
 test.item('2610.10001','RL for math reasoning','["Reasoning","Policy optimization","Reinforcement learning"]',1),
 test.item('2610.10002','GRPO again','["Reasoning","Reinforcement learning"]',2),
 test.item('2610.10003','Chain of thought','["Reasoning"]',1),
 test.item('2610.10004','Sparse autoencoders','["Mechanistic interpretability"]',1,'We study circuit tracing in language models.'),
 test.item('2610.10005','Tokenizer-free models','["Tokenization"]',3),
 test.item('2610.10006','Byte tokens','["Tokenization","Efficient inference"]',2,repeat('Long abstract. ',133)||'xxxxx'),
 test.item('2610.10007','Trending video','["Video generation"]',1),
 test.item('2610.10008','Old reasoning','["Reasoning"]',20),
 test.item('2401.20001','Our reasoning paper','["Reasoning","Policy optimization"]',1),
 test.item('2610.10009','Circuits at scale','[]',1,'Circuit tracing for every head.'),
 test.item('2610.10010','Dismissed tokens','["Tokenization"]',1)),'feed-topics-v1') as written \gset
select test.assert((:'written'::jsonb->>'inserted')::integer=11,'pool written');
reset role;
select test.assert((select char_length(abstract)=2000 from app_private.feed_papers where source_id='2610.10006'),'a 2,000-character (bounded) abstract');
set role service_role;

-- Popularity plan: never-fetched days first, newest first, at most six.
select public.worker_feed_signal_plan(:'c1') as plan \gset
select test.assert(:'plan'::jsonb->>'source'='huggingface' and (:'plan'::jsonb->>'enabled')::boolean
 and :'plan'::jsonb->'days'=jsonb_build_array(test.day(0),test.day(1),test.day(2),test.day(3),test.day(4),test.day(5)),'first plan: six newest days');
select test.reject($q$select public.worker_feed_signal_plan(gen_random_uuid())$q$,'feed_claim_lost');

-- Recording: strict items, only pool papers updated, nothing for papers not listed.
select public.worker_feed_signals_record(:'c1',test.day(1)::date,'ok',
 '[{"source_id":"2610.10007","upvotes":120},{"source_id":"2610.10001","upvotes":7},{"source_id":"2609.99999","upvotes":3}]') as rec \gset
select test.assert((:'rec'::jsonb->>'matched')::integer=2 and (:'rec'::jsonb->>'items')::integer=3,'two pool papers matched; a paper outside the pool ignored');
reset role;
select test.assert((select upvotes=120 and upvotes_at is not null from app_private.feed_papers where source_id='2610.10007'),'upvotes observed');
select test.assert((select upvotes is null and upvotes_at is null from app_private.feed_papers where source_id='2610.10003'),'unlisted: unknown, not zero');
set role service_role;
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(1),'ok','[{"source_id":"2610.1000x","upvotes":1}]'),'invalid_feed_signals');
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(1),'ok','[{"source_id":"2610.10001","upvotes":1.5}]'),'invalid_feed_signals');
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(1),'ok','[{"source_id":"2610.10001","upvotes":-1}]'),'invalid_feed_signals');
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(1),'ok','[{"source_id":"2610.10001","upvotes":"5"}]'),'invalid_feed_signals');
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(1),'ok','[{"source_id":"2610.10001","upvotes":2000000}]'),'invalid_feed_signals');
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(1),'ok','[{"source_id":"2610.10001","upvotes":1,"title":"x"}]'),'invalid_feed_signals');
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(1),'ok','[{"source_id":"2610.10001"}]'),'invalid_feed_signals');
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(1),'ok','[{"upvotes":3}]'),'invalid_feed_signals');
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(1),'ok',
 '[{"source_id":"2610.10001","upvotes":1},{"source_id":"2610.10001","upvotes":2}]'),'invalid_feed_signals');
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(1),'failed','[{"source_id":"2610.10001","upvotes":1}]'),'invalid_feed_signals');
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(70),'ok','[]'),'invalid_feed_signals');
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(1),'skipped','[]'),'invalid_feed_signals');
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(1),'ok','{}'),'invalid_feed_signals');
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',gen_random_uuid(),test.day(1),'ok','[]'),'feed_claim_lost');

-- A failed or throttled day keeps earlier upvotes and waits 25 minutes; recent days refresh after
-- 110 minutes, older days after 23 hours.
select public.worker_feed_signals_record(:'c1',test.day(0)::date,'busy','[]');
select public.worker_feed_signals_record(:'c1',test.day(1)::date,'failed','[]');
reset role;
select test.assert((select fetched_at is not null and items=3 and status='failed' from app_private.feed_signal_days where day=test.day(1)::date),
 'a failure keeps the last fetch');
select test.assert((select upvotes=120 from app_private.feed_papers where source_id='2610.10007'),'and the pool keeps its upvotes');
set role service_role;
select public.worker_feed_signal_plan(:'c1') as plan2 \gset
select test.assert(not (:'plan2'::jsonb->'days' ? test.day(0)) and not (:'plan2'::jsonb->'days' ? test.day(1))
 and :'plan2'::jsonb->'days'->>0=test.day(2) and jsonb_array_length(:'plan2'::jsonb->'days')=6,'just tried days wait; never-fetched days next');
reset role;
update app_private.feed_signal_days set checked_at=now()-interval '30 minutes' where day=test.day(0)::date;
insert into app_private.feed_signal_days values('huggingface',test.day(2)::date,now()-interval '2 hours',now()-interval '2 hours','ok',10),
 ('huggingface',test.day(10)::date,now()-interval '2 hours',now()-interval '2 hours','ok',10);
update app_private.feed_signal_days set fetched_at=now()-interval '2 hours',checked_at=now()-interval '2 hours',status='ok' where day=test.day(1)::date;
-- Fetch every other day of the window recently, so only the due ones remain.
insert into app_private.feed_signal_days select 'huggingface',(now() at time zone 'UTC')::date-n,now(),now(),'ok',1
 from generate_series(3,14) n where n<>10 on conflict do nothing;
set role service_role;
select public.worker_feed_signal_plan(:'c1') as plan3 \gset
select test.assert(:'plan3'::jsonb->'days'=jsonb_build_array(test.day(0),test.day(1),test.day(2)),
 'due: the throttled day (never fetched), then recent days after 110 minutes; not an older day after 2 hours: '||(:'plan3'::jsonb->'days')::text);
select public.worker_set_feed_popularity(false);
select test.assert(public.worker_feed_signal_plan(:'c1')=jsonb_build_object('source','huggingface','enabled',false,'days','[]'::jsonb),'switched off: no days');
select public.worker_set_feed_popularity(true);
select public.worker_feed_refresh_finish(:'c1','updated',null,null,11);
select test.reject(format('select public.worker_feed_signals_record(%L,%L,%L,%L)',:'c1',test.day(1),'ok','[]'),'feed_claim_lost');
reset role;

-- Reader A: one library paper (catalog tags, an own phrase tag and an organizational tag).
select doc as own_doc,approval as own_approval from test.paper('2401.20001','Our reasoning paper','["cs.CL"]') \gset
set role authenticated;
select set_config('request.jwt.claim.sub','48000000-0000-0000-0000-00000000000a',false);
select public.v2_set_library_item(gen_random_uuid(),:'own_doc',true,0,:'own_approval');
reset role;
update app_private.library_items set catalog_tags='{Reasoning,"Policy optimization","Large language models"}',user_tags='{"circuit tracing","to read",tokenization}'
 where account_id='48000000-0000-0000-0000-00000000000a';
set role service_role;
select public.worker_set_feed_policy('all',true);
reset role;
set role authenticated;
select public.v1_feed_feedback('2610.10010','not_interested');
reset role;

-- For you v2: 043's candidates with upvotes and topics, no abstracts; per-topic counts over eligible papers.
set role service_role;
select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a',p_compounds=>test.compounds()) as fy \gset
reset role;
select test.assert(not test.ids(:'fy'::jsonb->'candidates') && '{2401.20001,2610.10008,2610.10010}',
 'library, out-of-window and Not interested papers are excluded');
select test.assert(test.ids(:'fy'::jsonb->'candidates') @> '{2610.10001,2610.10004,2610.10007,2610.10009}','candidates');
select test.assert(not exists(select 1 from jsonb_array_elements(:'fy'::jsonb->'candidates') c where c ? 'abstract'),'no abstracts in candidates');
select test.assert((select (c->>'upvotes')::integer=120 and c->'topics'='["Video generation"]'::jsonb
 from jsonb_array_elements(:'fy'::jsonb->'candidates') c where c->>'source_id'='2610.10007'),'upvotes and topics');
select test.assert((select c->'upvotes'='null'::jsonb from jsonb_array_elements(:'fy'::jsonb->'candidates') c where c->>'source_id'='2610.10003'),
 'unknown upvotes are null');
select test.assert((select c->'matched_tags'='["circuit tracing"]'::jsonb from jsonb_array_elements(:'fy'::jsonb->'candidates') c
 where c->>'source_id'='2610.10009'),'an own tag still matches as a phrase');
select test.assert(:'fy'::jsonb->'topics'->'tags'='{"Reasoning":3,"Policy optimization":1,"Tokenization":2}'::jsonb,
 'tag counts over eligible window papers: '||(:'fy'::jsonb->'topics'->'tags')::text);
select test.assert(:'fy'::jsonb->'topics'->'own'='{"circuit tracing":2,"tokenization":2}'::jsonb,'own phrase counts; organizational tags left out: '||(:'fy'::jsonb->'topics'->'own')::text);
select test.assert(:'fy'::jsonb->'topics'->'compounds'='{"RL for reasoning":2,"Byte-level models":1}'::jsonb,
 'combination counts: '||(:'fy'::jsonb->'topics'->'compounds')::text);
select test.assert(jsonb_array_length(:'fy'::jsonb->'profile')=1 and (:'fy'::jsonb->>'pool')::integer=10,'profile and pool');

set role service_role;
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a',p_compounds=>'[{"name":"A","all":["x","y","z","w","v"],"any":[]}]')$q$,'invalid_feed_topic');
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a',p_compounds=>'[{"name":"A","all":["x"],"any":[]},{"name":"a","all":["y"],"any":[]}]')$q$,'invalid_feed_topic');
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a',p_compounds=>'[{"name":"A","all":[1],"any":[]}]')$q$,'invalid_feed_topic');
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a',p_compounds=>'[{"name":"A","all":["x"]}]')$q$,'invalid_feed_topic');
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a',p_compounds=>'{}')$q$,'invalid_feed_topic');

-- One topic: a vocabulary tag, a combination, or one of the reader's own tags as a phrase.
select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a','{Tokenization}') as tok \gset
select test.assert(test.ids(:'tok'::jsonb->'candidates')='{2610.10005,2610.10006}' and :'tok'::jsonb->'topics'='null'::jsonb,
 'a tag: its eligible papers (Not interested removed)');
select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a','{Reasoning}','{"Reinforcement learning","Policy optimization"}') as rl \gset
select test.assert(test.ids(:'rl'::jsonb->'candidates')='{2610.10001,2610.10002}','a combination: all of one list and any of the other');
select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a',p_phrase=>'Circuit Tracing') as own \gset
select test.assert(test.ids(:'own'::jsonb->'candidates')='{2610.10004,2610.10009}'
 and not exists(select 1 from jsonb_array_elements(:'own'::jsonb->'candidates') c where c->'matched_tags'<>'["Circuit Tracing"]'::jsonb),
 'an own tag as a phrase (any case)');
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a',p_phrase=>'diffusion')$q$,'invalid_feed_topic');
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a',p_phrase=>'to read')$q$,'invalid_feed_topic');
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a','{Reasoning}',p_phrase=>'circuit tracing')$q$,'invalid_feed_topic');
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a',p_any=>'{Reasoning}')$q$,'invalid_feed_topic');
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a','{}')$q$,'invalid_feed_topic');
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a','{" Reasoning"}')$q$,'invalid_feed_topic');
-- Another reader cannot use reader A's own tag.
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000b',p_phrase=>'circuit tracing')$q$,'invalid_feed_topic');
select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000b',p_compounds=>test.compounds()) as cold \gset
select test.assert(jsonb_array_length(:'cold'::jsonb->'profile')=0 and :'cold'::jsonb->'topics'->'tags'='{}'::jsonb
 and test.ids(:'cold'::jsonb->'candidates') @> '{2610.10010,2401.20001}','cold start: no topics; others'' exclusions do not apply');

-- Details for papers about to be shown: complete only below the pool's bound.
select public.worker_feed_details('{2610.10006,2610.10001,2609.99999}') as det \gset
select test.assert(test.ids(:'det'::jsonb)='{2610.10001,2610.10006}','pool papers only');
select test.assert((select (d->>'abstract_complete')::boolean and (d->>'upvotes')::integer=7 and d->>'abstract'='An abstract.'
 from jsonb_array_elements(:'det'::jsonb) d where d->>'source_id'='2610.10001'),'a complete abstract with its upvotes');
select test.assert((select not (d->>'abstract_complete')::boolean and d->'upvotes'='null'::jsonb
 from jsonb_array_elements(:'det'::jsonb) d where d->>'source_id'='2610.10006'),'a bounded abstract is not complete');
select test.reject($q$select public.worker_feed_details(array(select format('2610.%s',20000+n) from generate_series(1,61) n))$q$,'invalid_feed_details');
select test.reject($q$select public.worker_feed_details('{2610.1000x}')$q$,'invalid_feed_details');
select test.reject($q$select public.worker_feed_details(null)$q$,'invalid_feed_details');

-- Category chips v2: topics, upvotes, stored abstracts; Not interested removed.
select public.worker_feed_category_v2('48000000-0000-0000-0000-00000000000a','cs.CL') as chip \gset
select test.assert(:'chip'::jsonb->>'serving'='true' and not ('2610.10010'=any(test.ids(:'chip'::jsonb->'results')))
 and '2401.20001'=any(test.ids(:'chip'::jsonb->'results')),'chip: library papers kept, dismissed removed');
select test.assert((select (r->>'upvotes')::integer=120 and r->'topics'='["Video generation"]'::jsonb and (r->>'abstract_complete')::boolean
 from jsonb_array_elements(:'chip'::jsonb->'results') r where r->>'source_id'='2610.10007'),'chip rows carry topics and upvotes');
select test.assert(public.worker_feed_category_v2('48000000-0000-0000-0000-00000000000a','hep-th')->'results'='null'::jsonb,'outside the pool');
select test.reject($q$select public.worker_feed_category_v2('48000000-0000-0000-0000-00000000000a','cs.CL;',25)$q$,'invalid_feed_category');

-- Status for operations.
select test.assert((public.worker_feed_status()->'pool'->>'with_upvotes')::integer=2
 and (public.worker_feed_status()->'popularity'->>'days')::integer>=14 and public.worker_feed_status()->'policy' ? 'popularity_enabled','status');
reset role;

-- A closed account is not served.
update app_private.accounts set closed_at=now() where id='48000000-0000-0000-0000-00000000000a';
set role service_role;
select test.reject($q$select public.worker_feed_candidates_v2('48000000-0000-0000-0000-00000000000a')$q$,'account_unavailable');
select test.reject($q$select public.worker_feed_category_v2('48000000-0000-0000-0000-00000000000a','cs.CL')$q$,'account_unavailable');
reset role;
rollback;
