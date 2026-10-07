begin;
insert into auth.users(id) values('37000000-0000-0000-0000-00000000000a'),('37000000-0000-0000-0000-00000000000b'),('37000000-0000-0000-0000-00000000000c');
insert into app_private.app_roles(account_id,role) values('37000000-0000-0000-0000-00000000000c','owner'),('37000000-0000-0000-0000-00000000000b','support');
\set A '37000000-0000-0000-0000-00000000000a'
\set B '37000000-0000-0000-0000-00000000000b'
\set C '37000000-0000-0000-0000-00000000000c'
\set O1 '37000000-0000-0000-0001-000000000001'
\set O2 '37000000-0000-0000-0001-000000000002'
\set O3 '37000000-0000-0000-0001-000000000003'
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,1000000,true);
select public.worker_grant_credits(:'A','adjustment','spending-admin-fixture',100,now()-interval '1 day',null,'Fixture');
select public.worker_reserve_operation(:'A',:'O1','chat',sha256('request-private-fixture'),'beta-credits-v1',5,10000);
select public.worker_provider_attempt_begin(:'A',:'O1',:'O1','anthropic','chat','claude-sonnet-5-5',sha256('private-prompt-fixture'),10000,'{"output_tokens":5}');
select public.worker_provider_attempt_finish(:'A',:'O1',:'O1','succeeded','req_admin_fixture',3000,'{"input_tokens":100,"output_tokens":5}',null);
select public.worker_settle_operation(:'A',:'O1',1,3000);
select public.worker_reserve_operation(:'A',:'O2','chat',sha256('unknown-request'),'beta-credits-v1',5,20000);
select public.worker_provider_attempt_begin(:'A',:'O2',:'O2','anthropic','chat','claude-sonnet-5-5',sha256('unknown-prompt'),20000,'{"output_tokens":5}');
select public.worker_provider_attempt_finish(:'A',:'O2',:'O2','unknown',null,null,'{}','transport_unknown');
select public.worker_settle_operation(:'A',:'O2',0,0);
select public.worker_reserve_operation(:'A',:'O3','chat',sha256('legacy-request'),'beta-credits-v1',5,10000);
select public.worker_record_provider_usage(:'A',:'O3','anthropic','legacy-admin-fixture','legacy-model','{"unstructured":"private-legacy-value"}',7000);
select public.worker_settle_operation(:'A',:'O3',2,7000);
reset role;

-- The customer, support, and an owner without MFA cannot inspect expenses.
set role anon;
select test.reject('select public.v1_admin_spending()','permission denied');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub',:'A',false);
select set_config('request.jwt.claim.aal','aal2',false);
select test.reject('select public.v1_admin_spending()','owner_mfa_required');
select set_config('request.jwt.claim.sub',:'B',false);
select test.reject('select public.v1_admin_spending()','owner_mfa_required');
select set_config('request.jwt.claim.sub',:'C',false);
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject('select public.v1_admin_spending()','owner_mfa_required');
select set_config('request.jwt.claim.aal','aal2',false);
select public.v1_admin_spending(30,:'A') as summary \gset
select test.assert((:'summary'::jsonb->'attempts'->>'reported_microusd')::bigint=3000,'reported expense excludes held and legacy');
select test.assert((:'summary'::jsonb->'attempts'->>'held_microusd')::bigint=20000,'unknown held after customer refund visible');
select test.assert((:'summary'::jsonb->'legacy'->>'estimated_microusd')::bigint=7000,'legacy estimates explicitly separate');
select test.assert((:'summary'::jsonb->'customers'->>'settled_credits')::bigint=3,'customer debit separately reported');
select test.assert(not (:'summary'::jsonb->'forecast'->>'complete')::boolean and (:'summary'::jsonb->'forecast'->>'missing_components')::integer=8,'unknown overhead does not become a complete zero-dollar forecast');
select test.reject('select public.v1_admin_spending(0)','invalid_spending_window');
select test.reject('select public.v1_admin_spending(91)','invalid_spending_window');
select public.v1_admin_spending_operations(30,:'A',null,null,null,1) as page1 \gset
select public.v1_admin_spending_operations(30,:'A',(:'page1'::jsonb->'next'->>'created_at')::timestamptz,(:'page1'::jsonb->'next'->>'account_id')::uuid,(:'page1'::jsonb->'next'->>'id')::uuid,1) as page2 \gset
select test.assert(jsonb_array_length(:'page1'::jsonb->'operations')=1 and :'page1'::jsonb->'operations'->0->>'id'<>:'page2'::jsonb->'operations'->0->>'id','deterministic bounded operations page');
select test.assert(jsonb_array_length(public.v1_admin_spending_operations(30,:'B')->'operations')=0,'account filter isolates operations');
select public.v1_admin_spending_operation(:'A',:'O2') as detail \gset
select test.assert((:'detail'::jsonb->'record_counts'->>'events')::integer=2 and (:'detail'::jsonb->'operation'->>'provider_liability_microusd')::integer=20000,'detail connects operation to immutable history');
select test.assert(position('request_sha256' in :'detail')=0 and position('private-prompt-fixture' in :'detail')=0,'request digests/content excluded from inspection');
select public.v1_admin_spending_records(:'A',:'O2','events',null,null,1) as event1 \gset
select public.v1_admin_spending_records(:'A',:'O2','events',(:'event1'::jsonb->'next'->>'at')::timestamptz,:'event1'::jsonb->'next'->>'id',1) as event2 \gset
select test.assert(:'event1'::jsonb->'records'->0->>'key'<>:'event2'::jsonb->'records'->0->>'key','event timeline pages without repeated records');
select test.assert(position('private-legacy-value' in public.v1_admin_spending_records(:'A',:'O3','legacy_usage')::text)=0,'unstructured legacy provider data excluded');
select test.reject(format('select public.v1_admin_spending_records(%L,%L,%L,null,null,101)',:'A',:'O2','events'),'invalid_spending_page');
select test.reject(format('select public.v1_admin_spending_operation(%L,%L)',:'B',:'O2'),'spending_operation_unavailable');
reset role;

-- External evidence is append-only, idempotent, finite and separately sourced.
set role service_role;
select public.worker_record_spending_observation(:'C','37000000-0000-0000-0002-000000000001','tavily_subscription',date_trunc('month',now() at time zone 'UTC')::date,
 'commitment',30000000,true,now(),'owner-confirmed','tavily-project-fixture','{"included_searches":4000}');
select test.assert((public.worker_record_spending_observation(:'C','37000000-0000-0000-0002-000000000001','tavily_subscription',date_trunc('month',now() at time zone 'UTC')::date,
 'commitment',30000000,true,now(),'owner-confirmed','tavily-project-fixture','{"included_searches":4000}')->>'replayed')::boolean,'observation replay idempotent');
reset role;
select test.reject('delete from app_private.spending_cost_observations','immutable_record_requires_compensating_entry');
set role authenticated;
select public.v1_admin_spending(30,:'A') as with_overhead \gset
select test.assert((:'with_overhead'::jsonb->'forecast'->>'overhead_allocation_microusd')::bigint=30000000 and (:'with_overhead'::jsonb->'forecast'->>'missing_components')::integer=7,'one commitment does not erase missing infrastructure evidence');
select test.assert((:'with_overhead'::jsonb->'forecast'->>'funded_plan_microusd')::bigint=31000000,'provider allocation counted once alongside prepaid subscription');
reset role;

-- A short reporting window must not hide a much older unresolved vendor charge
-- or a prepaid search whose dollar ceiling is zero. Exercise real admissions.
set role service_role;
select public.worker_provider_allowance_configure('37000000-0000-0000-0003-000000000001',now()-interval '1 day',now()+interval '29 days',20,0,now(),'fixture-search-baseline',true);
select public.worker_reserve_operation(:'A','37000000-0000-0000-0001-000000000004','metadata',sha256('prepaid-admin-request'),'beta-credits-v1',0,0);
select public.worker_provider_attempt_begin(:'A','37000000-0000-0000-0001-000000000004','37000000-0000-0000-0001-000000000004',
 'tavily','reference_lookup','search-basic',sha256('prepaid-admin-request'),0,'{"credits":1}');
select public.worker_provider_attempt_finish(:'A','37000000-0000-0000-0001-000000000004','37000000-0000-0000-0001-000000000004',
 'unknown',null,null,'{}','transport_unknown');
select public.worker_settle_operation(:'A','37000000-0000-0000-0001-000000000004',0,0);
reset role;
-- Fixture clock: their original starts predate even the longest reporting window.
update app_private.metered_operations set created_at=now()-interval '120 days' where account_id=:'A' and id in (:'O2','37000000-0000-0000-0001-000000000004');
update app_private.provider_attempts set created_at=now()-interval '120 days' where account_id=:'A' and id in (:'O2','37000000-0000-0000-0001-000000000004');
set role authenticated;
select public.v1_admin_spending(7,:'A') as aged_summary \gset
select test.assert((:'aged_summary'::jsonb->'unresolved'->>'total')::integer=2 and
 (:'aged_summary'::jsonb->'unresolved'->>'held_microusd')::bigint=20000,'all-time unknown attempts include zero-dollar prepaid requests');
select public.v1_admin_spending_operations(7,:'A',null,null,null,50,true) as unknown_page \gset
select test.assert(jsonb_array_length(:'unknown_page'::jsonb->'operations')=2 and :'unknown_page'::jsonb->>'since' is null,
 'unresolved drill-down spans all dates including zero-dollar prepaid liability');
select test.assert(jsonb_array_length(public.v1_admin_spending_operations(7,:'A')->'operations')=2,'ordinary history retains its chosen time window');
reset role;
update app_private.accounts set closed_at=now() where id=:'A';
set role authenticated;
select test.assert((public.v1_admin_spending_operation(:'A',:'O2')->'account'->>'closed')::boolean,'de-identified financial records survive closure for authorized investigation');
reset role;
rollback;
