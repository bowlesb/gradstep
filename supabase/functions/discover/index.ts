// Authenticated arXiv search for the Library's "arXiv" segment and the Feed. Shares the
// global arXiv request pacing with the paper pipeline.
//   ?q=…            arXiv search (OpenAlex ranking, arXiv metadata)
//   ?category=X     a Feed chip: from the shared pool when the feed switch serves this reader
//                   (migrations 043/046, with topics and upvotes), else arXiv's live RSS as before
//   ?feed=for_you   For you (docs/architecture/PERSONALIZED_FEED.md): the reader's ranked pool, and
//                   `feed.topics`, the reader's specific topic chips (feed-interests.ts)
//   ?feed=topic&topic=NAME  one of those topics, ranked for the reader
// Feed responses carry `feed.for_you: true` when For you is offered, so the app can show the chip.
// Every result carries `topics` (specific first; keyword rules, no model) and pool-served results
// `upvotes` (Hugging Face Papers, recorded by the pool refresh; null when unknown).
import { installEgressGuard } from '../_shared/egress.ts';
import { cors, rpc, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { readBounded } from '../_shared/feed-pool.ts';
import { arxivIDListURL, arxivRecentURL, arxivSearchURLs, exactTitleMatches, mergeDiscovery, openAlexArxivWorkURL, openAlexResult, openAlexSearchURLs,
  orderByRanking, parseArxivRSS, parseArxivSearch, rankOpenAlex, type DiscoveryResult, type RankedWork } from '../_shared/discover.ts';
import { FEED_RANKING_VERSION, poolResultV2, rankForYou, withDetails, type CandidateSet, type PoolDetail } from '../_shared/feed-rank.ts';
import { compoundsParameter, interestTopics, resolveTopic, type TopicStats } from '../_shared/feed-interests.ts';
import { displayTopics, feedTopics } from '../_shared/feed-topics.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); EGRESS_ARXIV sets report or block.
installEgressGuard('discover');

type ServiceClient = ReturnType<typeof serviceClient>;
/** Pool abstracts and upvotes for the papers shown; null when the pool cannot answer (results keep theirs). */
async function details(service: ServiceClient, ids: string[]): Promise<PoolDetail[] | null> {
  const valid = ids.filter(id => /^\d{4}\.\d{4,5}$|^[a-z-]{2,20}(\.[A-Z]{2})?\/\d{7}$/.test(id)).slice(0, 60);
  if (!valid.length) return [];
  const { data, error } = await service.rpc('worker_feed_details', { p_source_ids: valid });
  return error || !Array.isArray(data) ? null : data as PoolDetail[];
}
/** Specific topics for a result that did not come from the pool (live RSS, search). */
const withTopics = (result: DiscoveryResult) =>
  ({ ...result, topics: displayTopics(feedTopics(result.title, result.full_abstract ?? result.abstract, result.categories)) });

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    headers = cors(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'GET') throw new PublicError(405, 'method_unavailable');
    const { accountID } = await userClient(request);
    const service = serviceClient();
    await rpc(service, 'worker_consume_request', { p_account_id: accountID, p_route: 'discover' });
    const params = new URL(request.url).searchParams;
    const fullAbstracts = params.get('abstract') === 'full';
    if (params.has('abstract') && !fullAbstracts) throw new PublicError(400, 'invalid_request');
    const feed = params.get('feed');
    if (feed !== null) {
      const topicName = params.get('topic');
      if ((feed !== 'for_you' && feed !== 'topic') || (feed === 'topic') !== (topicName !== null) || params.has('category') || params.has('q')) {
        throw new PublicError(400, 'invalid_feed');
      }
      const topic = topicName === null ? null : resolveTopic(topicName);
      if (topicName !== null && !topic) throw new PublicError(400, 'invalid_feed_topic');
      const args = !topic ? { p_account_id: accountID, p_compounds: compoundsParameter() }
        : topic.kind === 'own' ? { p_account_id: accountID, p_phrase: topic.phrase }
        : { p_account_id: accountID, p_all: topic.all, p_any: topic.any.length ? topic.any : null };
      const { data, error } = await service.rpc('worker_feed_candidates_v2', args);
      if (error) {
        if (error.message === 'feed_unavailable') throw new PublicError(404, 'feed_unavailable');
        if (error.message === 'invalid_feed_topic') throw new PublicError(400, 'invalid_feed_topic');
        throw new PublicError(503, 'service_unavailable');
      }
      const set = data as CandidateSet & { topics?: TopicStats | null };
      const ranked = rankForYou(set, { topic: topic?.name ?? null });
      const results = withDetails(ranked.results, await details(service, ranked.results.map(result => result.source_id)));
      return Response.json({ results, feed: { for_you: true, ranking: FEED_RANKING_VERSION, cold_start: ranked.cold_start,
        refreshed_at: set.refreshed_at, pool: set.pool,
        ...(topic ? { topic: { name: topic.name, kind: topic.kind } } : { topics: interestTopics(set, set.topics) }) } }, { headers });
    }
    const category = params.get('category');
    const recent = category ? arxivRecentURL(category) : null;
    if (category && !recent) throw new PublicError(400, 'invalid_category');
    // A chip from the shared pool when this reader is served; otherwise (or if the pool can't
    // answer) the live RSS below, still flagging For you so the app can offer it.
    let forYou = false;
    if (category) {
      const { data, error } = await service.rpc('worker_feed_category_v2', { p_account_id: accountID, p_category: category, p_limit: 25 });
      const pooled = error ? null : data as { serving?: boolean; results?: Parameters<typeof poolResultV2>[0][] | null; refreshed_at?: string | null } | null;
      forYou = pooled?.serving === true;
      // The pool keeps abstracts up to 2,000 characters (arXiv allows 1,920): one it had to shorten is
      // marked incomplete, and the app links to arXiv for the rest.
      if (forYou && Array.isArray(pooled?.results)) {
        return Response.json({ results: pooled.results.map(row => poolResultV2(row, fullAbstracts)),
          feed: { for_you: true, refreshed_at: pooled.refreshed_at ?? null } }, { headers });
      }
    }
    const query = params.get('q') ?? '';
    let urls = recent ? [recent] : arxivSearchURLs(query);
    if (!urls.length) return Response.json({ results: [] }, { headers });
    // Topic queries are ranked with OpenAlex (relevance and citations); arXiv then
    // supplies metadata for those IDs. If OpenAlex fails, arXiv's own search.
    let ranking: RankedWork[] = [];
    const openAlex = recent ? [] : openAlexSearchURLs(query);
    if (openAlex.length) {
      const fetchJSON = async (url: string) => {
        const response = await fetch(url, { redirect: 'error', signal: AbortSignal.timeout(10_000),
          headers: { accept: 'application/json', 'user-agent': 'ScienceReader/0.1 (research paper reader)' } });
        if (!response.ok) { void response.body?.cancel().catch(() => {}); throw new Error('openalex_unavailable'); }
        return JSON.parse(new TextDecoder().decode(await readBounded(response, 4 * 1024 * 1024)));
      };
      const [relevant, cited] = await Promise.allSettled(openAlex.map(fetchJSON));
      try { if (relevant.status === 'fulfilled') ranking = rankOpenAlex(relevant.value, cited.status === 'fulfilled' ? cited.value : undefined, 25, fullAbstracts); }
      catch { ranking = []; }
      const ids = arxivIDListURL(ranking.map(r => r.sourceID));
      // Keep the exact-title lookup (if any) first; replace arXiv's word search with the ranked IDs.
      if (ids) urls = [...urls.slice(0, urls.length - 1), ids];
    }
    const slot = await rpc<{ reserved: boolean; wait_ms: number; spacing_ms?: number }>(service, 'worker_pipeline_arxiv_slot', { p_slots: urls.length, p_max_wait_ms: 8000 });
    if (!slot.reserved) {
      // arXiv's pacing is taken (imports use it too): OpenAlex's ranked results alone.
      const ranked = orderByRanking(ranking.map(r => r.result).filter((r): r is DiscoveryResult => !!r), ranking, query);
      if (ranked.length) return Response.json({ results: mergeDiscovery([ranked]) }, { headers });
      throw new PublicError(503, 'search_busy');
    }
    if (slot.wait_ms > 0) await new Promise(resolve => setTimeout(resolve, slot.wait_ms));
    // arXiv's API throttles intermittently (429): each call may fail on its own.
    const lists: (DiscoveryResult[] | null)[] = [];
    for (const [index, url] of urls.entries()) {
      if (index > 0) await new Promise(resolve => setTimeout(resolve, slot.spacing_ms ?? 3000));
      try {
        const response = await fetch(url, { redirect: 'error', signal: AbortSignal.timeout(15_000),
          headers: { accept: recent ? 'application/rss+xml' : 'application/atom+xml', 'user-agent': 'ScienceReader/0.1 (research paper reader)' } });
        if (!response.ok || !response.body) { void response.body?.cancel().catch(() => {}); throw new Error(`arxiv_${response.status}`); }
        const bytes = await readBounded(response, recent ? 4 * 1024 * 1024 : 1024 * 1024);
        lists.push(recent ? parseArxivRSS(bytes, 25, fullAbstracts) : parseArxivSearch(bytes, fullAbstracts));
      } catch (error) {
        console.log(JSON.stringify({ function: 'discover', event: 'arxiv_failed', code: error instanceof Error ? error.message.slice(0, 40) : 'unknown' }));
        lists.push(null);
      }
    }
    const last = lists.length - 1;
    if (ranking.length) {
      // The ranked list: arXiv's metadata in OpenAlex's order, or OpenAlex's own metadata if arXiv failed.
      lists[last] = lists[last] ? orderByRanking(lists[last]!, ranking, query)
        : orderByRanking(ranking.map(r => r.result).filter((r): r is DiscoveryResult => !!r), ranking, query);
      if (last > 0) lists[0] = lists[0] ? exactTitleMatches(lists[0]!, query) : [];
    } else if (lists[last] === null && !recent && !openAlex.length) {
      // An arXiv ID lookup: OpenAlex's record of that paper.
      const id = new URL(urls[last]).searchParams.get('id_list')?.replace(/v\d+$/, '');
      if (id) {
        try {
          const response = await fetch(openAlexArxivWorkURL(id), { redirect: 'error', signal: AbortSignal.timeout(10_000), headers: { accept: 'application/json' } });
          const work = response.ok ? openAlexResult(JSON.parse(new TextDecoder().decode(await readBounded(response, 4 * 1024 * 1024))), fullAbstracts) : null;
          if (!response.ok) void response.body?.cancel().catch(() => {});
          lists[last] = work && work.source_id === id ? [work] : null;
        } catch { lists[last] = null; }
      }
    }
    if (lists.every(list => list === null)) throw new PublicError(503, 'search_unavailable');
    let results: (DiscoveryResult & { topics: string[]; upvotes?: number | null })[] =
      mergeDiscovery(lists.filter((list): list is DiscoveryResult[] => !!list)).map(withTopics);
    if (recent && forYou) {
      // Live RSS for a served reader (a category outside the pool, or a stale pool): known upvotes.
      const known = new Map((await details(service, results.map(result => result.source_id)) ?? []).map(detail => [detail.source_id, detail.upvotes]));
      results = results.map(result => ({ ...result, upvotes: known.get(result.source_id) ?? null }));
    }
    return Response.json({ results, ...(forYou ? { feed: { for_you: true } } : {}) }, { headers });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'search_unavailable');
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
});
