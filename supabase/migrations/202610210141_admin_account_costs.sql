-- 0141: per-account AI cost for the owner (owner, 2026-10-21: "exclusively use open router for better breakdowns of
-- user by cost"; design: docs/architecture/OPERATIONS_AND_BILLING.md "Cost per account").
-- Built from our own ledger, never from OpenRouter's dashboard: every provider attempt carries its account UUID, route,
-- model and (since 089) the feature it served; settled operations carry the credits the reader was charged. For the
-- current UTC month and the last 30 UTC days, per account: recorded provider cost (OpenRouter's reported cost, and
-- estimates where it never came), the ceilings still held by unresolved attempts, attempts, prepaid Tavily searches and
-- the credits charged, each by feature (chat, figure explainer, equation explainer, tags, podcasts, search) and by model.
-- Attempts of retired direct providers stay in the totals and are marked legacy. Owner with MFA only, rate limited as
-- the Spending tab is (spending_owner). Read only: no table changes. The account is named by its pseudonymous UUID;
-- its sign-in email is returned exactly where the Accounts tab already shows it (an account that still has a login).
begin;
set local lock_timeout='15s';

-- The feature a provider attempt served: its route, and for chat the action recorded with the dispatch (089). Chat's
-- titles, suggestions and Study maps are part of the answer they came with.
create function app_private.cost_feature(p_route text,p_feature text) returns text
language sql immutable set search_path='' as $$
 select case
  when p_route in ('chat_search','ingest_lookup','reference_lookup') then 'search'
  when p_route='catalog_tags' then 'tags'
  when left(p_route,8)='podcast_' then 'podcasts'
  when p_route='paper_ocr' then 'ocr'
  when p_route='chat' and p_feature in ('equation','equation_background') then 'equation_explainer'
  when p_route='chat' and p_feature in ('figure','figure_simpler','figure_detail') then 'figure_explainer'
  when p_route='chat' then 'chat'
  else 'other' end
$$;
revoke all on function app_private.cost_feature(text,text) from public,anon,authenticated;

-- One window's figures as the page shows them. Cost is what the ledger recorded (reported plus estimated); `held` is the
-- liability of attempts not yet resolved, never added to cost. Tavily searches are prepaid: `search_list_microusd` is
-- their pay-as-you-go value ($0.008 a credit), shown beside cost, not in it.
create function app_private.cost_window(p_reported numeric,p_estimated numeric,p_held numeric,p_attempts bigint,p_credits numeric,
 p_legacy numeric,p_charged numeric default null) returns jsonb
language sql immutable set search_path='' as $$
 select jsonb_build_object('cost_microusd',coalesce(p_reported,0)+coalesce(p_estimated,0),'reported_microusd',coalesce(p_reported,0),
  'estimated_microusd',coalesce(p_estimated,0),'held_microusd',coalesce(p_held,0),'attempts',coalesce(p_attempts,0),
  'searches',coalesce(p_credits,0),'search_list_microusd',coalesce(p_credits,0)*8000,'legacy_microusd',coalesce(p_legacy,0))
  ||case when p_charged is null then '{}'::jsonb else jsonb_build_object('credits_charged',p_charged) end
$$;
revoke all on function app_private.cost_window(numeric,numeric,numeric,bigint,numeric,numeric,numeric) from public,anon,authenticated;

create function public.v1_admin_account_costs(p_limit integer default 200) returns jsonb
language plpgsql security definer set search_path='' as $$
declare since timestamptz; month_start timestamptz:=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC'; result jsonb;
begin
 -- Owner with MFA, the admin-spending request rate; the last 30 UTC days start at `since`.
 since:=app_private.spending_owner(30);
 if p_limit is null or p_limit not between 1 and 500 then raise exception 'invalid_costs_query'; end if;
 with a as (
  select p.account_id,p.provider,p.model,app_private.cost_feature(p.route,p.transport_metadata->>'feature') feature,
   p.created_at>=month_start in_month,p.created_at>=since in_30d,
   case when p.actual_microusd is not null and coalesce((p.actual_units->>'estimated')::bigint,0)=0 then p.actual_microusd else 0 end reported,
   case when p.actual_microusd is not null and coalesce((p.actual_units->>'estimated')::bigint,0)>0 then p.actual_microusd else 0 end estimated,
   case when p.state in ('admitted','unknown') then p.ceiling_microusd else 0 end held,
   case when p.provider='tavily' and p.actual_microusd is not null then coalesce((p.actual_units->>'credits')::bigint,0) else 0 end credits,
   app_private.legacy_provider(p.provider) legacy
  from app_private.provider_attempts p
  where p.created_at>=least(since,month_start) and p.state<>'denied'),
 charged as (
  select o.account_id,sum(o.actual_credits) filter(where o.settled_at>=month_start) m,sum(o.actual_credits) filter(where o.settled_at>=since) d
  from app_private.metered_operations o where o.state='settled' and o.settled_at>=least(since,month_start) group by o.account_id),
 per_account as (
  select a.account_id,
   sum(reported) filter(where in_month) m_reported,sum(estimated) filter(where in_month) m_estimated,sum(held) filter(where in_month) m_held,
   count(*) filter(where in_month) m_attempts,sum(credits) filter(where in_month) m_credits,
   sum(reported+estimated) filter(where in_month and legacy) m_legacy,
   sum(reported) filter(where in_30d) d_reported,sum(estimated) filter(where in_30d) d_estimated,sum(held) filter(where in_30d) d_held,
   count(*) filter(where in_30d) d_attempts,sum(credits) filter(where in_30d) d_credits,
   sum(reported+estimated) filter(where in_30d and legacy) d_legacy
  from a group by a.account_id),
 per_feature as (
  select a.account_id,a.feature,
   sum(reported) filter(where in_month) m_reported,sum(estimated) filter(where in_month) m_estimated,sum(held) filter(where in_month) m_held,
   count(*) filter(where in_month) m_attempts,sum(credits) filter(where in_month) m_credits,sum(reported+estimated) filter(where in_month and legacy) m_legacy,
   sum(reported) filter(where in_30d) d_reported,sum(estimated) filter(where in_30d) d_estimated,sum(held) filter(where in_30d) d_held,
   count(*) filter(where in_30d) d_attempts,sum(credits) filter(where in_30d) d_credits,sum(reported+estimated) filter(where in_30d and legacy) d_legacy
  from a group by a.account_id,a.feature),
 per_model as (
  select a.account_id,a.provider,a.model,bool_or(a.legacy) legacy,
   sum(reported) filter(where in_month) m_reported,sum(estimated) filter(where in_month) m_estimated,sum(held) filter(where in_month) m_held,
   count(*) filter(where in_month) m_attempts,sum(credits) filter(where in_month) m_credits,sum(reported+estimated) filter(where in_month and a.legacy) m_legacy,
   sum(reported) filter(where in_30d) d_reported,sum(estimated) filter(where in_30d) d_estimated,sum(held) filter(where in_30d) d_held,
   count(*) filter(where in_30d) d_attempts,sum(credits) filter(where in_30d) d_credits,sum(reported+estimated) filter(where in_30d and a.legacy) d_legacy
  from a group by a.account_id,a.provider,a.model),
 accounts as (
  select coalesce(pa.account_id,c.account_id) account_id,pa.m_reported,pa.m_estimated,pa.m_held,pa.m_attempts,pa.m_credits,pa.m_legacy,
   pa.d_reported,pa.d_estimated,pa.d_held,pa.d_attempts,pa.d_credits,pa.d_legacy,coalesce(c.m,0) m_charged,coalesce(c.d,0) d_charged
  from per_account pa full join charged c on c.account_id=pa.account_id),
 ranked as (
  select x.*,row_number() over(order by coalesce(x.d_reported,0)+coalesce(x.d_estimated,0)+coalesce(x.d_held,0) desc,
   coalesce(x.m_reported,0)+coalesce(x.m_estimated,0)+coalesce(x.m_held,0) desc,x.d_charged desc,x.account_id) rn
  from accounts x)
 select jsonb_build_object('generated_at',now(),'month_start',month_start,'since',since,'limit',p_limit,
  'accounts_with_activity',(select count(*) from ranked),'truncated',(select count(*) from ranked)>p_limit,
  'totals',jsonb_build_object(
   'month',(select app_private.cost_window(sum(m_reported),sum(m_estimated),sum(m_held),sum(m_attempts)::bigint,sum(m_credits),sum(m_legacy),sum(m_charged)) from ranked),
   'last_30_days',(select app_private.cost_window(sum(d_reported),sum(d_estimated),sum(d_held),sum(d_attempts)::bigint,sum(d_credits),sum(d_legacy),sum(d_charged)) from ranked),
   'by_feature',(select coalesce(jsonb_agg(jsonb_build_object('feature',f.feature,
     'month',app_private.cost_window(f.mr,f.me,f.mh,f.ma,f.mc,f.ml),'last_30_days',app_private.cost_window(f.dr,f.de,f.dh,f.da,f.dc,f.dl))
     order by f.dr+f.de desc,f.feature),'[]'::jsonb)
    from (select feature,sum(m_reported) mr,sum(m_estimated) me,sum(m_held) mh,sum(m_attempts)::bigint ma,sum(m_credits) mc,sum(m_legacy) ml,
     coalesce(sum(d_reported),0) dr,coalesce(sum(d_estimated),0) de,sum(d_held) dh,sum(d_attempts)::bigint da,sum(d_credits) dc,sum(d_legacy) dl
     from per_feature group by feature) f),
   'by_model',(select coalesce(jsonb_agg(jsonb_build_object('provider',m.provider,'model',m.model,'legacy',m.legacy,
     'month',app_private.cost_window(m.mr,m.me,m.mh,m.ma,m.mc,m.ml),'last_30_days',app_private.cost_window(m.dr,m.de,m.dh,m.da,m.dc,m.dl))
     order by m.dr+m.de desc,m.provider,m.model),'[]'::jsonb)
    from (select provider,model,bool_or(legacy) legacy,sum(m_reported) mr,sum(m_estimated) me,sum(m_held) mh,sum(m_attempts)::bigint ma,sum(m_credits) mc,
     sum(m_legacy) ml,coalesce(sum(d_reported),0) dr,coalesce(sum(d_estimated),0) de,sum(d_held) dh,sum(d_attempts)::bigint da,sum(d_credits) dc,sum(d_legacy) dl
     from per_model group by provider,model) m)),
  'accounts',(select coalesce(jsonb_agg(jsonb_build_object(
    'account_id',r.account_id,
    -- The sign-in email exactly as Accounts shows it: present while the account has a login, null after deletion.
    'email',u.email,
    'synthetic',coalesce(lower(u.email) like '%@example.invalid',false),
    'test',coalesce(lower(u.email) ~ '@example\.(invalid|test)$',false),
    'closed',acct.closed_at is not null,
    'month',app_private.cost_window(r.m_reported,r.m_estimated,r.m_held,r.m_attempts,r.m_credits,r.m_legacy,r.m_charged),
    'last_30_days',app_private.cost_window(r.d_reported,r.d_estimated,r.d_held,r.d_attempts,r.d_credits,r.d_legacy,r.d_charged),
    'by_feature',(select coalesce(jsonb_agg(jsonb_build_object('feature',f.feature,
      'month',app_private.cost_window(f.m_reported,f.m_estimated,f.m_held,f.m_attempts,f.m_credits,f.m_legacy),
      'last_30_days',app_private.cost_window(f.d_reported,f.d_estimated,f.d_held,f.d_attempts,f.d_credits,f.d_legacy))
      order by coalesce(f.d_reported,0)+coalesce(f.d_estimated,0) desc,f.feature),'[]'::jsonb) from per_feature f where f.account_id=r.account_id),
    'by_model',(select coalesce(jsonb_agg(jsonb_build_object('provider',m.provider,'model',m.model,'legacy',m.legacy,
      'month',app_private.cost_window(m.m_reported,m.m_estimated,m.m_held,m.m_attempts,m.m_credits,m.m_legacy),
      'last_30_days',app_private.cost_window(m.d_reported,m.d_estimated,m.d_held,m.d_attempts,m.d_credits,m.d_legacy))
      order by coalesce(m.d_reported,0)+coalesce(m.d_estimated,0) desc,m.provider,m.model),'[]'::jsonb) from per_model m where m.account_id=r.account_id))
   order by r.rn),'[]'::jsonb)
   from ranked r left join app_private.accounts acct on acct.id=r.account_id left join auth.users u on u.id=acct.auth_user_id
   where r.rn<=p_limit))
 into result;
 return result;
end $$;
revoke all on function public.v1_admin_account_costs(integer) from public,anon;
grant execute on function public.v1_admin_account_costs(integer) to authenticated;

notify pgrst,'reload schema';
commit;
