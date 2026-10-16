// Authenticated paper search for the Library's "ML paper search" segment (clients that don't search for
// themselves) and the Feed. Our servers never contact arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md): search and
// chips outside the pool read DataCite, which holds arXiv's records (CC0).
//   ?q=…            DataCite, ordered by paper-search.ts as the browser orders it
//   ?category=X     a Feed chip: from the shared pool when the feed switch serves this reader
//                   (migrations 043/046, with topics and upvotes), else the category's newest papers of the last
//                   week from DataCite
//   ?feed=for_you   For you (docs/architecture/PERSONALIZED_FEED.md): the reader's ranked pool, and
//                   `feed.topics`, the reader's specific topic chips (feed-interests.ts)
//   ?feed=topic&topic=NAME  one of those topics, ranked for the reader
// Feed responses carry `feed.for_you: true` when For you is offered, so the app can show the chip.
// Every result carries `topics` (specific first; keyword rules, no model) and pool-served results
// `upvotes` (Hugging Face Papers, recorded by the pool refresh; null when unknown).
import { installEgressGuard } from '../_shared/egress.ts';
import { installProviderHealth } from '../_shared/provider-health.ts';
import { cors, rpc, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { errorResponse } from '../_shared/retry-after.ts';
import { POOL_CATEGORY } from '../_shared/feed-pool.ts';
import { FEED_RANKING_VERSION, poolResultV2, rankForYou, withDetails, type CandidateSet, type PoolDetail } from '../_shared/feed-rank.ts';
import { compoundsParameter, interestTopics, resolveTopic, type TopicStats } from '../_shared/feed-interests.ts';
import { DataCiteError, dataciteGet } from '../_shared/datacite.ts';
import { dataCiteCategoryURL } from '../_shared/feed-datacite.ts';
import { parseDataCiteSearch, runSearch, SearchNotFound } from '../_shared/paper-search.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('discover');
// Provider calls are counted per hour and fail fast while a provider's breaker is open (docs/architecture/RESILIENCE.md).
installProviderHealth('discover', serviceClient);

type ServiceClient = ReturnType<typeof serviceClient>;
/** Pool abstracts and upvotes for the papers shown; null when the pool cannot answer (results keep theirs). */
async function details(service: ServiceClient, ids: string[]): Promise<PoolDetail[] | null> {
  const valid = ids.filter(id => /^\d{4}\.\d{4,5}$|^[a-z-]{2,20}(\.[A-Z]{2})?\/\d{7}$/.test(id)).slice(0, 60);
  if (!valid.length) return [];
  const { data, error } = await service.rpc('worker_feed_details', { p_source_ids: valid });
  return error || !Array.isArray(data) ? null : data as PoolDetail[];
}

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
    if (category && !POOL_CATEGORY.test(category)) throw new PublicError(400, 'invalid_category');
    // A chip from the shared pool when this reader is served; otherwise (or if the pool can't
    // answer) DataCite below, still flagging For you so the app can offer it.
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
      // A chip the pool doesn't answer: the category's newest papers of the last week from DataCite.
      let found;
      try {
        found = parseDataCiteSearch(await dataciteGet(dataCiteCategoryURL(category, new Date().toISOString().slice(0, 10)),
          { signal: AbortSignal.timeout(10_000) })).slice(0, 25);
      } catch { throw new PublicError(503, 'search_unavailable'); }
      const known = forYou ? new Map((await details(service, found.map(result => result.source_id)) ?? []).map(detail => [detail.source_id, detail.upvotes])) : null;
      const results = found.map(({ citations: _, full_abstract, abstract_truncated, ...rest }) => ({ ...rest,
        ...(fullAbstracts ? { full_abstract, abstract_truncated } : {}), ...(known ? { upvotes: known.get(rest.source_id) ?? null } : {}) }));
      return Response.json({ results, ...(forYou ? { feed: { for_you: true } } : {}) }, { headers });
    }
    // A search: DataCite's records, ordered as the browser orders them (paper-search.ts).
    let found;
    try {
      found = await runSearch('datacite', params.get('q') ?? '', async ask => {
        try { return JSON.stringify(await dataciteGet(ask.url, { signal: AbortSignal.timeout(10_000) })); }
        catch (error) { if (error instanceof DataCiteError && error.code === 'datacite_not_found') throw new SearchNotFound(); throw error; }
      });
    } catch { throw new PublicError(503, 'search_unavailable'); }
    // Older clients asked for previews only: the same fields as before.
    const results = found.map(({ full_abstract, abstract_truncated, ...rest }) => fullAbstracts ? { ...rest, full_abstract, abstract_truncated } : rest);
    return Response.json({ results }, { headers });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'search_unavailable');
    return errorResponse(failure, headers);
  }
});
