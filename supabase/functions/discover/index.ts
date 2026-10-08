// Authenticated arXiv search for the Library's "arXiv" segment and the Feed. Shares the
// global arXiv request pacing with the paper pipeline.
//   ?q=…            arXiv search (OpenAlex ranking, arXiv metadata)
//   ?category=X     a Feed chip: from the shared pool when the feed switch serves this reader
//                   (migration 043), else arXiv's live RSS as before
//   ?feed=for_you   For you (docs/architecture/PERSONALIZED_FEED.md): the reader's ranked pool
// Feed responses carry `feed.for_you: true` when For you is offered, so the app can show the chip.
import { cors, rpc, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { arxivIDListURL, arxivRecentURL, arxivSearchURLs, exactTitleMatches, mergeDiscovery, openAlexArxivWorkURL, openAlexResult, openAlexSearchURLs,
  orderByRanking, parseArxivRSS, parseArxivSearch, rankOpenAlex, type DiscoveryResult, type RankedWork } from '../_shared/discover.ts';
import { FEED_RANKING_VERSION, poolResult, rankForYou, type CandidateSet } from '../_shared/feed-rank.ts';

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
    const feed = params.get('feed');
    if (feed !== null) {
      if (feed !== 'for_you' || params.has('category') || params.has('q')) throw new PublicError(400, 'invalid_feed');
      const { data, error } = await service.rpc('worker_feed_candidates', { p_account_id: accountID });
      if (error) throw new PublicError(error.message === 'feed_unavailable' ? 404 : 503, error.message === 'feed_unavailable' ? 'feed_unavailable' : 'service_unavailable');
      const set = data as CandidateSet;
      const ranked = rankForYou(set);
      return Response.json({ results: ranked.results, feed: { for_you: true, ranking: FEED_RANKING_VERSION, cold_start: ranked.cold_start,
        refreshed_at: set.refreshed_at, pool: set.pool } }, { headers });
    }
    const category = params.get('category');
    const recent = category ? arxivRecentURL(category) : null;
    if (category && !recent) throw new PublicError(400, 'invalid_category');
    // A chip from the shared pool when this reader is served; otherwise (or if the pool can't
    // answer) the live RSS below, still flagging For you so the app can offer it.
    let forYou = false;
    if (category) {
      const { data, error } = await service.rpc('worker_feed_category', { p_account_id: accountID, p_category: category, p_limit: 25 });
      const pooled = error ? null : data as { serving?: boolean; results?: Parameters<typeof poolResult>[0][] | null; refreshed_at?: string | null } | null;
      forYou = pooled?.serving === true;
      if (forYou && Array.isArray(pooled?.results)) {
        return Response.json({ results: pooled.results.map(poolResult), feed: { for_you: true, refreshed_at: pooled.refreshed_at ?? null } }, { headers });
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
        return JSON.parse(new TextDecoder().decode(new Uint8Array(await response.arrayBuffer()).subarray(0, 4 * 1024 * 1024)));
      };
      const [relevant, cited] = await Promise.allSettled(openAlex.map(fetchJSON));
      try { if (relevant.status === 'fulfilled') ranking = rankOpenAlex(relevant.value, cited.status === 'fulfilled' ? cited.value : undefined); }
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
        const bytes = new Uint8Array(await response.arrayBuffer());
        if (bytes.length > 6 * 1024 * 1024) throw new Error('arxiv_too_large');
        lists.push(recent ? parseArxivRSS(bytes) : parseArxivSearch(bytes));
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
          const work = response.ok ? openAlexResult(await response.json()) : null;
          lists[last] = work && work.source_id === id ? [work] : null;
        } catch { lists[last] = null; }
      }
    }
    if (lists.every(list => list === null)) throw new PublicError(503, 'search_unavailable');
    return Response.json({ results: mergeDiscovery(lists.filter((list): list is DiscoveryResult[] => !!list)),
      ...(forYou ? { feed: { for_you: true } } : {}) }, { headers });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'search_unavailable');
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
});
