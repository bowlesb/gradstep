-- Account deletion (migration 017): personal rows deleted, billing kept under
-- the closed account's ID, login rejected, busy accounts refused, bystanders
-- untouched. Rolled back at the end.
begin;
insert into auth.users values('17000000-0000-0000-0000-00000000000a'),('17000000-0000-0000-0000-00000000000b');
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits('17000000-0000-0000-0000-00000000000a','adjustment','deletion-test-a',200,now()-interval '1 day',null,'Deletion test grant');
select public.worker_grant_credits('17000000-0000-0000-0000-00000000000b','adjustment','deletion-test-b',200,now()-interval '1 day',null,'Deletion test grant');
reset role;

-- Personal data for A and for bystander B: keys, encrypted history, library, a report.
set role authenticated;
select set_config('request.jwt.claim.sub','17000000-0000-0000-0000-00000000000a',false);
select public.v1_bootstrap_keys('17100000-0000-0000-0000-00000000000a',decode(repeat('11',32),'hex'),decode(repeat('22',60),'hex'),decode(repeat('33',32),'hex'),decode(repeat('44',92),'hex'),decode(repeat('aa',32),'hex'));
select public.v1_append_event('17100000-0000-0000-0000-00000000000a','17200000-0000-0000-0000-00000000000a',1,1,decode(repeat('55',64),'hex'),decode(repeat('33',32),'hex'));
select public.v2_begin_import('17300000-0000-0000-0000-00000000000a','2305.18290',0);
select public.v1_create_report('17400000-0000-0000-0000-00000000000a','Equation clipped','The last symbol is off screen.','0.1','1','iOS 26.4','paper');
select public.v1_set_report_status('17500000-0000-0000-0000-00000000000a','17400000-0000-0000-0000-00000000000a','verified');
select set_config('request.jwt.claim.sub','17000000-0000-0000-0000-00000000000b',false);
select public.v1_bootstrap_keys('17100000-0000-0000-0000-00000000000b',decode(repeat('11',32),'hex'),decode(repeat('22',60),'hex'),decode(repeat('33',32),'hex'),decode(repeat('44',92),'hex'),decode(repeat('aa',32),'hex'));
select public.v1_append_event('17100000-0000-0000-0000-00000000000b','17200000-0000-0000-0000-00000000000b',1,1,decode(repeat('66',64),'hex'),decode(repeat('33',32),'hex'));
select public.v2_begin_import('17300000-0000-0000-0000-00000000000b','2305.18290',0);
-- Customers cannot call the deletion functions.
select test.reject($q$select public.worker_delete_account_begin('17000000-0000-0000-0000-00000000000b')$q$,'permission denied');
select test.reject($q$select public.worker_delete_account_finish('17000000-0000-0000-0000-00000000000b')$q$,'permission denied');
reset role;

-- A private conversion pending for A.
insert into app_private.pipeline_papers(owner_id,source_id,stage,eligible) values('17000000-0000-0000-0000-00000000000a','2106.09685','download',false);

-- Billing for A: one settled answer with recorded provider usage, then one held.
set role service_role;
select public.worker_reserve_operation('17000000-0000-0000-0000-00000000000a','17600000-0000-0000-0000-00000000000a','chat',decode(repeat('cc',32),'hex'),'beta-credits-v1',30,150000);
select public.worker_settle_operation('17000000-0000-0000-0000-00000000000a','17600000-0000-0000-0000-00000000000a',5,25000);
select public.worker_record_provider_usage('17000000-0000-0000-0000-00000000000a','17600000-0000-0000-0000-00000000000a','anthropic','msg_deletion_test','claude-sonnet-5-5','{}'::jsonb,25000);
select public.worker_reserve_operation('17000000-0000-0000-0000-00000000000a','17600000-0000-0000-0000-00000000000b','chat',decode(repeat('dd',32),'hex'),'beta-credits-v1',30,150000);
-- A held answer blocks deletion; nothing changes.
select test.reject($q$select public.worker_delete_account_begin('17000000-0000-0000-0000-00000000000a')$q$,'account_busy');
reset role;
select test.assert((select closed_at is null from app_private.accounts where id='17000000-0000-0000-0000-00000000000a'),'busy account stays open');
select test.assert((select count(*)=1 from app_private.keyrings where account_id='17000000-0000-0000-0000-00000000000a'),'busy account keeps its keys');
set role service_role;
select public.worker_settle_operation('17000000-0000-0000-0000-00000000000a','17600000-0000-0000-0000-00000000000b',0,0);

-- Delete A (capacity counters are adjusted once for the whole history).
reset role;
select ciphertext_bytes as env_bytes_before, event_count as env_events_before from app_private.sync_environment_storage where singleton \gset
set role service_role;
select public.worker_delete_account_begin('17000000-0000-0000-0000-00000000000a') as result \gset
reset role;
select test.assert((select ciphertext_bytes=:env_bytes_before-64 and event_count=:env_events_before-1 from app_private.sync_environment_storage where singleton),
 'environment capacity released exactly');
select test.assert((select count(*) from app_private.sync_account_storage where account_id='17000000-0000-0000-0000-00000000000a')=0,'account capacity row removed');
set role service_role;
select test.assert(:'result'::jsonb->'prefixes' @> '[{"bucket":"paper-assets","prefix":"private/17000000-0000-0000-0000-00000000000a/"},{"bucket":"support","prefix":"17000000-0000-0000-0000-00000000000a/"}]'::jsonb,
 'private and support prefixes returned');
select test.assert('17000000-0000-0000-0000-00000000000a'=any(public.worker_account_deletions_pending(5)),'closed account with a linked login is pending');
select test.assert((:'result'::jsonb->>'private_prefix')='private/17000000-0000-0000-0000-00000000000a/','private prefix returned');
-- Repeating the first step is safe.
select public.worker_delete_account_begin('17000000-0000-0000-0000-00000000000a');
select test.assert(public.worker_delete_account_finish('17000000-0000-0000-0000-00000000000a')>=0,'finish marks removed files');
select test.reject($q$select public.worker_delete_account_finish('17000000-0000-0000-0000-00000000000b')$q$,'account_not_closed');
reset role;

-- Personal data is gone.
select test.assert((select count(*) from app_private.keyrings where account_id='17000000-0000-0000-0000-00000000000a')=0,'keyring deleted');
select test.assert((select count(*) from app_private.devices where account_id='17000000-0000-0000-0000-00000000000a')=0,'devices deleted');
select test.assert((select count(*) from app_private.sync_events where account_id='17000000-0000-0000-0000-00000000000a')=0,'encrypted history deleted');
select test.assert((select count(*) from app_private.import_requests where account_id='17000000-0000-0000-0000-00000000000a')=0,'imports deleted');
select test.assert((select count(*) from app_private.pipeline_imports where account_id='17000000-0000-0000-0000-00000000000a')=0,'pipeline links deleted');
select test.assert((select count(*) from app_private.library_commands where account_id='17000000-0000-0000-0000-00000000000a')=0,'library receipts deleted');
select test.assert((select count(*) from app_private.library_changes where account_id='17000000-0000-0000-0000-00000000000a')=0,'library journal deleted');
select test.assert((select count(*) from app_private.library_sync_state where account_id='17000000-0000-0000-0000-00000000000a')=0,'library cursor deleted');
select test.assert((select count(*) from app_private.support_reports where account_id='17000000-0000-0000-0000-00000000000a')=0,'reports deleted');
select test.assert((select count(*) from app_private.support_status_events where report_id='17400000-0000-0000-0000-00000000000a')=0,'report status history deleted');
select test.assert((select count(*) from app_private.api_rate_windows where scope_id='17000000-0000-0000-0000-00000000000a')=0,'rate counters deleted');

-- Billing is kept under the closed account.
select test.assert((select count(*)=2 from app_private.metered_operations where account_id='17000000-0000-0000-0000-00000000000a'),'operations kept');
select test.assert((select count(*)>0 from app_private.credit_ledger where account_id='17000000-0000-0000-0000-00000000000a'),'ledger kept');
select test.assert((select count(*)=1 from app_private.credit_buckets where account_id='17000000-0000-0000-0000-00000000000a'),'credit bucket kept');
select test.assert((select count(*)=1 from app_private.provider_usage_events where account_id='17000000-0000-0000-0000-00000000000a'),'provider usage kept');
select test.assert((select closed_at is not null from app_private.accounts where id='17000000-0000-0000-0000-00000000000a'),'account closed');

select test.assert((public.worker_account_deletion_status('17000000-0000-0000-0000-00000000000a')->>'personal_rows')::int=0,'status reports no personal rows');
select test.assert((public.worker_account_deletion_status('17000000-0000-0000-0000-00000000000a')->>'billing_rows')::int>0,'status reports kept billing');

-- The pending private conversion stopped.
select test.assert((select stage='failed' and error_code='owner_deleted' and claim_id is null
 from app_private.pipeline_papers where owner_id='17000000-0000-0000-0000-00000000000a'),'private conversion stopped');

-- A remaining login token is rejected; deleting the login nulls the link.
set role authenticated;
select set_config('request.jwt.claim.sub','17000000-0000-0000-0000-00000000000a',false);
select test.reject('select public.v1_reports()','authentication_required');
reset role;
delete from auth.users where id='17000000-0000-0000-0000-00000000000a';
select test.assert((select auth_user_id is null and closed_at is not null from app_private.accounts where id='17000000-0000-0000-0000-00000000000a'),'login unlinked from the kept records');
set role service_role;
select test.assert(not ('17000000-0000-0000-0000-00000000000a'=any(public.worker_account_deletions_pending(5))),'finished deletion is no longer pending');
reset role;

-- Bystander B is untouched and append-only rules still hold for it.
select test.assert((select count(*)=1 from app_private.keyrings where account_id='17000000-0000-0000-0000-00000000000b'),'bystander keys kept');
select test.assert((select count(*)=1 from app_private.sync_events where account_id='17000000-0000-0000-0000-00000000000b'),'bystander history kept');
select test.assert((select count(*)=1 from app_private.import_requests where account_id='17000000-0000-0000-0000-00000000000b'),'bystander library kept');
select test.reject($q$delete from app_private.library_commands where account_id='17000000-0000-0000-0000-00000000000b'$q$,'immutable_record_requires_compensating_entry');
select set_config('app_private.deleting_account','17000000-0000-0000-0000-00000000000a',true);
select test.reject($q$delete from app_private.library_commands where account_id='17000000-0000-0000-0000-00000000000b'$q$,'immutable_record_requires_compensating_entry');
select set_config('app_private.deleting_account','',true);
set role authenticated;
select set_config('request.jwt.claim.sub','17000000-0000-0000-0000-00000000000b',false);
select test.assert(jsonb_typeof(public.v1_reports())='array','bystander still signed in');
reset role;
rollback;
