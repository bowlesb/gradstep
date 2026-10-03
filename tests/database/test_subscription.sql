insert into app_private.plans values('test-monthly','Fixture monthly',false);
insert into app_private.price_versions values('test-1','test-monthly','test.monthly',1000,'2026-01-01','{}');
set role authenticated;
select test.reject($q$select public.worker_record_subscription('00000000-0000-0000-0000-000000000001','Sandbox','fake','original',now(),'test.monthly','active',now()+interval '1 day',now(),now()+interval '1 day','{}')$q$,'permission denied');
reset role;
set role service_role;
select public.worker_record_subscription('00000000-0000-0000-0000-000000000001','Sandbox','purchase','original',now()-interval '4 hours','test.monthly','active',now()+interval '1 day',date_trunc('month',now()),now()+interval '1 day','{"transaction":"purchase"}');
select test.assert(not public.worker_record_subscription('00000000-0000-0000-0000-000000000001','Sandbox','purchase','original',now()-interval '4 hours','test.monthly','active',now()+interval '1 day',date_trunc('month',now()),now()+interval '1 day','{"transaction":"purchase"}'),'same purchase event does not grant again');
select test.reject($q$select public.worker_record_subscription('00000000-0000-0000-0000-000000000002','Sandbox','restore-other-account','original',now(),'test.monthly','active',now()+interval '1 day',now(),now()+interval '1 day','{}')$q$,'subscription_owned_by_another_account');
select public.worker_record_subscription('00000000-0000-0000-0000-000000000001','Sandbox','refund','original',now()-interval '2 hours','test.monthly','revoked',now()+interval '1 day',null,null,'{"transaction":"refund"}');
select test.assert(not public.worker_record_subscription('00000000-0000-0000-0000-000000000001','Sandbox','late-old-notification','original',now()-interval '3 hours','test.monthly','active',now()+interval '1 day',date_trunc('month',now()),now()+interval '1 day','{"transaction":"late"}'),'older notification cannot resurrect revoked entitlement');
reset role;
select test.assert((select state='revoked' from app_private.entitlements where original_transaction_id='original'),'revocation remains authoritative');
select test.assert((select balance=0 and revoked_at is not null from app_private.credit_buckets where source='subscription'),'revoked allowance unavailable');
select test.assert((select count(*)=1 from app_private.allowance_periods),'duplicate and reordered events retain one allowance');
-- Reinstatement uses exactly the same verified allowance boundaries.
select public.worker_record_subscription('00000000-0000-0000-0000-000000000001','Sandbox','reinstatement','original',now()-interval '1 hour','test.monthly','active',
 (select ends_at from app_private.allowance_periods where original_transaction_id='original'),
 (select starts_at from app_private.allowance_periods where original_transaction_id='original'),
 (select ends_at from app_private.allowance_periods where original_transaction_id='original'),'{"transaction":"reinstated"}');
select test.assert((select balance=1000 and revoked_at is null from app_private.credit_buckets where source='subscription'),'reinstatement compensates prior revocation');
select test.assert((select count(*)=1 from app_private.credit_ledger where kind='grant' and bucket_id=(select bucket_id from app_private.allowance_periods where original_transaction_id='original')),'one original allowance grant');
