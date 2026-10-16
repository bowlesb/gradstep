-- Switch on (owner decisions, 2026-10-16: "Search: turn on device-only search, which drops OpenAlex — Sure"; "Shared
-- Feed: take it from DataCite on our servers, so our servers never contact arXiv — Ok"): devices search for themselves
-- (native: arXiv's API; browser: DataCite), the server's own search and DOI naming leave OpenAlex (DataCite, Crossref),
-- and the Feed's pool comes from DataCite. Recorded in the admin audit log against the owner account when one exists.
-- Apply after deploying the functions that read `feed_source` (feed-refresh, discover); older functions keep RSS.
begin;
set local lock_timeout='15s';

update app_private.pipeline_policy set device_search_enabled=true, openalex_enabled=false, feed_source='datacite' where singleton;

insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
select r.account_id,'search_sources','pipeline_policy',
 'Owner decision 2026-10-16: device search on, OpenAlex off, Feed pool from DataCite (docs/architecture/ARXIV_DEVICE_ONLY.md)',
 jsonb_build_object('device_search_enabled',true,'openalex_enabled',false,'feed_source','datacite','migration','202610160075')
from app_private.app_roles r join app_private.accounts a on a.id=r.account_id
where r.role='owner' and a.closed_at is null order by r.account_id limit 1;

commit;
