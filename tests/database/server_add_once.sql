-- Server adds without duplicates (review A5, migration 120; docs/architecture/HTML_FIRST_READER.md "Server adds without
-- duplicates"): v2_add_paper_once begins an import only when the reader does not already have the paper (a visible import
-- in accepted/resolving/acquiring/source_only, or a visible item naming the source), replays its own receipt, uses no
-- capacity for a paper that is present, and keeps accounts apart. Synthetic local SQL; nothing leaves the machine.
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

\set A '12000000-0000-4000-8000-00000000000a'
\set B '12000000-0000-4000-8000-00000000000b'
\set OP1 '12000000-0000-4000-8000-000000000001'
\set OP2 '12000000-0000-4000-8000-000000000002'
\set OP3 '12000000-0000-4000-8000-000000000003'
\set OP4 '12000000-0000-4000-8000-000000000004'
\set OP5 '12000000-0000-4000-8000-000000000005'
\set OP6 '12000000-0000-4000-8000-000000000006'
\set OP7 '12000000-0000-4000-8000-000000000007'
\set OP8 '12000000-0000-4000-8000-000000000008'
\set OP9 '12000000-0000-4000-8000-000000000009'
\set CLIENT '12000000-0000-4000-8000-0000000000c1'
insert into auth.users(id) values(:'A'),(:'B');

-- Grants: the reader's own token only.
select test.assert(has_function_privilege('authenticated','public.v2_add_paper_once(uuid,text,boolean)','execute'),'readers may add');
select test.assert(not has_function_privilege('anon','public.v2_add_paper_once(uuid,text,boolean)','execute'),'anonymous callers may not');
select test.assert(not has_function_privilege('service_role','public.v2_add_paper_once(uuid,text,boolean)','execute'),'the service role has no actor');
select test.assert(not has_function_privilege('authenticated','app_private.library_source_present(uuid,text)','execute'),'the check is private');

set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
-- A new paper: one import, one receipt, one change, exactly like v2_begin_import.
select public.v2_add_paper_once(:'OP1','2305.18290',false) as first \gset
select test.assert(:'first'::jsonb->'result'->>'status'='applied' and :'first'::jsonb->'result'->>'id'=:'OP1'
 and :'first'::jsonb->>'replayed'='false','a new paper is queued');
reset role;
select test.assert((select count(*) from app_private.import_requests where account_id=:'A' and source_id='2305.18290')=1,'one import');
select test.assert((select observed_cursor=created_seq-1 and requested_revision is null and desired_present and phase='accepted'
 from app_private.import_requests where account_id=:'A' and id=:'OP1'),'observed cursor is the whole library at the time');
select test.assert(app_private.library_import_entry(:'A',:'OP1')->>'source_id'='2305.18290','projected like any import');
select (select count(*) from app_private.library_commands where account_id=:'A') as receipts,
 (select last_seq from app_private.library_sync_state where account_id=:'A') as seq \gset

set role authenticated;
-- A retried request (the same derived operation id) replays its receipt; nothing new is written.
select test.assert(public.v2_add_paper_once(:'OP1','2305.18290',false)->>'replayed'='true','retry replays');
select test.assert(public.v2_add_paper_once(:'OP1','2305.18290',false)->'result'=:'first'::jsonb->'result','replay is the same result');
-- Adding it again under a new request: present, the existing import named, nothing written.
select public.v2_add_paper_once(:'OP2','2305.18290',false) as again \gset
select test.assert(:'again'::jsonb->'result'=jsonb_build_object('status','present','kind','import','id',:'OP1'),'an active import is present');
select test.assert(:'again'::jsonb->'entry'->>'id'=:'OP1','the current entry is returned');
-- The digest binds the operation to its paper: another paper under OP1 is a conflict, as is a client's own receipt id.
select test.reject(format('select public.v2_add_paper_once(%L,%L,false)',:'OP1','1706.03762'),'operation_id_conflict');
select public.v2_begin_import(:'CLIENT','1706.03762',0);
select test.reject(format('select public.v2_add_paper_once(%L,%L,false)',:'CLIENT','1706.03762'),'operation_id_conflict');
reset role;
select test.assert((select count(*) from app_private.import_requests where account_id=:'A' and source_id='2305.18290')=1,'still one import');
select test.assert((select count(*) from app_private.library_commands where account_id=:'A')=:'receipts'::bigint+1,'present writes no receipt (one is the client import)');

-- The HTML-first resting phase (source_only, migration 058) is present: the bug this fixes.
update app_private.import_requests set phase='source_only' where account_id=:'A' and id=:'OP1';
set role authenticated;
select test.assert(public.v2_add_paper_once(:'OP3','2305.18290',false)->'result'->>'status'='present','a finished source-only paper is present');
reset role;
-- A failed import is not present: Add after a failure starts a new attempt.
update app_private.import_requests set phase='failed',error_code='metadata_unavailable',retryable=true where account_id=:'A' and id=:'OP1';
set role authenticated;
select test.assert(public.v2_add_paper_once(:'OP3','2305.18290',false)->'result'->>'status'='applied','a failed import is not present');
-- Neither is a cancelled one (the reader removed it).
reset role;
update app_private.import_requests set phase='cancelled',desired_present=false,error_code=null,retryable=false where account_id=:'A' and source_id='2305.18290';
set role authenticated;
select test.assert(public.v2_add_paper_once(:'OP4','2305.18290',false)->'result'->>'status'='applied','a removed paper can be added again');
reset role;
select test.assert((select count(*) from app_private.import_requests where account_id=:'A' and source_id='2305.18290' and desired_present)=1,'one live import');

-- Another account's copy is not this reader's.
set role authenticated;
select set_config('request.jwt.claim.sub',:'B',false);
select test.assert(public.v2_add_paper_once(:'OP1','2305.18290',false)->'result'->>'status'='applied','presence is per account; operation ids are per account');
select set_config('request.jwt.claim.sub',:'A',false);
reset role;

-- A legacy library item (server copy era) naming the source is present; once removed it is not.
create or replace function test.sa_item(a uuid, src text) returns uuid language plpgsql as $$
declare pub uuid:=gen_random_uuid(); ver uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); meta uuid:=gen_random_uuid();
 appr uuid:=gen_random_uuid(); orig uuid:=gen_random_uuid(); md jsonb:=jsonb_build_object('title','Item fixture '||src); item uuid;
begin
 insert into app_private.publications(id,title) values(pub,'Item fixture '||src);
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
 insert into app_private.library_items(account_id,document_id,approval_id) values(a,doc,appr) returning id into item;
 return item;
end $$;
select test.sa_item(:'A','2401.00001') as item \gset
set role authenticated;
select public.v2_add_paper_once(:'OP5','2401.00001',false) as legacy \gset
select test.assert(:'legacy'::jsonb->'result'=jsonb_build_object('status','present','kind','item','id',:'item'),'a visible item naming the source is present');
select test.assert(:'legacy'::jsonb->'entry'->>'kind'='item','its entry');
reset role;
update app_private.library_items set removed_at=now() where id=:'item';
set role authenticated;
select test.assert(public.v2_add_paper_once(:'OP5','2401.00001',false)->'result'->>'status'='applied','a removed item is not present');

-- Web papers (openalex:W…, migration 019) by their normalized id.
select public.v2_add_paper_once(:'OP6','openalex:w2963403868',true) as web \gset
select test.assert(:'web'::jsonb->'result'->>'status'='applied','a web paper is queued');
select test.assert(public.v2_add_paper_once(:'OP7','openalex:W2963403868',true)->'result'->>'status'='present','the same web paper is present');
reset role;
select test.assert((select source_id from app_private.import_requests where account_id=:'A' and id=:'OP6')='openalex:W2963403868','normalized like v2_begin_web_import');
set role authenticated;

-- Validation before any lock or write.
select test.reject(format('select public.v2_add_paper_once(%L,%L,false)',:'OP8','openalex:W1'),'invalid_arxiv_id');
select test.reject(format('select public.v2_add_paper_once(%L,%L,true)',:'OP8','2305.18290'),'invalid_web_source_id');
select test.reject(format('select public.v2_add_paper_once(%L,%L,null)',:'OP8','2305.18290'),'invalid_import_request');
select test.reject(format('select public.v2_add_paper_once(null,%L,false)','2305.18290'),'invalid_import_request');
reset role;

-- Capacity: at the account's lifetime import limit a present paper still answers (it uses none); a new one is refused.
update app_private.library_policy set account_imports=(select count(*) from app_private.import_requests where account_id=:'A');
set role authenticated;
select test.assert(public.v2_add_paper_once(:'OP8','openalex:W2963403868',true)->'result'->>'status'='present','present needs no capacity');
select test.reject(format('select public.v2_add_paper_once(%L,%L,false)',:'OP9','2204.02311'),'library_account_import_limit');
reset role;

-- Another reader's token cannot see or replay A's receipts through this call.
set role anon;
select test.reject(format('select public.v2_add_paper_once(%L,%L,false)',:'OP9','2204.02311'),'permission denied');
reset role;
rollback;
