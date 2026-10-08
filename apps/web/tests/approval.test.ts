// QR device approval, the browser's half: payload/code against the shared public fixture, and the request → poll →
// unwrap flow against an in-memory server with real WebCrypto keys.
import { readFileSync } from 'node:fs';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { accountTag, approvalPayload, comparisonCode, displayCode, qrPath, toBase64Url } from '../src/lib/approval';
import { fromBase64, fromBytea, fromHex, toBytea, toHex } from '../src/lib/bytes';
import { type DeviceRecord, checkApproval, prepare, recoverWithCode, requestApproval } from '../src/lib/keys';
import { generateBundle, generateDeviceKeyPair, generateRecoveryCode, wrapForDevice, wrapRecovery } from '../src/lib/wire';

const fixture = JSON.parse(readFileSync(new URL('../../apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/device-approval-v1.json', import.meta.url), 'utf8'));

describe('payload and comparison code (device-approval-v1.json)', () => {
  it('reproduces the fixture payload, account tag and codes exactly', async () => {
    const result = await approvalPayload({ requestID: fixture.requestID, account: fixture.accountID, deviceID: fixture.deviceID,
      publicKey: fromBase64(fixture.publicKey), challenge: fromBase64(fixture.challenge), kind: 'w' });
    expect(result).toEqual({ payload: fixture.payload, code: fixture.code });
    expect(result.payload).toHaveLength(97);
    expect(toBase64Url(await accountTag(fixture.accountID.toUpperCase()))).toBe(fixture.accountTag);
    for (const [hex, code] of Object.entries(fixture.codeVectors)) expect(await comparisonCode(fromHex(hex)!)).toBe(code);
    expect(displayCode('016434')).toBe('016 434');
  });

  it('draws a QR code locally (version 6, medium error correction for 97 characters)', () => {
    const { size, path } = qrPath(fixture.payload);
    expect(size).toBe(41);
    expect(path).toMatch(/^(M\d+ \d+h1v1h-1z)+$/);
  });
});

// ---------- An in-memory server following migration 002's enrollment contract ----------
const account = '11111111-2222-4333-8444-555555555555';
const login = vi.hoisted(() => ({ signal: new AbortController().signal, generation: 0, session: { user: { id: '11111111-2222-4333-8444-555555555555' }, lifetime: 'test-login' } }));
const storage = vi.hoisted(() => ({ record: undefined as DeviceRecord | undefined }));
const server = vi.hoisted(() => ({
  keyring: null as null | { epoch: number; recovery_package: string },
  devices: new Map<string, { id: string; revoked_at: string | null }>(),
  envelopes: new Map<string, string>(),
  requests: new Map<string, { id: string; device_id: string; public_key: string; challenge: string; expired: boolean; approved: boolean }>(),
  calls: [] as string[],
}));
const rpc = vi.hoisted(() => vi.fn(async (name: string, p: Record<string, string>) => {
  server.calls.push(name);
  switch (name) {
    case 'v1_key_state': return server.keyring && { ...server.keyring,
      device_envelope: server.devices.get(p.p_device_id)?.revoked_at === null ? server.envelopes.get(p.p_device_id) ?? null : null };
    case 'v1_devices': return [...server.devices.values()];
    case 'v1_request_enrollment': {
      const old = server.requests.get(p.p_request_id);
      if (old && (old.public_key !== p.p_public_key || old.challenge !== p.p_challenge)) throw new Error('enrollment_id_conflict');
      if (!old) server.requests.set(p.p_request_id, { id: p.p_request_id, device_id: p.p_device_id, public_key: p.p_public_key,
        challenge: p.p_challenge, expired: false, approved: false });
      return p.p_request_id;
    }
    case 'v1_enrollment_requests': return [...server.requests.values()].filter(r => !r.expired && !r.approved);
    case 'v1_approve_enrollment': {
      const r = server.requests.get(p.p_request_id)!;
      server.devices.set(r.device_id, { id: r.device_id, revoked_at: null });
      server.envelopes.set(r.device_id, p.p_envelope); r.approved = true;
      return null;
    }
  }
  throw new Error('unexpected ' + name);
}));
vi.mock('../src/lib/backend', () => ({ config: { environment: 'test', url: 'https://fixture.example' }, rpc, BackendError: class extends Error {},
  auth: { snapshot: () => login } }));
vi.mock('../src/lib/idb', async importOriginal => ({ ...await importOriginal<typeof import('../src/lib/idb')>(), idb: {
  reapWriters: async () => {},
  admit: async (key: string, origin: string, lifetime: string, writer: string) => ({ key, origin, lifetime, writer, incarnation: crypto.randomUUID(), generation: 1 }),
  retireWriter: async () => {},
  putDevice: async (_fence: unknown, record: DeviceRecord, current: () => boolean) => {
    if (!current()) return false;
    const cloned = structuredClone(record);
    storage.record = cloned; return true;
  },
  get: async () => storage.record && structuredClone(storage.record),
  put: async (_store: string, _key: string, record: DeviceRecord) => { storage.record = structuredClone(record); },
} }));

/** The approving device's side, as the app does it (DeviceApproval.swift; its Swift interop is in interop.test.ts). */
async function approveAs(bundle: ReturnType<typeof generateBundle>, requestID: string, overrideKey?: Uint8Array) {
  const r = server.requests.get(requestID)!;
  const envelope = await wrapForDevice(bundle, r.device_id, overrideKey as never ?? fromBytea(r.public_key), fromBytea(r.challenge));
  await rpc('v1_approve_enrollment', { p_request_id: requestID, p_envelope: toBytea(envelope) });
}

describe('approve this browser from another device', () => {
  const bundle = generateBundle(account), code = generateRecoveryCode();
  beforeEach(async () => {
    storage.record = undefined; server.devices.clear(); server.envelopes.clear(); server.requests.clear(); server.calls = [];
    server.keyring = { epoch: 1, recovery_package: toBytea(await wrapRecovery(bundle, code)) };
    vi.stubGlobal('navigator', { locks: { request: async (_name: string, options: unknown, callback: (lock?: object) => unknown) => callback({}) } }); vi.stubGlobal('localStorage', { getItem: () => JSON.stringify(login.session) });
  });
  afterEach(() => { vi.unstubAllGlobals(); });

  it('shows a payload bound to its pending recipient, then activates the approved envelope', async () => {
    expect(await prepare(account)).toEqual({ kind: 'recovery_required' });
    const step = await requestApproval(account);
    if (step.kind !== 'awaiting_approval') throw new Error(step.kind);
    const candidate = storage.record!.pending!.candidate;
    expect(candidate.privateKey.extractable).toBe(false);
    expect(step.requestID).toBe(storage.record!.pending!.requestID);
    expect(server.requests.get(step.requestID)?.public_key).toBe(toBytea(candidate.publicKey));
    const expected = await approvalPayload({ requestID: step.requestID, account, deviceID: candidate.deviceID, publicKey: candidate.publicKey,
      challenge: candidate.challenge, kind: 'w' });
    expect(step).toMatchObject(expected);
    // Asking again (a reload, another tab) resumes the same request and code.
    expect(await requestApproval(account)).toEqual(step);
    expect(server.requests.size).toBe(1);

    expect(await checkApproval(account)).toBeNull();
    await approveAs(bundle, step.requestID);
    const ready = await checkApproval(account);
    expect(ready).toMatchObject({ kind: 'ready', deviceID: candidate.deviceID });
    expect(ready?.kind === 'ready' && toHex(ready.ring.managementToken)).toBe(toHex(bundle.managementToken));
    expect(storage.record!.pending).toBeUndefined();
    expect(storage.record!.deviceID).toBe(candidate.deviceID);
    expect(await prepare(account)).toMatchObject({ kind: 'ready', deviceID: candidate.deviceID });
  });

  it('renews an expired request for the same recipient, keeping the code; a late approval of the old one still opens', async () => {
    await prepare(account);
    const first = await requestApproval(account);
    if (first.kind !== 'awaiting_approval') throw new Error(first.kind);
    server.requests.get(first.requestID)!.expired = true;
    const second = await requestApproval(account);
    if (second.kind !== 'awaiting_approval') throw new Error(second.kind);
    expect(second.requestID).not.toBe(first.requestID);
    expect(second.code).toBe(first.code);
    expect(second.payload.split('.')[3]).toBe(first.payload.split('.')[3]); // same fingerprint
    await approveAs(bundle, first.requestID);
    expect(await checkApproval(account)).toMatchObject({ kind: 'ready' });
  });

  it('refuses an envelope wrapped for another key and keeps waiting with the same recipient', async () => {
    await prepare(account);
    const step = await requestApproval(account);
    if (step.kind !== 'awaiting_approval') throw new Error(step.kind);
    const attacker = await generateDeviceKeyPair();
    await approveAs(bundle, step.requestID, attacker.publicKey);
    await expect(checkApproval(account)).rejects.toThrow();
    expect(storage.record!.pending?.requestID).toBe(step.requestID); // not activated, not discarded
  });

  it('switching to the recovery code reuses the pending recipient and request', async () => {
    await prepare(account);
    const step = await requestApproval(account);
    if (step.kind !== 'awaiting_approval') throw new Error(step.kind);
    const deviceID = storage.record!.pending!.candidate.deviceID;
    expect(await recoverWithCode(account, code)).toMatchObject({ kind: 'ready', deviceID });
    expect(server.requests.size).toBe(1);
    expect(server.requests.get(step.requestID)?.approved).toBe(true);
  });

  it('an account without keys needs new keys, not approval', async () => {
    server.keyring = null;
    expect(await requestApproval(account)).toEqual({ kind: 'needs_new_keys' });
    expect(server.calls).not.toContain('v1_request_enrollment');
  });
});
