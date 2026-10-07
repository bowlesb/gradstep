-- Provider allowance (migration 021): service-only sum of one usage unit over recent days,
-- per provider, ignoring other providers, other units, old events and non-numeric values.
begin;
insert into auth.users values('21000000-0000-0000-0000-00000000000a');
set role service_role;
select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,10000000,true);
select public.worker_grant_credits('21000000-0000-0000-0000-00000000000a','adjustment','allowance-test',200,now()-interval '1 day',null,'Allowance test grant');
select public.worker_reserve_operation('21000000-0000-0000-0000-00000000000a','21600000-0000-0000-0000-00000000000a','chat',decode(repeat('cc',32),'hex'),'beta-credits-v1',30,150000);
select public.worker_reserve_operation('21000000-0000-0000-0000-00000000000a','21600000-0000-0000-0000-00000000000b','chat',decode(repeat('dd',32),'hex'),'beta-credits-v1',30,150000);
select test.assert(public.worker_provider_units_recent('tavily','credits',31)=0,'nothing recorded yet');
select public.worker_record_provider_usage('21000000-0000-0000-0000-00000000000a','21600000-0000-0000-0000-00000000000a','tavily',
 'operation:21600000-0000-0000-0000-00000000000a','search-basic','{"searches":3,"credits":3,"failed":0,"list_microusd":24000}'::jsonb,0);
select public.worker_record_provider_usage('21000000-0000-0000-0000-00000000000a','21600000-0000-0000-0000-00000000000b','tavily',
 'operation:21600000-0000-0000-0000-00000000000b','search-basic','{"searches":2,"credits":2,"failed":1}'::jsonb,0);
-- Other providers and malformed units do not count.
select public.worker_record_provider_usage('21000000-0000-0000-0000-00000000000a','21600000-0000-0000-0000-00000000000a','anthropic',
 'msg_allowance','claude-sonnet-5-5','{"credits":50}'::jsonb,1000);
select public.worker_record_provider_usage('21000000-0000-0000-0000-00000000000a','21600000-0000-0000-0000-00000000000b','tavily',
 'operation:malformed','search-basic','{"credits":"9"}'::jsonb,0);
select test.assert(public.worker_provider_units_recent('tavily','credits',31)=5,'credits summed for the provider');
select test.assert(public.worker_provider_units_recent('tavily','searches',31)=5,'any unit');
select test.reject($q$select public.worker_provider_units_recent('tavily','credits',0)$q$,'invalid_usage_query');
select test.reject($q$select public.worker_provider_units_recent('Tavily!','credits',31)$q$,'invalid_usage_query');
reset role;
-- Events older than the window age out.
alter table app_private.provider_usage_events disable trigger provider_usage_immutable;
update app_private.provider_usage_events set created_at=now()-interval '40 days' where provider_event_id='operation:21600000-0000-0000-0000-00000000000a';
alter table app_private.provider_usage_events enable trigger provider_usage_immutable;
set role service_role;
select test.assert(public.worker_provider_units_recent('tavily','credits',31)=2,'older events age out');
reset role;
-- Customers cannot read it.
set role authenticated;
select set_config('request.jwt.claim.sub','21000000-0000-0000-0000-00000000000a',false);
select test.reject($q$select public.worker_provider_units_recent('tavily','credits',31)$q$,'permission denied');
reset role;
set role anon;
select test.reject($q$select public.worker_provider_units_recent('tavily','credits',31)$q$,'permission denied');
reset role;
rollback;
