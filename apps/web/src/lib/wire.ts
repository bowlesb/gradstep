// Encrypted wire format 1 (docs/architecture/ENCRYPTED_WIRE_FORMAT.md) with WebCrypto.
// The reference implementation is ScienceReaderCore/Crypto.swift; tests/interop.test.ts
// proves byte compatibility in both directions against the Swift executable.
import { type Bytes, canonicalJSON, concat, fromBase64, fromHex, fromUtf8, randomBytes, sha256, toBase64, toHex, utf8, wireUUID } from './bytes';

const subtle = () => globalThis.crypto.subtle;
export const MAXIMUM_EVENT_BYTES = 262_144;
const INT32_MAX = 2_147_483_647;

export class WireError extends Error {
  constructor(readonly code: 'invalid_key' | 'invalid_recovery_code' | 'wrong_account' | 'unsupported_format' | 'corrupt_data'
    | 'stale_epoch' | 'missing_key' | 'invalid_event' | 'unsupported_browser') { super(code); }
}

/** Fixed nonce/ephemeral inputs for public test vectors only. Production never passes this. */
export interface TestVector { nonce?: Bytes; ephemeralPrivate?: Bytes }

/** The decrypted `KeyBundle`: account identity, current epoch, retained epoch keys, management token. */
export interface KeyBundle { accountID: string; epoch: number; contentKeys: Record<string, Bytes>; managementToken: Bytes }

export function validateBundle(bundle: KeyBundle, accountID: string): void {
  if (wireUUID(bundle.accountID) !== wireUUID(accountID)) throw new WireError('wrong_account');
  const entries = Object.entries(bundle.contentKeys);
  if (!Number.isInteger(bundle.epoch) || bundle.epoch <= 0 || bundle.epoch > INT32_MAX || !bundle.contentKeys[String(bundle.epoch)]
    || bundle.managementToken.length !== 32 || entries.length === 0
    || !entries.every(([key, data]) => /^[1-9][0-9]*$/.test(key) && Number(key) <= bundle.epoch && data.length === 32)) {
    throw new WireError('invalid_key');
  }
}

/** Swift's `KeyBundle` JSON (Codable: UUID text, `Data` as standard base64). */
export function encodeBundle(bundle: KeyBundle): Bytes {
  return utf8(canonicalJSON({
    accountID: bundle.accountID, epoch: bundle.epoch, managementToken: toBase64(bundle.managementToken),
    contentKeys: Object.fromEntries(Object.entries(bundle.contentKeys).map(([k, v]) => [k, toBase64(v)])),
  }));
}
export function decodeBundle(bytes: Uint8Array, accountID: string): KeyBundle {
  let value: unknown;
  try { value = JSON.parse(fromUtf8(bytes)); } catch { throw new WireError('corrupt_data'); }
  const v = value as Record<string, unknown>;
  if (!v || typeof v !== 'object' || typeof v.accountID !== 'string' || typeof v.epoch !== 'number'
    || !v.contentKeys || typeof v.contentKeys !== 'object' || Array.isArray(v.contentKeys)) throw new WireError('corrupt_data');
  let bundle: KeyBundle;
  try {
    bundle = { accountID: v.accountID, epoch: v.epoch, managementToken: fromBase64(v.managementToken),
      contentKeys: Object.fromEntries(Object.entries(v.contentKeys as Record<string, unknown>).map(([k, d]) => [k, fromBase64(d)])) };
  } catch { throw new WireError('corrupt_data'); }
  validateBundle(bundle, accountID);
  return bundle;
}

export function generateBundle(accountID: string): KeyBundle {
  return { accountID: accountID.toUpperCase(), epoch: 1, contentKeys: { '1': randomBytes(32) }, managementToken: randomBytes(32) };
}

// AES-256-GCM combined form: 12-byte nonce, ciphertext, 16-byte tag.
async function aesKey(raw: Bytes, usages: KeyUsage[] = ['encrypt', 'decrypt']): Promise<CryptoKey> {
  if (raw.length !== 32) throw new WireError('invalid_key');
  return subtle().importKey('raw', raw, { name: 'AES-GCM' }, false, usages);
}
export async function seal(key: CryptoKey, plaintext: Bytes, aad: Bytes, nonce: Bytes = randomBytes(12)): Promise<Bytes> {
  if (nonce.length !== 12) throw new WireError('corrupt_data');
  const body = new Uint8Array(await subtle().encrypt({ name: 'AES-GCM', iv: nonce, additionalData: aad, tagLength: 128 }, key, plaintext));
  return concat(nonce, body);
}
export async function open(key: CryptoKey, combined: Bytes, aad: Bytes): Promise<Bytes> {
  if (combined.length < 28) throw new WireError('corrupt_data');
  try {
    return new Uint8Array(await subtle().decrypt({ name: 'AES-GCM', iv: combined.slice(0, 12), additionalData: aad, tagLength: 128 }, key, combined.slice(12)));
  } catch { throw new WireError('corrupt_data'); }
}

// Event envelopes.
export const eventAAD = (account: string, event: string, device: string, epoch: number, format = 1): Bytes =>
  utf8(`science-reader/event/v1\n${wireUUID(account)}\n${wireUUID(event)}\n${wireUUID(device)}\n${epoch}\n${format}\n`);

/** Content keys imported for use only: page code can encrypt/decrypt with them but never read them back. */
export interface KeyRing { accountID: string; epoch: number; keys: Map<number, CryptoKey>; managementToken: Bytes }
export async function keyRing(bundle: KeyBundle): Promise<KeyRing> {
  validateBundle(bundle, bundle.accountID);
  const keys = new Map<number, CryptoKey>();
  for (const [epoch, raw] of Object.entries(bundle.contentKeys)) keys.set(Number(epoch), await aesKey(raw));
  return { accountID: wireUUID(bundle.accountID), epoch: bundle.epoch, keys, managementToken: bundle.managementToken.slice() };
}

export interface EventEnvelope { id: string; deviceID: string; epoch: number; format: number; ciphertext: Bytes }
export async function sealEvent(payload: object, id: string, deviceID: string, ring: KeyRing, vector?: TestVector): Promise<EventEnvelope> {
  const key = ring.keys.get(ring.epoch);
  if (!key) throw new WireError('missing_key');
  const ciphertext = await seal(key, utf8(canonicalJSON(payload)), eventAAD(ring.accountID, id, deviceID, ring.epoch), vector?.nonce);
  if (ciphertext.length > MAXIMUM_EVENT_BYTES) throw new WireError('invalid_event');
  return { id, deviceID, epoch: ring.epoch, format: 1, ciphertext };
}
export async function openEvent(envelope: EventEnvelope, ring: KeyRing): Promise<Record<string, unknown>> {
  if (envelope.format !== 1) throw new WireError('unsupported_format');
  if (envelope.ciphertext.length < 28 || envelope.ciphertext.length > MAXIMUM_EVENT_BYTES) throw new WireError('corrupt_data');
  const key = ring.keys.get(envelope.epoch);
  if (!key) throw new WireError('missing_key');
  const plain = await open(key, envelope.ciphertext, eventAAD(ring.accountID, envelope.id, envelope.deviceID, envelope.epoch, envelope.format));
  let value: unknown;
  try { value = JSON.parse(fromUtf8(plain)); } catch { throw new WireError('corrupt_data'); }
  if (!value || typeof value !== 'object' || Array.isArray(value) || typeof (value as { kind?: unknown }).kind !== 'string') throw new WireError('invalid_event');
  return value as Record<string, unknown>;
}

// Recovery package.
/** 32 random bytes as hex in groups of eight, e.g. `0a1b2c3d-…`. */
export function generateRecoveryCode(): string {
  return toHex(randomBytes(32)).match(/.{8}/g)!.join('-');
}
export function recoveryCodeBytes(code: string): Bytes {
  const bytes = fromHex(code.toLowerCase().replace(/[\s-]/g, ''));
  if (!bytes || bytes.length !== 32) throw new WireError('invalid_recovery_code');
  return bytes;
}
async function hkdfAES(ikm: Bytes, salt: Bytes, info: Bytes, usages: KeyUsage[] = ['encrypt', 'decrypt']): Promise<CryptoKey> {
  const base = await subtle().importKey('raw', ikm, 'HKDF', false, ['deriveKey']);
  return subtle().deriveKey({ name: 'HKDF', hash: 'SHA-256', salt, info }, base, { name: 'AES-GCM', length: 256 }, false, usages);
}
const recoveryKey = (code: string, account: string) =>
  hkdfAES(recoveryCodeBytes(code), utf8(wireUUID(account)), utf8('science-reader/recovery/v1'));
const recoveryAAD = (account: string) => utf8('science-reader/recovery/v1/' + wireUUID(account));

export async function wrapRecovery(bundle: KeyBundle, code: string, vector?: TestVector): Promise<Bytes> {
  validateBundle(bundle, bundle.accountID);
  return seal(await recoveryKey(code, bundle.accountID), encodeBundle(bundle), recoveryAAD(bundle.accountID), vector?.nonce);
}
export async function recover(wrapped: Bytes, code: string, accountID: string): Promise<KeyBundle> {
  const key = await recoveryKey(code, accountID);
  let plain: Bytes;
  try { plain = await open(key, wrapped, recoveryAAD(accountID)); } catch { throw new WireError('invalid_recovery_code'); }
  return decodeBundle(plain, accountID);
}

// Device envelopes: ephemeral-static X25519.
const PKCS8_X25519 = fromHex('302e020100300506032b656e04220420')!;
const SPKI_X25519 = fromHex('302a300506032b656e032100')!;

export async function supportsX25519(): Promise<boolean> {
  try { await subtle().generateKey({ name: 'X25519' }, false, ['deriveBits']); return true; } catch { return false; }
}
/** A device key pair whose private half can never be exported from the browser. */
export async function generateDeviceKeyPair(): Promise<{ privateKey: CryptoKey; publicKey: Bytes }> {
  const pair = await subtle().generateKey({ name: 'X25519' }, false, ['deriveBits']) as CryptoKeyPair;
  return { privateKey: pair.privateKey, publicKey: new Uint8Array(await subtle().exportKey('raw', pair.publicKey)) };
}
/** Public test vectors only: imports raw private bytes (CryptoKit `rawRepresentation`). */
export async function importTestPrivateKey(raw: Bytes): Promise<{ privateKey: CryptoKey; publicKey: Bytes }> {
  const privateKey = await subtle().importKey('pkcs8', concat(PKCS8_X25519, raw), { name: 'X25519' }, true, ['deriveBits']);
  const jwk = await subtle().exportKey('jwk', privateKey);
  return { privateKey, publicKey: fromBase64Url(jwk.x!) };
}
function fromBase64Url(value: string): Bytes {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/');
  return fromBase64(padded + '='.repeat((4 - padded.length % 4) % 4));
}
async function importPublic(raw: Bytes): Promise<CryptoKey> {
  if (raw.length !== 32) throw new WireError('invalid_key');
  try { return await subtle().importKey('spki', concat(SPKI_X25519, raw), { name: 'X25519' }, true, []); }
  catch { throw new WireError('invalid_key'); }
}
async function sharedSecret(privateKey: CryptoKey, publicRaw: Bytes): Promise<Bytes> {
  try { return new Uint8Array(await subtle().deriveBits({ name: 'X25519', public: await importPublic(publicRaw) }, privateKey, 256)); }
  catch { throw new WireError('invalid_key'); }
}
function deviceContext(account: string, device: string, epoch: number, challenge: Bytes): Bytes {
  if (challenge.length !== 32 || !Number.isInteger(epoch) || epoch <= 0) throw new WireError('invalid_key');
  return concat(utf8(`science-reader/device-envelope/v1/${wireUUID(account)}/${wireUUID(device)}/${epoch}/`), challenge);
}

export async function wrapForDevice(bundle: KeyBundle, deviceID: string, recipientPublic: Bytes, challenge: Bytes, vector?: TestVector): Promise<Bytes> {
  validateBundle(bundle, bundle.accountID);
  const ephemeral = vector?.ephemeralPrivate ? await importTestPrivateKey(vector.ephemeralPrivate) : await generateDeviceKeyPair();
  const context = deviceContext(bundle.accountID, deviceID, bundle.epoch, challenge);
  const secret = await sharedSecret(ephemeral.privateKey, recipientPublic);
  const key = await hkdfAES(secret, context, concat(ephemeral.publicKey, recipientPublic));
  const wrapped = await seal(key, encodeBundle(bundle), concat(context, ephemeral.publicKey, recipientPublic), vector?.nonce);
  return concat(ephemeral.publicKey, wrapped);
}

export async function unwrapForDevice(wrapped: Bytes, accountID: string, deviceID: string, epoch: number,
  privateKey: CryptoKey, recipientPublic: Bytes, challenge: Bytes): Promise<KeyBundle> {
  if (wrapped.length < 60 || wrapped.length > 65_536) throw new WireError('corrupt_data');
  const ephemeral = wrapped.slice(0, 32);
  const context = deviceContext(accountID, deviceID, epoch, challenge);
  const secret = await sharedSecret(privateKey, ephemeral);
  const key = await hkdfAES(secret, context, concat(ephemeral, recipientPublic), ['decrypt']);
  const bundle = decodeBundle(await open(key, wrapped.slice(32), concat(context, ephemeral, recipientPublic)), accountID);
  if (bundle.epoch !== epoch) throw new WireError('stale_epoch');
  return bundle;
}

export async function enrollmentFingerprint(accountID: string, deviceID: string, publicKey: Bytes, challenge: Bytes): Promise<string> {
  if (publicKey.length !== 32 || challenge.length !== 32) throw new WireError('invalid_key');
  return toHex(await sha256(concat(utf8(`science-reader/enrollment/v1/${wireUUID(accountID)}/${wireUUID(deviceID)}/`), publicKey, challenge)));
}
