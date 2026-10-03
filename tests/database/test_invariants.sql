create schema test;
grant usage on schema test to anon,authenticated,service_role;
create function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create function test.reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin
 begin execute statement;
 exception when others then
   if position(expected in sqlerrm)=0 then raise exception 'Unexpected rejection: % (wanted %)',sqlerrm,expected; end if;
   rejected:=true;
 end;
 if not rejected then raise exception 'Expected rejection: %',expected; end if;
end $$;
grant execute on all functions in schema test to anon,authenticated,service_role;
insert into auth.users values('00000000-0000-0000-0000-000000000001'),('00000000-0000-0000-0000-000000000002');

select test.assert(not exists(select 1 from pg_tables where schemaname='app_private' and not rowsecurity),'RLS enabled on every private table');
set role anon;
select test.reject('select public.v1_library()','permission denied');
select test.reject('select * from app_private.accounts','permission denied');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
select test.reject('select * from app_private.accounts','permission denied');
select test.reject($q$select public.worker_grant_credits('00000000-0000-0000-0000-000000000001','trial','cheat',1000,now(),null,'cheat')$q$,'permission denied');
select test.assert(public.v1_bootstrap_keys('10000000-0000-0000-0000-000000000001',decode(repeat('11',32),'hex'),decode(repeat('22',60),'hex'),decode(repeat('33',32),'hex'),decode(repeat('44',92),'hex'),decode(repeat('aa',32),'hex')),'first bootstrap succeeds');
select test.assert(not public.v1_bootstrap_keys('10000000-0000-0000-0000-000000000002',decode(repeat('11',32),'hex'),decode(repeat('22',60),'hex'),decode(repeat('33',32),'hex'),decode(repeat('44',92),'hex'),decode(repeat('aa',32),'hex')),'second bootstrap does not overwrite keys');
select test.assert(public.v1_append_event('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',1,1,decode(repeat('55',60),'hex'),decode(repeat('33',32),'hex'))=1,'initial cursor');
select test.assert(public.v1_append_event('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',1,1,decode(repeat('55',60),'hex'),decode(repeat('33',32),'hex'))=1,'exact replay same cursor');
select test.reject($q$select public.v1_append_event('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',1,1,decode(repeat('66',60),'hex'),decode(repeat('33',32),'hex'))$q$,'event_id_conflict');
select test.reject($q$select public.v1_append_event('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002',1,1,decode(repeat('55',60),'hex'),decode(repeat('99',32),'hex'))$q$,'key_authority_required');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
select test.assert(public.v1_pull_events(0)='[]'::jsonb,'another account cannot read events');
select test.assert(public.v1_key_state('10000000-0000-0000-0000-000000000001') is null,'another account cannot read recovery envelope');
reset role;

insert into app_private.documents(id,sha256,scope,owner_id,byte_count,page_count) values('30000000-0000-0000-0000-000000000001',decode(repeat('aa',32),'hex'),'owner_private','00000000-0000-0000-0000-000000000001',100,1);
insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values('30000000-0000-0000-0000-000000000002',decode(repeat('bb',32),'hex'),'shared_catalog','{"license":"CC-BY-4.0"}',100,1);
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
select test.reject($q$select public.v1_set_library_item('30000000-0000-0000-0000-000000000001',true)$q$,'document_unavailable');
select public.v1_set_library_item('30000000-0000-0000-0000-000000000002',true);
select test.assert(jsonb_array_length(public.v1_library())=1,'shared item available to second account');
select public.v1_set_library_item('30000000-0000-0000-0000-000000000002',false);
select test.assert(jsonb_array_length(public.v1_library())=0,'account-scoped removal');
reset role;
select test.assert(exists(select 1 from app_private.documents where id='30000000-0000-0000-0000-000000000002'),'library removal preserves catalog');

insert into app_private.platform_budgets(period,limit_microusd,work_enabled) values(date_trunc('month',now() at time zone 'UTC')::date,1000000,true);
set role service_role;
select public.worker_grant_credits('00000000-0000-0000-0000-000000000001','trial','fixture',100,'2026-01-01',null,'Fixture grant');
select public.worker_grant_credits('00000000-0000-0000-0000-000000000001','trial','fixture',100,'2026-01-01',null,'Fixture grant');
select test.reject($q$select public.worker_grant_credits('00000000-0000-0000-0000-000000000002','trial','fixture',100,'2026-01-01',null,'Fixture grant')$q$,'grant_id_conflict');
select public.worker_reserve_operation('00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','chat',decode(repeat('cc',32),'hex'),'test-1',70,700000);
select test.assert((public.worker_reserve_operation('00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','chat',decode(repeat('cc',32),'hex'),'test-1',70,700000)->>'replayed')::boolean,'reservation replay');
select test.reject($q$select public.worker_reserve_operation('00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000002','chat',decode(repeat('cc',32),'hex'),'test-1',40,100000)$q$,'insufficient_credits');
select test.reject($q$select public.worker_reserve_operation('00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000002','chat',decode(repeat('cc',32),'hex'),'test-1',10,400000)$q$,'platform_budget_exhausted');
select public.worker_settle_operation('00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',20,100000);
select public.worker_settle_operation('00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',20,100000);
select test.reject($q$select public.worker_settle_operation('00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',10,100000)$q$,'settlement_id_conflict');
reset role;
select test.assert((select balance=80 and reserved=0 from app_private.credit_buckets where external_key='fixture'),'unused reservation released, capture only once');
select test.assert((select spent_microusd=100000 and reserved_microusd=0 from app_private.platform_budgets),'platform settlement reconciles');
select test.assert(not exists(select 1 from app_private.credit_buckets b join lateral(
 select sum(balance_delta) balance,sum(reserved_delta) reserved from app_private.credit_ledger l where l.bucket_id=b.id
) l on true where b.balance<>l.balance or b.reserved<>l.reserved),'ledger reconstructs materialized balances');
select test.reject('delete from app_private.credit_ledger','immutable_record');

-- Worker fencing and paid-submit ambiguity.
select public.worker_reserve_operation('00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000003','ocr',decode(repeat('dd',32),'hex'),'test-1',20,200000);
insert into app_private.ocr_runs(id,document_id,provider,options_sha256) values('50000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','stub',decode(repeat('ee',32),'hex'));
insert into app_private.processing_jobs(id,ocr_run_id,funding_account_id,operation_id) values('60000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000003');
set role service_role;
select test.assert((public.worker_claim_job()->>'lease_generation')::bigint=1,'first fenced lease');
select test.reject($q$select public.worker_transition_job('60000000-0000-0000-0000-000000000001',0,'claimed','submitting')$q$,'stale_job_lease');
select public.worker_transition_job('60000000-0000-0000-0000-000000000001',1,'claimed','submitting');
reset role;
update app_private.processing_jobs set lease_until=now()-interval '1 second' where id='60000000-0000-0000-0000-000000000001';
set role service_role;
select test.assert(public.worker_claim_job() is null,'uncertain submission is never blindly retried');
reset role;
select test.assert((select state='submission_uncertain' from app_private.processing_jobs where id='60000000-0000-0000-0000-000000000001'),'uncertain submission quarantined');
select test.assert((select reserved=20 from app_private.credit_buckets where external_key='fixture'),'uncertain submission retains its reserve');
