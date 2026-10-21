// Tavily web search for chat: our search_web tool, which the model calls through OpenRouter and our server runs
// (docs/architecture/CHAT.md "Web search"). No provider-native search exists.
// Deno and Node compatible. Never log queries, results or the API key.

export const TAVILY_SEARCH_URL = 'https://api.tavily.com/search';
/** Pages per search and characters kept per page: together they bound the
 * tokens one search adds to the answer (about 5 × 1,500 / 3 ≈ 2,500). */
export const TAVILY_MAX_RESULTS = 5;
export const TAVILY_RESULT_CHARS = 1_500;
export const TAVILY_QUERY_CHARS = 400;
export const TAVILY_TIMEOUT_MS = 15_000;

/** Scholarly sites for `academic` searches: preprints, proceedings, journals. */
export const ACADEMIC_DOMAINS = Object.freeze([
  'arxiv.org', 'openreview.net', 'aclanthology.org', 'proceedings.neurips.cc', 'papers.nips.cc', 'proceedings.mlr.press', // egress-ok: tavily-filter
  'jmlr.org', 'openaccess.thecvf.com', 'ojs.aaai.org', 'ijcai.org', 'dl.acm.org', 'ieeexplore.ieee.org', 'nature.com',
  'science.org', 'pnas.org', 'link.springer.com', 'sciencedirect.com', 'biorxiv.org', 'medrxiv.org', 'semanticscholar.org',
]);

export interface SearchInput { query: string; academic: boolean }
export interface WebResult { url: string; title: string; text: string; published: string | null }
/** limit: the plan's or pay-as-you-go cap (HTTP 432/433). rejected: this query (400/422). */
export type SearchFailure = 'limit' | 'rate_limited' | 'unauthorized' | 'rejected' | 'unavailable';
export type SearchOutcome = { status: 'ok'; results: WebResult[]; credits: number }
  | { status: 'failed'; failure: SearchFailure; retryAfterMs: number | null };
export interface SearchBilling {
  state: 'succeeded' | 'rejected' | 'unknown'; requestID: string | null; credits: number | null; failureCode: string | null;
}
export type SearchAttemptOutcome = SearchOutcome & { billing: SearchBilling };

/** Opaque provider identifiers only. Error text and queries never reach the ledger. */
export function providerRequestID(value: unknown): string | null {
  return typeof value === 'string' && /^[A-Za-z0-9._:/-]{1,256}$/.test(value) ? value : null;
}

/** Validates the model's search_web input (untrusted). */
export function searchInput(input: unknown): SearchInput | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const value = input as Record<string, unknown>;
  if (Object.keys(value).some(key => !['query', 'academic'].includes(key))) return null;
  const query = typeof value.query === 'string' ? value.query.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim() : '';
  if (query.length < 2) return null;
  if (value.academic !== undefined && typeof value.academic !== 'boolean') return null;
  return { query: [...query].slice(0, TAVILY_QUERY_CHARS).join(''), academic: value.academic === true };
}

const clean = (text: string, limit: number) => [...text.replace(/\s+/g, ' ').trim()].slice(0, limit).join('');

/** Bounded, typed results; anything malformed is dropped. */
export function parseResults(body: unknown): { results: WebResult[]; credits: number } | null {
  if (!body || typeof body !== 'object' || !Array.isArray((body as { results?: unknown }).results)) return null;
  const results: WebResult[] = [];
  for (const raw of (body as { results: unknown[] }).results) {
    if (results.length >= TAVILY_MAX_RESULTS) break;
    if (!raw || typeof raw !== 'object') continue;
    const item = raw as Record<string, unknown>;
    const url = typeof item.url === 'string' ? item.url.trim() : '';
    if (!/^https?:\/\/[^\s]{1,2000}$/i.test(url)) continue;
    const text = typeof item.content === 'string' ? clean(item.content, TAVILY_RESULT_CHARS) : '';
    if (!text) continue;
    let title = typeof item.title === 'string' ? clean(item.title, 300) : '';
    if (!title) { try { title = new URL(url).hostname; } catch { continue; } }
    const published = typeof item.published_date === 'string' && item.published_date.length <= 40 ? item.published_date.trim() || null : null;
    results.push({ url, title, text, published });
  }
  const used = (body as { usage?: { credits?: unknown } }).usage?.credits;
  return { results, credits: Number.isSafeInteger(used) && (used as number) >= 0 && (used as number) <= 10 ? used as number : 1 };
}

function failure(status: number): SearchFailure {
  if (status === 432 || status === 433) return 'limit';
  if (status === 429) return 'rate_limited';
  if (status === 401 || status === 403) return 'unauthorized';
  if (status === 400 || status === 422) return 'rejected';
  return 'unavailable';
}

/**
 * One basic search (1 Tavily credit), exactly one transport attempt. The caller
 * must durably admit it first (provider-spending.ts). A lost response or 5xx is
 * unknown usage, not permission to retry or release the reserved credit.
 */
export async function tavilySearch(fetcher: typeof fetch, apiKey: string, input: SearchInput, signal: AbortSignal,
  options: { timeoutMs?: number } = {}): Promise<SearchAttemptOutcome> {
  const body = JSON.stringify({
    query: input.query, search_depth: 'basic', auto_parameters: false, topic: 'general', max_results: TAVILY_MAX_RESULTS,
    include_answer: false, include_raw_content: false, include_images: false, include_usage: true,
    ...(input.academic ? { include_domains: ACADEMIC_DOMAINS } : {}),
  });
  if (signal.aborted) return { status: 'failed', failure: 'unavailable', retryAfterMs: null,
    billing: { state: 'rejected', requestID: null, credits: 0, failureCode: 'aborted_before_send' } };
  let status = 0, retryAfter: string | null = null, requestID: string | null = null;
  try {
      const response = await fetcher(TAVILY_SEARCH_URL, {
        method: 'POST', redirect: 'error', body,
        signal: AbortSignal.any([signal, AbortSignal.timeout(options.timeoutMs ?? TAVILY_TIMEOUT_MS)]),
        headers: { authorization: `Bearer ${apiKey}`, 'content-type': 'application/json', accept: 'application/json' },
      });
      status = response.status; retryAfter = response.headers.get('retry-after');
      requestID = providerRequestID(response.headers.get('request-id') ?? response.headers.get('x-request-id'));
      if (response.ok) {
        const raw = await response.json().catch(() => null);
        requestID = providerRequestID(raw?.request_id) ?? requestID;
        const parsed = parseResults(raw);
        // include_usage is required: a usable result without final usage still
        // retains the grant. Never invent a 1-credit exact provider report.
        const used = raw?.usage?.credits;
        if (parsed) return { status: 'ok', ...parsed, billing: {
          state: Number.isSafeInteger(used) && used >= 0 && used <= 10 ? 'succeeded' : 'unknown',
          requestID, credits: Number.isSafeInteger(used) && used >= 0 && used <= 10 ? used : null,
          failureCode: Number.isSafeInteger(used) && used >= 0 && used <= 10 ? null : 'usage_missing',
        } };
        status = 502;
      } else void response.body?.cancel().catch(() => {});
  } catch { status = 0; }
  const rejected = [400, 401, 403, 422, 429, 432, 433].includes(status);
  const seconds = retryAfter && /^\d{1,5}$/.test(retryAfter) ? Number(retryAfter) * 1000 : null;
  return { status: 'failed', failure: failure(status), retryAfterMs: seconds,
    billing: { state: rejected ? 'rejected' : 'unknown', requestID, credits: rejected ? 0 : null,
      failureCode: status ? `http_${status}` : 'transport_unknown' } };
}
