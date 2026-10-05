// Authenticated arXiv search for the Library's "arXiv" segment. Shares the
// global arXiv request pacing with the paper pipeline.
import { cors, rpc, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { arxivSearchURL, parseArxivSearch } from '../_shared/discover.ts';

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    headers = cors(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'GET') throw new PublicError(405, 'method_unavailable');
    const { accountID } = await userClient(request);
    const service = serviceClient();
    await rpc(service, 'worker_consume_request', { p_account_id: accountID, p_route: 'discover' });
    const url = arxivSearchURL(new URL(request.url).searchParams.get('q') ?? '');
    if (!url) return Response.json({ results: [] }, { headers });
    const slot = await rpc<{ reserved: boolean; wait_ms: number }>(service, 'worker_pipeline_arxiv_slot', { p_slots: 1, p_max_wait_ms: 8000 });
    if (!slot.reserved) throw new PublicError(503, 'search_busy');
    if (slot.wait_ms > 0) await new Promise(resolve => setTimeout(resolve, slot.wait_ms));
    const response = await fetch(url, { redirect: 'error', signal: AbortSignal.timeout(20_000),
      headers: { accept: 'application/atom+xml', 'user-agent': 'ScienceReader/0.1 (research paper reader)' } });
    if (!response.ok || !response.body) { void response.body?.cancel().catch(() => {}); throw new PublicError(503, 'search_unavailable'); }
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length > 2 * 1024 * 1024) throw new PublicError(503, 'search_unavailable');
    return Response.json({ results: parseArxivSearch(bytes) }, { headers });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'search_unavailable');
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
});
