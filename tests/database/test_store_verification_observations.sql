-- Diagnostic admission never changes money and never trusts a claimed transaction.
begin;
insert into auth.users values('38000000-0000-0000-0000-000000000001'),('38000000-0000-0000-0000-000000000002'),
 ('38000000-0000-0000-0000-000000000003'),('38000000-0000-0000-0000-000000000004');
insert into app_private.app_roles values('38000000-0000-0000-0000-000000000004','owner',now());
\set A '\'38000000-0000-0000-0000-000000000001\''
\set B '\'38000000-0000-0000-0000-000000000002\''
\set C '\'38000000-0000-0000-0000-000000000003\''
\set O '\'38000000-0000-0000-0000-000000000004\''
\set I '\'38000000-0000-0000-0000-000000000011\''
\set J '\'38000000-0000-0000-0000-000000000012\''
\set K '\'38000000-0000-0000-0000-000000000013\''

set role anon;
select test.reject('select public.v1_admin_store_verifications()','permission denied');
select test.reject('select public.worker_store_verification_readiness()','permission denied');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub',:A,false);
select set_config('request.jwt.claim.aal','aal2',false);
select test.reject('select public.v1_admin_store_verifications()','owner_mfa_required');
select test.reject($q$select public.worker_store_verification_begin('38000000-0000-0000-0000-000000000001',gen_random_uuid(),decode(repeat('38',32),'hex'))$q$,'permission denied');
select test.reject('select * from app_private.store_verification_observations','permission denied');
select set_config('request.jwt.claim.sub',:O,false);
select set_config('request.jwt.claim.aal','aal1',false);
select test.reject('select public.v1_admin_store_verifications()','owner_mfa_required');
select test.reject($q$select public.v1_admin_store_verification_attempts('38000000-0000-0000-0000-000000000001',repeat('38',32))$q$,'owner_mfa_required');
reset role;

set role service_role;
select test.assert(public.worker_store_verification_begin(:A,:I,decode(repeat('38',32),'hex'))->>'granted'='true','admit one call');
select test.assert(public.worker_store_verification_begin(:A,:I,decode(repeat('38',32),'hex'))=
 '{"granted":false,"reason":"attempt_replayed"}'::jsonb,'replaying a grant cannot send again');
select test.reject($q$select public.worker_store_verification_begin('38000000-0000-0000-0000-000000000001','38000000-0000-0000-0000-000000000011',decode(repeat('39',32),'hex'))$q$,'store_observation_conflict');
select test.reject($q$select public.worker_store_verification_begin('38000000-0000-0000-0000-000000000002','38000000-0000-0000-0000-000000000011',decode(repeat('38',32),'hex'))$q$,'store_observation_conflict');
select test.reject($q$select public.worker_store_verification_begin('38000000-0000-0000-0000-000000000001',gen_random_uuid(),decode('38','hex'))$q$,'invalid_store_observation');
select public.worker_store_verification_finish(:A,:I,'verification_unavailable','revocation','retryable_verification_failure','timeout');
select public.worker_store_verification_finish(:A,:I,'verification_unavailable','revocation','retryable_verification_failure','timeout');
select test.reject($q$select public.worker_store_verification_finish('38000000-0000-0000-0000-000000000001','38000000-0000-0000-0000-000000000011','recorded')$q$,'store_observation_conflict');
select test.assert(public.worker_store_verification_begin(:A,:J,decode(repeat('38',32),'hex'))->>'granted'='true','a distinct attempt retries same submission');
select public.worker_store_verification_finish(:A,:J,'recorded');
select test.assert(public.worker_store_verification_begin(:B,:K,decode(repeat('39',32),'hex'))->>'granted'='true','another submission admitted');
select test.reject($q$select public.worker_store_verification_finish('38000000-0000-0000-0000-000000000002','38000000-0000-0000-0000-000000000013','invalid','private arbitrary error')$q$,'check constraint');
reset role;
select test.assert((select count(*)=0 from app_private.store_transactions where account_id in (:A,:B)),'observations create no financial transaction');
select test.assert((select count(*)=0 from app_private.credit_buckets where account_id in (:A,:B)),'observations grant no credits');
update app_private.store_verification_observations set admitted_at=admitted_at-interval '11 minutes',expires_at=expires_at-interval '11 minutes' where id=:K;

set role authenticated;
select set_config('request.jwt.claim.sub',:O,false);
select set_config('request.jwt.claim.aal','aal2',false);
select public.v1_admin_store_verifications('all') as observed \gset
select test.assert((:'observed'::jsonb->>'matched')::integer=2,'two submissions, three attempts');
select test.assert(:'observed'::jsonb->'counts'='{"confirmed":1,"interrupted":1}'::jsonb,'interrupted is unconfirmed, completed retry is confirmed');
select test.assert((public.v1_admin_store_verifications('unconfirmed')->>'matched')::integer=1,'default view includes stale interrupted calls');
select test.assert((public.v1_admin_store_verifications('confirmed',repeat('38',6))->'submissions'->0->>'attempts')::integer=2,'support-code prefix groups retries');
select test.assert(jsonb_array_length(public.v1_admin_store_verification_attempts(:A,repeat('38',32)))=2,'MFA owner can inspect attempts');
select test.assert(jsonb_array_length(public.v1_admin_store_verification_attempts(:B,repeat('38',32)))=0,'attempt lookup remains account-bound');
select test.reject($q$select public.v1_admin_store_verifications('all','%')$q$,'invalid_store_observation_query');
select test.reject($q$select public.v1_admin_store_verifications('all',null,201)$q$,'invalid_store_observation_query');
reset role;

-- Retained caps apply atomically before admission; a rejection allocates no row.
update app_private.store_verification_policy set account_rows=2,environment_rows=3;
set role service_role;
select test.assert(public.worker_store_verification_begin(:C,gen_random_uuid(),decode(repeat('40',32),'hex'))->>'reason'='observation_capacity','global retained cap');
reset role;
update app_private.store_verification_policy set environment_rows=10;
set role service_role;
select test.assert(public.worker_store_verification_begin(:A,gen_random_uuid(),decode(repeat('40',32),'hex'))->>'reason'='observation_capacity','account retained cap');
reset role;
select test.assert((select count(*) from app_private.store_verification_observations)=3,'capacity refusals allocate nothing');

-- Expired diagnostics are hidden before cleanup and pruned in a bounded batch.
update app_private.store_verification_observations set admitted_at=now()-interval '31 days',expires_at=now()-interval '1 day' where id=:K;
set role authenticated;
select test.assert((public.v1_admin_store_verifications('all')->>'matched')::integer=1,'expired pending disappears from operator view');
reset role;
set role service_role;
select test.assert(public.worker_prune_store_verifications(1)=1,'bounded expiry cleanup removes one row');
select test.assert(public.worker_prune_store_verifications(1)=0,'cleanup replay is harmless');
reset role;

-- Rate limits govern actual attempted verifications, not only HTTP batches.
delete from app_private.api_rate_windows where route='store-verification';
update app_private.api_rate_rules set account_limit=1,environment_limit=2 where route='store-verification';
set role service_role;
select test.assert(public.worker_store_verification_begin(:B,:K,decode(repeat('39',32),'hex'))->>'granted'='true','fresh actual attempt consumes one slot');
select test.assert(public.worker_store_verification_begin(:B,gen_random_uuid(),decode(repeat('41',32),'hex'))->>'reason'='verification_rate','account hourly rate enforced');
select test.assert(public.worker_store_verification_begin(:C,gen_random_uuid(),decode(repeat('42',32),'hex'))->>'granted'='true','other account gets last global slot');
select test.assert(public.worker_store_verification_begin(:O,gen_random_uuid(),decode(repeat('43',32),'hex'))->>'reason'='verification_rate','global hourly rate enforced');
reset role;
select test.assert((select count(*) from app_private.store_verification_observations)=4,'rate refusals allocate nothing');

-- Account closure removes support diagnostics; an in-flight finish cannot recreate them.
update app_private.accounts set closed_at=now() where id=:B;
select test.assert((select count(*) from app_private.store_verification_observations where account_id=:B)=0,'closure erases observations');
set role service_role;
select public.worker_store_verification_finish(:B,:K,'verification_unavailable','revocation');
select test.assert(public.worker_store_verification_begin(:B,gen_random_uuid(),decode(repeat('39',32),'hex'))->>'reason'='account_unavailable','closed account cannot admit new work');
select test.assert(public.worker_store_verification_readiness()->'cleanup'->>'active'='false','fixture truthfully reports absent cleanup scheduler');
reset role;
rollback;
