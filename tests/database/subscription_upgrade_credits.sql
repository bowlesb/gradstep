-- The owner-approved upgrade rule. Local disposable database only; no Apple calls.
create function pg_temp.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create function pg_temp.tx(tid text,otid text,product text,a uuid,purchased timestamptz,expires timestamptz,signed timestamptz,
 revoked timestamptz default null,env text default 'Production',apptx text default null,reason text default 'PURCHASE')
returns jsonb language sql as $$
 select jsonb_strip_nulls(jsonb_build_object('environment',env,'transaction_id',tid,'original_transaction_id',otid,
  'product_id','com.sciencereader.ios.'||product,'type','Auto-Renewable Subscription','quantity',1,
  'purchase_date',(extract(epoch from purchased)*1000)::bigint,'expires_date',(extract(epoch from expires)*1000)::bigint,
  'signed_date',(extract(epoch from signed)*1000)::bigint,'revocation_date',(extract(epoch from revoked)*1000)::bigint,
  'app_account_token',a,'app_transaction_id',apptx,'reason',reason))
$$;
create function pg_temp.available(a uuid) returns bigint language sql as $$
 select coalesce(sum(balance-reserved) filter(where revoked_at is null and starts_at<=now()
  and (expires_at is null or expires_at>now())),0) from app_private.credit_buckets where account_id=a
$$;
create function pg_temp.financial_fingerprint() returns text language sql as $$
 select md5(jsonb_build_object(
  'buckets',(select jsonb_agg(to_jsonb(b) order by id) from app_private.credit_buckets b),
  'ledger',(select jsonb_agg(to_jsonb(l) order by id) from app_private.credit_ledger l),
  'transactions',(select jsonb_agg(to_jsonb(t) order by environment,transaction_id) from app_private.store_transactions t),
  'seen',(select jsonb_agg(to_jsonb(s) order by environment,transaction_id) from app_private.store_seen s),
  'sandbox',(select jsonb_agg(to_jsonb(d) order by transaction_id,period,reason) from app_private.store_sandbox_decisions d))::text)
$$;

begin;
insert into auth.users(id) values('44000000-0000-0000-0000-000000000001');
set role service_role;
select public.worker_record_store_transaction('44000000-0000-0000-0000-000000000001',
 pg_temp.tx('44001','44001','standard.monthly','44000000-0000-0000-0000-000000000001',
 now()-interval '10 days',now()+interval '20 days',now()));
select public.worker_record_store_transaction('44000000-0000-0000-0000-000000000001',
 pg_temp.tx('44002','44001','pro.monthly','44000000-0000-0000-0000-000000000001',
 now(),now()+interval '30 days',now()));
reset role;
select pg_temp.assert(pg_temp.available('44000000-0000-0000-0000-000000000001')=2600,
 'Upgrade must retain the old 800 credits until their original expiry (expected2600, old recorder leaves1800)');
select pg_temp.assert((select b.revoked_at is null and b.expires_at=t.expires_at
 from app_private.credit_buckets b join app_private.store_transactions t on t.bucket_id=b.id
 where t.environment='Production' and t.transaction_id='44001'),'Old period retains its original expiry and is not revoked');

-- The opposite arrival order, exact/older/newer replays and notification UUIDs
-- must neither lose the old allowance nor create another grant.
do $$ declare a uuid:=gen_random_uuid(); old jsonb; upgrade jsonb; result jsonb; notice uuid:=gen_random_uuid();
begin
 insert into auth.users(id) values(a);
 old:=pg_temp.tx('44101','44101','standard.monthly',a,now()-interval '10 days',now()+interval '20 days',now());
 upgrade:=pg_temp.tx('44102','44101','pro.monthly',a,now(),now()+interval '30 days',now());
 perform public.worker_record_store_notification('Production',notice,'DID_CHANGE_RENEWAL_PREF','UPGRADE',now(),upgrade);
 result:=public.worker_record_store_transaction(a,old);
 perform pg_temp.assert(result->>'credits'='800' and pg_temp.available(a)=2600,'Late first sight retains the old unexpired allowance');
 perform pg_temp.assert(public.worker_record_store_notification('Production',notice,'DID_CHANGE_RENEWAL_PREF','UPGRADE',now(),upgrade)->>'duplicate'='true','Notification UUID is idempotent');
 perform public.worker_record_store_transaction(a,upgrade);
 perform public.worker_record_store_transaction(a,old||jsonb_build_object('signed_date',(old->>'signed_date')::bigint-1000));
 perform public.worker_record_store_transaction(a,old||jsonb_build_object('signed_date',(old->>'signed_date')::bigint+1000));
 perform pg_temp.assert((select count(*)=2 from app_private.credit_ledger where account_id=a and kind='grant')
  and (select count(*)=2 from app_private.credit_buckets where account_id=a) and pg_temp.available(a)=2600,'All receipt orders grant exactly once');
 perform set_config('request.jwt.claim.sub',a::text,true);
 perform pg_temp.assert(public.v1_store_summary()->>'plan'='pro','Retained credits do not change the current Pro plan');
end $$;

-- A held old allowance survives upgrade; later reservations still choose its
-- earlier expiry. Refund/settlement/reversal restores only unspent credits.
do $$ declare a uuid:=gen_random_uuid(); old jsonb; upgrade jsonb; b uuid; original_expiry timestamptz;
 hold uuid:=gen_random_uuid(); next_hold uuid:=gen_random_uuid(); actual bigint; old_ledger_count bigint;
begin
 insert into auth.users(id) values(a);
 perform public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
 old:=pg_temp.tx('44201','44201','standard.monthly',a,now()-interval '10 days',now()+interval '20 days',now());
 upgrade:=pg_temp.tx('44202','44201','pro.monthly',a,now(),now()+interval '30 days',now());
 perform public.worker_record_store_transaction(a,old);
 select id,expires_at into strict b,original_expiry from app_private.credit_buckets where account_id=a;
 perform public.worker_reserve_operation(a,hold,'chat',sha256('upgrade-held'),'beta-credits-v1',50,250000);
 perform public.worker_mark_submitted(a,hold);
 select count(*) into old_ledger_count from app_private.credit_ledger where bucket_id=b;
 perform public.worker_record_store_transaction(a,upgrade);
 perform pg_temp.assert((select balance=800 and reserved=50 and expires_at=original_expiry and revoked_at is null from app_private.credit_buckets where id=b)
  and (select count(*)=old_ledger_count from app_private.credit_ledger where bucket_id=b),'Upgrade never touches the prior hold, balance, expiry or ledger');
 perform public.worker_reserve_operation(a,next_hold,'chat',sha256('upgrade-next-hold'),'beta-credits-v1',10,50000);
 perform pg_temp.assert((select bucket_id=b and credits=10 from app_private.reservation_allocations where account_id=a and operation_id=next_hold),'Next hold spends the earlier retained period first');
 perform public.worker_record_store_transaction(a,old||jsonb_build_object('revocation_date',(old->>'signed_date')::bigint,'signed_date',(old->>'signed_date')::bigint+1000));
 perform pg_temp.assert((select balance=60 and reserved=60 and revoked_at is not null from app_private.credit_buckets where id=b)
  and pg_temp.available(a)=1800,'A real old-period refund retains only its existing holds');
 perform public.worker_record_store_transaction(a,old);
 perform pg_temp.assert(pg_temp.available(a)=1800,'Old signed receipt cannot reverse refund');
 perform public.worker_settle_operation(a,hold,20,100000);
 perform public.worker_settle_operation(a,next_hold,0,0);
 perform public.worker_record_store_transaction(a,old||jsonb_build_object('signed_date',(old->>'signed_date')::bigint+2000));
 perform public.worker_record_store_transaction(a,old||jsonb_build_object('signed_date',(old->>'signed_date')::bigint+2000));
 perform pg_temp.assert(pg_temp.available(a)=2580 and (select balance=780 and reserved=0 and revoked_at is null and expires_at=original_expiry from app_private.credit_buckets where id=b),
  'Reversal restores exactly removed old credits, never spent credits, with original expiry');
 perform pg_temp.assert((select count(*)=1 from app_private.credit_ledger where bucket_id=b and entry_key like 'store-reinstate:%'),'Exact reversal replay appends once');
 perform public.worker_settle_operation(a,hold,20,100000);
 perform pg_temp.assert(pg_temp.available(a)=2580,'Settlement replay after reversal does not mint credits');
 perform public.worker_record_store_transaction(a,upgrade||jsonb_build_object('revocation_date',(upgrade->>'signed_date')::bigint,'signed_date',(upgrade->>'signed_date')::bigint+1000));
 perform pg_temp.assert(pg_temp.available(a)=780,'Refunding Pro does not remove retained Standard credits');
 perform public.worker_record_store_transaction(a,upgrade||jsonb_build_object('signed_date',(upgrade->>'signed_date')::bigint+2000));
 perform pg_temp.assert(pg_temp.available(a)=2580,'Pro reversal restores its own removed allowance only');
 -- The existing metadata-only extension behavior is deliberately unchanged.
 perform public.worker_record_store_transaction(a,old||jsonb_build_object('expires_date',(old->>'expires_date')::bigint+86400000,'signed_date',(old->>'signed_date')::bigint+3000));
 perform pg_temp.assert((select expires_at=original_expiry from app_private.credit_buckets where id=b),'A later signed expiry metadata change does not extend credit validity');
 perform pg_temp.assert(not exists(select 1 from app_private.credit_buckets c where c.account_id=a and
  (c.balance<>(select coalesce(sum(balance_delta),0) from app_private.credit_ledger where bucket_id=c.id)
   or c.reserved<>(select coalesce(sum(reserved_delta),0) from app_private.credit_ledger where bucket_id=c.id))), 'Ledger conservation after upgrade/refund/reversal/settlement');
end $$;

-- A previously refunded period can be reversed after the upgrade in either
-- first-sight order. Expired periods still never receive a first grant.
do $$ declare a uuid; old jsonb; upgrade jsonb; first_refunded boolean;
begin
 foreach first_refunded in array array[false,true] loop
  a:=gen_random_uuid(); insert into auth.users(id) values(a);
  old:=pg_temp.tx(case when first_refunded then '44311' else '44301' end,case when first_refunded then '44311' else '44301' end,
   'standard.monthly',a,now()-interval '10 days',now()+interval '20 days',now());
  upgrade:=pg_temp.tx(case when first_refunded then '44312' else '44302' end,old->>'original_transaction_id',
   'pro.monthly',a,now(),now()+interval '30 days',now());
  if not first_refunded then perform public.worker_record_store_transaction(a,old); end if;
  perform public.worker_record_store_transaction(a,old||jsonb_build_object('revocation_date',(old->>'signed_date')::bigint,'signed_date',(old->>'signed_date')::bigint+1000));
  perform public.worker_record_store_transaction(a,upgrade);
  perform public.worker_record_store_transaction(a,old||jsonb_build_object('signed_date',(old->>'signed_date')::bigint+2000));
  perform pg_temp.assert(pg_temp.available(a)=2600,'Old refund reversal after upgrade retains eligible original-period credits');
 end loop;
 a:=gen_random_uuid(); insert into auth.users(id) values(a);
 old:=pg_temp.tx('44321','44321','standard.monthly',a,now()-interval '31 days',now()-interval '1 day',now());
 perform public.worker_record_store_transaction(a,old||jsonb_build_object('revocation_date',(old->>'signed_date')::bigint));
 perform public.worker_record_store_transaction(a,pg_temp.tx('44322','44321','pro.monthly',a,now(),now()+interval '30 days',now()));
 perform public.worker_record_store_transaction(a,old||jsonb_build_object('signed_date',(old->>'signed_date')::bigint+1000));
 perform pg_temp.assert(pg_temp.available(a)=1800 and (select bucket_id is null and credits=0 from app_private.store_transactions where environment='Production' and transaction_id='44321'),
  'Reversing a first-seen expired refund creates no bucket');
 perform public.worker_record_store_transaction(a,pg_temp.tx('44323','44321','standard.monthly',a,now()-interval '61 days',now()-interval '31 days',now()));
 perform pg_temp.assert(pg_temp.available(a)=1800,'Expired restored history adds no credits');
end $$;

-- Sandbox keeps both dimensions of the exact same1,000-credit monthly cap.
-- Retention is not a way to recycle a refund or bypass verified identity.
do $$ declare a uuid:=gen_random_uuid(); other_account uuid:=gen_random_uuid(); old jsonb; upgrade jsonb; r jsonb; rejected boolean:=false;
begin
 insert into auth.users(id) values(a),(other_account);
 old:=pg_temp.tx('44401','44401','standard.monthly',a,now()-interval '10 days',now()+interval '20 days',now(),env=>'Sandbox',apptx=>'4449001');
 upgrade:=pg_temp.tx('44402','44401','pro.monthly',a,now(),now()+interval '30 days',now(),env=>'Sandbox',apptx=>'4449001');
 perform public.worker_record_store_transaction(a,old);
 r:=public.worker_record_store_transaction(a,upgrade);
 perform pg_temp.assert(r->>'credits'='200' and pg_temp.available(a)=1000,'Sandbox upgrade retains800 and grants only remaining200');
 perform public.worker_record_store_transaction(a,old||jsonb_build_object('revocation_date',(old->>'signed_date')::bigint,'signed_date',(old->>'signed_date')::bigint+1000));
 r:=public.worker_record_store_transaction(a,pg_temp.tx('44403','44403','standard.monthly',a,now(),now()+interval '30 days',now(),env=>'Sandbox',apptx=>'4449002'));
 perform pg_temp.assert(r->>'credits'='0','New Apple identity cannot reset the same account cap after refund');
 r:=public.worker_record_store_transaction(other_account,pg_temp.tx('44404','44404','standard.monthly',other_account,now(),now()+interval '30 days',now(),env=>'Sandbox',apptx=>'4449001'));
 perform pg_temp.assert(r->>'credits'='0','New app account cannot reset Apple identity cap after refund');
 perform public.worker_record_store_transaction(a,old||jsonb_build_object('signed_date',(old->>'signed_date')::bigint+2000));
 perform pg_temp.assert(pg_temp.available(a)=1000 and (select sum(credits)=1000 from app_private.store_transactions where environment='Sandbox' and account_id=a),'Reversal restores prior allowance without replenishing admission');
 begin
  perform public.worker_record_store_transaction(a,upgrade||jsonb_build_object('app_transaction_id','4449999','signed_date',(upgrade->>'signed_date')::bigint+3000));
 exception when others then if sqlerrm<>'store_transaction_conflict' then raise; end if; rejected:=true; end;
 perform pg_temp.assert(rejected,'Changed verified Apple identity is rejected');
 a:=gen_random_uuid(); insert into auth.users(id) values(a);
 r:=public.worker_record_store_transaction(a,pg_temp.tx('44411','44411','standard.monthly',a,now()-interval '10 days',now()+interval '20 days',now(),env=>'Sandbox'));
 perform pg_temp.assert(r->>'credits'='0','No verified Sandbox identity means zero grant');
 r:=public.worker_record_store_transaction(a,pg_temp.tx('44412','44411','pro.monthly',a,now(),now()+interval '30 days',now(),env=>'Sandbox'));
 perform pg_temp.assert(r->>'credits'='0' and pg_temp.available(a)=0,'Upgrade cannot bypass a missing Sandbox identity');
end $$;

-- Already-recorded credits remain forfeited on their closed owner. Restoring
-- the purchase binding and a later plan grant does not transfer the old bucket.
do $$ declare old_account uuid:=gen_random_uuid(); new_account uuid:=gen_random_uuid(); old jsonb; b uuid; before_bucket jsonb; rejected boolean:=false;
begin
 insert into auth.users(id) values(old_account),(new_account);
 old:=pg_temp.tx('44501','44501','standard.monthly',old_account,now()-interval '10 days',now()+interval '20 days',now());
 perform public.worker_record_store_transaction(old_account,old);
 select id into strict b from app_private.credit_buckets where account_id=old_account;
 perform public.worker_delete_account_begin(old_account);
 select to_jsonb(c) into before_bucket from app_private.credit_buckets c where id=b;
 perform public.worker_record_store_transaction(new_account,old);
 perform public.worker_record_store_transaction(new_account,pg_temp.tx('44502','44501','pro.monthly',new_account,now(),now()+interval '30 days',now()));
 perform public.worker_record_store_transaction(new_account,old||jsonb_build_object('signed_date',(old->>'signed_date')::bigint+1000));
 perform pg_temp.assert(pg_temp.available(new_account)=1800 and (select to_jsonb(c)=before_bucket from app_private.credit_buckets c where id=b)
  and (select closed_at is not null from app_private.accounts where id=old_account),
  'Restore never transfers or reinstates a deleted owner bucket');
 begin
  perform public.worker_reserve_operation(old_account,gen_random_uuid(),'chat',sha256('closed-upgrade'),'beta-credits-v1',1,5000);
 exception when others then if sqlerrm<>'account_unavailable' then raise; end if; rejected:=true; end;
 perform pg_temp.assert(rejected,'Closed account cannot spend its retained accounting balance');
end $$;

-- Preserve the existing first-seen deleted-token restore rule. An unreported
-- valid purchase has never granted/forfeited credits; already-recorded history,
-- even a zero grant, stays on its original closed account.
do $$ declare old_account uuid:=gen_random_uuid(); new_account uuid:=gen_random_uuid(); old jsonb; zero_grant jsonb;
begin
 insert into auth.users(id) values(old_account),(new_account);
 zero_grant:=pg_temp.tx('44511','44511','standard.monthly',old_account,now()-interval '10 days',now()+interval '20 days',now(),revoked=>now());
 perform public.worker_record_store_transaction(old_account,zero_grant);
 perform public.worker_delete_account_begin(old_account);
 perform public.worker_record_store_transaction(new_account,zero_grant);
 perform public.worker_record_store_transaction(new_account,pg_temp.tx('44512','44511','pro.monthly',new_account,now(),now()+interval '30 days',now()));
 perform public.worker_record_store_transaction(new_account,(zero_grant-'revocation_date')||jsonb_build_object('signed_date',(zero_grant->>'signed_date')::bigint+1000));
 perform pg_temp.assert((select account_id=old_account and credits=0 and bucket_id is null from app_private.store_transactions where environment='Production' and transaction_id='44511')
  and pg_temp.available(new_account)=1800,'Previously recorded zero grant never moves or grants on a closed account');
 old:=pg_temp.tx('44521','44521','standard.monthly',old_account,now()-interval '10 days',now()+interval '20 days',now());
 perform public.worker_record_store_transaction(new_account,pg_temp.tx('44522','44521','pro.monthly',old_account,now(),now()+interval '30 days',now()));
 perform public.worker_record_store_transaction(new_account,old);
 perform public.worker_record_store_transaction(new_account,old);
 perform pg_temp.assert((select account_id=new_account and credits=800 from app_private.store_transactions where environment='Production' and transaction_id='44521')
  and (select count(*)=1 from app_private.credit_ledger l join app_private.store_transactions t on t.bucket_id=l.bucket_id where t.environment='Production' and t.transaction_id='44521' and l.kind='grant'),
  'Never-recorded valid prior period receives one grant under existing deleted-token restore rule');
end $$;

-- Every accepted copy must retain known-product terms. The old recorder checked
-- these only on first sight: a refunded-first subscription followed by a newer
-- reversal missing expiry could mint a non-expiring bucket. Include Sandbox's
-- missing-identity rows, so an unsupported receipt cannot fill identity either.
do $$ declare a uuid; old jsonb; upgrade jsonb; reversal jsonb; pack jsonb; bad jsonb; item jsonb;
 store_environment text; before_state text; result jsonb; rejected boolean;
begin
 foreach store_environment in array array['Production','Sandbox'] loop
  a:=gen_random_uuid(); insert into auth.users(id) values(a);
  old:=pg_temp.tx('44701','44701','standard.monthly',a,now()-interval '10 days',now()+interval '20 days',now(),revoked=>now(),env=>store_environment);
  upgrade:=pg_temp.tx('44702','44701','pro.monthly',a,now(),now()+interval '30 days',now(),env=>store_environment,apptx=>'4479001');
  perform public.worker_record_store_transaction(a,old);
  perform public.worker_record_store_transaction(a,upgrade);
  reversal:=(old-'revocation_date')||jsonb_build_object('signed_date',(old->>'signed_date')::bigint+1000,'app_transaction_id','4479001');
  for bad in select value from jsonb_array_elements(jsonb_build_array(
   reversal-'expires_date', reversal||'{"expires_date":null}'::jsonb,
   reversal||'{"type":"Consumable"}'::jsonb, reversal||'{"quantity":2}'::jsonb,
   reversal||'{"ownership":"FAMILY_SHARED"}'::jsonb,
   reversal||jsonb_build_object('expires_date',(old->>'purchase_date')::bigint+401*86400000::bigint))) loop
   before_state:=pg_temp.financial_fingerprint();
   result:=public.worker_record_store_transaction(a,bad);
   perform pg_temp.assert(result->>'outcome'='unsupported' and pg_temp.financial_fingerprint()=before_state,
    store_environment||' malformed subscription reversal changes no bucket, ledger, receipt, newest state, identity or allowance');
  end loop;
  perform pg_temp.assert((select bucket_id is null and credits=0 and app_transaction_id is null from app_private.store_transactions
   where store_transactions.environment=store_environment and transaction_id='44701'), 'Refused reversal cannot mint credits or fill missing identity');
  perform public.worker_record_store_transaction(a,reversal);
  perform pg_temp.assert(pg_temp.available(a)=case when store_environment='Sandbox' then 1000 else 2600 end,
   'Later valid reversal retains normal grants and Sandbox allowance');
  perform pg_temp.assert(not exists(select 1 from app_private.credit_buckets where account_id=a and source='subscription' and expires_at is null),
   'No subscription bucket has perpetual credit validity');
  pack:=(old-'expires_date')||jsonb_build_object('transaction_id','44711','original_transaction_id','44711',
   'product_id','com.sciencereader.ios.credits.400','type','Consumable');
  perform public.worker_record_store_transaction(a,pack);
  reversal:=(pack-'revocation_date')||jsonb_build_object('signed_date',(pack->>'signed_date')::bigint+1000,'app_transaction_id','4479001');
  for bad in select value from jsonb_array_elements(jsonb_build_array(
   reversal||jsonb_build_object('expires_date',(old->>'expires_date')::bigint),
   reversal||'{"type":"Auto-Renewable Subscription"}'::jsonb,
   reversal||'{"quantity":0}'::jsonb, reversal||'{"quantity":11}'::jsonb,
   reversal||'{"ownership":"FAMILY_SHARED"}'::jsonb)) loop
   before_state:=pg_temp.financial_fingerprint();
   result:=public.worker_record_store_transaction(a,bad);
   perform pg_temp.assert(result->>'outcome'='unsupported' and pg_temp.financial_fingerprint()=before_state,
    store_environment||' malformed consumable reversal changes no financial or identity state');
  end loop;
  -- The private grant has its own guard even if a future internal caller omits
  -- the recorder's product validation. It is not callable by service clients.
  before_state:=pg_temp.financial_fingerprint(); rejected:=false;
  begin
   perform app_private.store_grant(store_environment,'44721','44721',a,'com.sciencereader.ios.standard.monthly',1,
    now(),null,'PURCHASE','4479001');
  exception when others then if sqlerrm<>'invalid_store_transaction' then raise; end if; rejected:=true; end;
  perform pg_temp.assert(rejected and pg_temp.financial_fingerprint()=before_state,'Private subscription grant rejects missing expiry without writes');
 end loop;
end $$;

select pg_temp.assert(not has_function_privilege('authenticated','app_private.store_grant(text,text,text,uuid,text,integer,timestamptz,timestamptz,text,text)','EXECUTE')
 and not has_function_privilege('service_role','app_private.record_store_transaction_locked(text,uuid,jsonb)','EXECUTE'), 'Private financial helpers remain inaccessible directly');
select pg_temp.assert(has_function_privilege('service_role','public.worker_record_store_transaction(uuid,jsonb)','EXECUTE')
 and not has_function_privilege('authenticated','public.worker_record_store_transaction(uuid,jsonb)','EXECUTE'),'Public recording remains service-only');
rollback;

-- Cross a real expiry boundary between transactions. No artificial production
-- clock override or bucket-date update: the local database is dropped afterwards.
create temp table upgrade_expiry_fixture(account_id uuid, old_receipt jsonb, bucket_id uuid, original_expiry timestamptz);
do $$ declare a uuid:=gen_random_uuid(); old jsonb;
begin
 insert into auth.users(id) values(a);
 old:=pg_temp.tx('44601','44601','standard.monthly',a,now()-interval '30 days',now()+interval '1 second',now());
 perform public.worker_record_store_transaction(a,old);
 perform public.worker_record_store_transaction(a,pg_temp.tx('44602','44601','pro.monthly',a,now(),now()+interval '30 days',now()));
 insert into upgrade_expiry_fixture select a,old,id,expires_at from app_private.credit_buckets where account_id=a and balance=800;
 perform pg_temp.assert(pg_temp.available(a)=2600,'Old credits retained immediately before natural expiry');
end $$;
select pg_sleep(least(2,greatest(0,extract(epoch from (original_expiry-clock_timestamp())))+0.05)) from upgrade_expiry_fixture;
do $$ declare e upgrade_expiry_fixture; newer bigint;
begin
 select * into strict e from upgrade_expiry_fixture;
 perform set_config('request.jwt.claim.sub',e.account_id::text,true);
 perform pg_temp.assert(public.v1_credit_balance()->>'available'='1800','Actual credit API excludes the naturally expired old period');
 newer:=(extract(epoch from clock_timestamp())*1000)::bigint;
 perform public.worker_record_store_transaction(e.account_id,e.old_receipt||jsonb_build_object('revocation_date',newer,'signed_date',newer));
 perform public.worker_record_store_transaction(e.account_id,e.old_receipt||jsonb_build_object('signed_date',newer+1000));
 perform pg_temp.assert((select balance=800 and revoked_at is null and expires_at=e.original_expiry from app_private.credit_buckets where id=e.bucket_id)
  and public.v1_credit_balance()->>'available'='1800','Expired refund reversal restores accounting balance only, never spendability or expiry');
end $$;
