import { installEgressGuard } from '../_shared/egress.ts';
import { accountProviderFetch, installProviderHealth } from '../_shared/provider-health.ts';
import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError, sha256 } from '../_shared/http.ts';
import { errorResponse } from '../_shared/retry-after.ts';
import { retryOnceWhenBusy } from '../_shared/inference.ts';
import { MAX_PAPER_BYTES, readChatBody, RpcFailure, runChat, sseFrame, type AiSwitches, type ChatDependencies } from '../_shared/chat.ts';
import { openAlexAllowed, paperFinder } from '../_shared/find-paper.ts';
import { type SearchFailure } from '../_shared/tavily.ts';
import { admittedModelCalls, admittedTavily } from '../_shared/provider-spending.ts';
import { publishedProfiles } from '../_shared/chat-profiles.ts';
import { withCheapDefaults } from '../_shared/ai-switches.ts';
import { openRouterChat } from '../_shared/openrouter-chat.ts';
import { ACCEPT_MARGIN_MS, PUBLISH_MARGIN_MS, tariffOpen, tariffValidity } from '../_shared/openrouter-tariffs.ts';

// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('chat');
// Provider calls are counted per hour and fail fast while a provider's breaker is open (docs/architecture/RESILIENCE.md).
installProviderHealth('chat', serviceClient);

type Runtime = { waitUntil(promise: Promise<unknown>): void };
/** The spending policy (Tavily allowance, OpenRouter card validity), or null when it cannot be read. Never throws. */
const spendingPolicy = (service: ReturnType<typeof serviceClient>): Promise<unknown> => Promise.resolve(service.rpc('worker_provider_spending_policy', {}))
  .then(({ data, error }) => error ? null : data, () => null);
/** The owner's AI switches (migration 0150; RUNBOOK_SPENDING.md), or null when they cannot be read. Never throws. */
const aiSwitches = (service: ReturnType<typeof serviceClient>): Promise<AiSwitches | null> => Promise.resolve(service.rpc('worker_ai_switches', {}))
  .then(({ data, error }) => error || !data || typeof data !== 'object' ? null : data as AiSwitches, () => null);
const encoder = new TextEncoder();

// After a failure, this instance answers without web search for a while.
let tavilyPausedUntil = 0;
// DeepSeek in chat (docs/architecture/CHAT.md "DeepSeek in chat"): `on` publishes and accepts it, `hidden` accepts it
// without publishing it (the recorded quality check before it is offered), anything else turns it off. Needs its key.
const openrouterKey = Deno.env.get('OPENROUTER_CHAT_API_KEY');
const deepseekMode = Deno.env.get('CHAT_DEEPSEEK') ?? 'off';
const deepseekAccepted = !!openrouterKey && (deepseekMode === 'on' || deepseekMode === 'hidden');
const deepseekPublished = !!openrouterKey && deepseekMode === 'on';
const geminiMode = Deno.env.get('CHAT_GEMINI') ?? 'off';
// Each model's price-card validity is app_private.openrouter_tariffs (A4, migration 0101), read per request below.
const geminiAccepted = !!openrouterKey && ['on', 'hidden'].includes(geminiMode);
// OpenRouter is the only inference provider (owner, 2026-10-18 and 2026-10-21): every model below is sent through it.
const geminiPublished = geminiAccepted && geminiMode === 'on';
const PAUSE_MS: Record<SearchFailure, number> = { limit: 6 * 3600_000, unauthorized: 3600_000, rate_limited: 60_000, unavailable: 120_000, rejected: 0 };

// Streams one metered answer as text/event-stream. Authentication, origin and
// method failures are HTTP JSON errors; everything after authentication is an
// SSE `error` event. Plaintext prompts and answers are never logged or stored.
// GET returns the versioned chat profile table (models, effort, length, credit
// estimates) that clients display; it calls nothing and changes nothing.
Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  let accountID: string, body: unknown, service: ReturnType<typeof serviceClient>, user: Awaited<ReturnType<typeof userClient>>['user'];
  try {
    headers = cors(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'POST' && request.method !== 'GET') throw new PublicError(405, 'method_unavailable');
    ({ accountID, user } = await userClient(request));
    if (request.method === 'GET') {
      // A4: a model whose price card lapses within a day is not offered (clients keep the table for a while). An
      // unreadable table leaves the list as it is; admission still refuses a lapsed card.
      const [policy, switches] = await Promise.all([spendingPolicy(serviceClient()), aiSwitches(serviceClient())]);
      const validity = tariffValidity(policy);
      const table = publishedProfiles({ deepseek: deepseekPublished && new URL(request.url).searchParams.get('consent_version') === 'cloud-ai-v6',
        gemini: geminiPublished, available: model => tariffOpen(validity, model, PUBLISH_MARGIN_MS) });
      // "Cheaper models only" (the owner's switch): every published default becomes Gemini Flash; premium requests are refused.
      return Response.json(switches?.cheap_models_only === true ? withCheapDefaults(table) : table, { headers });
    }
    service = serviceClient();
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return errorResponse(failure, headers);
  }
  // Started before the body is read and awaited only when search is decided (time to first text).
  const providerPolicy = spendingPolicy(service) as Promise<{ tavily_enabled?: boolean; openrouter_tariffs?: unknown } | null>;
  const switches = aiSwitches(service);
  // One balance read serves the hold cap and the free-credit check.
  let balanceRead: Promise<{ available?: unknown; free?: { usable?: unknown; available?: unknown } | null } | null> | null = null;
  const balance = () => balanceRead ??= Promise.resolve(user.rpc('v1_credit_balance')).then(({ data, error }) => error ? null : data, () => null);
  // An unreadable body is reported as invalid_request after rate limiting.
  try { body = await readChatBody(request); } catch { body = null; }

  const tavilyKey = Deno.env.get('TAVILY_API_KEY');
  // This account's provider calls: counted, failed fast while a breaker is open, and reachable by a fault drill only
  // when the account is a test account (docs/architecture/RESILIENCE.md).
  const providerFetch = accountProviderFetch('chat', () => accountID, () => service);
  const router = openrouterKey ? openRouterChat({ apiKey: openrouterKey, fetch: providerFetch }) : null;
  const rpc: ChatDependencies['rpc'] = async (name, params) => {
    const { data, error } = await service.rpc(name, params);
    // A database exception carries a SQLSTATE; a fetch failure does not and
    // stays ambiguous (the call may have committed).
    if (error) throw error.code ? new RpcFailure(error.message) : new Error('transport');
    return data;
  };
  const log: ChatDependencies['log'] = entry => console.warn(JSON.stringify({ function: 'chat', ...entry }));
  // Validation in runChat precedes every provider call. Keep the canonical UUID
  // here so case differences cannot create a second attempt namespace.
  const rawID = body && typeof body === 'object' ? (body as { operation_id?: unknown }).operation_id : null;
  const feature = body && typeof body === 'object' && typeof (body as { action?: unknown }).action === 'string'
    ? (body as { action: string }).action : 'chat';
  const spending = { accountID, feature, operationID: typeof rawID === 'string' ? rawID.toLowerCase() : '', rpc, sha256Hex: sha256, log };
  const search = tavilyKey ? admittedTavily(spending, 'chat_search', providerFetch, tavilyKey) : null;
  // Ingest asks OpenAlex only while the owner's `openalex_enabled` switch is on (off since migration 075): the policy is
  // read lazily, only when an Ingest looks a title up, and an unreadable policy keeps OpenAlex off.
  // An Ingest's import is named after this chat operation (migration 120), so it can never be queued twice.
  const finder = paperFinder(user, tavilyKey ? admittedTavily(spending, 'ingest_lookup', providerFetch, tavilyKey) : undefined, fetch, {
    requestID: spending.operationID, openAlex: () => Promise.resolve(service.rpc('worker_search_policy')).then(({ data, error }) => !error && openAlexAllowed(data), () => false) });
  const deps: ChatDependencies = {
    accountID,
    rpc,
    loadPaper: async (bucket, path, expectedBytes) => {
      const { data, error } = await service.storage.from(bucket).download(path);
      if (error || !data || data.size > MAX_PAPER_BYTES || (expectedBytes !== undefined && data.size !== expectedBytes)) return null;
      return new Uint8Array(await data.arrayBuffer());
    },
    // One more try, inside the same answer, when the provider refused it as busy before starting (fix 7).
    generate: router ? retryOnceWhenBusy(admittedModelCalls(spending, router), { log }) : null,
    deepseek: deepseekAccepted,
    gemini: geminiAccepted,
    // A4: refused as model_unavailable before any hold when the card lapses within the answer's time.
    modelAvailable: async model => tariffOpen(tariffValidity(await providerPolicy), model, ACCEPT_MARGIN_MS),
    sha256Hex: sha256,
    // Web search is our search_web tool, run with Tavily (CHAT.md "Web search"); no provider-native search exists.
    webSearch: Deno.env.get('CHAT_WEB_SEARCH') === 'on',
    search: search ? {
      ready: async () => {
        // This local pause is advisory. The transactional grant is the sole
        // authority for provider allowance, account limits and platform pause.
        return (await providerPolicy)?.tavily_enabled === true && Date.now() >= tavilyPausedUntil;
      },
      run: async (input, signal) => {
        const outcome = await search(input, signal);
        if (outcome.status === 'failed') tavilyPausedUntil = Math.max(tavilyPausedUntil, Date.now() + (outcome.retryAfterMs ?? PAUSE_MS[outcome.failure]));
        return outcome;
      },
    } : undefined,
    availableCredits: async () => {
      const data = await balance();
      return typeof data?.available !== 'number' ? null : data.available;
    },
    // Free credits that can pay now (migration 0150): the same balance read.
    freeCredits: async () => {
      const free = (await balance())?.free;
      return !!free && free.usable === true && typeof free.available === 'number' && free.available > 0;
    },
    aiSwitches: () => switches,
    findPaper: finder.findPaper,
    importPaper: finder.importPaper,
    log,
  };

  const gone = new AbortController();
  request.signal.addEventListener('abort', () => gone.abort(), { once: true });
  let sink: ReadableStreamDefaultController<Uint8Array> | undefined;
  const write = (frame: string) => {
    if (gone.signal.aborted || !sink) return;
    try { sink.enqueue(encoder.encode(frame)); } catch { gone.abort(); }
  };
  const stream = new ReadableStream<Uint8Array>({
    start(controller) { sink = controller; controller.enqueue(encoder.encode(': open\n\n')); },
    cancel() { gone.abort(); },
  });
  // Keep intermediaries from treating thinking time as an idle connection.
  const ping = setInterval(() => write(': ping\n\n'), 15_000);
  const work = runChat(deps, body, event => write(sseFrame(event)), gone.signal)
    .catch(() => deps.log({ event: 'chat_unexpected_failure' }))
    .finally(() => { clearInterval(ping); try { sink?.close(); } catch { /* already closed */ } });
  // Settlement must finish even after the client disconnects.
  (globalThis as { EdgeRuntime?: Runtime }).EdgeRuntime?.waitUntil(work);
  return new Response(stream, {
    headers: { ...headers, 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no' },
  });
});
