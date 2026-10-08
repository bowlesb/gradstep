// Regressions for session changes and bounded/cancelled requests. No live backend calls.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Session } from '../src/lib/backend';

const first = '11111111-2222-4333-8444-555555555555';
const second = '22222222-3333-4444-8555-666666666666';
const savedSession = (id = first, expiresAt = Date.now() / 1000 + 3600): Session => ({
  accessToken: 'old-access', refreshToken: 'old-refresh', expiresAt, lifetime: 'fixture-login', user: { id, email: 'reader@example.test' },
});
const wireSession = (id = first) => ({ access_token: 'new-access', refresh_token: 'new-refresh', expires_in: 3600,
  user: { id, email: 'reader@example.test' } });
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

async function setup(session: Session | null = savedSession()) {
  const values = new Map<string, string>();
  if (session) values.set('gradstep.test.session', JSON.stringify(session));
  vi.stubGlobal('localStorage', { getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value), removeItem: (key: string) => values.delete(key) });
  vi.stubGlobal('window', new EventTarget());
  vi.stubGlobal('navigator', { locks: { request: async (_name: string, _options: unknown, body: () => Promise<unknown>) => body() } });
  vi.stubEnv('VITE_SUPABASE_URL', 'https://fixture.invalid');
  vi.stubEnv('VITE_SUPABASE_ANON_KEY', 'fixture-anon');
  vi.stubEnv('VITE_ENVIRONMENT', 'test');
  return { ...await import('../src/lib/backend'), values };
}

beforeEach(() => { vi.resetModules(); });
afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });

describe('authentication lifetimes', () => {
  it.each([first, second].flatMap(id => [200, 400].map(status => ({ id, status }))))('a stale refresh ($status) cannot replace the subsequent login ($id)', async ({ id, status }) => {
    const { auth } = await setup(savedSession(first, 0));
    const reply = Promise.withResolvers<Response>();
    const started = Promise.withResolvers<void>();
    vi.stubGlobal('fetch', vi.fn(async (url: string) => {
      if (url.includes('/token?')) { started.resolve(); return reply.promise; }
      return url.includes('/verify') ? json(wireSession(id)) : new Response(null, { status: 204 });
    }));
    const old = auth.token().catch(error => error);
    await started.promise;
    await auth.signOut();
    await auth.verifyCode('reader@example.test', '123456');
    reply.resolve(json({ ...wireSession(first), access_token: 'stale-access' }, status));
    expect(await old).toMatchObject({ code: 'cancelled' });
    expect(auth.session()).toMatchObject({ accessToken: 'new-access', user: { id } });
  });

  it('preserves the UI lifetime across refresh, and changes it on same-account sign-in', async () => {
    const { auth } = await setup(savedSession(first, 0));
    vi.stubGlobal('fetch', vi.fn(async (url: string) => url.includes('/logout') ? new Response(null, { status: 204 }) : json(wireSession())));
    const initial = auth.snapshot().generation;
    expect(await auth.token()).toBe('new-access');
    expect(auth.snapshot().generation).toBe(initial);
    await auth.signOut();
    await auth.verifyCode('reader@example.test', '123456');
    expect(auth.snapshot().generation).toBeGreaterThan(initial);
  });

  it('retains a cross-tab logout boundary even when storage already contains a new login', async () => {
    const { auth, values } = await setup();
    const initial = auth.snapshot().generation;
    values.set('gradstep.test.session', JSON.stringify(savedSession()));
    const event = new Event('storage');
    Object.assign(event, { key: 'gradstep.test.session', newValue: null });
    window.dispatchEvent(event);
    expect(auth.session()?.user.id).toBe(first);
    expect(auth.snapshot().generation).toBeGreaterThan(initial);
  });

  it('a cross-tab same-account login retires the old signal; a token refresh does not', async () => {
    const { auth, values } = await setup();
    const original = auth.snapshot();
    const storage = (value: Session | null) => {
      if (value) values.set('gradstep.test.session', JSON.stringify(value)); else values.delete('gradstep.test.session');
      const event = new Event('storage');
      Object.assign(event, { key: value ? 'gradstep.test.session' : null, newValue: value && JSON.stringify(value) });
      window.dispatchEvent(event);
    };
    storage({ ...savedSession(), accessToken: 'refreshed' });
    expect(auth.snapshot().generation).toBe(original.generation);
    expect(original.signal.aborted).toBe(false);
    storage({ ...savedSession(), lifetime: 'another-login' });
    expect(original.signal.aborted).toBe(true);
    const signedIn = auth.snapshot();
    storage(null);
    expect(signedIn.signal.aborted).toBe(true);
    expect(auth.session()).toBeNull();
  });

  it('shares one refresh when Web Locks are unavailable', async () => {
    const { auth } = await setup(savedSession(first, 0));
    vi.stubGlobal('navigator', {});
    const reply = Promise.withResolvers<Response>();
    const fetcher = vi.fn(() => reply.promise); vi.stubGlobal('fetch', fetcher);
    const one = auth.token(), two = auth.token();
    expect(fetcher).toHaveBeenCalledTimes(1);
    reply.resolve(json(wireSession()));
    expect(await Promise.all([one, two])).toEqual(['new-access', 'new-access']);
  });

  it('a delayed refresh failure preserves a token another tab refreshed without Web Locks', async () => {
    const { auth, values } = await setup(savedSession(first, 0));
    vi.stubGlobal('navigator', {});
    const reply = Promise.withResolvers<Response>();
    vi.stubGlobal('fetch', vi.fn(() => reply.promise));
    const pending = auth.token();
    values.set('gradstep.test.session', JSON.stringify({ ...savedSession(), accessToken: 'other-tab-access', refreshToken: 'other-tab-refresh' }));
    reply.resolve(json({}, 400));
    expect(await pending).toBe('other-tab-access');
    expect(auth.session()?.accessToken).toBe('other-tab-access');
  });

  it('abandoned verification never publishes a late response', async () => {
    const { auth } = await setup(null);
    const reply = Promise.withResolvers<Response>();
    vi.stubGlobal('fetch', vi.fn(() => reply.promise));
    const controller = new AbortController();
    const pending = auth.verifyCode('reader@example.test', '123456', controller.signal).catch(error => error);
    controller.abort();
    reply.resolve(json(wireSession()));
    expect(await pending).toMatchObject({ issue: 'rejected' });
    expect(auth.session()).toBeNull();
  });

  it('a sign-out that waited for local cleanup cannot sign out a subsequent login', async () => {
    const { auth } = await setup();
    const owner = auth.snapshot();
    const fetcher = vi.fn(async () => json(wireSession(second))); vi.stubGlobal('fetch', fetcher);
    await auth.verifyCode('reader@example.test', '123456');
    await auth.signOut(owner.generation);
    expect(auth.session()?.user.id).toBe(second);
    expect(fetcher).toHaveBeenCalledTimes(1); // verification only, no logout for the new session
  });

  it('a key operation finishing crypto after logout cannot send its next RPC under the new login', async () => {
    const { auth } = await setup();
    const wrapping = Promise.withResolvers<Uint8Array<ArrayBuffer>>(), started = Promise.withResolvers<void>();
    const deviceID = 'aaaaaaaa-0000-4000-8000-000000000001';
    const { generateDeviceKeyPair, generateBundle, generateRecoveryCode } = await import('../src/lib/wire');
    const device = { ...await generateDeviceKeyPair(), origin: 'https://fixture.invalid', accountID: first, deviceID, challenge: new Uint8Array(32),
      localKey: await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']) };
    vi.doMock('../src/lib/idb', async importOriginal => ({ ...await importOriginal<typeof import('../src/lib/idb')>(), idb: { get: async () => device,
      admit: async (key: string, origin: string, lifetime: string, writer: string) => ({ key, origin, lifetime, writer, incarnation: crypto.randomUUID(), generation: 1 }),
      retireWriter: async () => {},
    } }));
    vi.doMock('../src/lib/wire', async importOriginal => ({ ...await importOriginal<typeof import('../src/lib/wire')>(),
      wrapRecovery: () => { started.resolve(); return wrapping.promise; } }));
    try {
      const { bootstrap } = await import('../src/lib/keys');
      const fetcher = vi.fn(async (url: string) => url.includes('/verify') ? json(wireSession()) : new Response(null, { status: 204 }));
      vi.stubGlobal('fetch', fetcher);
      const pending = bootstrap(first, generateBundle(first), generateRecoveryCode()).catch(error => error);
      await started.promise;
      await auth.signOut(); await auth.verifyCode('reader@example.test', '123456');
      wrapping.resolve(new Uint8Array(32));
      expect(await pending).toMatchObject({ name: 'AbortError' });
      expect(fetcher.mock.calls.some(([url]) => url.includes('/rest/'))).toBe(false);
    } finally { vi.doUnmock('../src/lib/idb'); vi.doUnmock('../src/lib/wire'); }
  });

  it('does not send an authorized request after its captured login ends', async () => {
    const { auth, rpc } = await setup();
    const fetcher = vi.fn(async () => new Response(null, { status: 204 }));
    vi.stubGlobal('fetch', fetcher);
    const pending = rpc('v1_key_state', {}, { account: first }).catch(error => error);
    await auth.signOut();
    expect(await pending).toMatchObject({ code: 'cancelled' });
    expect(fetcher.mock.calls).toHaveLength(1); // logout only; no key request
  });
});

describe('request lifetime', () => {
  it('bounded members carry the captured account token; legacy URLs do not', async () => {
    const { signedMember } = await setup();
    const calls: RequestInit[] = [];
    vi.stubGlobal('fetch', vi.fn(async (_url: string, init: RequestInit) => { calls.push(init); return new Response(new Uint8Array([1, 2, 3])); }));
    const target = `https://fixture.invalid/functions/v1/reader-member?grant=${'a'.repeat(64)}&member=${first}`;
    expect(await signedMember(target, 3, undefined, first)).toEqual(new Uint8Array([1, 2, 3]));
    expect(new Headers(calls[0].headers).get('Authorization')).toBe('Bearer old-access');
    expect(calls[0].redirect).toBe('error');
    await signedMember('https://fixture.invalid/storage/v1/object/sign/paper/file?token=legacy', 3);
    expect(new Headers(calls[1].headers).has('Authorization')).toBe(false);
    for (const invalid of [target.replace('fixture.invalid', 'evil.invalid'), target + '&grant=duplicate',
      target.replace('/reader-member?', '/anything?'), target + '#fragment']) {
      await expect(signedMember(invalid, 3, undefined, first)).rejects.toMatchObject({ code: 'reader_integrity_failed' });
    }
    await expect(signedMember(target, 3, undefined, second)).rejects.toMatchObject({ code: 'sign_in_required' });
    expect(calls).toHaveLength(2);
  });

  it.each(['rpc', 'storage'])('%s retains its deadline while a caller signal and a stalled body are present', async kind => {
    vi.useFakeTimers();
    const { rpc, signedMember } = await setup();
    const parent = new AbortController();
    const started = Promise.withResolvers<void>();
    vi.stubGlobal('fetch', vi.fn(async (_url: string, init: RequestInit) => {
      const stream = new ReadableStream({ start(controller) {
        init.signal!.addEventListener('abort', () => controller.error(init.signal!.reason), { once: true });
      } });
      started.resolve();
      return new Response(stream);
    }));
    const pending = (kind === 'rpc' ? rpc('v1_key_state', {}, { account: first, signal: parent.signal })
      : signedMember('https://fixture.invalid/storage/v1/object/sign/paper/file', 100, parent.signal)).catch(error => error);
    await started.promise;
    await vi.advanceTimersByTimeAsync(kind === 'rpc' ? 30_000 : 60_000);
    expect(await pending).toMatchObject({ code: 'connection' });
    expect(parent.signal.aborted).toBe(false);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('caller cancellation interrupts a request before its deadline', async () => {
    vi.useFakeTimers();
    const { rpc } = await setup();
    const parent = new AbortController(), started = Promise.withResolvers<void>();
    vi.stubGlobal('fetch', vi.fn((_url: string, init: RequestInit) => new Promise<Response>((_resolve, reject) => {
      init.signal!.addEventListener('abort', () => reject(init.signal!.reason), { once: true }); started.resolve();
    })));
    const pending = rpc('v1_key_state', {}, { account: first, signal: parent.signal }).catch(error => error);
    await started.promise;
    parent.abort();
    expect(await pending).toMatchObject({ name: 'AbortError' });
    expect(vi.getTimerCount()).toBe(0);
  });
});

describe('chat stream lifetime and bounds', () => {
  it('requests five minutes of token validity and cancels the stream when its consumer ends', async () => {
    const { auth, functionStream } = await setup(savedSession(first, Date.now() / 1000 + 100));
    const cancelled = vi.fn();
    const fetcher = vi.fn(async (url: string) => url.includes('/token?') ? json(wireSession()) : new Response(new ReadableStream({
      start(c) { c.enqueue(new TextEncoder().encode(': ping\n\n')); }, cancel: cancelled,
    }), { headers: { 'Content-Type': 'text/event-stream' } }));
    vi.stubGlobal('fetch', fetcher);
    for await (const _chunk of functionStream('chat', {}, { account: first, signal: new AbortController().signal, maximum: 100, minimumValidity: 300 })) break;
    expect(fetcher).toHaveBeenCalledTimes(2); expect(auth.session()?.accessToken).toBe('new-access'); expect(cancelled).toHaveBeenCalled();
  });
  it('never yields a late chunk after the login is retired', async () => {
    const { auth, functionStream } = await setup();
    let stream!: ReadableStreamDefaultController<Uint8Array>;
    vi.stubGlobal('fetch', vi.fn(async (url: string) => url.includes('/logout') ? new Response(null, { status: 204 }) : new Response(new ReadableStream({ start(c) { stream = c; } }), { headers: { 'Content-Type': 'text/event-stream' } })));
    const iterator = functionStream('chat', {}, { account: first, signal: new AbortController().signal, maximum: 100 });
    const pending = iterator.next().catch(e => e); await vi.waitFor(() => expect(stream).toBeDefined());
    await auth.signOut(); stream.enqueue(new Uint8Array([65]));
    expect(await pending).toMatchObject({ code: 'cancelled' });
  });
  it('rejects an oversized stream and a redirected/non-SSE body without exposing it', async () => {
    const { functionStream } = await setup();
    vi.stubGlobal('fetch', vi.fn(async () => new Response('sensitive error', { headers: { 'Content-Type': 'text/html' } })));
    const consume = async () => { for await (const _ of functionStream('chat', {}, { account: first, signal: new AbortController().signal, maximum: 10 })) { /* consume */ } };
    await expect(consume()).rejects.toMatchObject({ code: 'invalid_response' });
    vi.stubGlobal('fetch', vi.fn(async () => new Response('a'.repeat(11), { headers: { 'Content-Type': 'text/event-stream' } })));
    await expect(consume()).rejects.toMatchObject({ code: 'payload_too_large' });
  });
});
