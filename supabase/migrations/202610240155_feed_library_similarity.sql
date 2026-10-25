-- For you by similarity to the library (docs/architecture/PERSONALIZED_FEED.md, "Similarity to the library").
-- The interest index (0152) holds a gte-small fingerprint of every pool paper and every catalog paper with public
-- metadata. Measured on staging (2026-10-24, the owner's 70 library papers, 8,175 window papers): a candidate's cosine
-- similarity to its nearest library paper is the clearest relevance signal For you has (≥ 0.90 reads as "like this
-- paper"), but 0154's candidates, chosen by shared generic area tags, held only 11 of the 232 window papers at ≥ 0.90.
--
-- Additive: supersedes public.worker_feed_candidates_v2 (same signature; 0154's result plus new fields). When the
-- interest index may serve the reader (app_private.interest_serves: interest_policy.serving 'all', or 'staff' and the
-- account has an app role; the rule the interest-index Edge function applies) and their library has fingerprints:
--
-- - A "similar" candidate tier (≤ 140): each library paper (≤ 300, non-pending, never an upload) picks its 3 nearest
--   mid-level map nodes by centroid; window papers in those nodes are scored only against the library papers that
--   picked their node; the best 140 at ≥ 0.86 (a little extra for Hugging Face upvotes) join the candidates. On
--   staging this finds 224 of the 231 papers at ≥ 0.90 for about 28 thousand vector comparisons instead of 572
--   thousand. The other tiers shrink so the set stays ≤ 400 (topic/author 150, category 50, newest 30, popular 30).
-- - Every candidate carries `similarity` (cosine to its nearest library paper, 4 decimals) and `similar_to`
--   ({source_id, title} of that library paper): ≤ 400 candidates × ≤ 300 library vectors, exact.
-- - Not served, or no library fingerprints: the fields are null and the tiers keep 0154's sizes (250/100/50/30), so
--   ranking falls back to the topic/author/category heuristic. No published map: no similar tier and 0154's sizes,
--   but candidates are still scored.
--
-- Also for every reader: `author_counts`, how many window papers carry each of the profile's author keys (so ranking can
-- tell a rare name from a common one, "Yu Wang"), and the profile is read once (it was read twice).
-- Nothing is stored: similarity is computed per request from the reader's own library membership, which For you already
-- reads, and public fingerprints.
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
  lib as materialized (select * from unnest(lib_ids,lib_titles,lib_fps) with ordinality l(source_id,title,f,n) where sim_on),
  -- Each library paper's 3 nearest mid-level map nodes; a window paper is compared only with the library papers that
  -- picked its node.
  lib_mids as materialized (
   select lib.n,m.node_id mid from lib cross join lateral (
    select nv.node_id from app_private.interest_node_versions nv where nv.version=mapv and nv.level=2
    order by nv.centroid operator(extensions.<=>) lib.f limit 3) m
   where mapv is not null),
  -- The window's fingerprints by interest_papers_pool (never the whole 180-day corpus); exclusions apply after.
  near_win as (
   select ip.source_id,max(1-(ip.fingerprint operator(extensions.<=>) lib.f)) sim
   from app_private.interest_papers ip
   join app_private.interest_node_versions lf on lf.version=mapv and lf.node_id=ip.leaf_id
   join lib_mids lm on lm.mid=lf.parent_id
   join lib on lib.n=lm.n
   where ip.pool_announced_on>=since and ip.state='embedded' and ip.model_version=imodel and ip.leaf_map_version=mapv
   group by ip.source_id),
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
