// This browser as a device (docs/architecture/BROWSER_READER.md#keys-in-the-browser).
// The algorithm is the native DeviceKeys (apps/apple/ScienceReader/Services/DeviceKeys.swift):
// bootstrap, recovery with a self-approved enrollment, and resumable pending enrollments.
// Device private keys are non-extractable CryptoKeys; key bundles are never persisted.
import { type Bytes, fromBytea, randomBytes, toBytea, wireUUID } from './bytes';
import { auth, config, rpc } from './backend';
import { cancellation } from './cancellation';
import { idb } from './idb';
import { type KeyBundle, type KeyRing, WireError, generateBundle, generateDeviceKeyPair, keyRing, recover as recoverBundle, unwrapForDevice,
  open, seal, wrapForDevice, wrapRecovery } from './wire';

interface Identity { deviceID: string; privateKey: CryptoKey; publicKey: Bytes; challenge: Bytes }
interface Pending { requestID: string; candidate: Identity; envelope: Bytes; epoch: number }
export interface DeviceRecord extends Identity { accountID: string; localKey: CryptoKey; pending?: Pending }
interface KeyState { epoch: number; recovery_package: string; device_envelope: string | null }

export type Preparation = { kind: 'ready'; ring: KeyRing; deviceID: string } | { kind: 'needs_new_keys' } | { kind: 'recovery_required' };

const recordKey = (account: string) => `${config.environment}:${wireUUID(account)}`;
const uuid = () => crypto.randomUUID();

async function newIdentity(): Promise<Identity> {
  const pair = await generateDeviceKeyPair();
  return { deviceID: uuid(), privateKey: pair.privateKey, publicKey: pair.publicKey, challenge: randomBytes(32) };
}

/** Serializes key-changing work for one account across tabs (DeviceKeys' operation lane). */
function keyLock<T>(account: string, body: () => Promise<T>, signal?: AbortSignal): Promise<T> {
  return navigator.locks ? navigator.locks.request(`gradstep.keys.${recordKey(account)}`, { signal }, body) : body();
}
function exclusive<T>(account: string, body: (signal: AbortSignal) => Promise<T>, signal?: AbortSignal): Promise<T> {
  const scope = cancellation([auth.snapshot().signal, signal]);
  const run = async () => { scope.signal.throwIfAborted(); const value = await body(scope.signal); scope.signal.throwIfAborted(); return value; };
  return keyLock(account, run, scope.signal).finally(scope.dispose);
}

/** Signed UI reads the device prepared by the key lane; it must never recreate a forgotten identity. */
export async function readDevice(account: string): Promise<DeviceRecord | undefined> {
  const saved = await idb.get<DeviceRecord>('devices', recordKey(account));
  if (saved && saved.accountID !== wireUUID(account)) throw new WireError('wrong_account');
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
  await idb.put('devices', recordKey(account), record);
  return verifyDevice(account, record, await readDevice(account), signal);
}

async function loadDevice(account: string, signal?: AbortSignal): Promise<DeviceRecord> {
  const saved = await readDevice(account);
  signal?.throwIfAborted();
  if (saved) return verifyDevice(account, saved, saved, signal);
  const identity = await newIdentity();
  const localKey = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const record: DeviceRecord = { ...identity, accountID: wireUUID(account), localKey };
  signal?.throwIfAborted();
  const persisted = await persistDevice(account, record, signal);
  // Ask the browser not to evict this origin's storage (keys live here). Best effort.
  try { await navigator.storage?.persist?.(); } catch { /* not granted */ }
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
    const envelope = saved && saved.epoch === bundle.epoch ? saved.envelope
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
        p_expected_public_key: toBytea(candidate.publicKey), p_expected_challenge: toBytea(candidate.challenge), p_envelope: toBytea(pending.envelope),
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

/** For a shared computer: forget this browser's device keys and reading data for the account. */
export async function forgetDevice(account: string): Promise<void> {
  await keyLock(account, () => idb.forgetDevice(recordKey(account)));
}
