-- Direct add-reference outcomes (migration 026): service-only, validated, recorded as reliability events.
begin;
insert into auth.users values('26000000-0000-0000-0000-00000000000a');
set role service_role;
select public.worker_record_reference_event('added','crossref','openalex:W1572676502',812);
select test.reject($q$select public.worker_record_reference_event('Added!','crossref',null,1)$q$,'invalid_reference_event');
select test.reject($q$select public.worker_record_reference_event('added','crossref',null,-1)$q$,'invalid_reference_event');
reset role;
select test.assert(exists(select 1 from app_private.api_rate_rules where route='add-reference'),'rate rule exists');
select test.assert(exists(select 1 from app_private.pipeline_events where kind='reference' and phase='added' and error_code='crossref' and duration_ms=812),'outcome recorded');
set role authenticated;
select set_config('request.jwt.claim.sub','26000000-0000-0000-0000-00000000000a',false);
select test.reject($q$select public.worker_record_reference_event('added','crossref',null,1)$q$,'permission denied');
reset role;
rollback;
