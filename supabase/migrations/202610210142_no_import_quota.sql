-- 0142: no import quota (owner, 2026-10-21: "I'm not sure why import quota is even a thing? Users can import and download
-- whenever they want if it's free"; design: docs/architecture/LIBRARY_CAPACITY.md "No import quota (2026-10-21)").
-- Before (migration 010, 2026-10-03): lifetime counts refused free library work forever once reached: 2,000 import
-- requests and 2,000 membership rows per account (20,000 each for the whole service), 12,000 library commands per account
-- (120,000 for the service, so every reader would eventually be refused together), 10,000 shared catalog records (32 MiB),
-- and a synced-descriptor count derived from items plus imports. Removed paper copies and device-only PDFs (058, 080)
-- left nothing these counts protect: adding, importing, removing and downloading cost Gradstep no provider money.
-- Now: a NULL limit is no limit. Every check compares against library_policy, and a comparison with NULL never refuses,
-- so the counts above no longer apply anywhere they were enforced (v2_begin_import and v5_begin_import, web imports,
-- v2_add_paper_once, library_write_item, the receipt check, catalog metadata, the descriptor trigger) without rewriting
-- those functions. What remains is abuse protection a reader adding papers by hand never meets: the per-account and
-- service request rates (add-paper and add-reference 120 an hour, library-write 1,000 an hour), a backstop on imports in
-- flight at once (100 per account, 2,000 for the service; was 10 and 100), and the existing bounds on each row (32 KiB of
-- catalog metadata, journal and descriptor bytes, the monthly library transfer). Paid AI work keeps its credits, holds,
-- the platform budget and its own attempt windows. No rows change except the singleton policy row.
begin;
set local lock_timeout='15s';

alter table app_private.library_policy
 alter column account_items drop not null, alter column environment_items drop not null,
 alter column account_imports drop not null, alter column environment_imports drop not null,
 alter column account_receipts drop not null, alter column environment_receipts drop not null,
 alter column metadata_rows drop not null, alter column metadata_bytes drop not null;
comment on column app_private.library_policy.account_imports is 'Lifetime import requests per account; null (since 0142): no limit.';
comment on column app_private.library_policy.account_items is 'Lifetime membership rows per account; null (since 0142): no limit.';
comment on column app_private.library_policy.account_receipts is 'Lifetime library commands per account; null (since 0142): no limit.';
comment on column app_private.library_policy.metadata_rows is 'Shared catalog metadata rows for the service; null (since 0142): no limit.';

update app_private.library_policy set account_items=null,environment_items=null,account_imports=null,environment_imports=null,
 account_receipts=null,environment_receipts=null,metadata_rows=null,metadata_bytes=null,
 account_active_imports=100,environment_active_imports=2000
where singleton;

notify pgrst,'reload schema';
commit;
