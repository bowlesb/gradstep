-- The owner-approved upgrade rule. Local disposable database only; no Apple calls.
begin;
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
rollback;
