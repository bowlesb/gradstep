import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError, sha256 } from '../_shared/http.ts';
import { createAnthropicClient, streamChat } from '../_shared/anthropic.ts';
import { MAX_PAPER_BYTES, readChatBody, RpcFailure, runChat, sseFrame, type ChatDependencies } from '../_shared/chat.ts';
import { paperFinder } from '../_shared/find-paper.ts';
import { type SearchFailure } from '../_shared/tavily.ts';
import { admittedAnthropic, admittedTavily } from '../_shared/provider-spending.ts';

type Runtime = { waitUntil(promise: Promise<unknown>): void };
const encoder = new TextEncoder();

// After a failure, this instance sends new answers to the backup for a while.
let tavilyPausedUntil = 0;
const PAUSE_MS: Record<SearchFailure, number> = { limit: 6 * 3600_000, unauthorized: 3600_000, rate_limited: 60_000, unavailable: 120_000, rejected: 0 };

// Streams one metered answer as text/event-stream. Authentication, origin and
// method failures are HTTP JSON errors; everything after authentication is an
// SSE `error` event. Plaintext prompts and answers are never logged or stored.
Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  let accountID: string, body: unknown, service: ReturnType<typeof serviceClient>, user: Awaited<ReturnType<typeof userClient>>['user'];
  try {
    headers = cors(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'POST') throw new PublicError(405, 'method_unavailable');
    ({ accountID, user } = await userClient(request));
    service = serviceClient();
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
  // An unreadable body is reported as invalid_request after rate limiting.
  try { body = await readChatBody(request); } catch { body = null; }

  const apiKey = Deno.env.get('ANTHROPIC_API_KEY'), tavilyKey = Deno.env.get('TAVILY_API_KEY');
  const client = apiKey ? createAnthropicClient({ apiKey }) : null;
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
  const spending = { accountID, operationID: typeof rawID === 'string' ? rawID.toLowerCase() : '', rpc, sha256Hex: sha256, log };
  const providerPolicy = await rpc('worker_provider_spending_policy', {}).catch(() => null) as { tavily_enabled?: boolean; native_search_enabled?: boolean } | null;
  const search = tavilyKey ? admittedTavily(spending, 'chat_search', fetch, tavilyKey) : null;
  const finder = paperFinder(service, user, tavilyKey ? admittedTavily(spending, 'ingest_lookup', fetch, tavilyKey) : undefined);
  const deps: ChatDependencies = {
    accountID,
    rpc,
    loadPaper: async (bucket, path, expectedBytes) => {
      const { data, error } = await service.storage.from(bucket).download(path);
      if (error || !data || data.size > MAX_PAPER_BYTES || (expectedBytes !== undefined && data.size !== expectedBytes)) return null;
      return new Uint8Array(await data.arrayBuffer());
    },
    generate: client ? admittedAnthropic(spending, (params, options) => streamChat(client, params, options)) : null,
    sha256Hex: sha256,
    webSearch: Deno.env.get('CHAT_WEB_SEARCH') === 'on',
    // RPC readiness cannot stand in for an enforceable native-search quote.
    // The adapter independently refuses native search until that work exists.
    nativeSearch: false,
    search: search ? {
      ready: async () => {
        // This local pause is advisory. The transactional grant is the sole
        // authority for provider allowance, account limits and platform pause.
        return providerPolicy?.tavily_enabled === true && Date.now() >= tavilyPausedUntil;
      },
      run: async (input, signal) => {
        const outcome = await search(input, signal);
        if (outcome.status === 'failed') tavilyPausedUntil = Math.max(tavilyPausedUntil, Date.now() + (outcome.retryAfterMs ?? PAUSE_MS[outcome.failure]));
        return outcome;
      },
    } : undefined,
    availableCredits: async () => {
      const { data, error } = await user.rpc('v1_credit_balance');
      return error || typeof data?.available !== 'number' ? null : data.available;
    },
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
