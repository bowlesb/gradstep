-- The general current-schema suites (scripts/test-database.py CURRENT_GENERAL) check contracts written before migration
-- 0150: the 2026-10-05 allowances (Standard 800, Pro 1,800) and no free AI credits. Their own behaviour is unchanged by
-- 0150; the new allowances and free credits have their own fixture (free_ai_and_spend.sql). Applied to their template.
update app_private.store_products set credits=800 where product_id='com.sciencereader.ios.standard.monthly';
update app_private.store_products set credits=1800 where product_id='com.sciencereader.ios.pro.monthly';
update app_private.ai_controls set free_monthly_credits=0;
