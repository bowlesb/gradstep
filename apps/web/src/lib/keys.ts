// This browser as a device (docs/architecture/BROWSER_READER.md#keys-in-the-browser).
// The algorithm is the native DeviceKeys (apps/apple/ScienceReader/Services/DeviceKeys.swift):
// bootstrap, recovery with a self-approved enrollment, and resumable pending enrollments.
// Device private keys are non-extractable CryptoKeys; key bundles are never persisted.
import { type Bytes, fromBytea, randomBytes, toBytea, wireUUID } from './bytes';
import { config, rpc } from './backend';
import { idb } from './idb';
import { type KeyBundle, type KeyRing, WireError, generateDeviceKeyPair, keyRing, recover as recoverBundle, unwrapForDevice,
  wrapForDevice, wrapRecovery } from './wire';

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
function exclusive<T>(account: string, body: () => Promise<T>): Promise<T> {
  return navigator.locks ? navigator.locks.request(`gradstep.keys.${recordKey(account)}`, body) : body();
}

export async function loadDevice(account: string): Promise<DeviceRecord> {
  const key = recordKey(account);
  const saved = await idb.get<DeviceRecord>('devices', key);
  if (saved) {
    if (saved.accountID !== wireUUID(account)) throw new WireError('wrong_account');
    return saved;
  }
  const identity = await newIdentity();
  const localKey = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const record: DeviceRecord = { ...identity, accountID: wireUUID(account), localKey };
  await idb.put('devices', key, record);
  // Ask the browser not to evict this origin's storage (keys live here). Best effort.
  try { await navigator.storage?.persist?.(); } catch { /* not granted */ }
  return record;
}

const keyState = (account: string, deviceID: string) =>
  rpc<KeyState | null>('v1_key_state', { p_device_id: wireUUID(deviceID) }, { account });

async function unwrapState(account: string, state: KeyState, identity: Identity): Promise<KeyBundle> {
  return unwrapForDevice(fromBytea(state.device_envelope), account, identity.deviceID, state.epoch, identity.privateKey, identity.publicKey, identity.challenge);
}

export function prepare(account: string): Promise<Preparation> {
  return exclusive(account, async () => {
    const record = await loadDevice(account);
    if (record.pending) { const done = await finishApproved(account, record, record.pending); if (done) return done; }
    const state = await keyState(account, record.deviceID);
    if (!state) return { kind: 'needs_new_keys' };
    if (!state.device_envelope) return { kind: 'recovery_required' };
    return { kind: 'ready', ring: await keyRing(await unwrapState(account, state, record)), deviceID: record.deviceID };
  });
}

/** First device of an account: upload the recovery package and this browser's envelope atomically. */
export function bootstrap(account: string, bundle: KeyBundle, code: string): Promise<Preparation> {
  return exclusive(account, async () => {
    const record = await loadDevice(account);
    const recovery = await wrapRecovery(bundle, code);
    const envelope = await wrapForDevice(bundle, record.deviceID, record.publicKey, record.challenge);
    const created = await rpc<boolean>('v1_bootstrap_keys', {
      p_device_id: record.deviceID, p_public_key: toBytea(record.publicKey), p_recovery_package: toBytea(recovery),
      p_management_token: toBytea(bundle.managementToken), p_device_envelope: toBytea(envelope), p_challenge: toBytea(record.challenge),
    }, { account });
    if (created === true) return { kind: 'ready', ring: await keyRing(bundle), deviceID: record.deviceID };
    // A timed-out successful bootstrap is recovered through this exact device envelope;
    // a different first device means this browser must use the recovery code.
    const state = await keyState(account, record.deviceID);
    if (state?.device_envelope) return { kind: 'ready', ring: await keyRing(await unwrapState(account, state, record)), deviceID: record.deviceID };
    return { kind: 'recovery_required' };
  });
}

export function recoverWithCode(account: string, code: string): Promise<Preparation> {
  return exclusive(account, async () => {
    let record = await loadDevice(account);
    let saved = record.pending;
    if (saved) { const done = await finishApproved(account, record, saved); if (done) return done; }
    const state = await keyState(account, record.deviceID);
    if (!state) throw new WireError('missing_key');
    const bundle = await recoverBundle(fromBytea(state.recovery_package), code, account);
    if (bundle.epoch !== state.epoch) throw new WireError('stale_epoch');
    if (saved) {
      // Only a positive revocation record retires a pending recipient.
      const devices = await rpc<{ id: string; revoked_at: string | null }[]>('v1_devices', {}, { account });
      if (devices?.some(d => d.id.toLowerCase() === saved!.candidate.deviceID && d.revoked_at)) saved = undefined;
    }
    const candidate = saved?.candidate ?? await newIdentity();
    const envelope = saved && saved.epoch === bundle.epoch ? saved.envelope
      : await wrapForDevice(bundle, candidate.deviceID, candidate.publicKey, candidate.challenge);
    let pending: Pending = { requestID: saved?.requestID ?? uuid(), candidate, envelope, epoch: bundle.epoch };
    record = { ...record, pending };
    await idb.put('devices', recordKey(account), record);
    await requestEnrollment(account, pending);
    const requests = await rpc<{ id: string }[]>('v1_enrollment_requests', {}, { account });
    if (!requests?.some(r => r.id.toLowerCase() === pending.requestID)) {
      const done = await finishApproved(account, record, pending);
      if (done) return done;
      // An old request may still win after the read above; keep its recipient key.
      pending = { ...pending, requestID: uuid() };
      record = { ...record, pending };
      await idb.put('devices', recordKey(account), record);
      await requestEnrollment(account, pending);
    }
    try {
      await rpc<null>('v1_approve_enrollment', {
        p_request_id: pending.requestID, p_epoch: bundle.epoch, p_management_token: toBytea(bundle.managementToken),
        p_expected_public_key: toBytea(candidate.publicKey), p_expected_challenge: toBytea(candidate.challenge), p_envelope: toBytea(pending.envelope),
      }, { account });
    } catch (error) {
      // The server may have committed, or an older request may have won.
      const done = await finishApproved(account, record, pending).catch(() => null);
      if (done) return done;
      throw error;
    }
    const done = await finishApproved(account, record, pending);
    if (!done) throw new WireError('missing_key');
    return done;
  });
}

async function requestEnrollment(account: string, pending: Pending): Promise<void> {
  const receipt = await rpc<string>('v1_request_enrollment', { p_request_id: pending.requestID, p_device_id: pending.candidate.deviceID,
    p_public_key: toBytea(pending.candidate.publicKey), p_challenge: toBytea(pending.candidate.challenge) }, { account });
  if (typeof receipt !== 'string' || receipt.toLowerCase() !== pending.requestID) throw new WireError('corrupt_data');
}

async function finishApproved(account: string, record: DeviceRecord, pending: Pending): Promise<Preparation | null> {
  const state = await keyState(account, pending.candidate.deviceID);
  if (!state?.device_envelope) return null;
  const bundle = await unwrapState(account, state, pending.candidate);
  // Persist the active device before removing its pending record.
  const active: DeviceRecord = { ...record, ...pending.candidate, pending: undefined };
  delete active.pending;
  await idb.put('devices', recordKey(account), active);
  return { kind: 'ready', ring: await keyRing(bundle), deviceID: active.deviceID };
}

/** For a shared computer: forget this browser's device keys and reading data for the account. */
export async function forgetDevice(account: string): Promise<void> {
  await idb.delete('devices', recordKey(account));
  await idb.delete('activity', recordKey(account));
}
