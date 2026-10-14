// Real WebCrypto with a storage boundary that can reproduce malformed, non-null readbacks.
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { type DeviceRecord, bootstrap, prepare } from '../src/lib/keys';
import { generateBundle, generateDeviceKeyPair, generateRecoveryCode } from '../src/lib/wire';

const account = '11111111-2222-4333-8444-555555555555';
const login = vi.hoisted(() => ({ signal: new AbortController().signal, generation: 0, session: { user: { id: '11111111-2222-4333-8444-555555555555' }, lifetime: 'test-login' } }));
const storage = vi.hoisted(() => ({ record: undefined as DeviceRecord | undefined,
  corrupt: undefined as ((record: DeviceRecord) => DeviceRecord) | undefined }));
const rpc = vi.hoisted(() => vi.fn(async () => null));
vi.mock('../src/lib/backend', () => ({ config: { environment: 'test', url: 'https://fixture.example' }, rpc, BackendError: class extends Error {},
  auth: { snapshot: () => login } }));
vi.mock('../src/lib/idb', async importOriginal => ({ ...await importOriginal<typeof import('../src/lib/idb')>(), idb: {
  reapWriters: async () => {},
  admit: async (key: string, origin: string, lifetime: string, writer: string) => ({ key, origin, lifetime, writer, incarnation: crypto.randomUUID(), generation: 1 }),
  retireWriter: async () => {},
  putDevice: async (_fence: unknown, record: DeviceRecord, current: () => boolean) => {
    if (!current()) return false;
    const cloned = structuredClone(record);
    storage.record = storage.corrupt ? storage.corrupt(cloned) : cloned; return true;
  },
  get: async () => storage.record && structuredClone(storage.record),
  put: async (_store: string, _key: string, record: DeviceRecord) => {
    const cloned = structuredClone(record);
    storage.record = storage.corrupt ? storage.corrupt(cloned) : cloned;
  },
} }));

beforeEach(() => { storage.record = undefined; storage.corrupt = undefined; rpc.mockClear(); vi.stubGlobal('navigator', { locks: { request: async (_name: string, options: unknown, callback: (lock?: object) => unknown) => callback({}) } }); vi.stubGlobal('localStorage', { getItem: () => JSON.stringify(login.session) }); });
afterEach(() => { vi.unstubAllGlobals(); });

async function device(): Promise<DeviceRecord> {
  return { ...await generateDeviceKeyPair(), origin: 'https://fixture.example', accountID: account, deviceID: crypto.randomUUID(), challenge: new Uint8Array(32),
    localKey: await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']) };
}

it.each(['extractable private key', 'missing private key', 'mismatched key pair', 'extractable AES key', 'encrypt-only AES key', 'decrypt-only AES key'] as const)(
  'a stored %s remains refused on setup retry and bootstrap', async kind => {
    const replacement = await device();
    const extractable = await crypto.subtle.generateKey({ name: 'X25519' }, true, ['deriveBits']) as CryptoKeyPair;
    const localKey = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, kind === 'extractable AES key',
      kind === 'encrypt-only AES key' ? ['encrypt'] : kind === 'decrypt-only AES key' ? ['decrypt'] : ['encrypt', 'decrypt']);
    storage.corrupt = record => {
      switch (kind) {
        case 'extractable private key': return { ...record, privateKey: extractable.privateKey };
        case 'missing private key': return { ...record, privateKey: null as unknown as CryptoKey };
        case 'mismatched key pair': return { ...record, privateKey: replacement.privateKey };
        default: return { ...record, localKey };
      }
    };
    await expect(prepare(account)).rejects.toMatchObject({ code: 'unsupported_browser' });
    expect(storage.record).toBeDefined(); // failed validation left a non-null record, as the affected engine might
    const deviceID = storage.record!.deviceID;
    await expect(prepare(account)).rejects.toMatchObject({ code: 'unsupported_browser' });
    await expect(bootstrap(account, generateBundle(account), generateRecoveryCode())).rejects.toMatchObject({ code: 'unsupported_browser' });
    expect(rpc).not.toHaveBeenCalled(); // no key-state, bootstrap, enrollment or approval reaches the server
    expect(storage.record!.deviceID).toBe(deviceID); // preserve material instead of silently replacing it
  });

it('validates pending recipients on reload and preserves a rejected pending enrollment', async () => {
  const active = await device(), candidate = await device(), wrongPair = await generateDeviceKeyPair();
  storage.record = { ...active, pending: { requestID: crypto.randomUUID(), epoch: 1, envelope: new Uint8Array(32),
    candidate: { ...candidate, privateKey: wrongPair.privateKey } } };
  const pending = storage.record.pending;
  await expect(prepare(account)).rejects.toMatchObject({ code: 'unsupported_browser' });
  await expect(prepare(account)).rejects.toMatchObject({ code: 'unsupported_browser' });
  expect(storage.record.pending).toBe(pending);
  expect(rpc).not.toHaveBeenCalled();
});

it('accepts a committed usable identity again without replacing it', async () => {
  await expect(prepare(account)).resolves.toEqual({ kind: 'needs_new_keys' });
  const saved = storage.record!;
  expect(saved.privateKey.extractable).toBe(false);
  expect(saved.localKey.extractable).toBe(false);
  await expect(prepare(account)).resolves.toEqual({ kind: 'needs_new_keys' });
  expect(storage.record).toBe(saved);
  expect(rpc).toHaveBeenCalledTimes(2);
});

it.each(['pending', 'denied', 'rejected', 'throws'] as const)('an optional %s storage-persistence request cannot hold up verified key preparation', async outcome => {
  const persist = vi.fn(() => {
    if (outcome === 'throws') throw Error('permission unavailable');
    if (outcome === 'rejected') return Promise.reject(Error('permission denied'));
    if (outcome === 'pending') return new Promise<boolean>(() => {});
    return Promise.resolve(false);
  });
  Object.assign(navigator, { storage: { persist } });
  let timer: ReturnType<typeof setTimeout>;
  try {
    await expect(Promise.race([prepare(account), new Promise((_, reject) => { timer = setTimeout(() => reject(Error('optional permission blocked sign-in')), 500); })]))
      .resolves.toEqual({ kind: 'needs_new_keys' });
  } finally { clearTimeout(timer!); }
  expect(persist).toHaveBeenCalledTimes(1);
  expect(storage.record?.privateKey.extractable).toBe(false);
  expect(storage.record?.localKey.extractable).toBe(false);
  expect(rpc).toHaveBeenCalledTimes(1);
});
