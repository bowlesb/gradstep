// Byte helpers shared by the wire format, transport and bundle verification.
// Strict decoders: anything the Swift decoders would refuse is refused here too.

export type Bytes = Uint8Array<ArrayBuffer>;

const encoder = new TextEncoder();
export const utf8 = (text: string): Bytes => encoder.encode(text) as Bytes;
export const fromUtf8 = (bytes: Uint8Array): string => new TextDecoder('utf-8', { fatal: true }).decode(bytes);

export function concat(...parts: Uint8Array[]): Bytes {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) { out.set(part, offset); offset += part.length; }
  return out;
}

export function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export const toHex = (bytes: Uint8Array): string => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');

export function fromHex(hex: string): Bytes | null {
  if (hex.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(hex)) return null;
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

/** PostgREST `bytea` transport: `\x` followed by hexadecimal bytes. */
export const toBytea = (bytes: Uint8Array): string => '\\x' + toHex(bytes);
export function fromBytea(value: unknown): Bytes {
  if (typeof value !== 'string' || !value.startsWith('\\x')) throw new Error('corrupt_data');
  const bytes = fromHex(value.slice(2));
  if (!bytes) throw new Error('corrupt_data');
  return bytes;
}

/** Standard padded base64, as Foundation's `Data(base64Encoded:)` accepts it. */
export function toBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}
export function fromBase64(value: unknown): Bytes {
  if (typeof value !== 'string' || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) throw new Error('corrupt_data');
  const binary = atob(value);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

export function randomBytes(count: number): Bytes {
  return crypto.getRandomValues(new Uint8Array(count));
}

export async function sha256(bytes: Uint8Array): Promise<Bytes> {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as Bytes));
}
export const sha256Hex = async (bytes: Uint8Array): Promise<string> => toHex(await sha256(bytes));

/** Lowercase canonical UUID text, as used in every authenticated context string. */
export function wireUUID(value: string): string {
  const lower = value.toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(lower)) throw new Error('invalid_uuid');
  return lower;
}
export const isUUID = (value: unknown): value is string =>
  typeof value === 'string' && /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(value);

/** Sorted-key JSON, the encoding the Node/Swift fixtures use (key order is not part of the contract). */
export function canonicalJSON(value: unknown): string {
  const sort = (v: unknown): unknown => Array.isArray(v) ? v.map(sort)
    : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map(k => [k, sort((v as Record<string, unknown>)[k])])) : v;
  return JSON.stringify(sort(value));
}
