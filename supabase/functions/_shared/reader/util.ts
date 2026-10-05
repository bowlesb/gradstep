import { createHash } from 'node:crypto';

// Small helpers shared by the renderer and the bundle validator. node:crypto
// and node:zlib are the only runtime modules; both exist in Deno/Edge and Node.

export class ReaderRenderError extends Error {
  readonly code: string;
  constructor(code: string) { super(code); this.name = 'ReaderRenderError'; this.code = code; }
}

export function fail(code: string): never { throw new ReaderRenderError(code); }
export function check(condition: unknown, code: string): asserts condition { if (!condition) fail(code); }

const encoder = new TextEncoder();
export const utf8 = (text: string): Uint8Array => encoder.encode(text);
export function decodeUTF8(bytes: Uint8Array, code = 'utf8_invalid'): string {
  try { return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes); }
  catch { return fail(code); }
}
export function byteLength(text: string): number { return encoder.encode(text).length; }

export function sha256Hex(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex');
}

// Sorted-key JSON plus LF: the same canonical form as reader-bundle-v1 and
// the retained Mathpix raw manifest. Only called with plain JSON values.
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().filter(key => object[key] !== undefined)
      .map(key => `${JSON.stringify(key)}:${canonical(object[key])}`).join(',')}}`;
  }
  check(value === null || typeof value === 'string' || typeof value === 'boolean' ||
    (typeof value === 'number' && Number.isFinite(value)), 'json_value');
  return JSON.stringify(value);
}
export const canonicalBytes = (value: unknown): Uint8Array => utf8(`${canonical(value)}\n`);
export function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let n = 0; n < a.length; n++) if (a[n] !== b[n]) return false;
  return true;
}

export const HEX64 = /^[a-f0-9]{64}$/;
// Bundle member paths: ASCII segments beginning with an alphanumeric.
export function memberPathIsSafe(path: unknown): path is string {
  return typeof path === 'string' && path.length > 0 && path.length <= 240 &&
    path.split('/').every(s => /^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(s) && s !== '.' && s !== '..');
}
export function idIsSafe(id: unknown): id is string {
  return typeof id === 'string' && /^[A-Za-z0-9][A-Za-z0-9_-]{0,199}$/.test(id);
}
// Control characters other than TAB/LF/CR are never admitted into text,
// attributes or index strings.
export const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/;
export function boundedText(text: string, maximum: number, code: string): string {
  check(typeof text === 'string' && !CONTROL.test(text) && byteLength(text) <= maximum, code);
  return text;
}
// Index excerpts may be shorter than the DOM text; they never split a UTF-16
// surrogate pair and always fit the native byte bound.
export function excerpt(text: string, maximum: number): string {
  if (byteLength(text) <= maximum) return text;
  let low = 0, high = Math.min(text.length, maximum);
  while (low < high) {
    const mid = Math.ceil((low + high) / 2);
    if (byteLength(text.slice(0, mid)) <= maximum - 3) low = mid; else high = mid - 1;
  }
  let cut = low;
  const code = text.charCodeAt(cut - 1);
  if (code >= 0xd800 && code <= 0xdbff) cut--;
  return `${text.slice(0, cut)}…`;
}
