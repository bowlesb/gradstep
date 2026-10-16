// Provider health (docs/architecture/RESILIENCE.md, migration 073): every request a server makes to an outside provider
// is classified (ok, throttled, overloaded, server error, timeout, transport, rejected) and counted per hour for the
// admin's Health tab; a provider failing steadily trips a breaker shared through the database, so further calls fail
// fast with an ordinary 429 (never billed, Retry-After set) instead of piling on; and, for drills only, a test account
// can be made to see a provider throttled or failing (FAULT_INJECTION=on, never production).
//
// Installed on a realm's global fetch next to the egress guard, so every provider call is seen, whatever library makes
// it. Counts only: never a URL path, query, body, header value or account. Self-contained (no SDK imports): the Edge
// functions and the Cloud Run worker share it.
//
// arXiv is counted too, as the egress counter of docs/architecture/ARXIV_DEVICE_ONLY.md §6.5: our servers never contact
// arXiv, so every `arxiv` row is an attempt the egress guard refused (outcome `rejected`, which never moves a breaker),
// or one it let through in report mode. The hosted check `egress.no-arxiv` and the Health tab require none.

export const PROVIDERS = ['anthropic', 'deepseek', 'google', 'tavily', 'crossref', 'datacite', 'openalex', 'huggingface', 'arxiv'] as const;
export type ProviderName = typeof PROVIDERS[number];
export type HealthOutcome = 'ok' | 'throttled' | 'overloaded' | 'server_error' | 'timeout' | 'transport' | 'rejected' | 'breaker_open';
/** `midstream` and `slow` (2026-10-16, migration 079) are streamed answers in the Messages API format (Anthropic and
 * DeepSeek's compatible API): `midstream` fails as overloaded after its first text; `slow` writes for up to a minute, so a
 * drill can press Stop or drop the connection partway. Elsewhere they answer as `error`. */
export type FaultMode = 'throttle' | 'overload' | 'error' | 'timeout' | 'malformed' | 'midstream' | 'slow';
export const FAULT_MODES: readonly FaultMode[] = ['throttle', 'overload', 'error', 'timeout', 'malformed', 'midstream', 'slow'];
/** `drill`: a fault drill's synthetic answer, counted apart and never moving the breaker. */
export interface HealthEvent { provider: ProviderName; route: string; outcome: HealthOutcome; latencyMs: number; retryAfterS: number | null; drill?: boolean }
export interface BreakerView { provider: ProviderName; state: 'closed' | 'open' | 'half_open'; reopenAt: number | null }
/** Records one call; resolves with the provider's breaker as the database sees it (or null). Must never throw. */
export type HealthRecorder = (event: HealthEvent) => Promise<BreakerView | null>;
export interface ActiveFault { provider: string; route: string | null; mode: FaultMode; rate: number }
/** The account's active faults (only consulted where FAULT_INJECTION=on). */
export type FaultSource = (account: string) => Promise<ActiveFault[]>;

/** Hosts we call, by provider, and arXiv (counted, never called). A host not listed passes through untouched (our own
 * database, storage). */
const HOSTS: [string, ProviderName][] = [
  ['api.anthropic.com', 'anthropic'], ['api.deepseek.com', 'deepseek'], ['aiplatform.googleapis.com', 'google'],
  ['api.tavily.com', 'tavily'], ['api.crossref.org', 'crossref'], ['api.datacite.org', 'datacite'],
  ['api.openalex.org', 'openalex'], ['huggingface.co', 'huggingface'], ['arxiv.org', 'arxiv'], // egress-ok: parse
];
export function providerForHost(host: string): ProviderName | null {
  const name = host.toLowerCase().replace(/\.+$/, '');
  for (const [suffix, provider] of HOSTS) if (name === suffix || name.endsWith(`.${suffix}`)) return provider;
  return null;
}

export function classifyStatus(status: number): HealthOutcome {
  if (status < 400) return 'ok';
  if (status === 429) return 'throttled';
  if (status === 503 || status === 529) return 'overloaded';
  if (status === 408 || status === 504) return 'timeout';
  if (status >= 500) return 'server_error';
  return 'rejected';
}

/** A thrown fetch error: a timeout (the request's own deadline), the egress guard's refusal (`rejected`: our request,
 * not the provider's health), or a transport failure. */
export function classifyError(error: unknown): 'timeout' | 'transport' | 'rejected' {
  const fields = error && typeof error === 'object' ? error as { name?: unknown; code?: unknown } : {};
  if (fields.code === 'arxiv_egress_blocked') return 'rejected';
  return fields.name === 'TimeoutError' ? 'timeout' : 'transport';
}

/** Retry-After in seconds (delta or HTTP date), bounded to a day; null when absent or unreadable. */
export function retryAfterSeconds(value: string | null | undefined, now = Date.now()): number | null {
  if (!value) return null;
  const trimmed = value.trim();
  if (/^\d{1,9}$/.test(trimmed)) return Math.min(86_400, Number(trimmed));
  const at = Date.parse(trimmed);
  return Number.isFinite(at) ? Math.min(86_400, Math.max(0, Math.ceil((at - now) / 1000))) : null;
}

/** Route names for the table: the function or worker that called (`pipeline-worker/podcast` → `pipeline_worker_podcast`). */
export function routeName(caller: string): string {
  const name = caller.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 32);
  return /^[a-z]/.test(name) ? name : 'server';
}

// ---------------------------------------------------------------------------
// Breakers: this realm's view of the shared state, refreshed by every recorded call
// ---------------------------------------------------------------------------
/** A probe whose answer never came back (its recording failed) stops blocking the next one after this long. */
const PROBE_MS = 30_000;
interface Known { state: BreakerView['state']; reopenAt: number | null; probingSince: number | null }
const known = new Map<ProviderName, Known>();
/** A recorded call's answer: the provider's breaker now. A new state or cool-off ends this realm's probe. */
export function noteBreaker(view: BreakerView | null): void {
  if (!view || !(PROVIDERS as readonly string[]).includes(view.provider)) return;
  const previous = known.get(view.provider);
  const same = previous && previous.state === view.state && previous.reopenAt === view.reopenAt;
  known.set(view.provider, { state: view.state, reopenAt: view.reopenAt, probingSince: same ? previous.probingSince : null });
}
/** Whether a call may go now. Open: no, until the cool-off ends; then one probe from this realm at a time. */
export function breakerVerdict(provider: ProviderName, now: number): { allow: true; probe: boolean } | { allow: false; retryAfterS: number } {
  const state = known.get(provider);
  if (!state || state.state === 'closed') return { allow: true, probe: false };
  if (state.reopenAt !== null && now < state.reopenAt) return { allow: false, retryAfterS: Math.max(1, Math.ceil((state.reopenAt - now) / 1000)) };
  if (state.probingSince !== null && now - state.probingSince < PROBE_MS) return { allow: false, retryAfterS: 5 };
  state.probingSince = now;
  return { allow: true, probe: true };
}
/** Tests only. */
export function resetBreakers(): void { known.clear(); }

// ---------------------------------------------------------------------------
// Synthetic answers: what a failing provider (or our breaker) looks like to the caller
// ---------------------------------------------------------------------------
/** The provider's own error shape, so its SDK classifies it exactly as a real one. A breaker's answer is a 429: refused
 * before any processing, never billed, with Retry-After set to the cool-off. */
export function syntheticResponse(provider: ProviderName, mode: Exclude<FaultMode, 'timeout' | 'midstream' | 'slow'> | 'breaker', retryAfterS: number): Response {
  const status = mode === 'throttle' || mode === 'breaker' ? 429 : mode === 'overload' ? (provider === 'anthropic' ? 529 : 503) : mode === 'error' ? 500 : 200;
  const headers: Record<string, string> = { 'content-type': 'application/json', 'retry-after': String(retryAfterS),
    'x-gradstep-synthetic': mode === 'breaker' ? 'breaker-open' : `fault-${mode}` };
  if (mode === 'malformed') return new Response('{"malformed', { status, headers });
  const type = status === 429 ? 'rate_limit_error' : status === 529 ? 'overloaded_error' : status === 503 ? 'overloaded_error' : 'api_error';
  const message = mode === 'breaker' ? 'Gradstep paused calls to this provider after repeated failures.' : `Gradstep fault drill: ${mode}.`;
  const body = provider === 'anthropic' ? { type: 'error', error: { type, message } } : { error: { code: status, status: type, message } };
  return new Response(JSON.stringify(body), { status, headers });
}

/** The model a request names (its JSON body), for a synthetic stream's message; a plain default otherwise. */
function requestedModel(body: unknown): string {
  try {
    const model = typeof body === 'string' ? (JSON.parse(body) as { model?: unknown }).model : null;
    if (typeof model === 'string' && /^[a-z0-9][a-z0-9.-]{0,63}$/.test(model)) return model;
  } catch { /* not JSON */ }
  return 'claude-haiku-5-5';
}

/** A drill's streamed answer (`midstream` or `slow`). Its request id starts `drill-` (kept as the attempt's provider
 * request id), so the drill can reconcile the attempt to zero afterwards: it never reached a provider. */
export function syntheticStream(mode: 'midstream' | 'slow', model: string, signal: AbortSignal | null | undefined, id: string = crypto.randomUUID()): Response {
  const encoder = new TextEncoder();
  const frame = (event: Record<string, unknown>) => encoder.encode(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
  const usage = { input_tokens: 12, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
  // Resolves false as soon as the caller gives up (the reader left, or the server's deadline).
  const wait = (ms: number) => new Promise<boolean>(resolve => {
    if (signal?.aborted) { resolve(false); return; }
    const timer = setTimeout(() => resolve(true), ms);
    signal?.addEventListener('abort', () => { clearTimeout(timer); resolve(false); }, { once: true });
  });
  const body = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        controller.enqueue(frame({ type: 'message_start', message: { id: `msg_drill_${id.replace(/-/g, '')}`, type: 'message', role: 'assistant', model,
          content: [], stop_reason: null, stop_sequence: null, usage } }));
        controller.enqueue(frame({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }));
        if (mode === 'midstream') {
          controller.enqueue(frame({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'This answer comes from a Gradstep fault drill and stops partway' } }));
          controller.enqueue(frame({ type: 'error', error: { type: 'overloaded_error', message: 'Gradstep fault drill: midstream.' } }));
          controller.close();
          return;
        }
        let written = 0;
        for (; written < 240; written++) {
          if (!await wait(250)) { controller.error(new DOMException('Gradstep fault drill: stopped.', 'AbortError')); return; }
          controller.enqueue(frame({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: `Drill sentence ${written + 1}. ` } }));
        }
        controller.enqueue(frame({ type: 'content_block_stop', index: 0 }));
        controller.enqueue(frame({ type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { ...usage, output_tokens: written * 5 } }));
        controller.enqueue(frame({ type: 'message_stop' }));
        controller.close();
      } catch { /* the reader went away */ }
    },
  });
  return new Response(body, { status: 200, headers: { 'content-type': 'text/event-stream', 'request-id': `drill-${id}`, 'x-gradstep-synthetic': `fault-${mode}` } });
}

// ---------------------------------------------------------------------------
// The fetch wrapper
// ---------------------------------------------------------------------------
type Fetch = typeof fetch;
export interface ProviderFetchOptions {
  route: string;
  record?: HealthRecorder;
  /** The account a request is for (fault drills only); a getter so one wrapper can follow a worker's current job. */
  account?: () => string | null;
  faults?: FaultSource;
  /** FAULT_INJECTION=on (staging and local only). */
  faultsEnabled?: () => boolean;
  now?: () => number;
  random?: () => number;
  /** Keeps a recording alive after the response (Edge: EdgeRuntime.waitUntil). */
  keepAlive?: (promise: Promise<unknown>) => void;
}

function host(input: unknown): string | null {
  let href: string;
  if (typeof input === 'string') href = input;
  else if (input instanceof URL) href = input.href;
  else if (input && typeof input === 'object' && typeof (input as { url?: unknown }).url === 'string') href = (input as { url: string }).url;
  else return null;
  try { const url = new URL(href); return url.protocol === 'https:' || url.protocol === 'http:' ? url.hostname : null; } catch { return null; }
}

export function providerFetch(inner: Fetch, options: ProviderFetchOptions): Fetch {
  const now = options.now ?? Date.now, random = options.random ?? Math.random;
  const route = routeName(options.route);
  const record = (event: HealthEvent) => {
    if (!options.record) return;
    const pending = options.record(event).then(noteBreaker, () => undefined);
    options.keepAlive?.(pending);
  };
  const wrapped = async (input: Parameters<Fetch>[0], init?: Parameters<Fetch>[1]): Promise<Response> => {
    const name = host(input);
    const provider = name ? providerForHost(name) : null;
    if (!provider) return inner(input, init);
    const started = now();
    // 1. Drills: a fault set for this test account (the database checks the account again).
    const account = options.account?.() ?? null;
    if (account && options.faults && options.faultsEnabled?.()) {
      let faults: ActiveFault[] = [];
      try { faults = await options.faults(account); } catch { faults = []; }
      const fault = faults.find(f => f.provider === provider && (f.route === null || f.route === route));
      if (fault && random() < fault.rate) {
        if (fault.mode === 'timeout') {
          record({ provider, route, outcome: 'timeout', latencyMs: now() - started, retryAfterS: null, drill: true });
          throw new DOMException('Gradstep fault drill: timeout.', 'TimeoutError');
        }
        if ((fault.mode === 'midstream' || fault.mode === 'slow') && (provider === 'anthropic' || provider === 'deepseek')) {
          // A dropped stream is a transport failure; a slow one is, as far as the provider is concerned, fine.
          record({ provider, route, outcome: fault.mode === 'midstream' ? 'transport' : 'ok', latencyMs: now() - started, retryAfterS: null, drill: true });
          return syntheticStream(fault.mode, requestedModel(init?.body), init?.signal ?? (input instanceof Request ? input.signal : undefined));
        }
        const mode = fault.mode === 'midstream' || fault.mode === 'slow' ? 'error' : fault.mode;
        const response = syntheticResponse(provider, mode, 5);
        record({ provider, route, outcome: mode === 'malformed' ? 'ok' : classifyStatus(response.status), latencyMs: now() - started, retryAfterS: 5, drill: true });
        return response;
      }
    }
    // 2. The breaker: an open provider is answered here, at once, as a 429 with its cool-off.
    const verdict = breakerVerdict(provider, now());
    if (!verdict.allow) {
      record({ provider, route, outcome: 'breaker_open', latencyMs: 0, retryAfterS: verdict.retryAfterS });
      return syntheticResponse(provider, 'breaker', verdict.retryAfterS);
    }
    let response: Response;
    try { response = await inner(input, init); }
    catch (error) {
      const signal = init?.signal ?? (input instanceof Request ? input.signal : undefined);
      const reason = signal?.aborted ? (signal.reason as { name?: unknown } | undefined) : undefined;
      // The caller giving up (the reader left) says nothing about the provider; its own deadline does.
      if (!signal?.aborted || (reason && reason.name === 'TimeoutError')) {
        record({ provider, route, outcome: signal?.aborted ? 'timeout' : classifyError(error), latencyMs: now() - started, retryAfterS: null });
      } else if (verdict.probe) { const state = known.get(provider); if (state) state.probingSince = null; }
      throw error;
    }
    record({ provider, route, outcome: classifyStatus(response.status), latencyMs: now() - started,
      retryAfterS: retryAfterSeconds(response.headers.get('retry-after'), now()) });
    return response;
  };
  return wrapped as Fetch;
}

// ---------------------------------------------------------------------------
// Wiring: the database recorder, the fault source, and the realm-wide install
// ---------------------------------------------------------------------------
export interface HealthRpc { rpc(name: string, params: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }> }

function breakerFrom(value: unknown): BreakerView | null {
  if (!value || typeof value !== 'object') return null;
  const row = value as { provider?: unknown; state?: unknown; reopen_at?: unknown };
  if (typeof row.provider !== 'string' || !['closed', 'open', 'half_open'].includes(row.state as string)) return null;
  const reopenAt = typeof row.reopen_at === 'string' ? Date.parse(row.reopen_at) : NaN;
  return { provider: row.provider as ProviderName, state: row.state as BreakerView['state'], reopenAt: Number.isFinite(reopenAt) ? reopenAt : null };
}

/** worker_provider_health over a service client, bounded; never throws. */
export function rpcRecorder(client: HealthRpc, timeoutMs = 3_000): HealthRecorder {
  return async event => {
    try {
      const call = Promise.resolve(client.rpc('worker_provider_health', { p_provider: event.provider, p_route: event.route, p_outcome: event.outcome,
        p_latency_ms: Math.max(0, Math.round(event.latencyMs)), p_retry_after_s: event.retryAfterS, ...(event.drill ? { p_drill: true } : {}) }));
      const result = await Promise.race([call, new Promise<null>(resolve => setTimeout(() => resolve(null), timeoutMs))]);
      return result && !result.error ? breakerFrom(result.data) : null;
    } catch { return null; }
  };
}

/** The open breakers at start, so a fresh instance doesn't rediscover an outage on its own. */
export async function loadBreakers(client: HealthRpc): Promise<void> {
  try {
    const { data, error } = await client.rpc('worker_provider_breakers', {});
    if (!error && Array.isArray(data)) for (const row of data) noteBreaker(breakerFrom(row));
  } catch { /* closed by default */ }
}

/** worker_fault_injection_active, cached 15 s per account. */
export function rpcFaultSource(client: HealthRpc, now: () => number = Date.now): FaultSource {
  const cache = new Map<string, { at: number; faults: ActiveFault[] }>();
  return async account => {
    const hit = cache.get(account);
    if (hit && now() - hit.at < 15_000) return hit.faults;
    let faults: ActiveFault[] = [];
    try {
      const { data, error } = await client.rpc('worker_fault_injection_active', { p_account: account });
      if (!error && Array.isArray(data)) faults = data.filter((f): f is ActiveFault => !!f && typeof f === 'object'
        && typeof (f as ActiveFault).provider === 'string' && FAULT_MODES.includes((f as ActiveFault).mode))
        .map(f => ({ provider: f.provider, route: typeof f.route === 'string' ? f.route : null, mode: f.mode, rate: Number(f.rate) > 0 ? Math.min(1, Number(f.rate)) : 1 }));
    } catch { faults = []; }
    cache.set(account, { at: now(), faults });
    return faults;
  };
}

const env = (name: string): string | undefined => {
  const g = globalThis as { Deno?: { env?: { get?: (n: string) => string | undefined } }; process?: { env?: Record<string, string | undefined> } };
  try { return g.Deno?.env?.get?.(name) ?? g.process?.env?.[name]; } catch { return undefined; }
};
export const faultInjectionEnabled = (): boolean => env('FAULT_INJECTION') === 'on';
const keepAlive = (promise: Promise<unknown>) => {
  try { (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime?.waitUntil(promise); } catch { /* not an Edge runtime */ }
};

const INSTALLED = Symbol.for('gradstep.provider.health');
const BASE = Symbol.for('gradstep.provider.base');
type Realm = Record<PropertyKey, unknown> & { fetch: Fetch };

/** Installs the wrapper on this realm's global fetch (after the egress guard). Idempotent. */
export function installProviderHealth(caller: string, client: () => HealthRpc | null): void {
  const g = globalThis as unknown as Realm;
  if (g[INSTALLED]) return;
  const inner = g.fetch.bind(globalThis);
  g[BASE] = inner;
  let service: HealthRpc | null | undefined;
  const get = () => { if (service === undefined) { try { service = client(); } catch { service = null; } } return service; };
  g.fetch = providerFetch(inner, { route: caller, keepAlive,
    record: event => { const s = get(); return s ? rpcRecorder(s)(event) : Promise.resolve(null); } });
  g[INSTALLED] = caller;
}

/** A fetch for one account's provider calls (fault drills reach only that account). Built on the realm's fetch beneath
 * the installed wrapper, so a call is recorded once. */
export function accountProviderFetch(caller: string, account: () => string | null, client: () => HealthRpc | null): Fetch {
  const g = globalThis as unknown as Realm;
  const inner = (g[BASE] as Fetch | undefined) ?? g.fetch.bind(globalThis);
  let service: HealthRpc | null | undefined;
  const get = () => { if (service === undefined) { try { service = client(); } catch { service = null; } } return service; };
  let faults: FaultSource | null = null;
  return providerFetch(inner, { route: caller, account, keepAlive, faultsEnabled: faultInjectionEnabled,
    faults: async id => { const s = get(); if (!s) return []; faults ??= rpcFaultSource(s); return faults(id); },
    record: event => { const s = get(); return s ? rpcRecorder(s)(event) : Promise.resolve(null); } });
}
