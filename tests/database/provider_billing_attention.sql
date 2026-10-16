-- Provider billing refusals in Health (migration 084): attempts a provider refused for the account's own balance are
-- counted for the owner's Attention, other failures are not, and the earlier sections stay. Synthetic local SQL.
begin;
create schema if not exists test;
grant usage on schema test to anon,authenticated,service_role;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
grant execute on all functions in schema test to anon,authenticated,service_role;

\set A '84000000-0000-0000-0000-00000000000a'
\set OWN '84000000-0000-0000-0000-0000000000ff'
insert into auth.users(id,email) values(:'A','reader-84@gradstep.test.org'),(:'OWN','owner-84@gradstep.test.org');
insert into app_private.app_roles(account_id,role) values(:'OWN','owner');
select date_trunc('month',now() at time zone 'UTC')::date as month \gset
select public.worker_set_platform_budget(:'month',10000000,true);
select public.worker_grant_credits(:'A','adjustment','billing-84',1000,now()-interval '1 day',null,'Billing fixture');
create function test.refused(provider text, model text, failure text) returns void language plpgsql as $$
declare op uuid := gen_random_uuid(); attempt uuid := gen_random_uuid(); acct uuid := '84000000-0000-0000-0000-00000000000a';
begin
 perform public.worker_reserve_operation(acct, op, 'chat', sha256(convert_to(op::text,'UTF8')), 'beta-credits-v1', 10, 10000);
 perform public.worker_provider_attempt_begin(acct, op, attempt, provider, 'chat', model, sha256(convert_to(attempt::text,'UTF8')), 10000, '{"output_tokens":1}');
 perform public.worker_provider_attempt_finish(acct, op, attempt, 'rejected', null, 0, '{}', failure);
 perform public.worker_settle_operation(acct, op, 0, 0);
end $$;
set role service_role;
select test.refused('anthropic','claude-sonnet-5-5','provider_billing');
select test.refused('anthropic','claude-haiku-5-5','provider_billing');
select test.refused('deepseek','deepseek-flash','http_402');
select test.refused('anthropic','claude-sonnet-5-5','provider_rejected');
reset role;
select set_config('request.jwt.claim.sub',:'OWN',false);
select set_config('request.jwt.claim.aal','aal2',false);
select public.v1_admin_health(7) as h \gset
select set_config('request.jwt.claim.sub','',false);
select set_config('request.jwt.claim.aal','',false);
select test.assert((:'h'::jsonb ? 'people') and (:'h'::jsonb ? 'anomalies') and (:'h'::jsonb ? 'early_endings'),'the earlier sections are unchanged');
select test.assert((:'h'::jsonb->'provider_billing'->>'last_hour')::int=3 and (:'h'::jsonb->'provider_billing'->>'last_24h')::int=3,'three billing refusals; an ordinary rejection is not one');
select test.assert((:'h'::jsonb->'provider_billing'->'by_provider'->>'anthropic')::int=2 and (:'h'::jsonb->'provider_billing'->'by_provider'->>'deepseek')::int=1,'by provider');
select test.assert(:'h'::jsonb->'provider_billing'->>'last_at' is not null,'when it last happened');
-- A reader can't read it.
select set_config('request.jwt.claim.sub',:'A',false);
do $$ begin perform public.v1_admin_health(7); raise exception 'ASSERTION FAILED: a reader read Health'; exception when others then
 if sqlerrm like 'ASSERTION FAILED%' then raise; end if; end $$;
select set_config('request.jwt.claim.sub','',false);
rollback;
