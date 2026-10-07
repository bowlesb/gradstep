-- App Store purchases (migration 018): one grant per verified transaction,
-- ownership binding, renewals from notifications, refunds that keep credits in
-- flight, reversed refunds, the newest copy deciding, upgrades, packs, the
-- Sandbox cap, deleted-account rebinding. Rolled back.
begin;
insert into auth.users values('18000000-0000-0000-0000-00000000000a'),('18000000-0000-0000-0000-00000000000b'),('18000000-0000-0000-0000-00000000000c'),
 ('18000000-0000-0000-0000-00000000000e'),('18000000-0000-0000-0000-00000000000f'),('18000000-0000-0000-0000-000000000010'),('18000000-0000-0000-0000-000000000011'),
 ('18000000-0000-0000-0000-000000000012'),('18000000-0000-0000-0000-000000000013'),('18000000-0000-0000-0000-000000000014'),('18000000-0000-0000-0000-000000000015');
create function pg_temp.tx(tid text,otid text,product text,purchased timestamptz,expires timestamptz,signed timestamptz,
 token uuid default null,revoked timestamptz default null,kind text default 'Auto-Renewable Subscription',qty int default null,env text default 'Production',ownership text default null,
 reason text default null,apptx text default null)
returns jsonb language sql as $$
 select jsonb_strip_nulls(jsonb_build_object('environment',env,'transaction_id',tid,'original_transaction_id',otid,'product_id',product,'type',kind,
  'purchase_date',(extract(epoch from purchased)*1000)::bigint,'expires_date',(extract(epoch from expires)*1000)::bigint,
  'revocation_date',(extract(epoch from revoked)*1000)::bigint,'signed_date',(extract(epoch from signed)*1000)::bigint,
  'app_account_token',token,'quantity',qty,'ownership',ownership,'reason',reason,'app_transaction_id',apptx))
$$;
create function pg_temp.available(a uuid) returns bigint language sql as $$
 select coalesce(sum(balance-reserved) filter(where revoked_at is null and starts_at<=now() and (expires_at is null or expires_at>now())),0)
 from app_private.credit_buckets where account_id=a
$$;
\set A '\'18000000-0000-0000-0000-00000000000a\''
\set B '\'18000000-0000-0000-0000-00000000000b\''
\set C '\'18000000-0000-0000-0000-00000000000c\''
\set E '\'18000000-0000-0000-0000-00000000000e\''
\set G '\'18000000-0000-0000-0000-00000000000f\''
\set H '\'18000000-0000-0000-0000-000000000010\''
\set I '\'18000000-0000-0000-0000-000000000011\''
\set K '\'18000000-0000-0000-0000-000000000012\''
\set L '\'18000000-0000-0000-0000-000000000013\''
\set M '\'18000000-0000-0000-0000-000000000014\''
\set N '\'18000000-0000-0000-0000-000000000015\''
\set standard '\'com.sciencereader.ios.standard.monthly\''
\set pro '\'com.sciencereader.ios.pro.monthly\''
\set pack '\'com.sciencereader.ios.credits.400\''

-- Customers cannot record purchases.
set role authenticated;
select set_config('request.jwt.claim.sub','18000000-0000-0000-0000-00000000000a',false);
select test.reject($q$select public.worker_record_store_transaction('18000000-0000-0000-0000-00000000000a','{}')$q$,'permission denied');
select test.reject($q$select public.worker_record_store_notification('Sandbox','18900000-0000-0000-0000-000000000001','TEST',null,now(),null)$q$,'permission denied');
select test.assert(public.v1_store_summary()->>'plan' is null,'no plan before purchase');
reset role;

set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
-- A buys Standard in the app (token = A).
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('1001','1001',:standard,now()-interval '29 days',now()+interval '1 day',now()-interval '1 minute',:A))
 @> '{"outcome":"recorded","credits":800}','purchase recorded with the Standard allowance');
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('1001','1001',:standard,now()-interval '29 days',now()+interval '1 day',now()-interval '1 minute',:A))
 ->>'outcome'='already_recorded','exact replay grants nothing');
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('1001','1001',:standard,now()-interval '29 days',now()+interval '1 day',now()-interval '2 minutes',:A))
 ->>'outcome'='already_recorded','an older signed copy grants nothing');
select test.reject($q$select public.worker_record_store_transaction('18000000-0000-0000-0000-00000000000a',
 pg_temp.tx('1001','1001','com.sciencereader.ios.standard.monthly',now()-interval '5 minutes',now()+interval '1 day',now(),'18000000-0000-0000-0000-00000000000a'))$q$,'store_transaction_conflict');
reset role;
select test.assert(pg_temp.available(:A)=800,'A has 800 credits');
select test.assert((select count(*)=1 from app_private.credit_ledger l join app_private.credit_buckets b on b.id=l.bucket_id
 where b.account_id=:A and l.kind='grant'),'one grant');
select test.assert((select expires_at from app_private.credit_buckets where account_id=:A and source='subscription')
 between now()+interval '23 hours' and now()+interval '25 hours','allowance expires with the period');
set role authenticated;
select set_config('request.jwt.claim.sub','18000000-0000-0000-0000-00000000000a',false);
select test.assert(public.v1_store_summary()->>'plan'='standard','A sees Standard');
reset role;

-- B cannot claim A's purchase, with or without a token.
set role service_role;
select test.assert(public.worker_record_store_transaction(:B,pg_temp.tx('1001','1001',:standard,now()-interval '29 days',now()+interval '1 day',now(),:A))
 ->>'outcome'='linked_to_another_account','token for another account refused');
select test.assert(public.worker_record_store_transaction(:B,pg_temp.tx('2001','2001',:standard,now()-interval '1 minute',now()+interval '30 days',now(),:A))
 ->>'outcome'='linked_to_another_account','unbound purchase with another account''s token refused');
select test.assert(public.worker_record_store_transaction(:B,pg_temp.tx('1003','1001',:standard,now(),now()+interval '30 days',now()))
 ->>'outcome'='linked_to_another_account','bound purchase refused without a token');
reset role;
select test.assert(pg_temp.available(:B)=0,'B received nothing');
select test.assert((select count(*)=0 from app_private.store_owners where original_transaction_id='2001'),'refused purchase not bound');

-- A renewal arrives as a notification (token A); a repeat of the same notification is ignored.
set role service_role;
select test.assert(public.worker_record_store_notification('Production','18900000-0000-0000-0000-000000000002','DID_RENEW',null,now(),
 pg_temp.tx('1002','1001',:standard,now(),now()+interval '30 days',now(),:A))->>'outcome'='recorded','renewal from a notification');
select test.assert(public.worker_record_store_notification('Production','18900000-0000-0000-0000-000000000002','DID_RENEW',null,now(),
 pg_temp.tx('1002','1001',:standard,now(),now()+interval '30 days',now(),:A)) @> '{"duplicate":true}','duplicate notification');
select test.reject($q$select public.worker_record_store_notification('Sandbox','18900000-0000-0000-0000-000000000003','DID_RENEW',null,now(),
 pg_temp.tx('1004','1001','com.sciencereader.ios.standard.monthly',now(),now()+interval '30 days',now()))$q$,'invalid_store_notification');
reset role;
select test.assert(pg_temp.available(:A)=1600,'a renewal of the same plan keeps the ending period''s credits');

-- A refund of the renewal keeps credits held for an answer in flight (the hold
-- takes 800 from the first period, which expires sooner, and 100 from the renewal).
set role service_role;
select public.worker_reserve_operation(:A,'18600000-0000-0000-0000-00000000000a','chat',decode(repeat('aa',32),'hex'),'beta-credits-v1',900,100000);
select test.assert(public.worker_record_store_notification('Production','18900000-0000-0000-0000-000000000004','REFUND',null,now()+interval '1 second',
 pg_temp.tx('1002','1001',:standard,now(),now()+interval '30 days',now()+interval '1 second',:A,now()))->>'outcome'='updated','refund applied');
reset role;
select test.assert((select b.revoked_at is not null and b.balance=b.reserved from app_private.credit_buckets b join app_private.store_transactions t on t.bucket_id=b.id
 where t.transaction_id='1002'),'refunded bucket keeps only its holds');
select test.assert(pg_temp.available(:A)=0,'refund removes unspent credits');
set role service_role;
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('1002','1001',:standard,now(),now()+interval '30 days',now(),:A))
 ->>'outcome'='already_recorded','an older unrevoked copy cannot undo the refund');
select public.worker_settle_operation(:A,'18600000-0000-0000-0000-00000000000a',40,20000);
-- Apple reverses the refund.
select test.assert(public.worker_record_store_notification('Production','18900000-0000-0000-0000-000000000005','REFUND_REVERSED',null,now()+interval '2 seconds',
 pg_temp.tx('1002','1001',:standard,now(),now()+interval '30 days',now()+interval '2 seconds',:A))->>'outcome'='updated','reversal applied');
reset role;
select test.assert(pg_temp.available(:A)=1560,'reversal restores the refunded credits (1600 - 40 spent)');
select test.assert((select count(*)=1 from app_private.credit_ledger where entry_key like 'store-revoke:%')
 and (select count(*)=1 from app_private.credit_ledger where entry_key like 'store-reinstate:%'),'one revocation and one reinstatement entry');
-- A renewal-date extension (beyond a month) followed by a refund is still applied.
set role service_role;
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('1002','1001',:standard,now(),now()+interval '70 days',now()+interval '3 seconds',:A))
 ->>'outcome'='updated','extended period recorded');
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('1002','1001',:standard,now(),now()+interval '70 days',now()+interval '4 seconds',:A,now()))
 ->>'outcome'='updated','refund after an extension applied');
reset role;
select test.assert(pg_temp.available(:A)=760,'the extended period''s refund removed its credits');

-- Restored history: an ended period grants nothing; a refunded first sight grants nothing until the refund is reversed.
set role service_role;
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('1000','1001',:standard,now()-interval '60 days',now()-interval '30 days',now(),:A))
 @> '{"outcome":"recorded","credits":0}','ended period recorded without credits');
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('3001','3001',:pack,now(),null,now(),:A,now(),'Consumable'))
 @> '{"outcome":"recorded","credits":0}','refunded pack recorded without credits');
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('3001','3001',:pack,now(),null,now()+interval '1 second',:A,null,'Consumable'))
 ->>'outcome'='updated','reversal of a refund seen first');
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('3001','3001',:pack,now(),null,now()-interval '1 second',:A,null,'Consumable'))
 ->>'outcome'='already_recorded','the original copy afterwards grants nothing more');
reset role;
select test.assert((select credits=400 and bucket_id is not null from app_private.store_transactions where transaction_id='3001'),'reversal granted the pack');

-- A credit pack bought twice at once: 800 credits that never expire.
set role service_role;
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('3002','3002',:pack,now(),null,now(),:A,null,'Consumable',2))
 @> '{"outcome":"recorded","credits":800}','pack quantity 2');
reset role;
select test.assert((select bool_and(expires_at is null) from app_private.credit_buckets where source='purchased' and account_id=:A),'pack credits never expire');

-- Shapes the store does not sell.
set role service_role;
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('4001','4001','com.sciencereader.ios.unknown',now(),now()+interval '30 days',now(),:A))
 ->>'outcome'='unknown_product','unknown product');
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('4002','4002',:pack,now(),null,now(),:A,null,'Non-Consumable'))
 ->>'outcome'='unsupported','wrong product type');
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('4003','4003',:standard,now(),now()+interval '30 days',now(),:A,null,'Auto-Renewable Subscription',null,'Production','FAMILY_SHARED'))
 ->>'outcome'='unsupported','family sharing');
select test.reject($q$select public.worker_record_store_transaction('18000000-0000-0000-0000-00000000000a',
 pg_temp.tx('abc','4005','com.sciencereader.ios.standard.monthly',now(),now()+interval '30 days',now()))$q$,'invalid_store_transaction');
select test.reject($q$select public.worker_record_store_transaction('18000000-0000-0000-0000-00000000000a',
 pg_temp.tx('4006','4006','com.sciencereader.ios.standard.monthly',now(),now()+interval '30 days',now()+interval '2 hours'))$q$,'invalid_store_transaction');
select test.reject($q$select public.worker_record_store_transaction('18000000-0000-0000-0000-00000000000a',
 pg_temp.tx('4007','4007','com.sciencereader.ios.credits.400',now(),null,now(),null,null,'Consumable',null,'Xcode'))$q$,'invalid_store_transaction');
-- A notification with no token and no binding waits for the app, but its refund is remembered.
select test.assert(public.worker_record_store_notification('Production','18900000-0000-0000-0000-000000000006','REFUND',null,now(),
 pg_temp.tx('5001','5001',:pack,now()-interval '1 day',null,now(),null,now(),'Consumable'))->>'outcome'='unattributed','unattributed refund');
select test.assert(public.worker_record_store_transaction(:A,pg_temp.tx('5001','5001',:pack,now()-interval '1 day',null,now()-interval '1 day',:A,null,'Consumable'))
 @> '{"outcome":"recorded","credits":0}','the pre-refund copy reported later grants nothing');
select test.assert(public.worker_record_store_notification('Production','18900000-0000-0000-0000-000000000007','TEST',null,now(),null)->>'outcome'='no_transaction','test notification');
reset role;
select test.assert((select count(*)=2 from app_private.store_notifications where notification_uuid in
 ('18900000-0000-0000-0000-000000000006','18900000-0000-0000-0000-000000000007')),'notifications logged');

-- Upgrade: Standard then Pro mid-period gives Pro's credits; Standard's unspent credits end.
set role service_role;
select public.worker_record_store_transaction(:G,pg_temp.tx('9001','9001',:standard,now()-interval '10 days',now()+interval '20 days',now(),:G));
select test.assert(public.worker_record_store_transaction(:G,pg_temp.tx('9002','9001',:pro,now(),now()+interval '30 days',now(),:G))
 @> '{"outcome":"recorded","credits":1800}','upgrade grants Pro');
reset role;
select test.assert(pg_temp.available(:G)=1800,'the replaced Standard period''s credits ended');
-- Reported in the other order: the replaced Standard period grants nothing.
set role service_role;
select public.worker_record_store_transaction(:H,pg_temp.tx('9102','9101',:pro,now(),now()+interval '30 days',now(),:H));
select test.assert(public.worker_record_store_transaction(:H,pg_temp.tx('9101','9101',:standard,now()-interval '10 days',now()+interval '20 days',now(),:H))
 @> '{"outcome":"recorded","credits":0}','a replaced period reported late grants nothing');
reset role;
select test.assert(pg_temp.available(:H)=1800,'H has Pro''s credits only');

-- A refunded Standard period replaced by Pro stays ended when Apple reverses the refund.
set role service_role;
select public.worker_record_store_transaction(:K,pg_temp.tx('9201','9201',:standard,now()-interval '10 days',now()+interval '20 days',now(),:K));
select public.worker_record_store_transaction(:K,pg_temp.tx('9201','9201',:standard,now()-interval '10 days',now()+interval '20 days',now()+interval '1 second',:K,now()));
select public.worker_record_store_transaction(:K,pg_temp.tx('9202','9201',:pro,now(),now()+interval '30 days',now(),:K,reason=>'PURCHASE'));
select test.assert(public.worker_record_store_transaction(:K,pg_temp.tx('9201','9201',:standard,now()-interval '10 days',now()+interval '20 days',now()+interval '2 seconds',:K))
 ->>'outcome'='updated','reversal of a replaced period recorded');
reset role;
select test.assert(pg_temp.available(:K)=1800,'a reversed refund does not restore a period an upgrade replaced');
-- A downgrade takes effect at renewal (reason RENEWAL), even if charged early: both periods keep their credits.
set role service_role;
select public.worker_record_store_transaction(:N,pg_temp.tx('9301','9301',:pro,now()-interval '28 days',now()+interval '2 days',now(),:N));
select test.assert(public.worker_record_store_transaction(:N,pg_temp.tx('9302','9301',:standard,now(),now()+interval '30 days',now(),:N,reason=>'RENEWAL'))
 ->>'credits'='800','renewal into Standard granted');
reset role;
select test.assert(pg_temp.available(:N)=2600,'a renewal does not end the current period');

-- Sandbox purchases (free) grant at most 1,000 credits per account per month.
set role service_role;
select test.assert(public.worker_record_store_transaction(:I,pg_temp.tx('7101','7101',:pack,now(),null,now(),:I,null,'Consumable',null,'Sandbox',apptx=>'553'))->>'credits'='400','sandbox pack 1');
select test.assert(public.worker_record_store_transaction(:I,pg_temp.tx('7102','7102',:pack,now(),null,now(),:I,null,'Consumable',null,'Sandbox',apptx=>'553'))->>'credits'='400','sandbox pack 2');
select test.assert(public.worker_record_store_transaction(:I,pg_temp.tx('7103','7103',:pack,now(),null,now(),:I,null,'Consumable',null,'Sandbox',apptx=>'553'))->>'credits'='200','sandbox pack 3 capped');
select test.assert(public.worker_record_store_transaction(:I,pg_temp.tx('7104','7104',:pack,now(),null,now(),:I,null,'Consumable',null,'Sandbox',apptx=>'553'))
 @> '{"outcome":"recorded","credits":0}','sandbox cap reached');
reset role;
select test.assert(pg_temp.available(:I)=1000,'sandbox credits capped at 1,000');
-- The cap also follows the Apple Account across app accounts.
set role service_role;
select public.worker_record_store_transaction(:L,pg_temp.tx('7201','7201',:pack,now(),null,now(),:L,null,'Consumable',2,'Sandbox',apptx=>'555'));
select test.assert(public.worker_record_store_transaction(:M,pg_temp.tx('7202','7202',:pack,now(),null,now(),:M,null,'Consumable',null,'Sandbox',apptx=>'555'))
 ->>'credits'='200','second app account on the same Apple Account shares the cap');
reset role;

-- B subscribes, deletes the account, then restores the purchase on new account C.
set role service_role;
select test.assert(public.worker_record_store_transaction(:B,pg_temp.tx('6001','6001',:standard,now()-interval '1 minute',now()+interval '30 days',now(),:B))
 ->>'outcome'='recorded','B subscribes');
select public.worker_delete_account_begin(:B);
select test.assert(public.worker_record_store_notification('Production','18900000-0000-0000-0000-000000000008','DID_RENEW',null,now(),
 pg_temp.tx('6002','6001',:standard,now(),now()+interval '30 days',now(),:B))->>'outcome'='account_closed','renewal for a deleted account grants nothing');
select test.assert(public.worker_record_store_transaction(:C,pg_temp.tx('6002','6001',:standard,now(),now()+interval '30 days',now()+interval '1 second',:B))
 ->>'outcome'='recorded','C restores the deleted account''s purchase');
-- E's purchase never reached the server before E was deleted; C restores it too.
select public.worker_delete_account_begin(:E);
select test.assert(public.worker_record_store_transaction(:C,pg_temp.tx('6101','6101',:pack,now(),null,now(),:E,null,'Consumable'))
 @> '{"outcome":"recorded","credits":400}','a never-reported purchase of a deleted account moves to C');
reset role;
select test.assert((select account_id=:C and previous_account_id=:B from app_private.store_owners where original_transaction_id='6001'),'purchase moved to C');
select test.assert((select account_id=:C and previous_account_id=:E from app_private.store_owners where original_transaction_id='6101'),'unreported purchase moved to C');
select test.assert(pg_temp.available(:C)=1200,'C receives the current period and the pack');
select test.assert((select account_id=:B from app_private.store_transactions where transaction_id='6001'),'history stays with the deleted account');
rollback;
