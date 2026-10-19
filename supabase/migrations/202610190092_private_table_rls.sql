-- Recovery drill 2026-10-19: restore verification requires RLS on every private table.
-- These tables already have no customer grants; preserve service/definer access and add no policies.
begin;
set local lock_timeout='15s';
alter table app_private.arxiv_categories enable row level security;
alter table app_private.arxiv_licenses enable row level security;
alter table app_private.catalog_metadata_provenance enable row level security;
alter table app_private.podcast_device_sources enable row level security;
commit;
