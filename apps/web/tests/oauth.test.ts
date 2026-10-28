import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { callbackCode, newAttempt, parseAttempt, pkceChallenge } from '../src/lib/oauth';
import { parseStoredAuth } from '../src/lib/auth-state';
import type { Session } from '../src/lib/backend';

const origin = 'https://reader.example.test';
const scope = { url: 'https://auth.example.test', environment: 'test' };
const key = 'gradstep.test.session', tabKey = 'gradstep.test.oauth.v1';
const account = '11111111-2222-4333-8444-555555555555';
const second = '22222222-3333-4444-8555-666666666666';
const session = (id = account): Session => ({ accessToken: 'test-access', refreshToken: 'test-refresh', expiresAt: Date.now() / 1000 + 3600,
  lifetime: crypto.randomUUID(), user: { id, email: null } });
const wire = (id = account) => ({ access_token: 'accepted-access', refresh_token: 'accepted-refresh', expires_in: 3600, user: { id, email: null } });
const envelope = (s: Session | null = null) => ({ version: 2, origin: scope.url, environment: scope.environment, boundary: crypto.randomUUID(), session: s });
const json = (v: unknown, status = 200) => new Response(JSON.stringify(v), { status, headers: { 'Content-Type': 'application/json' } });
const storage = (map: Map<string, string>) => ({ getItem: vi.fn((key: string) => map.get(key) ?? null),
  setItem: vi.fn((key: string, value: string) => { map.set(key, value); }), removeItem: vi.fn((key: string) => { map.delete(key); }) });
function locks() {
  const queues = new Map<string, Promise<unknown>>();
  return { request: <T>(name: string, options: { signal?: AbortSignal }, fn: () => Promise<T> | T) => {
    const task = (queues.get(name) ?? Promise.resolve()).then(() => { options.signal?.throwIfAborted(); return fn(); });
    queues.set(name, task.catch(() => {})); return task;
  } };
}
async function setup(raw: string | null = null, initialize = true) {
  const values = new Map<string, string>(), tabs = new Map<string, string>();
  if (raw !== null) values.set(key, raw);
  const local = storage(values), tab = storage(tabs);
  vi.stubGlobal('localStorage', local); vi.stubGlobal('sessionStorage', tab);
  vi.stubGlobal('window', new EventTarget()); vi.stubGlobal('navigator', { locks: locks() });
  vi.stubGlobal('location', { pathname: '/', origin, href: origin + '/' });
  vi.stubEnv('VITE_SUPABASE_URL', scope.url); vi.stubEnv('VITE_SUPABASE_ANON_KEY', 'public-fixture-key'); vi.stubEnv('VITE_ENVIRONMENT', 'test');
  vi.stubEnv('VITE_GOOGLE_OAUTH_ENABLED', 'true'); vi.stubEnv('VITE_APPLE_OAUTH_ENABLED', 'false');
  const module = await import('../src/lib/backend');
  if (initialize) await module.auth.initialize();
  const notify = (newValue: string | null, eventKey: string | null = key) => {
    const event = new Event('storage'); Object.assign(event, { key: eventKey, newValue }); window.dispatchEvent(event);
  };
  return { ...module, values, tabs, local, tab, notify };
}
beforeEach(() => { vi.resetModules(); });
afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

describe('strict code-only PKCE', () => {
  it('matches the published S256 vector and creates a fresh 32-byte verifier', async () => {
    expect(await pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk')).toBe('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    const a = newAttempt('google', scope, origin, crypto.randomUUID());
    expect(a.verifier).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(parseAttempt(JSON.stringify(a), scope, origin)).toEqual(a);
    expect(newAttempt('google', scope, origin, crypto.randomUUID()).verifier).not.toBe(a.verifier);
    expect(callbackCode(origin + '/auth/callback?code=code_1-2.3~4', origin)).toBe('code_1-2.3~4');
  });
  it.each([
    '/auth/callback?code=a&code=b', '/auth/callback?code=a#', '/auth/callback?code=a#access_token=secret',
    '/auth/callback?access_token=secret', '/auth/callback?code=a&refresh_token=secret', '/auth/callback?code=a&unknown=b',
    '/auth/%63allback?code=a', '/auth/callback/?code=a', '/auth/callback?code=a%20b', '/auth/callback?code=',
    '/auth/callback?code=a&error=access_denied', '/auth/callback?code=' + 'a'.repeat(2049),
  ])('refuses malformed callback %s', path => { expect(() => callbackCode(origin + path, origin)).toThrow('oauth_rejected'); });
  it('rejects another origin/userinfo and maps denial without exposing provider descriptions', () => {
    expect(() => callbackCode('https://wrong.test/auth/callback?code=a', origin)).toThrow('oauth_rejected');
    expect(() => callbackCode('https://user@reader.example.test/auth/callback?code=a', origin)).toThrow('oauth_rejected');
    expect(() => callbackCode(origin + '/auth/callback?error=access_denied&error_description=private', origin)).toThrow('oauth_cancelled');
  });
  it('bounds attempt scope, expiry, backward clocks, verifier and unknown fields', () => {
    const a = newAttempt('apple', scope, origin, crypto.randomUUID(), 1_000_000);
    for (const change of [{ origin: 'https://wrong.test' }, { environment: 'other' }, { callback: origin + '/wrong' },
      { verifier: 'a'.repeat(42) }, { verifier: 43 }, { boundary: 'x' }, { future: true }, { version: 2 }])
      expect(() => parseAttempt(JSON.stringify({ ...a, ...change }), scope, origin, a.createdAt)).toThrow();
    expect(() => parseAttempt(JSON.stringify(a), scope, origin, a.createdAt - 1)).toThrow('oauth_expired');
    expect(() => parseAttempt(JSON.stringify(a), scope, origin, a.expiresAt)).toThrow('oauth_expired');
  });
});

describe('one session envelope authority', () => {
  it('adopts a bounded legacy login only at ordinary startup and preserves lifetime', async () => {
    const old = session(); const { auth, values } = await setup(JSON.stringify(old), false);
    expect(auth.session()).toBeNull(); await auth.initialize();
    expect(auth.session()).toEqual(old); expect(JSON.parse(values.get(key)!)).toMatchObject({ version: 2, session: old });
    const saved = auth.snapshot(); expect(auth.persistedCurrent(saved)).toBe(true);
    values.set(key, JSON.stringify(envelope({ ...old, lifetime: crypto.randomUUID() })));
    expect(auth.persistedCurrent(saved)).toBe(false); // no storage event needed for key admission
  });
  it.each(['{"version":99,"secret":"keep"}', '{broken', JSON.stringify({ ...session(), user: { id: 'not-a-uuid', email: null } })])(
    'preserves malformed/future bytes and refuses all writes: %s', async raw => {
      const { auth, values } = await setup(raw);
      expect(auth.session()).toBeNull();
      await expect(auth.verifyCode('reader@test.example', '123456')).rejects.toMatchObject({ issue: 'auth_storage' });
      await expect(auth.beginOAuth('google', origin)).rejects.toMatchObject({ issue: 'auth_storage' });
      await expect(auth.signOut()).rejects.toMatchObject({ issue: 'auth_storage' });
      expect(values.get(key)).toBe(raw);
    });
  it('never adopts or initializes a callback whose raw/missing envelope was overwritten by legacy code', async () => {
    const { auth, values, tabs } = await setup();
    const started = await auth.beginOAuth('google', origin);
    const raw = JSON.stringify(session(second)); values.set(key, raw);
    vi.resetModules(); vi.stubGlobal('location', { pathname: '/auth/callback', origin });
    const fresh = (await import('../src/lib/backend')).auth;
    await fresh.initialize(); // callback guard must precede adoption
    expect(values.get(key)).toBe(raw); expect(fresh.session()).toBeNull();
    await expect(fresh.completeOAuth(origin + '/auth/callback?code=old', origin)).rejects.toThrow();
    expect(values.get(key)).toBe(raw); expect(tabs.has(tabKey)).toBe(true);
    values.delete(key); // legacy login then logout while away
    await expect(fresh.completeOAuth(origin + '/auth/callback?code=old', origin)).rejects.toThrow();
    expect(values.has(key)).toBe(false); expect(started.attempt.id).toBeDefined();
  });
  it.each([null, JSON.stringify(session())])('late legacy removal/raw event retires despite a newer saved envelope: %s', async payload => {
    const { auth, values, notify } = await setup(JSON.stringify(envelope(session())));
    const old = auth.snapshot(); const newer = envelope(session(second)); values.set(key, JSON.stringify(newer));
    notify(payload);
    expect(old.signal.aborted).toBe(true); expect(auth.session()?.user.id).toBe(second);
    expect(auth.snapshot().generation).toBeGreaterThan(old.generation);
  });
  it('sign-out hides immediately, falls back to removal on quota, and reports denied removal', async () => {
    const { auth, local, values } = await setup(JSON.stringify(envelope(session())));
    const old = auth.snapshot();
    local.setItem.mockImplementation(() => { throw new DOMException('Quota', 'QuotaExceededError'); });
    vi.stubGlobal('fetch', vi.fn(async () => new Response(null, { status: 204 })));
    const leaving = auth.signOut(); expect(auth.session()).toBeNull(); expect(old.signal.aborted).toBe(true);
    await leaving; expect(values.has(key)).toBe(false);
    const secondLogin = envelope(session()); values.set(key, JSON.stringify(secondLogin));
    window.dispatchEvent(Object.assign(new Event('storage'), { key, newValue: JSON.stringify(secondLogin) }));
    local.removeItem.mockImplementation(() => { throw new DOMException('Denied', 'SecurityError'); });
    await expect(auth.signOut()).rejects.toMatchObject({ issue: 'auth_storage' });
    expect(auth.session()).toBeNull(); expect(auth.snapshot().issue).toBe('auth_storage');
    expect(values.get(key)).toBe(JSON.stringify(secondLogin));
  });
  it('does not publish OAuth credentials when the atomic session write fails', async () => {
    const { auth, local, values } = await setup(); await auth.beginOAuth('google', origin);
    const reply = Promise.withResolvers<Response>(); vi.stubGlobal('fetch', vi.fn(() => reply.promise));
    const pending = auth.completeOAuth(origin + '/auth/callback?code=one', origin).catch(e => e);
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    local.setItem.mockImplementation(() => { throw new DOMException('Quota', 'QuotaExceededError'); });
    reply.resolve(json(wire())); expect(await pending).toMatchObject({ issue: 'auth_storage' });
    expect(auth.session()).toBeNull(); expect(JSON.parse(values.get(key)!).oauth.phase).toBe('claimed');
  });
  it('validates token expiry, UUID, size and nullable email before session acceptance', () => {
    const good = envelope(session()); expect(parseStoredAuth(JSON.stringify(good), scope).kind).toBe('envelope');
    for (const changed of [{ expiresAt: null }, { accessToken: 'a'.repeat(16385) }, { refreshToken: 'a\nb' },
      { user: { id: account, email: 'a'.repeat(321) } }])
      expect(parseStoredAuth(JSON.stringify({ ...good, session: { ...good.session, ...changed } }), scope).kind).toBe('invalid');
  });
});

describe('redirect and exchange ownership', () => {
  it('uses the exact callback and once-only bounded PKCE exchange, including duplicate completion', async () => {
    const { auth, tabs, values } = await setup(); const start = await auth.beginOAuth('google', origin);
    const destination = new URL(start.url);
    expect(destination.origin).toBe(scope.url); expect(destination.pathname).toBe('/auth/v1/authorize');
    expect(destination.searchParams.get('redirect_to')).toBe(origin + '/auth/callback');
    expect(destination.searchParams.get('code_challenge_method')).toBe('s256');
    expect(destination.searchParams.get('code_challenge')).toBe(await pkceChallenge(start.attempt.verifier));
    const reply = Promise.withResolvers<Response>(); const fetcher = vi.fn(() => reply.promise); vi.stubGlobal('fetch', fetcher);
    const first = auth.completeOAuth(origin + '/auth/callback?code=one', origin);
    await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(1));
    expect(tabs.has(tabKey)).toBe(false);
    await expect(auth.completeOAuth(origin + '/auth/callback?code=one', origin)).rejects.toThrow();
    const [url, init] = fetcher.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe(scope.url + '/auth/v1/token?grant_type=pkce');
    expect(init).toMatchObject({ redirect: 'error', credentials: 'omit', referrerPolicy: 'no-referrer', cache: 'no-store' });
    expect(JSON.parse(init.body as string)).toEqual({ auth_code: 'one', code_verifier: start.attempt.verifier });
    reply.resolve(json(wire())); await first;
    expect(auth.session()).toMatchObject({ user: { id: account, email: null } });
    expect(JSON.parse(values.get(key)!)).toMatchObject({ version: 2, session: { user: { id: account } } });
    expect(fetcher).toHaveBeenCalledTimes(1);
  });
  it.each(['new-login', 'login-logout', 'legacy-login-logout', 'storage-clear'])('refuses %s while away, without a token request', async change => {
    const { auth, values } = await setup(); await auth.beginOAuth('google', origin);
    if (change === 'new-login') values.set(key, JSON.stringify(envelope(session(second))));
    else if (change === 'login-logout') { values.set(key, JSON.stringify(envelope(session(second)))); values.set(key, JSON.stringify(envelope())); }
    else { values.set(key, JSON.stringify(session(second))); values.delete(key); }
    const saved = values.get(key); vi.stubGlobal('fetch', vi.fn());
    await expect(auth.completeOAuth(origin + '/auth/callback?code=old', origin)).rejects.toThrow();
    expect(fetch).not.toHaveBeenCalled(); expect(values.get(key)).toBe(saved);
  });
  it.each([200, 400])('a delayed exchange (%s) cannot overwrite a newer login or signed-out boundary', async status => {
    const { auth, values } = await setup(); await auth.beginOAuth('google', origin);
    const reply = Promise.withResolvers<Response>(); vi.stubGlobal('fetch', vi.fn(() => reply.promise));
    const pending = auth.completeOAuth(origin + '/auth/callback?code=old', origin).catch(e => e);
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    const newer = JSON.stringify(envelope(status === 200 ? session(second) : null)); values.set(key, newer);
    reply.resolve(json(wire(), status)); expect(await pending).toMatchObject({ issue: 'oauth_rejected' });
    expect(values.get(key)).toBe(newer);
  });
  it('expired/malformed callback retires only its owned attempt and deletes the verifier', async () => {
    const { auth, values, tabs } = await setup(); await auth.beginOAuth('google', origin);
    vi.stubGlobal('fetch', vi.fn());
    await expect(auth.completeOAuth(origin + '/auth/callback?code=x#token', origin)).rejects.toThrow('oauth_rejected');
    expect(JSON.parse(values.get(key)!).oauth).toBeUndefined(); expect(tabs.has(tabKey)).toBe(false); expect(fetch).not.toHaveBeenCalled();
  });
  it('new provider choice survives an older suspended start being cancelled', async () => {
    const { auth, tabs, values } = await setup();
    const firstDigest = Promise.withResolvers<ArrayBuffer>(), started = Promise.withResolvers<void>();
    const digest = crypto.subtle.digest.bind(crypto.subtle); let calls = 0;
    vi.spyOn(crypto.subtle, 'digest').mockImplementation((algorithm, data) => { if (++calls === 1) { started.resolve(); return firstDigest.promise; } return digest(algorithm, data); });
    const old = auth.beginOAuth('google', origin).catch(e => e); await started.promise;
    const latest = await auth.beginOAuth('google', origin);
    firstDigest.resolve(new Uint8Array(32).buffer); await old;
    expect(JSON.parse(values.get(key)!).oauth.id).toBe(latest.attempt.id);
    expect(JSON.parse(tabs.get(tabKey)!).id).toBe(latest.attempt.id); expect(auth.canRedirect(latest.attempt)).toBe(true);
    vi.restoreAllMocks();
  });
  it('a fresh explicit method prevents a delayed exchange from accepting; cancellation does not send again', async () => {
    const { auth, values } = await setup(); await auth.beginOAuth('google', origin);
    const reply = Promise.withResolvers<Response>(); vi.stubGlobal('fetch', vi.fn(() => reply.promise));
    const cancel = new AbortController();
    const pending = auth.completeOAuth(origin + '/auth/callback?code=old', origin, cancel.signal).catch(e => e);
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    cancel.abort(); const next = await auth.beginOAuth('google', origin); reply.resolve(json(wire()));
    expect(await pending).toMatchObject({ issue: 'oauth_rejected' }); expect(JSON.parse(values.get(key)!).oauth.id).toBe(next.attempt.id);
    expect(fetch).toHaveBeenCalledTimes(1);
  });
  it('Back/normal return clears only this tab’s redirect; reload during claim cannot repeat it', async () => {
    const { auth, tabs, values } = await setup(); const first = await auth.beginOAuth('google', origin);
    await auth.returnedToApp(origin); expect(tabs.has(tabKey)).toBe(false); expect(JSON.parse(values.get(key)!).oauth).toBeUndefined();
    expect(auth.canRedirect(first.attempt)).toBe(false);
    await auth.beginOAuth('google', origin);
    const reply = Promise.withResolvers<Response>(); vi.stubGlobal('fetch', vi.fn(() => reply.promise));
    const pending = auth.completeOAuth(origin + '/auth/callback?code=one', origin);
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    vi.resetModules(); const reloaded = (await import('../src/lib/backend')).auth;
    await expect(reloaded.completeOAuth(origin + '/auth/callback?code=one', origin)).rejects.toThrow();
    expect(fetch).toHaveBeenCalledTimes(1); reply.resolve(json(wire())); await pending;
  });
  it('requires separately enabled Apple and refuses storage/lock failures before navigation', async () => {
    const { auth, tab, values } = await setup(); const saved = values.get(key);
    await expect(auth.beginOAuth('apple', origin)).rejects.toMatchObject({ issue: 'oauth_unavailable' });
    tab.setItem.mockImplementation(() => { throw new DOMException('Denied', 'SecurityError'); });
    await expect(auth.beginOAuth('google', origin)).rejects.toMatchObject({ issue: 'auth_storage' }); expect(values.get(key)).toBe(saved);
    vi.stubGlobal('navigator', {});
    await expect(auth.beginOAuth('google', origin)).rejects.toMatchObject({ issue: 'oauth_unavailable' });
  });
});
