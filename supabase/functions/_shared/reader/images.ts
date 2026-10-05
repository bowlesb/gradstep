import { inflateSync } from 'node:zlib';
import { inspectImage } from '../images.ts';
import { check, fail } from './util.ts';
import { LIMITS } from './profile.ts';

// Restricted figure profiles. Edge has no image codec, so admission is a
// complete structural check plus canonical re-containerization: metadata is
// dropped, the coded image data is kept byte-for-byte. Native clients then
// fully decode every admitted raster before a bundle becomes readable.
export interface AdmittedImage {
  mediaType: 'image/jpeg' | 'image/png';
  extension: 'jpg' | 'png';
  width: number;
  height: number;
  bytes: Uint8Array;
}

function dimensions(width: number, height: number): void {
  check(Number.isSafeInteger(width) && Number.isSafeInteger(height) && width > 0 && height > 0 &&
    width <= LIMITS.imageDimension && height <= LIMITS.imageDimension && width * height <= LIMITS.imagePixels, 'image_dimensions');
}
function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, part) => n + part.length, 0));
  let at = 0;
  for (const part of parts) { out.set(part, at); at += part.length; }
  return out;
}

// JPEG: one baseline/extended/progressive Huffman frame with 1 or 3 components,
// complete entropy-coded scans and EOI as the final two bytes. APP0 (JFIF),
// APP2 ICC profiles and APP14 (Adobe color transform) are kept; EXIF/XMP,
// comments and every other application segment are removed.
export function admitJPEG(input: Uint8Array): AdmittedImage {
  const data = new Uint8Array(input);
  check(data.length >= 4 && data.length <= LIMITS.memberBytes && data[0] === 0xff && data[1] === 0xd8, 'jpeg_structure');
  const kept: Uint8Array[] = [data.subarray(0, 2)];
  let at = 2, frame: { width: number; height: number; components: number[] } | null = null;
  let scans = 0, segments = 0, ended = false;
  const u16 = (offset: number) => (data[offset] << 8) | data[offset + 1];
  while (at < data.length) {
    check(++segments <= 4096 && at + 2 <= data.length && data[at] === 0xff, 'jpeg_structure');
    let marker = data[at + 1], start = at;
    while (marker === 0xff) { at++; check(at + 1 < data.length, 'jpeg_structure'); marker = data[at + 1]; start = at; }
    if (marker === 0xd9) { check(at + 2 === data.length && frame && scans > 0, 'jpeg_structure'); kept.push(data.subarray(start, at + 2)); ended = true; break; }
    check(marker !== 0x00 && marker !== 0x01 && marker !== 0xd8 && !(marker >= 0xd0 && marker <= 0xd7), 'jpeg_structure');
    check(at + 4 <= data.length, 'jpeg_structure');
    const length = u16(at + 2), end = at + 2 + length;
    check(length >= 2 && end <= data.length, 'jpeg_structure');
    const body = data.subarray(at + 4, end);
    if (marker === 0xc0 || marker === 0xc1 || marker === 0xc2) {
      check(!frame && body.length >= 6 && body[0] === 8, 'jpeg_profile');
      const height = u16(at + 5), width = u16(at + 7), count = body[5];
      check([1, 3].includes(count) && body.length === 6 + 3 * count, 'jpeg_profile');
      dimensions(width, height);
      const components: number[] = [];
      for (let n = 0; n < count; n++) {
        const id = body[6 + 3 * n], sampling = body[7 + 3 * n], table = body[8 + 3 * n];
        check(!components.includes(id) && (sampling >> 4) >= 1 && (sampling >> 4) <= 4 && (sampling & 15) >= 1 && (sampling & 15) <= 4 && table <= 3, 'jpeg_profile');
        components.push(id);
      }
      frame = { width, height, components };
      kept.push(data.subarray(start, end));
      at = end;
    } else if (marker === 0xda) {
      check(frame && body.length >= 6, 'jpeg_structure');
      const count = body[0];
      check(count >= 1 && count <= frame.components.length && body.length === 4 + 2 * count, 'jpeg_structure');
      for (let n = 0; n < count; n++) check(frame.components.includes(body[1 + 2 * n]), 'jpeg_structure');
      // Entropy-coded data ends at the first marker that is neither a stuffed
      // 0xFF00 nor a restart marker.
      let cursor = end;
      while (true) {
        check(cursor + 1 < data.length, 'jpeg_truncated');
        if (data[cursor] === 0xff) {
          const next = data[cursor + 1];
          if (next === 0x00 || (next >= 0xd0 && next <= 0xd7)) { cursor += 2; continue; }
          if (next === 0xff) { cursor++; continue; }
          break;
        }
        cursor++;
      }
      check(cursor > end, 'jpeg_structure');
      scans++;
      kept.push(data.subarray(start, cursor));
      at = cursor;
    } else if (marker === 0xdb || marker === 0xc4 || marker === 0xdd) {
      kept.push(data.subarray(start, end)); at = end;
    } else if (marker >= 0xe0 && marker <= 0xef) {
      const label = String.fromCharCode(...body.subarray(0, Math.min(body.length, 12)));
      if ((marker === 0xe0 && label.startsWith('JFIF\0')) || (marker === 0xe2 && label === 'ICC_PROFILE\0') ||
        (marker === 0xee && label.startsWith('Adobe'))) kept.push(data.subarray(start, end));
      at = end;
    } else if (marker === 0xfe) {
      at = end;
    } else {
      // SOF3/5-15 (lossless, hierarchical, arithmetic), DAC, DNL, EXP, JPG: unsupported.
      fail('jpeg_profile');
    }
  }
  check(ended && frame && scans > 0, 'jpeg_truncated');
  const bytes = concat(kept);
  const header = inspectImage(bytes);
  check(header.mediaType === 'image/jpeg' && header.width === frame.width && header.height === frame.height, 'jpeg_structure');
  return { mediaType: 'image/jpeg', extension: 'jpg', width: frame.width, height: frame.height, bytes };
}

const PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];
const crcTable = Uint32Array.from({ length: 256 }, (_, n) => {
  for (let bit = 0; bit < 8; bit++) n = (n >>> 1) ^ ((n & 1) ? 0xedb88320 : 0);
  return n >>> 0;
});
function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = (crc >>> 8) ^ crcTable[(crc ^ byte) & 255];
  return (crc ^ 0xffffffff) >>> 0;
}
function pngChunk(name: string, body: Uint8Array): Uint8Array {
  const out = new Uint8Array(body.length + 12), view = new DataView(out.buffer);
  view.setUint32(0, body.length);
  for (let n = 0; n < 4; n++) out[4 + n] = name.charCodeAt(n);
  out.set(body, 8);
  view.setUint32(8 + body.length, crc32(out.subarray(4, 8 + body.length)));
  return out;
}

// PNG: 8-bit truecolor (RGB/RGBA), non-interlaced — the profile the native
// validator already enforces. Ancillary chunks are dropped; the zlib stream
// is inflated under an exact output bound, its extent and filter bytes are
// checked, and IDAT is re-chunked without recompression.
export function admitPNG(input: Uint8Array): AdmittedImage {
  const data = new Uint8Array(input);
  check(data.length >= 45 && data.length <= LIMITS.memberBytes && PNG_SIGNATURE.every((b, n) => data[n] === b), 'png_structure');
  const view = new DataView(data.buffer);
  let at = 8, chunks = 0, width = 0, height = 0, channels = 0, ended = false, dataDone = false;
  let ihdr: Uint8Array | null = null;
  const idat: Uint8Array[] = [];
  while (at < data.length) {
    check(++chunks <= 4096 && at + 12 <= data.length, 'png_structure');
    const length = view.getUint32(at), end = at + 12 + length;
    check(length <= LIMITS.memberBytes && end <= data.length, 'png_structure');
    const type = data.subarray(at + 4, at + 8), name = String.fromCharCode(...type);
    check(/^[A-Za-z]{4}$/.test(name) && crc32(data.subarray(at + 4, end - 4)) === view.getUint32(end - 4), 'png_structure');
    const body = data.subarray(at + 8, end - 4);
    if (chunks === 1) {
      check(name === 'IHDR' && length === 13, 'png_structure');
      width = view.getUint32(at + 8); height = view.getUint32(at + 12);
      dimensions(width, height);
      check(body[8] === 8 && (body[9] === 2 || body[9] === 6) && body[10] === 0 && body[11] === 0 && body[12] === 0, 'png_profile');
      channels = body[9] === 2 ? 3 : 4;
      ihdr = body;
    } else if (name === 'IDAT') {
      check(!dataDone, 'png_structure');
      idat.push(body);
    } else if (name === 'IEND') {
      check(length === 0 && idat.length > 0 && end === data.length, 'png_structure');
      ended = true; at = end; break;
    } else {
      // Critical chunks (uppercase first letter) such as PLTE are outside this
      // profile; ancillary metadata/animation/text chunks are discarded.
      check(name.charCodeAt(0) >= 97 && name !== 'acTL' && name !== 'fcTL' && name !== 'fdAT', 'png_profile');
      if (idat.length) dataDone = true;
    }
    at = end;
  }
  check(ended && ihdr, 'png_truncated');
  const compressed = concat(idat), rowBytes = width * channels + 1, expected = rowBytes * height;
  let inflated: { buffer: Uint8Array; engine: { bytesWritten: number } };
  try {
    inflated = inflateSync(compressed, { info: true, maxOutputLength: expected }) as unknown as { buffer: Uint8Array; engine: { bytesWritten: number } };
  } catch { return fail('png_compression'); }
  check(inflated.buffer.length === expected && inflated.engine.bytesWritten === compressed.length, 'png_compression');
  for (let row = 0; row < height; row++) check(inflated.buffer[row * rowBytes] <= 4, 'png_filter');
  const bytes = concat([Uint8Array.from(PNG_SIGNATURE), pngChunk('IHDR', ihdr), pngChunk('IDAT', compressed), pngChunk('IEND', new Uint8Array())]);
  const header = inspectImage(bytes);
  check(header.mediaType === 'image/png' && header.width === width && header.height === height, 'png_structure');
  return { mediaType: 'image/png', extension: 'png', width, height, bytes };
}

export function admitReaderImage(input: Uint8Array): AdmittedImage {
  if (input.length >= 2 && input[0] === 0xff && input[1] === 0xd8) return admitJPEG(input);
  if (input.length >= 8 && PNG_SIGNATURE.every((b, n) => input[n] === b)) return admitPNG(input);
  return fail('image_format');
}
