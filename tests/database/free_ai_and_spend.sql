-- Migration 0150 (docs/PRICING_HOW_IT_WORKS.md, docs/RUNBOOK_SPENDING.md): free AI from a capped pool, the accepted
-- products, annual months, the owner's switches with previews and audit, Spend vs income, and alert throttling and
-- delivery. Synthetic local SQL; nothing leaves the machine (pg_net and Vault are local stand-ins).
begin;
create schema if not exists test;
grant usage on schema test to anon,authenticated,service_role;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin begin execute statement; exception when others then
 if position(expected in sqlerrm)=0 then raise exception 'Unexpected rejection: % (wanted %)',sqlerrm,expected; end if; rejected:=true; end;
 if not rejected then raise exception 'Expected rejection: %',expected; end if; end $$;
grant execute on all functions in schema test to anon,authenticated,service_role;

\set OWN '15000000-0000-4000-8000-0000000000ff'
\set R '15000000-0000-4000-8000-00000000000a'
\set S '15000000-0000-4000-8000-00000000000b'
\set P '15000000-0000-4000-8000-00000000000c'
\set T '15000000-0000-4000-8000-00000000000d'
\set Y '15000000-0000-4000-8000-00000000000e'
\set GEMINI '{"profile_version":"chat-profiles-v1","profile":"gemini-medium-standard","model":"gemini-3.8-flash","effort":"medium","length":"standard","tariff":"openrouter-google-flash-vertex-us-20261017","max_output_tokens":10000,"input_estimate_tokens":120000,"max_searches":0,"title_model":"claude-haiku-5-5","title_max_tokens":40,"title_ceiling_microusd":3000,"follow_ups_model":"claude-haiku-5-5","follow_ups_max_tokens":160,"follow_ups_ceiling_microusd":9000}'
\set SEARCHED '{"profile_version":"chat-profiles-v1","profile":"gemini-medium-standard","model":"gemini-3.8-flash","effort":"medium","length":"standard","tariff":"openrouter-google-flash-vertex-us-20261017","max_output_tokens":10000,"input_estimate_tokens":120000,"max_searches":3,"title_model":"claude-haiku-5-5","title_max_tokens":40,"title_ceiling_microusd":3000,"follow_ups_model":"claude-haiku-5-5","follow_ups_max_tokens":160,"follow_ups_ceiling_microusd":9000}'
\set SONNET '{"profile_version":"chat-profiles-v1","profile":"sonnet-low-standard","model":"claude-sonnet-5-5","effort":"low","length":"standard","tariff":"openrouter-claude-vertex-us-20261017","max_output_tokens":10000,"input_estimate_tokens":120000,"max_searches":0,"title_model":"claude-haiku-5-5","title_max_tokens":40,"title_ceiling_microusd":3000,"follow_ups_model":"claude-haiku-5-5","follow_ups_max_tokens":160,"follow_ups_ceiling_microusd":9000}'
insert into auth.users(id,email,email_confirmed_at) values(:'OWN','owner-150@gradstep.test.org',now()),(:'R','reader-150@gradstep.test.org',now()),
 (:'S','second-150@gradstep.test.org',now()),(:'P','pack-150@gradstep.test.org',now()),(:'T','check-150@example.invalid',now()),
 (:'Y','yearly-150@gradstep.test.org',now());
insert into app_private.app_roles(account_id,role) values(:'OWN','owner');
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits(:'P','purchased','Production:150000099',300,now()-interval '1 day',null,'Pack fixture');
select public.worker_grant_credits(:'P','purchased','Sandbox:150000098',5,now()-interval '1 day',null,'Sandbox pack fixture');
create or replace function test.reader(p uuid) returns void language sql as $$
 select set_config('request.jwt.claim.sub',p::text,false), set_config('request.jwt.claim.aal','aal1',false); $$;
create or replace function test.owner(p uuid) returns void language sql as $$
 select set_config('request.jwt.claim.sub',p::text,false), set_config('request.jwt.claim.aal','aal2',false); $$;

-- ── Grants ──────────────────────────────────────────────────────────────────────────────────────────────────────────
select test.assert(has_function_privilege('authenticated','public.v1_credit_balance()','execute'),'readers read their balance');
select test.assert(not has_function_privilege('authenticated','public.worker_ai_switches()','execute')
 and has_function_privilege('service_role','public.worker_ai_switches()','execute'),'switch reads are the service''s');
select test.assert(not has_function_privilege('authenticated','public.worker_spend_alerts_tick()','execute'),'the alert tick is the service''s');
select test.assert(not has_function_privilege('anon','public.v1_admin_spend_income()','execute'),'never anonymous');
select test.assert(not has_table_privilege('service_role','app_private.ai_controls','select')
 and not has_table_privilege('authenticated','app_private.spend_alerts','select'),'private tables stay private');
select test.assert((select free_monthly_credits=50 and free_daily_credits=20 and free_pool_microusd=15000000 and free_account_microusd=250000
 and apple_commission_bp=1500 and not free_ai_paused and not cheap_models_only and paused_features='{}' from app_private.ai_controls),'accepted defaults');

-- ── Products ────────────────────────────────────────────────────────────────────────────────────────────────────────
select test.assert((select credits=600 and period_months=1 and price_microusd=7990000 and intro_price_microusd=3990000
 from app_private.store_products where product_id='com.sciencereader.ios.standard.monthly'),'Plus monthly: 600 a month at $7.99, $3.99 first month');
select test.assert((select credits=2000 and period_months=12 and price_microusd=199990000 from app_private.store_products
 where product_id='com.sciencereader.ios.pro.annual'),'Pro annual: 2,000 a month');
select test.assert((select count(*)=7 from app_private.store_products),'old pack kept, four products added');
select test.assert((select credits=400 and active from app_private.store_products where product_id='com.sciencereader.ios.credits.400'),
 'the old 400 pack still records for earlier purchasers');

-- ── Free credits: issued lazily, only to readers on the free tier ──────────────────────────────────────────────────
set role authenticated;
select test.reader(:'R');
select test.assert((select (b->>'available')::int=50 and (b->'free'->>'available')::int=50 and (b->'free'->>'usable')::boolean
 and b->'free'->>'reason' is null and (b->'free'->>'monthly')::int=50 from public.v1_credit_balance() b),'a free reader sees 50 free credits');
select test.assert((select (b->>'available')::int=50 from public.v1_credit_balance() b),'issued once');
select test.reader(:'T');
select test.assert((select b->'free'='null'::jsonb and (b->>'available')::int=0 from public.v1_credit_balance() b),'synthetic check accounts get no free AI');
reset role;
select test.assert((select count(*)=1 and min(expires_at)=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC'+interval '1 month'
 from app_private.credit_buckets where account_id=:'R' and source='free'),'one free bucket, ending with the month');

-- A free-funded Gemini answer: free bucket first, marked, and counted in the pool.
set role service_role;
select test.assert(not (public.worker_reserve_chat(:'R','15000000-0000-4000-8001-000000000001',sha256('r1'),'beta-credits-v1',12,60000,:'GEMINI'::jsonb)->>'replayed')::boolean,
 'free credits pay for a fast model');
reset role;
select test.assert((select free_funded from app_private.metered_operations where id='15000000-0000-4000-8001-000000000001'),'marked free-funded');
select test.assert(app_private.free_pool_used()=60000,'the pool counts the whole open ceiling');
set role service_role;
select public.worker_settle_operation(:'R','15000000-0000-4000-8001-000000000001',3,11500);
reset role;
select test.assert(app_private.free_pool_used()=11500,'and the actual cost once settled');
-- Premium models and podcasts never use free credits.
set role service_role;
select test.reject(format('select public.worker_reserve_chat(%L,%L,sha256(%L),%L,12,60000,%L::jsonb)',:'R','15000000-0000-4000-8001-000000000002','r2','beta-credits-v1',:'SONNET'),'insufficient_credits');
-- A searched answer from an older chat function is still free-funded and counted (the current one offers no search on it).
select public.worker_reserve_chat(:'R','15000000-0000-4000-8001-000000000003',sha256('r3'),'beta-credits-v1',12,60000,:'SEARCHED'::jsonb);
select public.worker_settle_operation(:'R','15000000-0000-4000-8001-000000000003',0,0);
select test.reject(format('select public.worker_reserve_operation(%L,%L,%L,sha256(%L),%L,10,30000)',:'R','15000000-0000-4000-8001-000000000004','podcast','r4','beta-credits-v1'),'insufficient_credits');
-- Recommendations may.
select test.assert(not (public.worker_reserve_operation(:'R','15000000-0000-4000-8001-000000000005','recommend',sha256('r5'),'beta-credits-v1',1,15000)->>'replayed')::boolean,
 'free credits pay for a recommendation');
select public.worker_settle_operation(:'R','15000000-0000-4000-8001-000000000005',1,1300);
reset role;

-- The daily share (20 credits a day).
set role service_role;
select public.worker_reserve_chat(:'R','15000000-0000-4000-8001-000000000006',sha256('r6'),'beta-credits-v1',16,60000,:'GEMINI'::jsonb);
select public.worker_settle_operation(:'R','15000000-0000-4000-8001-000000000006',16,9000);
select test.reject(format('select public.worker_reserve_chat(%L,%L,sha256(%L),%L,5,60000,%L::jsonb)',:'R','15000000-0000-4000-8001-000000000007','r7','beta-credits-v1',:'GEMINI'),'insufficient_credits');
reset role;
set role authenticated;
select test.reader(:'R');
select test.assert((select b->'free'->>'reason'='daily' and not (b->'free'->>'usable')::boolean and (b->>'available')::int=0
 and (b->'free'->>'resumes_at')::timestamptz=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'+interval '1 day'
 from public.v1_credit_balance() b),'today''s share used: comes back tomorrow, and the balance leaves those credits out');
reset role;

-- The account's monthly cost share ($0.25) and the pool.
update app_private.metered_operations set created_at=created_at-interval '2 days' where account_id=:'R';
update app_private.metered_operations set actual_microusd=250000 where id='15000000-0000-4000-8001-000000000006';
set role authenticated;
select test.reader(:'R');
select test.assert((select b->'free'->>'reason'='account' from public.v1_credit_balance() b),'its monthly cost share is used');
reset role;
set role service_role;
select test.reject(format('select public.worker_reserve_chat(%L,%L,sha256(%L),%L,5,60000,%L::jsonb)',:'R','15000000-0000-4000-8001-000000000008','r8','beta-credits-v1',:'GEMINI'),'insufficient_credits');
reset role;

-- A second reader against a nearly used pool: a request whose worst case would pass the pool is refused before any call.
update app_private.ai_controls set free_pool_microusd=app_private.free_pool_used()+400000;
set role service_role;
select test.reject(format('select public.worker_reserve_chat(%L,%L,sha256(%L),%L,10,500000,%L::jsonb)',:'S','15000000-0000-4000-8001-000000000011','s1','beta-credits-v1',:'GEMINI'),'insufficient_credits');
select test.assert(not (public.worker_reserve_chat(:'S','15000000-0000-4000-8001-000000000012',sha256('s2'),'beta-credits-v1',10,200000,:'GEMINI'::jsonb)->>'replayed')::boolean,
 'a request that fits the pool is admitted');
reset role;
update app_private.ai_controls set free_pool_microusd=app_private.free_pool_used()+100000;
set role authenticated;
select test.reader(:'S');
select test.assert((select b->'free'->>'reason'='pool' and (b->'free'->>'resumes_at')::timestamptz=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC'+interval '1 month'
 from public.v1_credit_balance() b),'everyone''s free AI is used up: comes back on the 1st');
reset role;
-- A pack holder is unaffected: the pack pays, nothing is free-funded.
set role service_role;
select test.assert(not (public.worker_reserve_chat(:'P','15000000-0000-4000-8001-000000000021',sha256('p1'),'beta-credits-v1',10,500000,:'GEMINI'::jsonb)->>'replayed')::boolean,
 'pack credits pay when the pool cannot');
reset role;
select test.assert((select not free_funded from app_private.metered_operations where id='15000000-0000-4000-8001-000000000021'),'not free-funded');
select test.assert((select sum(ra.credits)=10 from app_private.reservation_allocations ra join app_private.credit_buckets b on b.id=ra.bucket_id
 where ra.operation_id='15000000-0000-4000-8001-000000000021' and b.source='purchased'),'held on the pack');
update app_private.ai_controls set free_pool_microusd=15000000;

-- ── The owner's switches ────────────────────────────────────────────────────────────────────────────────────────────
set role authenticated;
select test.reader(:'R');
select test.reject($q$select public.v1_admin_set_ai_switch('free_ai',true,'Not an owner')$q$,'owner_mfa_required');
select test.owner(:'OWN');
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject($q$select public.v1_admin_set_ai_switch('free_ai',true,'Needs two factors')$q$,'owner_mfa_required');
select test.owner(:'OWN');
select test.reject($q$select public.v1_admin_set_ai_switch('everything',true,'Unknown switch')$q$,'invalid_switch');
select test.reject($q$select public.v1_admin_set_ai_switch('podcasts',true,'x')$q$,'invalid_reason');
select test.assert((public.v1_admin_ai_switch_preview('free_ai')->>'requests')::int>=3 and (public.v1_admin_ai_switch_preview('free_ai')->>'on')='false',
 'the free AI preview counts free-funded requests');
select test.assert(public.v1_admin_set_ai_switch('podcasts',true,'Podcast costs spiked')->>'on'='true','podcasts paused');
select test.assert(public.v1_admin_set_ai_switch('recommendations',true,'Recommendations paused for review')->>'on'='true','recommendations paused');
select test.assert(public.v1_admin_set_ai_switch('cheap_models',true,'Premium spend too high')->>'on'='true','cheaper models only');
reset role;
select test.assert((select paused_features='{podcasts,recommendations}' and cheap_models_only from app_private.ai_controls),'recorded');
select test.assert((select count(*)=3 and bool_and(actor_id=:'OWN') from app_private.admin_audit_events where action='ai_switch'),'each change is audited to the owner');
select test.assert((select details->'before'->'paused_features'='[]'::jsonb and details->'after'->'paused_features'='["podcasts"]'::jsonb
 from app_private.admin_audit_events where action='ai_switch' and target_id='podcasts'),'with the state before and after');
set role service_role;
select test.reject(format('select public.worker_reserve_operation(%L,%L,%L,sha256(%L),%L,10,30000)',:'P','15000000-0000-4000-8001-000000000031','podcast','p31','beta-credits-v1'),'platform_budget_exhausted');
select test.reject(format('select public.worker_reserve_operation(%L,%L,%L,sha256(%L),%L,1,15000)',:'P','15000000-0000-4000-8001-000000000032','recommend','p32','beta-credits-v1'),'platform_budget_exhausted');
select test.reject(format('select public.worker_reserve_chat(%L,%L,sha256(%L),%L,10,60000,%L::jsonb)',:'P','15000000-0000-4000-8001-000000000033','p33','beta-credits-v1',:'SONNET'),'platform_budget_exhausted');
select test.assert(not (public.worker_reserve_chat(:'P','15000000-0000-4000-8001-000000000034',sha256('p34'),'beta-credits-v1',10,60000,:'GEMINI'::jsonb)->>'replayed')::boolean,
 'fast models keep working');
select test.assert((public.worker_reserve_chat(:'P','15000000-0000-4000-8001-000000000021',sha256('p1'),'beta-credits-v1',10,500000,:'GEMINI'::jsonb)->>'replayed')::boolean,
 'an exact replay is still answered');
select test.assert((select (s->>'cheap_models_only')::boolean and s->'paused_features'='["podcasts", "recommendations"]'::jsonb from public.worker_ai_switches() s),
 'the chat function reads the switches');
reset role;
set role authenticated;
select test.owner(:'OWN');
select public.v1_admin_set_ai_switch('podcasts',false,'Costs back to normal');
select public.v1_admin_set_ai_switch('recommendations',false,'Review done');
select public.v1_admin_set_ai_switch('cheap_models',false,'Premium spend back to normal');
select public.v1_admin_set_ai_switch('free_ai',true,'Free tier abused');
select test.owner(:'R');
select test.assert((select b->'free'->>'reason'='paused' and b->'free'->>'resumes_at' is null from public.v1_credit_balance() b),'paused free AI says so');
select test.owner(:'OWN');
select public.v1_admin_set_ai_switch('free_ai',false,'Free tier resumed');
select test.assert((public.v1_admin_ai_switch_preview('all_ai')->>'on')='false','all AI is running');
select public.v1_admin_set_ai_switch('all_ai',true,'Stop everything');
reset role;
select test.assert((select not work_enabled from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),'all AI paused with the existing switch');
set role authenticated;
select test.owner(:'OWN');
select public.v1_admin_set_ai_switch('all_ai',false,'Resume everything');
select test.reject($q$select public.v1_admin_set_free_pool(60000000,'Too much')$q$,'invalid_pool');
select test.assert((public.v1_admin_set_free_pool(20000000,'More free users this month')->>'pool_microusd')::bigint=20000000,'the pool can be resized by the owner');
reset role;
select test.assert((select free_pool_microusd=20000000 from app_private.ai_controls)
 and exists(select 1 from app_private.admin_audit_events where action='free_pool' and (details->>'before_microusd')::bigint=15000000),'audited');
select test.assert((select work_enabled from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),'resumed');

-- ── Annual plans: the first month at purchase, then each month of the paid year, once ──────────────────────────────
-- store_grant (the recorder's grant): an annual plan's first bucket ends after one month, not after the year.
select bucket as annual_bucket from app_private.store_grant('Production','150000001','150000001',:'Y','com.sciencereader.ios.standard.annual',1,
 now()-interval '40 days',now()-interval '40 days'+interval '1 year','PURCHASE',null) \gset
select test.assert((select expires_at=now()-interval '40 days'+interval '1 month' and balance=600 from app_private.credit_buckets where id=:'annual_bucket'),
 'the first month ends after a month');
insert into app_private.store_owners(environment,original_transaction_id,account_id,bound_by) values('Production','150000001',:'Y','app');
insert into app_private.store_transactions(environment,transaction_id,original_transaction_id,account_id,product_id,quantity,purchased_at,expires_at,signed_at,credits,bucket_id,granted_at,reason)
 select 'Production','150000001','150000001',:'Y','com.sciencereader.ios.standard.annual',1,now()-interval '40 days',now()-interval '40 days'+interval '1 year',now(),600,id,now(),'PURCHASE'
 from app_private.credit_buckets where account_id=:'Y' and external_key='Production:150000001';
set role authenticated;
select test.reader(:'Y');
select test.assert((select (b->>'available')::int=600 and b->'free'='null'::jsonb from public.v1_credit_balance() b),'month two issued; a subscriber has no free AI');
select public.v1_credit_balance();
select test.assert((select s->>'plan'='standard' and (s->>'period_months')::int=12 from public.v1_store_summary() s),'the summary says yearly');
reset role;
select test.assert((select count(*)=1 and min(balance)=600 from app_private.credit_buckets where external_key='Production:150000001:m1'),'month two once');
-- A refund removes the unspent credits of the issued months too.
update app_private.store_transactions set revoked_at=now() where transaction_id='150000001';
select test.assert((select balance=reserved and revoked_at is not null from app_private.credit_buckets where external_key='Production:150000001:m1'),
 'refund removes month two''s unspent credits');

-- ── Spend vs income ─────────────────────────────────────────────────────────────────────────────────────────────────
-- Two Production purchases this month (a Plus first month at the $3.99 introductory price, a 300 pack) and a Sandbox one.
insert into app_private.store_owners(environment,original_transaction_id,account_id,bound_by) values('Production','150000002',:'S','app'),
 ('Production','150000003',:'S','app'),('Sandbox','150000004',:'S','app');
insert into app_private.store_transactions(environment,transaction_id,original_transaction_id,account_id,product_id,quantity,purchased_at,expires_at,signed_at,credits)
 values('Production','150000002','150000002',:'S','com.sciencereader.ios.standard.monthly',1,now(),now()+interval '1 month',now(),0),
 ('Production','150000003','150000003',:'S','com.sciencereader.ios.credits.300',1,now(),null,now(),0),
 ('Sandbox','150000004','150000004',:'S','com.sciencereader.ios.pro.monthly',1,now(),now()+interval '5 minutes',now(),0);
-- Provider attempts this month for the funding split.
insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,state,actual_microusd,pricing_snapshot,transport_metadata)
 values('15000000-0000-4000-8009-000000000001',:'R','15000000-0000-4000-8001-000000000001','openrouter','chat','gemini-3.8-flash',sha256('a1'),60000,'{"output_tokens":1}','succeeded',11500,'{}','{"feature":"figure"}'),
 ('15000000-0000-4000-8009-000000000002',:'P','15000000-0000-4000-8001-000000000021','openrouter','chat','gemini-3.8-flash',sha256('a2'),60000,'{"output_tokens":1}','succeeded',20000,'{}','{"feature":"chat"}');
set role authenticated;
select test.owner(:'OWN');
select set_config('test.figures',public.v1_admin_spend_income()::text,false);
reset role;
-- The annual plan refunded above (bought last month) is deducted this month, as Apple does.
select test.assert((select (f->'income'->'production'->>'purchases')::int=2 and (f->'income'->'production'->>'gross_microusd')::bigint=3990000+4990000
 and (f->'income'->'production'->>'refunds')::int=1 and (f->'income'->'production'->>'refunded_microusd')::bigint=79990000
 and (f->'income'->'production'->>'proceeds_microusd')::bigint=round((3990000+4990000-79990000)*0.85)
 and (f->'income'->'sandbox'->>'purchases')::int=1 and f->'ratio'='null'::jsonb
 from (select current_setting('test.figures')::jsonb f) x),'proceeds: introductory price for a first month, refunds deducted, 15 % commission, Sandbox apart');
update app_private.store_transactions set revoked_at=null where transaction_id='150000001';
set role authenticated;
select test.owner(:'OWN');
select test.assert((select (f->'income'->'production'->>'proceeds_microusd')::bigint=round((3990000+4990000)*0.85) and (f->>'ratio')::numeric>0
 from (select public.v1_admin_spend_income() f) x),'without the refund: proceeds and a ratio');
reset role;
select test.assert((select (f->'spend'->'by_funding'->>'free')::bigint=11500 and (f->'spend'->'by_funding'->>'paid')::bigint=20000
 and f->'spend'->'by_feature' @> '[{"feature":"figure_explainer","cost_microusd":11500}]'
 and (f->'free'->>'accounts')::int>=2 and (f->'free'->>'suggested_pool_microusd')::bigint=15000000 and f->>'email_configured'='true'
 from (select current_setting('test.figures')::jsonb f) x),'spend split by funding and feature; the free pool; the owner''s address is known');

-- Sandbox (TestFlight) credits are test money: spend they pay for is `sandbox`, never `paid` (migration 0151).
insert into app_private.metered_operations(account_id,id,kind,request_sha256,rate_version,period,credit_ceiling,spend_ceiling_microusd,state)
 values(:'P','15000000-0000-4000-8001-000000000041','chat',sha256('p41'),'beta-credits-v1',date_trunc('month',now() at time zone 'UTC')::date,1,1000,'reserved');
insert into app_private.reservation_allocations select :'P','15000000-0000-4000-8001-000000000041',id,1 from app_private.credit_buckets where external_key='Sandbox:150000098';
select test.assert(app_private.operation_funding(:'P','15000000-0000-4000-8001-000000000041')='sandbox','Sandbox purchases are not income');
select test.assert(app_private.operation_funding(:'P','15000000-0000-4000-8001-000000000021')='paid','Production pack credits are');

-- ── Alerts: once a month each, recorded, then emailed when Vault and pg_net are there ──────────────────────────────
update app_private.platform_budgets set spent_microusd=8500000 where period=date_trunc('month',now() at time zone 'UTC')::date;
set role service_role;
select test.assert((public.worker_spend_alerts_tick()->>'not_configured')::int=2,'no key: recorded as not configured');
select test.assert((public.worker_spend_alerts_tick()->>'created')::int=0,'and not raised again');
reset role;
select test.assert((select count(*)=2 and bool_and(delivery='not_configured') from app_private.spend_alerts),'50 % and 80 % recorded');
-- Local stand-ins for Vault and pg_net.
create schema vault;
create table vault.decrypted_secrets(name text,decrypted_secret text);
insert into vault.decrypted_secrets values('science_reader_resend_key','re_test_key'),('science_reader_alert_email','alerts@gradstep.test.org');
create schema net;
create table net.sent(id bigserial primary key,url text,body jsonb,headers jsonb);
create table net._http_response(id bigint,status_code integer);
create function net.http_post(url text,body jsonb default '{}',params jsonb default '{}',headers jsonb default '{}',timeout_milliseconds integer default 5000)
 returns bigint language sql as $$ insert into net.sent(url,body,headers) values(url,body,headers) returning id $$;
update app_private.platform_budgets set spent_microusd=9900000 where period=date_trunc('month',now() at time zone 'UTC')::date;
update app_private.ai_controls set free_pool_microusd=1000;
set role service_role;
select test.assert((public.worker_spend_alerts_tick()->>'sent')::int=2,'limit reached and pool used up: one digest');
reset role;
select test.assert((select count(*)=1 and min(url)='https://api.resend.com/emails' and min(body->'to'->>0)='alerts@gradstep.test.org'
 and min(body->>'subject') like '%limit reached%free pool used up%' and min(headers->>'Authorization')='Bearer re_test_key' from net.sent),
 'one email to the configured owner address through Resend');
insert into net._http_response values((select max(id) from net.sent),200);
set role service_role;
select public.worker_spend_alerts_tick();
reset role;
select test.assert((select count(*)=2 from app_private.spend_alerts where delivery='sent' and attempts=1),'delivery recorded from the response');
select test.assert((select count(*)=1 from net.sent),'nothing sent twice');
set role authenticated;
select test.owner(:'OWN');
select test.assert((select jsonb_array_length(f->'alerts'->'recent')=4 from (select public.v1_admin_spend_income() f) x),'Admin lists the alerts');
reset role;
rollback;
