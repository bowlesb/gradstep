// Fetch client for the dedicated Supabase backend, mirroring the native BackendClient:
// configured origin only, no redirects, bounded bodies, one refresh at a time (across
// tabs), finite error codes and no provider/server bodies in messages or logs.
import { cancellation } from './cancellation';
import { isUUID } from './bytes';
import { parseStoredAuth, storedSession, type AuthEnvelope, type StoredAuth, type OAuthProvider } from './auth-state';
import { authorizeURL, callbackCode, newAttempt, oauthProviders, oauthStorageKey, parseAttempt, type OAuthAttempt, type OAuthIssue } from './oauth';

export interface BackendConfig { url: string; anonKey: string; environment: string }

export const config: BackendConfig = {
  url: (import.meta.env.VITE_SUPABASE_URL as string | undefined ?? '').replace(/\/$/, ''),
  anonKey: import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined ?? '',
  environment: import.meta.env.VITE_ENVIRONMENT as string | undefined ?? 'staging',
};

export interface Session { accessToken: string; refreshToken: string; expiresAt: number; lifetime: string; user: { id: string; email: string | null } }
export interface AuthSnapshot { session: Session | null; generation: number; signal: AbortSignal; boundary?: string | null; ready?: boolean; issue?: AuthIssue }

export type AuthIssue = 'invalid_email' | 'no_account' | 'rate_limited' | 'invalid_code' | 'connection' | 'configuration' | 'rejected' | 'auth_storage' | OAuthIssue;
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

// ---------- Authentication: one persisted authority and refresh owner ----------

type Listener = (session: Session | null) => void;
const listeners = new Set<Listener>();
const readStored = (): StoredAuth => {
  try { return parseStoredAuth(localStorage.getItem(sessionKey()), config); } catch { throw new AuthError('auth_storage'); }
};
let initial: StoredAuth;
try { initial = readStored(); } catch { initial = { kind: 'invalid', raw: '' }; }
let envelope: AuthEnvelope | null = initial.kind === 'envelope' ? initial.envelope : null;
let current: Session | null = envelope?.session ?? null;
let generation = 0;
let lifetime = new AbortController();
let ready = initial.kind !== 'legacy';
let issue: AuthIssue | undefined = initial.kind === 'invalid' ? 'auth_storage' : undefined;
let snapshot: AuthSnapshot = { session: current, generation, signal: lifetime.signal, boundary: envelope?.boundary ?? null, ready, issue };
let refreshing: { generation: number; task: Promise<Session> } | null = null;
let initializing: Promise<void> | null = null;
let localLane: Promise<unknown> = Promise.resolve();
let intent = 0;
function retire(): void { generation++; lifetime.abort(); lifetime = new AbortController(); }
function notify(): void {
  snapshot = { session: current, generation, signal: lifetime.signal, boundary: envelope?.boundary ?? null, ready, issue };
  for (const listener of listeners) listener(current);
}
function observe(stored: StoredAuth, forced = false): void {
  const next = stored.kind === 'envelope' ? stored.envelope : null;
  if (forced || envelope?.boundary !== next?.boundary || current?.lifetime !== next?.session?.lifetime || current?.user.id !== next?.session?.user.id) retire();
  envelope = next; current = next?.session ?? null; ready = true;
  issue = stored.kind === 'invalid' || stored.kind === 'legacy' ? 'auth_storage' : undefined;
  notify();
}
function lane<T>(body: () => T | Promise<T>, requireLocks = false): Promise<T> {
  if (typeof navigator !== 'undefined' && navigator.locks) return navigator.locks.request(`gradstep.${config.environment}.auth`, {}, body);
  if (requireLocks) return Promise.reject(new AuthError('oauth_unavailable'));
  const task = localLane.then(body); localLane = task.catch(() => {}); return task;
}
function fresh(session: Session | null, oauth?: AuthEnvelope['oauth']): AuthEnvelope {
  return { version: 2, origin: config.url, environment: config.environment, boundary: crypto.randomUUID(), session, ...(oauth ? { oauth } : {}) };
}
/** The caller holds the auth lane. No await separates the final check, atomic write, readback and publication. */
function write(next: AuthEnvelope, expected: StoredAuth): void {
  try {
    if (localStorage.getItem(sessionKey()) !== expected.raw) throw new AuthError('rejected');
    const value = JSON.stringify(next);
    localStorage.setItem(sessionKey(), value);
    if (localStorage.getItem(sessionKey()) !== value) throw new AuthError('auth_storage');
    observe({ kind: 'envelope', raw: value, envelope: next });
  } catch (error) { if (error instanceof AuthError) throw error; throw new AuthError('auth_storage'); }
}
function writable(): StoredAuth {
  const stored = readStored();
  if (stored.kind === 'invalid' || stored.kind === 'legacy') throw new AuthError('auth_storage');
  return stored;
}
function agrees(stored: StoredAuth, captured: AuthSnapshot): stored is Extract<StoredAuth, { kind: 'envelope' }> {
  return !captured.signal.aborted && captured.generation === generation && stored.kind === 'envelope'
    && stored.envelope.boundary === captured.boundary && stored.envelope.session?.user.id === captured.session?.user.id
    && stored.envelope.session?.lifetime === captured.session?.lifetime;
}
function initialize(): Promise<void> {
  if (initializing) return initializing;
  initializing = lane(() => {
    // A callback can never manufacture its missing boundary or adopt a legacy raw session.
    if (typeof location !== 'undefined' && location.pathname === '/auth/callback') return;
    const stored = readStored();
    if (stored.kind === 'invalid') { observe(stored); return; }
    if (stored.kind === 'legacy') write(fresh(stored.session), stored);
    else if (stored.kind === 'empty') write(fresh(null), stored);
    else observe(stored);
  }).catch(() => { current = null; retire(); ready = true; issue = 'auth_storage'; notify(); });
  return initializing;
}
function tabAttempt(): string | null {
  try { return sessionStorage.getItem(oauthStorageKey(config)); } catch { throw new AuthError('auth_storage'); }
}
function removeAttempt(expected?: string): void {
  try {
    if (expected !== undefined && sessionStorage.getItem(oauthStorageKey(config)) !== expected) return;
    sessionStorage.removeItem(oauthStorageKey(config));
    if (sessionStorage.getItem(oauthStorageKey(config)) !== null) throw new AuthError('auth_storage');
  } catch { throw new AuthError('auth_storage'); }
}
function matches(stored: StoredAuth, attempt: OAuthAttempt, phase: 'redirect' | 'claimed'): stored is Extract<StoredAuth, { kind: 'envelope' }> {
  return stored.kind === 'envelope' && stored.envelope.boundary === attempt.boundary && stored.envelope.session === null
    && stored.envelope.oauth?.id === attempt.id && stored.envelope.oauth.provider === attempt.provider && stored.envelope.oauth.phase === phase
    && stored.envelope.oauth.createdAt === attempt.createdAt && stored.envelope.oauth.expiresAt === attempt.expiresAt;
}
if (typeof window !== 'undefined') window.addEventListener('storage', event => {
  if (event.key !== sessionKey() && event.key !== null) return;
  try {
    // Notification payload preserves retirement even when a later value is already in storage.
    const changed = parseStoredAuth(event.newValue, config);
    const forced = event.key === null || changed.kind !== 'envelope' || changed.envelope.boundary !== envelope?.boundary;
    observe(readStored(), forced);
  } catch { current = null; envelope = null; retire(); issue = 'auth_storage'; ready = true; notify(); }
});

export const auth = {
  session: () => current,
  snapshot: () => snapshot,
  initialize,
  subscribe(listener: Listener): () => void { listeners.add(listener); return () => listeners.delete(listener); },
  /** Used synchronously inside IDB mutations, not just at UI/event boundaries. */
  persistedCurrent(captured: AuthSnapshot): boolean { try { return !!captured.session && agrees(readStored(), captured); } catch { return false; } },

  normalizeEmail(raw: string): string | null {
    const email = raw.trim();
    if (!email || new TextEncoder().encode(email).length > 320 || /[\u0000-\u001f\u007f\s]/.test(email) || !/^[^@]+@[^@]+\.[^@]+$/.test(email)) return null;
    return email;
  },

  /** A normal return/Back abandons only this tab's owned redirect, never another tab's attempt. */
  async returnedToApp(origin: string): Promise<void> {
    const raw = tabAttempt();
    if (!raw) return;
    let createdAt: number; try { createdAt = JSON.parse(raw).createdAt; } catch { return; }
    let attempt: OAuthAttempt; try { attempt = parseAttempt(raw, config, origin, createdAt); } catch { return; }
    if (matches(readStored(), attempt, 'redirect')) await auth.abandonOAuth(attempt.id);
  },

  /** Changing method retires an OAuth claim, including one initiated in another tab. */
  async abandonOAuth(id?: string): Promise<void> {
    const mine = id === undefined ? ++intent : intent;
    await initialize();
    await lane(() => {
      if (id === undefined && mine !== intent) return;
      const stored = writable();
      if (stored.kind === 'envelope' && stored.envelope.oauth && (id === undefined || stored.envelope.oauth.id === id)) write(fresh(null), stored);
      const raw = tabAttempt();
      if (raw) { let saved: { id?: string }; try { saved = JSON.parse(raw); } catch { return; }
        if (id === undefined || saved.id === id) removeAttempt(raw); }
    });
  },

  /** `delivered` false means a code may have been sent; never send twice automatically. */
  async sendCode(email: string, signal?: AbortSignal): Promise<{ delivered: boolean }> {
    await auth.abandonOAuth(); signal?.throwIfAborted();
    let reply;
    try { reply = await send('auth/v1/otp', { body: JSON.stringify({ email, create_user: false }), maximum: 65_536, signal }); }
    catch { return { delivered: false }; }
    if (reply.status >= 200 && reply.status < 300) return { delivered: true };
    throw authFailure(reply.status, reply.body, reply.headers, false);
  },

  async verifyCode(email: string, code: string, signal?: AbortSignal): Promise<Session> {
    if (!/^[0-9]{6}$/.test(code)) throw new AuthError('invalid_code');
    const myIntent = ++intent;
    await initialize(); if (signal?.aborted) throw new AuthError('rejected');
    const captured = await lane(() => {
      if (myIntent !== intent || signal?.aborted) throw new AuthError('rejected');
      const stored = writable();
      if (stored.kind === 'empty' || stored.kind === 'envelope' && stored.envelope.oauth) write(fresh(null), stored);
      else observe(stored);
      return snapshot;
    });
    let reply;
    try { reply = await send('auth/v1/verify', { body: JSON.stringify({ type: 'email', email, token: code }), maximum: 262_144, signal, sessionSignal: captured.signal }); }
    catch { throw new AuthError(captured.signal.aborted || signal?.aborted ? 'rejected' : 'connection'); }
    return lane(() => {
      const stored = writable();
      if (myIntent !== intent || !agrees(stored, captured) || signal?.aborted) throw new AuthError('rejected');
      if (reply.status < 200 || reply.status >= 300) throw authFailure(reply.status, reply.body, reply.headers, true);
      const session = decodeSession(reply.body);
      write(fresh(session), stored); return session;
    });
  },

  async beginOAuth(provider: OAuthProvider, origin: string, signal?: AbortSignal): Promise<{ url: string; attempt: OAuthAttempt }> {
    const myIntent = ++intent;
    if (!oauthProviders[provider] || !navigator.locks) throw new AuthError('oauth_unavailable');
    await initialize();
    let raw: string | undefined;
    const attempt = await lane(() => {
      signal?.throwIfAborted();
      if (myIntent !== intent) throw new AuthError('rejected');
      const stored = writable();
      if (stored.kind === 'envelope' && stored.envelope.session) throw new AuthError('rejected');
      const next = fresh(null), attempt = newAttempt(provider, config, origin, next.boundary);
      next.oauth = { id: attempt.id, provider, phase: 'redirect', createdAt: attempt.createdAt, expiresAt: attempt.expiresAt };
      raw = JSON.stringify(attempt);
      try { sessionStorage.setItem(oauthStorageKey(config), raw); if (tabAttempt() !== raw) throw new AuthError('auth_storage'); }
      catch { throw new AuthError('auth_storage'); }
      write(next, stored); return attempt;
    }, true).catch(error => { if (raw) { try { removeAttempt(raw); } catch { /* no callback can match a failed authority write */ } } throw error; });
    try {
      const url = await authorizeURL(attempt);
      await lane(() => {
        signal?.throwIfAborted();
        if (myIntent !== intent || !matches(writable(), attempt, 'redirect') || tabAttempt() !== raw) throw new AuthError('rejected');
      }, true);
      return { url, attempt };
    } catch (error) { await auth.abandonOAuth(attempt.id).catch(() => {}); throw error; }
  },
  /** Last synchronous guard immediately before location.assign; callers never navigate a cached result. */
  canRedirect(attempt: OAuthAttempt): boolean {
    try { return matches(readStored(), attempt, 'redirect') && parseAttempt(tabAttempt(), config, new URL(attempt.callback).origin).id === attempt.id; } catch { return false; }
  },

  async completeOAuth(rawURL: string, origin: string, signal?: AbortSignal): Promise<Session> {
    const myIntent = intent;
    if (!navigator.locks) throw new AuthError('oauth_unavailable');
    // Never call initialize here: a missing/raw/future boundary is a terminal refusal.
    const raw = tabAttempt();
    let createdAt: number; try { createdAt = JSON.parse(raw ?? 'null')?.createdAt; } catch { throw new AuthError('oauth_rejected'); }
    const attempt = parseAttempt(raw, config, origin, createdAt);
    let code: string;
    try {
      parseAttempt(raw, config, origin); code = callbackCode(rawURL, origin);
      if (!oauthProviders[attempt.provider]) throw new AuthError('oauth_unavailable');
    } catch (error) {
      await lane(() => {
        const stored = readStored();
        if (matches(stored, attempt, 'redirect')) write(fresh(null), stored);
        removeAttempt(raw!);
      }, true).catch(() => {});
      throw error;
    }
    const captured = await lane(() => {
      signal?.throwIfAborted();
      const stored = writable();
      if (myIntent !== intent || !matches(stored, attempt, 'redirect') || tabAttempt() !== raw) throw new AuthError('oauth_rejected');
      parseAttempt(raw, config, origin); // deadline is checked again after waiting for the lock
      const next = { ...stored.envelope, oauth: { ...stored.envelope.oauth!, phase: 'claimed' as const } };
      write(next, stored); removeAttempt(raw!);
      return snapshot;
    }, true);
    let reply;
    try { reply = await send('auth/v1/token?grant_type=pkce', { body: JSON.stringify({ auth_code: code, code_verifier: attempt.verifier }), maximum: 262_144, signal, sessionSignal: captured.signal }); }
    catch { throw new AuthError(captured.signal.aborted || signal?.aborted ? 'oauth_rejected' : 'connection'); }
    return lane(() => {
      const stored = writable();
      if (myIntent !== intent || !agrees(stored, captured) || !matches(stored, attempt, 'claimed') || signal?.aborted) throw new AuthError('oauth_rejected');
      parseAttempt(raw, config, origin);
      if (reply.status < 200 || reply.status >= 300) {
        write(fresh(null), stored);
        throw new AuthError(reply.status >= 500 ? 'connection' : 'oauth_rejected');
      }
      const session = decodeSession(reply.body); write(fresh(session), stored); return session;
    }, true);
  },

  async token(minimum = 60): Promise<string> {
    if (!ready) await initialize();
    const captured = snapshot, session = current;
    if (!session) throw new BackendError('sign_in_required', 401);
    if (!auth.persistedCurrent(captured)) throw new BackendError('cancelled');
    if (session.expiresAt > Date.now() / 1000 + minimum) return session.accessToken;
    const account = session.user.id, before = generation, owner = captured.signal;
    const refreshAndPublish = async () => {
      const stored = readStored();
      if (!agrees(stored, captured) || !stored.envelope.session) throw new BackendError('cancelled');
      const latest = stored.envelope.session;
      if (latest.expiresAt > Date.now() / 1000 + minimum) { observe(stored); return latest; }
      const reply = await send('auth/v1/token?grant_type=refresh_token', { body: JSON.stringify({ refresh_token: latest.refreshToken }), maximum: 262_144, signal: owner });
      return lane(() => {
        const active = readStored();
        if (!agrees(active, captured) || !active.envelope.session) throw new BackendError('cancelled');
        if (active.envelope.session.refreshToken !== latest.refreshToken && active.envelope.session.expiresAt > Date.now() / 1000 + 60) {
          observe(active); return active.envelope.session;
        }
        if (reply.status === 400 || reply.status === 401 || reply.status === 403) { write(fresh(null), active); throw new BackendError('sign_in_required', 401); }
        if (reply.status < 200 || reply.status >= 300) throw new BackendError('connection', reply.status);
        const next = decodeSession(reply.body, latest.lifetime);
        if (next.user.id !== account) throw new BackendError('cancelled');
        write({ ...active.envelope, session: next }, active); return next;
      });
    };
    if (!refreshing || refreshing.generation !== before) {
      const task = (navigator.locks ? navigator.locks.request(`gradstep.${config.environment}.refresh`, { signal: owner }, refreshAndPublish) : refreshAndPublish())
        .finally(() => { if (refreshing?.task === task) refreshing = null; });
      refreshing = { generation: before, task };
    }
    const next = await refreshing.task;
    if (!auth.persistedCurrent(captured) || next.user.id !== account) throw new BackendError('cancelled');
    return next.accessToken;
  },

  /** Hide/retire immediately. Durable failure is reported, never disguised as a successful sign-out. */
  async signOut(expectedGeneration = generation): Promise<void> {
    if (expectedGeneration !== generation) return;
    const captured = snapshot, token = current?.accessToken;
    intent++; current = null; retire(); issue = undefined; notify();
    const retirement = generation;
    try {
      await lane(() => {
        if (retirement !== generation) return;
        let stored: StoredAuth;
        try { stored = readStored(); } catch {
          try { localStorage.removeItem(sessionKey()); } catch { throw new AuthError('auth_storage'); }
          throw new AuthError('auth_storage'); // cannot read back whether removal succeeded
        }
        if (stored.kind === 'invalid' || stored.kind === 'legacy') throw new AuthError('auth_storage');
        if (stored.kind === 'envelope' && stored.envelope.boundary !== captured.boundary) { observe(stored); return; }
        try { write(fresh(null), stored); }
        catch {
          try { localStorage.removeItem(sessionKey()); if (localStorage.getItem(sessionKey()) !== null) throw new Error(); }
          catch { throw new AuthError('auth_storage'); }
          envelope = null; current = null; issue = undefined; notify();
        }
        try { removeAttempt(); } catch { /* removed/tombstoned authority is already terminal for every verifier */ }
      });
    } catch (error) { if (retirement === generation) { current = null; issue = 'auth_storage'; notify(); } throw error; }
    if (token) { try { await send('auth/v1/logout?scope=local', { body: '{}', token, maximum: 65_536, timeout: 10_000 }); } catch { /* captured old credential only */ } }
  },
};

function decodeSession(body: Uint8Array, loginLifetime: string = crypto.randomUUID()): Session {
  const v = parse(body) as { access_token?: unknown; refresh_token?: unknown; expires_at?: unknown; expires_in?: unknown; user?: { id?: unknown; email?: unknown } } | null;
  if (!v) throw new AuthError('rejected');
  const expiresAt = typeof v.expires_at === 'number' ? v.expires_at : typeof v.expires_in === 'number' ? Date.now() / 1000 + v.expires_in : NaN;
  const session = storedSession({ accessToken: v.access_token, refreshToken: v.refresh_token, expiresAt, lifetime: loginLifetime,
    user: { id: v.user?.id, email: v.user?.email ?? null } });
  if (!session || expiresAt <= Date.now() / 1000) throw new AuthError('rejected');
  return session;
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
        if (before !== generation) throw new BackendError('cancelled');
        options.signal.throwIfAborted(); sessionSignal.throwIfAborted();
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
