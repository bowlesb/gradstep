-- Interest index server layer (migration 0152; docs/architecture/INTEREST_INDEX.md): pgvector, grants and RLS, the
-- pool/catalog sync (uploads and placeholders excluded, pool text wins), embedding claims and stores (model, norm,
-- stale text), shards, a map build and its publication (IDs, successors, the stability gate), the manifest and
-- artifacts, and the reader's library fingerprints (only their own papers; no oracle for anyone else's). Local only.
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
-- A unit vector along axis i (1-based), as pgvector text.
create or replace function test.unit(i integer) returns text language sql as $$
 select '['||string_agg(case when g=i then '1' else '0' end,',' order by g)||']' from generate_series(1,384) g
$$;
grant execute on all functions in schema test to anon,authenticated,service_role;

\set A '15200000-0000-4000-8000-00000000000a'
\set B '15200000-0000-4000-8000-00000000000b'
\set C1 '15200000-0000-4000-8001-000000000001'
\set C2 '15200000-0000-4000-8001-000000000002'
\set IMP '15200000-0000-4000-8002-000000000001'
\set BIMP '15200000-0000-4000-8002-00000000000b'
insert into auth.users(id) values(:'A'),(:'B');

-- ---------- extension, grants, RLS ----------
select test.assert((select n.nspname='extensions' from pg_extension e join pg_namespace n on n.oid=e.extnamespace where e.extname='vector'),'pgvector in extensions');
select test.reject($q$select '[1,2,3]'::extensions.halfvec(384)$q$,'expected 384 dimensions');
select test.assert(not has_function_privilege('authenticated','public.worker_interest_claim(uuid)','execute'),'readers cannot run the worker');
select test.assert(not has_function_privilege('anon','public.v1_interest_library_fingerprints(text[],text,integer)','execute'),'never anonymous');
select test.assert(has_function_privilege('authenticated','public.v1_interest_library_fingerprints(text[],text,integer)','execute'),'readers may ask for their own');
select test.assert(not has_function_privilege('authenticated','public.worker_interest_manifest(uuid)','execute'),'manifest is the function''s');
select test.assert(has_function_privilege('service_role','public.worker_interest_artifact(uuid,uuid)','execute'),'service serves artifacts');
select test.assert(not has_function_privilege('service_role','app_private.interest_kick()','execute'),'helpers are private');
select test.assert((select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='app_private' and c.relname like 'interest\_%' and c.relkind='r'),'RLS on every interest table');
select test.assert(not has_table_privilege('authenticated','app_private.interest_papers','select'),'no table reads');
select test.assert((select not enabled and serving='off' from app_private.interest_policy),'off by default');
select test.assert(public.worker_interest_claim(:'C1')->>'reason'='disabled','disabled policy claims nothing');
select test.assert((select window_seconds=3600 and account_limit=60 from app_private.api_rate_rules where route='interest-library'),'library rate rule');

-- ---------- fixtures: pool papers, catalog papers, libraries ----------
insert into app_private.feed_papers(source_id,revision,title,authors,author_keys,abstract,categories,announced_on,announce_type) values
 ('2610.00001',1,'Sparse attention   for long contexts',array['A One'],array['one a'],repeat('Sparse attention keeps the KV cache small. ',4),array['cs.LG'],current_date-1,'new'),
 ('2610.00002',1,'A title only paper',array['B Two'],array['two b'],'Short.',array['cs.CL'],current_date-2,'new'),
 ('2610.00003',1,'Shared with the catalog',array['C Three'],array['three c'],repeat('Pool text for a paper the catalog also holds. ',3),array['cs.AI'],current_date-3,'new');
create or replace function test.cat_item(a uuid, src text, md jsonb, in_library boolean) returns void language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid();
 appr uuid:=gen_random_uuid(); orig uuid:=gen_random_uuid();
begin
 insert into app_private.publications(id,title) values(pub,md->>'title');
 insert into app_private.publication_versions(id,publication_id,source,revision) values(ver,pub,'arxiv','1');
 insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
  values(doc,sha256(convert_to(src||'-document','UTF8')),'shared_catalog','{"license":"CC-BY-4.0"}',1000,2);
 insert into app_private.version_documents values(ver,doc);
 insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
  values(orig,'paper-assets','originals/'||encode(sha256(convert_to(src,'UTF8')),'hex')||'.pdf',doc,'verified',sha256(convert_to(src,'UTF8')),1000,'application/pdf',now());
 insert into app_private.catalog_metadata(id,version_id,source_id,source_revision,metadata,metadata_sha256)
  values(meta,ver,src,1,md,sha256(convert_to(md::text,'UTF8')));
 insert into app_private.catalog_asset_approvals(id,version_id,document_id,metadata_id,original_object_id,license_uri,policy_version,evidence)
  values(appr,ver,doc,meta,orig,'https://creativecommons.org/licenses/by/4.0/','arxiv-reuse-v1','{}');
 if in_library then insert into app_private.library_items(account_id,document_id,approval_id) values(a,doc,appr); end if;
end $$;
-- A's library: a catalog paper (1706.03762) and the pool/catalog paper 2610.00003. B's library: 2301.00001.
-- 1810.04805 is in the catalog (someone's) but in nobody's library here; 2302.00002 has too short an abstract.
select test.cat_item(:'A','1706.03762',jsonb_build_object('title','Attention Is All You Need','abstract',repeat('We propose the Transformer. ',5),'categories',jsonb_build_array('cs.CL')),true);
select test.cat_item(:'A','2610.00003',jsonb_build_object('title','Shared with the catalog','abstract',repeat('Catalog text differs from the pool. ',3),'categories','[]'::jsonb),true);
select test.cat_item(:'B','2301.00001',jsonb_build_object('title','B''s private interest','abstract',repeat('Something only B reads about. ',4),'categories','[]'::jsonb),true);
select test.cat_item(:'B','1810.04805',jsonb_build_object('title','BERT','abstract',repeat('Bidirectional encoders. ',4),'categories','[]'::jsonb),false);
select test.cat_item(:'B','2302.00002',jsonb_build_object('title','Too short','abstract','Tiny.','categories','[]'::jsonb),false);
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v2_add_paper_once(:'IMP','2305.18290',false);
select set_config('request.jwt.claim.sub',:'B',false);
select public.v2_add_paper_once(:'BIMP','2404.00009',false);
reset role;

-- ---------- claim and sync ----------
select public.worker_interest_set_policy(true,'staff');
select test.assert((public.worker_interest_claim(:'C1'))->>'claimed'='true','claimed');
select test.assert(public.worker_interest_claim(:'C2')->>'reason'='busy','one run at a time');
select public.worker_interest_sync(:'C1') as sync \gset
select test.assert((:'sync'::jsonb->>'pool')::int=3 and (:'sync'::jsonb->>'catalog')::int=3,'pool 3, catalog 3 (short abstract excluded): '||:'sync');
select test.assert((select title_only from app_private.interest_papers where source_id='2610.00002'),'short abstract is title-only');
select test.assert((select abstract like 'Pool text%' and pool_announced_on is not null and in_catalog from app_private.interest_papers where source_id='2610.00003'),'pool text wins, catalog flagged');
select test.assert(not exists(select 1 from app_private.interest_papers where source_id in ('2302.00002') or source_id like 'upload:%'),'no short or upload rows');
select test.assert((select text_sha256=sha256(convert_to('Sparse attention for long contexts. '||btrim(repeat('Sparse attention keeps the KV cache small. ',4)),'UTF8'))
 from app_private.interest_papers where source_id='2610.00001'),'text recipe: whitespace collapsed, trimmed');
select test.assert((public.worker_interest_sync(:'C1')->>'pool')::int=0,'second sync is a no-op');
select test.reject(format('select public.worker_interest_sync(%L)',:'C2'),'interest_claim_lost');

-- ---------- embedding ----------
select public.worker_interest_embed_claim(:'C1',10) as batch \gset
select test.assert(jsonb_array_length(:'batch'::jsonb)=6,'six pending');
select test.assert((select attempts=1 and next_attempt_at>now() from app_private.interest_papers where source_id='2610.00001'),'claimed rows wait');
create or replace function test.row(src text,axis integer,model text default 'gte-small@17e1f34/onnx-fp32@5927d17/mean-l2/v1') returns jsonb language sql as $$
 select jsonb_build_object('source_id',src,'text_sha256',(select encode(text_sha256,'hex') from app_private.interest_papers where source_id=src),
  'model_version',model,'fingerprint',test.unit(axis),'q8',encode(decode(repeat(lpad(to_hex(axis),2,'0'),388),'hex'),'base64'))
$$;
select test.reject(format('select public.worker_interest_embed_store(%L,%L)',:'C1',jsonb_build_array(test.row('2610.00001',1,'other-model'))),'interest_model_mismatch');
select test.reject(format('select public.worker_interest_embed_store(%L,%L)',:'C1',
 jsonb_build_array(test.row('2610.00001',1)||jsonb_build_object('fingerprint',replace(test.unit(1),'[1,','[2,')))),'interest_fingerprint_norm');
select test.assert(((public.worker_interest_embed_store(:'C1',jsonb_build_array(
 test.row('2610.00001',1),test.row('2610.00002',2),test.row('2610.00003',3),test.row('1706.03762',4),test.row('2301.00001',5),
 test.row('1810.04805',6)||jsonb_build_object('text_sha256',repeat('00',32)))))->>'stored')::int=5,'five stored, a stale text skipped');
select test.assert((select count(*)=5 and count(distinct fp_seq)=5 from app_private.interest_papers where state='embedded'),'sequenced');
-- A changed abstract makes the paper pending again, with its fingerprint dropped.
update app_private.feed_papers set abstract=abstract||' Revised.' where source_id='2610.00001';
select public.worker_interest_sync(:'C1');
select test.assert((select state='pending' and fingerprint is null and attempts=0 from app_private.interest_papers where source_id='2610.00001'),'revised text re-pends');
update app_private.interest_papers set next_attempt_at=now() where state='pending';
select public.worker_interest_embed_store(:'C1',jsonb_build_array(test.row('2610.00001',1),test.row('1810.04805',6)));
select public.worker_interest_embed_fail(:'C1',array['nothing'],'x');

-- ---------- shards ----------
select public.worker_interest_shard_due(:'C1',100) as due \gset
select test.assert((:'due'::jsonb->>'due')::boolean and jsonb_array_length(:'due'::jsonb->'rows')=3,'three pool papers, no catalog-only paper: '||:'due');
select test.assert(not (:'due'::jsonb->'rows')::text like '%1706.03762%','catalog papers never enter a shard');
select test.reject(format('select public.worker_interest_shard_publish(%L,%L)',:'C1',jsonb_build_object('content','YWJj','sha256',repeat('0',64),
 'fp_seq_from',1,'fp_seq_to',9,'oldest_on',current_date,'newest_on',current_date,'papers',3)),'interest_artifact_digest');
select public.worker_interest_shard_publish(:'C1',jsonb_build_object('content','YWJj','sha256',encode(sha256('abc'),'hex'),
 'fp_seq_from',1,'fp_seq_to',(select max(fp_seq) from app_private.interest_papers),'oldest_on',current_date-3,'newest_on',current_date-1,'papers',3)) as shard \gset
select test.reject(format('select public.worker_interest_shard_publish(%L,%L)',:'C1',jsonb_build_object('content','YWJk','sha256',encode(sha256('abd'),'hex'),
 'fp_seq_from',2,'fp_seq_to',99,'oldest_on',current_date,'newest_on',current_date,'papers',1)),'interest_shard_overlap');

-- ---------- a map build ----------
select test.assert(jsonb_array_length(public.worker_interest_corpus_page(:'C1',null,10))=6,'every embedded paper in the corpus page');
select test.assert((select bool_and((x->>'in_map')::boolean = (x->>'source_id' in ('2610.00001','2610.00003'))) from jsonb_array_elements(public.worker_interest_corpus_page(:'C1',null,10)) x),'in_map: pool papers with an abstract');
select test.assert(length(public.worker_interest_corpus_page(:'C1',null,1)->0->>'fp')=1032,'fingerprints travel as halfvec_send');
select public.worker_interest_node_ids(:'C1',3) as ids \gset
select public.worker_interest_build_begin(:'C1','cold',2,'{}','{"levels":{"3":{"kept_share":null}}}') as v1 \gset
select public.worker_interest_build_nodes(:'C1',:v1,jsonb_build_array(
 jsonb_build_object('id',(:'ids'::bigint[])[1],'parent',null,'level',1,'centroid',test.unit(1),'size',2,'terms','["attention"]'::jsonb,'central_source_ids','["2610.00001"]'::jsonb,'central_titles','["Sparse attention"]'::jsonb),
 jsonb_build_object('id',(:'ids'::bigint[])[2],'parent',(:'ids'::bigint[])[1],'level',2,'centroid',test.unit(1),'size',2,'terms','[]'::jsonb,'central_source_ids','[]'::jsonb,'central_titles','[]'::jsonb),
 jsonb_build_object('id',(:'ids'::bigint[])[3],'parent',(:'ids'::bigint[])[2],'level',3,'centroid',test.unit(1),'size',2,'terms','[]'::jsonb,'central_source_ids','[]'::jsonb,'central_titles','[]'::jsonb)));
select public.worker_interest_build_rows(:'C1',:v1,(select jsonb_agg(jsonb_build_object('source_id',source_id,'leaf_id',(:'ids'::bigint[])[3],'terms','["kv cache"]'::jsonb))
 from app_private.interest_papers where state='embedded'));
select test.assert((public.worker_interest_build_publish(:'C1',:v1,'[]',jsonb_build_object('content','bWFw','sha256',encode(sha256('map'),'hex')),
 jsonb_build_object('content','dGVybXM=','sha256',encode(sha256('terms'),'hex'))))->>'published'='true','published');
select test.assert((select count(*)=3 and bool_and(born_version=:v1) from app_private.interest_nodes),'three nodes born');
select test.assert((select bool_and(leaf_id=(:'ids'::bigint[])[3] and leaf_map_version=:v1 and terms='{"kv cache"}') from app_private.interest_papers where state='embedded'),'leaves and terms applied');
select test.assert(not exists(select 1 from app_private.interest_build_rows),'staging cleared');
-- A second build that keeps almost nothing is blocked by the stability gate; the first stays published.
select public.worker_interest_build_begin(:'C1','warm',2,'{}','{"levels":{"3":{"kept_share":0.3}}}') as v2 \gset
select test.assert(public.worker_interest_build_publish(:'C1',:v2,'[]',jsonb_build_object('content','bWFw','sha256',encode(sha256('map'),'hex')),
 jsonb_build_object('content','dGVybXM=','sha256',encode(sha256('terms'),'hex')))->>'reason'='stability_gate','blocked');
select test.assert((select state from app_private.interest_map_versions where version=:v1)='published','v1 still serves');
select test.assert(app_private.interest_health()->'attention' @> '[{"kind":"interest_stability_blocked"}]','health names the blocked build');
select test.assert(app_private.admin_health_extra() ? 'interest_index' and app_private.admin_health_extra() ? 'recommendations','admin health carries the block');
select public.worker_interest_release(:'C1','finished','{"embedded":7}',null);
select test.assert((select claim_id is null from app_private.interest_state),'released');

-- ---------- delivery ----------
select test.reject(format('select public.worker_interest_manifest(%L)',:'A'),'interest_unavailable');
insert into app_private.app_roles(account_id,role) select id,'support' from app_private.accounts where id in (:'A',:'B');
select public.worker_interest_manifest(:'A') as manifest \gset
select test.assert((:'manifest'::jsonb#>>'{map,version}')::int=:v1 and jsonb_array_length(:'manifest'::jsonb->'shards')=1
 and :'manifest'::jsonb#>>'{model,version}' like 'gte-small@%','manifest: map, terms, one shard');
select test.assert(public.worker_interest_artifact(:'A',:'shard')->>'content'='YWJj','artifact bytes');
select test.reject(format('select public.worker_interest_artifact(%L,%L)',:'A',gen_random_uuid()),'interest_artifact_unavailable');

-- The reader's own library only: A has 1706.03762 and 2610.00003 (items) and 2305.18290 (an import, not yet embedded).
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select public.v1_interest_library_fingerprints() as lib \gset
select test.assert((select array_agg(x->>'source_id' order by x->>'source_id') from jsonb_array_elements(:'lib'::jsonb->'items') x)
 ='{1706.03762,2305.18290,2610.00003}','A sees exactly A''s papers: '||:'lib');
select test.assert((select (x->>'pending')::boolean from jsonb_array_elements(:'lib'::jsonb->'items') x where x->>'source_id'='2305.18290'),'the import is pending');
select test.assert((select length(x->>'q8')=520 and (x->>'leaf_id')::bigint>0 from jsonb_array_elements(:'lib'::jsonb->'items') x where x->>'source_id'='1706.03762'),'q8 and leaf');
-- Asking for B's paper or a catalog paper in nobody's library returns nothing: no oracle.
select test.assert(jsonb_array_length(public.v1_interest_library_fingerprints(array['2301.00001','1810.04805','2610.00001'])->'items')=0,'no oracle');
select test.assert(public.v1_interest_library_fingerprints(null,null,1)->>'next'='1706.03762','paging');
select test.reject($q$select public.v1_interest_library_fingerprints(null,null,501)$q$,'invalid_interest_request');
select test.reject($q$select * from app_private.interest_papers$q$,'permission denied');
select set_config('request.jwt.claim.sub',:'B',false);
select test.assert((select array_agg(x->>'source_id' order by x->>'source_id') from jsonb_array_elements(public.v1_interest_library_fingerprints()->'items') x)
 ='{2301.00001,2404.00009}','B sees only B''s');
reset role;
set role anon;
select test.reject($q$select public.v1_interest_library_fingerprints()$q$,'permission denied');
reset role;
-- Serving off: nothing for anyone.
select public.worker_interest_set_policy(null,'off');
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject($q$select public.v1_interest_library_fingerprints()$q$,'interest_unavailable');
reset role;

-- ---------- retention and the kick ----------
update app_private.feed_papers set announced_on=current_date-400 where source_id='2610.00002';
select public.worker_interest_claim(:'C2');
select public.worker_interest_sync(:'C2');
select test.assert(not exists(select 1 from app_private.interest_papers where source_id='2610.00002'),'pool-only rows leave after corpus_days');
select test.assert(exists(select 1 from app_private.interest_papers where source_id='1706.03762'),'catalog rows stay');
select test.assert(not app_private.interest_kick(),'no kick while a run holds the lease');
select public.worker_interest_release(:'C2','finished','{}',null);
rollback;
