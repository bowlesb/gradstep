-- Admin accounts (migration 031): the owner-with-MFA list (every account, search, sort, status,
-- plan, credits, library size), the Edge function's owner gate, and the service-only add tester,
-- credit grant and sign-in change: owner re-check, strict input, caps, idempotency, audit.
-- Rolled back.
begin;
-- O owner, T synthetic tester, C customer, D disabled, X closing (deletion started), Z closed (deleted).
insert into auth.users(id,email,created_at,last_sign_in_at,raw_app_meta_data) values
 ('31000000-0000-0000-0000-00000000000a','owner@example.com',now()-interval '30 days',now()-interval '1 hour','{"provider":"email","providers":["email","apple"]}'),
 ('31000000-0000-0000-0000-00000000000b','gradstep-check-import@example.invalid',now()-interval '2 days',null,'{"provider":"email","providers":["email"]}'),
 ('31000000-0000-0000-0000-00000000000c','reader@example.org',now()-interval '10 days',now()-interval '5 days','{"provider":"google","providers":["google"]}'),
 ('31000000-0000-0000-0000-00000000000d','former@example.org',now()-interval '20 days',now()-interval '3 days',null),
 ('31000000-0000-0000-0000-00000000000e','closing@example.org',now()-interval '25 days',now()-interval '2 days','{"providers":["email"]}'),
 ('31000000-0000-0000-0000-00000000000f','deleted@example.org',now()-interval '40 days',now()-interval '39 days','{"providers":["email"]}');
update app_private.accounts a set created_at=u.created_at from auth.users u where u.id=a.id and a.id::text like '31000000-%';
update auth.users set banned_until=now()+interval '100 years' where id='31000000-0000-0000-0000-00000000000d';
update app_private.accounts set closed_at=now() where id='31000000-0000-0000-0000-00000000000e';
update app_private.accounts set closed_at=now()-interval '1 day',auth_user_id=null where id='31000000-0000-0000-0000-00000000000f';
delete from auth.users where id='31000000-0000-0000-0000-00000000000f';
insert into app_private.app_roles values('31000000-0000-0000-0000-00000000000a','owner',now());
-- C: a Standard plan, 120 credits (20 held), two library items (one removed).
select public.worker_grant_credits('31000000-0000-0000-0000-00000000000c','purchased','owner-accounts-pack',120,now()-interval '1 day',null,'Fixture pack');
update app_private.credit_buckets set reserved=20 where external_key='owner-accounts-pack';
insert into app_private.store_owners(environment,original_transaction_id,account_id,bound_by) values('Sandbox','3100','31000000-0000-0000-0000-00000000000c','app');
insert into app_private.store_transactions(environment,transaction_id,original_transaction_id,account_id,product_id,quantity,purchased_at,expires_at,signed_at,credits)
 values('Sandbox','3100','3100','31000000-0000-0000-0000-00000000000c','com.sciencereader.ios.standard.monthly',1,now()-interval '1 day',now()+interval '29 days',now(),0);
insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values
 ('31000000-0000-0000-0000-0000000000d1',decode(repeat('31',32),'hex'),'shared_catalog','{"license":"cc-by"}',1000,3),
 ('31000000-0000-0000-0000-0000000000d2',decode(repeat('32',32),'hex'),'shared_catalog','{"license":"cc-by"}',1000,3);
insert into app_private.library_items(account_id,document_id,removed_at) values
 ('31000000-0000-0000-0000-00000000000c','31000000-0000-0000-0000-0000000000d1',null),
 ('31000000-0000-0000-0000-00000000000c','31000000-0000-0000-0000-0000000000d2',now());

-- Anonymous callers and customers: no list, no owner gate, no service functions.
set role anon;
select test.reject('select public.v1_admin_accounts()','permission denied');
select test.reject('select public.v1_admin_actor()','permission denied');
select test.reject($$select public.worker_admin_find_login('reader@example.org')$$,'permission denied');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','31000000-0000-0000-0000-00000000000c',false);
select set_config('request.jwt.claim.aal','aal2',false);
select test.reject('select public.v1_admin_accounts()','owner_mfa_required');
select test.reject('select public.v1_admin_actor()','owner_mfa_required');
select test.reject($$select public.worker_admin_find_login('reader@example.org')$$,'permission denied');
select test.reject($$select public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000c','31000000-0000-0000-0000-0000000000a1',
 '31000000-0000-0000-0000-00000000000c',100,'Self grant')$$,'permission denied');
select test.reject($$select public.worker_admin_add_tester('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-00000000000c',false,100)$$,'permission denied');
select test.reject($$select public.worker_admin_set_sign_in('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000a2',
 '31000000-0000-0000-0000-00000000000d',false,'Self enable')$$,'permission denied');
-- The owner without MFA is refused too.
select set_config('request.jwt.claim.sub','31000000-0000-0000-0000-00000000000a',false);
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject('select public.v1_admin_accounts()','owner_mfa_required');
select test.reject('select public.v1_admin_actor()','owner_mfa_required');

-- Owner with MFA.
select set_config('request.jwt.claim.aal','aal2',false);
select test.assert(public.v1_admin_actor()='31000000-0000-0000-0000-00000000000a','the gate returns the owner''s account');
select public.v1_admin_accounts(null,'created',false,500) as l \gset
reset role;
select test.assert((:'l'::jsonb->>'total')::int=(select count(*) from app_private.accounts) and (:'l'::jsonb->>'matched')::int=(:'l'::jsonb->>'total')::int
 and jsonb_array_length(:'l'::jsonb->'accounts')=(:'l'::jsonb->>'total')::int,'every account is listed, closed ones included');
create temporary table listed on commit drop as select a from jsonb_array_elements(:'l'::jsonb->'accounts') a;
select test.assert((select a->>'email'='reader@example.org' and a->>'status'='active' and a->'providers'='["google"]'::jsonb and a->'plan'->>'plan'='standard'
 and a->'plan'->>'environment'='Sandbox' and (a->'credits'->>'available')::int=100 and (a->'credits'->>'reserved')::int=20 and (a->>'library_items')::int=1
 and not (a->>'synthetic')::boolean and a->'roles'='[]'::jsonb from listed where a->>'id'='31000000-0000-0000-0000-00000000000c'),'a customer row');
select test.assert((select (a->>'synthetic')::boolean and a->>'last_sign_in_at' is null and a->'plan'='null'::jsonb and (a->'credits'->>'available')::int=0
 from listed where a->>'id'='31000000-0000-0000-0000-00000000000b'),'a synthetic test login is marked, not hidden');
select test.assert((select a->'roles'='["owner"]'::jsonb and a->'providers'='["email","apple"]'::jsonb from listed where a->>'id'='31000000-0000-0000-0000-00000000000a'),'roles and methods');
select test.assert((select a->>'status' from listed where a->>'id'='31000000-0000-0000-0000-00000000000d')='disabled','a banned login is disabled');
select test.assert((select a->>'status' from listed where a->>'id'='31000000-0000-0000-0000-00000000000e')='closing','deletion started, login still linked');
select test.assert((select a->>'status'='closed' and a->'email'='null'::jsonb and a->'providers'='[]'::jsonb from listed where a->>'id'='31000000-0000-0000-0000-00000000000f'),
 'a deleted account is listed without a login');
set role authenticated;
-- Search: case-insensitive substring of the email; LIKE wildcards are literal.
select test.assert((select jsonb_agg(a->>'id') from jsonb_array_elements(public.v1_admin_accounts(' EXAMPLE.INVALID ')->'accounts') a)
 ='["31000000-0000-0000-0000-00000000000b"]'::jsonb,'search by email');
select test.assert((public.v1_admin_accounts('reader@')->>'matched')::int=1,'search finds the customer');
select test.assert((public.v1_admin_accounts('%')->>'matched')::int=0 and (public.v1_admin_accounts('_')->>'matched')::int=0,'wildcards are not patterns');
-- Sort: created (newest first by default), last sign-in (never-signed-in last either way), ascending.
select test.assert((select jsonb_agg(a->>'id') from jsonb_array_elements(public.v1_admin_accounts('example.','created',false)->'accounts') a)
 ='["31000000-0000-0000-0000-00000000000b","31000000-0000-0000-0000-00000000000c","31000000-0000-0000-0000-00000000000d","31000000-0000-0000-0000-00000000000e","31000000-0000-0000-0000-00000000000a"]'::jsonb,
 'newest first');
select test.assert((select jsonb_agg(a->>'id') from jsonb_array_elements(public.v1_admin_accounts('example.','last_sign_in',false)->'accounts') a)
 ='["31000000-0000-0000-0000-00000000000a","31000000-0000-0000-0000-00000000000e","31000000-0000-0000-0000-00000000000d","31000000-0000-0000-0000-00000000000c","31000000-0000-0000-0000-00000000000b"]'::jsonb,
 'most recent sign-in first, never signed in last');
select test.assert((select jsonb_agg(a->>'id') from jsonb_array_elements(public.v1_admin_accounts('example.','last_sign_in',true)->'accounts') a)
 ='["31000000-0000-0000-0000-00000000000c","31000000-0000-0000-0000-00000000000d","31000000-0000-0000-0000-00000000000e","31000000-0000-0000-0000-00000000000a","31000000-0000-0000-0000-00000000000b"]'::jsonb,
 'ascending keeps never-signed-in last');
select test.assert(jsonb_array_length(public.v1_admin_accounts('example.','created',false,2)->'accounts')=2 and
 (public.v1_admin_accounts('example.','created',false,2)->>'matched')::int=5,'the limit bounds the page, not the match count');
select test.reject($$select public.v1_admin_accounts(null,'email')$$,'invalid_accounts_query');
select test.reject($$select public.v1_admin_accounts(null,'created',false,0)$$,'invalid_accounts_query');
select test.reject($$select public.v1_admin_accounts(null,'created',false,501)$$,'invalid_accounts_query');
select test.reject($$select public.v1_admin_accounts(repeat('a',255))$$,'invalid_accounts_query');
reset role;

-- Service functions: the acting account must be an open owner.
set role service_role;
select test.reject($$select public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000c','31000000-0000-0000-0000-0000000000a1',
 '31000000-0000-0000-0000-00000000000c',100,'Self grant')$$,'owner_required');
select test.reject($$select public.worker_admin_add_tester(null,'31000000-0000-0000-0000-00000000000b',false,0)$$,'owner_required');
select test.reject($$select public.worker_admin_set_sign_in('31000000-0000-0000-0000-00000000000d','31000000-0000-0000-0000-0000000000a2',
 '31000000-0000-0000-0000-00000000000d',false,'Self enable')$$,'owner_required');

-- Find the login for an email.
select test.assert(public.worker_admin_find_login('  Reader@Example.ORG ')='{"account_id":"31000000-0000-0000-0000-00000000000c","closed":false}'::jsonb,
 'find ignores case and surrounding space');
select test.assert(public.worker_admin_find_login('closing@example.org')->>'closed'='true','a closing account is reported closed');
select test.assert(public.worker_admin_find_login('nobody@example.org') is null and public.worker_admin_find_login('deleted@example.org') is null,
 'no login, no account');
select test.reject($$select public.worker_admin_find_login('no-at-sign')$$,'invalid_email');
select test.reject($$select public.worker_admin_find_login('@example.org')$$,'invalid_email');
select test.reject($$select public.worker_admin_find_login('a b@example.org')$$,'invalid_email');
select test.reject($$select public.worker_admin_find_login(repeat('a',250)||'@x.org')$$,'invalid_email');

-- Add tester: audited once per account; starting credits granted once per account.
select public.worker_admin_add_tester('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-00000000000b',true,1000) as t \gset
select test.assert(:'t'::jsonb='{"account_id":"31000000-0000-0000-0000-00000000000b","status":"active","starting_credits":1000,"starting_granted":true}'::jsonb,'tester added');
select public.worker_admin_add_tester('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-00000000000b',false,500) as t \gset
select test.assert(:'t'::jsonb->>'starting_credits'='1000' and :'t'::jsonb->>'starting_granted'='false','adding again reports the earlier grant');
select test.assert(public.worker_admin_add_tester('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-00000000000d',false,0)
 ='{"account_id":"31000000-0000-0000-0000-00000000000d","status":"disabled","starting_credits":0,"starting_granted":false}'::jsonb,
 'an existing disabled account is reported, not re-enabled');
select test.reject($$select public.worker_admin_add_tester('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-00000000000b',false,2001)$$,'invalid_tester');
select test.reject($$select public.worker_admin_add_tester('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-00000000000b',false,-1)$$,'invalid_tester');
select test.reject($$select public.worker_admin_add_tester('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-00000000000e',false,10)$$,'account_closed');
select test.reject($$select public.worker_admin_add_tester('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000ff',false,10)$$,'account_unavailable');
reset role;
select test.assert((select count(*) from app_private.admin_audit_events where target_id='31000000-0000-0000-0000-00000000000b' and action='add_tester')=1
 and (select count(*) from app_private.admin_audit_events where target_id='31000000-0000-0000-0000-00000000000b' and action='grant_credits'
  and actor_id='31000000-0000-0000-0000-00000000000a' and (details->>'credits')::int=1000)=1,'one addition and one starting grant are audited');
select test.assert((select sum(balance) from app_private.credit_buckets where account_id='31000000-0000-0000-0000-00000000000b')=1000
 and (select source='adjustment' and expires_at is null from app_private.credit_buckets where external_key='tester-start:31000000-0000-0000-0000-00000000000b'),
 'starting credits are a never-expiring adjustment');

-- Grant credits: 1-2,000, reason required, once per request ID, audited with the grant.
set role service_role;
select public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000a1',
 '31000000-0000-0000-0000-00000000000c',300,'  Beta top-up for chat testing ') as g \gset
select test.assert(:'g'::jsonb->>'replayed'='false' and (:'g'::jsonb->>'credits')::int=300,'granted');
select test.assert(public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000a1',
 '31000000-0000-0000-0000-00000000000c',300,'Beta top-up for chat testing')->>'replayed'='true','a retried request is a replay');
select test.reject($$select public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000a1',
 '31000000-0000-0000-0000-00000000000c',301,'Beta top-up')$$,'request_id_conflict');
select test.reject($$select public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000a1',
 '31000000-0000-0000-0000-00000000000b',300,'Beta top-up')$$,'request_id_conflict');
select test.reject($$select public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000a3',
 '31000000-0000-0000-0000-00000000000c',2001,'Too many')$$,'invalid_grant');
select test.reject($$select public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000a3',
 '31000000-0000-0000-0000-00000000000c',0,'Nothing')$$,'invalid_grant');
select test.reject($$select public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000a',null,
 '31000000-0000-0000-0000-00000000000c',10,'No request')$$,'invalid_grant');
select test.reject($$select public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000a3',
 '31000000-0000-0000-0000-00000000000c',10,' ab ')$$,'invalid_reason');
select test.reject($$select public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000a3',
 '31000000-0000-0000-0000-00000000000c',10,'two'||chr(10)||'lines')$$,'invalid_reason');
select test.reject($$select public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000a3',
 '31000000-0000-0000-0000-00000000000c',10,repeat('x',501))$$,'invalid_reason');
select test.reject($$select public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000a3',
 '31000000-0000-0000-0000-00000000000f',10,'Deleted account')$$,'account_closed');
select test.reject($$select public.worker_admin_grant_credits('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000a3',
 '31000000-0000-0000-0000-0000000000ff',10,'Unknown account')$$,'account_unavailable');
reset role;
select test.assert((select (sum(balance)-sum(reserved))=400 from app_private.credit_buckets where account_id='31000000-0000-0000-0000-00000000000c'),'the grant is spendable once');
select test.assert((select reason='Admin grant: Beta top-up for chat testing' and kind='grant' and balance_delta=300 from app_private.credit_ledger l
 join app_private.credit_buckets b on b.id=l.bucket_id where b.external_key='admin:31000000-0000-0000-0000-0000000000a1'),'ledger entry');
select test.assert((select count(*)=1 and min(reason)='Beta top-up for chat testing' and min(actor_id::text)='31000000-0000-0000-0000-00000000000a'
 and min(details->>'request_id')='31000000-0000-0000-0000-0000000000a1' and min((details->>'credits')::int)=300
 from app_private.admin_audit_events where action='grant_credits' and target_id='31000000-0000-0000-0000-00000000000c'),'one audit row with actor, reason and amount');

-- Sign-in changes: audited before the Auth ban; idempotent per request ID; owners stay enabled.
set role service_role;
select public.worker_admin_set_sign_in('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000b1',
 '31000000-0000-0000-0000-00000000000c',true,'Left the beta') as s \gset
select test.assert(:'s'::jsonb='{"auth_user_id":"31000000-0000-0000-0000-00000000000c","disabled":true,"replayed":false}'::jsonb,'disable returns the login to ban');
select test.assert(public.worker_admin_set_sign_in('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000b1',
 '31000000-0000-0000-0000-00000000000c',true,'Left the beta')->>'replayed'='true','a retried request is a replay');
select test.reject($$select public.worker_admin_set_sign_in('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000b1',
 '31000000-0000-0000-0000-00000000000c',false,'Left the beta')$$,'request_id_conflict');
select test.reject($$select public.worker_admin_set_sign_in('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000a1',
 '31000000-0000-0000-0000-00000000000c',true,'Reused grant ID')$$,'request_id_conflict');
select test.reject($$select public.worker_admin_set_sign_in('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000b2',
 '31000000-0000-0000-0000-00000000000a',true,'Lock myself out')$$,'owner_cannot_be_disabled');
select test.reject($$select public.worker_admin_set_sign_in('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000b3',
 '31000000-0000-0000-0000-00000000000e',true,'Closing account')$$,'account_closed');
select test.reject($$select public.worker_admin_set_sign_in('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000b4',
 '31000000-0000-0000-0000-00000000000c',null,'No direction')$$,'invalid_sign_in_change');
select test.assert(public.worker_admin_set_sign_in('31000000-0000-0000-0000-00000000000a','31000000-0000-0000-0000-0000000000b5',
 '31000000-0000-0000-0000-00000000000d',false,'Back for round two')->>'auth_user_id'='31000000-0000-0000-0000-00000000000d','enable returns the login to unban');
reset role;
select test.assert((select array_agg(action order by action)=array['disable_sign_in','enable_sign_in'] from app_private.admin_audit_events
 where action like '%_sign_in' and actor_id='31000000-0000-0000-0000-00000000000a'),'each change is audited once');
select test.reject($$update app_private.admin_audit_events set reason='rewritten'$$,'immutable_record_requires_compensating_entry');
-- The Edge function's rate limit route exists.
set role service_role;
select public.worker_consume_request('31000000-0000-0000-0000-00000000000a','admin-accounts');
reset role;
rollback;
