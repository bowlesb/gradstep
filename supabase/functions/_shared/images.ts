import { PublicError } from './http.ts';

const crcTable = new Uint32Array(256).map((_, n) => {
  let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0;
});
function crc32(data: Uint8Array) { let c = 0xffffffff; for (const b of data) c = crcTable[(c ^ b) & 255]! ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }
function invalid(): never { throw new PublicError(400, 'invalid_image'); }
/** The largest image accepted: 8,192 px a side and 20 million pixels by default; a caller that scales what it reads
 * (the device reader, which fits every figure to a pixel budget) may accept larger. */
export interface ImageBounds { side: number; pixels: number }
const DEFAULT_BOUNDS: ImageBounds = { side: 8192, pixels: 20_000_000 };
function size(width: number, height: number, bounds: ImageBounds) {
  if (width < 1 || height < 1 || width > bounds.side || height > bounds.side || width * height > bounds.pixels) throw new PublicError(422, 'image_dimensions_exceeded');
  return { width, height };
}

// Check bounded file structure before storage. This intentionally does not
// inflate attacker-controlled pixels. Native clients decode and re-encode the
// preview; reads are constrained image responses with nosniff and no-store.
export function inspectImage(bytes: Uint8Array, bounds: ImageBounds = DEFAULT_BOUNDS): { mediaType: 'image/png' | 'image/jpeg'; width: number; height: number } {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes.length >= 33 && [137,80,78,71,13,10,26,10].every((b, i) => bytes[i] === b)) {
    let at = 8; let chunks = 0; let dataSeen = false; let dimensions: { width: number; height: number } | null = null;
    while (at + 12 <= bytes.length && chunks++ < 10000) {
      const length = view.getUint32(at); const end = at + 12 + length;
      if (end > bytes.length) invalid();
      const name = String.fromCharCode(...bytes.subarray(at + 4, at + 8));
      if (!/^[A-Za-z]{4}$/.test(name) || crc32(bytes.subarray(at + 4, end - 4)) !== view.getUint32(end - 4)) invalid();
      if (chunks === 1 && name !== 'IHDR') invalid();
      if (name === 'IHDR') {
        if (chunks !== 1 || length !== 13) invalid();
        dimensions = size(view.getUint32(at + 8), view.getUint32(at + 12), bounds);
        const depths: Record<number, number[]> = { 0:[1,2,4,8,16], 2:[8,16], 3:[1,2,4,8], 4:[8,16], 6:[8,16] };
        if (!depths[bytes[at + 17]!] ?.includes(bytes[at + 16]!) || bytes[at + 18] !== 0 || bytes[at + 19] !== 0 || bytes[at + 20]! > 1) invalid();
      }
      if (['acTL', 'fcTL', 'fdAT'].includes(name)) invalid(); // Static screenshots only.
      if (name === 'IDAT') dataSeen = true;
      if (name === 'IEND') {
        if (length !== 0 || end !== bytes.length || !dataSeen || !dimensions) invalid();
        return { mediaType: 'image/png', ...dimensions };
      }
      at = end;
    }
    invalid();
  }
  if (bytes.length >= 12 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes.at(-2) === 0xff && bytes.at(-1) === 0xd9) {
    let at = 2; let segments = 0; let dimensions: { width: number; height: number } | null = null;
    while (at + 4 < bytes.length && segments++ < 10000) {
      if (bytes[at++] !== 0xff) invalid();
      while (bytes[at] === 0xff) at++;
      const marker = bytes[at++];
      if (marker === undefined || marker === 0 || marker === 0xd8 || marker === 0xd9 || (marker >= 0xd0 && marker <= 0xd7)) invalid();
      if (marker === 0x01) continue;
      if (at + 2 > bytes.length) invalid();
      const length = view.getUint16(at);
      if (length < 2 || at + length > bytes.length - 2) invalid();
      if ([0xc0,0xc1,0xc2].includes(marker)) {
        if (length < 8 || dimensions || length !== 8 + 3 * bytes[at + 7]!) invalid();
        dimensions = size(view.getUint16(at + 5), view.getUint16(at + 3), bounds);
      }
      if (marker === 0xda) {
        if (!dimensions || length < 6) invalid();
        return { mediaType: 'image/jpeg', ...dimensions };
      }
      at += length;
    }
  }
  return invalid();
}
