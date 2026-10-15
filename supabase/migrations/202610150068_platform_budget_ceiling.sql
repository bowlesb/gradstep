-- 068: The platform provider budget's hard ceiling rises from $30 to $50 a month (docs/architecture/SPENDING_CONTROLS.md).
-- Owner, 2026-10-15 ("it's all fine with me, just push ahead"): October's $25 cap was reached during the evening's
-- testing (chat holds then refuse with platform_budget_exhausted: "AI answers are paused"). The ceiling stays inside
-- the approved $100/month incremental beta budget; the month's limit itself is still set explicitly by the operator
-- (worker_set_platform_budget) and recorded, never raised silently.
begin;
alter table app_private.platform_budgets drop constraint platform_budgets_limit_microusd_check1;
alter table app_private.platform_budgets add constraint platform_budgets_limit_microusd_check1 check(limit_microusd<=50000000);
commit;
