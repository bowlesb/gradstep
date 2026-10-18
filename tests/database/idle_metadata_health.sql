-- The health snapshot must distinguish orphaned metadata from an import a reader is waiting for.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
insert into auth.users(id) values('90000000-0000-4000-8000-000000000001');
select set_config('request.jwt.claim.sub','90000000-0000-4000-8000-000000000001',true);
select public.v2_begin_import('90000000-0000-4000-8000-000000000002','2305.18290',0,3);
insert into app_private.pipeline_papers(source_id,stage,stage_entered_at) values('2406.09246','metadata',now()-interval '2 hours');
insert into app_private.pipeline_papers(source_id,stage,stage_entered_at,claim_id,lease_until)
 values('2406.09247','metadata',now()-interval '2 hours',gen_random_uuid(),now()+interval '1 minute');
update app_private.pipeline_papers set stage_entered_at=now()-interval '2 hours' where source_id='2305.18290';
select public.worker_workflow_snapshot() as h \gset
select test.assert((:'h'::jsonb->>'resting_metadata')::int=1,'only unclaimed metadata with no reader is idle');
select test.assert(jsonb_array_length(:'h'::jsonb->'stuck')=2,'interested reader and claimed metadata still alert');
select test.assert(not exists(select 1 from jsonb_array_elements(:'h'::jsonb->'stuck') x where x->>'source'='2406.09246'),'orphan is not a stalled import');
select test.assert((select stage='metadata' and claim_id is null from app_private.pipeline_papers where source_id='2406.09246'),'observation does not mutate the paper');
rollback;
