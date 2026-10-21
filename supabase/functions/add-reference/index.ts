// Direct "Add to library" on a bibliography entry: identifies the cited paper without a model
// (arXiv id, DOI, Crossref's citation matcher; OpenAlex only while its switch is on) and queues it with the caller's own
// import, like the app's Add. No credits. Answers within ~25 s with a plain outcome the app shows.
import { installEgressGuard } from '../_shared/egress.ts';
import { installProviderHealth } from '../_shared/provider-health.ts';
import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError, sha256 } from '../_shared/http.ts';
import { errorResponse } from '../_shared/retry-after.ts';
import { openAlexAllowed, paperFinder } from '../_shared/find-paper.ts';
import { MAX_REFERENCE_CHARS, resolveReference } from '../_shared/reference.ts';
import { RpcFailure } from '../_shared/chat.ts';
import { referenceLookupSpending } from '../_shared/provider-spending.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('add-reference');
// Provider calls are counted per hour and fail fast while a provider's breaker is open (docs/architecture/RESILIENCE.md).
installProviderHealth('add-reference', serviceClient);

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
    let body: { operation_id?: unknown; reference?: unknown; capabilities?: unknown; consent_version?: unknown };
    try { body = await request.json(); } catch { throw new PublicError(400, 'invalid_request'); }
    const reference = typeof body.reference === 'string' ? body.reference.replace(/\s+/g, ' ').trim() : '';
    if (typeof body.operation_id !== 'string' || !UUID.test(body.operation_id) || reference.length < 8 || [...reference].length > MAX_REFERENCE_CHARS) {
      throw new PublicError(400, 'invalid_request');
    }
    const web = Array.isArray(body.capabilities) && body.capabilities.includes('web_import');
    // The search policy is read alongside the rate limit. OpenAlex is off (migration 075); unreadable keeps it off.
    const [limited, policy] = await Promise.all([service.rpc('worker_consume_request', { p_account_id: accountID, p_route: 'add-reference' }),
      Promise.resolve(service.rpc('worker_search_policy')).then(({ data, error }) => error ? null : data, () => null)]);
    const openAlex = openAlexAllowed(policy);
    if (limited.error) throw new PublicError(limited.error.message === 'request_rate_limit' ? 429 : 503, limited.error.message === 'request_rate_limit' ? 'rate_limited' : 'service_unavailable');

    const started = Date.now();
    const budget = AbortSignal.any([request.signal, AbortSignal.timeout(BUDGET_MS)]);
    const operationID = body.operation_id.toLowerCase();
    const rpc = async (name: string, params: Record<string, unknown>) => {
      const { data, error } = await service.rpc(name, params);
      if (error) throw error.code ? new RpcFailure(error.message) : new Error('transport');
      return data;
    };
    // Old builds never consented to send citation text to Tavily. They retain
    // the free catalog lookup. An explicit new consent is necessary, not a key.
    const spending = await referenceLookupSpending({ accountID, operationID, rpc, sha256Hex: sha256 }, {
      reference, web, consentVersion: body.consent_version, enabled: Deno.env.get('CHAT_WEB_SEARCH') === 'on',
      apiKey: Deno.env.get('TAVILY_API_KEY'), fetcher: fetch,
    });
    const finder = paperFinder(user, spending.search, fetch, { openAlex, requestID: operationID });
    const { result, route } = await resolveReference({ fetch, openAlex,
      findPaper: (wanted, signal, options) => finder.findPaper(wanted, signal, { ...options, tavily: !!spending.search }) }, reference, web, budget)
      .catch(() => ({ result: { status: 'unavailable' as const }, route: 'none' as const }))
      .finally(spending.finish);
    let status: string = result.status;
    const paper = 'paper' in result ? result.paper : null;
    if (result.status === 'found' && paper) status = budget.aborted ? 'unavailable' : await finder.importPaper(paper, budget).catch(() => 'failed' as const);
    await service.rpc('worker_record_reference_event', { p_result: status, p_route: route, p_source_id: paper?.source_id?.slice(0, 200) ?? null,
      p_duration_ms: Date.now() - started }).then(() => {}, () => {});
    console.log(JSON.stringify({ function: 'add-reference', event: 'reference', status, route, ms: Date.now() - started }));
    return reply(200, { status, route, paper: paper ? { title: paper.title, year: paper.year, source_id: paper.source_id,
      kind: paper.kind ?? 'arxiv', host: paper.host ?? null, link: paper.link ?? null } : null });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return errorResponse(failure, headers);
  }
});
