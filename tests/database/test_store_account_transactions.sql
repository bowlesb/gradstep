-- Read-only owner ledger: no receipt-to-submission inference and no financial mutation.
begin;
insert into auth.users values('38100000-0000-0000-0000-000000000001'),('38100000-0000-0000-0000-000000000002'),
 ('38100000-0000-0000-0000-000000000003'),('38100000-0000-0000-0000-000000000009');
insert into app_private.app_roles values('38100000-0000-0000-0000-000000000003','support',now()),
 ('38100000-0000-0000-0000-000000000009','owner',now());
\set A '\'38100000-0000-0000-0000-000000000001\''
\set B '\'38100000-0000-0000-0000-000000000002\''
\set S '\'38100000-0000-0000-0000-000000000003\''
\set O '\'38100000-0000-0000-0000-000000000009\''
create function pg_temp.purchase(tid text,env text default 'Sandbox',product text default 'credits.400',identity text default '999001',
 revoked timestamptz default null,signed timestamptz default now()-interval '1 hour') returns jsonb language sql as $$
 select jsonb_strip_nulls(jsonb_build_object('environment',env,'transaction_id',tid,'original_transaction_id',tid,
  'product_id','com.sciencereader.ios.'||product,'quantity',1,
  'type',case when product='credits.400' then 'Consumable' else 'Auto-Renewable Subscription' end,
  'purchase_date',(extract(epoch from now()-interval '2 days')*1000)::bigint,
  'expires_date',case when product<>'credits.400' then (extract(epoch from now()+interval '1 day')*1000)::bigint end,
  'signed_date',(extract(epoch from signed)*1000)::bigint,'revocation_date',(extract(epoch from revoked)*1000)::bigint,
  'app_transaction_id',identity))
$$;

set role service_role;
select public.worker_record_store_transaction(:A,pg_temp.purchase('6101','Sandbox','standard.monthly'));
select public.worker_record_store_transaction(:A,pg_temp.purchase('6102'));
select public.worker_record_store_transaction(:A,pg_temp.purchase('6103'));
select public.worker_record_store_transaction(:A,pg_temp.purchase('6104','Sandbox','credits.400','999002'));
select public.worker_record_store_transaction(:A,pg_temp.purchase('6105','Sandbox','credits.400',null));
select public.worker_record_store_transaction(:A,pg_temp.purchase('7101','Production'));
select public.worker_record_store_transaction(:A,pg_temp.purchase('7102','Production','standard.monthly'));
select public.worker_record_store_transaction(:A,pg_temp.purchase('7103','Production'));
select public.worker_record_store_transaction(:A,pg_temp.purchase('7104','Production','credits.400',null,now()-interval '1 day'));
select public.worker_record_store_transaction(:B,pg_temp.purchase('8101','Production'));
reset role;
-- Synthetic held/consumed balances and elapsed time exercise the read projection;
-- the refund below runs the actual recorder so it must preserve in-flight credits.
update app_private.credit_buckets set reserved=60 where external_key='Sandbox:6101';
update app_private.credit_buckets set balance=160,reserved=20 where external_key='Sandbox:6102';
update app_private.credit_buckets set reserved=40 where external_key='Production:7101';
update app_private.credit_buckets set balance=600,reserved=20,expires_at=now()-interval '1 minute' where external_key='Production:7102';
update app_private.credit_buckets set balance=0 where external_key='Production:7103';
set role service_role;
select public.worker_record_store_transaction(:A,pg_temp.purchase('7101','Production','credits.400','999001',now()-interval '1 minute',now()));
reset role;
-- A previous allowance observation, and a newer one for a different account,
-- must not replace this account's actual latest decision.
insert into app_private.store_sandbox_decisions(transaction_id,period,account_id,reason,requested_credits,granted_credits,
 account_used_before,identity_used_before,credit_cap,created_at) values
 ('6103',(date_trunc('month',now())-interval '1 month')::date,:A,'account_allowance_exhausted',400,0,1000,0,1000,now()-interval '1 day'),
 ('6103',date_trunc('month',now())::date,:B,'identity_missing',400,0,0,0,1000,now()+interval '1 minute');

-- Equal timestamps and same transaction IDs in different environments prove the
-- complete tuple continuation, independent of a particular default page size.
insert into app_private.store_owners(environment,original_transaction_id,account_id,bound_by)
 select 'Production',(900000+n)::text,:A,'app' from generate_series(1,160) n;
insert into app_private.store_transactions(environment,transaction_id,original_transaction_id,account_id,product_id,quantity,
 purchased_at,signed_at,credits,recorded_at)
 select 'Production',(900000+n)::text,(900000+n)::text,:A,'com.sciencereader.ios.credits.400',1,
 now()-interval '31 days',now()-interval '30 days',0,now()-interval '30 days' from generate_series(1,160) n;
insert into app_private.store_owners(environment,original_transaction_id,account_id,bound_by) values('Sandbox','900100',:A,'app');
insert into app_private.store_transactions(environment,transaction_id,original_transaction_id,account_id,product_id,quantity,
 purchased_at,signed_at,credits,recorded_at) values('Sandbox','900100','900100',:A,'com.sciencereader.ios.credits.400',1,
 now()-interval '31 days',now()-interval '30 days',0,now()-interval '30 days');
create function pg_temp.financial_digest() returns text language sql as $$
 select md5(jsonb_build_array(
  (select jsonb_agg(to_jsonb(t) order by environment,transaction_id) from app_private.store_transactions t),
  (select jsonb_agg(to_jsonb(t) order by id) from app_private.credit_buckets t),
  (select jsonb_agg(to_jsonb(t) order by id) from app_private.credit_ledger t),
  (select jsonb_agg(to_jsonb(t) order by account_id,transaction_id,period,reason) from app_private.store_sandbox_decisions t),
  (select jsonb_agg(to_jsonb(t) order by environment,original_transaction_id) from app_private.store_owners t),
  (select jsonb_agg(to_jsonb(t) order by environment,transaction_id) from app_private.store_seen t))::text)
$$;
select pg_temp.financial_digest() as before_read \gset

set role anon;
select test.reject($q$select public.v1_admin_store_account_transactions('38100000-0000-0000-0000-000000000001')$q$,'permission denied');
reset role;
set role service_role;
select set_config('request.jwt.claim.sub',:O,false);
select set_config('request.jwt.claim.aal','aal2',false);
select test.reject($q$select public.v1_admin_store_account_transactions('38100000-0000-0000-0000-000000000001')$q$,'permission denied');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub',:A,false);
select test.reject($q$select public.v1_admin_store_account_transactions('38100000-0000-0000-0000-000000000001')$q$,'owner_mfa_required');
select set_config('request.jwt.claim.sub',:S,false);
select test.reject($q$select public.v1_admin_store_account_transactions('38100000-0000-0000-0000-000000000001')$q$,'owner_mfa_required');
select set_config('request.jwt.claim.sub',:O,false);
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject($q$select public.v1_admin_store_account_transactions('38100000-0000-0000-0000-000000000001')$q$,'owner_mfa_required');
select set_config('request.jwt.claim.aal','aal2',false);
select public.v1_admin_store_account_transactions(:A,null,50) as first_page \gset
select test.assert(:'first_page'::jsonb->>'account_id'=:A,'ledger identifies the requested account');
select test.assert(jsonb_array_length(:'first_page'::jsonb->'transactions')=50,'first page bounded at 50');
select test.assert((:'first_page'::jsonb->'next_cursor') is distinct from 'null'::jsonb,'older page offered');
select test.assert(:'first_page' not like '%app_transaction_id%' and :'first_page' not like '%999001%','Apple app identity never returned');
select test.assert(jsonb_array_length(public.v1_admin_store_account_transactions(:B)->'transactions')=1,'other account has only its own transaction');
select test.assert(public.v1_admin_store_account_transactions(:O)->'transactions'='[]'::jsonb,'empty account ledger');
select test.assert(public.v1_admin_store_account_transactions(:O)->'next_cursor'='null'::jsonb,'empty page has no continuation');
select test.reject($q$select public.v1_admin_store_account_transactions(null)$q$,'invalid_store_ledger_query');
select test.reject($q$select public.v1_admin_store_account_transactions('38100000-0000-0000-0000-000000000001',null,51)$q$,'invalid_store_ledger_query');
select test.reject(format('select public.v1_admin_store_account_transactions(%L,%L::jsonb)',:B,:'first_page'::jsonb->'next_cursor'),'invalid_store_ledger_cursor');
select test.reject(format('select public.v1_admin_store_account_transactions(%L,%L::jsonb)',:A,
 (:'first_page'::jsonb->'next_cursor')||'{"extra":true}'),'invalid_store_ledger_cursor');
select test.reject(format('select public.v1_admin_store_account_transactions(%L,%L::jsonb)',:A,
 (:'first_page'::jsonb->'next_cursor')||'{"transaction_id":"no-such-row"}'),'invalid_store_ledger_cursor');
select test.reject(format('select public.v1_admin_store_account_transactions(%L,%L::jsonb)',:A,
 (:'first_page'::jsonb->'next_cursor')||'{"recorded_at":"infinity"}'),'invalid_store_ledger_cursor');
select test.reject(format('select public.v1_admin_store_account_transactions(%L,%L::jsonb)',:A,
 (:'first_page'::jsonb->'next_cursor')||'{"recorded_at":"2026-99-99T12:00:00Z"}'),'invalid_store_ledger_cursor');
select test.reject(format('select public.v1_admin_store_account_transactions(%L,%L::jsonb)',:A,
 (:'first_page'::jsonb->'next_cursor')||'{"recorded_at":"2000-01-01T12:00:00Z"}'),'invalid_store_ledger_cursor');
select test.reject(format('select public.v1_admin_store_account_transactions(%L,%L::jsonb)',:A,
 (:'first_page'::jsonb->'next_cursor')||'{"environment":"Other"}'),'invalid_store_ledger_cursor');
select test.reject(format('select public.v1_admin_store_account_transactions(%L,%L::jsonb)',:A,
 (:'first_page'::jsonb->'next_cursor')||'{"version":"1"}'),'invalid_store_ledger_cursor');
reset role;
create temporary table ledger_rows as select * from jsonb_array_elements(:'first_page'::jsonb->'transactions');
select test.assert((select value->'credits' @> '{"granted":800,"balance":800,"reserved":60,"spendable":740,"state":"active"}' from ledger_rows where value->>'transaction_id'='6101'),'active grant is separate from spendable/reserved');
select test.assert((select value->'credits' @> '{"granted":200,"balance":160,"reserved":20,"spendable":140}'
 and value->'sandbox_decision' @> '{"requested_credits":400,"granted_credits":200,"reason":"partial_allowance"}' from ledger_rows where value->>'transaction_id'='6102'),'partial actual grant and allowance reason');
select test.assert((select value->'credits' @> '{"granted":0,"spendable":0,"state":"no_grant"}'
 and value->'sandbox_decision'->>'reason'='both_allowances_exhausted' from ledger_rows where value->>'transaction_id'='6103'),'zero grant and latest same-account allowance decision');
select test.assert((select value->'sandbox_decision'->>'reason'='account_allowance_exhausted' from ledger_rows where value->>'transaction_id'='6104'),'account-only allowance exhaustion distinguished');
select test.assert((select value->'sandbox_decision'->>'reason'='identity_missing' from ledger_rows where value->>'transaction_id'='6105'),'missing identity reason is finite, identity itself absent');
select test.assert((select value->'credits' @> '{"granted":400,"balance":40,"reserved":40,"spendable":0,"state":"revoked"}' from ledger_rows where value->>'transaction_id'='7101'),'refund preserves reservations and original grant');
select test.assert((select value->'credits' @> '{"granted":800,"balance":600,"reserved":20,"spendable":0,"state":"expired"}' from ledger_rows where value->>'transaction_id'='7102'),'expired credits still show reservations but not spendability');
select test.assert((select value->'credits' @> '{"granted":400,"balance":0,"reserved":0,"spendable":0,"state":"spent"}' from ledger_rows where value->>'transaction_id'='7103'),'fully spent grant remains visible');
select test.assert((select value->'credits'->>'state'='no_grant' and value->'sandbox_decision'='null'::jsonb from ledger_rows where value->>'transaction_id'='7104'),'no grant does not invent allowance exhaustion');

set role authenticated;
select set_config('request.jwt.claim.sub',:O,false);
create temporary table all_ledger_pages(ordinal bigint generated always as identity,value jsonb);
do $$ declare cursor jsonb:=null; page jsonb; loops integer:=0; begin
 loop
  page:=public.v1_admin_store_account_transactions('38100000-0000-0000-0000-000000000001',cursor,7);
  insert into all_ledger_pages(value) select value from jsonb_array_elements(page->'transactions');
  loops:=loops+1; if loops>30 then raise exception 'pagination_did_not_terminate'; end if;
  cursor:=nullif(page->'next_cursor','null'::jsonb); exit when cursor is null;
 end loop;
end $$;
reset role;
select test.assert((select count(*)=170 and count(distinct(value->>'environment',value->>'transaction_id'))=170 from all_ledger_pages),'all keyset pages cover tied timestamps/environments exactly once');
select test.assert((select jsonb_agg(jsonb_build_array(value->>'environment',value->>'transaction_id') order by ordinal) from all_ledger_pages)=
 (select jsonb_agg(jsonb_build_array(environment,transaction_id) order by recorded_at desc,environment desc,transaction_id desc)
  from app_private.store_transactions where account_id=:A),'full tuple ordering maintained across page boundaries');

-- Actual EXPLAIN verifies that both continuation and latest-decision ordering
-- can use their bounded account indexes. No total-count or whole-table join is needed.
create function pg_temp.plan(query text) returns text language plpgsql as $$ declare result json; begin
 execute 'explain (format json) '||query into result; return result::text; end $$;
analyze app_private.store_transactions;
analyze app_private.store_sandbox_decisions;
set local enable_seqscan=off;
select test.assert(position('store_transactions_account_recorded' in pg_temp.plan($q$
 select * from app_private.store_transactions where account_id='38100000-0000-0000-0000-000000000001'
 and (recorded_at,environment,transaction_id)<(now()-interval '30 days','Production','900100')
 order by recorded_at desc,environment desc,transaction_id desc limit 51$q$))>0,'older-page tuple uses the account keyset index');
select test.assert(position('store_sandbox_decision_account_latest' in pg_temp.plan($q$
 select * from app_private.store_sandbox_decisions where account_id='38100000-0000-0000-0000-000000000001' and transaction_id='6103'
 order by created_at desc,period desc,reason desc limit 1$q$))>0,'latest same-account decision uses matching index');
set local enable_seqscan=on;
select test.assert(pg_temp.financial_digest()=:'before_read','all ledger reads leave financial records unchanged');
rollback;
