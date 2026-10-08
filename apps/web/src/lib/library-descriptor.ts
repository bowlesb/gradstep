// Encrypted library display descriptors, separate from format-1 history events.
// Contract: docs/architecture/ASSET_SPENDING.md; frozen independent vectors:
// tests/fixtures/library-descriptor/v1.json. This module performs no I/O or caching.
import { type Bytes, canonicalJSON, equal, fromBase64, fromUtf8, sha256Hex, toBase64, utf8 } from './bytes';
import { type KeyRing, type TestVector, WireError, open, seal } from './wire';

const INT32_MAX = 2_147_483_647;
const MAX_PLAINTEXT_BYTES = 4_096;
const MIN_COMBINED_BYTES = 28;
const MAX_COMBINED_BYTES = MAX_PLAINTEXT_BYTES + MIN_COMBINED_BYTES;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export interface LibraryDescriptorPayload { display_name: string; filename?: string }
/** Session account and authorized source, never values inferred from an object path. */
export interface LibraryDescriptorContext { accountID: string; sourceID: string }
export interface LibraryDescriptorWrite extends LibraryDescriptorContext {
  descriptorID: string;
  revision: number;
  mutationID: string;
  deviceID: string;
}
export interface LibraryDescriptorEnvelope {
  descriptor_id: string;
  revision: number;
  mutation_id: string;
  device_id: string;
  epoch: number;
  format: 1;
  ciphertext: string;
  sha256: string;
}
type Header = Omit<LibraryDescriptorEnvelope, 'ciphertext' | 'sha256'>;

function corrupt(): never { throw new WireError('corrupt_data'); }
function record(value: unknown, required: readonly string[], optional: readonly string[] = []): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) corrupt();
  const fields = Object.keys(value);
  if (!required.every(k => fields.includes(k)) || fields.some(k => !required.includes(k) && !optional.includes(k))) corrupt();
  return value as Record<string, unknown>;
}
function canonicalUUID(value: unknown): asserts value is string {
  if (typeof value !== 'string' || value.length !== 36 || !UUID.test(value)) corrupt();
}
function positiveInt32(value: unknown): asserts value is number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 1 || value > INT32_MAX) corrupt();
}
function validateContext(context: LibraryDescriptorContext): void {
  canonicalUUID(context.accountID);
  // The authorized source's grammar is owned by its source kind. Preserve case,
  // but reject ambiguity in the newline-delimited AAD and bound it like source_id.
  if (typeof context.sourceID !== 'string' || context.sourceID.length < 1 || context.sourceID.length > 128
    || /[^\x21-\x7e]/.test(context.sourceID)) corrupt();
}
function validateHeader(header: Header): void {
  canonicalUUID(header.descriptor_id); canonicalUUID(header.mutation_id); canonicalUUID(header.device_id);
  positiveInt32(header.revision); positiveInt32(header.epoch);
  if (header.format !== 1) throw new WireError('unsupported_format');
}

/** This fixed scalar set must not be replaced by trim(), \s, or Unicode categories. */
function whitespace(scalar: number): boolean {
  return (scalar >= 0x09 && scalar <= 0x0d) || scalar === 0x20 || scalar === 0x85 || scalar === 0xa0
    || scalar === 0x1680 || (scalar >= 0x2000 && scalar <= 0x200a) || scalar === 0x2028 || scalar === 0x2029
    || scalar === 0x202f || scalar === 0x205f || scalar === 0x3000;
}
const control = (scalar: number) => scalar <= 0x1f || (scalar >= 0x7f && scalar <= 0x9f);
function scalarOf(character: string): number {
  const scalar = character.codePointAt(0)!;
  // for...of preserves an unpaired UTF-16 surrogate as one code point. Refuse
  // before TextEncoder could silently replace it with U+FFFD.
  if (scalar >= 0xd800 && scalar <= 0xdfff) corrupt();
  return scalar;
}
function displayName(value: unknown): string {
  if (typeof value !== 'string') corrupt();
  const normalized: string[] = [];
  let pendingSpace = false;
  for (const character of value) {
    const scalar = scalarOf(character);
    if (whitespace(scalar)) { pendingSpace = normalized.length > 0; continue; }
    if (control(scalar)) corrupt();
    if (pendingSpace) { normalized.push(' '); pendingSpace = false; }
    normalized.push(character);
    if (normalized.length > 500) corrupt();
  }
  const text = normalized.join('');
  if (normalized.length === 0 || utf8(text).length > 2_000) corrupt();
  return text;
}
function filename(value: unknown): string {
  if (typeof value !== 'string') corrupt();
  let count = 0, visible = false;
  for (const character of value) {
    const scalar = scalarOf(character);
    if (control(scalar) || ++count > 255) corrupt();
    if (!whitespace(scalar)) visible = true;
  }
  if (!visible || utf8(value).length > 1_024) corrupt();
  return value;
}

/** Normalize only on creation/edit. Opening must validate the original canonical bytes unchanged. */
export function normalizeLibraryDescriptor(payload: LibraryDescriptorPayload): LibraryDescriptorPayload {
  const input = record(payload, ['display_name'], ['filename']);
  return {
    display_name: displayName(input.display_name),
    ...(Object.hasOwn(input, 'filename') ? { filename: filename(input.filename) } : {}),
  };
}
function payloadBytes(payload: LibraryDescriptorPayload): Bytes {
  const encoded = utf8(canonicalJSON(payload));
  if (encoded.length > MAX_PLAINTEXT_BYTES) corrupt();
  return encoded;
}

/** Exact AAD, including its final newline. All inputs must already be canonical. */
export function libraryDescriptorAAD(context: LibraryDescriptorContext, header: Header): Bytes {
  validateContext(context); validateHeader(header);
  return utf8(`science-reader/library-descriptor/v1\n${context.accountID}\n${context.sourceID}\n${header.descriptor_id}\n${header.revision}\n${header.mutation_id}\n${header.device_id}\n${header.epoch}\n1\n`);
}
function accountKey(ring: KeyRing, context: LibraryDescriptorContext, epoch: number): CryptoKey {
  validateContext(context);
  if (ring.accountID !== context.accountID) throw new WireError('wrong_account');
  const key = epoch <= ring.epoch ? ring.descriptorKeys.get(epoch) : undefined;
  if (!key) throw new WireError('missing_key');
  return key;
}

/**
 * New mutations use fresh randomness and the current epoch. Persist/replay this exact envelope on retries.
 * `vector` is fixed-nonce injection for public synthetic tests only, following wire.ts's TestVector convention.
 * Application callers must omit it; reusing a GCM nonce with the same key compromises confidentiality.
 */
export async function sealLibraryDescriptor(payload: LibraryDescriptorPayload, binding: LibraryDescriptorWrite,
  ring: KeyRing, vector?: Pick<TestVector, 'nonce'>): Promise<LibraryDescriptorEnvelope> {
  const header: Header = {
    descriptor_id: binding.descriptorID, revision: binding.revision, mutation_id: binding.mutationID,
    device_id: binding.deviceID, epoch: ring.epoch, format: 1,
  };
  const aad = libraryDescriptorAAD(binding, header);
  const key = accountKey(ring, binding, header.epoch);
  const combined = await seal(key, payloadBytes(normalizeLibraryDescriptor(payload)), aad, vector?.nonce);
  return { ...header, ciphertext: toBase64(combined), sha256: await sha256Hex(combined) };
}

/** Retains no plaintext. Callers keep opaque envelopes when keys or this format are unavailable. */
export async function openLibraryDescriptor(envelope: unknown, context: LibraryDescriptorContext,
  ring: KeyRing): Promise<LibraryDescriptorPayload> {
  const value = record(envelope, ['descriptor_id', 'revision', 'mutation_id', 'device_id', 'epoch', 'format', 'ciphertext', 'sha256']);
  const header = value as unknown as Header;
  const aad = libraryDescriptorAAD(context, header);
  if (typeof value.ciphertext !== 'string' || value.ciphertext.length < 40 || value.ciphertext.length > 5_500
    || typeof value.sha256 !== 'string' || value.sha256.length !== 64 || !/^[0-9a-f]{64}$/.test(value.sha256)) corrupt();
  let combined: Bytes;
  try { combined = fromBase64(value.ciphertext); } catch { corrupt(); }
  if (combined.length < MIN_COMBINED_BYTES || combined.length > MAX_COMBINED_BYTES
    || toBase64(combined) !== value.ciphertext || await sha256Hex(combined) !== value.sha256) corrupt();
  const plaintext = await open(accountKey(ring, context, header.epoch), combined, aad);
  if (plaintext.length > MAX_PLAINTEXT_BYTES) corrupt();
  let payload: LibraryDescriptorPayload;
  try { payload = JSON.parse(fromUtf8(plaintext)); } catch { corrupt(); }
  const normalized = normalizeLibraryDescriptor(payload);
  // Compare bytes, not decoded strings: fatal TextDecoder still strips an initial
  // UTF-8 BOM, and equivalent JSON spellings (duplicates/escapes/order) are refused.
  if (!equal(plaintext, payloadBytes(normalized))) corrupt();
  return normalized;
}
