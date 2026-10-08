-- Personalized feed, option A (docs/architecture/PERSONALIZED_FEED.md): a shared pool of new arXiv
-- papers refreshed on a schedule, ranked per reader from server-visible signals only, with
-- "Not interested" / "More like this" feedback. No paid provider is called. Additive over 001-042.
--
-- Switches (both off): feed_policy.serving ('off' | 'staff' | 'all') gates For you, pool-served
-- category chips and feedback; feed_policy.refresh_enabled gates the arXiv refresh. The refresh is
-- woken by pg_cron through pg_net only when the source is due (feed_refresh_kick), posting to the
-- `feed-refresh` Edge function with a dedicated Vault secret; locally (no pg_cron/pg_net/Vault) it is
-- a no-op. Ranking itself lives in the discover function (TypeScript) so it can change without a
-- migration; SQL returns bounded inputs (worker_feed_candidates).
--
-- Feed feedback is service-visible (like personal tags, owner decision 2026-10-07) and is deleted
-- when the account is closed (trigger below), without re-wrapping the reviewed deletion function.
begin;
set local lock_timeout='15s';

-- arXiv identifiers and categories as the discover function accepts them.
create function app_private.feed_valid_source(p text) returns boolean language sql immutable set search_path='' as $$
 select p is not null and (p ~ '^[0-9]{4}\.[0-9]{4,5}$' or p ~ '^[a-z-]{2,20}(\.[A-Z]{2})?/[0-9]{7}$')
$$;
create function app_private.feed_valid_categories(p text[]) returns boolean language sql immutable set search_path='' as $$
 select p is not null and coalesce(array_ndims(p),1)=1 and cardinality(p) between 1 and 16
  and not exists(select 1 from unnest(p) c where c is null or c !~ '^[a-z]{2,8}(-[a-z]{2,6})?(\.[A-Z]{2})?$')
$$;
-- Normalized author name for matching (same function on both sides, so locale effects agree).
create function app_private.feed_author_key(p text) returns text language sql immutable set search_path='' as $$
 select coalesce(btrim(regexp_replace(lower(coalesce(p,'')),'[[:space:][:punct:]]+',' ','g')),'')
$$;
-- Keys aligned with the authors array (an unusable name keeps its slot as '').
create function app_private.feed_author_keys(p text[]) returns text[] language sql immutable set search_path='' as $$
 select coalesce(array(select app_private.feed_author_key(a) from unnest(p) with ordinality u(a,n) order by n),'{}')
$$;
-- First three and last author: the people a reader follows a paper for (big collaborations add noise).
create function app_private.feed_lead_keys(p text[]) returns text[] language sql immutable set search_path='' as $$
 select coalesce(array(select distinct k from unnest(p[1:3]||p[cardinality(p):cardinality(p)]) k where k<>''),'{}')
$$;
create function app_private.feed_json_texts(p jsonb,p_limit integer) returns text[] language sql immutable set search_path='' as $$
 select coalesce(array(select left(x,256) from jsonb_array_elements_text(case when jsonb_typeof(p)='array' then p else '[]'::jsonb end)
  with ordinality e(x,n) where n<=p_limit order by n),'{}')
$$;

create table app_private.feed_policy (
 singleton boolean primary key default true check(singleton),
 serving text not null default 'off' check(serving in ('off','staff','all')),
 refresh_enabled boolean not null default false,
 categories text[] not null default array['cs.LG','cs.CL','cs.CV','cs.AI','stat.ML','cs.RO','cs.IR','cs.NE','cs.MA','cs.SD','eess.AS','eess.IV']
  check(app_private.feed_valid_categories(categories)),
 refresh_minutes integer not null default 120 check(refresh_minutes between 30 and 1440),
 lease_seconds integer not null default 300 check(lease_seconds between 60 and 900),
 retention_days integer not null default 30 check(retention_days between 7 and 90),
 window_days integer not null default 14 check(window_days between 2 and 30),
 max_rows integer not null default 60000 check(max_rows between 1000 and 200000),
 max_items integer not null default 3000 check(max_items between 100 and 10000),
 feedback_rows integer not null default 1000 check(feedback_rows between 10 and 10000),
 updated_at timestamptz not null default now(),
 check(window_days<=retention_days)
);
insert into app_private.feed_policy default values;

-- One row per upstream feed; today only 'arxiv-ml' (one combined, conditional RSS request).
create table app_private.feed_sources (
 name text primary key check(name ~ '^[a-z0-9-]{1,32}$'),
 categories text[] not null check(app_private.feed_valid_categories(categories)),
 next_check_at timestamptz not null default now(),
 claim_id uuid, lease_until timestamptz,
 etag text check(char_length(etag)<=256),
 last_modified text check(char_length(last_modified)<=64),
 last_attempt_at timestamptz, last_success_at timestamptz,
 last_status text check(last_status in ('updated','not_modified','failed','busy')),
 last_items integer check(last_items>=0),
 failures integer not null default 0 check(failures>=0),
 check((claim_id is null)=(lease_until is null))
);

-- The shared pool: public arXiv metadata only, one row per paper, kept retention_days.
create table app_private.feed_papers (
 source_id text primary key check(app_private.feed_valid_source(source_id)),
 revision integer not null check(revision between 1 and 10000),
 title text not null check(char_length(title) between 1 and 2000),
 authors text[] not null check(cardinality(authors)<=12 and coalesce(array_ndims(authors),1)=1),
 author_keys text[] not null check(cardinality(author_keys)=cardinality(authors)),
 abstract text check(char_length(abstract)<=2000),
 categories text[] not null check(cardinality(categories) between 1 and 12 and coalesce(array_ndims(categories),1)=1),
 topics text[] not null default '{}' check(app_private.valid_tag_list(topics,12)),
 topics_version text check(topics_version ~ '^[a-z0-9-]{1,64}$'),
 announced_on date not null,
 announce_type text not null check(announce_type in ('new','cross')),
 first_seen_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 search tsvector generated always as (to_tsvector('english'::regconfig,title||' '||coalesce(abstract,''))) stored
);
create index feed_papers_announced on app_private.feed_papers(announced_on desc,source_id desc);
create index feed_papers_categories on app_private.feed_papers using gin(categories);
create index feed_papers_topics on app_private.feed_papers using gin(topics);
create index feed_papers_authors on app_private.feed_papers using gin(author_keys);
create index feed_papers_search on app_private.feed_papers using gin(search);

-- A reader's Feed choices. The paper's features are snapshotted so the signal outlives the pool.
create table app_private.feed_feedback (
 account_id uuid not null references app_private.accounts(id),
 source_id text not null check(app_private.feed_valid_source(source_id)),
 kind text not null check(kind in ('not_interested','more_like_this')),
 title text check(char_length(title) between 1 and 300),
 categories text[] not null default '{}' check(cardinality(categories)<=12),
 topics text[] not null default '{}' check(cardinality(topics)<=12),
 author_keys text[] not null default '{}' check(cardinality(author_keys)<=4),
 created_at timestamptz not null default now(),
 primary key(account_id,source_id)
);
create index feed_feedback_recent on app_private.feed_feedback(account_id,created_at desc);

-- The "added by several readers" aggregate starts from at most 400 candidate papers.
create index feed_catalog_metadata_source on app_private.catalog_metadata(source_id);
create index feed_library_items_approval on app_private.library_items(approval_id) where removed_at is null;

alter table app_private.feed_policy enable row level security;
alter table app_private.feed_sources enable row level security;
alter table app_private.feed_papers enable row level security;
alter table app_private.feed_feedback enable row level security;

insert into app_private.api_rate_rules values('feed-feedback',3600,120,3000) on conflict(route) do nothing;

-- Who For you serves: everyone, staff (accounts with an operator/tester role), or no one.
create function app_private.feed_serves(a uuid) returns boolean language sql stable security definer set search_path='' as $$
 select case (select serving from app_private.feed_policy where singleton)
  when 'all' then true
  when 'staff' then exists(select 1 from app_private.app_roles where account_id=a)
  else false end
$$;

-- Closing an account (deletion) forgets its Feed choices; worker_delete_account_begin sets closed_at.
create function app_private.feed_forget_account() returns trigger language plpgsql security definer set search_path='' as $$
begin delete from app_private.feed_feedback where account_id=new.id; return null; end $$;
create trigger feed_forget_closed_account after update of closed_at on app_private.accounts
 for each row when (new.closed_at is not null) execute function app_private.feed_forget_account();

-- Operator switch (scripts and the rollout steps); returns the policy.
create function public.worker_set_feed_policy(p_serving text,p_refresh boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.feed_policy;
begin
 if p_serving is null or p_serving not in ('off','staff','all') or p_refresh is null then raise exception 'invalid_feed_policy'; end if;
 update app_private.feed_policy set serving=p_serving,refresh_enabled=p_refresh,updated_at=now() where singleton returning * into strict r;
 return to_jsonb(r)-'singleton';
end $$;

-- Refresh, step 1: claim the source if refreshing is on and it is due (or its lease expired).
-- A changed category list resets the conditional-request validators (the URL changes).
create function public.worker_feed_refresh_claim() returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.feed_policy; s app_private.feed_sources; claim uuid:=gen_random_uuid();
begin
 select * into strict pol from app_private.feed_policy where singleton;
 if not pol.refresh_enabled then return null; end if;
 insert into app_private.feed_sources(name,categories) values('arxiv-ml',pol.categories) on conflict(name) do nothing;
 select * into strict s from app_private.feed_sources where name='arxiv-ml' for update;
 if s.categories is distinct from pol.categories then
  update app_private.feed_sources set categories=pol.categories,etag=null,last_modified=null,next_check_at=now()
   where name=s.name returning * into s;
 end if;
 if s.next_check_at>now() or (s.lease_until is not null and s.lease_until>now()) then return null; end if;
 update app_private.feed_sources set claim_id=claim,lease_until=now()+make_interval(secs=>pol.lease_seconds),last_attempt_at=now()
  where name=s.name;
 return jsonb_build_object('claim_id',claim,'source',s.name,'categories',to_jsonb(s.categories),'etag',s.etag,
  'last_modified',s.last_modified,'max_items',pol.max_items);
end $$;

create function app_private.feed_claimed(p_claim_id uuid) returns app_private.feed_sources
language plpgsql security definer set search_path='' as $$
declare s app_private.feed_sources;
begin
 select * into s from app_private.feed_sources where claim_id=p_claim_id and lease_until>now() for update;
 if not found then raise exception 'feed_claim_lost'; end if;
 return s;
end $$;

-- One pool item as the refresh function sends it (strict: the function filters arXiv's data first).
create function app_private.feed_valid_item(p jsonb) returns boolean language sql immutable set search_path='' as $$
 select jsonb_typeof(p)='object'
  and (p-'source_id'-'revision'-'title'-'authors'-'abstract'-'categories'-'topics'-'announced_on'-'announce_type')='{}'::jsonb
  and jsonb_typeof(p->'source_id')='string' and app_private.feed_valid_source(p->>'source_id')
  and jsonb_typeof(p->'revision')='number' and (p->>'revision') ~ '^[0-9]{1,5}$' and (p->>'revision')::integer between 1 and 10000
  and jsonb_typeof(p->'title')='string' and char_length(p->>'title') between 1 and 2000
  and jsonb_typeof(p->'authors')='array' and jsonb_array_length(p->'authors')<=12
  and not exists(select 1 from jsonb_array_elements(p->'authors') a where jsonb_typeof(a)<>'string' or char_length(a#>>'{}') not between 1 and 256)
  and (p->'abstract' is null or jsonb_typeof(p->'abstract')='null' or (jsonb_typeof(p->'abstract')='string' and char_length(p->>'abstract')<=2000))
  and jsonb_typeof(p->'categories')='array' and jsonb_array_length(p->'categories') between 1 and 12
  and not exists(select 1 from jsonb_array_elements(p->'categories') c where jsonb_typeof(c)<>'string' or (c#>>'{}') !~ '^[A-Za-z][A-Za-z0-9.-]{0,63}$')
  and jsonb_typeof(p->'topics')='array' and jsonb_array_length(p->'topics')<=12
  and not exists(select 1 from jsonb_array_elements(p->'topics') t where jsonb_typeof(t)<>'string')
  and app_private.valid_tag_list(app_private.feed_json_texts(p->'topics',12),12)
  and jsonb_typeof(p->'announced_on')='string' and (p->>'announced_on') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  and jsonb_typeof(p->'announce_type')='string' and p->>'announce_type' in ('new','cross')
$$;

-- Called only while holding the sole upstream's claim row (all pool writers use that fence).
-- Bound every committed batch, not only a successful finish: a dead/expired worker must not
-- accumulate unpruned rows across later claims. This is pool metadata, never a reader's library.
create function app_private.feed_prune_pool() returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.feed_policy; pruned integer; extra integer; n integer;
begin
 select * into strict pol from app_private.feed_policy where singleton;
 delete from app_private.feed_papers where announced_on<(now() at time zone 'UTC')::date-pol.retention_days;
 get diagnostics pruned=row_count;
 select count(*) into n from app_private.feed_papers;
 extra:=n-pol.max_rows;
 if extra>0 then
  delete from app_private.feed_papers where source_id in (select source_id from app_private.feed_papers
   order by announced_on,first_seen_at,source_id limit extra);
  pruned:=pruned+extra; n:=n-extra;
 end if;
 return jsonb_build_object('pruned',pruned,'pool',n);
end $$;

-- Refresh, step 2 (repeatable, batches of at most 500): upsert pool rows under a live claim.
-- A paper seen again keeps its first-seen time and earliest announcement, gains categories, and
-- is "new" if any listing announced it as new.
create function public.worker_feed_upsert(p_claim_id uuid,p_items jsonb,p_topics_version text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare inserted integer; total integer;
begin
 perform app_private.feed_claimed(p_claim_id);
 if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items)>500
  or p_topics_version is null or p_topics_version !~ '^[a-z0-9-]{1,64}$'
  or exists(select 1 from jsonb_array_elements(p_items) i where not app_private.feed_valid_item(i))
  or (select count(distinct i->>'source_id') from jsonb_array_elements(p_items) i)<>jsonb_array_length(p_items) then
  raise exception 'invalid_feed_items';
 end if;
 if exists(select 1 from jsonb_array_elements(p_items) i where (i->>'announced_on')::date not between
   (now() at time zone 'UTC')::date-60 and (now() at time zone 'UTC')::date+2) then raise exception 'invalid_feed_items'; end if;
 with rows as (
  select i->>'source_id' source_id,(i->>'revision')::integer revision,btrim(i->>'title') title,
   app_private.feed_json_texts(i->'authors',12) authors,nullif(i->>'abstract','') abstract,
   app_private.feed_json_texts(i->'categories',12) categories,app_private.feed_json_texts(i->'topics',12) topics,
   (i->>'announced_on')::date announced_on,i->>'announce_type' announce_type
  from jsonb_array_elements(p_items) i),
 written as (
  insert into app_private.feed_papers as f(source_id,revision,title,authors,author_keys,abstract,categories,topics,topics_version,announced_on,announce_type)
  select source_id,revision,title,authors,app_private.feed_author_keys(authors),abstract,categories,topics,p_topics_version,announced_on,announce_type from rows
  on conflict(source_id) do update set revision=greatest(f.revision,excluded.revision),title=excluded.title,authors=excluded.authors,
   author_keys=excluded.author_keys,abstract=coalesce(excluded.abstract,f.abstract),
   categories=(select array_agg(c order by n) from (select c,min(n) n from unnest(f.categories||excluded.categories) with ordinality u(c,n) group by c) x
    where n<=12),
   topics=excluded.topics,topics_version=excluded.topics_version,announced_on=least(f.announced_on,excluded.announced_on),
   announce_type=case when 'new' in (f.announce_type,excluded.announce_type) then 'new' else 'cross' end,updated_at=now()
  returning (xmax=0) as fresh)
 select count(*) filter (where fresh),count(*) into inserted,total from written;
 return jsonb_build_object('inserted',inserted,'updated',total-inserted)||app_private.feed_prune_pool();
end $$;

-- Refresh, step 3: record the outcome, schedule the next check, release the claim, prune the pool.
-- updated/not_modified: next check after refresh_minutes. failed: back off 15 min doubling, at most
-- 6 h. busy (arXiv pacing slot taken): try again in 10 min without counting a failure.
create function public.worker_feed_refresh_finish(p_claim_id uuid,p_status text,p_etag text,p_last_modified text,p_items integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.feed_policy; s app_private.feed_sources;
begin
 if p_status is null or p_status not in ('updated','not_modified','failed','busy') or (p_items is not null and p_items<0)
  or char_length(p_etag)>256 or char_length(p_last_modified)>64 then raise exception 'invalid_feed_refresh'; end if;
 select * into strict pol from app_private.feed_policy where singleton;
 s:=app_private.feed_claimed(p_claim_id);
 update app_private.feed_sources set claim_id=null,lease_until=null,last_status=p_status,
  last_items=case when p_status='updated' then coalesce(p_items,0) else last_items end,
  last_success_at=case when p_status in ('updated','not_modified') then now() else last_success_at end,
  etag=case when p_status='updated' then p_etag else etag end,
  last_modified=case when p_status='updated' then p_last_modified else last_modified end,
  failures=case when p_status='failed' then failures+1 when p_status='busy' then failures else 0 end,
  next_check_at=now()+case p_status when 'failed' then least(interval '6 hours',interval '15 minutes'*power(2,least(s.failures,10)))
   when 'busy' then interval '10 minutes' else make_interval(mins=>pol.refresh_minutes) end
  where name=s.name;
 return app_private.feed_prune_pool();
end $$;

-- pg_cron (every 30 min): wake the feed-refresh function only when refreshing is on and the
-- source is due. pg_net and the Vault secrets exist only hosted; otherwise this does nothing.
create function app_private.feed_refresh_kick() returns boolean language plpgsql security definer set search_path='' as $$
declare due boolean; url text; secret text;
begin
 select p.refresh_enabled and coalesce((select s.next_check_at<=now() and (s.lease_until is null or s.lease_until<=now())
   from app_private.feed_sources s where s.name='arxiv-ml'),true) into due from app_private.feed_policy p where p.singleton;
 if not coalesce(due,false) or to_regnamespace('net') is null or to_regnamespace('vault') is null then return false; end if;
 begin
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into url using 'science_reader_feed_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into secret using 'science_reader_feed_secret';
  if url is null or secret is null then return false; end if;
  execute 'select net.http_post(url:=$1,body:=$2,headers:=$3,timeout_milliseconds:=10000)'
   using url,'{"reason":"cron"}'::jsonb,jsonb_build_object('content-type','application/json','x-feed-secret',secret);
  return true;
 exception when others then return false;
 end;
end $$;

-- A reader's profile: visible library papers (≤ 300, newest first) and imports in flight (≤ 50),
-- with public metadata only. Uploads contribute their personal tags, never their (encrypted) title.
create function app_private.feed_profile(a uuid) returns table(source_id text,title text,added_at timestamptz,archived boolean,
 pending boolean,categories text[],tags text[],own_tags text[],author_keys text[])
language sql stable security definer set search_path='' as $$
 (select cm.source_id,case when cm.source_id like 'upload:%' then null else left(btrim(cm.metadata->>'title'),300) end,
   li.added_at,li.archived_at is not null,false,
   case when cm.source_id like 'upload:%' then '{}'::text[] else app_private.feed_json_texts(cm.metadata->'categories',12) end,
   coalesce(array(select distinct t from unnest(array(select x from unnest(li.catalog_tags) x
    where lower(x)<>all(array(select lower(h) from unnest(li.hidden_tags) h)))||li.user_tags) t),'{}'),
   li.user_tags,
   case when cm.source_id like 'upload:%' then '{}'::text[] else
    app_private.feed_lead_keys(app_private.feed_author_keys(app_private.feed_json_texts(cm.metadata->'authors',512))) end
  from app_private.library_items li
  left join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
  left join app_private.catalog_metadata cm on cm.id=ca.metadata_id
  where li.account_id=a and li.removed_at is null
  order by li.added_at desc limit 300)
 union all
 (select i.source_id,case when i.source_id like 'upload:%' then null else left(btrim(cm.metadata->>'title'),300) end,
   i.created_at,false,true,app_private.feed_json_texts(cm.metadata->'categories',12),'{}'::text[],'{}'::text[],
   app_private.feed_lead_keys(app_private.feed_author_keys(app_private.feed_json_texts(cm.metadata->'authors',512)))
  from app_private.import_requests i left join app_private.catalog_metadata cm on cm.id=i.metadata_id
  where i.account_id=a and i.desired_present and i.phase in ('accepted','resolving','acquiring') and i.library_item_id is null
  order by i.created_at desc limit 50)
$$;

-- For you, inputs for ranking (the discover function ranks). Excludes papers in the library, in
-- flight or marked Not interested. Candidates (≤ 400 from the window): those sharing a topic, a lead
-- author or a phrase-matched own tag with the profile (best 250 by a coarse score), then up to 100
-- that share only a category, then the newest (50, or 200 for a reader with no profile), each set
-- ordered by a per-account-per-day hash so the sample changes daily. Own tags that match more than 2 %
-- of the window ("important", "to read") are ignored as phrases. `readers` is reported only when at
-- least three other accounts added the paper in the last 14 days.
create function public.worker_feed_candidates(p_account_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare pol app_private.feed_policy; today date:=(now() at time zone 'UTC')::date; since date; pool_rows integer;
 seed text; t_topics text[]; t_own text[]; t_authors text[]; t_categories text[]; empty_profile boolean;
 candidates jsonb; refreshed timestamptz;
begin
 if p_account_id is null or not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is null) then
  raise exception 'account_unavailable' using errcode='42501';
 end if;
 select * into strict pol from app_private.feed_policy where singleton;
 if not app_private.feed_serves(p_account_id) then raise exception 'feed_unavailable'; end if;
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

 -- Ranking uses a bounded recent profile; eligibility must cover the entire account. Otherwise
 -- older owned/dismissed papers (and failed imports still in the library) reappear after the cap.
 with excluded as materialized (
  select cm.source_id from app_private.library_items li
   join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
   join app_private.catalog_metadata cm on cm.id=ca.metadata_id
   where li.account_id=p_account_id and li.removed_at is null
  union select i.source_id from app_private.import_requests i
   where i.account_id=p_account_id and i.desired_present
  union select f.source_id from app_private.feed_feedback f
   where f.account_id=p_account_id and f.kind='not_interested'),
 own_q as (
  select t,phraseto_tsquery('english'::regconfig,t) q from unnest(t_own) t
  where t ~ '[[:alpha:]]' and lower(t) not in ('to read','read later','read','reading','important','favorite','favorites','todo','to do',
   'later','reviewed','review','starred','misc','other','paper','papers','work','thesis')),
 own_hits as (
  select o.t,p.source_id from own_q o join app_private.feed_papers p on numnode(o.q)>0 and p.search@@o.q and p.announced_on>=since),
 own_ok as (select t from own_hits group by t having count(*)<=greatest(20,pool_rows/50)),
 phrase as (select h.source_id,array_agg(distinct h.t) tags from own_hits h join own_ok using(t) group by h.source_id),
 -- Scoring columns only (abstracts and text vectors would be materialized for the whole window).
 win as (
  select p.source_id,p.announced_on,p.categories,coalesce(ph.tags,'{}') matched_tags,
   case when p.topics&&t_topics then (select count(*) from unnest(p.topics) x where x=any(t_topics))::integer else 0 end topic_hits,
   case when p.author_keys&&t_authors then (select count(*) from unnest(p.author_keys) x where x<>'' and x=any(t_authors))::integer else 0 end author_hits,
   case when p.categories&&t_categories then (select count(*) from unnest(p.categories) x where x=any(t_categories))::integer else 0 end category_hits,
   md5(seed||p.source_id) shuffle
  from app_private.feed_papers p left join phrase ph on ph.source_id=p.source_id
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
 chosen as (select source_id from strong union select source_id from broad union select source_id from fresh),
 readers as (
  select cm.source_id,count(distinct li.account_id)::integer n
  from app_private.catalog_metadata cm
  join app_private.catalog_asset_approvals ca on ca.metadata_id=cm.id
  join app_private.library_items li on li.approval_id=ca.id
  where cm.source_id in (select source_id from chosen) and li.removed_at is null and li.account_id<>p_account_id
   and li.added_at>now()-interval '14 days'
  group by cm.source_id having count(distinct li.account_id)>=3)
 select coalesce(jsonb_agg(jsonb_build_object('source_id',p.source_id,'revision',p.revision,'title',p.title,'authors',to_jsonb(p.authors),
   'author_keys',to_jsonb(p.author_keys),'abstract',left(p.abstract,700),'categories',to_jsonb(p.categories),'topics',to_jsonb(p.topics),
   'announced_on',p.announced_on,'first_seen_at',p.first_seen_at,'matched_tags',to_jsonb(coalesce(ph.tags,'{}')),'readers',r.n)
   order by p.announced_on desc,p.source_id desc),'[]'::jsonb)
 into candidates
 from chosen c join app_private.feed_papers p on p.source_id=c.source_id
 left join phrase ph on ph.source_id=p.source_id left join readers r on r.source_id=p.source_id;

 select max(last_success_at) into refreshed from app_private.feed_sources;
 return jsonb_build_object('now',now(),'today',today,'seed',seed,'window_days',pol.window_days,'pool',pool_rows,'refreshed_at',refreshed,
  'categories',to_jsonb(pol.categories),
  'profile',(select coalesce(jsonb_agg(to_jsonb(x) order by x.added_at desc),'[]'::jsonb) from app_private.feed_profile(p_account_id) x),
  'feedback',(select coalesce(jsonb_agg(jsonb_build_object('source_id',f.source_id,'kind',f.kind,'title',f.title,'categories',to_jsonb(f.categories),
    'topics',to_jsonb(f.topics),'author_keys',to_jsonb(f.author_keys),'created_at',f.created_at) order by f.created_at desc),'[]'::jsonb)
   from (select * from app_private.feed_feedback where account_id=p_account_id order by created_at desc limit 300) f),
  'candidates',candidates);
end $$;

-- A category chip served from the pool: null results when the account is not served, the category
-- is not in the pool, or the pool has not refreshed in three days (the function then uses live RSS).
create function public.worker_feed_category(p_account_id uuid,p_category text,p_limit integer default 25) returns jsonb
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
   'abstract',left(p.abstract,700),'categories',to_jsonb(p.categories),'announced_on',p.announced_on,'first_seen_at',p.first_seen_at)
   order by p.announced_on desc,p.source_id desc),'[]'::jsonb)
 into results
 from (select * from app_private.feed_papers p
  where p.categories@>array[p_category] and p.announced_on>=(now() at time zone 'UTC')::date-pol.retention_days
   and not exists(select 1 from app_private.feed_feedback f where f.account_id=p_account_id and f.source_id=p.source_id and f.kind='not_interested')
  order by p.announced_on desc,p.source_id desc limit p_limit) p;
 return jsonb_build_object('serving',true,'results',results,'refreshed_at',refreshed);
end $$;

-- Not interested / More like this, or clear (p_kind null). One row per account and paper; the newest
-- feedback_rows are kept.
create function public.v1_feed_feedback(p_source_id text,p_kind text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); pol app_private.feed_policy; p app_private.feed_papers;
begin
 if not app_private.feed_valid_source(p_source_id) or (p_kind is not null and p_kind not in ('not_interested','more_like_this')) then
  raise exception 'invalid_feed_feedback';
 end if;
 -- Hold an account fence through commit. The closure UPDATE either waits for this write and
 -- deletes it, or finishes first and the rechecked row refuses the late write. KEY SHARE would
 -- not fence a non-key closed_at update. Account -> rate windows -> feedback is the lock order.
 perform 1 from app_private.accounts where id=a and closed_at is null for share;
 if not found then raise exception 'account_unavailable' using errcode='42501'; end if;
 select * into strict pol from app_private.feed_policy where singleton;
 if not app_private.feed_serves(a) then raise exception 'feed_unavailable'; end if;
 perform public.worker_consume_request(a,'feed-feedback');
 -- One writer per account at a time keeps the row cap exact (namespace 744400 is reserved for this).
 perform pg_advisory_xact_lock(744400,hashtext(a::text));
 if p_kind is null then
  delete from app_private.feed_feedback where account_id=a and source_id=p_source_id;
  return jsonb_build_object('source_id',p_source_id,'kind',null);
 end if;
 select * into p from app_private.feed_papers where source_id=p_source_id;
 insert into app_private.feed_feedback(account_id,source_id,kind,title,categories,topics,author_keys)
  values(a,p_source_id,p_kind,left(p.title,300),coalesce(p.categories,'{}'),coalesce(p.topics,'{}'),
   coalesce(app_private.feed_lead_keys(p.author_keys),'{}'))
  on conflict(account_id,source_id) do update set kind=excluded.kind,title=excluded.title,categories=excluded.categories,
   topics=excluded.topics,author_keys=excluded.author_keys,created_at=now();
 delete from app_private.feed_feedback where account_id=a and source_id in (select source_id from app_private.feed_feedback
  where account_id=a order by created_at desc,source_id desc offset pol.feedback_rows);
 return jsonb_build_object('source_id',p_source_id,'kind',p_kind);
end $$;

-- Operations: switch state, the source's last outcome and the pool's size.
create function public.worker_feed_status() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare cron_state jsonb;
begin
 if to_regclass('cron.job') is not null then
  execute $q$select jsonb_build_object('active',active,'schedule',schedule) from cron.job where jobname='science-reader-feed'$q$ into cron_state;
 end if;
 return jsonb_build_object('policy',(select to_jsonb(p)-'singleton' from app_private.feed_policy p),
  'sources',(select coalesce(jsonb_agg(to_jsonb(s)-'claim_id' order by s.name),'[]'::jsonb) from app_private.feed_sources s),
  'pool',(select jsonb_build_object('rows',count(*),'newest',max(announced_on),'oldest',min(announced_on),
    'last_14_days',count(*) filter (where announced_on>=(now() at time zone 'UTC')::date-14)) from app_private.feed_papers),
  'feedback_rows',(select count(*) from app_private.feed_feedback),'cron',cron_state);
end $$;

do $$ begin
 if to_regprocedure('cron.schedule(text,text,text)') is not null then
  execute $q$select cron.schedule('science-reader-feed','*/30 * * * *','select app_private.feed_refresh_kick()')$q$;
 end if;
end $$;

revoke all on function app_private.feed_refresh_kick() from public,anon,authenticated;
revoke all on function app_private.feed_profile(uuid) from public,anon,authenticated;
revoke all on function app_private.feed_serves(uuid) from public,anon,authenticated;
revoke all on function app_private.feed_claimed(uuid) from public,anon,authenticated;
do $$ declare f record; begin
 for f in select p.oid::regprocedure signature,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  and p.proname in ('worker_set_feed_policy','worker_feed_refresh_claim','worker_feed_upsert','worker_feed_refresh_finish',
   'worker_feed_candidates','worker_feed_category','worker_feed_status','v1_feed_feedback') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  execute format('grant execute on function %s to %I',f.signature,case when f.proname like 'worker_%' then 'service_role' else 'authenticated' end);
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
