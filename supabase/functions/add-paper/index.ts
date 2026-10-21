// The Add sheet's "arXiv ID, DOI or link" (functions/v1/add-paper): identifies the paper without a
// model and queues it with the caller's own import, like the app's Add and add-reference. No
// credits here. Answers within ~25 s with an outcome and, when our servers can't fetch the paper,
// the link the reader's own device can try (see _shared/add-paper.ts).
import { installEgressGuard } from '../_shared/egress.ts';
import { installProviderHealth } from '../_shared/provider-health.ts';
import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { errorResponse } from '../_shared/retry-after.ts';
import { openAlexAllowed, paperFinder } from '../_shared/find-paper.ts';
import { addPaper } from '../_shared/add-paper.ts';
import { MAX_INPUT_CHARS } from '../_shared/identify.ts';
import { edgeResolveHost } from '../_shared/edge-dns.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('add-paper');
// Provider calls are counted per hour and fail fast while a provider's breaker is open (docs/architecture/RESILIENCE.md).
installProviderHealth('add-paper', serviceClient);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BUDGET_MS = 25_000;

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  const reply = (status: number, body: unknown) => Response.json(body, { status, headers });
  try {
    headers = { ...cors(request), 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'POST') throw new PublicError(405, 'method_unavailable');
    const { accountID, user } = await userClient(request);
    const service = serviceClient();
    let body: { operation_id?: unknown; query?: unknown; capabilities?: unknown };
    try { body = await request.json(); } catch { throw new PublicError(400, 'invalid_request'); }
    const query = typeof body.query === 'string' ? body.query.trim() : '';
    if (typeof body.operation_id !== 'string' || !UUID.test(body.operation_id) || !query || [...query].length > MAX_INPUT_CHARS) {
      throw new PublicError(400, 'invalid_request');
    }
    const web = Array.isArray(body.capabilities) && body.capabilities.includes('web_import');
    // The search policy is read alongside the rate limit (one round trip, not two). OpenAlex is asked only when the
    // owner's `openalex_enabled` switch says so; it is off (migration 075), and an unreadable policy keeps it off.
    const [limited, policy] = await Promise.all([service.rpc('worker_consume_request', { p_account_id: accountID, p_route: 'add-paper' }),
      Promise.resolve(service.rpc('worker_search_policy')).then(({ data, error }) => error ? null : data, () => null)]);
    if (limited.error) throw new PublicError(limited.error.message === 'request_rate_limit' ? 429 : 503, limited.error.message === 'request_rate_limit' ? 'rate_limited' : 'service_unavailable');
    const openAlex = openAlexAllowed(policy);

    const started = Date.now();
    const budget = AbortSignal.any([request.signal, AbortSignal.timeout(BUDGET_MS)]);
    // Add is free: it never uses the paid web search (it passed the key text here, which was never called).
    const finder = paperFinder(user, undefined, fetch, { openAlex });
    const outcome = await addPaper({ fetch, resolveHost: edgeResolveHost, findPaper: finder.findPaper, importPaper: finder.importPaper, openAlex }, query, web, budget);
    // Outcomes join the reliability events (no account ids; the reader's text is never stored).
    await service.rpc('worker_record_reference_event', { p_result: outcome.status, p_route: `add_${outcome.route}`,
      p_source_id: outcome.paper?.source_id?.slice(0, 200) ?? null, p_duration_ms: Date.now() - started }).then(() => {}, () => {});
    console.log(JSON.stringify({ function: 'add-paper', event: 'add', status: outcome.status, route: outcome.route, ms: Date.now() - started }));
    return reply(200, outcome);
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return errorResponse(failure, headers);
  }
});
