// This browser as a device (docs/architecture/BROWSER_READER.md#keys-in-the-browser).
// The algorithm is the native DeviceKeys (apps/apple/ScienceReader/Services/DeviceKeys.swift):
// bootstrap, recovery with a self-approved enrollment, approval by another device (QR), and resumable pending enrollments.
// Device private keys are non-extractable CryptoKeys; key bundles are never persisted.
import { requestPersistence } from './persistence';
import { type Bytes, fromBytea, randomBytes, toBytea, wireUUID } from './bytes';
import { approvalPayload } from './approval';
import { auth, config, rpc, BackendError, type AuthSnapshot } from './backend';
import { cancellation } from './cancellation';
import { idb, storage, StorageError, type WriterFence } from './idb';
import { type KeyBundle, type KeyRing, WireError, generateBundle, generateDeviceKeyPair, keyRing, recover as recoverBundle, unwrapForDevice,
  open, seal, wrapForDevice, wrapRecovery } from './wire';

interface Identity { deviceID: string; privateKey: CryptoKey; publicKey: Bytes; challenge: Bytes }
/** `envelope`/`epoch`: the self-approval made with the recovery code. A request awaiting another device has neither. */
interface Pending { requestID: string; candidate: Identity; envelope?: Bytes; epoch?: number }
export interface DeviceRecord extends Identity { accountID: string; localKey: CryptoKey; origin?: string; pending?: Pending }
interface KeyState { epoch: number; recovery_package: string; device_envelope: string | null }

export interface PreparedLocal { key: CryptoKey; fence: WriterFence; current: () => boolean }
export type Preparation = { kind: 'ready'; ring: KeyRing; deviceID: string; local?: PreparedLocal } | { kind: 'needs_new_keys' } | { kind: 'recovery_required' };
/** Shown as a QR code and a six-digit comparison code until an approved device adds this browser. */
export interface AwaitingApproval { kind: 'awaiting_approval'; requestID: string; payload: string; code: string }

const recordKey = (account: string) => `${config.environment}:${wireUUID(account)}`;
const uuid = () => crypto.randomUUID();
interface Owner { fence: WriterFence; current: () => boolean }
const owners = new WeakMap<AbortSignal, Promise<Owner>>();
const operationOwners = new WeakMap<AbortSignal, Owner>();
/** A synchronous check is repeated inside each IDB mutation, including after a suspended callback. */
function currentLogin(account: string, captured: AuthSnapshot): boolean {
  const now = auth.snapshot();
  if (captured.signal.aborted || now.signal !== captured.signal || now.session?.user.id !== account || !captured.session) return false;
  try {
    const stored = JSON.parse(localStorage.getItem(`gradstep.${config.environment}.session`) ?? 'null');
    return stored?.user?.id === account && (stored.lifetime ?? 'legacy') === captured.session.lifetime;
  } catch { return false; } // durable admission cannot infer a login from inaccessible storage
}
async function ownerFor(account: string, captured: AuthSnapshot): Promise<Owner> {
  let pending = owners.get(captured.signal);
  if (!pending) {
    const current = () => currentLogin(account, captured);
    pending = (async () => {
      if (!current()) throw new BackendError('sign_in_required');
      const writer = uuid(), key = recordKey(account);
      let release: (() => void) | undefined;
      if (navigator.locks) {
        const prior = await idb.get<{ generation: number; writers: string[] }>('devices', `${key}:admission`);
        const dead: string[] = [];
        for (const id of prior?.writers ?? []) await navigator.locks.request(`gradstep.writer.${id}`, { ifAvailable: true }, lock => { if (lock) dead.push(id); });
        if (dead.length) await idb.reapWriters(key, prior!.generation, dead);
        await new Promise<void>((resolve, reject) => { navigator.locks.request(`gradstep.writer.${writer}`, {}, () => new Promise<void>(done => {
          release = done; resolve();
        })).catch(reject); });
      }
      let fence: WriterFence;
      try { fence = await idb.admit(key, config.url, captured.session!.lifetime, writer, current); }
      catch (error) { release?.(); throw error; }
      const owner = { fence, current };
      captured.signal.addEventListener('abort', () => { void idb.retireWriter(fence).catch(() => {}).finally(() => release?.()); }, { once: true });
      if (!current()) { await idb.retireWriter(fence); release?.(); throw new BackendError('cancelled'); }
      return owner;
    })();
    owners.set(captured.signal, pending);
    pending.catch(() => { if (owners.get(captured.signal) === pending) owners.delete(captured.signal); });
  }
  return pending;
}

async function newIdentity(): Promise<Identity> {
  const pair = await generateDeviceKeyPair();
  return { deviceID: uuid(), privateKey: pair.privateKey, publicKey: pair.publicKey, challenge: randomBytes(32) };
}

/** Serializes key-changing work for one account across tabs (DeviceKeys' operation lane). */
function keyLock<T>(account: string, body: () => Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!navigator.locks) return Promise.reject(new WireError('unsupported_browser'));
  return navigator.locks.request(`gradstep.keys.${recordKey(account)}`, { signal }, body);
}
function exclusive<T>(account: string, body: (signal: AbortSignal) => Promise<T>, signal?: AbortSignal): Promise<T> {
  // A page whose storage was retired by a newer tab starts no key work (and so no enrollment request) at all.
  if (!storage.writable()) return Promise.reject(storageRefusal());
  const captured = auth.snapshot(), scope = cancellation([captured.signal, signal]);
  const run = async () => {
    scope.signal.throwIfAborted();
    if (!storage.writable()) throw storageRefusal();
    const owner = await ownerFor(account, captured);
    operationOwners.set(scope.signal, owner);
    const value = await body(scope.signal); scope.signal.throwIfAborted();
    if (!owner.current()) throw new BackendError('cancelled');
    if (value && typeof value === 'object' && 'kind' in value && value.kind === 'ready') {
      const record = await readDevice(account);
      if (!record || !owner.current()) throw new BackendError('cancelled');
      return { ...value, local: { key: record.localKey, fence: owner.fence, current: owner.current } };
    }
    return value;
  };
  return keyLock(account, run, scope.signal).finally(scope.dispose);
}

function storageRefusal(): StorageError {
  const { issue } = storage.snapshot();
  return new StorageError(issue === 'upgraded' ? 'storage_upgraded' : issue === 'closed' ? 'storage_closed' : 'storage_update');
}

/** Signed UI reads the device prepared by the key lane; it must never recreate a forgotten identity. */
export async function readDevice(account: string): Promise<DeviceRecord | undefined> {
  const saved = await idb.get<DeviceRecord>('devices', recordKey(account));
  if (saved && saved.accountID !== wireUUID(account)) throw new WireError('wrong_account');
  // This is the only deployment to which old environment-only records can be explicitly attributed.
  const legacy = config.environment === 'staging' && config.url === 'https://coxhjvqpflgxkleydati.supabase.co';
  if (saved && (saved.origin ? saved.origin !== config.url : !legacy)) throw new BackendError('local_scope');
  return saved;
}

/** Check existing records too: a failed write check must not become trusted on retry or reload. */
async function verifyDevice(account: string, original: DeviceRecord, saved: DeviceRecord | undefined, signal?: AbortSignal): Promise<DeviceRecord> {
  signal?.throwIfAborted();
  try {
    if (!saved || saved.deviceID !== original.deviceID || saved.localKey.extractable !== false
      || saved.localKey.type !== 'secret' || saved.localKey.algorithm.name !== 'AES-GCM'
      || (saved.localKey.algorithm as AesKeyAlgorithm).length !== 256
      || !saved.localKey.usages.includes('encrypt') || !saved.localKey.usages.includes('decrypt')) throw new Error('key_storage');
    // Use the established envelope format with a disposable bundle. Even on reload this proves that the
    // stored private key matches its public bytes; comparing a derivation to itself would not establish that.
    const probeBundle = generateBundle(account);
    const check = async (original: Identity, restored: Identity) => {
      if (!restored || original.deviceID !== restored.deviceID || restored.privateKey.extractable !== false
        || restored.privateKey.type !== 'private' || restored.privateKey.algorithm.name !== 'X25519') throw new Error('key_storage');
      const envelope = await wrapForDevice(probeBundle, original.deviceID, original.publicKey, original.challenge);
      signal?.throwIfAborted();
      await unwrapForDevice(envelope, account, restored.deviceID, probeBundle.epoch,
        restored.privateKey, restored.publicKey, restored.challenge);
    };
    await check(original, saved);
    if (original.pending) await check(original.pending.candidate, saved.pending!.candidate);
    const probe = randomBytes(16);
    const decoded = await open(saved.localKey, await seal(original.localKey, probe, original.challenge), original.challenge);
    if (decoded.length !== probe.length || !probe.every((v, i) => v === decoded[i])) throw new Error('key_storage');
  } catch { signal?.throwIfAborted(); throw new WireError('unsupported_browser'); }
  signal?.throwIfAborted();
  return saved!;
}

/** Prove committed keys can be read and used before relying on them for server enrollment. */
async function persistDevice(account: string, record: DeviceRecord, signal?: AbortSignal): Promise<DeviceRecord> {
  signal?.throwIfAborted();
  const owner = signal && operationOwners.get(signal);
  if (!owner || !await idb.putDevice(owner.fence, { ...record, origin: config.url }, owner.current)) throw new BackendError('cancelled');
  return verifyDevice(account, record, await readDevice(account), signal);
}

async function loadDevice(account: string, signal?: AbortSignal): Promise<DeviceRecord> {
  const saved = await readDevice(account);
  signal?.throwIfAborted();
  if (saved) return verifyDevice(account, saved, saved, signal);
  const identity = await newIdentity();
  const localKey = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const record: DeviceRecord = { ...identity, accountID: wireUUID(account), localKey, origin: config.url };
  signal?.throwIfAborted();
  const persisted = await persistDevice(account, record, signal);
  // Advisory eviction protection may wait for a permission prompt (e.g. Firefox).
  // The committed key readback above is the admission gate; this optional prompt
  // must not hold the account's key-operation lock or stall sign-in.
  void requestPersistence();
  return persisted;
}

const keyState = (account: string, deviceID: string, signal?: AbortSignal) =>
  rpc<KeyState | null>('v1_key_state', { p_device_id: wireUUID(deviceID) }, { account, signal });

async function unwrapState(account: string, state: KeyState, identity: Identity): Promise<KeyBundle> {
  return unwrapForDevice(fromBytea(state.device_envelope), account, identity.deviceID, state.epoch, identity.privateKey, identity.publicKey, identity.challenge);
}

export function prepare(account: string, signal?: AbortSignal): Promise<Preparation> {
  return exclusive(account, async signal => {
    const record = await loadDevice(account, signal);
    if (record.pending) { const done = await finishApproved(account, record, record.pending, signal); if (done) return done; }
    const state = await keyState(account, record.deviceID, signal);
    if (!state) return { kind: 'needs_new_keys' };
    if (!state.device_envelope) return { kind: 'recovery_required' };
    return { kind: 'ready', ring: await keyRing(await unwrapState(account, state, record)), deviceID: record.deviceID };
  }, signal);
}

/** First device of an account: upload the recovery package and this browser's envelope atomically. */
export function bootstrap(account: string, bundle: KeyBundle, code: string, signal?: AbortSignal): Promise<Preparation> {
  return exclusive(account, async signal => {
    const record = await loadDevice(account, signal);
    const recovery = await wrapRecovery(bundle, code);
    const envelope = await wrapForDevice(bundle, record.deviceID, record.publicKey, record.challenge);
    const created = await rpc<boolean>('v1_bootstrap_keys', {
      p_device_id: record.deviceID, p_public_key: toBytea(record.publicKey), p_recovery_package: toBytea(recovery),
      p_management_token: toBytea(bundle.managementToken), p_device_envelope: toBytea(envelope), p_challenge: toBytea(record.challenge),
    }, { account, signal });
    if (created === true) return { kind: 'ready', ring: await keyRing(bundle), deviceID: record.deviceID };
    // A timed-out successful bootstrap is recovered through this exact device envelope;
    // a different first device means this browser must use the recovery code.
    const state = await keyState(account, record.deviceID, signal);
    if (state?.device_envelope) return { kind: 'ready', ring: await keyRing(await unwrapState(account, state, record)), deviceID: record.deviceID };
    return { kind: 'recovery_required' };
  }, signal);
}

export function recoverWithCode(account: string, code: string, signal?: AbortSignal): Promise<Preparation> {
  return exclusive(account, async signal => {
    let record = await loadDevice(account, signal);
    let saved = record.pending;
    if (saved) { const done = await finishApproved(account, record, saved, signal); if (done) return done; }
    const state = await keyState(account, record.deviceID, signal);
    if (!state) throw new WireError('missing_key');
    const bundle = await recoverBundle(fromBytea(state.recovery_package), code, account);
    if (bundle.epoch !== state.epoch) throw new WireError('stale_epoch');
    if (saved) {
      // Only a positive revocation record retires a pending recipient.
      const devices = await rpc<{ id: string; revoked_at: string | null }[]>('v1_devices', {}, { account, signal });
      if (devices?.some(d => d.id.toLowerCase() === saved!.candidate.deviceID && d.revoked_at)) saved = undefined;
    }
    const candidate = saved?.candidate ?? await newIdentity();
    const envelope = saved?.envelope && saved.epoch === bundle.epoch ? saved.envelope
      : await wrapForDevice(bundle, candidate.deviceID, candidate.publicKey, candidate.challenge);
    let pending: Pending = { requestID: saved?.requestID ?? uuid(), candidate, envelope, epoch: bundle.epoch };
    record = { ...record, pending };
    signal?.throwIfAborted();
    record = await persistDevice(account, record, signal);
    await requestEnrollment(account, pending, signal);
    const requests = await rpc<{ id: string }[]>('v1_enrollment_requests', {}, { account, signal });
    if (!requests?.some(r => r.id.toLowerCase() === pending.requestID)) {
      const done = await finishApproved(account, record, pending, signal);
      if (done) return done;
      // An old request may still win after the read above; keep its recipient key.
      pending = { ...pending, requestID: uuid() };
      record = { ...record, pending };
      signal?.throwIfAborted();
      record = await persistDevice(account, record, signal);
      await requestEnrollment(account, pending, signal);
    }
    try {
      await rpc<null>('v1_approve_enrollment', {
        p_request_id: pending.requestID, p_epoch: bundle.epoch, p_management_token: toBytea(bundle.managementToken),
        p_expected_public_key: toBytea(candidate.publicKey), p_expected_challenge: toBytea(candidate.challenge), p_envelope: toBytea(envelope),
      }, { account, signal });
    } catch (error) {
      // The server may have committed, or an older request may have won.
      const done = await finishApproved(account, record, pending, signal).catch(() => null);
      if (done) return done;
      throw error;
    }
    const done = await finishApproved(account, record, pending, signal);
    if (!done) throw new WireError('missing_key');
    return done;
  }, signal);
}

/**
 * Ask an approved device to add this browser: create (or resume) the pending recipient, make sure the server holds an
 * unexpired request for it — renewing under a new request ID while keeping the same recipient — and return the QR
 * payload. Renewal keeps the fingerprint, so the six-digit code stays the same.
 */
export function requestApproval(account: string, signal?: AbortSignal): Promise<Preparation | AwaitingApproval> {
  return exclusive(account, async signal => {
    let record = await loadDevice(account, signal);
    let saved = record.pending;
    if (saved) { const done = await finishApproved(account, record, saved, signal); if (done) return done; }
    const state = await keyState(account, record.deviceID, signal);
    if (!state) return { kind: 'needs_new_keys' };
    if (state.device_envelope) return { kind: 'ready', ring: await keyRing(await unwrapState(account, state, record)), deviceID: record.deviceID };
    if (saved) {
      // Only a positive revocation record retires a pending recipient.
      const devices = await rpc<{ id: string; revoked_at: string | null }[]>('v1_devices', {}, { account, signal });
      if (devices?.some(d => d.id.toLowerCase() === saved!.candidate.deviceID && d.revoked_at)) saved = undefined;
    }
    let pending: Pending = saved ?? { requestID: uuid(), candidate: await newIdentity() };
    if (pending !== record.pending) { record = await persistDevice(account, { ...record, pending }, signal); }
    await requestEnrollment(account, pending, signal);
    const requests = await rpc<{ id: string }[]>('v1_enrollment_requests', {}, { account, signal });
    if (!requests?.some(r => r.id.toLowerCase() === pending.requestID)) {
      const done = await finishApproved(account, record, pending, signal);
      if (done) return done;
      // Expired: renew with the same recipient, so a late approval of the old request still opens here.
      pending = { ...pending, requestID: uuid() };
      record = await persistDevice(account, { ...record, pending }, signal);
      await requestEnrollment(account, pending, signal);
    }
    const { candidate } = pending;
    const { payload, code } = await approvalPayload({ requestID: pending.requestID, account, deviceID: candidate.deviceID,
      publicKey: candidate.publicKey, challenge: candidate.challenge, kind: 'w' });
    return { kind: 'awaiting_approval', requestID: pending.requestID, payload, code };
  }, signal);
}

/** One poll while awaiting approval: the active keys once another device (or this one, with the code) approved it. */
export function checkApproval(account: string, signal?: AbortSignal): Promise<Preparation | null> {
  return exclusive(account, async signal => {
    const record = await loadDevice(account, signal);
    if (record.pending) return finishApproved(account, record, record.pending, signal);
    const state = await keyState(account, record.deviceID, signal);
    return state?.device_envelope ? { kind: 'ready', ring: await keyRing(await unwrapState(account, state, record)), deviceID: record.deviceID } : null;
  }, signal);
}

async function requestEnrollment(account: string, pending: Pending, signal?: AbortSignal): Promise<void> {
  const receipt = await rpc<string>('v1_request_enrollment', { p_request_id: pending.requestID, p_device_id: pending.candidate.deviceID,
    p_public_key: toBytea(pending.candidate.publicKey), p_challenge: toBytea(pending.candidate.challenge) }, { account, signal });
  if (typeof receipt !== 'string' || receipt.toLowerCase() !== pending.requestID) throw new WireError('corrupt_data');
}

async function finishApproved(account: string, record: DeviceRecord, pending: Pending, signal?: AbortSignal): Promise<Preparation | null> {
  const state = await keyState(account, pending.candidate.deviceID, signal);
  if (!state?.device_envelope) return null;
  const bundle = await unwrapState(account, state, pending.candidate);
  // Persist the active device before removing its pending record.
  const active: DeviceRecord = { ...record, ...pending.candidate, pending: undefined };
  delete active.pending;
  signal?.throwIfAborted();
  await persistDevice(account, active, signal);
  return { kind: 'ready', ring: await keyRing(bundle), deviceID: active.deviceID };
}

/** A deleted account: everything forgetDevice removes, then its coordination record too, so nothing of it remains. */
export async function eraseDeletedAccount(account: string, signal?: AbortSignal): Promise<void> {
  await forgetDevice(account, signal);
  await idb.forgetAdmission(recordKey(account));
}

/** For a shared computer: forget this browser's device keys and reading data for the account. */
export async function forgetDevice(account: string, signal?: AbortSignal): Promise<void> {
  await exclusive(account, async signal => {
    const owner = operationOwners.get(signal)!;
    await idb.forgetDevice(recordKey(account), owner.fence, owner.current);
  }, signal);
}
