import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError, sha256 } from '../_shared/http.ts';
import { createAnthropicClient, streamChat } from '../_shared/anthropic.ts';
import { MAX_PAPER_BYTES, readChatBody, RpcFailure, runChat, sseFrame, type ChatDependencies } from '../_shared/chat.ts';
import { arxivTitleURLs, bestTitleMatch, searchArxiv, type DiscoveryResult } from '../_shared/discover.ts';

type Runtime = { waitUntil(promise: Promise<unknown>): void };
const encoder = new TextEncoder();

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

  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  const client = apiKey ? createAnthropicClient({ apiKey }) : null;
  const deps: ChatDependencies = {
    accountID,
    rpc: async (name, params) => {
      const { data, error } = await service.rpc(name, params);
      // A database exception carries a SQLSTATE; a fetch failure does not and
      // stays ambiguous (the call may have committed).
      if (error) throw error.code ? new RpcFailure(error.message) : new Error('transport');
      return data;
    },
    loadPaper: async (bucket, path) => {
      const { data, error } = await service.storage.from(bucket).download(path);
      if (error || !data || data.size > MAX_PAPER_BYTES) return null;
      return new Uint8Array(await data.arrayBuffer());
    },
    generate: client ? (params, options) => streamChat(client, params, options) : null,
    sha256Hex: sha256,
    findPaper: async wanted => {
      // One paced request at a time, stopping at the first clear match.
      const slot = async (slots: number) => {
        const { data, error } = await service.rpc('worker_pipeline_arxiv_slot', { p_slots: slots, p_max_wait_ms: 10_000 });
        if (error) throw new Error('search_busy');
        return data;
      };
      const seen: DiscoveryResult[] = [];
      for (const url of arxivTitleURLs(wanted.title, wanted.arxivID)) {
        seen.push(...await searchArxiv([url], fetch, slot));
        const match = bestTitleMatch(wanted.title, wanted.year, seen);
        if (match) return { source_id: match.source_id, title: match.title, year: match.year };
      }
      return null;
    },
    importPaper: async sourceID => {
      // The caller's own library command, exactly like the app's Add; the
      // observed cursor is the library's current head (a fresh intent).
      const page = await user.rpc('v2_library_page', { p_cursor: null, p_limit: 1 });
      const cursor = page.data?.baseline_cursor;
      if (page.error || typeof cursor !== 'number') return 'failed';
      const { data, error } = await user.rpc('v2_begin_import', { p_operation_id: crypto.randomUUID(), p_source_id: sourceID, p_observed_cursor: cursor });
      return !error && data?.result?.status === 'applied' ? 'added' : 'failed';
    },
    log: entry => console.warn(JSON.stringify({ function: 'chat', ...entry })),
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
