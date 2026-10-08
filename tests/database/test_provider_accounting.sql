-- Financial evidence and liabilities remain correct across lost responses,
-- customer refunds, later usage, duplicate requests and operator correction.
begin;
insert into auth.users(id) values('33000000-0000-0000-0000-00000000000a'),('33000000-0000-0000-0000-00000000000b'),('33000000-0000-0000-0000-00000000000c');
insert into app_private.app_roles(account_id,role) values('33000000-0000-0000-0000-00000000000c','owner');
\set A '33000000-0000-0000-0000-00000000000a'
\set B '33000000-0000-0000-0000-00000000000b'
\set C '33000000-0000-0000-0000-00000000000c'
\set O '33000000-0000-0000-0001-000000000001'
\set T '33000000-0000-0000-0002-000000000001'
select coalesce((select spent_microusd from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),0) as initial_spent,
 coalesce((select reserved_microusd from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),0) as initial_reserved \gset
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'A','adjustment','provider-a',1000,now()-interval '1 day',null,'Provider fixture');
select public.worker_grant_credits(:'B','adjustment','provider-b',1000,now()-interval '1 day',null,'Provider fixture');
select public.worker_reserve_operation(:'A',:'O','chat',sha256('test'),'beta-credits-v1',50,100000);
select test.assert((public.worker_provider_attempt_begin(:'A',:'O',:'T','anthropic','chat','claude-sonnet-5-5',sha256('first'),60000,'{"output_tokens":100,"web_searches":0}')->>'granted')::boolean,'first durable grant');
select test.assert(not (public.worker_provider_attempt_begin(:'A',:'O',:'T','anthropic','chat','claude-sonnet-5-5',sha256('first'),60000,'{"output_tokens":100,"web_searches":0}')->>'granted')::boolean,'lost acknowledgement never grants another POST');
select test.reject(format('select public.worker_provider_attempt_begin(%L,%L,%L,%L,%L,%L,sha256(%L),60000,%L)',:'A',:'O',:'T','anthropic','chat','claude-sonnet-5-5','different','{"output_tokens":100,"web_searches":0}'),'provider_attempt_id_conflict');
select test.assert(public.worker_provider_attempt_begin(:'A',:'O','33000000-0000-0000-0002-000000000002','anthropic','chat','claude-sonnet-5-5',sha256('too-big'),50000,'{"output_tokens":100}') ->>'reason'='operation_ceiling','combined requests cannot exceed reservation');
select public.worker_provider_attempt_finish(:'A',:'O',:'T','unknown',null,null,'{}','http_503');
select public.worker_settle_operation(:'A',:'O',0,123);
select public.worker_settle_operation(:'A',:'O',0,123);
reset role;
select test.assert((select actual_microusd=0 and provider_liability_microusd=60000 and actual_credits=0 from app_private.metered_operations where account_id=:'A' and id=:'O'),'refunded customer retains vendor liability');
select test.assert((select spent_microusd=:'initial_spent'::bigint and reserved_microusd=:'initial_reserved'::bigint+60000 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),'hold only outstanding child, not both operation and child');
select test.assert((select balance=1000 and reserved=0 from app_private.credit_buckets where external_key='provider-a'),'customer hold released without a debit');
set role service_role;
select public.worker_provider_attempt_finish(:'A',:'O',:'T','unknown',null,null,'{}','http_503');
select public.worker_provider_attempt_finish(:'A',:'O',:'T','succeeded','req_final',20000,'{"input_tokens":100,"output_tokens":100}',null);
select public.worker_provider_attempt_finish(:'A',:'O',:'T','succeeded','req_final',20000,'{"input_tokens":100,"output_tokens":100}',null);
select public.worker_settle_operation(:'A',:'O',0,123);
select test.reject(format('select public.worker_provider_attempt_finish(%L,%L,%L,%L,%L,1,%L,null)',:'A',:'O',:'T','succeeded','req_final','{}'),'provider_result_conflict');
reset role;
select test.assert((select spent_microusd=:'initial_spent'::bigint+20000 and reserved_microusd=:'initial_reserved'::bigint from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),'late result releases liability into expense once');
select test.assert((select count(*)=1 from app_private.provider_attempt_adjustments where attempt_id=:'T'),'late result has durable adjustment');
select test.assert((select count(*)=1 from app_private.provider_usage_events where provider_event_id='attempt:'||:'T'),'exact result has one usage event');
set role service_role;
select public.worker_record_provider_usage(:'A',:'O','anthropic','old-aggregate','claude-sonnet-5-5','{}',20000);
select public.worker_provider_attempt_reconcile(:'C','33000000-0000-0000-0003-000000000001',:'T',10000,'{"input_tokens":50,"output_tokens":50}','invoice-fixture-1','Invoice correction');
select test.assert((public.worker_provider_attempt_reconcile(:'C','33000000-0000-0000-0003-000000000001',:'T',10000,'{"input_tokens":50,"output_tokens":50}','invoice-fixture-1','Invoice correction')->>'replayed')::boolean,'reconcile replay idempotent');
reset role;
select test.assert(not exists(select 1 from app_private.provider_usage_events where provider_event_id='old-aggregate'),'legacy aggregate does not double count attempt');
select test.assert((select spent_microusd=:'initial_spent'::bigint+10000 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),'negative invoice adjustment applied exactly once');
select test.assert((select count(*)=1 from app_private.provider_reconciliations where invoice_reference='attempt-adjustment:33000000-0000-0000-0003-000000000001'),'original usage immutable, separate adjustment');
select test.reject(format('delete from app_private.provider_attempt_events where attempt_id=%L',:'T'),'immutable_record_requires_compensating_entry');

-- Provider-unit enforcement is independent of the cash reservation.
set role service_role;
select public.worker_reserve_operation(:'A','33000000-0000-0000-0001-000000000002','metadata',sha256('lookup'),'beta-credits-v1',0,0);
select test.assert(public.worker_provider_attempt_begin(:'A','33000000-0000-0000-0001-000000000002','33000000-0000-0000-0002-000000000003','tavily','reference_lookup','search-basic',sha256('no-period'),0,'{"credits":1}')->>'reason'='provider_allowance_unverified','missing billing evidence fails closed');
select public.worker_provider_allowance_configure('33000000-0000-0000-0004-000000000001',now()-interval '1 day',now()+interval '29 days',3,2,now(),'tavily-usage-fixture',true);
select test.assert((public.worker_provider_spending_policy()->>'tavily_enabled')::boolean,'verified prepaid allowance offered');
select test.assert(not (public.worker_provider_spending_policy()->>'native_search_enabled')::boolean,'native unbounded search disabled');
select test.assert((public.worker_provider_attempt_begin(:'A','33000000-0000-0000-0001-000000000002','33000000-0000-0000-0002-000000000004','tavily','reference_lookup','search-basic',sha256('last-credit'),0,'{"credits":1}')->>'granted')::boolean,'last prepaid unit admitted');
select public.worker_provider_attempt_finish(:'A','33000000-0000-0000-0001-000000000002','33000000-0000-0000-0002-000000000004','unknown',null,null,'{}','transport_unknown');
select public.worker_settle_operation(:'A','33000000-0000-0000-0001-000000000002',0,0);
select public.worker_reserve_operation(:'B','33000000-0000-0000-0001-000000000003','metadata',sha256('other-lookup'),'beta-credits-v1',0,0);
select test.assert(public.worker_provider_attempt_begin(:'B','33000000-0000-0000-0001-000000000003','33000000-0000-0000-0002-000000000005','tavily','reference_lookup','search-basic',sha256('other-last'),0,'{"credits":1}')->>'reason'='provider_allowance_exhausted','unknown response keeps last unit globally held');
select public.worker_provider_attempt_reconcile(:'C','33000000-0000-0000-0003-000000000002','33000000-0000-0000-0002-000000000004',0,'{"credits":0}','usage-fixture-no-bill','Provider confirmed no charge');
select test.assert((public.worker_provider_attempt_begin(:'B','33000000-0000-0000-0001-000000000003','33000000-0000-0000-0002-000000000006','tavily','reference_lookup','search-basic',sha256('new-last'),0,'{"credits":1}')->>'granted')::boolean,'evidence-based reconciliation can release prepaid unit');
select public.worker_provider_attempt_finish(:'B','33000000-0000-0000-0001-000000000003','33000000-0000-0000-0002-000000000006','succeeded','search_req',0,'{"credits":1,"searches":1}',null);
reset role;
select test.assert((select baseline_units=2 and spent_units=1 and reserved_units=0 from app_private.provider_allowance_periods where id='33000000-0000-0000-0004-000000000001'),'period baseline, used and held stay separate');

-- Suspension blocks fresh holds and grants even if the caller still has a JWT.
set role service_role;
select public.worker_admin_set_sign_in(:'C','33000000-0000-0000-0005-000000000001',:'B',true,'Suspend fixture');
select test.reject(format('select public.worker_reserve_operation(%L,gen_random_uuid(),%L,sha256(%L),%L,0,0)',:'B','metadata','suspended','beta-credits-v1'),'spending_suspended');
select test.assert(public.worker_provider_attempt_begin(:'B','33000000-0000-0000-0001-000000000003','33000000-0000-0000-0002-000000000007','tavily','reference_lookup','search-basic',sha256('suspended'),0,'{"credits":1}')->>'reason'='account_unavailable','existing operation does not bypass suspension');
select public.worker_admin_set_sign_in(:'C','33000000-0000-0000-0005-000000000002',:'B',false,'Enable fixture');
select test.assert(not (public.worker_admin_set_sign_in(:'C','33000000-0000-0000-0005-000000000001',:'B',true,'Suspend fixture')->>'disabled')::boolean,'old disable replay cannot undo newer enable');
select public.worker_settle_operation(:'B','33000000-0000-0000-0001-000000000003',0,0);

-- An unexpectedly expensive result is retained, then admission stops.
select public.worker_reserve_operation(:'A','33000000-0000-0000-0001-000000000004','chat',sha256('overrun'),'beta-credits-v1',10,10000);
select public.worker_provider_attempt_begin(:'A','33000000-0000-0000-0001-000000000004','33000000-0000-0000-0002-000000000008','anthropic','chat','claude-sonnet-5-5',sha256('overrun-req'),10000,'{"output_tokens":1}');
select public.worker_provider_attempt_finish(:'A','33000000-0000-0000-0001-000000000004','33000000-0000-0000-0002-000000000008','succeeded','overrun_req',15000,'{"output_tokens":1000}',null);
select public.worker_settle_operation(:'A','33000000-0000-0000-0001-000000000004',3,1);
reset role;
select test.assert((select not work_enabled from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),'overrun pauses platform');
select test.assert((select actual_microusd=15000 from app_private.metered_operations where account_id=:'A' and id='33000000-0000-0000-0001-000000000004'),'caller cannot underreport known provider expense');

set role authenticated;
select test.reject('select public.worker_provider_spending_policy()','permission denied');
select test.reject('select public.worker_provider_attempt_reconcile(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),0,''{}'',''evidence'',''reason'')','permission denied');
select test.reject('select * from app_private.provider_attempts','permission denied');
reset role;
rollback;
