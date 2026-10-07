-- Adding a paper must be "absolutely bullet proof" (owner, 2026-10-07). Design:
-- docs/architecture/PDF_UPLOADS.md.
--
-- 1. Add by any identifier or link: a rate rule for functions/v1/add-paper (identification
--    without a model; imports go through the existing begin RPCs).
begin;
set local lock_timeout='15s';

insert into app_private.api_rate_rules values('add-paper',3600,120,2000) on conflict(route) do nothing;

notify pgrst,'reload schema';
commit;
