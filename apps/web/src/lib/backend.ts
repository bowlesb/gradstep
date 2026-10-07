// Fetch client for the dedicated Supabase backend, mirroring the native BackendClient:
// configured origin only, no redirects, bounded bodies, one refresh at a time (across
// tabs), finite error codes and no provider/server bodies in messages or logs.

export interface BackendConfig { url: string; anonKey: string; environment: string }

export const config: BackendConfig = {
  url: (import.meta.env.VITE_SUPABASE_URL as string | undefined ?? '').replace(/\/$/, ''),
  anonKey: import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined ?? '',
  environment: import.meta.env.VITE_ENVIRONMENT as string | undefined ?? 'staging',
};

export interface Session { accessToken: string; refreshToken: string; expiresAt: number; user: { id: string; email: string | null } }

export type AuthIssue = 'invalid_email' | 'no_account' | 'rate_limited' | 'invalid_code' | 'connection' | 'configuration' | 'rejected';
export class AuthError extends Error { constructor(readonly issue: AuthIssue, readonly retryAfter?: number) { super(issue); } }
/** `code` is a known server code (e.g. `library_resync_required`, `key_authority_required`) or `request_failed`. */
export class BackendError extends Error { constructor(readonly code: string, readonly status = 0) { super(code); } }

const KNOWN = new Set(['library_resync_required', 'key_authority_required', 'stale_key_epoch', 'operation_id_conflict', 'request_rate_limit',
  'library_account_import_limit', 'library_environment_import_limit', 'library_active_import_limit', 'library_account_receipt_limit',
  'library_environment_receipt_limit', 'import_not_retryable', 'invalid_library_cursor', 'invalid_arxiv_id', 'invalid_import_request',
  'too_many_enrollment_requests', 'enrollment_mismatch', 'enrollment_conflict', 'enrollment_id_conflict', 'invalid_management_token',
  'reader_not_ready', 'reader_integrity_failed', 'reader_unavailable', 'item_unavailable', 'origin_unavailable', 'insufficient_credits',
  'account_busy', 'platform_budget_exhausted', 'import_unavailable']);

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

async function send(path: string, init: RequestInit & { token?: string; maximum?: number; timeout?: number }): Promise<{ status: number; body: Uint8Array<ArrayBuffer>; headers: Headers }> {
  if (!config.url || !config.anonKey) throw new BackendError('not_configured');
  const headers: Record<string, string> = { apikey: config.anonKey, ...(init.body ? { 'Content-Type': 'application/json' } : {}) };
  if (init.token) headers.Authorization = `Bearer ${init.token}`;
  let response: Response;
  try {
    response = await fetch(endpoint(path), { method: init.method ?? 'POST', body: init.body, headers, redirect: 'error', cache: 'no-store',
      credentials: 'omit', referrerPolicy: 'no-referrer', signal: init.signal ?? AbortSignal.timeout(init.timeout ?? 30_000) });
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError' && init.signal?.aborted) throw error;
    throw new BackendError('connection');
  }
  return { status: response.status, body: await bounded(response, init.maximum ?? 262_144), headers: response.headers };
}

const parse = (body: Uint8Array): unknown => { try { return JSON.parse(new TextDecoder().decode(body)); } catch { return null; } };

// ---------- Authentication (email one-time code) ----------

type Listener = (session: Session | null) => void;
const listeners = new Set<Listener>();
let current: Session | null = load();
let generation = 0;

function load(): Session | null {
  try {
    const value = JSON.parse(localStorage.getItem(sessionKey()) ?? 'null') as Session | null;
    return value && typeof value.accessToken === 'string' && typeof value.refreshToken === 'string' && typeof value.user?.id === 'string' ? value : null;
  } catch { return null; }
}
function publish(next: Session | null): void {
  const changedAccount = current?.user.id !== next?.user.id;
  current = next;
  if (changedAccount) generation++;
  try { if (next) localStorage.setItem(sessionKey(), JSON.stringify(next)); else localStorage.removeItem(sessionKey()); } catch { /* storage unavailable */ }
  for (const listener of listeners) listener(next);
}
if (typeof window !== 'undefined') {
  // Another tab signed in, refreshed or signed out.
  window.addEventListener('storage', event => {
    if (event.key !== sessionKey()) return;
    const next = load();
    if (current?.user.id !== next?.user.id) generation++;
    current = next;
    for (const listener of listeners) listener(next);
  });
}

export const auth = {
  session: () => current,
  subscribe(listener: Listener): () => void { listeners.add(listener); return () => listeners.delete(listener); },

  /** Bounded, trimmed, no control characters; the submitted text is what verification uses. */
  normalizeEmail(raw: string): string | null {
    const email = raw.trim();
    if (!email || new TextEncoder().encode(email).length > 320 || /[\u0000-\u001f\u007f\s]/.test(email) || !/^[^@]+@[^@]+\.[^@]+$/.test(email)) return null;
    return email;
  },

  /** `delivered` false: the reply was lost or unreadable; a code may still have been sent. */
  async sendCode(email: string): Promise<{ delivered: boolean }> {
    let reply;
    try { reply = await send('auth/v1/otp', { body: JSON.stringify({ email, create_user: false }), maximum: 65_536 }); }
    catch { return { delivered: false }; }
    if (reply.status >= 200 && reply.status < 300) return { delivered: true };
    throw authFailure(reply.status, reply.body, reply.headers, false);
  },

  async verifyCode(email: string, code: string): Promise<Session> {
    if (!/^[0-9]{6}$/.test(code)) throw new AuthError('invalid_code');
    const before = generation;
    let reply;
    try { reply = await send('auth/v1/verify', { body: JSON.stringify({ type: 'email', email, token: code }), maximum: 262_144 }); }
    catch { throw new AuthError('connection'); }
    if (reply.status < 200 || reply.status >= 300) throw authFailure(reply.status, reply.body, reply.headers, true);
    const session = decodeSession(reply.body);
    if (before !== generation) throw new AuthError('rejected');
    publish(session);
    return session;
  },

  /** A valid access token for the current account, refreshing (once, across tabs) when it expires within a minute. */
  async token(): Promise<string> {
    const session = current;
    if (!session) throw new BackendError('sign_in_required', 401);
    if (session.expiresAt > Date.now() / 1000 + 60) return session.accessToken;
    const account = session.user.id, before = generation;
    const refresh = async () => {
      const latest = load() ?? current; // another tab may have refreshed already
      if (!latest || latest.user.id !== account) throw new BackendError('sign_in_required', 401);
      if (latest.expiresAt > Date.now() / 1000 + 60) return latest;
      const reply = await send('auth/v1/token?grant_type=refresh_token', { body: JSON.stringify({ refresh_token: latest.refreshToken }), maximum: 262_144 });
      if (reply.status === 400 || reply.status === 401 || reply.status === 403) { publish(null); throw new BackendError('sign_in_required', 401); }
      if (reply.status < 200 || reply.status >= 300) throw new BackendError('connection', reply.status);
      return decodeSession(reply.body);
    };
    const next = navigator.locks ? await navigator.locks.request(`gradstep.${config.environment}.refresh`, refresh) : await refresh();
    if (before !== generation || next.user.id !== account) throw new BackendError('cancelled');
    if (next.accessToken !== current?.accessToken) publish(next);
    return next.accessToken;
  },

  /** Clears this browser's session first; the server logout is best effort with the captured token. */
  async signOut(): Promise<void> {
    const token = current?.accessToken;
    publish(null);
    if (token) { try { await send('auth/v1/logout?scope=local', { body: '{}', token, maximum: 65_536, timeout: 10_000 }); } catch { /* best effort */ } }
  },
};

function decodeSession(body: Uint8Array): Session {
  const v = parse(body) as { access_token?: unknown; refresh_token?: unknown; expires_at?: unknown; expires_in?: unknown; user?: { id?: unknown; email?: unknown } } | null;
  const valid = (t: unknown) => typeof t === 'string' && t.length > 0 && t.length <= 16_384 && !/[\s\u0000-\u001f]/.test(t);
  if (!v || !valid(v.access_token) || !valid(v.refresh_token) || typeof v.user?.id !== 'string') throw new AuthError('rejected');
  const expiresAt = typeof v.expires_at === 'number' ? v.expires_at : Date.now() / 1000 + (typeof v.expires_in === 'number' ? v.expires_in : 3600);
  return { accessToken: v.access_token as string, refreshToken: v.refresh_token as string, expiresAt,
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

async function authorized(path: string, init: { method?: string; body?: string; maximum?: number; account?: string; signal?: AbortSignal }): Promise<Uint8Array<ArrayBuffer>> {
  const account = current?.user.id, before = generation;
  if (!account || (init.account && init.account !== account)) throw new BackendError('sign_in_required', 401);
  const token = await auth.token();
  const reply = await send(path, { ...init, token });
  if (before !== generation) throw new BackendError('cancelled');
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

/** A signed Storage URL on the configured project host; carries no account credential. */
export async function signedMember(url: string, bytes: number, signal?: AbortSignal): Promise<Uint8Array<ArrayBuffer>> {
  const parsed = new URL(url);
  if (parsed.origin !== new URL(config.url).origin || !parsed.pathname.startsWith('/storage/v1/object/sign/')) throw new BackendError('reader_integrity_failed');
  let response: Response;
  try { response = await fetch(parsed, { redirect: 'error', cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer', signal: signal ?? AbortSignal.timeout(60_000) }); }
  catch (error) { if (signal?.aborted) throw error; throw new BackendError('connection'); }
  if (response.status !== 200) { await response.body?.cancel(); throw new BackendError('reader_not_ready', response.status); }
  const data = await bounded(response, bytes);
  if (data.length !== bytes) throw new BackendError('reader_integrity_failed');
  return data;
}
