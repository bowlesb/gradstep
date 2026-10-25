-- For you within half a second (TestFlight 92, 2026-10-25: "Stuck here for like 10 seconds" on For you after sign-in;
-- docs/architecture/PERSONALIZED_FEED.md "Speed: For you right after sign-in"). The same function as 0156 (same
-- signature, inputs, result and order; nothing stored) with three of its parts made cheaper. Measured read-only on
-- staging for the owner's account (84 library papers, 293 author keys, 10 topics, 8,167 window papers, 15 combinations),
-- the live function took 1.51–1.59 s:
--   - combination counts ~1.0 s: each combination's tag lists were parsed again for every window paper
--     (feed_json_texts sets its own search_path, so it is never inlined): 15 × 8,167 calls. Now parsed once (`comp`);
--   - author hits ~240 ms: every window paper's author keys compared with the whole 293-key list. Now one join through
--     feed_papers_authors (`author_hits`), as author_counts already does;
--   - topic counts ~44 ms: the reader's topics lower-cased once per window paper's tag. Now once (`topic_set`).
-- The For you statement generated from this file (variables computed as the function computes them) returned the same
-- candidates and topic counts as the live function (equal MD5 of both) in about a third of a second. Topic chips (topic
-- mode) and 0156's similar tier are unchanged.
begin;
set local lock_timeout='15s';

create or replace function public.worker_feed_candidates_v2(p_account_id uuid,p_all text[] default null,p_any text[] default null,
 p_phrase text default null,p_compounds jsonb default '[]'::jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare pol app_private.feed_policy; today date:=(now() at time zone 'UTC')::date; since date; pool_rows integer;
 seed text; t_topics text[]; t_own text[]; t_authors text[]; t_categories text[]; empty_profile boolean;
 topic_mode boolean:=p_all is not null or p_phrase is not null; phrase tsquery;
 candidates jsonb; v_topics jsonb; refreshed timestamptz;
 prof jsonb; authors_n jsonb; sim_on boolean:=false; imodel text; mapv integer;
 lib_ids text[]:='{}'; lib_titles text[]:='{}'; lib_fps extensions.halfvec[]:='{}';
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

 -- The profile, read once: the response's `profile` and every feature set below come from it.
 select coalesce(jsonb_agg(to_jsonb(x) order by x.added_at desc),'[]'::jsonb) into prof from app_private.feed_profile(p_account_id) x;
 with pr as (select * from jsonb_to_recordset(prof) r(tags text[],own_tags text[],author_keys text[],categories text[])),
 fb as (select * from app_private.feed_feedback where account_id=p_account_id order by created_at desc limit 300)
 select coalesce((select array_agg(distinct t) from (select unnest(tags) t from pr union all
    select unnest(topics) from fb where kind='more_like_this') x),'{}'),
  coalesce((select array_agg(distinct t) from (select unnest(own_tags) t from pr) x),'{}'),
  coalesce((select array_agg(distinct k) from (select unnest(author_keys) k from pr union all
    select unnest(author_keys) from fb where kind='more_like_this') x where k<>''),'{}'),
  coalesce((select array_agg(distinct c) from (select unnest(categories) c from pr union all
    select unnest(categories) from fb where kind='more_like_this') x),'{}')
 into t_topics,t_own,t_authors,t_categories;
 empty_profile:=cardinality(t_topics)=0 and cardinality(t_own)=0 and cardinality(t_authors)=0 and cardinality(t_categories)=0;

 -- How common each of the reader's author keys is in the window: a rare key is a person, a common one may be a namesake.
 select coalesce(jsonb_object_agg(k,n),'{}'::jsonb) into authors_n from (
  select k,count(*)::integer n from app_private.feed_papers p cross join lateral unnest(p.author_keys) k
  where p.announced_on>=since and p.author_keys&&t_authors and k=any(t_authors) group by k) x;

 -- The library's fingerprints (≤ 300 settled, titled public papers, newest first) when the interest index serves them.
 if app_private.interest_serves(p_account_id) then
  select model_version into imodel from app_private.interest_policy where singleton;
  select version into mapv from app_private.interest_map_versions where state='published';
  select coalesce(array_agg(l.source_id order by l.n),'{}'),coalesce(array_agg(l.title order by l.n),'{}'),coalesce(array_agg(l.f order by l.n),'{}')
  into lib_ids,lib_titles,lib_fps from (
   select e.x->>'source_id' source_id,e.x->>'title' title,ip.fingerprint f,e.n
   from jsonb_array_elements(prof) with ordinality e(x,n)
   join app_private.interest_papers ip on ip.source_id=e.x->>'source_id' and ip.state='embedded' and ip.model_version=imodel
   where e.x->>'pending'='false' and e.x->>'title' is not null and e.x->>'source_id' not like 'upload:%'
   order by e.n limit 300) l;
  sim_on:=cardinality(lib_ids)>0;
 end if;

 if topic_mode then
  with excluded as materialized (select x.source_id from app_private.feed_excluded(p_account_id) x),
  win as (
   select p.source_id,p.announced_on,md5(seed||p.source_id) shuffle from app_private.feed_papers p
   where p.announced_on>=since and not exists(select 1 from excluded x where x.source_id=p.source_id)
    and case when phrase is not null then p.search@@phrase
     else p.topics@>p_all and (coalesce(cardinality(p_any),0)=0 or p.topics&&p_any) end),
  chosen as (select source_id from win order by announced_on desc,shuffle limit 300),
  readers as (select r.source_id,r.n from app_private.feed_readers(p_account_id,array(select source_id from chosen)) r),
  lib as materialized (select * from unnest(lib_ids,lib_titles,lib_fps) with ordinality l(source_id,title,f,n) where sim_on),
  nearest as (
   select c.source_id,n.source_id lib_id,n.title lib_title,1-n.d sim from chosen c
   join app_private.interest_papers ip on ip.source_id=c.source_id and ip.state='embedded' and ip.model_version=imodel
   cross join lateral (select lib.source_id,lib.title,ip.fingerprint operator(extensions.<=>) lib.f d from lib order by ip.fingerprint operator(extensions.<=>) lib.f limit 1) n
   where sim_on)
  select coalesce(jsonb_agg(jsonb_build_object('source_id',p.source_id,'revision',p.revision,'title',p.title,'authors',to_jsonb(p.authors),
    'author_keys',to_jsonb(p.author_keys),'categories',to_jsonb(p.categories),'topics',to_jsonb(p.topics),
    'announced_on',p.announced_on,'first_seen_at',p.first_seen_at,
    'matched_tags',case when phrase is not null then jsonb_build_array(p_phrase) else '[]'::jsonb end,
    'readers',r.n,'upvotes',p.upvotes,'similarity',round(nr.sim::numeric,4),
    'similar_to',case when nr.lib_id is not null then jsonb_build_object('source_id',nr.lib_id,'title',nr.lib_title) end)
    order by p.announced_on desc,p.source_id desc),'[]'::jsonb)
  into candidates
  from chosen c join app_private.feed_papers p on p.source_id=c.source_id left join readers r on r.source_id=p.source_id
  left join nearest nr on nr.source_id=p.source_id;
  v_topics:=null;
 else
  with excluded as materialized (select x.source_id from app_private.feed_excluded(p_account_id) x),
  -- 0158: the reader's authors in the window's papers through the author_keys index, once (was: every window paper's
  -- keys compared with the whole author list, ~240 ms for the owner's 293 keys over 8,167 papers).
  author_hits as materialized (
   select p.source_id,count(*)::integer n from app_private.feed_papers p cross join lateral unnest(p.author_keys) k
   where p.announced_on>=since and p.author_keys&&t_authors and k<>'' and k=any(t_authors) group by p.source_id),
  own_q as (
   select t,phraseto_tsquery('english'::regconfig,t) q from unnest(t_own) t where not app_private.feed_generic_tag(t)),
  own_hits as (
   select o.t,p.source_id from own_q o join app_private.feed_papers p on numnode(o.q)>0 and p.search@@o.q and p.announced_on>=since),
  own_ok as (select t from own_hits group by t having count(*)<=greatest(20,pool_rows/50)),
  phrase_tags as (select h.source_id,array_agg(distinct h.t) tags from own_hits h join own_ok using(t) group by h.source_id),
  win as (
   select p.source_id,p.announced_on,p.categories,p.topics,p.upvotes,coalesce(ph.tags,'{}') matched_tags,
    case when p.topics&&t_topics then (select count(*) from unnest(p.topics) x where x=any(t_topics))::integer else 0 end topic_hits,
    coalesce(ah.n,0) author_hits,
    case when p.categories&&t_categories then (select count(*) from unnest(p.categories) x where x=any(t_categories))::integer else 0 end category_hits,
    md5(seed||p.source_id) shuffle
   from app_private.feed_papers p left join phrase_tags ph on ph.source_id=p.source_id left join author_hits ah on ah.source_id=p.source_id
   where p.announced_on>=since and not exists(select 1 from excluded x where x.source_id=p.source_id)),
  lib as materialized (select * from unnest(lib_ids,lib_titles,lib_fps) with ordinality l(source_id,title,f,n) where sim_on),
  -- Each library paper's 3 nearest mid-level map nodes; a window paper is compared only with the library papers that
  -- picked its node.
  lib_mids as materialized (
   select lib.n,m.node_id mid from lib cross join lateral (
    select nv.node_id from app_private.interest_node_versions nv where nv.version=mapv and nv.level=2
    order by nv.centroid operator(extensions.<=>) lib.f limit 3) m
   where mapv is not null),
  -- The window's fingerprints by interest_papers_pool (never the whole 180-day corpus); exclusions apply after.
  -- 0156: each pair's cosine is computed before grouping (the `offset 0` keeps the subquery from being flattened), so
  -- the grouping sorts (source_id, sim) pairs. Grouping the joined rows first sorted both 384-dimension vectors of
  -- every pair: about 117 thousand rows of 1.5 KB for a 300-paper library, which spilled past work_mem (1.0–3.7 s).
  near_win as (
   select d.source_id,max(d.sim) sim from (
    select ip.source_id,1-(ip.fingerprint operator(extensions.<=>) lib.f) sim
    from app_private.interest_papers ip
    join app_private.interest_node_versions lf on lf.version=mapv and lf.node_id=ip.leaf_id
    join lib_mids lm on lm.mid=lf.parent_id
    join lib on lib.n=lm.n
    where ip.pool_announced_on>=since and ip.state='embedded' and ip.model_version=imodel and ip.leaf_map_version=mapv
    offset 0) d
   group by d.source_id),
  alike as (
   select s.source_id from near_win s join win w on w.source_id=s.source_id where s.sim>=0.86
   order by s.sim+0.02*least(1,ln(1+greatest(coalesce(w.upvotes,0),0))/ln(101)) desc,w.announced_on desc,w.shuffle limit 140),
  strong as (
   select source_id from win where topic_hits>0 or author_hits>0 or cardinality(matched_tags)>0
   order by 3*topic_hits+4*author_hits+3*cardinality(matched_tags)+category_hits desc,announced_on desc,shuffle
   limit case when sim_on and mapv is not null then 150 else 250 end),
  broad as (
   select source_id from win where category_hits>0 and source_id not in (select source_id from strong)
   order by announced_on desc,shuffle limit case when sim_on and mapv is not null then 50 else 100 end),
  fresh as (
   select source_id from win where categories && pol.categories
    and source_id not in (select source_id from strong union all select source_id from broad)
   order by announced_on desc,shuffle limit case when empty_profile then 200 when sim_on and mapv is not null then 30 else 50 end),
  popular as (
   select source_id from win where upvotes>=5 and categories && pol.categories
    and source_id not in (select source_id from strong union all select source_id from broad union all select source_id from fresh)
   order by upvotes desc,announced_on desc,shuffle limit 30),
  chosen as (select source_id from alike union select source_id from strong union select source_id from broad
   union select source_id from fresh union select source_id from popular),
  readers as (select r.source_id,r.n from app_private.feed_readers(p_account_id,array(select source_id from chosen)) r),
  -- Exact: every candidate against every library fingerprint (≤ 400 × ≤ 300).
  nearest as (
   select c.source_id,n.source_id lib_id,n.title lib_title,1-n.d sim from chosen c
   join app_private.interest_papers ip on ip.source_id=c.source_id and ip.state='embedded' and ip.model_version=imodel
   cross join lateral (select lib.source_id,lib.title,ip.fingerprint operator(extensions.<=>) lib.f d from lib order by ip.fingerprint operator(extensions.<=>) lib.f limit 1) n
   where sim_on),
  -- Case-insensitive: a reader's own tag "tokenization" counts the pool's "Tokenization".
  -- 0158: the reader's topics lower-cased once (was: once per window paper's tag).
  topic_set as materialized (select distinct lower(x) l from unnest(t_topics) x),
  tag_counts as (select t,count(*)::integer n from win cross join lateral unnest(win.topics) t
   where lower(t) in (select l from topic_set) group by t),
  own_counts as (
   select h.t,count(*)::integer n from own_hits h where not exists(select 1 from excluded x where x.source_id=h.source_id) group by h.t),
  -- 0158: each combination's tag lists read once (was: parsed again for every window paper, 15 × 8,167 calls of a
  -- function that is never inlined; ~1.0 s of the owner's 1.5 s).
  comp as materialized (
   select c->>'name' name,app_private.feed_json_texts(c->'all',4) all_tags,app_private.feed_json_texts(c->'any',6) any_tags,
    jsonb_array_length(c->'any')=0 any_empty
   from jsonb_array_elements(p_compounds) c),
  compound_counts as (
   select k.name,count(w.source_id)::integer n from comp k
   left join win w on w.topics@>k.all_tags and (k.any_empty or w.topics&&k.any_tags)
   group by k.name)
  select (select coalesce(jsonb_agg(jsonb_build_object('source_id',p.source_id,'revision',p.revision,'title',p.title,'authors',to_jsonb(p.authors),
     'author_keys',to_jsonb(p.author_keys),'categories',to_jsonb(p.categories),'topics',to_jsonb(p.topics),
     'announced_on',p.announced_on,'first_seen_at',p.first_seen_at,'matched_tags',to_jsonb(coalesce(ph.tags,'{}')),'readers',r.n,
     'upvotes',p.upvotes,'similarity',round(nr.sim::numeric,4),
     'similar_to',case when nr.lib_id is not null then jsonb_build_object('source_id',nr.lib_id,'title',nr.lib_title) end)
     order by p.announced_on desc,p.source_id desc),'[]'::jsonb)
    from chosen c join app_private.feed_papers p on p.source_id=c.source_id
    left join phrase_tags ph on ph.source_id=p.source_id left join readers r on r.source_id=p.source_id
    left join nearest nr on nr.source_id=p.source_id),
   jsonb_build_object(
    'tags',(select coalesce(jsonb_object_agg(t,n),'{}'::jsonb) from tag_counts),
    'own',(select coalesce(jsonb_object_agg(t,n),'{}'::jsonb) from own_counts),
    'compounds',(select coalesce(jsonb_object_agg(name,n),'{}'::jsonb) from compound_counts))
  into candidates,v_topics;
 end if;

 select max(last_success_at) into refreshed from app_private.feed_sources;
 return jsonb_build_object('now',now(),'today',today,'seed',seed,'window_days',pol.window_days,'pool',pool_rows,'refreshed_at',refreshed,
  'categories',to_jsonb(pol.categories),
  'profile',prof,
  'feedback',(select coalesce(jsonb_agg(jsonb_build_object('source_id',f.source_id,'kind',f.kind,'title',f.title,'categories',to_jsonb(f.categories),
    'topics',to_jsonb(f.topics),'author_keys',to_jsonb(f.author_keys),'created_at',f.created_at) order by f.created_at desc),'[]'::jsonb)
   from (select * from app_private.feed_feedback where account_id=p_account_id order by created_at desc limit 300) f),
  'author_counts',authors_n,
  'similarity',jsonb_build_object('served',sim_on,'library',cardinality(lib_ids),'map_version',case when sim_on then mapv end),
  'candidates',candidates,'topics',v_topics);
end $$;

revoke all on function public.worker_feed_candidates_v2(uuid,text[],text[],text,jsonb) from public,anon,authenticated;
grant execute on function public.worker_feed_candidates_v2(uuid,text[],text[],text,jsonb) to service_role;
notify pgrst,'reload schema';
commit;
