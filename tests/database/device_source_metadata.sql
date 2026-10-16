-- Device-supplied source metadata (migration 071, docs/architecture/ARXIV_DEVICE_ONLY.md §5.4): refused while the flag
-- is off; account-scoped; validated (hostile payloads refused); never written to the shared catalog by a device;
-- promoted only by a DataCite match through the worker or by the owner with MFA and a reason; rate-limited; the reader
-- capability follows the flag. Synthetic local SQL.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin begin execute statement; exception when others then
 if position(expected in sqlerrm)=0 then raise exception 'Unexpected rejection: % (wanted %)',sqlerrm,expected; end if; rejected:=true; end;
 if not rejected then raise exception 'Expected rejection: %',expected; end if; end $$;
grant usage on schema test to anon,authenticated,service_role;
grant execute on all functions in schema test to anon,authenticated,service_role;

\set A '71000000-0000-0000-0000-00000000000a'
\set B '71000000-0000-0000-0000-00000000000b'
\set O '71000000-0000-0000-0000-00000000000f'
\set IA '71000000-0000-0000-0000-0000000000a1'
\set IB '71000000-0000-0000-0000-0000000000b1'
insert into auth.users(id,email) values(:'A','a@gradstep.test.org'),(:'B','b@gradstep.test.org'),(:'O','owner@gradstep.test.org');
insert into app_private.app_roles(account_id,role) values(:'O','owner');
insert into app_private.import_requests(account_id,id,request_sha256,source_id,requested_revision,observed_cursor,created_seq,state_seq,intent_revision,desired_present,phase,retryable)
values(:'A',:'IA',sha256('a'),'2305.18290',3,0,1,1,1,true,'source_only',false),(:'B',:'IB',sha256('b'),'2305.18290',3,0,1,1,1,true,'source_only',false);

create temp table good as select jsonb_build_object('format','arxiv-source-metadata-v1','source_id','2305.18290','revision',3,'origin','arxiv_html',
 'title','Direct Preference Optimization: Your Language Model is Secretly a Reward Model','authors',jsonb_build_array('Rafael Rafailov','Archit Sharma'),
 'abstract','While large-scale unsupervised language models learn broad world knowledge.','categories',jsonb_build_array('cs.LG'),
 'license_uri','https://creativecommons.org/licenses/by/4.0/','version_date','2024-07-29','html_available',true,'observed_at','2026-10-15T10:00:00Z') m;
grant select on good to authenticated;

select test.assert(app_private.valid_source_metadata((select m from good),'2305.18290',3),'the good record is valid');
-- Hostile and malformed payloads.
select test.assert(not app_private.valid_source_metadata((select m from good)||'{"extra":1}','2305.18290',3),'unknown key');
select test.assert(not app_private.valid_source_metadata((select m from good)-'abstract','2305.18290',3),'missing key');
select test.assert(not app_private.valid_source_metadata((select m from good),'2305.18291',3),'another paper');
select test.assert(not app_private.valid_source_metadata((select m from good),'2305.18290',2),'another revision');
select test.assert(not app_private.valid_source_metadata((select m from good)||'{"revision":"3"}','2305.18290',3),'revision as text');
select test.assert(not app_private.valid_source_metadata((select m from good)||'{"origin":"server"}','2305.18290',3),'unknown origin');
select test.assert(not app_private.valid_source_metadata((select m from good)||jsonb_build_object('title',' padded'),'2305.18290',3),'untrimmed title');
select test.assert(not app_private.valid_source_metadata((select m from good)||jsonb_build_object('title','a'||chr(8238)||'b'),'2305.18290',3),'direction override');
select test.assert(not app_private.valid_source_metadata((select m from good)||jsonb_build_object('title',repeat('x',2001)),'2305.18290',3),'title too long');
select test.assert(not app_private.valid_source_metadata((select m from good)||jsonb_build_object('title',normalize('é',NFD)),'2305.18290',3),'not NFC');
select test.assert(not app_private.valid_source_metadata((select m from good)||'{"authors":[]}','2305.18290',3),'no authors');
select test.assert(not app_private.valid_source_metadata((select m from good)||jsonb_build_object('authors',(select jsonb_agg('A '||n) from generate_series(1,513) n)),'2305.18290',3),'too many authors');
select test.assert(not app_private.valid_source_metadata((select m from good)||'{"authors":[1]}','2305.18290',3),'author not text');
select test.assert(not app_private.valid_source_metadata((select m from good)||'{"categories":["cs.XX"]}','2305.18290',3),'unknown category');
select test.assert(not app_private.valid_source_metadata((select m from good)||'{"categories":["cs.LG","cs.LG"]}','2305.18290',3),'repeated category');
select test.assert(not app_private.valid_source_metadata((select m from good)||'{"license_uri":"https://example.com/mine"}','2305.18290',3),'unknown licence');
select test.assert(not app_private.valid_source_metadata((select m from good)||'{"version_date":"2023-04-30"}','2305.18290',3),'before the identifier month');
select test.assert(not app_private.valid_source_metadata((select m from good)||'{"version_date":"2024-02-30"}','2305.18290',3),'no such day');
select test.assert(not app_private.valid_source_metadata((select m from good)||jsonb_build_object('version_date',(current_date+3)::text),'2305.18290',3),'future version');
select test.assert(not app_private.valid_source_metadata((select m from good)||jsonb_build_object('observed_at',to_char(now()+interval '1 day','YYYY-MM-DD"T"HH24:MI:SS"Z"')),'2305.18290',3),'future observation');
select test.assert(not app_private.valid_source_metadata((select m from good)||'{"html_available":"yes"}','2305.18290',3),'flag not boolean');
select test.assert(not app_private.valid_source_metadata((select m from good)||jsonb_build_object('abstract',repeat('x',24001)),'2305.18290',3),'abstract too long');
select test.assert(app_private.valid_source_metadata((select m from good)||'{"abstract":null,"license_uri":null,"version_date":null,"categories":[]}','2305.18290',3),'nullable fields');
select test.assert(app_private.valid_source_metadata((select m from good)||'{"source_id":"hep-th/9711200","version_date":"1997-11-27"}','hep-th/9711200',3),'old-style identifier');
select test.assert(not app_private.valid_source_metadata('[1]'::jsonb,'2305.18290',3) and not app_private.valid_source_metadata(null,'2305.18290',3),'not an object');

-- Migration 077 switched devices on (arxiv_egress_off.sql checks it); off, the capability says so and the RPC refuses.
select test.assert((select source_metadata_enabled from app_private.pipeline_policy where singleton),'switched on by 077');
update app_private.pipeline_policy set source_metadata_enabled=false where singleton;
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert((public.v1_reader_capabilities()->'source_metadata'->>'enabled')::boolean=false,'capability off with the switch');
select test.reject($$select public.v1_submit_source_metadata('71000000-0000-0000-0000-0000000000a1',(select m from good),3)$$,'source_metadata_disabled');
reset role;
update app_private.pipeline_policy set source_metadata_enabled=true where singleton;

set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.assert((public.v1_reader_capabilities()->'source_metadata'->>'enabled')::boolean,'capability on with the flag');
select test.assert(public.v1_submit_source_metadata(:'IA',(select m from good),3)->>'status'='stored','stored on the account''s own import');
select test.assert(public.v1_submit_source_metadata(:'IA',(select m from good),3)->>'status'='unchanged','the same record is unchanged');
-- Another account's import, a revision the import didn't ask for, an invalid record.
select test.reject($$select public.v1_submit_source_metadata('71000000-0000-0000-0000-0000000000b1',(select m from good),3)$$,'document_unavailable');
select test.reject($$select public.v1_submit_source_metadata('71000000-0000-0000-0000-0000000000a1',(select m from good)||'{"revision":2}',2)$$,'revision_mismatch');
select test.reject($$select public.v1_submit_source_metadata('71000000-0000-0000-0000-0000000000a1',(select m from good)||'{"categories":["nope"]}',3)$$,'invalid_source_metadata');
-- Devices can't write shared tables or read others' rows.
select test.reject('select * from app_private.catalog_metadata','permission denied');
select test.reject('select * from app_private.import_requests','permission denied');
select test.reject($$select public.worker_catalog_promote('71000000-0000-0000-0000-00000000000a','71000000-0000-0000-0000-0000000000a1','{}'::jsonb)$$,'permission denied');
reset role;
select test.assert((select device_metadata_origin='arxiv_html' and device_metadata_revision=3 and device_metadata->>'title' like 'Direct Preference%'
 from app_private.import_requests where id=:'IA'),'stored on A''s import');
select test.assert((select device_metadata is null from app_private.import_requests where id=:'IB'),'B''s import untouched');
select test.assert(not exists(select 1 from app_private.catalog_metadata where source_id='2305.18290'),'nothing reached the shared catalog');

-- An older revision never replaces a newer one (an import without a pinned revision).
update app_private.import_requests set requested_revision=null where id=:'IA';
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject($$select public.v1_submit_source_metadata('71000000-0000-0000-0000-0000000000a1',(select m from good)||'{"revision":2}',2)$$,'revision_older');
reset role;

-- Promotion: the verifier's DataCite evidence must match; then the shared catalog gets a row marked device_verified.
set role service_role;
select test.reject($$select public.worker_catalog_promote('71000000-0000-0000-0000-00000000000a','71000000-0000-0000-0000-0000000000a1',
 '{"origin":"datacite","doi":"10.48550/arxiv.2305.18290","title":"Another Paper Entirely","first_author":"Rafailov, Rafael","version":3}')$$,'verification_mismatch');
select test.reject($$select public.worker_catalog_promote('71000000-0000-0000-0000-00000000000a','71000000-0000-0000-0000-0000000000a1',
 '{"origin":"datacite","doi":"10.48550/arxiv.2305.18290","title":"Direct Preference Optimization: Your Language Model is Secretly a Reward Model","first_author":"Sharma, Archit","version":3}')$$,'verification_mismatch');
select test.reject($$select public.worker_catalog_promote('71000000-0000-0000-0000-00000000000a','71000000-0000-0000-0000-0000000000a1',
 '{"origin":"datacite","doi":"10.48550/arxiv.2305.18290","title":"Direct Preference Optimization: Your Language Model is Secretly a Reward Model","first_author":"Rafailov, Rafael","version":2}')$$,'verification_mismatch');
select test.reject($$select public.worker_catalog_promote('71000000-0000-0000-0000-00000000000b','71000000-0000-0000-0000-0000000000b1',
 '{"origin":"datacite","doi":"10.48550/arxiv.2305.18290","title":"x","first_author":"y","version":3}')$$,'source_metadata_unavailable');
select public.worker_catalog_promote(:'A',:'IA','{"origin":"datacite","doi":"10.48550/arxiv.2305.18290","title":"Direct Preference Optimization — Your Language Model Is Secretly a Reward Model","first_author":"Rafailov, Rafael","version":3}'::jsonb) as promoted \gset
reset role;
select test.assert((select p.origin='device_verified' and p.import_id=:'IA' and m.metadata->>'title' like 'Direct Preference%' and m.metadata->>'updated_at'='2024-07-29'
 from app_private.catalog_metadata m join app_private.catalog_metadata_provenance p on p.metadata_id=m.id where m.id=:'promoted'),'promoted with its origin and evidence (typographic punctuation and case don''t count)');

-- The owner can promote, with MFA and a reason, and it is audited; a reader can't.
update app_private.import_requests set device_metadata=device_metadata||'{"title":"Direct Preference Optimization, revised title"}',device_metadata_sha256=sha256('changed') where id=:'IA';
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select test.reject($$select public.admin_catalog_promote('71000000-0000-0000-0000-00000000000a','71000000-0000-0000-0000-0000000000a1','because')$$,'operator_required');
select set_config('request.jwt.claim.sub',:'O',false);
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject($$select public.admin_catalog_promote('71000000-0000-0000-0000-00000000000a','71000000-0000-0000-0000-0000000000a1','because')$$,'operator_required');
select set_config('request.jwt.claim.aal','aal2',false);
select test.reject($$select public.admin_catalog_promote('71000000-0000-0000-0000-00000000000a','71000000-0000-0000-0000-0000000000a1','')$$,'reason_required');
select public.admin_catalog_promote(:'A',:'IA','Checked the abstract page by hand') as operated \gset
reset role;
select test.assert((select origin='operator' from app_private.catalog_metadata_provenance where metadata_id=:'operated'),'operator promotion marked');
select test.assert(exists(select 1 from app_private.admin_audit_events where action='catalog_promote' and reason='Checked the abstract page by hand'),'audited');

-- Rate limit: the account's 120 per hour.
update app_private.api_rate_rules set account_limit=2 where route='source-metadata';
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject($$select public.v1_submit_source_metadata('71000000-0000-0000-0000-0000000000a1',(select m from good),3)$$,'request_rate_limit');
reset role;
rollback;
