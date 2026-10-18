// "No server request to arXiv" (docs/architecture/ARXIV_DEVICE_ONLY.md §5.1, §6.5). Every server entry point (Edge
// functions, the Cloud Run worker's server and threads, the workflow job) installs this guard on its global `fetch`.
// A request to any *.arxiv.org host, on the first request or on any redirect hop, is logged and counted; in `block`
// mode it is refused. Block is the default since the cutover (rollout step 6, 2026-10-16); only EGRESS_ARXIV=report
// (a developer diagnosing a test, never a deployment) lets a request through to be reported. Self-contained on
// purpose: the workflow job copies this one file into its image.

export type EgressMode = 'report' | 'block';
export interface EgressAttempt { mode: EgressMode; host: string; caller: string; blocked: boolean }

export class EgressBlocked extends Error {
  readonly code = 'arxiv_egress_blocked';
  readonly host: string;
  constructor(host: string) { super('arxiv_egress_blocked'); this.host = host; }
}

/** True for arxiv.org and every subdomain, however the host was spelled (case, a trailing dot, full-width or other
 * IDNA-mapped characters: `new URL` applies UTS #46 before we look). */
export function isArxivHost(host: string): boolean {
  const name = host.toLowerCase().replace(/\.+$/, '');
  return name === 'arxiv.org' || name.endsWith('.arxiv.org'); // egress-ok: parse
}

/** Paid inference is OpenRouter-only. This also blocks accidental use of retained historical adapters. */
export function isDirectModelHost(host: string): boolean {
  const name = host.toLowerCase().replace(/\.+$/, '');
  return ['api.anthropic.com', 'api.deepseek.com', 'api.openai.com', 'generativelanguage.googleapis.com',
    'aiplatform.googleapis.com'].includes(name) || name.endsWith('-aiplatform.googleapis.com');
}
export class ModelEgressBlocked extends Error {
  readonly code = 'model_route_requires_openrouter';
  constructor() { super('model_route_requires_openrouter'); }
}

/** The host a request would go to, or null for something that is not an absolute http(s) URL. */
export function requestHost(input: unknown): string | null {
  let href: string;
  if (typeof input === 'string') href = input;
  else if (input instanceof URL) href = input.href;
  else if (input && typeof input === 'object' && typeof (input as { url?: unknown }).url === 'string') href = (input as { url: string }).url;
  else return null;
  try {
    const url = new URL(href);
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.hostname : null;
  } catch { return null; }
}

const env = (name: string): string | undefined => {
  const g = globalThis as { Deno?: { env?: { get?: (n: string) => string | undefined } }; process?: { env?: Record<string, string | undefined> } };
  try { return g.Deno?.env?.get?.(name) ?? g.process?.env?.[name]; } catch { return undefined; }
};
export const egressMode = (): EgressMode => env('EGRESS_ARXIV') === 'report' ? 'report' : 'block';

const attempts: EgressAttempt[] = [];
/** How many arXiv requests this process saw (report) or refused (block); the hosted check reads it from logs. */
export const egressAttempts = (): readonly EgressAttempt[] => attempts;

type Fetch = typeof fetch;
/** The request options this guard reads; spelled out because some runtimes' lib types narrow `RequestInit`. */
type FetchInit = NonNullable<Parameters<Fetch>[1]> & { redirect?: 'follow' | 'manual' | 'error'; method?: string; body?: unknown };
const INSTALLED = Symbol.for('gradstep.egress.guard');
const MAX_REDIRECTS = 20;

function note(host: string, caller: string, mode: EgressMode, log: (line: string) => void): EgressAttempt {
  const attempt = { mode, host, caller, blocked: mode === 'block' };
  attempts.push(attempt);
  if (attempts.length > 1000) attempts.shift();
  // Counts and the host only; never the path or query (a search query could be the reader's words).
  log(JSON.stringify({ event: 'arxiv_egress', mode, host, caller, blocked: attempt.blocked }));
  return attempt;
}

/** A fetch that refuses (block) or reports (report) arXiv on the first request and every redirect hop. In block mode
 * redirects are followed here, one hop at a time, so a hop to arXiv is refused before it is requested; in report mode
 * the platform follows them and a final arXiv URL is reported after the fact. */
export function guardedFetch(inner: Fetch, caller: string, options: { mode?: () => EgressMode; log?: (line: string) => void } = {}): Fetch {
  const modeOf = options.mode ?? egressMode, log = options.log ?? ((line: string) => console.error(line));
  const guarded = async (input: Parameters<Fetch>[0], init?: FetchInit): Promise<Response> => {
    const mode = modeOf();
    const host = requestHost(input);
    if (host && isDirectModelHost(host)) throw new ModelEgressBlocked();
    if (host !== null && isArxivHost(host)) {
      note(host, caller, mode, log);
      if (mode === 'block') throw new EgressBlocked(host);
    }
    const redirect = init?.redirect ?? (input instanceof Request ? input.redirect : 'follow');
    if (mode !== 'block' || redirect !== 'follow') {
      const response = await inner(input, init);
      if (mode === 'report' && response.redirected && response.url) {
        const final = requestHost(response.url);
        if (final !== null && isArxivHost(final)) note(final, caller, mode, log);
      }
      return response;
    }
    // Block mode, automatic redirects: follow them here so every hop is checked first.
    let url = typeof input === 'string' || input instanceof URL ? new URL(String(input)) : new URL((input as Request).url);
    let request: FetchInit = { ...init, redirect: 'manual' };
    for (let hop = 0; ; hop++) {
      if (isDirectModelHost(url.hostname)) throw new ModelEgressBlocked();
      const response = await inner(hop === 0 && input instanceof Request ? input : url.href, hop === 0 && input instanceof Request ? { ...init, redirect: 'manual' } : request);
      if (response.status < 300 || response.status >= 400 || response.status === 304) return response;
      const location = response.headers.get('location');
      if (!location) return response;
      if (hop >= MAX_REDIRECTS) throw new TypeError('too_many_redirects');
      url = new URL(location, url);
      const next = requestHost(url.href);
      if (next !== null && isArxivHost(next)) { note(next, caller, mode, log); throw new EgressBlocked(next); }
      // As browsers do: 303 (and 301/302 after POST) become a bodiless GET.
      const method = (request?.method ?? (input instanceof Request ? input.method : 'GET')).toUpperCase();
      if (response.status === 303 || ((response.status === 301 || response.status === 302) && method === 'POST')) {
        request = { ...request, method: 'GET', body: undefined };
      }
      try { await response.body?.cancel(); } catch { /* already consumed */ }
    }
  };
  return guarded as Fetch;
}

/** Installs the guard on this realm's global fetch (each worker thread is its own realm). Idempotent. */
export function installEgressGuard(caller: string): void {
  const g = globalThis as unknown as Record<PropertyKey, unknown> & { fetch: Fetch };
  if (g[INSTALLED]) return;
  const inner = g.fetch.bind(globalThis);
  g.fetch = guardedFetch(inner, caller);
  g[INSTALLED] = caller;
}
