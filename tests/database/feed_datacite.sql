-- The Feed from DataCite and the search switches (migrations 074/075, docs/architecture/ARXIV_DEVICE_ONLY.md §5.5):
-- 075 switched device search on, OpenAlex off and the Feed's source to DataCite, recorded against the owner
-- (feed_datacite_owner.sql); the refresh claim and the cron wake-up use the active source's row, the RSS row stays
-- for audit and switching back. Synthetic local SQL.
begin;
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin begin execute statement; exception when others then
 if position(expected in sqlerrm)=0 then raise exception 'Unexpected rejection: % (wanted %)',sqlerrm,expected; end if; rejected:=true; end;
 if not rejected then raise exception 'Expected rejection: %',expected; end if; end $$;
grant usage on schema test to anon,authenticated,service_role;
grant execute on all functions in schema test to anon,authenticated,service_role;

\set O '74000000-0000-0000-0000-00000000000a'

-- Switched, and recorded once against the owner.
select test.assert((select device_search_enabled and not openalex_enabled and feed_source='datacite' from app_private.pipeline_policy where singleton),'075 switched');
select test.assert((select count(*)=1 from app_private.admin_audit_events where action='search_sources' and target_id='pipeline_policy'
 and actor_id=:'O' and details->>'feed_source'='datacite' and details->>'openalex_enabled'='false' and details->>'migration'='202610160075'),'recorded against the owner');
set role service_role;
select test.assert(public.worker_search_policy()='{"openalex":false,"device_search":true,"feed_source":"datacite"}'::jsonb,'the functions see the switches');
select test.reject($q$select app_private.feed_active_source()$q$,'permission denied');
reset role;
select test.reject($q$update app_private.pipeline_policy set feed_source='openalex' where singleton$q$,'check constraint');
set role authenticated;
select set_config('request.jwt.claim.sub',:'O',false);
select test.reject($q$select public.worker_search_policy()$q$,'permission denied');
select test.reject($q$select public.worker_feed_refresh_claim()$q$,'permission denied');
reset role;
set role anon;
select test.reject($q$select public.worker_feed_refresh_claim()$q$,'permission denied');
reset role;

-- The claim is on DataCite's row and says so; one live claim at a time.
select test.assert(app_private.feed_active_source()='datacite-ml','active source');
set role service_role;
select public.worker_set_feed_policy('off',true);
select public.worker_feed_refresh_claim() as claim \gset
select test.assert((:'claim'::jsonb->>'source')='datacite-ml' and (:'claim'::jsonb->>'kind')='datacite' and :'claim'::jsonb->'etag'='null'::jsonb
 and :'claim'::jsonb->'last_modified'='null'::jsonb and jsonb_array_length(:'claim'::jsonb->'categories')=12 and (:'claim'::jsonb->>'max_items')::integer=3000,'first DataCite claim');
select :'claim'::jsonb->>'claim_id' as c1 \gset
select test.assert(public.worker_feed_refresh_claim() is null,'a live claim excludes another');
select public.worker_feed_refresh_finish(:'c1','updated',null,'2026-10-15T06:00:00Z',14);
reset role;
select test.assert((select last_status='updated' and last_items=14 and last_modified='2026-10-15T06:00:00Z' and etag is null and claim_id is null
 from app_private.feed_sources where name='datacite-ml'),'the mark is kept on the DataCite row');
select test.assert(not exists(select 1 from app_private.feed_sources where name='arxiv-ml' and last_attempt_at is not null),'no claim touched the RSS row');

-- The next refresh reads from the mark; nothing new keeps it.
update app_private.feed_sources set next_check_at=now()-interval '1 minute' where name='datacite-ml';
set role service_role;
select public.worker_feed_refresh_claim() as claim2 \gset
select test.assert((:'claim2'::jsonb->>'last_modified')='2026-10-15T06:00:00Z','the claim carries the mark');
select public.worker_feed_refresh_finish((:'claim2'::jsonb->>'claim_id')::uuid,'not_modified',null,null,null);
reset role;
select test.assert((select last_status='not_modified' and last_modified='2026-10-15T06:00:00Z' and last_items=14 from app_private.feed_sources where name='datacite-ml'),
 'not modified keeps the mark and the count');
-- The cron wake-up reads the active row (not due now) and needs pg_net (absent locally) either way.
select test.assert(not app_private.feed_refresh_kick(),'nothing to wake');

-- Migration 076: the Feed can no longer be switched back to arXiv's RSS (our servers never contact arXiv); claims stay
-- on DataCite's row.
select test.reject($q$update app_private.pipeline_policy set feed_source='arxiv_rss' where singleton$q$,'pipeline_policy_feed_source_check');
select test.assert(app_private.feed_active_source()='datacite-ml','still DataCite');
select test.assert(not exists(select 1 from app_private.feed_sources where name='arxiv-ml' and last_attempt_at is not null),'no claim touched the RSS row');
select test.assert(exists(select 1 from app_private.admin_audit_events where action='arxiv_egress' and actor_id=:'O'
 and details->>'migration'='202610160076'),'076 recorded against the owner');
rollback;
