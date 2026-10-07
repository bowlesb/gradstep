-- Owner/MFA investigation over the durable attempt ledger. Private content is
-- deliberately absent. Customer credits, cash estimates, liability, prepaid
-- units and external overhead evidence remain separate.
begin;

insert into app_private.api_rate_rules values('admin-spending',60,90,180) on conflict(route) do nothing;
create index metered_operations_investigation on app_private.metered_operations(created_at desc,account_id,id);
create index metered_operations_account_investigation on app_private.metered_operations(account_id,created_at desc,id);
create index provider_usage_investigation on app_private.provider_usage_events(created_at,account_id);

create table app_private.spending_cost_components (
 id text primary key check(id ~ '^[a-z][a-z0-9_]{0,47}$'),
 label text not null check(length(label) between 1 and 80),
 required boolean not null default true
);
insert into app_private.spending_cost_components(id,label) values
 ('tavily_subscription','Tavily subscription'),('domains','Domains, amortized'),
 ('supabase_compute','Incremental Supabase plan and compute'),('cloud_run','Cloud Run processing'),
 ('storage_egress','Storage and transfer overages'),('builds_registry','Builds and container registry'),
 ('backups','Backup hosting'),('web_hosting','Web and admin hosting');
create table app_private.spending_cost_observations (
 id uuid primary key,
 component text not null references app_private.spending_cost_components(id),
 period date not null check(extract(day from period)=1),
 measure text not null check(measure in ('commitment','forecast','invoice','metric')),
 amount_microusd bigint check(amount_microusd between 0 and 10000000000),
 complete boolean not null,
 observed_at timestamptz not null,
 source text not null check(source ~ '^[a-z][a-z0-9_-]{0,63}$'),
 evidence_reference text not null check(length(evidence_reference) between 3 and 256),
 units jsonb not null check(jsonb_typeof(units)='object' and octet_length(units::text)<=2048),
 actor_id uuid not null references app_private.accounts(id),
 recorded_at timestamptz not null default now(),
 check(not complete or amount_microusd is not null or measure='metric')
);
create index spending_cost_observation_latest on app_private.spending_cost_observations(period,component,measure,observed_at desc,recorded_at desc,id);
create trigger spending_cost_observation_immutable before update or delete on app_private.spending_cost_observations
 for each row execute function app_private.immutable_record();
alter table app_private.spending_cost_components enable row level security;
alter table app_private.spending_cost_observations enable row level security;
revoke all on app_private.spending_cost_components,app_private.spending_cost_observations from public,anon,authenticated,service_role;

create function public.worker_record_spending_observation(p_actor_id uuid,p_id uuid,p_component text,p_period date,p_measure text,
 p_amount_microusd bigint,p_complete boolean,p_observed_at timestamptz,p_source text,p_evidence_reference text,p_units jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare prior app_private.spending_cost_observations; item record;
begin
 perform app_private.require_owner_account(p_actor_id);
 if p_id is null or p_complete is null or p_observed_at is null or p_observed_at>now()+interval '5 minutes'
  or p_period is null or p_period<date '2026-10-01' or p_period>date_trunc('month',now() at time zone 'UTC')::date+interval '12 months'
  or p_evidence_reference is null or length(p_evidence_reference) not between 3 and 256
  or p_evidence_reference !~ '^[a-zA-Z0-9._:/ -]+$'
  or p_units is null or jsonb_typeof(p_units)<>'object' or octet_length(p_units::text)>2048 then raise exception 'invalid_spending_observation'; end if;
 for item in select key,value from jsonb_each(p_units) loop
  if item.key !~ '^[a-z][a-z0-9_]{0,47}$' or jsonb_typeof(item.value)<>'number'
   or item.value::text !~ '^[0-9]+(\.[0-9]+)?$' or (item.value::text)::numeric>1000000000000
  then raise exception 'invalid_spending_metric'; end if;
 end loop;
 -- Small operator-only history: capacity is explicit, never silently prune invoices.
 perform 1 from app_private.spending_cost_components where id=p_component for update;
 if not found then raise exception 'spending_component_unavailable'; end if;
 select * into prior from app_private.spending_cost_observations where id=p_id;
 if found then
  if (prior.component,prior.period,prior.measure,prior.amount_microusd,prior.complete,prior.observed_at,prior.source,prior.evidence_reference,prior.units,prior.actor_id)
   is distinct from (p_component,p_period,p_measure,p_amount_microusd,p_complete,p_observed_at,p_source,p_evidence_reference,p_units,p_actor_id)
  then raise exception 'spending_observation_id_conflict'; end if;
  return jsonb_build_object('id',prior.id,'replayed',true);
 end if;
 if (select count(*) from app_private.spending_cost_observations where component=p_component and period=p_period)>=200
 then raise exception 'spending_observation_capacity'; end if;
 insert into app_private.spending_cost_observations(id,component,period,measure,amount_microusd,complete,observed_at,source,evidence_reference,units,actor_id)
 values(p_id,p_component,p_period,p_measure,p_amount_microusd,p_complete,p_observed_at,p_source,p_evidence_reference,p_units,p_actor_id);
 return jsonb_build_object('id',p_id,'replayed',false);
end $$;

create function app_private.spending_owner(p_days integer) returns timestamptz
language plpgsql security definer set search_path='' as $$
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_days is null or p_days not between 1 and 90 then raise exception 'invalid_spending_window'; end if;
 perform public.worker_consume_request(app_private.require_actor(),'admin-spending');
 return (date_trunc('day',now() at time zone 'UTC') at time zone 'UTC')-make_interval(days=>p_days-1);
end $$;

create function public.v1_admin_spending(p_days integer default 30,p_account_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare since timestamptz; month_start date:=date_trunc('month',now() at time zone 'UTC')::date;
 budget app_private.platform_budgets; overhead jsonb; allocations bigint; missing integer;
begin
 since:=app_private.spending_owner(p_days);
 select * into budget from app_private.platform_budgets where period=month_start;
 with latest as (
  select c.id,c.label,c.required,o.id observation_id,o.measure,o.amount_microusd,o.complete,o.observed_at,o.source,o.evidence_reference
  from app_private.spending_cost_components c left join lateral (
   select * from app_private.spending_cost_observations x where x.component=c.id and x.period=month_start
    and x.measure in ('commitment','forecast') order by observed_at desc,recorded_at desc,id desc limit 1) o on true)
 select jsonb_agg(to_jsonb(latest) order by id),coalesce(sum(amount_microusd),0),
  count(*) filter(where required and (observation_id is null or not complete or observed_at<now()-interval '31 days'))
 into overhead,allocations,missing from latest;
 return jsonb_build_object('since',since,'generated_at',now(),'account_id',p_account_id,
  'coverage_started_at',(select coverage_started_at from app_private.provider_spending_policy where singleton),
  'budget',case when budget.period is null then null else to_jsonb(budget) end,
  'attempts',(select jsonb_build_object('total',count(*),'admitted',count(*) filter(where state='admitted'),
    'unknown',count(*) filter(where state='unknown'),'denied',count(*) filter(where state='denied'),
    'reported_microusd',coalesce(sum(actual_microusd) filter(where coalesce((actual_units->>'estimated')::bigint,0)=0),0),
    'estimated_microusd',coalesce(sum(actual_microusd) filter(where coalesce((actual_units->>'estimated')::bigint,0)>0),0),
    'held_microusd',coalesce(sum(ceiling_microusd) filter(where state in ('admitted','unknown')),0))
   from app_private.provider_attempts where created_at>=since and (p_account_id is null or account_id=p_account_id)),
  'unresolved',(select jsonb_build_object('total',count(*),'held_microusd',coalesce(sum(ceiling_microusd),0),
    'aged_over_hour',count(*) filter(where created_at<now()-interval '1 hour'),'oldest_at',min(created_at))
   from app_private.provider_attempts where state in ('admitted','unknown') and (p_account_id is null or account_id=p_account_id)),
  'providers',(select coalesce(jsonb_agg(g order by g->>'provider',g->>'model',g->>'route'),'[]'::jsonb) from (
   select jsonb_build_object('provider',provider,'model',model,'route',route,'attempts',count(*),
    'reported_microusd',coalesce(sum(actual_microusd) filter(where coalesce((actual_units->>'estimated')::bigint,0)=0),0),
    'estimated_microusd',coalesce(sum(actual_microusd) filter(where coalesce((actual_units->>'estimated')::bigint,0)>0),0),
    'held_microusd',coalesce(sum(ceiling_microusd) filter(where state in ('admitted','unknown')),0),
    'prepaid_used',coalesce(sum((actual_units->>'credits')::bigint) filter(where actual_microusd is not null),0),
    'prepaid_held',coalesce(sum((reserved_units->>'credits')::bigint) filter(where state in ('admitted','unknown')),0)) g
   from app_private.provider_attempts where created_at>=since and (p_account_id is null or account_id=p_account_id)
   group by provider,model,route order by count(*) desc,provider,model,route limit 100) x),
  'provider_group_limit',100,
  'customers',(select jsonb_build_object('settled_credits',coalesce(sum(actual_credits),0),
    'platform_funded_operations',count(*) filter(where credit_ceiling=0),
    'held_credits',coalesce(sum(credit_ceiling) filter(where state<>'settled'),0))
   from app_private.metered_operations where created_at>=since and (p_account_id is null or account_id=p_account_id)),
  'legacy',(select jsonb_build_object('usage_records',count(*),'estimated_microusd',coalesce(sum(u.estimated_microusd),0),
    'reconciliation_microusd',coalesce(sum((select coalesce(sum(r.adjustment_microusd),0) from app_private.provider_reconciliations r where r.usage_event_id=u.id)),0))
   from app_private.provider_usage_events u where u.created_at>=since and u.provider_event_id not like 'attempt:%'
    and u.provider in ('anthropic','mathpix','tavily') and (p_account_id is null or u.account_id=p_account_id)),
  'allowances',(select coalesce(jsonb_agg(to_jsonb(a) order by starts_at desc),'[]'::jsonb) from
   (select id,provider,starts_at,ends_at,limit_units,baseline_units,spent_units,reserved_units,enabled,overage_disabled,observed_at,evidence_reference
    from app_private.provider_allowance_periods where ends_at>=since order by starts_at desc limit 6) a),
  'forecast',jsonb_build_object('period',month_start,'operating_limit_microusd',100000000,'provider_allocation_microusd',budget.limit_microusd,
   'overhead_allocation_microusd',allocations,'funded_plan_microusd',case when budget.period is null then null else budget.limit_microusd+allocations end,
   'complete',missing=0 and budget.period is not null,'missing_components',missing,'components',overhead),
  'external_observations',(select coalesce(jsonb_agg(to_jsonb(o) order by observed_at desc,recorded_at desc,id desc),'[]'::jsonb)
   from (select id,component,period,measure,amount_microusd,complete,observed_at,source,evidence_reference,units,recorded_at
    from app_private.spending_cost_observations where period=month_start order by observed_at desc,recorded_at desc,id desc limit 40) o),
  'anomalies',jsonb_build_object('budget_paused',coalesce(not budget.work_enabled,true),
   'budget_eighty_percent',coalesce(budget.spent_microusd+budget.reserved_microusd>=budget.limit_microusd*0.8,false),
   'forecast_incomplete',missing>0 or budget.period is null,'funded_plan_over_budget',coalesce(budget.limit_microusd+allocations>100000000,false),
   'tavily_unverified',not exists(select 1 from app_private.provider_allowance_periods where enabled and starts_at<=now() and ends_at>now()),
   'native_search_gated',true,
   'attempt_capacity_eighty_percent',(select (select count(*) from app_private.provider_attempts)>=attempt_limit*0.8 from app_private.provider_spending_policy where singleton)));
end $$;

create function public.v1_admin_spending_operations(p_days integer default 30,p_account_id uuid default null,
 p_before_created_at timestamptz default null,p_before_account_id uuid default null,p_before_id uuid default null,p_limit integer default 25,p_unresolved_only boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare since timestamptz; rows jsonb; more boolean; cursor_row jsonb;
begin
 since:=app_private.spending_owner(p_days);
 if p_limit is null or p_limit not between 1 and 50 or p_unresolved_only is null
  or (p_before_created_at is null) is distinct from (p_before_account_id is null)
  or (p_before_created_at is null) is distinct from (p_before_id is null)
 then raise exception 'invalid_spending_page'; end if;
 with candidates as (
  select op.* from app_private.metered_operations op where (op.created_at>=since or p_unresolved_only) and (p_account_id is null or op.account_id=p_account_id)
   and (not p_unresolved_only or exists(select 1 from app_private.provider_attempts a where (a.account_id,a.operation_id)=(op.account_id,op.id) and a.state in ('admitted','unknown')))
   and (p_before_created_at is null or (op.created_at,op.account_id,op.id)<(p_before_created_at,p_before_account_id,p_before_id))
   order by op.created_at desc,op.account_id desc,op.id desc limit p_limit+1), numbered as (
  select op.*,row_number() over(order by op.created_at desc,op.account_id desc,op.id desc) n from candidates op)
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'account_id',account_id,'kind',kind,'state',state,'created_at',created_at,
   'settled_at',settled_at,'credit_ceiling',credit_ceiling,'actual_credits',actual_credits,'spend_ceiling_microusd',spend_ceiling_microusd,
   'settled_microusd',actual_microusd,'provider_liability_microusd',provider_liability_microusd,'attempt_accounting',attempt_accounting,
   'attempts',(select count(*) from app_private.provider_attempts a where (a.account_id,a.operation_id)=(numbered.account_id,numbered.id)),
   'current_provider_microusd',(select coalesce(sum(a.actual_microusd),0) from app_private.provider_attempts a where (a.account_id,a.operation_id)=(numbered.account_id,numbered.id)))
  order by created_at desc,account_id desc,id desc) filter(where n<=p_limit),'[]'::jsonb),coalesce(bool_or(n>p_limit),false) into rows,more from numbered;
 if more then cursor_row:=rows->(jsonb_array_length(rows)-1); end if;
 return jsonb_build_object('since',case when p_unresolved_only then null else since end,'operations',rows,'next',case when more then jsonb_build_object('created_at',cursor_row->>'created_at',
  'account_id',cursor_row->>'account_id','id',cursor_row->>'id') else null end);
end $$;

create function public.v1_admin_spending_operation(p_account_id uuid,p_operation_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare op app_private.metered_operations;
begin
 perform app_private.spending_owner(1);
 select * into op from app_private.metered_operations where account_id=p_account_id and id=p_operation_id;
 if not found then raise exception 'spending_operation_unavailable'; end if;
 return jsonb_build_object('operation',to_jsonb(op)-'request_sha256','account',(
  select jsonb_build_object('id',id,'closed',closed_at is not null,'spending_suspended',spending_suspended) from app_private.accounts where id=p_account_id),
  'attempts',(select coalesce(jsonb_agg(to_jsonb(a)-'request_sha256' order by a.created_at,a.id),'[]'::jsonb)
   from app_private.provider_attempts a where account_id=p_account_id and operation_id=p_operation_id),
  'record_counts',jsonb_build_object(
   'events',(select count(*) from app_private.provider_attempt_events e join app_private.provider_attempts a on a.id=e.attempt_id
    where a.account_id=p_account_id and a.operation_id=p_operation_id),
   'adjustments',(select count(*) from app_private.provider_attempt_adjustments r join app_private.provider_attempts a on a.id=r.attempt_id
    where a.account_id=p_account_id and a.operation_id=p_operation_id),
   'credits',(select count(*) from app_private.credit_ledger where account_id=p_account_id and operation_id=p_operation_id),
   'legacy_usage',(select count(*) from app_private.provider_usage_events u where u.account_id=p_account_id and u.operation_id=p_operation_id
    and u.provider_event_id not like 'attempt:%')));
end $$;

-- Financial history can be retained indefinitely without making an unbounded
-- admin response. Each section pages independently with a deterministic cursor.
create function public.v1_admin_spending_records(p_account_id uuid,p_operation_id uuid,p_kind text,
 p_before_at timestamptz default null,p_before_id text default null,p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb; more boolean; last_row jsonb;
begin
 perform app_private.spending_owner(1);
 if p_kind is null or p_kind not in ('events','adjustments','credits','legacy_usage') or p_limit is null or p_limit not between 1 and 100
  or (p_before_at is null) is distinct from (p_before_id is null)
  or (p_before_id is not null and p_before_id !~ '^[a-z0-9-]{1,40}$') then raise exception 'invalid_spending_page'; end if;
 if not exists(select 1 from app_private.metered_operations where account_id=p_account_id and id=p_operation_id)
 then raise exception 'spending_operation_unavailable'; end if;
 with records as (
  select e.created_at at,lpad(e.id::text,20,'0') key,to_jsonb(e) entry from app_private.provider_attempt_events e
   join app_private.provider_attempts a on a.id=e.attempt_id where p_kind='events' and a.account_id=p_account_id and a.operation_id=p_operation_id
  union all select r.created_at,r.id::text,to_jsonb(r) from app_private.provider_attempt_adjustments r
   join app_private.provider_attempts a on a.id=r.attempt_id where p_kind='adjustments' and a.account_id=p_account_id and a.operation_id=p_operation_id
  union all select l.created_at,lpad(l.id::text,20,'0'),jsonb_build_object('id',l.id,'bucket_id',l.bucket_id,'kind',l.kind,
   'balance_delta',l.balance_delta,'reserved_delta',l.reserved_delta,'created_at',l.created_at)
   from app_private.credit_ledger l where p_kind='credits' and l.account_id=p_account_id and l.operation_id=p_operation_id
  union all select u.created_at,u.id::text,jsonb_build_object('id',u.id,'provider',u.provider,'provider_event_id',u.provider_event_id,
   'model',u.model,'estimated_microusd',u.estimated_microusd,'created_at',u.created_at,
   'units',case when app_private.valid_provider_units(u.units) then u.units else '{}'::jsonb end)
   from app_private.provider_usage_events u where p_kind='legacy_usage' and u.account_id=p_account_id and u.operation_id=p_operation_id
   and u.provider_event_id not like 'attempt:%'), candidates as (
  select * from records where p_before_at is null or (at,key)<(p_before_at,p_before_id) order by at desc,key desc limit p_limit+1), numbered as (
  select *,row_number() over(order by at desc,key desc) n from candidates)
 select coalesce(jsonb_agg(jsonb_build_object('at',at,'key',key,'entry',entry) order by at desc,key desc) filter(where n<=p_limit),'[]'::jsonb),
  coalesce(bool_or(n>p_limit),false) into rows,more from numbered;
 if more then last_row:=rows->(jsonb_array_length(rows)-1); end if;
 return jsonb_build_object('kind',p_kind,'records',rows,'next',case when more then jsonb_build_object('at',last_row->>'at','id',last_row->>'key') else null end);
end $$;

revoke all on function app_private.spending_owner(integer) from public,anon,authenticated,service_role;
revoke all on function public.worker_record_spending_observation(uuid,uuid,text,date,text,bigint,boolean,timestamptz,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.worker_record_spending_observation(uuid,uuid,text,date,text,bigint,boolean,timestamptz,text,text,jsonb) to service_role;
revoke all on function public.v1_admin_spending(integer,uuid) from public,anon;
revoke all on function public.v1_admin_spending_operations(integer,uuid,timestamptz,uuid,uuid,integer,boolean) from public,anon;
revoke all on function public.v1_admin_spending_operation(uuid,uuid) from public,anon;
grant execute on function public.v1_admin_spending(integer,uuid) to authenticated;
grant execute on function public.v1_admin_spending_operations(integer,uuid,timestamptz,uuid,uuid,integer,boolean) to authenticated;
grant execute on function public.v1_admin_spending_operation(uuid,uuid) to authenticated;
revoke all on function public.v1_admin_spending_records(uuid,uuid,text,timestamptz,text,integer) from public,anon;
grant execute on function public.v1_admin_spending_records(uuid,uuid,text,timestamptz,text,integer) to authenticated;
notify pgrst,'reload schema';
commit;
