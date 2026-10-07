-- Archive (migration 020): a synced item flag, replayable, revision-checked, cleared on remove,
-- and absent from the JSON of non-archived items.
begin;
insert into auth.users values('20000000-0000-0000-0000-00000000000a'),('20000000-0000-0000-0000-00000000000b');
set role service_role;
select public.worker_record_arxiv_metadata('2401.05555',1,'{"title":"Archive me","authors":["A. Reader"],"categories":["cs.LG"]}') as meta \gset
reset role;
insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values
 ('20000000-0000-0000-0000-000000000010',decode(repeat('2a',32),'hex'),'shared_catalog','{"legacy_fixture":true}',1000,2);
insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values
 ('20000000-0000-0000-0000-000000000011','paper-assets','test/archive/original.pdf','20000000-0000-0000-0000-000000000010','verified',decode(repeat('2a',32),'hex'),1000,'application/pdf',now());
set role service_role;
select public.worker_approve_arxiv_asset('20000000-0000-0000-0000-000000000101',:'meta','20000000-0000-0000-0000-000000000010','20000000-0000-0000-0000-000000000011','https://creativecommons.org/licenses/by/4.0/',
 jsonb_build_object('source_id','2401.05555','source_revision',1,'source_url','https://arxiv.org/abs/2401.05555v1','license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_sha256',repeat('a',64),'observed_at','2026-10-06T01:00:00Z'));
reset role;

set role anon;
select test.reject($q$select public.v2_set_item_archived(gen_random_uuid(),'20000000-0000-0000-0000-000000000010',true,1)$q$,'permission denied');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-00000000000a',false);
select public.v2_set_library_item('20000000-0000-0000-0000-0000000000a1','20000000-0000-0000-0000-000000000010',true,0,'20000000-0000-0000-0000-000000000101')->'entry' as added \gset
select test.assert(not (:'added'::jsonb ? 'archived'),'a non-archived item has no archived key (unchanged JSON)');
select (:'added'::jsonb->>'membership_revision')::bigint as rev \gset
select test.reject($q$select public.v2_set_item_archived(gen_random_uuid(),'20000000-0000-0000-0000-000000000010',null,1)$q$,'invalid_archive_command');

-- Archive: applied receipt, entry flagged, revision bumped, journal entry for other devices.
select public.v2_set_item_archived('20000000-0000-0000-0000-0000000000a2','20000000-0000-0000-0000-000000000010',true,:rev) as archived \gset
select test.assert(:'archived'::jsonb->'result'->>'status'='applied' and (:'archived'::jsonb->'result'->>'revision')::bigint=:rev+1,'archive applied');
select test.assert((:'archived'::jsonb->'entry'->>'archived')::boolean and :'archived'::jsonb->'entry'->>'visible'='true','entry says archived, still in the library');
select test.assert((public.v2_set_item_archived('20000000-0000-0000-0000-0000000000a2','20000000-0000-0000-0000-000000000010',true,:rev)->>'replayed')::boolean,'replay');
select test.assert(exists(select 1 from jsonb_array_elements(public.v3_library_changes(0)->'changes') c, jsonb_array_elements(c->'entries') e
 where (e->>'archived')::boolean),'other devices receive the archive');
-- A stale revision is a conflict, not a change.
select test.assert(public.v2_set_item_archived(gen_random_uuid(),'20000000-0000-0000-0000-000000000010',false,:rev)->'result'->>'status'='revision_conflict','stale revision conflicts');
-- Unarchive.
select public.v2_set_item_archived(gen_random_uuid(),'20000000-0000-0000-0000-000000000010',false,:rev+1)->'entry' as restored \gset
select test.assert(not (:'restored'::jsonb ? 'archived') and (:'restored'::jsonb->>'membership_revision')::bigint=:rev+2,'unarchived');
-- Remove clears the mark: a re-add starts unarchived.
select public.v2_set_item_archived(gen_random_uuid(),'20000000-0000-0000-0000-000000000010',true,:rev+2);
select public.v2_set_library_item(gen_random_uuid(),'20000000-0000-0000-0000-000000000010',false,:rev+3);
reset role;
select test.assert((select archived_at is null and removed_at is not null from app_private.library_items where account_id='20000000-0000-0000-0000-00000000000a'),'removal clears archive');
set role authenticated;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-00000000000a',false);
select test.assert(public.v2_set_item_archived(gen_random_uuid(),'20000000-0000-0000-0000-000000000010',true,:rev+4)->'result'->>'status'='revision_conflict','a removed item cannot be archived');
-- Another account cannot archive an item it doesn't have.
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-00000000000b',false);
select test.assert(public.v2_set_item_archived(gen_random_uuid(),'20000000-0000-0000-0000-000000000010',true,1)->'result'->>'revision'='0','no item, no change');
reset role;
rollback;
