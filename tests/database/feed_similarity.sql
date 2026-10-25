-- For you by similarity to the library (migration 0155; docs/architecture/PERSONALIZED_FEED.md "Similarity to the
-- library"): candidates carry the cosine similarity to the nearest settled library paper and that paper; a "similar"
-- tier brings in close papers no other tier would, found through the map's mid-level nodes; only when the interest
-- index serves the reader (interest_policy.serving: staff → accounts with a role, all, off); author_counts for every
-- reader. Synthetic local SQL with hand-made unit vectors; nothing leaves the machine.
begin;
create schema if not exists test;
grant usage on schema test to anon,authenticated,service_role;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
grant execute on all functions in schema test to anon,authenticated,service_role;

\set R  '15500000-0000-4000-8000-00000000000a'
\set O  '15500000-0000-4000-8000-00000000000b'
\set I1 '15500000-0000-4000-8001-000000000001'
\set I2 '15500000-0000-4000-8001-000000000002'
\set I3 '15500000-0000-4000-8001-000000000003'
\set J1 '15500000-0000-4000-8002-000000000001'
insert into auth.users(id) values(:'R'),(:'O');
select public.worker_set_feed_policy('all',false);
-- The reader R has a role (staff); O has none.
insert into app_private.app_roles(account_id,role) values(:'R','tester');

-- A unit vector a·e_i + b·e_j (gte-small's 384 dimensions); the caller keeps a² + b² = 1.
create or replace function test.v(i integer,a float8,j integer default 384,b float8 default 0) returns extensions.halfvec
language sql immutable as $$
 select ('['||(select string_agg((case when k=i then a else 0 end+case when k=j then b else 0 end)::text,',' order by k)
  from generate_series(1,384) k)||']')::extensions.halfvec(384)
$$;
create or replace function test.meta(src text,md jsonb) returns uuid language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid();
begin
 insert into app_private.publications(id,title) values(pub,md->>'title');
 insert into app_private.publication_versions(id,publication_id,source,revision) values(ver,pub,'arxiv','1');
 insert into app_private.catalog_metadata(id,version_id,source_id,source_revision,metadata,metadata_sha256)
  values(meta,ver,src,1,md,sha256(convert_to(md::text,'UTF8')));
 return meta;
end $$;
create or replace function test.settle(a uuid,i uuid,meta uuid) returns void language plpgsql as $$
declare s bigint;
begin
 s:=app_private.library_next_seq(a);
 update app_private.import_requests set phase='source_only',metadata_id=meta,source_tags='{}',source_tags_customized=false,source_archived=false,state_seq=s
 where account_id=a and id=i;
 perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,i)));
end $$;
-- An embedded interest-index row in leaf `leaf` of map version `mv` (pool papers carry today's announcement).
create or replace function test.fp(src text,title text,f extensions.halfvec,leaf bigint,mv integer,pool boolean) returns void language sql as $$
 insert into app_private.interest_papers(source_id,title,abstract,pool_announced_on,in_catalog,title_only,text_sha256,state,model_version,
  fingerprint,fp_q8,fp_seq,embedded_at,leaf_id,leaf_map_version)
 values(src,title,'An abstract long enough to be embedded as a paper.',case when pool then (now() at time zone 'UTC')::date end,not pool,false,
  sha256(convert_to(src,'UTF8')),'embedded',(select model_version from app_private.interest_policy),f,decode(repeat('00',388),'hex'),
  nextval('app_private.interest_fp_seq'),now(),leaf,mv)
$$;

-- R's library: two settled HTML-first papers (L1 ≈ e1, L2 ≈ e20) and one import still in flight (≈ e10). O has L1.
set role authenticated;
select set_config('request.jwt.claim.sub',:'R',false);
select public.v2_add_paper_once(:'I1','2401.11111',false);
select public.v2_add_paper_once(:'I2','2401.22222',false);
select public.v2_add_paper_once(:'I3','2401.33333',false);
select set_config('request.jwt.claim.sub',:'O',false);
select public.v2_add_paper_once(:'J1','2401.11111',false);
reset role;
select test.meta('2401.11111',jsonb_build_object('title','Direct Preference Optimization','authors',jsonb_build_array('Ada One','Bo Two'),
 'categories',jsonb_build_array('cs.LG'))) as m1 \gset
select test.meta('2401.22222',jsonb_build_object('title','Diffusion Policies for Robots','authors',jsonb_build_array('Cy Three'),
 'categories',jsonb_build_array('cs.RO'))) as m2 \gset
select test.settle(:'R',:'I1',:'m1');
select test.settle(:'R',:'I2',:'m2');
select test.settle(:'O',:'J1',:'m1');
update app_private.import_requests set metadata_id=test.meta('2401.33333',jsonb_build_object('title','Still importing','authors',jsonb_build_array('Di Four'),
 'categories',jsonb_build_array('cs.LG'))) where id=:'I3';

-- The published map: mid-level nodes 101 (e1), 102 (e20), 103 (e10), 104 (e30) and 105, which faces away from both
-- library papers, so neither picks it among its 3 nearest; one leaf under each.
insert into app_private.interest_map_versions(kind,state,model_version,corpus_papers,published_at)
 values('cold','published',(select model_version from app_private.interest_policy),100,now()) returning version as mv \gset
insert into app_private.interest_node_versions(version,node_id,parent_id,level,centroid,size) values
 (:mv,1,null,1,test.v(1,1),100),
 (:mv,101,1,2,test.v(1,1),20),(:mv,102,1,2,test.v(20,1),20),(:mv,103,1,2,test.v(10,1),20),(:mv,104,1,2,test.v(30,1),20),
 (:mv,105,1,2,test.v(1,-sqrt(0.5),20,-sqrt(0.5)),20),
 (:mv,201,101,3,test.v(1,1),10),(:mv,202,102,3,test.v(20,1),10),(:mv,203,103,3,test.v(10,1),10),(:mv,204,104,3,test.v(30,1),10),
 (:mv,205,105,3,test.v(1,-sqrt(0.5),20,-sqrt(0.5)),10);

-- The pool. q-bio.NC is outside the reader's categories and the pool's, so only the similar tier can offer those papers.
insert into app_private.feed_papers(source_id,revision,title,authors,author_keys,abstract,categories,topics,announced_on,announce_type)
select s,1,t,au,array(select lower(x) from unnest(au) x),'An abstract.',c,'{}',(now() at time zone 'UTC')::date,'new'
from (values
 ('2610.80001','Close to DPO','{"Zed Zero"}'::text[],'{q-bio.NC}'::text[]),
 ('2610.80002','Somewhat close to diffusion policies','{"Yan Yi"}','{q-bio.NC}'),
 ('2610.80003','Not close enough','{"Xu Er"}','{q-bio.NC}'),
 ('2610.80004','Close, in a node no library paper picks','{"Wu San"}','{q-bio.NC}'),
 ('2610.80005','Close only to the import in flight','{"Vi Si"}','{q-bio.NC}'),
 ('2610.80006','Not embedded yet','{"Uma Wu"}','{cs.LG}'),
 ('2610.80007','By a library author, unrelated','{"Ada One"}','{cs.LG}'),
 ('2610.80008','Also by a library author','{"Ada One","Bo Two"}','{cs.LG}'),
 ('2401.11111','Direct Preference Optimization','{"Ada One","Bo Two"}','{cs.LG}')) p(s,t,au,c);
select test.fp('2401.11111','Direct Preference Optimization',test.v(1,1),201,:mv,true);
select test.fp('2401.22222','Diffusion Policies for Robots',test.v(20,1),202,:mv,false);
select test.fp('2401.33333','Still importing',test.v(10,1),203,:mv,false);
select test.fp('2610.80001','Close to DPO',test.v(1,0.95,5,sqrt(1-0.95^2)),201,:mv,true);
select test.fp('2610.80002','Somewhat close to diffusion policies',test.v(20,0.88,6,sqrt(1-0.88^2)),202,:mv,true);
select test.fp('2610.80003','Not close enough',test.v(20,0.80,7,0.6),202,:mv,true);
select test.fp('2610.80004','Close, in a node no library paper picks',test.v(1,0.90,8,sqrt(1-0.9^2)),205,:mv,true);
select test.fp('2610.80005','Close only to the import in flight',test.v(10,0.97,9,sqrt(1-0.97^2)),203,:mv,true);
select test.fp('2610.80007','By a library author, unrelated',test.v(30,1),204,:mv,true);
select test.fp('2610.80008','Also by a library author',test.v(1,0.6,20,0.8),201,:mv,true);

-- ---------- staff: similarity served ----------
update app_private.interest_policy set serving='staff';
set role service_role;
select public.worker_feed_candidates_v2(:'R') as v \gset
reset role;
create temp table fy as select :'v'::jsonb v;
create temp table cand as select c->>'source_id' source_id,c from fy,jsonb_array_elements(v->'candidates') c;
select test.assert((select v->'similarity'=('{"served":true,"library":2,"map_version":'||:mv||'}')::jsonb from fy),
 'served with two library fingerprints (not the import in flight): '||(select v->>'similarity' from fy));
select test.assert((select jsonb_array_length(v->'profile')=3 from fy),'the profile is unchanged (two settled, one in flight)');
select test.assert((select abs((c->>'similarity')::float8-0.95)<0.002 and c->'similar_to'='{"source_id":"2401.11111","title":"Direct Preference Optimization"}'
 from cand where source_id='2610.80001'),'a close paper only the similar tier offers, with its nearest library paper');
select test.assert((select abs((c->>'similarity')::float8-0.88)<0.002 and c->'similar_to'->>'source_id'='2401.22222'
 from cand where source_id='2610.80002'),'0.88: offered (the tier starts at 0.86), nearest to the second paper');
select test.assert(not exists(select 1 from cand where source_id='2610.80003'),'0.80 is not close enough for the similar tier');
select test.assert(not exists(select 1 from cand where source_id='2610.80004'),'bounded: a node no library paper picks is never scanned');
select test.assert(not exists(select 1 from cand where source_id='2610.80005'),'an import in flight is not a library fingerprint');
select test.assert((select c->'similarity'='null'::jsonb and c->'similar_to'='null'::jsonb from cand where source_id='2610.80006'),
 'not yet embedded: offered by another tier, similarity null');
select test.assert((select abs((c->>'similarity')::float8)<0.002 from cand where source_id='2610.80007'),'every candidate is scored exactly (0 here)');
select test.assert((select abs((c->>'similarity')::float8-0.8)<0.002 and c->'similar_to'->>'source_id'='2401.22222' from cand where source_id='2610.80008'),
 'the nearest of all library papers: 0.8 to the second beats 0.6 to the first');
select test.assert(not exists(select 1 from cand where source_id='2401.11111'),'library papers are never offered');
select test.assert((select v->'author_counts'='{"ada one":3,"bo two":2}'::jsonb from fy),
 'author counts: window papers per profile author key (keys on none are absent): '||(select v->>'author_counts' from fy));

-- A topic: the same fields.
update app_private.feed_papers set topics='{"Machine learning"}' where source_id='2610.80008';
set role service_role;
select test.assert((select abs((x->>'similarity')::float8-0.8)<0.002 from jsonb_array_elements(public.worker_feed_candidates_v2(:'R',array['Machine learning'])->'candidates') x
 where x->>'source_id'='2610.80008'),'topic candidates carry similarity');

-- ---------- not served: no role under staff; off ----------
select public.worker_feed_candidates_v2(:'O') as o \gset
reset role;
select test.assert((:'o'::jsonb->'similarity')='{"served":false,"library":0,"map_version":null}','no role: not served');
select test.assert(not exists(select 1 from jsonb_array_elements(:'o'::jsonb->'candidates') x where x->'similarity'<>'null'::jsonb),
 'no role: every similarity is null');
select test.assert(not exists(select 1 from jsonb_array_elements(:'o'::jsonb->'candidates') x where x->>'source_id' like '2610.8000_' and x->'categories'?'q-bio.NC'),
 'no role: no similar tier');
update app_private.interest_policy set serving='all';
set role service_role;
select test.assert((public.worker_feed_candidates_v2(:'O')->'similarity'->>'served')::boolean,'all: everyone');
reset role;
update app_private.interest_policy set serving='off';
set role service_role;
select test.assert(not (public.worker_feed_candidates_v2(:'R')->'similarity'->>'served')::boolean,'off: nobody, staff included');
reset role;

-- No published map: exact similarity still, but no similar tier.
update app_private.interest_policy set serving='staff';
update app_private.interest_map_versions set state='superseded' where version=:mv;
set role service_role;
select public.worker_feed_candidates_v2(:'R') as nomap \gset
reset role;
select test.assert(not exists(select 1 from jsonb_array_elements(:'nomap'::jsonb->'candidates') x where x->>'source_id'='2610.80001'),
 'no map: no similar tier');
select test.assert((select abs((x->>'similarity')::float8-0.8)<0.002 from jsonb_array_elements(:'nomap'::jsonb->'candidates') x
 where x->>'source_id'='2610.80008'),'no map: candidates are still scored');

select test.assert(has_function_privilege('service_role','public.worker_feed_candidates_v2(uuid,text[],text[],text,jsonb)','execute')
 and not has_function_privilege('authenticated','public.worker_feed_candidates_v2(uuid,text[],text[],text,jsonb)','execute'),'candidates: service only');
rollback;
