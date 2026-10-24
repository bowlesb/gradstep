-- For you reads the current (v4) library. Since the HTML-first reader (058) an arXiv paper the reader adds stays an
-- import (`phase='source_only'`, no library item), but 043's profile read library papers only from the legacy
-- `library_items` plus imports in flight, so a reader whose library is all v4 imports was ranked as a cold start
-- (every reason "popular" or "category"), and "Added by several readers this week" counted legacy items only.
-- Design: docs/architecture/PERSONALIZED_FEED.md, "Interest signals". Additive: 043 and 046 are unchanged; this
-- supersedes app_private.feed_profile and public.worker_feed_candidates_v2 with the same signatures and results.
--
-- - Profile: present imports that are no longer in flight and have no library item (source_only; also failed and
--   membership_conflict, which the Library still lists) count as library papers: pending=false, archived as the Library
--   shows it, added at the import's creation, title/categories/authors from the catalog record (metadata_id) or else
--   the device's record (device_metadata), tags as the Library shows them (library_query_entries.effective_tags; with
--   none, the reader's tags, else the paper's category tags, as for a device-only record without a catalog row), own
--   tags = the reader's customized tags less the paper's category tags. A paper that also has a present library item
--   counts once (as the item). Library papers stay ≤ 300 newest (items and imports together), imports in flight ≤ 50.
--   Uploads keep their rule: no title, categories or authors; only their own tags.
-- - Readers: an account counts toward "Added by several readers this week" for a present library item or a present
--   import created in the last 14 days (still ≥ 3 other accounts).
-- - A topic chip on one of the reader's own tags is accepted when the tag is on a v4 import, too.
-- - Exclusions are unchanged: 046's feed_excluded already drops every present import (source_only included).
begin;
set local lock_timeout='15s';

-- The readers aggregate looks imports up by paper across accounts (at most 400 candidate papers per request).
create index import_requests_source_added on app_private.import_requests(source_id,created_at) where desired_present;

-- An import's own tags: the tags the reader set, less the paper's category tags (the Library's default tags for an
-- import), as library_items keeps user_tags apart from catalog tags. Uploads: their tags are all their own.
create function app_private.feed_import_own_tags(p_source_id text,p_tags text[],p_customized boolean,p_categories jsonb) returns text[]
language sql immutable set search_path='' as $$
 select case when p_source_id like 'upload:%' then coalesce(p_tags,'{}')
  when not coalesce(p_customized,false) then '{}'::text[]
  else coalesce(array(select t from unnest(p_tags) with ordinality u(t,n)
   where lower(t)<>all(array(select lower(c) from unnest(app_private.library_query_category_tags(
    case when jsonb_typeof(p_categories)='array' then p_categories else '[]'::jsonb end)) c)) order by n),'{}') end
$$;

-- How many other accounts added each paper in the last 14 days (library items or imports they still have), reported
-- only at three or more.
create function app_private.feed_readers(a uuid,p_source_ids text[]) returns table(source_id text,n integer)
language sql stable security definer set search_path='' as $$
 select x.source_id,count(distinct x.account_id)::integer from (
  select cm.source_id,li.account_id from app_private.catalog_metadata cm
   join app_private.catalog_asset_approvals ca on ca.metadata_id=cm.id
   join app_private.library_items li on li.approval_id=ca.id
   where cm.source_id=any(p_source_ids) and li.removed_at is null and li.account_id<>a and li.added_at>now()-interval '14 days'
  union all
  select i.source_id,i.account_id from app_private.import_requests i
   where i.source_id=any(p_source_ids) and i.desired_present and i.account_id<>a and i.created_at>now()-interval '14 days'
 ) x group by x.source_id having count(distinct x.account_id)>=3
$$;

-- A reader's profile: library papers (≤ 300, newest first: present library items and settled imports without an item)
-- and imports in flight (≤ 50), with public metadata only. Uploads contribute their personal tags, never their
-- (encrypted) title.
create or replace function app_private.feed_profile(a uuid) returns table(source_id text,title text,added_at timestamptz,archived boolean,
 pending boolean,categories text[],tags text[],own_tags text[],author_keys text[])
language sql stable security definer set search_path='' as $$
 with item_sources as materialized (
  select cm.source_id from app_private.library_items li
   join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
   join app_private.catalog_metadata cm on cm.id=ca.metadata_id
   where li.account_id=a and li.removed_at is null),
 items as (
  select cm.source_id,case when cm.source_id like 'upload:%' then null else left(btrim(cm.metadata->>'title'),300) end title,
   li.added_at,li.archived_at is not null archived,false pending,
   case when cm.source_id like 'upload:%' then '{}'::text[] else app_private.feed_json_texts(cm.metadata->'categories',12) end categories,
   coalesce(array(select distinct t from unnest(array(select x from unnest(li.catalog_tags) x
    where lower(x)<>all(array(select lower(h) from unnest(li.hidden_tags) h)))||li.user_tags) t),'{}') tags,
   li.user_tags own_tags,
   case when cm.source_id like 'upload:%' then '{}'::text[] else
    app_private.feed_lead_keys(app_private.feed_author_keys(app_private.feed_json_texts(cm.metadata->'authors',512))) end author_keys
  from app_private.library_items li
  left join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
  left join app_private.catalog_metadata cm on cm.id=ca.metadata_id
  where li.account_id=a and li.removed_at is null
  order by li.added_at desc limit 300),
 settled as (
  select d.* from (
   select distinct on (i.source_id) i.id,i.source_id,i.created_at,i.metadata_id,i.device_metadata,i.source_archived,i.source_tags,
    i.source_tags_customized
   from app_private.import_requests i
   where i.account_id=a and i.desired_present and i.library_item_id is null and i.phase in ('source_only','failed','membership_conflict')
    and not exists(select 1 from item_sources s where s.source_id=i.source_id)
   order by i.source_id,i.created_at desc,i.id desc) d
  order by d.created_at desc,d.id desc limit 300),
 imports as (
  select s.source_id,case when md.upload then null else left(btrim(md.m->>'title'),300) end title,
   s.created_at added_at,coalesce(q.archived,s.source_archived) archived,false pending,
   case when md.upload then '{}'::text[] else app_private.feed_json_texts(md.m->'categories',12) end categories,
   case when md.upload then s.source_tags
    else coalesce(nullif(q.effective_tags,'{}'),nullif(s.source_tags,'{}'),
     app_private.library_query_category_tags(case when jsonb_typeof(md.m->'categories')='array' then md.m->'categories' else '[]'::jsonb end))
    end tags,
   app_private.feed_import_own_tags(s.source_id,s.source_tags,s.source_tags_customized,md.m->'categories') own_tags,
   case when md.upload then '{}'::text[] else
    app_private.feed_lead_keys(app_private.feed_author_keys(app_private.feed_json_texts(md.m->'authors',512))) end author_keys
  from settled s
  left join app_private.catalog_metadata cm on cm.id=s.metadata_id
  left join app_private.library_query_entries q on q.account_id=a and q.kind='import' and q.id=s.id
  cross join lateral (select coalesce(cm.metadata,s.device_metadata) m,s.source_id like 'upload:%' upload) md)
 (select l.* from (select * from items union all select * from imports) l order by l.added_at desc limit 300)
 union all
 (select i.source_id,case when i.source_id like 'upload:%' then null else left(btrim(coalesce(cm.metadata,i.device_metadata)->>'title'),300) end,
   i.created_at,false,true,app_private.feed_json_texts(coalesce(cm.metadata,i.device_metadata)->'categories',12),'{}'::text[],'{}'::text[],
   app_private.feed_lead_keys(app_private.feed_author_keys(app_private.feed_json_texts(coalesce(cm.metadata,i.device_metadata)->'authors',512)))
  from app_private.import_requests i left join app_private.catalog_metadata cm on cm.id=i.metadata_id
  where i.account_id=a and i.desired_present and i.phase in ('accepted','resolving','acquiring') and i.library_item_id is null
  order by i.created_at desc limit 50)
$$;

-- 046's For you inputs, version 2, unchanged except: readers come from feed_readers (items and imports), and a topic
-- on one of the reader's own tags may name a tag on a v4 import.
create or replace function public.worker_feed_candidates_v2(p_account_id uuid,p_all text[] default null,p_any text[] default null,
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
    or not (exists(select 1 from app_private.library_items li where li.account_id=p_account_id and li.removed_at is null
     and exists(select 1 from unnest(li.user_tags) t where lower(t)=lower(p_phrase)))
     or exists(select 1 from app_private.import_requests i left join app_private.catalog_metadata cm on cm.id=i.metadata_id
      where i.account_id=p_account_id and i.desired_present and i.library_item_id is null and i.phase in ('source_only','failed','membership_conflict')
      and exists(select 1 from unnest(app_private.feed_import_own_tags(i.source_id,i.source_tags,i.source_tags_customized,
       coalesce(cm.metadata,i.device_metadata)->'categories')) t where lower(t)=lower(p_phrase)))))) then
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
  readers as (select r.source_id,r.n from app_private.feed_readers(p_account_id,array(select source_id from chosen)) r)
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
  readers as (select r.source_id,r.n from app_private.feed_readers(p_account_id,array(select source_id from chosen)) r),
  -- Case-insensitive: a reader's own tag "tokenization" counts the pool's "Tokenization".
  tag_counts as (select t,count(*)::integer n from win cross join lateral unnest(win.topics) t
   where lower(t)=any(array(select lower(x) from unnest(t_topics) x)) group by t),
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


revoke all on function app_private.feed_profile(uuid) from public,anon,authenticated;
revoke all on function app_private.feed_import_own_tags(text,text[],boolean,jsonb),app_private.feed_readers(uuid,text[])
 from public,anon,authenticated,service_role;
revoke all on function public.worker_feed_candidates_v2(uuid,text[],text[],text,jsonb) from public,anon,authenticated;
grant execute on function public.worker_feed_candidates_v2(uuid,text[],text[],text,jsonb) to service_role;
notify pgrst,'reload schema';
commit;
