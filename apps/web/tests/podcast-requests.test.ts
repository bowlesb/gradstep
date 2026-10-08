import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { Quote } from '../src/lib/podcast';
const ACCOUNT = '11111111-2222-4333-8444-555555555555';
const ITEM = 'd0000000-0000-4000-8000-000000000001';
const REQUEST = 'c0000000-0000-4000-8000-000000000001';
const QUOTE = 'c0000000-0000-4000-8000-000000000002';
const quote: Quote = { id: QUOTE, expiresAt: 1_900_000_000_000, maxCredits: 150, estimate: 'private server text must not persist',
  providers: ['Anthropic (script)', 'Google Vertex AI (speech)'], consentVersion: 'podcast-private-v1', targetSeconds: 300 };
function memory() {
  const values = new Map<string, string>();
  const storage = { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => { values.set(key, value); },
    removeItem: (key: string) => { values.delete(key); }, get length() { return values.size; }, key: (index: number) => [...values.keys()][index] ?? null };
  return { values, storage };
}
async function setup() {
  const local = memory(), session = memory();
  local.storage.setItem('gradstep.test.session', JSON.stringify({ accessToken: 'access', refreshToken: 'refresh', expiresAt: Date.now() / 1000 + 3600,
    lifetime: 'login-a', user: { id: ACCOUNT, email: 'reader@example.test' } }));
  vi.stubGlobal('localStorage', local.storage); vi.stubGlobal('sessionStorage', session.storage); vi.stubGlobal('window', new EventTarget());
  vi.stubEnv('VITE_SUPABASE_URL', 'https://fixture.invalid'); vi.stubEnv('VITE_SUPABASE_ANON_KEY', 'fixture-anon'); vi.stubEnv('VITE_ENVIRONMENT', 'test');
  const module = await import('../src/lib/podcast-requests'), { auth, config } = await import('../src/lib/backend');
  const owner = auth.snapshot(), ledger = new module.PodcastRequests(ACCOUNT, owner), key = module.podcastRequestsKey(ACCOUNT, 'login-a');
  return { ...module, ...session, local, auth, config, owner, ledger, key };
}
beforeEach(() => vi.resetModules());
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });
it('recovers the exact finite quote after reconstruction and clears only a matching receipt', async () => {
  const { ledger, PodcastRequests, auth, values, key } = await setup();
  ledger.remember(ITEM, REQUEST, quote);
  expect(values.get(key)).not.toContain('private server text'); expect(values.get(key)).not.toContain('Anthropic');
  const recovered = new PodcastRequests(ACCOUNT, auth.snapshot()).get(ITEM)!;
  expect(recovered).toMatchObject({ itemID: ITEM, requestID: REQUEST, quote: { ...quote, estimate: expect.any(String) } });
  ledger.resolve(ITEM, QUOTE); expect(ledger.get(ITEM)).not.toBeNull();
  ledger.resolve(ITEM, REQUEST); expect(ledger.get(ITEM)).toBeNull();
});
it('refuses to replace a different unresolved quote and never evicts at the bound', async () => {
  const { ledger, values, MAX_UNRESOLVED_PODCASTS } = await setup();
  ledger.remember(ITEM, REQUEST, quote); ledger.remember(ITEM, REQUEST, quote);
  expect(() => ledger.remember(ITEM, QUOTE, quote)).toThrow('conflict');
  expect(() => ledger.remember(ITEM, REQUEST, { ...quote, id: REQUEST })).toThrow('conflict');
  for (let i = 2; i <= MAX_UNRESOLVED_PODCASTS; i++) {
    const n = String(i).padStart(12, '0');
    ledger.remember(`d0000000-0000-4000-8000-${n}`, `c0000000-0000-4000-8000-${n}`, quote);
  }
  const before = [...values];
  expect(() => ledger.remember(QUOTE, 'c0000000-0000-4000-8000-000000000099', quote)).toThrow('full');
  expect([...values]).toEqual(before); expect(ledger.get(ITEM)?.requestID).toBe(REQUEST);
});
it('refuses unknown or damaged storage without resetting it or admitting a new request', async () => {
  const { ledger, storage, key, values } = await setup();
  for (const raw of ['{', JSON.stringify({ version: 2, records: [] }), JSON.stringify({ version: 1, records: [{ itemID: ITEM, requestID: REQUEST, quoteID: QUOTE, expiresAt: 10, title: 'private' }] })]) {
    storage.setItem(key, raw);
    expect(() => ledger.get(ITEM)).toThrow('damaged'); expect(() => ledger.remember(ITEM, REQUEST, quote)).toThrow('damaged');
    expect(values.get(key)).toBe(raw);
  }
});
it('requires write and exact read-back before admitting the transport', async () => {
  const { ledger, storage } = await setup();
  const write = vi.spyOn(storage, 'setItem').mockImplementation(() => { throw new DOMException('full', 'QuotaExceededError'); });
  expect(() => ledger.remember(ITEM, REQUEST, quote)).toThrow('unavailable');
  write.mockImplementation(() => {});
  expect(() => ledger.remember(ITEM, REQUEST, quote)).toThrow('unavailable');
  write.mockRestore(); ledger.remember(ITEM, REQUEST, quote);
  vi.spyOn(storage, 'getItem').mockImplementation(() => { throw new DOMException('denied', 'SecurityError'); });
  expect(() => ledger.get(ITEM)).toThrow('unavailable');
});
it('retirement clears the captured lifetime after unmount, and old handles cannot erase a new login', async () => {
  const { ledger, auth, owner, local, key, values, PodcastRequests, podcastRequestsKey, config } = await setup();
  ledger.remember(ITEM, REQUEST, quote);
  const sessionKey = 'gradstep.test.session', next = JSON.parse(local.storage.getItem(sessionKey)!);
  next.lifetime = 'login-b'; local.storage.setItem(sessionKey, JSON.stringify(next));
  window.dispatchEvent(Object.assign(new Event('storage'), { key: sessionKey, newValue: JSON.stringify(next) }));
  expect(owner.signal.aborted).toBe(true); expect(values.has(key)).toBe(false);
  const current = new PodcastRequests(ACCOUNT, auth.snapshot()); current.remember(ITEM, REQUEST, quote);
  expect(() => ledger.resolve(ITEM, REQUEST)).toThrow('retired'); expect(current.get(ITEM)?.requestID).toBe(REQUEST);
  expect(podcastRequestsKey(ACCOUNT, 'login-b')).not.toBe(key);
  expect(podcastRequestsKey(QUOTE, 'login-b')).not.toBe(key);
  config.url = 'https://other.invalid'; expect(new PodcastRequests(ACCOUNT, auth.snapshot()).get(ITEM)).toBeNull();
});

it('a reload can retire stored hints even before any request handle is used', async () => {
  const { ledger, local, values, key } = await setup();
  ledger.remember(ITEM, REQUEST, quote);
  vi.resetModules();
  // Import is the signed-in account boundary; no constructor/get/remember in the reloaded page.
  await import('../src/lib/podcast-requests');
  const { auth } = await import('../src/lib/backend');
  const sessionKey = 'gradstep.test.session', next = JSON.parse(local.storage.getItem(sessionKey)!);
  next.lifetime = 'after-reload'; local.storage.setItem(sessionKey, JSON.stringify(next));
  window.dispatchEvent(Object.assign(new Event('storage'), { key: sessionKey, newValue: JSON.stringify(next) }));
  expect(auth.session()?.lifetime).toBe('after-reload'); expect(values.has(key)).toBe(false);
});
