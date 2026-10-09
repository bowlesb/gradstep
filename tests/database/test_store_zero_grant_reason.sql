-- The diagnostic explanation is finite and read-only; it never changes the
-- receipt or credit ledger. The purchase fixture itself is rolled back.
begin;
insert into auth.users values('56000000-0000-0000-0000-000000000001');
create function pg_temp.tx(tid text, identity text, qty integer default 1)
returns jsonb language sql as $$
 select jsonb_build_object('environment','Sandbox','transaction_id',tid,'original_transaction_id',tid,
  'product_id','com.sciencereader.ios.credits.400','type','Consumable','quantity',qty,'ownership','PURCHASED',
  'purchase_date',(extract(epoch from now()-interval '1 minute')*1000)::bigint,
  'signed_date',(extract(epoch from now())*1000)::bigint,
  'app_account_token','56000000-0000-0000-0000-000000000001','app_transaction_id',identity)
$$;
set role service_role;
select public.worker_record_store_transaction('56000000-0000-0000-0000-000000000001',pg_temp.tx('560001','56001',1));
select public.worker_record_store_transaction('56000000-0000-0000-0000-000000000001',pg_temp.tx('560002','56001',1));
select public.worker_record_store_transaction('56000000-0000-0000-0000-000000000001',pg_temp.tx('560003','56001',1));
select test.assert(public.worker_record_store_transaction('56000000-0000-0000-0000-000000000001',pg_temp.tx('560004','56001',1))->>'credits'='0','Sandbox cap produces a final zero-credit record');
select test.assert(public.worker_store_zero_grant_reason('56000000-0000-0000-0000-000000000001','Sandbox','560004')='sandbox_monthly_cap','zero-credit record explains the Sandbox cap');
select test.assert(public.worker_store_zero_grant_reason('56000000-0000-0000-0000-000000000001','Sandbox','missing') is null,'missing records have no explanation');
reset role;
rollback;
