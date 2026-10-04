import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

export const profile = Object.freeze(JSON.parse(readFileSync(new URL('./profile.json', import.meta.url), 'utf8')));
export const sha256 = value => createHash('sha256').update(value).digest('hex');
export function requireThat(condition, code) { if (!condition) throw new Error(code); }
export function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
  return JSON.stringify(value);
}
export const jsonBytes = value => Buffer.from(`${canonical(value)}\n`);
export function pathIsSafe(path) {
  return typeof path === 'string' && path.length <= 240 && path.split('/').every(s => /^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(s) && s !== '.' && s !== '..');
}
export function idIsSafe(id) { return typeof id === 'string' && /^[A-Za-z0-9][A-Za-z0-9_-]{0,199}$/.test(id); }
export function boundedText(text, code = 'text_limit') {
  requireThat(typeof text === 'string' && !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(text) && Buffer.byteLength(text) <= profile.max_text_bytes, code);
  return text;
}
export const escapeText = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
export const escapeAttr = value => escapeText(String(value)).replaceAll('"', '&quot;');
export function decodeUTF8(bytes) { return new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
