-- Verified-fixture Sandbox credits: both allowance dimensions, missing/stable
-- identity, refunds and owner deletion. No Apple/provider calls. Rolled back.
begin;
insert into auth.users select ('35000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,10) n;
create function pg_temp.sandbox_tx(tid text, a uuid, identity text default null, qty integer default 1,
 signed_offset interval default interval '0', revoked boolean default false, env text default 'Sandbox')
returns jsonb language sql as $$
 select jsonb_strip_nulls(jsonb_build_object('environment',env,'transaction_id',tid,'original_transaction_id',tid,
  'product_id','com.sciencereader.ios.credits.400','type','Consumable','quantity',qty,'ownership','PURCHASED',
  'purchase_date',(extract(epoch from now()-interval '1 minute')*1000)::bigint,
  'signed_date',(extract(epoch from now()+signed_offset)*1000)::bigint,
  'revocation_date',case when revoked then (extract(epoch from now())*1000)::bigint end,
  'app_account_token',a,'app_transaction_id',identity))
$$;
\set A '\'35000000-0000-0000-0000-000000000001\''
\set B '\'35000000-0000-0000-0000-000000000002\''
\set C '\'35000000-0000-0000-0000-000000000003\''
\set D '\'35000000-0000-0000-0000-000000000004\''
\set E '\'35000000-0000-0000-0000-000000000005\''
\set F '\'35000000-0000-0000-0000-000000000006\''
\set G '\'35000000-0000-0000-0000-000000000007\''
\set H '\'35000000-0000-0000-0000-000000000008\''
\set I '\'35000000-0000-0000-0000-000000000009\''
\set J '\'35000000-0000-0000-0000-000000000010\''

set role service_role;
select test.assert(public.worker_record_store_transaction(:A,pg_temp.sandbox_tx('350001',:A))
 @> '{"outcome":"recorded","credits":0}','missing verified identity records a compatible final outcome without free credits');
select test.assert(public.worker_record_store_transaction(:A,pg_temp.sandbox_tx('350001',:A))->>'outcome'='already_recorded','missing-identity replay remains final');
reset role;
select test.assert((select count(*)=1 and max(reason)='identity_missing' and max(granted_credits)=0
 from app_private.store_sandbox_decisions where transaction_id='350001'),'missing identity denial is durable and deduplicated');

-- Unattributed notifications preserve a verified identity for the same transaction.
set role service_role;
select test.assert(public.worker_record_store_notification('Sandbox','35000000-0000-0000-1000-000000000001','DID_RENEW',null,now(),
 pg_temp.sandbox_tx('350002',null,'35111'))->>'outcome'='unattributed','unattributed notification has no financial effect');
select test.assert(public.worker_record_store_transaction(:A,pg_temp.sandbox_tx('350002',:A))
 @> '{"outcome":"recorded","credits":400}','an omitted field uses this transaction''s previously verified identity');
select test.reject($q$select public.worker_record_store_transaction('35000000-0000-0000-0000-000000000001',
 pg_temp.sandbox_tx('350002','35000000-0000-0000-0000-000000000001','35222',1,interval '1 second'))$q$,'store_transaction_conflict');
reset role;
select test.assert((select app_transaction_id='35111' from app_private.store_seen where environment='Sandbox' and transaction_id='350002'),'newest-copy record retains stable identity');
select test.reject($q$update app_private.store_seen set app_transaction_id='35222' where environment='Sandbox' and transaction_id='350002'$q$,'store_transaction_conflict');
select test.reject($q$update app_private.store_transactions set app_transaction_id=null where environment='Sandbox' and transaction_id='350002'$q$,'store_transaction_conflict');

-- Refunds remove customer balances but never replenish either grant allowance.
set role service_role;
select test.assert(public.worker_record_store_transaction(:B,pg_temp.sandbox_tx('350003',:B,'35301',2))->>'credits'='800','first identity grant');
select public.worker_record_store_transaction(:B,pg_temp.sandbox_tx('350003',:B,'35301',2,interval '1 second',true));
select test.assert(public.worker_record_store_transaction(:C,pg_temp.sandbox_tx('350004',:C,'35301',2))->>'credits'='200','refund does not replenish Apple identity allowance');
select public.worker_record_store_transaction(:B,pg_temp.sandbox_tx('350003',:B,'35301',2,interval '2 seconds',false));
select test.assert(public.worker_record_store_transaction(:D,pg_temp.sandbox_tx('350005',:D,'35301'))->>'credits'='0','reversal does not create extra allowance');
reset role;
select test.assert((select sum(credits)=1000 from app_private.store_transactions where environment='Sandbox' and app_transaction_id='35301'),'immutable grant history records 1,000 across accounts');

-- Account and identity limits are separate intersections, not a double-counted union.
set role service_role;
select test.assert(public.worker_record_store_transaction(:E,pg_temp.sandbox_tx('350006',:E,'35310',2))->>'credits'='800','account first Apple identity');
select test.assert(public.worker_record_store_transaction(:E,pg_temp.sandbox_tx('350007',:E,'35311',2))->>'credits'='200','new Apple identity cannot reset account allowance');
select test.assert(public.worker_record_store_transaction(:F,pg_temp.sandbox_tx('350008',:F,'35311',2))->>'credits'='800','other account receives this identity''s exact remaining allowance');

-- Deleting an app account leaves the Apple identity's allowance history in place.
select test.assert(public.worker_record_store_transaction(:G,pg_temp.sandbox_tx('350009',:G,'35777',2))->>'credits'='800','soon-deleted account grant');
select public.worker_delete_account_begin(:G);
select test.assert(public.worker_record_store_transaction(:H,pg_temp.sandbox_tx('350009',:G,'35777',2))->>'outcome'='already_recorded','restoring deleted purchase does not duplicate a grant');
select test.assert(public.worker_record_store_transaction(:H,pg_temp.sandbox_tx('350010',:H,'35777',2))->>'credits'='200','new account still shares original Apple allowance');

-- A first-seen refund can reverse through the notification path using known identity.
select public.worker_record_store_transaction(:I,pg_temp.sandbox_tx('350011',:I,'35888',1,interval '0',true));
select public.worker_record_store_notification('Sandbox','35000000-0000-0000-1000-000000000002','REFUND_REVERSED',null,now()+interval '1 second',
 pg_temp.sandbox_tx('350011',:I,null,1,interval '1 second',false));
reset role;
select test.assert((select credits=400 from app_private.store_transactions where environment='Sandbox' and transaction_id='350011'),'notification refund reversal passes same allowance gate');

set role service_role;
select test.assert(public.worker_record_store_transaction(:J,pg_temp.sandbox_tx('350012',:J,null,10,interval '0',false,'Production'))->>'credits'='4000','Production missing identity and uncapped policy remain unchanged');
select test.reject('select * from app_private.store_sandbox_decisions','permission denied');
select test.reject($q$select app_private.record_store_transaction_v018('app','35000000-0000-0000-0000-000000000001','{}')$q$,'permission denied');
reset role;
select test.reject($q$update app_private.store_policy set monthly_credit_cap=null where environment='Sandbox'$q$,'store_sandbox_finite_cap');
select test.reject($q$update app_private.store_policy set monthly_credit_cap=1001 where environment='Sandbox'$q$,'store_sandbox_finite_cap');
select test.reject($q$delete from app_private.store_sandbox_decisions$q$,'immutable_record_requires_compensating_entry');
rollback;
