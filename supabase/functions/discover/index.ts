// Authenticated arXiv search for the Library's "arXiv" segment. Shares the
// global arXiv request pacing with the paper pipeline.
import { cors, rpc, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { arxivIDListURL, arxivRecentURL, arxivSearchURLs, mergeDiscovery, exactTitleMatches, openAlexSearchURLs, orderByRanking, parseArxivRSS, parseArxivSearch,
  rankOpenAlex, type RankedWork } from '../_shared/discover.ts';

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
    const category = params.get('category');
    const recent = category ? arxivRecentURL(category) : null;
    if (category && !recent) throw new PublicError(400, 'invalid_category');
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
    if (!slot.reserved) throw new PublicError(503, 'search_busy');
    if (slot.wait_ms > 0) await new Promise(resolve => setTimeout(resolve, slot.wait_ms));
    const lists = [];
    for (const [index, url] of urls.entries()) {
      if (index > 0) await new Promise(resolve => setTimeout(resolve, slot.spacing_ms ?? 3000));
      const response = await fetch(url, { redirect: 'error', signal: AbortSignal.timeout(20_000),
        headers: { accept: recent ? 'application/rss+xml' : 'application/atom+xml', 'user-agent': 'ScienceReader/0.1 (research paper reader)' } });
      if (!response.ok || !response.body) { void response.body?.cancel().catch(() => {}); throw new PublicError(503, 'search_unavailable'); }
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (bytes.length > 6 * 1024 * 1024) throw new PublicError(503, 'search_unavailable');
      lists.push(recent ? parseArxivRSS(bytes) : parseArxivSearch(bytes));
    }
    if (ranking.length) {
      lists[lists.length - 1] = orderByRanking(lists[lists.length - 1], ranking, query);
      if (lists.length > 1) lists[0] = exactTitleMatches(lists[0], query);
    }
    return Response.json({ results: mergeDiscovery(lists) }, { headers });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'search_unavailable');
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
});
