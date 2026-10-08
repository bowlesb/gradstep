// Fetch client for the dedicated Supabase backend, mirroring the native BackendClient:
// configured origin only, no redirects, bounded bodies, one refresh at a time (across
// tabs), finite error codes and no provider/server bodies in messages or logs.
import { cancellation } from './cancellation';
import { isUUID } from './bytes';

export interface BackendConfig { url: string; anonKey: string; environment: string }

export const config: BackendConfig = {
  url: (import.meta.env.VITE_SUPABASE_URL as string | undefined ?? '').replace(/\/$/, ''),
  anonKey: import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined ?? '',
  environment: import.meta.env.VITE_ENVIRONMENT as string | undefined ?? 'staging',
};

export interface Session { accessToken: string; refreshToken: string; expiresAt: number; lifetime: string; user: { id: string; email: string | null } }
export interface AuthSnapshot { session: Session | null; generation: number; signal: AbortSignal }

export type AuthIssue = 'invalid_email' | 'no_account' | 'rate_limited' | 'invalid_code' | 'connection' | 'configuration' | 'rejected';
export class AuthError extends Error { constructor(readonly issue: AuthIssue, readonly retryAfter?: number) { super(issue); } }
/** `code` is a known server code (e.g. `library_resync_required`, `key_authority_required`) or `request_failed`. */
export class BackendError extends Error { constructor(readonly code: string, readonly status = 0) { super(code); } }

const KNOWN = new Set(['library_resync_required', 'key_authority_required', 'stale_key_epoch', 'operation_id_conflict', 'request_rate_limit',
  'library_account_import_limit', 'library_environment_import_limit', 'library_active_import_limit', 'library_account_receipt_limit',
  'library_environment_receipt_limit', 'import_not_retryable', 'invalid_library_cursor', 'invalid_arxiv_id', 'invalid_import_request',
  'too_many_enrollment_requests', 'enrollment_mismatch', 'enrollment_conflict', 'enrollment_id_conflict', 'invalid_management_token',
  'reader_not_ready', 'reader_integrity_failed', 'reader_unavailable', 'item_unavailable', 'origin_unavailable', 'insufficient_credits',
  'account_busy', 'platform_budget_exhausted', 'import_unavailable', 'reader_transfer_limit', 'reader_upgrade_required',
  'reader_grant_unavailable', 'reader_grant_consumed', 'asset_inventory_incomplete', 'rate_limited', 'invalid_category', 'service_unavailable']);

const sessionKey = () => `gradstep.${config.environment}.session`;

async function bounded(response: Response, maximum: number): Promise<Uint8Array<ArrayBuffer>> {
  const declared = Number(response.headers.get('content-length') ?? '0');
  if (declared > maximum) { await response.body?.cancel(); throw new BackendError('payload_too_large', response.status); }
  if (!response.body) return new Uint8Array(0);
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = []; let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > maximum) { await reader.cancel(); throw new BackendError('payload_too_large', response.status); }
    chunks.push(value);
  }
  const out = new Uint8Array(total); let offset = 0;
  for (const chunk of chunks) { out.set(chunk, offset); offset += chunk.length; }
  return out;
}

function endpoint(path: string): string {
  const url = new URL('/' + path, config.url);
  if (url.origin !== new URL(config.url).origin) throw new BackendError('request_failed');
  return url.toString();
}

async function send(path: string, init: RequestInit & { token?: string; maximum?: number; timeout?: number; sessionSignal?: AbortSignal }): Promise<{ status: number; body: Uint8Array<ArrayBuffer>; headers: Headers }> {
  if (!config.url || !config.anonKey) throw new BackendError('not_configured');
  const headers: Record<string, string> = { apikey: config.anonKey, ...(init.body ? { 'Content-Type': 'application/json' } : {}) };
  if (init.token) headers.Authorization = `Bearer ${init.token}`;
  const deadline = requestDeadline([init.signal, init.sessionSignal], init.timeout ?? 30_000);
  try {
    const response = await fetch(endpoint(path), { method: init.method ?? 'POST', body: init.body, headers, redirect: 'error', cache: 'no-store',
      credentials: 'omit', referrerPolicy: 'no-referrer', signal: deadline.signal });
    return { status: response.status, body: await bounded(response, init.maximum ?? 262_144), headers: response.headers };
  } catch (error) {
    if (init.signal?.aborted || init.sessionSignal?.aborted || error instanceof BackendError) throw error;
    throw new BackendError('connection');
  } finally { deadline.dispose(); }
}

/** Caller cancellation and a finite deadline both apply, including while reading the response body. */
function requestDeadline(parents: (AbortSignal | null | undefined)[], milliseconds: number) {
  const controller = cancellation(parents);
  const timer = setTimeout(() => controller.abort(new DOMException('Request timed out', 'TimeoutError')), milliseconds);
  return { signal: controller.signal, dispose: () => { clearTimeout(timer); controller.dispose(); } };
}

const parse = (body: Uint8Array): unknown => { try { return JSON.parse(new TextDecoder().decode(body)); } catch { return null; } };

// ---------- Authentication (email one-time code) ----------

type Listener = (session: Session | null) => void;
const listeners = new Set<Listener>();
let current: Session | null = load() ?? null;
let generation = 0;
let lifetime = new AbortController();
let snapshot: AuthSnapshot = { session: current, generation, signal: lifetime.signal };
let refreshing: { generation: number; task: Promise<Session> } | null = null;

function retire(): void { generation++; lifetime.abort(); lifetime = new AbortController(); }

function load(): Session | null | undefined {
  try {
    const value = JSON.parse(localStorage.getItem(sessionKey()) ?? 'null') as Session | null;
    if (!value || typeof value.accessToken !== 'string' || typeof value.refreshToken !== 'string' || typeof value.user?.id !== 'string') return null;
    // Older browser builds did not persist a lifetime. Refresh keeps this legacy marker; the next login replaces it.
    return { ...value, lifetime: typeof value.lifetime === 'string' ? value.lifetime : 'legacy' };
  } catch { return undefined; } // storage unavailable: the in-memory session can still be used
}
function publish(next: Session | null, newLogin = false): void {
  const changedAccount = current?.user.id !== next?.user.id;
  const changedLifetime = current?.lifetime !== next?.lifetime;
  current = next;
  if (changedAccount || changedLifetime || newLogin || !next) retire();
  snapshot = { session: current, generation, signal: lifetime.signal };
  try { if (next) localStorage.setItem(sessionKey(), JSON.stringify(next)); else localStorage.removeItem(sessionKey()); } catch { /* storage unavailable */ }
  for (const listener of listeners) listener(next);
}
if (typeof window !== 'undefined') {
  // Another tab signed in, refreshed or signed out.
  window.addEventListener('storage', event => {
    if (event.key !== sessionKey() && event.key !== null) return;
    const next = load() ?? null;
    // Preserve a logout boundary even if a subsequent login is already in storage when its event arrives.
    if (event.newValue === null || current?.user.id !== next?.user.id || current?.lifetime !== next?.lifetime) retire();
    current = next;
    snapshot = { session: current, generation, signal: lifetime.signal };
    for (const listener of listeners) listener(next);
  });
}

export const auth = {
  session: () => current,
  snapshot: () => snapshot,
  subscribe(listener: Listener): () => void { listeners.add(listener); return () => listeners.delete(listener); },

  /** Bounded, trimmed, no control characters; the submitted text is what verification uses. */
  normalizeEmail(raw: string): string | null {
    const email = raw.trim();
    if (!email || new TextEncoder().encode(email).length > 320 || /[\u0000-\u001f\u007f\s]/.test(email) || !/^[^@]+@[^@]+\.[^@]+$/.test(email)) return null;
    return email;
  },

  /** `delivered` false: the reply was lost or unreadable; a code may still have been sent. */
  async sendCode(email: string, signal?: AbortSignal): Promise<{ delivered: boolean }> {
    let reply;
    try { reply = await send('auth/v1/otp', { body: JSON.stringify({ email, create_user: false }), maximum: 65_536, signal }); }
    catch { return { delivered: false }; }
    if (reply.status >= 200 && reply.status < 300) return { delivered: true };
    throw authFailure(reply.status, reply.body, reply.headers, false);
  },

  async verifyCode(email: string, code: string, signal?: AbortSignal): Promise<Session> {
    if (!/^[0-9]{6}$/.test(code)) throw new AuthError('invalid_code');
    const before = generation;
    let reply;
    try { reply = await send('auth/v1/verify', { body: JSON.stringify({ type: 'email', email, token: code }), maximum: 262_144, signal, sessionSignal: lifetime.signal }); }
    catch { throw new AuthError('connection'); }
    if (reply.status < 200 || reply.status >= 300) throw authFailure(reply.status, reply.body, reply.headers, true);
    const session = decodeSession(reply.body);
    if (before !== generation || signal?.aborted) throw new AuthError('rejected');
    publish(session, true);
    return session;
  },

  /** A valid access token for the current account, refreshing (once, across tabs) when it expires within `minimum` seconds. */
  async token(minimum = 60): Promise<string> {
    const session = current;
    if (!session) throw new BackendError('sign_in_required', 401);
    if (session.expiresAt > Date.now() / 1000 + minimum) return session.accessToken;
    const account = session.user.id, before = generation, owner = lifetime.signal;
    const refresh = async () => {
      if (before !== generation) throw new BackendError('cancelled');
      const stored = load();
      const latest = stored === undefined ? current : stored; // distinguish unavailable storage from a real logout
      if (!latest || latest.user.id !== account || latest.lifetime !== session.lifetime) throw new BackendError('sign_in_required', 401);
      if (latest.expiresAt > Date.now() / 1000 + minimum) return latest;
      const reply = await send('auth/v1/token?grant_type=refresh_token', { body: JSON.stringify({ refresh_token: latest.refreshToken }), maximum: 262_144, signal: owner });
      if (before !== generation) throw new BackendError('cancelled');
      const persisted = load(), active = persisted === undefined ? current : persisted;
      if (!active || active.user.id !== account || active.lifetime !== session.lifetime) throw new BackendError('cancelled');
      // A browser without Web Locks can overlap another tab's refresh; never retire its newer token.
      if (active.refreshToken !== latest.refreshToken && active.expiresAt > Date.now() / 1000 + 60) return active;
      if (reply.status === 400 || reply.status === 401 || reply.status === 403) { publish(null); throw new BackendError('sign_in_required', 401); }
      if (reply.status < 200 || reply.status >= 300) throw new BackendError('connection', reply.status);
      return decodeSession(reply.body, latest.lifetime);
    };
    const refreshAndPublish = async () => {
      const next = await refresh();
      if (before !== generation || next.user.id !== account) throw new BackendError('cancelled');
      if (next.accessToken !== current?.accessToken) publish(next);
      return next;
    };
    if (!refreshing || refreshing.generation !== before) {
      // Publish before releasing the cross-tab lock, so the next waiter observes the fresh token.
      const task = (navigator.locks ? navigator.locks.request(`gradstep.${config.environment}.refresh`, { signal: owner }, refreshAndPublish) : refreshAndPublish())
        .finally(() => { if (refreshing?.task === task) refreshing = null; });
      refreshing = { generation: before, task };
    }
    const next = await refreshing.task;
    if (before !== generation || next.user.id !== account) throw new BackendError('cancelled');
    if (next.accessToken !== current?.accessToken) publish(next);
    return next.accessToken;
  },

  /** Clears this browser's session first; the server logout is best effort with the captured token. */
  async signOut(expectedGeneration = generation): Promise<void> {
    if (expectedGeneration !== generation) return;
    const token = current?.accessToken;
    publish(null);
    if (token) { try { await send('auth/v1/logout?scope=local', { body: '{}', token, maximum: 65_536, timeout: 10_000 }); } catch { /* best effort */ } }
  },
};

function decodeSession(body: Uint8Array, lifetime: string = crypto.randomUUID()): Session {
  const v = parse(body) as { access_token?: unknown; refresh_token?: unknown; expires_at?: unknown; expires_in?: unknown; user?: { id?: unknown; email?: unknown } } | null;
  const valid = (t: unknown) => typeof t === 'string' && t.length > 0 && t.length <= 16_384 && !/[\s\u0000-\u001f]/.test(t);
  if (!v || !valid(v.access_token) || !valid(v.refresh_token) || typeof v.user?.id !== 'string') throw new AuthError('rejected');
  const expiresAt = typeof v.expires_at === 'number' ? v.expires_at : Date.now() / 1000 + (typeof v.expires_in === 'number' ? v.expires_in : 3600);
  return { accessToken: v.access_token as string, refreshToken: v.refresh_token as string, expiresAt, lifetime,
    user: { id: v.user.id.toLowerCase(), email: typeof v.user.email === 'string' ? v.user.email : null } };
}

function authFailure(status: number, body: Uint8Array, headers: Headers, verifying: boolean): AuthError {
  if (status >= 500) return new AuthError('connection');
  const v = parse(body) as { code?: unknown; error_code?: unknown } | null;
  const codes = [v?.code, v?.error_code].filter((c): c is string => typeof c === 'string');
  if (status === 429 || codes.some(c => ['over_email_send_rate_limit', 'over_request_rate_limit', 'over_send_rate_limit'].includes(c))) {
    const retry = headers.get('retry-after');
    return new AuthError('rate_limited', retry && /^[0-9]{1,5}$/.test(retry) ? Number(retry) : undefined);
  }
  if (codes.some(c => ['signup_disabled', 'otp_disabled', 'user_not_found'].includes(c))) return new AuthError(verifying ? 'invalid_code' : 'no_account');
  if (codes.includes('email_address_invalid')) return new AuthError('invalid_email');
  if (codes.some(c => ['provider_disabled', 'email_provider_disabled'].includes(c))) return new AuthError('configuration');
  if (verifying && (status === 400 || status === 401 || status === 403 || codes.some(c => ['otp_expired', 'invalid_credentials'].includes(c)))) return new AuthError('invalid_code');
  if (!verifying && status === 422) return new AuthError('no_account');
  return new AuthError('rejected');
}

// ---------- Authorized calls ----------

async function authorized(path: string, init: { method?: string; body?: string; maximum?: number; account?: string; signal?: AbortSignal; timeout?: number }): Promise<Uint8Array<ArrayBuffer>> {
  init.signal?.throwIfAborted();
  const account = current?.user.id, before = generation;
  const sessionSignal = lifetime.signal;
  if (!account || (init.account && init.account !== account)) throw new BackendError('sign_in_required', 401);
  const token = await auth.token();
  if (before !== generation) throw new BackendError('cancelled');
  init.signal?.throwIfAborted();
  const reply = await send(path, { ...init, token, sessionSignal });
  if (before !== generation) throw new BackendError('cancelled');
  init.signal?.throwIfAborted();
  if (reply.status === 401) throw new BackendError('sign_in_required', 401);
  if (reply.status < 200 || reply.status >= 300) {
    const v = parse(reply.body) as { code?: unknown; message?: unknown } | null;
    const candidates = [v?.message, v?.code].filter((c): c is string => typeof c === 'string');
    throw new BackendError(candidates.find(c => KNOWN.has(c)) ?? 'request_failed', reply.status);
  }
  return reply.body;
}

/** PostgREST RPC. `void` functions answer 204 with an empty body (returned as null). */
export async function rpc<T>(name: string, params: Record<string, unknown> = {}, options: { maximum?: number; account?: string; signal?: AbortSignal } = {}): Promise<T> {
  if (!/^v[0-9]+_[a-z_]+$/.test(name)) throw new BackendError('request_failed');
  const body = await authorized(`rest/v1/rpc/${name}`, { body: JSON.stringify(params), ...options });
  if (body.length === 0) return null as T;
  const value = parse(body);
  if (value === null && new TextDecoder().decode(body).trim() !== 'null') throw new BackendError('invalid_response');
  return value as T;
}

export async function functionGet<T>(path: string, options: { maximum?: number; account?: string; signal?: AbortSignal } = {}): Promise<T> {
  const value = parse(await authorized(`functions/v1/${path}`, { method: 'GET', ...options }));
  if (value === null) throw new BackendError('invalid_response');
  return value as T;
}

/** An Edge function's `text/event-stream` answer (`chat`), bounded in total bytes, with an idle deadline between chunks
 * (the server pings every 15 s). The token is refreshed first when it has less than `minimumValidity` seconds left: the
 * server may act as the user after the answer (Ingest). Non-200 replies throw their known `{code}`. */
export async function* functionStream(path: string, body: unknown, options: { account: string; signal: AbortSignal; maximum: number; minimumValidity?: number; idle?: number }): AsyncGenerator<Uint8Array<ArrayBuffer>> {
  options.signal.throwIfAborted();
  const account = current?.user.id, before = generation, sessionSignal = lifetime.signal;
  if (!account || account !== options.account) throw new BackendError('sign_in_required', 401);
  const token = await auth.token(options.minimumValidity ?? 60);
  if (before !== generation) throw new BackendError('cancelled');
  const controller = cancellation([options.signal, sessionSignal]);
  let idle: ReturnType<typeof setTimeout> | undefined;
  const arm = () => { clearTimeout(idle); idle = setTimeout(() => controller.abort(new DOMException('Stream idle', 'TimeoutError')), options.idle ?? 45_000); };
  try {
    arm();
    let response: Response;
    try {
      response = await fetch(endpoint(`functions/v1/${path}`), { method: 'POST', body: JSON.stringify(body), redirect: 'error', cache: 'no-store', credentials: 'omit',
        referrerPolicy: 'no-referrer', signal: controller.signal, headers: { apikey: config.anonKey, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } });
    } catch (error) { if (options.signal.aborted || sessionSignal.aborted) throw error; throw new BackendError('connection'); }
    if (before !== generation) throw new BackendError('cancelled');
    if (response.status === 401) { await response.body?.cancel(); throw new BackendError('sign_in_required', 401); }
    if (response.status !== 200) {
      const v = parse(await bounded(response, 65_536).catch(() => new Uint8Array(0))) as { code?: unknown } | null;
      throw new BackendError(typeof v?.code === 'string' && /^[a-z_]{1,64}$/.test(v.code) ? v.code : 'request_failed', response.status);
    }
    if (!(response.headers.get('content-type') ?? '').startsWith('text/event-stream') || !response.body) { await response.body?.cancel(); throw new BackendError('invalid_response'); }
    const reader = response.body.getReader();
    let total = 0;
    try {
      for (;;) {
        let chunk: ReadableStreamReadResult<Uint8Array<ArrayBuffer>>;
        try { chunk = await reader.read() as ReadableStreamReadResult<Uint8Array<ArrayBuffer>>; }
        catch (error) { if (options.signal.aborted || sessionSignal.aborted) throw error; throw new BackendError('connection'); }
        if (chunk.done) return;
        arm();
        total += chunk.value.length;
        if (total > options.maximum) throw new BackendError('payload_too_large');
        yield chunk.value;
      }
    } finally { reader.cancel().catch(() => {}); }
  } finally { clearTimeout(idle); controller.dispose(); }
}

/** An Edge function POST with a JSON body (e.g. `add-paper`). */
export async function functionPost<T>(path: string, body: unknown, options: { maximum?: number; account?: string; signal?: AbortSignal; timeout?: number } = {}): Promise<T> {
  const value = parse(await authorized(`functions/v1/${path}`, { method: 'POST', body: JSON.stringify(body), ...options }));
  if (value === null) throw new BackendError('invalid_response');
  return value as T;
}

/** A signed Storage URL on the configured project host; carries no account credential. */
export async function signedMember(url: string, bytes: number, signal?: AbortSignal, account?: string): Promise<Uint8Array<ArrayBuffer>> {
  const parsed = new URL(url);
  if (parsed.origin !== new URL(config.url).origin || parsed.username || parsed.password || parsed.hash) throw new BackendError('reader_integrity_failed');
  if (parsed.pathname === '/functions/v1/reader-member') {
    if (!account || parsed.searchParams.size !== 2 || !/^[0-9a-f]{64}$/.test(parsed.searchParams.get('grant') ?? '')
      || !isUUID(parsed.searchParams.get('member')) || new Set(parsed.searchParams.keys()).size !== 2) throw new BackendError('reader_integrity_failed');
    const data = await authorized(`functions/v1/reader-member${parsed.search}`, { method: 'GET', maximum: bytes, account, signal });
    if (data.length !== bytes) throw new BackendError('reader_integrity_failed');
    return data;
  }
  if (!parsed.pathname.startsWith('/storage/v1/object/sign/')) throw new BackendError('reader_integrity_failed');
  const deadline = requestDeadline([signal], 60_000);
  try {
    const response = await fetch(parsed, { redirect: 'error', cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer', signal: deadline.signal });
    if (response.status !== 200) { await response.body?.cancel(); throw new BackendError('reader_not_ready', response.status); }
    const data = await bounded(response, bytes);
    if (data.length !== bytes) throw new BackendError('reader_integrity_failed');
    return data;
  } catch (error) { if (signal?.aborted || error instanceof BackendError) throw error; throw new BackendError('connection'); }
  finally { deadline.dispose(); }
}
