-- 0150: the accepted pricing (owner, 2026-10-22: "I will take your defaults"; docs/proposals/PRICING_PROPOSAL_20261022.md,
-- DECISIONS.md "Pricing accepted") and the owner's safeguards against spend that is high relative to income
-- (docs/PRICING_HOW_IT_WORKS.md, docs/RUNBOOK_SPENDING.md). It reuses the credits, holds and budget machinery:
--
--  * Free AI. An account without a subscription gets 50 credits each UTC month (a `free` bucket, granted lazily at its
--    first balance read or AI request of the month, expiring at month end). Free credits pay only for the fast models
--    (Gemini Flash, DeepSeek, Haiku; the chat function offers no web search on them) and recommendations; never podcasts
--    or premium models.
--    An operation they fund is marked `free_funded`. Before any free-funded provider call the reservation, under the
--    existing budget -> account lock, checks that the whole month's free-funded worst case (settled cost + liability,
--    or the full ceiling while open) plus this request's ceiling fits the free pool ($15), that the account's free
--    spend this month is under $0.25 and that it used fewer than 20 free credits today. Otherwise the free credits are
--    skipped: other credits still pay, or the request is refused as `insufficient_credits` (every deployed client and
--    function already handles that code; the balance's `free.reason` says why). Paying users never touch the pool.
--  * Plans. Plus (`standard`) 600 credits a month, Pro 2,000; annual plans grant each month of the paid year (the first
--    when recorded, the rest lazily, once each); packs of 300 and 700 never expire. `credits.400` keeps working.
--  * Owner controls (owner + MFA, audited, reversible, with a dry-run preview): pause free AI, pause podcasts /
--    recommendations / figures / equations, cheaper models only, pause all AI (the existing switch); the free pool size.
--  * Spend vs income for the owner: this month's provider spend by funding, feature and model next to an estimate of App
--    Store proceeds from verified transactions (configured price x (1 - commission); never Apple's report), the ratio
--    and a straight-line forecast.
--  * Alerts: 50/80/100 % of the month's provider limit, the free pool used up, spend over a share of proceeds. Each at
--    most once a month (the table is the audit trail and the throttle); emailed through Resend by pg_net from a cron
--    tick when Vault holds the key; otherwise recorded as not configured and shown in Admin.
-- No limit is raised: the month's provider limit and the $100/month operating budget are unchanged.
begin;
set local lock_timeout='15s';

-- ── Free credits are their own bucket source; operations they fund are marked ─────────────────────────────────────
alter table app_private.credit_buckets drop constraint credit_buckets_source_check;
alter table app_private.credit_buckets add constraint credit_buckets_source_check
 check(source in ('subscription','purchased','trial','adjustment','free'));
alter table app_private.metered_operations add column free_funded boolean not null default false;
create index metered_operations_free_funded on app_private.metered_operations(period,account_id) where free_funded;

-- ── One row of AI controls: the free tier's numbers, the owner's switches, the alert thresholds ────────────────────
create table app_private.ai_controls (
 id boolean primary key default true check(id),
 free_monthly_credits integer not null default 50 check(free_monthly_credits between 0 and 1000),
 free_daily_credits integer not null default 20 check(free_daily_credits between 0 and 1000),
 -- The owner's whole monthly subsidy for free AI, and one account's share of it.
 free_pool_microusd bigint not null default 15000000 check(free_pool_microusd between 0 and 50000000),
 free_account_microusd bigint not null default 250000 check(free_account_microusd between 0 and 5000000),
 -- Model families (matched against the request's OpenRouter model) free credits may pay for, and the premium ones.
 free_models text not null default 'gemini|deepseek|haiku' check(length(free_models) between 1 and 200),
 premium_models text not null default 'sonnet|opus' check(length(premium_models) between 1 and 200),
 free_ai_paused boolean not null default false,
 cheap_models_only boolean not null default false,
 paused_features text[] not null default '{}' check(paused_features <@ array['podcasts','recommendations','figures','equations']),
 -- Apple's commission for the proceeds estimate: 15 % in the Small Business Program (recommended; owner enrolls).
 apple_commission_bp integer not null default 1500 check(apple_commission_bp between 0 and 3000),
 alert_spend_income_ratio numeric not null default 0.6 check(alert_spend_income_ratio>0 and alert_spend_income_ratio<=10),
 alert_min_proceeds_microusd bigint not null default 20000000 check(alert_min_proceeds_microusd>=0),
 updated_at timestamptz not null default now()
);
insert into app_private.ai_controls default values;
alter table app_private.ai_controls enable row level security;
revoke all on app_private.ai_controls from public,anon,authenticated,service_role;

-- ── Products: the accepted plan (US prices for the proceeds estimate) ──────────────────────────────────────────────
-- period_months: 1 for monthly plans, 12 for annual (credits are per month of the paid year), null for packs.
alter table app_private.store_products add column period_months integer check(period_months in (1,12));
alter table app_private.store_products add column price_microusd bigint check(price_microusd between 0 and 1000000000);
alter table app_private.store_products add column intro_price_microusd bigint check(intro_price_microusd between 0 and 1000000000);
update app_private.store_products set period_months=1,credits=600,price_microusd=7990000,intro_price_microusd=3990000
 where product_id='com.sciencereader.ios.standard.monthly';
update app_private.store_products set period_months=1,credits=2000,price_microusd=19990000 where product_id='com.sciencereader.ios.pro.monthly';
-- Retired for new sales in App Store Connect (owner action); restores and refunds of earlier purchases keep working.
update app_private.store_products set price_microusd=4990000 where product_id='com.sciencereader.ios.credits.400';
insert into app_private.store_products(product_id,kind,plan,credits,active,period_months,price_microusd) values
 ('com.sciencereader.ios.standard.annual','subscription','standard',600,true,12,79990000),
 ('com.sciencereader.ios.pro.annual','subscription','pro',2000,true,12,199990000),
 ('com.sciencereader.ios.credits.300','credits',null,300,true,null,4990000),
 ('com.sciencereader.ios.credits.700','credits',null,700,true,null,9990000);
alter table app_private.store_products add check((kind='subscription')=(period_months is not null));

-- An annual plan's first month is granted when the purchase is recorded (the bucket ends after one month); the other
-- eleven are issued by app_private.issue_allowances. Otherwise 044's function, unchanged.
create or replace function app_private.store_grant(p_env text,p_tid text,p_otid text,p_account uuid,p_product text,p_quantity integer,
 p_purchased timestamptz,p_expires timestamptz,p_reason text,p_app_transaction text,out granted bigint,out bucket uuid)
language plpgsql security definer set search_path = '' as $$
declare product app_private.store_products; cap bigint; used bigint;
 requested bigint; account_used bigint:=0; identity_used bigint:=0; decision text; identity text:=p_app_transaction;
 month_start timestamptz:=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC';
begin
 granted:=0; bucket:=null;
 select * into strict product from app_private.store_products where product_id=p_product;
 if product.kind='subscription' then
  if p_expires is null or not isfinite(p_expires) then raise exception 'invalid_store_transaction'; end if;
  if p_expires<=now() then return; end if;
 end if;
 granted:=product.credits*p_quantity; requested:=granted;
 select monthly_credit_cap into cap from app_private.store_policy where environment=p_env;
 if p_env='Sandbox' then
  if identity is null then
   select app_transaction_id into identity from app_private.store_seen where environment=p_env and transaction_id=p_tid;
  end if;
  select coalesce(sum(credits),0) into account_used from app_private.store_transactions
   where environment='Sandbox' and account_id=p_account and granted_at>=month_start and credits>0;
  if identity is null then granted:=0; decision:='identity_missing';
  else
   select coalesce(sum(credits),0) into identity_used from app_private.store_transactions
    where environment='Sandbox' and app_transaction_id=identity and granted_at>=month_start and credits>0;
   granted:=least(granted,greatest(cap-account_used,0),greatest(cap-identity_used,0));
   decision:=case when granted=requested then 'granted' when granted>0 then 'partial_allowance'
    when account_used>=cap and identity_used>=cap then 'both_allowances_exhausted'
    when account_used>=cap then 'account_allowance_exhausted' else 'apple_allowance_exhausted' end;
  end if;
  insert into app_private.store_sandbox_decisions(transaction_id,period,account_id,app_transaction_id,reason,
   requested_credits,granted_credits,account_used_before,identity_used_before,credit_cap)
   values(p_tid,(month_start at time zone 'UTC')::date,p_account,identity,decision,requested,granted,account_used,identity_used,cap)
   on conflict(transaction_id,period,reason) do nothing;
 elsif cap is not null then
  select coalesce(sum(credits),0) into used from app_private.store_transactions
   where environment=p_env and granted_at>=month_start
    and (account_id=p_account or (p_app_transaction is not null and app_transaction_id=p_app_transaction));
  granted:=least(granted,greatest(cap-used,0));
 end if;
 if granted=0 then return; end if;
 bucket:=public.worker_grant_credits(p_account,case when product.kind='credits' then 'purchased' else 'subscription' end,
  p_env||':'||p_tid,granted,least(p_purchased,now()),
  case when product.kind<>'subscription' then null
   when product.period_months=12 then greatest(least(p_expires,p_purchased+interval '1 month'),least(p_purchased,now())+interval '1 second')
   else p_expires end,
  case when product.kind='credits' then 'App Store credit purchase' else 'App Store subscription allowance' end);
end $$;

-- A refunded annual plan also loses the unspent credits of the months issued after its first (the first month's bucket
-- is the transaction's own and is handled by the recorder, as before).
create function app_private.store_annual_months_revoked() returns trigger language plpgsql security definer set search_path='' as $$
declare b app_private.credit_buckets;
begin
 if old.revoked_at is null and new.revoked_at is not null then
  for b in select * from app_private.credit_buckets where source='subscription' and account_id=new.account_id
    and external_key like new.environment||':'||new.transaction_id||':m%' and revoked_at is null order by id loop
   perform app_private.store_remove_unspent(b.id,'store-revoke-month:'||b.external_key,'App Store refund of an annual plan');
  end loop;
 end if;
 return new;
end $$;
revoke all on function app_private.store_annual_months_revoked() from public,anon,authenticated;
create trigger store_annual_months_revoked after update of revoked_at on app_private.store_transactions
 for each row execute function app_private.store_annual_months_revoked();

-- ── Free AI: who gets it, what is used, and the allowances issued lazily ───────────────────────────────────────────
create function app_private.month_start() returns timestamptz language sql stable set search_path='' as $$
 select date_trunc('month',now() at time zone 'UTC') at time zone 'UTC'
$$;

-- An open, unsuspended reader account with no active plan and no testing allowance; never a synthetic test account.
create function app_private.free_ai_eligible(p_account uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.accounts a where a.id=p_account and a.closed_at is null and not a.spending_suspended)
  and not app_private.is_test_account(p_account)
  and not exists(select 1 from app_private.testing_allowances t where t.account_id=p_account and t.enabled)
  and not exists(select 1 from app_private.store_transactions st join app_private.store_products p using(product_id)
   where st.account_id=p_account and p.kind='subscription' and st.revoked_at is null and st.expires_at>now())
$$;

-- Free-funded worst case this month: settled cost plus any liability still held, or the whole ceiling while open.
create function app_private.free_pool_used(p_account uuid default null) returns bigint
language sql stable security definer set search_path='' as $$
 select coalesce(sum(case when state='settled' then coalesce(actual_microusd,0)+provider_liability_microusd else spend_ceiling_microusd end),0)::bigint
 from app_private.metered_operations
 where free_funded and period=(app_private.month_start() at time zone 'UTC')::date and (p_account is null or account_id=p_account)
$$;

create function app_private.free_credits_today(p_account uuid) returns bigint
language sql stable security definer set search_path='' as $$
 select coalesce(sum(case when state='settled' then actual_credits else credit_ceiling end),0)::bigint
 from app_private.metered_operations
 where free_funded and account_id=p_account and created_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
   and period=(app_private.month_start() at time zone 'UTC')::date
$$;

create function app_private.free_bucket(p_account uuid) returns app_private.credit_buckets
language sql stable security definer set search_path='' as $$
 select * from app_private.credit_buckets where source='free'
  and external_key='free:'||to_char(app_private.month_start() at time zone 'UTC','YYYY-MM')||':'||p_account::text
$$;

-- Lazily issues what is due now: this month's free credits, and this month of each annual plan. Idempotent (each bucket
-- has a stable key); takes the account lock only when it grants.
create function app_private.issue_allowances(p_account uuid) returns void
language plpgsql security definer set search_path='' as $$
declare c app_private.ai_controls; t record; k integer; starts timestamptz; ends timestamptz; m timestamptz:=app_private.month_start(); key text;
begin
 for t in select st.environment,st.transaction_id,st.purchased_at,st.expires_at,p.credits
   from app_private.store_transactions st join app_private.store_products p using(product_id)
   where st.account_id=p_account and p.kind='subscription' and p.period_months=12 and st.revoked_at is null
    and st.expires_at>now() and st.credits>0
    and not exists(select 1 from app_private.store_transactions n where n.environment=st.environment
     and n.original_transaction_id=st.original_transaction_id and n.purchased_at>st.purchased_at) loop
  k:=(extract(year from age(now(),t.purchased_at))*12+extract(month from age(now(),t.purchased_at)))::integer;
  if k between 1 and 11 then
   starts:=t.purchased_at+make_interval(months=>k); ends:=least(t.purchased_at+make_interval(months=>k+1),t.expires_at);
   key:=t.environment||':'||t.transaction_id||':m'||k;
   if ends>now() and not exists(select 1 from app_private.credit_buckets where source='subscription' and external_key=key) then
    perform public.worker_grant_credits(p_account,'subscription',key,t.credits,starts,ends,'App Store annual plan, month '||(k+1));
   end if;
  end if;
 end loop;
 select * into c from app_private.ai_controls;
 if c.free_monthly_credits>0 and (app_private.free_bucket(p_account)).id is null and app_private.free_ai_eligible(p_account) then
  perform public.worker_grant_credits(p_account,'free','free:'||to_char(m at time zone 'UTC','YYYY-MM')||':'||p_account::text,
   c.free_monthly_credits,m,m+interval '1 month','Free AI allowance');
 end if;
end $$;

-- What the reader is told about free AI (null when the account is not on the free tier). `reason` is why it cannot pay
-- right now: used (this month's credits are spent), daily (today's share), account (its monthly cost share), pool
-- (everyone's free AI for the month is used), paused (the owner paused it). `resumes_at` is when it comes back.
create function app_private.free_ai_state(p_account uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare c app_private.ai_controls; b app_private.credit_buckets; reason text; available bigint; resumes timestamptz;
 next_month timestamptz:=app_private.month_start()+interval '1 month';
begin
 if not app_private.free_ai_eligible(p_account) then return null; end if;
 select * into c from app_private.ai_controls;
 b:=app_private.free_bucket(p_account);
 available:=case when b.id is null or b.revoked_at is not null then 0 else greatest(b.balance-b.reserved,0) end;
 reason:=case when c.free_ai_paused then 'paused'
  when c.free_pool_microusd-app_private.free_pool_used()<c.free_account_microusd then 'pool'
  when available=0 and b.id is not null then 'used'
  when app_private.free_pool_used(p_account)>=c.free_account_microusd then 'account'
  when app_private.free_credits_today(p_account)>=c.free_daily_credits then 'daily' end;
 resumes:=case when reason='paused' then null when reason='daily' then date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'+interval '1 day'
  else next_month end;
 return jsonb_build_object('monthly',c.free_monthly_credits,'available',available,'usable',reason is null and c.free_monthly_credits>0,
  'reason',reason,'resumes_at',resumes,'daily',c.free_daily_credits);
end $$;

revoke all on function app_private.month_start(),app_private.free_ai_eligible(uuid),app_private.free_pool_used(uuid),
 app_private.free_credits_today(uuid),app_private.free_bucket(uuid),app_private.issue_allowances(uuid),app_private.free_ai_state(uuid)
 from public,anon,authenticated;

-- ── Reservation: free credits only where the reservation says so ───────────────────────────────────────────────────
-- 094's core, with one change: a `free` bucket is used only when the wrapper below set gradstep.free_allowed for this
-- transaction, and then right after the testing bucket (free credits expire first). Everything else is unchanged.
create or replace function app_private.reserve_operation_before_034(p_account_id uuid,p_id uuid,p_kind text,p_request_sha256 bytea,
 p_rate_version text,p_credits bigint,p_microusd bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare period_start date := date_trunc('month',now() at time zone 'UTC')::date;
 budget app_private.platform_budgets; op app_private.metered_operations; b app_private.credit_buckets; remaining bigint:=p_credits; held bigint;
 free_allowed boolean:=coalesce(current_setting('gradstep.free_allowed',true),'')='on';
begin
 if p_credits is null or p_microusd is null or p_credits<0 or p_microusd<0 then raise exception 'invalid_reservation'; end if;
 select * into strict budget from app_private.platform_budgets where period=period_start for update;
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null for update;
 if not found then raise exception 'account_unavailable'; end if;
 select * into op from app_private.metered_operations where account_id=p_account_id and id=p_id;
 if found then
  if op.kind is distinct from p_kind or op.request_sha256 is distinct from p_request_sha256 or op.rate_version is distinct from p_rate_version
    or op.credit_ceiling<>p_credits or op.spend_ceiling_microusd<>p_microusd then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('id',op.id,'state',op.state,'replayed',true);
 end if;
 if not budget.work_enabled or budget.spent_microusd+budget.reserved_microusd+p_microusd>budget.limit_microusd then raise exception 'platform_budget_exhausted'; end if;
 if (select count(*) from app_private.metered_operations where account_id=p_account_id and state<>'settled')>=3 then raise exception 'too_many_active_operations'; end if;
 insert into app_private.metered_operations(account_id,id,kind,request_sha256,rate_version,period,credit_ceiling,spend_ceiling_microusd,state)
 values(p_account_id,p_id,p_kind,p_request_sha256,p_rate_version,period_start,p_credits,p_microusd,'reserved');
 for b in select * from app_private.credit_buckets where account_id=p_account_id and revoked_at is null and starts_at<=now() and (expires_at is null or expires_at>now())
   and balance>reserved and (source<>'free' or free_allowed)
   order by (id=coalesce((select t.bucket_id from app_private.testing_allowances t where t.account_id=p_account_id and t.enabled),'00000000-0000-0000-0000-000000000000'::uuid)) desc,
    (source='free') desc,expires_at nulls last,id for update loop
  exit when remaining=0;
  held:=least(remaining,b.balance-b.reserved);
  update app_private.credit_buckets set reserved=reserved+held where id=b.id;
  insert into app_private.reservation_allocations values(p_account_id,p_id,b.id,held);
  insert into app_private.credit_ledger(account_id,bucket_id,operation_id,entry_key,kind,balance_delta,reserved_delta,reason)
    values(p_account_id,b.id,p_id,'hold:'||p_id,'hold',0,held,'Reserved before provider submission');
  remaining:=remaining-held;
 end loop;
 if remaining>0 then raise exception 'insufficient_credits'; end if;
 update app_private.platform_budgets set reserved_microusd=reserved_microusd+p_microusd where period=period_start;
 return jsonb_build_object('id',p_id,'state','reserved','replayed',false);
end $$;

-- The wrapper every paid operation goes through (chat, figures, equations, study, podcasts, recommendations). Same lock
-- order as before (budget, then account); the pool and the account's share are checked under those locks, so
-- concurrent reservations are counted in turn and free spend can never pass the pool.
alter function public.worker_reserve_operation(uuid,uuid,text,bytea,text,bigint,bigint) rename to reserve_operation_before_0150;
alter function public.reserve_operation_before_0150(uuid,uuid,text,bytea,text,bigint,bigint) set schema app_private;
revoke all on function app_private.reserve_operation_before_0150(uuid,uuid,text,bytea,text,bigint,bigint) from public,anon,authenticated,service_role;
create function public.worker_reserve_operation(p_account_id uuid,p_id uuid,p_kind text,p_request_sha256 bytea,
 p_rate_version text,p_credits bigint,p_microusd bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c app_private.ai_controls; eligible boolean; free_ok boolean:=false; result jsonb; fb app_private.credit_buckets;
begin
 perform 1 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date for update;
 perform 1 from app_private.accounts where id=p_account_id for update;
 -- An exact replay is answered as before, whatever the switches say now.
 if exists(select 1 from app_private.metered_operations where account_id=p_account_id and id=p_id) then
  return app_private.reserve_operation_before_0150(p_account_id,p_id,p_kind,p_request_sha256,p_rate_version,p_credits,p_microusd);
 end if;
 select * into c from app_private.ai_controls;
 -- The owner's feature switches. `platform_budget_exhausted` is the code every client already shows as "paused".
 if (p_kind='podcast' and 'podcasts'=any(c.paused_features)) or (p_kind='recommend' and 'recommendations'=any(c.paused_features)) then
  raise exception 'platform_budget_exhausted';
 end if;
 if coalesce(p_credits,0)>0 then perform app_private.issue_allowances(p_account_id); end if;
 eligible:=p_kind='recommend' or (p_kind='chat' and coalesce(current_setting('gradstep.free_eligible',true),'')='on');
 if eligible and not c.free_ai_paused then
  fb:=app_private.free_bucket(p_account_id);
  free_ok:=fb.id is not null and fb.revoked_at is null and fb.balance>fb.reserved and fb.expires_at>now()
   and app_private.free_pool_used()+coalesce(p_microusd,0)<=c.free_pool_microusd
   and app_private.free_pool_used(p_account_id)<c.free_account_microusd
   and app_private.free_credits_today(p_account_id)<c.free_daily_credits;
 end if;
 perform set_config('gradstep.free_allowed',case when free_ok then 'on' else 'off' end,true);
 result:=app_private.reserve_operation_before_0150(p_account_id,p_id,p_kind,p_request_sha256,p_rate_version,p_credits,p_microusd);
 perform set_config('gradstep.free_allowed','off',true);
 if free_ok and exists(select 1 from app_private.reservation_allocations ra join app_private.credit_buckets b on b.id=ra.bucket_id
   where ra.account_id=p_account_id and ra.operation_id=p_id and b.source='free') then
  update app_private.metered_operations set free_funded=true where account_id=p_account_id and id=p_id;
 end if;
 return result;
end $$;
revoke all on function public.worker_reserve_operation(uuid,uuid,text,bytea,text,bigint,bigint) from public,anon,authenticated;
grant execute on function public.worker_reserve_operation(uuid,uuid,text,bytea,text,bigint,bigint) to service_role;

-- Chat: whether free credits may pay is decided from the frozen quote (a fast model), and premium models
-- are refused while the owner has "cheaper models only" on. The signature is unchanged.
alter function public.worker_reserve_chat(uuid,uuid,bytea,text,bigint,bigint,jsonb) rename to reserve_chat_before_0150;
alter function public.reserve_chat_before_0150(uuid,uuid,bytea,text,bigint,bigint,jsonb) set schema app_private;
revoke all on function app_private.reserve_chat_before_0150(uuid,uuid,bytea,text,bigint,bigint,jsonb) from public,anon,authenticated,service_role;
create function public.worker_reserve_chat(p_account_id uuid,p_id uuid,p_request_sha256 bytea,p_rate_version text,
 p_credits bigint,p_microusd bigint,p_quote jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c app_private.ai_controls; model text; result jsonb;
begin
 select * into c from app_private.ai_controls;
 model:=case when jsonb_typeof(p_quote->'model')='string' then p_quote->>'model' else '' end;
 if c.cheap_models_only and model ~* c.premium_models
  and not exists(select 1 from app_private.metered_operations where account_id=p_account_id and id=p_id) then
  raise exception 'platform_budget_exhausted';
 end if;
 -- Web search is not refused here: the chat function does not offer it on free answers (prepaid search is kept for paying
 -- readers), and an older chat function that offers it is still bounded by the pool and Tavily's own allowances.
 perform set_config('gradstep.free_eligible',case when model ~* c.free_models and not model ~* c.premium_models then 'on' else 'off' end,true);
 result:=app_private.reserve_chat_before_0150(p_account_id,p_id,p_request_sha256,p_rate_version,p_credits,p_microusd,p_quote);
 perform set_config('gradstep.free_eligible','off',true);
 return result;
end $$;
revoke all on function public.worker_reserve_chat(uuid,uuid,bytea,text,bigint,bigint,jsonb) from public,anon,authenticated;
grant execute on function public.worker_reserve_chat(uuid,uuid,bytea,text,bigint,bigint,jsonb) to service_role;

-- The switches the chat function reads before it reserves (a clearer refusal than the database's backstop above), and
-- for the published defaults while "cheaper models only" is on.
create function public.worker_ai_switches() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('free_ai_paused',free_ai_paused,'cheap_models_only',cheap_models_only,'paused_features',to_jsonb(paused_features),
  'premium_models',premium_models,'free_models',free_models) from app_private.ai_controls
$$;
revoke all on function public.worker_ai_switches() from public,anon,authenticated;
grant execute on function public.worker_ai_switches() to service_role;

-- ── The reader's balance: issues what is due, leaves out free credits that cannot pay now, and says why ───────────
create or replace function public.v1_credit_balance() returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare actor uuid:=app_private.require_actor(); free jsonb; unusable bigint:=0; result jsonb;
begin
 perform app_private.issue_allowances(actor);
 free:=app_private.free_ai_state(actor);
 if free is not null and not (free->>'usable')::boolean then unusable:=(free->>'available')::bigint; end if;
 select jsonb_build_object(
  'available',greatest(coalesce(sum(balance-reserved) filter(where revoked_at is null and starts_at<=now() and (expires_at is null or expires_at>now())),0)-unusable,0),
  'reserved',coalesce(sum(reserved),0),
  'unlimited_testing',exists(select 1 from app_private.testing_allowances t join app_private.accounts a on a.id=t.account_id
   where t.account_id=actor and t.enabled and a.closed_at is null and not a.spending_suspended),
  'free',free)
 into result from app_private.credit_buckets where account_id=actor;
 return result;
end $$;
revoke all on function public.v1_credit_balance() from public,anon;
grant execute on function public.v1_credit_balance() to authenticated;

-- The active plan, with whether it is billed monthly or yearly.
create or replace function public.v1_store_summary() returns jsonb language sql stable security definer set search_path = '' as $$
 select coalesce((select jsonb_build_object('plan',p.plan,'product_id',t.product_id,'expires_at',t.expires_at,'period_months',p.period_months)
  from app_private.store_transactions t join app_private.store_products p using(product_id)
  where t.account_id=app_private.require_actor() and p.kind='subscription' and t.revoked_at is null and t.expires_at>now()
  order by t.expires_at desc limit 1),jsonb_build_object('plan',null))
$$;

-- ── Spend vs income (owner + MFA) ──────────────────────────────────────────────────────────────────────────────────
-- Funding of an operation: free credits, the owner's testing allowance, paid (plan or pack credits), granted (operator
-- adjustments, tester starting credits, workflow checks) or platform (no customer credits: tags, curated podcasts).
create function app_private.operation_funding(p_account uuid,p_operation uuid) returns text
language sql stable security definer set search_path='' as $$
 select case when bool_or(o.free_funded) then 'free'
  when bool_or(t.account_id is not null) then 'testing'
  when bool_or(b.source in ('subscription','purchased')) then 'paid'
  when bool_or(b.source in ('adjustment','trial')) then 'granted'
  else 'platform' end
 from app_private.metered_operations o
 left join app_private.reservation_allocations ra on ra.account_id=o.account_id and ra.operation_id=o.id
 left join app_private.credit_buckets b on b.id=ra.bucket_id
 left join app_private.testing_allowances t on t.bucket_id=b.id
 where o.account_id=p_account and o.id=p_operation
$$;

-- Estimated App Store proceeds of one month from verified transactions: each purchase or renewal at its product's
-- configured US price (a plan's first purchase at the introductory price when one is configured: conservative), less
-- refunds made that month, times (1 - commission). Not Apple's financial report: no VAT, currency or timing adjustment.
create function app_private.store_proceeds(p_period date,p_environment text) returns jsonb
language sql stable security definer set search_path='' as $$
 with c as (select apple_commission_bp bp from app_private.ai_controls),
 t as (
  select st.product_id,st.quantity,st.purchased_at,st.revoked_at,p.kind,
   case when p.intro_price_microusd is not null and st.transaction_id=st.original_transaction_id then p.intro_price_microusd
    else p.price_microusd end*st.quantity price
  from app_private.store_transactions st join app_private.store_products p using(product_id)
  where st.environment=p_environment
   and ((st.purchased_at>=p_period and st.purchased_at<p_period+interval '1 month')
    or (st.revoked_at>=p_period and st.revoked_at<p_period+interval '1 month'))),
 by_product as (
  select product_id,count(*) filter(where purchased_at>=p_period and purchased_at<p_period+interval '1 month') purchases,
   coalesce(sum(price) filter(where purchased_at>=p_period and purchased_at<p_period+interval '1 month'),0) gross,
   count(*) filter(where revoked_at>=p_period and revoked_at<p_period+interval '1 month') refunds,
   coalesce(sum(price) filter(where revoked_at>=p_period and revoked_at<p_period+interval '1 month'),0) refunded
  from t group by product_id)
 select jsonb_build_object('purchases',coalesce(sum(purchases),0),'refunds',coalesce(sum(refunds),0),
  'gross_microusd',coalesce(sum(gross),0),'refunded_microusd',coalesce(sum(refunded),0),
  'proceeds_microusd',round((coalesce(sum(gross),0)-coalesce(sum(refunded),0))*(10000-(select bp from c))/10000.0)::bigint,
  'by_product',coalesce(jsonb_agg(jsonb_build_object('product_id',product_id,'purchases',purchases,'gross_microusd',gross,
   'refunds',refunds,'refunded_microusd',refunded) order by gross desc),'[]'::jsonb))
 from by_product
$$;

create function app_private.spend_income_figures() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare m timestamptz:=app_private.month_start(); mon date:=(app_private.month_start() at time zone 'UTC')::date;
 c app_private.ai_controls; budget app_private.platform_budgets; spend jsonb; production jsonb; sandbox jsonb; previous jsonb;
 elapsed numeric; days numeric; total bigint; proceeds bigint; fixed bigint; fixed_missing integer;
begin
 select * into c from app_private.ai_controls;
 select * into budget from app_private.platform_budgets where platform_budgets.period=mon;
 elapsed:=greatest(extract(epoch from now()-m)/86400.0,0.0001);
 days:=extract(epoch from (m+interval '1 month')-m)/86400.0;
 with a as (
  select p.account_id,p.operation_id,p.model,app_private.cost_feature(p.route,p.transport_metadata->>'feature') feature,
   coalesce(p.actual_microusd,0) cost,case when p.state in ('admitted','unknown') then p.ceiling_microusd else 0 end held
  from app_private.provider_attempts p where p.created_at>=m and p.state<>'denied'),
 f as (select a.*,app_private.operation_funding(a.account_id,a.operation_id) funding from a)
 select jsonb_build_object('cost_microusd',coalesce(sum(cost),0),'held_microusd',coalesce(sum(held),0),
  'by_funding',coalesce((select jsonb_object_agg(funding,s) from (select funding,sum(cost)::bigint s from f group by funding) x),'{}'::jsonb),
  'by_feature',coalesce((select jsonb_agg(jsonb_build_object('feature',feature,'cost_microusd',s,'attempts',n) order by s desc)
   from (select feature,sum(cost)::bigint s,count(*) n from f group by feature) x),'[]'::jsonb),
  'by_model',coalesce((select jsonb_agg(jsonb_build_object('model',model,'cost_microusd',s,'attempts',n) order by s desc)
   from (select model,sum(cost)::bigint s,count(*) n from f group by model order by sum(cost) desc limit 12) x),'[]'::jsonb))
 into spend from f;
 total:=(spend->>'cost_microusd')::bigint;
 production:=app_private.store_proceeds(mon,'Production');
 sandbox:=app_private.store_proceeds(mon,'Sandbox');
 previous:=app_private.store_proceeds((mon-interval '1 month')::date,'Production');
 proceeds:=(production->>'proceeds_microusd')::bigint;
 -- Fixed costs the owner recorded for this month (Spending › evidence): the latest commitment or forecast per component.
 select coalesce(sum(amount_microusd),0),(select count(*) from app_private.spending_cost_components k where k.required
   and not exists(select 1 from app_private.spending_cost_observations o where o.component=k.id and o.period=mon
    and o.measure in ('commitment','forecast')))
 into fixed,fixed_missing
 from (select distinct on (component) amount_microusd from app_private.spending_cost_observations o
  where o.period=mon and o.measure in ('commitment','forecast') order by component,observed_at desc,recorded_at desc) x;
 return jsonb_build_object('period',mon,'generated_at',now(),'days_elapsed',round(elapsed,2),'days_in_month',days,
  'spend',spend,
  'budget',case when budget.period is null then null else jsonb_build_object('limit_microusd',budget.limit_microusd,
   'spent_microusd',budget.spent_microusd,'reserved_microusd',budget.reserved_microusd,'work_enabled',budget.work_enabled) end,
  'fixed',jsonb_build_object('recorded_microusd',fixed,'components_missing',fixed_missing),
  'income',jsonb_build_object('method','estimate','commission_bp',c.apple_commission_bp,'production',production,'sandbox',sandbox,
   'previous_month_production',previous),
  'ratio',case when proceeds>0 then round(total::numeric/proceeds,3) end,
  'forecast',jsonb_build_object('spend_microusd',round(total*days/elapsed)::bigint,
   'proceeds_microusd',round(proceeds*days/elapsed)::bigint,'early',elapsed<3),
  'free',jsonb_build_object('pool_microusd',c.free_pool_microusd,'used_microusd',app_private.free_pool_used(),
   'account_microusd',c.free_account_microusd,'monthly_credits',c.free_monthly_credits,'daily_credits',c.free_daily_credits,
   'accounts',(select count(distinct account_id) from app_private.metered_operations where free_funded and metered_operations.period=mon),
   'operations',(select count(*) from app_private.metered_operations where free_funded and metered_operations.period=mon),
   -- Accepted growth rule, applied only by the owner: max($15, 10 % of last month's estimated Production proceeds).
   'suggested_pool_microusd',greatest(15000000,((previous->>'proceeds_microusd')::bigint)/10)),
  'switches',jsonb_build_object('free_ai_paused',c.free_ai_paused,'cheap_models_only',c.cheap_models_only,
   'paused_features',to_jsonb(c.paused_features),'all_ai_paused',not coalesce(budget.work_enabled,false)),
  'alerts',jsonb_build_object('spend_income_ratio',c.alert_spend_income_ratio,'min_proceeds_microusd',c.alert_min_proceeds_microusd,
   'recent',coalesce((select jsonb_agg(jsonb_build_object('kind',kind,'period',a.period,'created_at',created_at,'delivery',delivery,
     'attempts',attempts,'delivered_at',delivered_at,'details',details) order by created_at desc)
    from (select * from app_private.spend_alerts order by created_at desc limit 20) a),'[]'::jsonb)));
end $$;

create function public.v1_admin_spend_income() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.spending_owner(1); -- owner with MFA; the admin-spending request rate
 return app_private.spend_income_figures()||jsonb_build_object('email_configured',app_private.alert_destination() is not null);
end $$;

-- ── Owner switches: preview, set (audited, reversible), free pool size ─────────────────────────────────────────────
-- What a switch would have affected over the last 7 days: requests, accounts and provider cost, and its share of all.
create function public.v1_admin_ai_switch_preview(p_switch text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare since timestamptz; c app_private.ai_controls; result jsonb;
begin
 since:=app_private.spending_owner(7);
 if p_switch is null or p_switch not in ('free_ai','podcasts','recommendations','figures','equations','cheap_models','all_ai') then
  raise exception 'invalid_switch';
 end if;
 select * into c from app_private.ai_controls;
-- One row per operation started in the window: its provider cost (recorded plus still held; the operation's own figures
 -- when it made no attempt yet) and what it served.
 with ops as (
  select o.account_id,o.id,o.kind,o.free_funded,
   case when count(p.id)>0 then sum(coalesce(p.actual_microusd,0)+case when p.state in ('admitted','unknown') then p.ceiling_microusd else 0 end)
    when o.state='settled' then max(o.actual_microusd) else max(o.spend_ceiling_microusd) end cost,
   coalesce(bool_or(app_private.cost_feature(p.route,p.transport_metadata->>'feature')='figure_explainer'),false) figure,
   coalesce(bool_or(app_private.cost_feature(p.route,p.transport_metadata->>'feature')='equation_explainer'),false) equation,
   coalesce(bool_or(p.route='chat' and p.model ~* c.premium_models),false) premium
  from app_private.metered_operations o
  left join app_private.provider_attempts p on p.account_id=o.account_id and p.operation_id=o.id and p.state<>'denied'
  where o.created_at>=since group by o.account_id,o.id),
 hit as (select * from ops where case p_switch
   when 'free_ai' then free_funded
   when 'podcasts' then kind='podcast'
   when 'recommendations' then kind='recommend'
   when 'figures' then figure
   when 'equations' then equation
   when 'cheap_models' then premium
   else true end)
 select jsonb_build_object('switch',p_switch,'since',since,
  'requests',(select count(*) from hit),'accounts',(select count(distinct account_id) from hit),
  'cost_microusd',(select coalesce(sum(cost),0) from hit),'all_cost_microusd',(select coalesce(sum(cost),0) from ops),
  'paying_accounts',(select count(distinct h.account_id) from hit h where exists(select 1 from app_private.store_transactions st
    where st.account_id=h.account_id and st.revoked_at is null and (st.expires_at is null or st.expires_at>now()))),
  'on',case p_switch when 'free_ai' then c.free_ai_paused when 'cheap_models' then c.cheap_models_only
   when 'all_ai' then not coalesce((select work_enabled from app_private.platform_budgets where period=(app_private.month_start() at time zone 'UTC')::date),false)
   else p_switch=any(c.paused_features) end)
 into result;
 return result;
end $$;

create function public.v1_admin_set_ai_switch(p_switch text,p_on boolean,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare prior app_private.ai_controls; cur app_private.ai_controls; feature text;
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_switch is null or p_switch not in ('free_ai','podcasts','recommendations','figures','equations','cheap_models','all_ai') or p_on is null then
  raise exception 'invalid_switch';
 end if;
 if p_reason is null or length(btrim(p_reason)) not between 3 and 500 then raise exception 'invalid_reason'; end if;
 if p_switch='all_ai' then
  perform public.v1_admin_pause_work(p_on,btrim(p_reason)); -- the existing audited pause (every month already created)
  return jsonb_build_object('switch',p_switch,'on',p_on);
 end if;
 select * into prior from app_private.ai_controls for update;
 feature:=case when p_switch in ('podcasts','recommendations','figures','equations') then p_switch end;
 update app_private.ai_controls set
  free_ai_paused=case when p_switch='free_ai' then p_on else free_ai_paused end,
  cheap_models_only=case when p_switch='cheap_models' then p_on else cheap_models_only end,
  paused_features=case when feature is null then paused_features
   when p_on then array(select distinct x from unnest(paused_features||feature) x order by x)
   else array_remove(paused_features,feature) end,
  updated_at=now()
 returning * into cur;
 insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
 values(app_private.actor(),'ai_switch',p_switch,btrim(p_reason),jsonb_build_object('on',p_on,
  'before',jsonb_build_object('free_ai_paused',prior.free_ai_paused,'cheap_models_only',prior.cheap_models_only,'paused_features',to_jsonb(prior.paused_features)),
  'after',jsonb_build_object('free_ai_paused',cur.free_ai_paused,'cheap_models_only',cur.cheap_models_only,'paused_features',to_jsonb(cur.paused_features))));
 return jsonb_build_object('switch',p_switch,'on',p_on);
end $$;

-- The free pool's size (never above the month's schema ceiling). Raising it spends more of the owner's money, so it is
-- an audited owner action, never automatic (the accepted growth rule is only shown as a suggestion).
create function public.v1_admin_set_free_pool(p_pool_microusd bigint,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare prior bigint;
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_pool_microusd is null or p_pool_microusd not between 0 and 50000000 then raise exception 'invalid_pool'; end if;
 if p_reason is null or length(btrim(p_reason)) not between 3 and 500 then raise exception 'invalid_reason'; end if;
 select free_pool_microusd into prior from app_private.ai_controls for update;
 update app_private.ai_controls set free_pool_microusd=p_pool_microusd,updated_at=now();
 insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
 values(app_private.actor(),'free_pool','free_ai',btrim(p_reason),jsonb_build_object('before_microusd',prior,'after_microusd',p_pool_microusd));
 return jsonb_build_object('pool_microusd',p_pool_microusd);
end $$;

-- ── Alerts: evaluated and emailed by a database tick; the table is both the audit trail and the throttle ───────────
create table app_private.spend_alerts (
 id uuid primary key default gen_random_uuid(),
 period date not null check(extract(day from period)=1),
 kind text not null check(kind in ('budget_50','budget_80','budget_100','free_pool_exhausted','spend_over_income')),
 created_at timestamptz not null default now(),
 details jsonb not null check(jsonb_typeof(details)='object' and octet_length(details::text)<=2048),
 delivery text not null default 'pending' check(delivery in ('pending','sent','failed','not_configured')),
 attempts integer not null default 0 check(attempts between 0 and 10),
 request_id bigint,
 delivered_at timestamptz,
 unique(period,kind)
);
alter table app_private.spend_alerts enable row level security;
revoke all on app_private.spend_alerts from public,anon,authenticated,service_role;

-- Where alerts go: Vault's science_reader_alert_email when set (deploy-staging.py writes OWNER_ALERT_EMAIL there),
-- otherwise the sign-in email of the first owner account. Never stored in source or in this table.
create function app_private.alert_destination() returns text
language plpgsql stable security definer set search_path='' as $$
declare v text;
begin
 if to_regclass('vault.decrypted_secrets') is not null then
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into v using 'science_reader_alert_email';
 end if;
 if v is null or v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
  select u.email into v from app_private.app_roles r join auth.users u on u.id=r.account_id
   join app_private.accounts a on a.id=r.account_id and a.closed_at is null
   where r.role='owner' and u.email is not null order by u.created_at limit 1;
 end if;
 return nullif(v,'');
end $$;

create function app_private.spend_alerts_evaluate() returns integer
language plpgsql security definer set search_path='' as $$
declare f jsonb; mon date:=(app_private.month_start() at time zone 'UTC')::date; c app_private.ai_controls; used numeric; lim numeric;
 inserted integer:=0; n integer; pool numeric; pool_used numeric; spend numeric; proceeds numeric;
begin
 select * into c from app_private.ai_controls;
 f:=app_private.spend_income_figures();
 if f->'budget' is not null and jsonb_typeof(f->'budget')='object' then
  used:=(f->'budget'->>'spent_microusd')::numeric+(f->'budget'->>'reserved_microusd')::numeric;
  lim:=greatest((f->'budget'->>'limit_microusd')::numeric,1);
  -- 100 % means new paid work is about to be refused (98 %: a typical request no longer fits).
  insert into app_private.spend_alerts(period,kind,details)
  select mon,k,jsonb_build_object('spent_microusd',(f->'budget'->>'spent_microusd')::bigint,'reserved_microusd',(f->'budget'->>'reserved_microusd')::bigint,
    'limit_microusd',(f->'budget'->>'limit_microusd')::bigint,'percent',round(used*100/lim,1),'forecast_microusd',(f->'forecast'->>'spend_microusd')::bigint)
  from (values ('budget_50',0.5),('budget_80',0.8),('budget_100',0.98)) t(k,threshold) where used>=lim*threshold
  on conflict(period,kind) do nothing;
  get diagnostics n=row_count; inserted:=inserted+n;
 end if;
 pool:=c.free_pool_microusd; pool_used:=(f->'free'->>'used_microusd')::numeric;
 if pool>0 and pool_used>=pool*0.95 then
  insert into app_private.spend_alerts(period,kind,details) values(mon,'free_pool_exhausted',
   jsonb_build_object('pool_microusd',pool::bigint,'used_microusd',pool_used::bigint,'accounts',(f->'free'->>'accounts')::bigint))
  on conflict(period,kind) do nothing;
  get diagnostics n=row_count; inserted:=inserted+n;
 end if;
 spend:=(f->'spend'->>'cost_microusd')::numeric; proceeds:=(f->'income'->'production'->>'proceeds_microusd')::numeric;
 if proceeds>=c.alert_min_proceeds_microusd and proceeds>0 and spend/proceeds>c.alert_spend_income_ratio then
  insert into app_private.spend_alerts(period,kind,details) values(mon,'spend_over_income',
   jsonb_build_object('spend_microusd',spend::bigint,'proceeds_microusd',proceeds::bigint,'ratio',round(spend/proceeds,3),
    'threshold',c.alert_spend_income_ratio))
  on conflict(period,kind) do nothing;
  get diagnostics n=row_count; inserted:=inserted+n;
 end if;
 return inserted;
end $$;

create function app_private.usd(p_microusd bigint) returns text language sql immutable set search_path='' as $$
 select '$'||to_char(coalesce(p_microusd,0)/1000000.0,'FM999990.00')
$$;

-- One digest email per tick for every new alert; a failed send is retried on later ticks (three tries in all).
create function public.worker_spend_alerts_tick() returns jsonb
language plpgsql security definer set search_path='' as $$
declare created integer; destination text; key text; sender text; body text:=''; subject text; ids uuid[]; request bigint; a record;
 resolved integer:=0;
begin
 created:=app_private.spend_alerts_evaluate();
 -- Outcomes of earlier sends (pg_net keeps responses for a while; a missing response stays pending until it appears).
 if to_regclass('net._http_response') is not null then
  execute $q$update app_private.spend_alerts a set delivery=case when r.status_code between 200 and 299 then 'sent' else 'failed' end,
    delivered_at=now() from net._http_response r where a.delivery='pending' and a.request_id=r.id$q$;
  get diagnostics resolved=row_count;
 end if;
 update app_private.spend_alerts set delivery='pending',request_id=null where delivery='failed' and attempts<3;
 select array_agg(id order by created_at) into ids from app_private.spend_alerts where delivery='pending' and request_id is null;
 if ids is null then return jsonb_build_object('created',created,'sent',0,'resolved',resolved); end if;
 destination:=app_private.alert_destination();
 if to_regclass('vault.decrypted_secrets') is not null then
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into key using 'science_reader_resend_key';
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into sender using 'science_reader_alert_from';
 end if;
 if destination is null or key is null or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
  update app_private.spend_alerts set delivery='not_configured' where id=any(ids);
  return jsonb_build_object('created',created,'sent',0,'resolved',resolved,'not_configured',cardinality(ids));
 end if;
 for a in select * from app_private.spend_alerts where id=any(ids) order by created_at,kind loop
  body:=body||case a.kind
   when 'budget_50' then '50% of '||to_char(a.period,'FMMonth')||'''s provider limit is used: '||app_private.usd((a.details->>'spent_microusd')::bigint)
    ||' spent + '||app_private.usd((a.details->>'reserved_microusd')::bigint)||' held of '||app_private.usd((a.details->>'limit_microusd')::bigint)
    ||'. Forecast for the month: '||app_private.usd((a.details->>'forecast_microusd')::bigint)||'.'
   when 'budget_80' then '80% of '||to_char(a.period,'FMMonth')||'''s provider limit is used: '||app_private.usd((a.details->>'spent_microusd')::bigint)
    ||' spent + '||app_private.usd((a.details->>'reserved_microusd')::bigint)||' held of '||app_private.usd((a.details->>'limit_microusd')::bigint)
    ||'. Forecast for the month: '||app_private.usd((a.details->>'forecast_microusd')::bigint)||'.'
   when 'budget_100' then to_char(a.period,'FMMonth')||'''s provider limit is reached ('||app_private.usd((a.details->>'limit_microusd')::bigint)
    ||'): new paid AI work is being refused until you raise the limit or the month ends.'
   when 'free_pool_exhausted' then 'This month''s free AI pool is used up ('||app_private.usd((a.details->>'used_microusd')::bigint)||' of '
    ||app_private.usd((a.details->>'pool_microusd')::bigint)||', '||(a.details->>'accounts')||' accounts). Free readers now see "free AI comes back on the 1st"; paying readers are unaffected.'
   else 'AI spend is '||(a.details->>'ratio')||'x estimated App Store proceeds this month ('||app_private.usd((a.details->>'spend_microusd')::bigint)
    ||' vs '||app_private.usd((a.details->>'proceeds_microusd')::bigint)||'; alert above '||(a.details->>'threshold')||'x).' end||E'\n\n';
 end loop;
 subject:='Gradstep spending: '||(select string_agg(case kind when 'budget_50' then '50% of limit' when 'budget_80' then '80% of limit'
  when 'budget_100' then 'limit reached' when 'free_pool_exhausted' then 'free pool used up' else 'spend high vs income' end,', ' order by created_at,kind)
  from app_private.spend_alerts where id=any(ids));
 body:=body||E'Admin › Spend vs income: https://admin.gradstep.ai/#spend%20vs%20income\nWhat to do, in order: docs/RUNBOOK_SPENDING.md\n'
  ||E'Each alert is sent once a month; this mailbox is set by OWNER_ALERT_EMAIL (or the owner account).';
 execute 'select net.http_post(url:=$1,body:=$2,headers:=$3,timeout_milliseconds:=10000)' into request
  using 'https://api.resend.com/emails',
   jsonb_build_object('from',coalesce(nullif(sender,''),'Gradstep alerts <alerts@gradstep.ai>'),'to',jsonb_build_array(destination),'subject',subject,'text',body),
   jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||key);
 update app_private.spend_alerts set request_id=request,attempts=attempts+1 where id=any(ids);
 return jsonb_build_object('created',created,'sent',cardinality(ids),'resolved',resolved);
end $$;

revoke all on function app_private.operation_funding(uuid,uuid),app_private.store_proceeds(date,text),app_private.spend_income_figures(),
 app_private.alert_destination(),app_private.spend_alerts_evaluate(),app_private.usd(bigint) from public,anon,authenticated;
revoke all on function public.v1_admin_spend_income(),public.v1_admin_ai_switch_preview(text),public.v1_admin_set_ai_switch(text,boolean,text),
 public.v1_admin_set_free_pool(bigint,text) from public,anon;
grant execute on function public.v1_admin_spend_income(),public.v1_admin_ai_switch_preview(text),public.v1_admin_set_ai_switch(text,boolean,text),
 public.v1_admin_set_free_pool(bigint,text) to authenticated;
revoke all on function public.worker_spend_alerts_tick() from public,anon,authenticated;
grant execute on function public.worker_spend_alerts_tick() to service_role;

-- Every 10 minutes, as other database tasks are scheduled (060): evaluate and email.
do $$ begin
 if to_regprocedure('cron.schedule(text,text,text)') is not null then
  perform cron.schedule('science-reader-spend-alerts','*/10 * * * *','select public.worker_spend_alerts_tick()');
 end if;
end $$;

notify pgrst,'reload schema';
commit;
