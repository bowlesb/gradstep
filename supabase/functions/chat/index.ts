import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError, sha256 } from '../_shared/http.ts';
import { createAnthropicClient, streamChat } from '../_shared/anthropic.ts';
import { MAX_PAPER_BYTES, readChatBody, RpcFailure, runChat, sseFrame, type ChatDependencies } from '../_shared/chat.ts';
import { arxivTitleURLs, matchPaper, searchArxiv, type DiscoveryResult, openAlexCandidates, openAlexFindURL } from '../_shared/discover.ts';
import { publicHTTPS } from '../_shared/web-source.ts';
import { type SearchFailure, tavilySearch } from '../_shared/tavily.ts';
import type { FindResult } from '../_shared/chat.ts';

type Runtime = { waitUntil(promise: Promise<unknown>): void };
const encoder = new TextEncoder();

// Tavily searches allowed in any 31 days (the plan's monthly credits less a margin for
// searches in flight); past it, answers use Anthropic's search until older ones age out.
const tavilyAllowance = Number(Deno.env.get('TAVILY_SEARCH_ALLOWANCE') ?? '3900');
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
    webSearch: Deno.env.get('CHAT_WEB_SEARCH') === 'on',
    search: tavilyKey ? {
      ready: async () => {
        if (Date.now() < tavilyPausedUntil || !(tavilyAllowance > 0)) return false;
        const { data, error } = await service.rpc('worker_provider_units_recent', { p_provider: 'tavily', p_unit: 'credits', p_days: 31 });
        return !error && typeof data === 'number' && data < tavilyAllowance;
      },
      run: async (input, signal) => {
        const outcome = await tavilySearch(fetch, tavilyKey, input, signal);
        if (outcome.status === 'failed') tavilyPausedUntil = Math.max(tavilyPausedUntil, Date.now() + (outcome.retryAfterMs ?? PAUSE_MS[outcome.failure]));
        return outcome;
      },
    } : undefined,
    availableCredits: async () => {
      const { data, error } = await user.rpc('v1_credit_balance');
      return error || typeof data?.available !== 'number' ? null : data.available;
    },
    findPaper: async (wanted, signal, { web }) => {
      // One paced request at a time, stopping at the first clear match. A
      // failed query does not hide the others; all failing is "unavailable".
      const slot = async (slots: number) => {
        const { data, error } = await service.rpc('worker_pipeline_arxiv_slot', { p_slots: slots, p_max_wait_ms: 10_000 });
        if (error) throw new Error('search_busy');
        return data;
      };
      const seen: DiscoveryResult[] = [];
      let answered = false, closed: FindResult | null = null;
      for (const url of arxivTitleURLs(wanted.title, wanted.arxivID)) {
        if (signal.aborted) break;
        try { seen.push(...await searchArxiv([url], fetch, slot, signal)); answered = true; } catch { continue; }
        const match = matchPaper(wanted, seen);
        if (match) return { status: 'found', paper: { source_id: match.source_id, title: match.title, year: match.year } };
      }
      // OpenAlex knows a paper's other versions: an arXiv copy arXiv's own search
      // missed (conference titles often differ), with the same strict match; otherwise
      // an open-access copy elsewhere (the worker re-reads its locations from OpenAlex).
      const find = !signal.aborted ? openAlexFindURL(wanted) : null;
      if (find) {
        try {
          const response = await fetch(find, { redirect: 'error', signal: AbortSignal.any([signal, AbortSignal.timeout(10_000)]),
            headers: { accept: 'application/json', 'user-agent': 'ScienceReader/0.1 (research paper reader)' } });
          if (response.ok) {
            answered = true;
            // A paper's preprint and journal versions are often separate works: prefer one
            // with an arXiv copy, then one with an open-access PDF.
            const candidates = openAlexCandidates(await response.json());
            const openPDF = (url: string | null) => {
              const open = url ? publicHTTPS(url.replace(/^http:\/\//i, 'https://')) : null;
              return open && !/(^|\.)arxiv\.org$/.test(open.hostname) ? open : null;
            };
            const match = matchPaper(wanted, candidates.filter(c => c.arxivID)) ?? matchPaper(wanted, candidates.filter(c => openPDF(c.pdfURL)))
              ?? matchPaper(wanted, candidates);
            if (match?.arxivID) return { status: 'found', paper: { source_id: match.arxivID, title: match.title, year: match.year, kind: 'arxiv' } };
            if (match) {
              const open = openPDF(match.pdfURL);
              const paper = { source_id: `openalex:${match.openalexID}`, title: match.title, year: match.year, kind: 'web' as const,
                host: open?.hostname ?? null, link: match.landingURL };
              if (open) return { status: web ? 'found' : 'needs_update', paper };
              closed = { status: 'closed', paper };
            }
          } else void response.body?.cancel().catch(() => {});
        } catch { /* unavailable */ }
      }
      // Last resort: a scholarly web search (Tavily) for an arXiv copy under another title
      // or one arXiv's search missed, accepted only under the same strict match.
      if (tavilyKey && !signal.aborted) {
        const query = `${wanted.title}${wanted.firstAuthor ? ` ${wanted.firstAuthor}` : ''} arXiv`;
        const searched = await tavilySearch(fetch, tavilyKey, { query, academic: true }, signal).catch(() => null);
        const ids = searched?.status === 'ok'
          ? [...new Set(searched.results.flatMap(r => /arxiv\.org\/(?:abs|pdf)\/(\d{4}\.\d{4,5})/.exec(r.url)?.[1] ?? []))].slice(0, 5) : [];
        if (ids.length) {
          const url = `https://export.arxiv.org/api/query?${new URLSearchParams({ id_list: ids.join(','), max_results: String(ids.length) })}`;
          try {
            const match = matchPaper(wanted, await searchArxiv([url], fetch, slot, signal));
            if (match) return { status: 'found', paper: { source_id: match.source_id, title: match.title, year: match.year, kind: 'arxiv' } };
          } catch { /* fall through */ }
        }
      }
      if (closed) return closed;
      return { status: answered && !signal.aborted ? 'not_found' : 'unavailable' };
    },
    importPaper: async (paper, signal) => {
      // The caller's own library command, exactly like the app's Add. Skip
      // papers already present or still importing (bounded look-up).
      const sourceID = paper.source_id;
      let cursor: unknown = null, head: unknown = null;
      for (let page = 0; page < 3; page++) {
        const { data, error } = await user.rpc('v3_library_page', { p_cursor: cursor, p_limit: 100 }).abortSignal(signal);
        if (error || typeof data?.baseline_cursor !== 'number') return 'failed';
        head ??= data.baseline_cursor;
        const entries: { kind?: string; source_id?: string; visible?: boolean; phase?: string }[] = Array.isArray(data.entries) ? data.entries : [];
        if (entries.some(e => e.source_id === sourceID && e.visible && (e.kind === 'item' || ['accepted', 'resolving', 'acquiring'].includes(e.phase ?? '')))) return 'present';
        if (!data.has_more || !data.next_cursor) break;
        cursor = data.next_cursor;
      }
      if (signal.aborted) return 'failed';
      const { data, error } = await user.rpc(paper.kind === 'web' ? 'v2_begin_web_import' : 'v2_begin_import',
        { p_operation_id: crypto.randomUUID(), p_source_id: sourceID, p_observed_cursor: head }).abortSignal(signal);
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
