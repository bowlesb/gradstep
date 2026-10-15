// Base64 without atob/btoa: the compiler runs in a bare JavaScriptCore context.
const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const LOOKUP = new Int16Array(128).fill(-1);
for (let i = 0; i < ALPHABET.length; i++) LOOKUP[ALPHABET.charCodeAt(i)] = i;

export function encodeBase64(bytes: Uint8Array): string {
  const parts: string[] = [];
  let chunk = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i], b = bytes[i + 1], c = bytes[i + 2];
    const n = (a << 16) | ((b ?? 0) << 8) | (c ?? 0);
    chunk += ALPHABET[(n >> 18) & 63] + ALPHABET[(n >> 12) & 63] + (i + 1 < bytes.length ? ALPHABET[(n >> 6) & 63] : '=') + (i + 2 < bytes.length ? ALPHABET[n & 63] : '=');
    if (chunk.length >= 8192) { parts.push(chunk); chunk = ''; }
  }
  parts.push(chunk);
  return parts.join('');
}

export function decodeBase64(text: string, maximum: number): Uint8Array {
  if (typeof text !== 'string' || text.length % 4 !== 0 || text.length / 4 * 3 > maximum + 2) throw new Error('base64_limit');
  const padding = text.endsWith('==') ? 2 : text.endsWith('=') ? 1 : 0;
  const out = new Uint8Array(text.length / 4 * 3 - padding);
  let o = 0;
  for (let i = 0; i < text.length; i += 4) {
    const v = [0, 1, 2, 3].map(k => {
      const code = text.charCodeAt(i + k);
      if (code === 61 && i + 4 === text.length && k >= 4 - padding) return 0;
      const value = code < 128 ? LOOKUP[code] : -1;
      if (value < 0) throw new Error('base64_invalid');
      return value;
    });
    const n = (v[0] << 18) | (v[1] << 12) | (v[2] << 6) | v[3];
    if (o < out.length) out[o++] = (n >> 16) & 255;
    if (o < out.length) out[o++] = (n >> 8) & 255;
    if (o < out.length) out[o++] = n & 255;
  }
  if (out.length > maximum) throw new Error('base64_limit');
  return out;
}
