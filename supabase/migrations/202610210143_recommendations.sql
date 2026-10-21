-- 0143: AI recommendations (owner, TestFlight 78, 2026-10-21: "uses AI with our server to search for the most similar
-- papers and just adds them … 1, 3 or 5"; design: docs/architecture/AI_RECOMMENDATIONS.md). Additive.
-- The `recommend` function holds 1 credit (operation kind `recommend`, $0.015 ceiling), finds candidates without a model
-- (DataCite and the Feed pool, never arXiv), asks Haiku 5.5 through OpenRouter (route `chat`, already admitted for
-- non-podcast operations) to choose among them, adds the picks as the reader (v2_add_paper_once) and settles: 1 credit
-- when at least one paper was added, nothing otherwise. This migration adds:
--  1. the operation kind, a singleton policy (on, 20 a day, 1 credit, $0.015) and the request gate (30 an hour);
--  2. recommendation_runs: one row per request (seeds, count, picks with reasons, outcome), deleted with the account;
--  3. worker_recommend_begin (replay, daily limit, seeds from the reader's own library, exclusions, the hold),
--     worker_recommend_pool (the Feed pool's full-text index) and worker_recommend_finish (picks and settlement);
--  4. stale runs settled uncharged by the existing stale sweep and by the account's own next request;
--  5. Admin: feature `recommend` → `recommendations` in Costs, and a `recommendations` block on Health.
begin;
set local lock_timeout='15s';

-- 1. Kind, policy, request gate.
alter table app_private.metered_operations drop constraint metered_operations_kind_check;
alter table app_private.metered_operations add constraint metered_operations_kind_check
 check(kind in ('chat','ocr','search','metadata','diagram','podcast','recommend'));

create table app_private.recommendation_policy (
 singleton boolean primary key default true check(singleton),
 enabled boolean not null default true,
 -- New requests per account in any rolling 24 hours (every request counts, whatever its outcome).
 daily_runs integer not null default 20 check(daily_runs between 0 and 1000),
 -- What a request that added at least one paper costs the reader (1 credit = $0.005).
 credits bigint not null default 1 check(credits between 0 and 100),
 -- The operation's provider ceiling: the one model call's hold must fit (docs: "Prompt (bounded)").
 hold_microusd bigint not null default 15000 check(hold_microusd between 1000 and 1000000)
);
insert into app_private.recommendation_policy default values;
alter table app_private.recommendation_policy enable row level security;
revoke all on app_private.recommendation_policy from public,anon,authenticated;

insert into app_private.api_rate_rules values('recommend',3600,30,600) on conflict(route) do nothing;

-- 2. One row per request. Seeds and picks are library-membership data (server-visible like the library, not end-to-end
-- encrypted); the operation and its provider attempts stay as the de-identified billing record after account deletion.
create table app_private.recommendation_runs (
 account_id uuid not null,
 id uuid not null,
 request_sha256 bytea not null check(octet_length(request_sha256)=32),
 scope text not null check(scope in ('paper','catalog')),
 seeds text[] not null check(cardinality(seeds) between 1 and 8 and coalesce(array_ndims(seeds),1)=1),
 requested integer not null check(requested in (1,3,5)),
 state text not null default 'running' check(state in ('running','finished','failed')),
 picks jsonb not null default '[]' check(jsonb_typeof(picks)='array' and jsonb_array_length(picks)<=5 and octet_length(picks::text)<=16384),
 added integer not null default 0 check(added between 0 and 5),
 credits bigint not null default 0 check(credits>=0),
 failure text check(failure ~ '^[a-z_]{1,48}$'),
 created_at timestamptz not null default now(),
 finished_at timestamptz,
 primary key(account_id,id),
 foreign key(account_id,id) references app_private.metered_operations(account_id,id),
 check((state='running')=(finished_at is null)),
 check(added<=requested)
);
create index recommendation_runs_recent on app_private.recommendation_runs(account_id,created_at desc);
create index recommendation_runs_open on app_private.recommendation_runs(created_at) where state='running';
alter table app_private.recommendation_runs enable row level security;
revoke all on app_private.recommendation_runs from public,anon,authenticated;

-- 3. The paper a seed names, from the reader's own library only: a visible item's catalog record, else a visible
-- import's catalog record or the record the reader's device submitted (HTML-first papers rest as imports). Null when
-- the reader has no such paper or the server has no details for it yet. Bounded: title, 3 authors, 2,000 characters
-- of abstract, 6 categories, 12 tags.
create function app_private.recommend_paper(p_source_id text,m jsonb,p_tags text[]) returns jsonb
language sql immutable set search_path='' as $$
 select case when jsonb_typeof(m->'title')='string' and length(btrim(m->>'title'))>0 then jsonb_build_object(
  'source_id',p_source_id,
  'title',left(btrim(m->>'title'),300),
  'abstract',left(coalesce(case when jsonb_typeof(m->'abstract')='string' then m->>'abstract' end,''),2000),
  'authors',coalesce((select jsonb_agg(left(x,120) order by n) from jsonb_array_elements_text(case when jsonb_typeof(m->'authors')='array' then m->'authors' else '[]'::jsonb end)
    with ordinality t(x,n) where n<=3),'[]'::jsonb),
  'categories',coalesce((select jsonb_agg(left(x,32) order by n) from jsonb_array_elements_text(case when jsonb_typeof(m->'categories')='array' then m->'categories' else '[]'::jsonb end)
    with ordinality t(x,n) where n<=6),'[]'::jsonb),
  'tags',coalesce((select jsonb_agg(x) from (select distinct x from unnest(coalesce(p_tags,'{}')) x limit 12) y),'[]'::jsonb)) end
$$;

create function app_private.recommend_seed(a uuid,p_source_id text) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(
  (select app_private.recommend_paper(cm.source_id,cm.metadata,li.catalog_tags||li.user_tags)
   from app_private.library_items li join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
   join app_private.catalog_metadata cm on cm.id=ca.metadata_id
   where li.account_id=a and li.removed_at is null and cm.source_id=p_source_id order by li.created_seq desc limit 1),
  (select app_private.recommend_paper(i.source_id,coalesce(cm.metadata,i.device_metadata),i.source_tags)
   from app_private.import_requests i left join app_private.catalog_metadata cm on cm.id=i.metadata_id
   where i.account_id=a and i.source_id=p_source_id and i.desired_present and coalesce(cm.metadata,i.device_metadata) is not null
   order by i.created_seq desc limit 1))
$$;

-- Everything the reader has or had: every import (removed included), every item (removed included), papers marked
-- Not interested in the Feed.
create function app_private.recommend_exclusions(a uuid) returns text[]
language sql stable security definer set search_path='' as $$
 select coalesce(array_agg(distinct s order by s),'{}') from (
  select source_id s from app_private.import_requests where account_id=a
  union all
  select cm.source_id from app_private.library_items li join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
   join app_private.catalog_metadata cm on cm.id=ca.metadata_id where li.account_id=a
  union all
  select source_id from app_private.feed_feedback where account_id=a and kind='not_interested') x
$$;

-- A run left `running` (its function was killed): settled uncharged, marked failed. Holds the account's locks in the
-- reservation's order (budget, then account) through worker_settle_operation.
create function app_private.recommend_expire(p_account_id uuid,p_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform public.worker_settle_operation(p_account_id,p_id,0,0);
 update app_private.recommendation_runs set state='failed',failure='expired',finished_at=now()
  where account_id=p_account_id and id=p_id and state='running';
end $$;

create function public.worker_recommend_begin(p_account_id uuid,p_operation_id uuid,p_request_sha256 bytea,p_scope text,
 p_seeds text[],p_count integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.recommendation_policy; r app_private.recommendation_runs; seeds jsonb:='[]'::jsonb; s text; seed jsonb; stale record;
begin
 if p_account_id is null or p_operation_id is null or octet_length(p_request_sha256) is distinct from 32
  or p_scope is null or p_scope not in ('paper','catalog') or p_count is null or p_count not in (1,3,5)
  or p_seeds is null or coalesce(array_ndims(p_seeds),1)<>1 or cardinality(p_seeds) not between 1 and 8
  or (p_scope='paper' and cardinality(p_seeds)<>1)
  or exists(select 1 from unnest(p_seeds) x where x is null or length(x) not between 1 and 128)
  or (select count(distinct x) from unnest(p_seeds) x)<>cardinality(p_seeds)
 then raise exception 'invalid_recommendation'; end if;
 -- A request already made: its outcome, never a second hold or call.
 select * into r from app_private.recommendation_runs where account_id=p_account_id and id=p_operation_id;
 if found then
  if r.request_sha256<>p_request_sha256 then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('replayed',true,'state',r.state,'requested',r.requested,'picks',r.picks,'added',r.added,
   'credits',r.credits,'failure',r.failure);
 end if;
 if exists(select 1 from app_private.metered_operations where account_id=p_account_id and id=p_operation_id) then
  raise exception 'operation_id_conflict';
 end if;
 select * into strict pol from app_private.recommendation_policy where singleton;
 if not pol.enabled then raise exception 'recommend_unavailable'; end if;
 -- The reservation's lock order (budget, then account): concurrent requests of one account count each other.
 perform 1 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date for update;
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null for update;
 if not found then raise exception 'account_unavailable'; end if;
 -- This account's runs left open by a killed function (10 minutes; an answer takes seconds) are settled uncharged
 -- first, so their holds never block it.
 for stale in select id from app_private.recommendation_runs where account_id=p_account_id and state='running'
  and created_at<now()-interval '10 minutes' order by created_at limit 5 loop
  perform app_private.recommend_expire(p_account_id,stale.id);
 end loop;
 if (select count(*) from app_private.recommendation_runs where account_id=p_account_id and created_at>now()-interval '24 hours')>=pol.daily_runs
 then raise exception 'recommend_daily_limit'; end if;
 foreach s in array p_seeds loop
  seed:=app_private.recommend_seed(p_account_id,s);
  if seed is null then raise exception 'recommend_seed_unavailable'; end if;
  seeds:=seeds||jsonb_build_array(seed);
 end loop;
 -- Balance, platform budget, open operations, suspension and testing cap, exactly as every paid request.
 perform public.worker_reserve_operation(p_account_id,p_operation_id,'recommend',p_request_sha256,'beta-credits-v1',pol.credits,pol.hold_microusd);
 insert into app_private.recommendation_runs(account_id,id,request_sha256,scope,seeds,requested)
 values(p_account_id,p_operation_id,p_request_sha256,p_scope,p_seeds,p_count);
 return jsonb_build_object('replayed',false,'state','running','requested',p_count,'seeds',seeds,
  'exclude',to_jsonb(app_private.recommend_exclusions(p_account_id)),'credits',pol.credits,'hold_microusd',pol.hold_microusd);
end $$;

-- The Feed pool's papers matching any of the terms (each term's words all present), ranked by full-text relevance and
-- a shared arXiv category; the reader's exclusions (above) left out. Read-only; nothing about the reader is stored.
create function public.worker_recommend_pool(p_account_id uuid,p_terms text[],p_categories text[],p_limit integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare q tsquery; t text; part tsquery; excluded text[];
begin
 if p_account_id is null or not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is null) then
  raise exception 'account_unavailable' using errcode='42501';
 end if;
 if p_terms is null or coalesce(array_ndims(p_terms),1)<>1 or cardinality(p_terms) not between 1 and 8
  or exists(select 1 from unnest(p_terms) x where x is null or length(x) not between 2 and 120)
  or p_categories is null or coalesce(array_ndims(p_categories),1)<>1 or cardinality(p_categories)>12
  or exists(select 1 from unnest(p_categories) x where x is null or x !~ '^[a-zA-Z.-]{2,32}$')
  or p_limit is null or p_limit not between 1 and 30
 then raise exception 'invalid_recommendation'; end if;
 foreach t in array p_terms loop
  part:=plainto_tsquery('english',t);
  if numnode(part)>0 then q:=case when q is null then part else q||part end; end if;
 end loop;
 if q is null then return '[]'::jsonb; end if;
 excluded:=app_private.recommend_exclusions(p_account_id);
 return coalesce((select jsonb_agg(jsonb_build_object('source_id',x.source_id,'revision',x.revision,'title',x.title,
   'authors',to_jsonb(x.authors[1:3]),'year',extract(year from x.announced_on)::integer,'abstract',left(coalesce(x.abstract,''),700),
   'categories',to_jsonb(x.categories[1:6])) order by x.score desc,x.announced_on desc,x.source_id)
  from (select f.*,ts_rank_cd(f.search,q)*(case when f.categories&&p_categories then 1.3 else 1 end) score
   from app_private.feed_papers f where f.search@@q and not (f.source_id=any(excluded))
   order by score desc,f.announced_on desc,f.source_id limit p_limit) x),'[]'::jsonb);
end $$;

-- The request's outcome: its picks (what the reader saw), then the settlement: the policy's credits when at least one
-- paper was added, nothing otherwise. Replaying the identical outcome is a no-op; a different one conflicts.
create function public.worker_recommend_finish(p_account_id uuid,p_operation_id uuid,p_picks jsonb,p_failure text,p_actual_microusd bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r app_private.recommendation_runs; op app_private.metered_operations; n integer; v_added integer; v_credits bigint; p jsonb;
begin
 if p_account_id is null or p_operation_id is null or p_picks is null or jsonb_typeof(p_picks)<>'array' or jsonb_array_length(p_picks)>5
  or octet_length(p_picks::text)>16384 or (p_failure is not null and p_failure !~ '^[a-z_]{1,48}$')
  or p_actual_microusd is null or p_actual_microusd<0 then raise exception 'invalid_recommendation'; end if;
 for p in select value from jsonb_array_elements(p_picks) loop
  if jsonb_typeof(p)<>'object' or not p ?& array['source_id','title','reason','status']
   or exists(select 1 from jsonb_object_keys(p) k where k not in ('source_id','revision','title','authors','year','reason','status','import_id'))
   or jsonb_typeof(p->'source_id')<>'string' or length(p->>'source_id') not between 1 and 128
   or jsonb_typeof(p->'title')<>'string' or length(p->>'title') not between 1 and 300
   or jsonb_typeof(p->'reason')<>'string' or length(p->>'reason')>200
   or p->>'status' is null or p->>'status' not in ('added','present','failed')
   or (p ? 'import_id' and jsonb_typeof(p->'import_id')<>'null' and (p->>'import_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
   or (p ? 'authors' and (jsonb_typeof(p->'authors')<>'array' or jsonb_array_length(p->'authors')>3))
   or (p ? 'revision' and jsonb_typeof(p->'revision') not in ('number','null'))
   or (p ? 'year' and jsonb_typeof(p->'year') not in ('number','null'))
  then raise exception 'invalid_recommendation'; end if;
 end loop;
 if (select count(distinct value->>'source_id') from jsonb_array_elements(p_picks))<>jsonb_array_length(p_picks) then
  raise exception 'invalid_recommendation';
 end if;
 -- Locks in the reservation's order (budget, then account), then the run.
 select * into op from app_private.metered_operations where account_id=p_account_id and id=p_operation_id and kind='recommend';
 if not found then raise exception 'recommendation_unavailable'; end if;
 perform 1 from app_private.platform_budgets where period=op.period for update;
 perform 1 from app_private.accounts where id=p_account_id for update;
 select * into r from app_private.recommendation_runs where account_id=p_account_id and id=p_operation_id for update;
 if not found then raise exception 'recommendation_unavailable'; end if;
 n:=jsonb_array_length(p_picks);
 v_added:=(select count(*) from jsonb_array_elements(p_picks) x where x->>'status'='added');
 if r.state<>'running' then
  if r.picks=p_picks and r.failure is not distinct from p_failure then
   return jsonb_build_object('state',r.state,'added',r.added,'credits',r.credits,'charged',r.credits>0,'replayed',true);
  end if;
  raise exception 'settlement_id_conflict';
 end if;
 if n>r.requested then raise exception 'invalid_recommendation'; end if;
 v_credits:=case when v_added>0 then op.credit_ceiling else 0 end;
 perform public.worker_settle_operation(p_account_id,p_operation_id,v_credits,p_actual_microusd);
 update app_private.recommendation_runs set state=case when v_added>0 or p_failure is null then 'finished' else 'failed' end,
  picks=p_picks,added=v_added,credits=v_credits,failure=p_failure,finished_at=now()
  where account_id=p_account_id and id=p_operation_id returning * into r;
 return jsonb_build_object('state',r.state,'added',r.added,'credits',r.credits,'charged',r.credits>0,'replayed',false);
end $$;

-- 4. The stale sweep (every pipeline run) also settles recommendation runs left open for p minutes, uncharged, with
-- 0108's failure record and back-off. The chat part is unchanged.
alter function public.worker_expire_stale_chat_operations(integer) rename to expire_stale_chat_before_143;
alter function public.expire_stale_chat_before_143(integer) set schema app_private;
create function public.worker_expire_stale_chat_operations(p_older_than_minutes integer default 30) returns integer
language plpgsql security definer set search_path='' as $$
declare n integer; run record;
begin
 n:=app_private.expire_stale_chat_before_143(p_older_than_minutes);
 for run in select r.account_id,r.id from app_private.recommendation_runs r
  where r.state='running' and r.created_at<now()-make_interval(mins=>p_older_than_minutes)
   and not exists(select 1 from app_private.stale_sweep_failures f where (f.account_id,f.operation_id)=(r.account_id,r.id) and f.next_at>now())
  order by r.created_at limit 50 loop
  begin
   perform app_private.recommend_expire(run.account_id,run.id);
   delete from app_private.stale_sweep_failures where (account_id,operation_id)=(run.account_id,run.id);
   n:=n+1;
  exception when others then
   insert into app_private.stale_sweep_failures as f(account_id,operation_id,failures,last_code,next_at)
   values(run.account_id,run.id,1,sqlstate,now()+interval '10 minutes')
   on conflict(account_id,operation_id) do update set failures=f.failures+1,last_code=excluded.last_code,
    next_at=now()+least(interval '1 day',interval '10 minutes'*power(2,least(f.failures,8))),updated_at=now();
  end;
 end loop;
 return n;
end $$;

-- Account deletion removes the runs (personal library data) and counts them while any remain.
alter function public.worker_delete_account_begin(uuid) rename to delete_account_begin_before_143;
alter function public.delete_account_begin_before_143(uuid) set schema app_private;
create function public.worker_delete_account_begin(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=app_private.delete_account_begin_before_143(p_account_id);
 delete from app_private.recommendation_runs where account_id=p_account_id;
 return result;
end $$;
alter function public.worker_account_deletion_status(uuid) rename to account_deletion_status_before_143;
alter function public.account_deletion_status_before_143(uuid) set schema app_private;
create function public.worker_account_deletion_status(p_account_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 with old as (select app_private.account_deletion_status_before_143(p_account_id) value),
 runs as (select count(*) n from app_private.recommendation_runs where account_id=p_account_id)
 select old.value||jsonb_build_object('personal_rows',(old.value->>'personal_rows')::bigint+runs.n,'recommendation_runs',runs.n) from old,runs
$$;

-- 5. Admin. Costs names the feature; Health counts the requests.
create or replace function app_private.cost_feature(p_route text,p_feature text) returns text
language sql immutable set search_path='' as $$
 select case
  when p_route in ('chat_search','ingest_lookup','reference_lookup') then 'search'
  when p_route='catalog_tags' then 'tags'
  when left(p_route,8)='podcast_' then 'podcasts'
  when p_route='paper_ocr' then 'ocr'
  when p_route='chat' and p_feature in ('equation','equation_background') then 'equation_explainer'
  when p_route='chat' and p_feature in ('figure','figure_simpler','figure_detail') then 'figure_explainer'
  when p_route='chat' and p_feature='recommend' then 'recommendations'
  when p_route='chat' then 'chat'
  else 'other' end
$$;

create function app_private.recommendation_health() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('enabled',(select enabled from app_private.recommendation_policy where singleton),
  'daily_runs',(select daily_runs from app_private.recommendation_policy where singleton),
  'last_24h',(select jsonb_build_object('runs',count(*),'papers_added',coalesce(sum(added),0),'charged',count(*) filter(where credits>0),
    'failed',count(*) filter(where state='failed'),'running',count(*) filter(where state='running'),'accounts',count(distinct account_id))
   from app_private.recommendation_runs where created_at>now()-interval '24 hours'),
  'last_30d',(select jsonb_build_object('runs',count(*),'papers_added',coalesce(sum(added),0),'charged',count(*) filter(where credits>0),
    'failed',count(*) filter(where state='failed'),'accounts',count(distinct account_id))
   from app_private.recommendation_runs where created_at>now()-interval '30 days'))
$$;
create or replace function app_private.admin_health_extra() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('tariffs',app_private.openrouter_tariff_attention(),'reconciliation',app_private.openrouter_reconcile_health(),
  'recommendations',app_private.recommendation_health())
$$;

revoke all on function app_private.recommend_paper(text,jsonb,text[]),app_private.recommend_seed(uuid,text),
 app_private.recommend_exclusions(uuid),app_private.recommend_expire(uuid,uuid),app_private.recommendation_health(),
 app_private.expire_stale_chat_before_143(integer),app_private.delete_account_begin_before_143(uuid),
 app_private.account_deletion_status_before_143(uuid) from public,anon,authenticated,service_role;
revoke all on function public.worker_recommend_begin(uuid,uuid,bytea,text,text[],integer),
 public.worker_recommend_pool(uuid,text[],text[],integer),public.worker_recommend_finish(uuid,uuid,jsonb,text,bigint),
 public.worker_expire_stale_chat_operations(integer),public.worker_delete_account_begin(uuid),public.worker_account_deletion_status(uuid)
 from public,anon,authenticated;
grant execute on function public.worker_recommend_begin(uuid,uuid,bytea,text,text[],integer),
 public.worker_recommend_pool(uuid,text[],text[],integer),public.worker_recommend_finish(uuid,uuid,jsonb,text,bigint),
 public.worker_expire_stale_chat_operations(integer),public.worker_delete_account_begin(uuid),public.worker_account_deletion_status(uuid)
 to service_role;

notify pgrst,'reload schema';
commit;
