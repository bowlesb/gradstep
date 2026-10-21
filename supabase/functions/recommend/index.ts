// AI recommendations (functions/v1/recommend; docs/architecture/AI_RECOMMENDATIONS.md). POST {operation_id, count: 1|3|5,
// scope: "paper"|"catalog", seeds: [{source_id, keywords}]} → text/event-stream of JSON `data:` lines (status, paper,
// done, error). A 1-credit hold, candidates from DataCite and the Feed pool (never arXiv), one admitted OpenRouter call
// (Haiku 5.5, feature `recommend`), each pick added as the reader, then the settlement. Authentication, origin, method and
// body failures are HTTP JSON errors; everything after them is a stream event. Prompts, titles and reasons are never
// logged. The work outlives the connection: a closed sheet still gets its papers added and the request settled.
import { installEgressGuard } from '../_shared/egress.ts';
import { accountProviderFetch, installProviderHealth } from '../_shared/provider-health.ts';
import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError, sha256 } from '../_shared/http.ts';
import { readRequestJSON } from '../_shared/bounded-json.ts';
import { errorResponse } from '../_shared/retry-after.ts';
import { retryOnceWhenBusy } from '../_shared/inference.ts';
import { admittedModelCalls } from '../_shared/provider-spending.ts';
import { openRouterChat } from '../_shared/openrouter-chat.ts';
import { DataCiteError, dataciteGet } from '../_shared/datacite.ts';
import { runSearch, SearchNotFound, SEARCH_RESULTS } from '../_shared/paper-search.ts';
import { parseRecommendRequest, recommendFrame, RecommendRpcFailure, runRecommend, type RecommendDeps } from '../_shared/recommend.ts';

// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('recommend');
// Provider calls are counted per hour and fail fast while a provider's breaker is open (docs/architecture/RESILIENCE.md).
installProviderHealth('recommend', serviceClient);

type Runtime = { waitUntil(promise: Promise<unknown>): void };
const encoder = new TextEncoder();
/** operation id, count, scope and up to 8 seeds with 6 keywords each. */
const MAX_BODY_BYTES = 8 * 1024;
// The chat key (or a later per-feature key): every model call goes through OpenRouter.
const openrouterKey = Deno.env.get('OPENROUTER_CHAT_API_KEY');

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  let accountID: string, user: Awaited<ReturnType<typeof userClient>>['user'], service: ReturnType<typeof serviceClient>;
  let parsed: ReturnType<typeof parseRecommendRequest>;
  try {
    headers = cors(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'POST') throw new PublicError(405, 'method_unavailable');
    ({ accountID, user } = await userClient(request));
    parsed = parseRecommendRequest(await readRequestJSON(request, MAX_BODY_BYTES));
    if (!parsed) throw new PublicError(400, 'invalid_request');
    service = serviceClient();
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return errorResponse(failure, headers);
  }
  const body = parsed;

  const rpc: RecommendDeps['rpc'] = async (name, params) => {
    const { data, error } = await service.rpc(name, params);
    // A database exception carries a SQLSTATE; a fetch failure does not and stays ambiguous (it may have committed).
    if (error) throw error.code ? new RecommendRpcFailure(error.message) : new Error('transport');
    return data;
  };
  const log: RecommendDeps['log'] = entry => console.warn(JSON.stringify({ function: 'recommend', ...entry }));
  const providerFetch = accountProviderFetch('recommend', () => accountID, () => service);
  const router = openrouterKey ? openRouterChat({ apiKey: openrouterKey, fetch: providerFetch }) : null;
  const spending = { accountID, feature: 'recommend', operationID: body.operationID, rpc, sha256Hex: sha256, log };
  const deps: RecommendDeps = {
    accountID, rpc, log, sha256Hex: sha256,
    generate: router ? retryOnceWhenBusy(admittedModelCalls(spending, router), { log }) : null,
    // The reader's own token: the library's rate limits, receipts and presence check apply as for any Add (migration 120).
    addPaper: async (importID, sourceID) => {
      const { data, error } = await user.rpc('v2_add_paper_once', { p_operation_id: importID, p_source_id: sourceID, p_web: false });
      const result = error ? null : (data as { result?: { status?: unknown; id?: unknown } } | null)?.result;
      if (result?.status === 'applied') return { status: 'added', id: typeof result.id === 'string' ? result.id : importID };
      if (result?.status === 'present') return { status: 'present', id: typeof result.id === 'string' ? result.id : null };
      return { status: 'failed', id: null };
    },
    // DataCite, ordered as every search orders it (paper-search.ts); the search words are all DataCite receives.
    search: (term, signal) => runSearch('datacite', term, async ask => {
      try { return JSON.stringify(await dataciteGet(ask.url, { signal })); }
      catch (error) { if (error instanceof DataCiteError && error.code === 'datacite_not_found') throw new SearchNotFound(); throw error; }
    }, SEARCH_RESULTS),
  };

  let sink: ReadableStreamDefaultController<Uint8Array> | undefined, open = true;
  const write = (frame: string) => {
    if (!open || !sink) return;
    try { sink.enqueue(encoder.encode(frame)); } catch { open = false; }
  };
  const stream = new ReadableStream<Uint8Array>({
    start(controller) { sink = controller; controller.enqueue(encoder.encode(': open\n\n')); },
    // The reader closed the sheet: nothing more is sent, but the request runs to its settlement.
    cancel() { open = false; },
  });
  const ping = setInterval(() => write(': ping\n\n'), 15_000);
  const work = runRecommend(deps, body, event => write(recommendFrame(event)))
    .catch(() => log({ event: 'recommend_unexpected_failure' }))
    .finally(() => { clearInterval(ping); open = false; try { sink?.close(); } catch { /* already closed */ } });
  (globalThis as { EdgeRuntime?: Runtime }).EdgeRuntime?.waitUntil(work);
  return new Response(stream, {
    headers: { ...headers, 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no' },
  });
});
