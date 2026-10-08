-- Feed topics and popularity (docs/architecture/PERSONALIZED_FEED.md, "Specific topics and popularity";
-- owner feedback on TestFlight build 21, 2026-10-08). Additive over 043: both feed switches keep their
-- values, the 043 functions stay as they are for any client or function still calling them.
--
-- 1. Popularity: Hugging Face Papers upvotes, observed by the shared pool refresh under its claim
--    (never per reader request) and stored on the pool row. Null means not listed there or unknown;
--    nothing is estimated. Per-day fetch state bounds the requests: the last four days at most about
--    every two hours, older days in the 14-day window once a day, at most six days per refresh run.
--    feed_policy.popularity_enabled turns only these requests off.
-- 2. Specific topics: worker_feed_candidates_v2 returns, with For you's inputs, how many eligible pool
--    papers carry each of the reader's own topics, tags and curated topic combinations (the discover
--    function chooses and orders the chips), and serves one such topic ranked for the reader.
-- 3. Category chips v2 and pool details return topics, upvotes and the stored abstract, marked
--    complete only when it is shorter than the pool's 2,000-character bound.
begin;
set local lock_timeout='15s';

alter table app_private.feed_papers
 add column upvotes integer check(upvotes between 0 and 1000000),
 add column upvotes_at timestamptz,
 add constraint feed_papers_upvotes_observed check((upvotes is null)=(upvotes_at is null));

alter table app_private.feed_policy add column popularity_enabled boolean not null default true;

-- One row per popularity source and listing day; only Hugging Face's daily papers today.
create table app_private.feed_signal_days (
 source text not null check(source in ('huggingface')),
 day date not null,
 checked_at timestamptz not null,
 fetched_at timestamptz,
 status text not null check(status in ('ok','failed','busy')),
 items integer check(items between 0 and 1000),
 primary key(source,day)
);
alter table app_private.feed_signal_days enable row level security;

-- Personal tags that say nothing about a topic ("to read"): never chips or phrases.
create function app_private.feed_generic_tag(p text) returns boolean language sql immutable set search_path='' as $$
 select p is null or p !~ '[[:alpha:]]' or lower(p) in ('to read','read later','read','reading','important','favorite','favorites',
  'todo','to do','later','reviewed','review','starred','misc','other','paper','papers','work','thesis')
$$;

-- Topic combinations the discover function sends: [{name, all: [1-4 tags], any: [0-6 tags]}], at most 32.
create function app_private.feed_valid_compounds(p jsonb) returns boolean language sql immutable set search_path='' as $$
 select jsonb_typeof(p)='array' and jsonb_array_length(p)<=32
  and not exists(select 1 from jsonb_array_elements(p) c where jsonb_typeof(c)<>'object'
   or (c-'name'-'all'-'any')<>'{}'::jsonb
   or jsonb_typeof(c->'name') is distinct from 'string' or not app_private.valid_tag_list(array[c->>'name'],1)
   or jsonb_typeof(c->'all') is distinct from 'array' or jsonb_array_length(c->'all') not between 1 and 4
   or jsonb_typeof(c->'any') is distinct from 'array' or jsonb_array_length(c->'any')>6
   or exists(select 1 from jsonb_array_elements((c->'all')||(c->'any')) t where jsonb_typeof(t)<>'string')
   or not app_private.valid_tag_list(app_private.feed_json_texts(c->'all',4),4)
   or not app_private.valid_tag_list(app_private.feed_json_texts(c->'any',6),6))
  and (select count(distinct lower(c->>'name')) from jsonb_array_elements(p) c)=jsonb_array_length(p)
$$;

-- Pool papers a reader is never offered: everything in the library (archived and failed imports
-- included), imports they want and papers marked Not interested (as 043's candidates exclude them).
create function app_private.feed_excluded(a uuid) returns table(source_id text)
language sql stable security definer set search_path='' as $$
 select cm.source_id from app_private.library_items li
  join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
  join app_private.catalog_metadata cm on cm.id=ca.metadata_id
  where li.account_id=a and li.removed_at is null
 union select i.source_id from app_private.import_requests i where i.account_id=a and i.desired_present
 union select f.source_id from app_private.feed_feedback f where f.account_id=a and f.kind='not_interested'
$$;

create function public.worker_set_feed_popularity(p_enabled boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.feed_policy;
begin
 if p_enabled is null then raise exception 'invalid_feed_policy'; end if;
 update app_private.feed_policy set popularity_enabled=p_enabled,updated_at=now() where singleton returning * into strict r;
 return to_jsonb(r)-'singleton';
end $$;

-- Popularity, step 1 (under the pool refresh's live claim): the listing days due, newest first among
-- days never fetched, at most six. Recent days (the last four) refresh after 110 minutes, older days
-- after 23 hours; a failed or throttled day waits at least 25 minutes.
create function public.worker_feed_signal_plan(p_claim_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.feed_policy; today date:=(now() at time zone 'UTC')::date; days jsonb;
begin
 perform app_private.feed_claimed(p_claim_id);
 select * into strict pol from app_private.feed_policy where singleton;
 if not pol.popularity_enabled then return jsonb_build_object('source','huggingface','enabled',false,'days','[]'::jsonb); end if;
 select coalesce(jsonb_agg(to_char(x.day,'YYYY-MM-DD') order by x.never desc,x.day desc),'[]'::jsonb) into days from (
  select g.day,s.fetched_at is null never
  from (select (today-n) as day from generate_series(0,pol.window_days) n) g
  left join app_private.feed_signal_days s on s.source='huggingface' and s.day=g.day
  where (s.fetched_at is null or s.fetched_at<now()-case when g.day>=today-3 then interval '110 minutes' else interval '23 hours' end)
   and (s.checked_at is null or s.status='ok' or s.checked_at<now()-interval '25 minutes')
  order by s.fetched_at is null desc,g.day desc limit 6) x;
 return jsonb_build_object('source','huggingface','enabled',true,'days',days);
end $$;

-- Popularity, step 2 (repeatable): one listing day's outcome. 'ok' writes the observed upvotes onto
-- the pool papers listed (papers outside the pool are ignored); 'failed'/'busy' only record the try.
create function public.worker_feed_signals_record(p_claim_id uuid,p_day date,p_status text,p_items jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare today date:=(now() at time zone 'UTC')::date; matched integer:=0; n integer;
begin
 perform app_private.feed_claimed(p_claim_id);
 if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'invalid_feed_signals'; end if;
 if p_day is null or p_day not between today-60 and today+1 or p_status is null or p_status not in ('ok','failed','busy')
  or jsonb_array_length(p_items)>1000
  or (p_status<>'ok' and jsonb_array_length(p_items)>0)
  or exists(select 1 from jsonb_array_elements(p_items) i where jsonb_typeof(i)<>'object' or (i-'source_id'-'upvotes')<>'{}'::jsonb
   or jsonb_typeof(i->'source_id') is distinct from 'string' or not app_private.feed_valid_source(i->>'source_id')
   or jsonb_typeof(i->'upvotes') is distinct from 'number' or (i->>'upvotes') !~ '^[0-9]{1,7}$' or (i->>'upvotes')::integer>1000000)
  or (select count(distinct i->>'source_id') from jsonb_array_elements(p_items) i)<>jsonb_array_length(p_items) then
  raise exception 'invalid_feed_signals';
 end if;
 n:=jsonb_array_length(p_items);
 if p_status='ok' then
  update app_private.feed_papers p set upvotes=(i->>'upvotes')::integer,upvotes_at=now()
   from jsonb_array_elements(p_items) i where p.source_id=i->>'source_id';
  get diagnostics matched=row_count;
 end if;
 insert into app_private.feed_signal_days as d(source,day,checked_at,fetched_at,status,items)
  values('huggingface',p_day,now(),case when p_status='ok' then now() end,p_status,case when p_status='ok' then n end)
  on conflict(source,day) do update set checked_at=now(),status=excluded.status,
   fetched_at=case when excluded.status='ok' then now() else d.fetched_at end,
   items=case when excluded.status='ok' then excluded.items else d.items end;
 delete from app_private.feed_signal_days where day<today-90;
 return jsonb_build_object('matched',matched,'items',n);
end $$;

-- For you inputs, version 2 (the discover function ranks). Without a topic: 043's candidates plus up
-- to 30 eligible papers with at least five upvotes, and `topics` — how many eligible pool papers in
-- the window carry each of the reader's tags, phrase-match each of their own tags, and satisfy each
-- combination in p_compounds. With a topic (p_all [+ p_any], or p_phrase: one of the reader's own
-- tags, matched as a phrase): up to 300 eligible papers of that topic, newest first in a daily order.
-- Candidates carry topics and upvotes, not abstracts (worker_feed_details returns those for the papers
-- shown), keeping the per-request payload small.
create function public.worker_feed_candidates_v2(p_account_id uuid,p_all text[] default null,p_any text[] default null,
 p_phrase text default null,p_compounds jsonb default '[]'::jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare pol app_private.feed_policy; today date:=(now() at time zone 'UTC')::date; since date; pool_rows integer;
 seed text; t_topics text[]; t_own text[]; t_authors text[]; t_categories text[]; empty_profile boolean;
 topic_mode boolean:=p_all is not null or p_phrase is not null; phrase tsquery;
 candidates jsonb; v_topics jsonb; refreshed timestamptz;
begin
 if p_account_id is null or not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is null) then
  raise exception 'account_unavailable' using errcode='42501';
 end if;
 select * into strict pol from app_private.feed_policy where singleton;
 if not app_private.feed_serves(p_account_id) then raise exception 'feed_unavailable'; end if;
 if topic_mode then
  if (p_all is not null and p_phrase is not null)
   or (p_all is not null and (cardinality(p_all)=0 or not app_private.valid_tag_list(p_all,4)))
   or (p_any is not null and (p_all is null or not app_private.valid_tag_list(p_any,6)))
   or (p_phrase is not null and (not app_private.valid_tag_list(array[p_phrase],1) or app_private.feed_generic_tag(p_phrase)
    or not exists(select 1 from app_private.library_items li where li.account_id=p_account_id and li.removed_at is null
     and exists(select 1 from unnest(li.user_tags) t where lower(t)=lower(p_phrase))))) then
   raise exception 'invalid_feed_topic';
  end if;
  if p_phrase is not null then
   phrase:=phraseto_tsquery('english'::regconfig,p_phrase);
   if numnode(phrase)=0 then raise exception 'invalid_feed_topic'; end if;
  end if;
 elsif p_any is not null or p_compounds is null or not app_private.feed_valid_compounds(p_compounds) then
  raise exception 'invalid_feed_topic';
 end if;
 since:=today-pol.window_days;
 select count(*) into pool_rows from app_private.feed_papers where announced_on>=since;
 if pool_rows=0 then raise exception 'feed_unavailable'; end if;
 seed:=p_account_id::text||':'||today::text;

 with prof as (select * from app_private.feed_profile(p_account_id)),
 fb as (select * from app_private.feed_feedback where account_id=p_account_id order by created_at desc limit 300)
 select coalesce((select array_agg(distinct t) from (select unnest(tags) t from prof union all
    select unnest(topics) from fb where kind='more_like_this') x),'{}'),
  coalesce((select array_agg(distinct t) from (select unnest(own_tags) t from prof) x),'{}'),
  coalesce((select array_agg(distinct k) from (select unnest(author_keys) k from prof union all
    select unnest(author_keys) from fb where kind='more_like_this') x where k<>''),'{}'),
  coalesce((select array_agg(distinct c) from (select unnest(categories) c from prof union all
    select unnest(categories) from fb where kind='more_like_this') x),'{}')
 into t_topics,t_own,t_authors,t_categories;
 empty_profile:=cardinality(t_topics)=0 and cardinality(t_own)=0 and cardinality(t_authors)=0 and cardinality(t_categories)=0;

 if topic_mode then
  with excluded as materialized (select x.source_id from app_private.feed_excluded(p_account_id) x),
  win as (
   select p.source_id,p.announced_on,md5(seed||p.source_id) shuffle from app_private.feed_papers p
   where p.announced_on>=since and not exists(select 1 from excluded x where x.source_id=p.source_id)
    and case when phrase is not null then p.search@@phrase
     else p.topics@>p_all and (coalesce(cardinality(p_any),0)=0 or p.topics&&p_any) end),
  chosen as (select source_id from win order by announced_on desc,shuffle limit 300),
  readers as (
   select cm.source_id,count(distinct li.account_id)::integer n
   from app_private.catalog_metadata cm
   join app_private.catalog_asset_approvals ca on ca.metadata_id=cm.id
   join app_private.library_items li on li.approval_id=ca.id
   where cm.source_id in (select source_id from chosen) and li.removed_at is null and li.account_id<>p_account_id
    and li.added_at>now()-interval '14 days'
   group by cm.source_id having count(distinct li.account_id)>=3)
  select coalesce(jsonb_agg(jsonb_build_object('source_id',p.source_id,'revision',p.revision,'title',p.title,'authors',to_jsonb(p.authors),
    'author_keys',to_jsonb(p.author_keys),'categories',to_jsonb(p.categories),'topics',to_jsonb(p.topics),
    'announced_on',p.announced_on,'first_seen_at',p.first_seen_at,
    'matched_tags',case when phrase is not null then jsonb_build_array(p_phrase) else '[]'::jsonb end,
    'readers',r.n,'upvotes',p.upvotes) order by p.announced_on desc,p.source_id desc),'[]'::jsonb)
  into candidates
  from chosen c join app_private.feed_papers p on p.source_id=c.source_id left join readers r on r.source_id=p.source_id;
  v_topics:=null;
 else
  with excluded as materialized (select x.source_id from app_private.feed_excluded(p_account_id) x),
  own_q as (
   select t,phraseto_tsquery('english'::regconfig,t) q from unnest(t_own) t where not app_private.feed_generic_tag(t)),
  own_hits as (
   select o.t,p.source_id from own_q o join app_private.feed_papers p on numnode(o.q)>0 and p.search@@o.q and p.announced_on>=since),
  own_ok as (select t from own_hits group by t having count(*)<=greatest(20,pool_rows/50)),
  phrase_tags as (select h.source_id,array_agg(distinct h.t) tags from own_hits h join own_ok using(t) group by h.source_id),
  win as (
   select p.source_id,p.announced_on,p.categories,p.topics,p.upvotes,coalesce(ph.tags,'{}') matched_tags,
    case when p.topics&&t_topics then (select count(*) from unnest(p.topics) x where x=any(t_topics))::integer else 0 end topic_hits,
    case when p.author_keys&&t_authors then (select count(*) from unnest(p.author_keys) x where x<>'' and x=any(t_authors))::integer else 0 end author_hits,
    case when p.categories&&t_categories then (select count(*) from unnest(p.categories) x where x=any(t_categories))::integer else 0 end category_hits,
    md5(seed||p.source_id) shuffle
   from app_private.feed_papers p left join phrase_tags ph on ph.source_id=p.source_id
   where p.announced_on>=since and not exists(select 1 from excluded x where x.source_id=p.source_id)),
  strong as (
   select source_id from win where topic_hits>0 or author_hits>0 or cardinality(matched_tags)>0
   order by 3*topic_hits+4*author_hits+3*cardinality(matched_tags)+category_hits desc,announced_on desc,shuffle limit 250),
  broad as (
   select source_id from win where category_hits>0 and source_id not in (select source_id from strong)
   order by announced_on desc,shuffle limit 100),
  fresh as (
   select source_id from win where categories && pol.categories
    and source_id not in (select source_id from strong union all select source_id from broad)
   order by announced_on desc,shuffle limit case when empty_profile then 200 else 50 end),
  popular as (
   select source_id from win where upvotes>=5 and categories && pol.categories
    and source_id not in (select source_id from strong union all select source_id from broad union all select source_id from fresh)
   order by upvotes desc,announced_on desc,shuffle limit 30),
  chosen as (select source_id from strong union select source_id from broad union select source_id from fresh
   union select source_id from popular),
  readers as (
   select cm.source_id,count(distinct li.account_id)::integer n
   from app_private.catalog_metadata cm
   join app_private.catalog_asset_approvals ca on ca.metadata_id=cm.id
   join app_private.library_items li on li.approval_id=ca.id
   where cm.source_id in (select source_id from chosen) and li.removed_at is null and li.account_id<>p_account_id
    and li.added_at>now()-interval '14 days'
   group by cm.source_id having count(distinct li.account_id)>=3),
  tag_counts as (select t,count(*)::integer n from win cross join lateral unnest(win.topics) t where t=any(t_topics) group by t),
  own_counts as (
   select h.t,count(*)::integer n from own_hits h where not exists(select 1 from excluded x where x.source_id=h.source_id) group by h.t),
  compound_counts as (
   select c->>'name' name,count(w.source_id)::integer n from jsonb_array_elements(p_compounds) c
   left join win w on w.topics@>app_private.feed_json_texts(c->'all',4)
    and (jsonb_array_length(c->'any')=0 or w.topics&&app_private.feed_json_texts(c->'any',6))
   group by c->>'name')
  select (select coalesce(jsonb_agg(jsonb_build_object('source_id',p.source_id,'revision',p.revision,'title',p.title,'authors',to_jsonb(p.authors),
     'author_keys',to_jsonb(p.author_keys),'categories',to_jsonb(p.categories),'topics',to_jsonb(p.topics),
     'announced_on',p.announced_on,'first_seen_at',p.first_seen_at,'matched_tags',to_jsonb(coalesce(ph.tags,'{}')),'readers',r.n,
     'upvotes',p.upvotes) order by p.announced_on desc,p.source_id desc),'[]'::jsonb)
    from chosen c join app_private.feed_papers p on p.source_id=c.source_id
    left join phrase_tags ph on ph.source_id=p.source_id left join readers r on r.source_id=p.source_id),
   jsonb_build_object(
    'tags',(select coalesce(jsonb_object_agg(t,n),'{}'::jsonb) from tag_counts),
    'own',(select coalesce(jsonb_object_agg(t,n),'{}'::jsonb) from own_counts),
    'compounds',(select coalesce(jsonb_object_agg(name,n),'{}'::jsonb) from compound_counts))
  into candidates,v_topics;
 end if;

 select max(last_success_at) into refreshed from app_private.feed_sources;
 return jsonb_build_object('now',now(),'today',today,'seed',seed,'window_days',pol.window_days,'pool',pool_rows,'refreshed_at',refreshed,
  'categories',to_jsonb(pol.categories),
  'profile',(select coalesce(jsonb_agg(to_jsonb(x) order by x.added_at desc),'[]'::jsonb) from app_private.feed_profile(p_account_id) x),
  'feedback',(select coalesce(jsonb_agg(jsonb_build_object('source_id',f.source_id,'kind',f.kind,'title',f.title,'categories',to_jsonb(f.categories),
    'topics',to_jsonb(f.topics),'author_keys',to_jsonb(f.author_keys),'created_at',f.created_at) order by f.created_at desc),'[]'::jsonb)
   from (select * from app_private.feed_feedback where account_id=p_account_id order by created_at desc limit 300) f),
  'candidates',candidates,'topics',v_topics);
end $$;

-- Pool details for papers about to be shown (at most 60): the stored abstract, whether it is complete,
-- topics and upvotes. Public arXiv metadata and a public count only; nothing about any reader.
create function public.worker_feed_details(p_source_ids text[]) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if p_source_ids is null or coalesce(array_ndims(p_source_ids),1)<>1 or cardinality(p_source_ids)>60
  or exists(select 1 from unnest(p_source_ids) s where not app_private.feed_valid_source(s)) then
  raise exception 'invalid_feed_details';
 end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('source_id',p.source_id,'abstract',p.abstract,
   'abstract_complete',char_length(coalesce(p.abstract,''))<2000,'topics',to_jsonb(p.topics),'upvotes',p.upvotes) order by p.source_id),'[]'::jsonb)
  from app_private.feed_papers p where p.source_id=any(p_source_ids));
end $$;

-- A category chip from the pool, version 2: as 043's worker_feed_category, with each paper's topics,
-- upvotes and its stored abstract (and whether that is complete).
create function public.worker_feed_category_v2(p_account_id uuid,p_category text,p_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare pol app_private.feed_policy; refreshed timestamptz; results jsonb;
begin
 if p_account_id is null or not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is null) then
  raise exception 'account_unavailable' using errcode='42501';
 end if;
 if p_category is null or p_category !~ '^[a-z]{2,8}(-[a-z]{2,6})?(\.[A-Z]{2})?$' or p_limit is null or p_limit not between 1 and 50 then
  raise exception 'invalid_feed_category';
 end if;
 select * into strict pol from app_private.feed_policy where singleton;
 if not app_private.feed_serves(p_account_id) then return jsonb_build_object('serving',false,'results',null); end if;
 select max(last_success_at) into refreshed from app_private.feed_sources where p_category=any(categories);
 if p_category<>all(pol.categories) or refreshed is null or refreshed<now()-interval '3 days' then
  return jsonb_build_object('serving',true,'results',null);
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('source_id',p.source_id,'revision',p.revision,'title',p.title,'authors',to_jsonb(p.authors),
   'abstract',p.abstract,'abstract_complete',char_length(coalesce(p.abstract,''))<2000,'categories',to_jsonb(p.categories),
   'topics',to_jsonb(p.topics),'upvotes',p.upvotes,'announced_on',p.announced_on,'first_seen_at',p.first_seen_at)
   order by p.announced_on desc,p.source_id desc),'[]'::jsonb)
 into results
 from (select * from app_private.feed_papers p
  where p.categories@>array[p_category] and p.announced_on>=(now() at time zone 'UTC')::date-pol.retention_days
   and not exists(select 1 from app_private.feed_feedback f where f.account_id=p_account_id and f.source_id=p.source_id and f.kind='not_interested')
  order by p.announced_on desc,p.source_id desc limit p_limit) p;
 return jsonb_build_object('serving',true,'results',results,'refreshed_at',refreshed);
end $$;

-- Operations: 043's status plus popularity (switch, listing days, pool papers with upvotes).
create or replace function public.worker_feed_status() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare cron_state jsonb;
begin
 if to_regclass('cron.job') is not null then
  execute $q$select jsonb_build_object('active',active,'schedule',schedule) from cron.job where jobname='science-reader-feed'$q$ into cron_state;
 end if;
 return jsonb_build_object('policy',(select to_jsonb(p)-'singleton' from app_private.feed_policy p),
  'sources',(select coalesce(jsonb_agg(to_jsonb(s)-'claim_id' order by s.name),'[]'::jsonb) from app_private.feed_sources s),
  'pool',(select jsonb_build_object('rows',count(*),'newest',max(announced_on),'oldest',min(announced_on),
    'last_14_days',count(*) filter (where announced_on>=(now() at time zone 'UTC')::date-14),
    'with_upvotes',count(*) filter (where upvotes is not null)) from app_private.feed_papers),
  'popularity',(select jsonb_build_object('days',count(*),'ok',count(*) filter (where status='ok'),'last_checked',max(checked_at),
    'last_fetched',max(fetched_at)) from app_private.feed_signal_days),
  'feedback_rows',(select count(*) from app_private.feed_feedback),'cron',cron_state);
end $$;

revoke all on function app_private.feed_generic_tag(text) from public,anon,authenticated;
revoke all on function app_private.feed_valid_compounds(jsonb) from public,anon,authenticated;
revoke all on function app_private.feed_excluded(uuid) from public,anon,authenticated;
do $$ declare f record; begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  and p.proname in ('worker_set_feed_popularity','worker_feed_signal_plan','worker_feed_signals_record','worker_feed_candidates_v2',
   'worker_feed_details','worker_feed_category_v2','worker_feed_status') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
