// Restricted authored-image profile. Decode every scanline before canonicalizing;
// signatures/dimensions alone do not establish a decodable image.
import { inflateSync, deflateSync } from 'node:zlib';
import { profile, requireThat } from './common.mjs';

const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const crcTable = Array.from({ length: 256 }, (_, n) => {
  for (let i = 0; i < 8; i++) n = (n >>> 1) ^ ((n & 1) ? 0xedb88320 : 0);
  return n >>> 0;
});
export function crc32(bytes) { let c = 0xffffffff; for (const b of bytes) c = crcTable[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }
function chunk(name, bytes) {
  const data = Buffer.concat([Buffer.from(name), bytes]);
  const head = Buffer.alloc(4); head.writeUInt32BE(bytes.length);
  const tail = Buffer.alloc(4); tail.writeUInt32BE(crc32(data));
  return Buffer.concat([head, data, tail]);
}
export function encodePNG(width, height, rgba) {
  requireThat(Number.isInteger(width) && Number.isInteger(height) && width > 0 && height > 0 && width <= profile.max_image_dimension && height <= profile.max_image_dimension && width * height <= profile.max_image_pixels, 'image_dimensions');
  requireThat(rgba.length === width * height * 4, 'image_pixels');
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(width); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 6;
  const scanlines = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) Buffer.from(rgba.buffer, rgba.byteOffset + y * width * 4, width * 4).copy(scanlines, y * (width * 4 + 1) + 1);
  return Buffer.concat([signature, chunk('IHDR', ihdr), chunk('IDAT', deflateSync(scanlines, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}
export function decodePNG(input) {
  const bytes = Buffer.from(input);
  requireThat(bytes.length <= profile.max_member_bytes && bytes.subarray(0, 8).equals(signature), 'image_format');
  let pos = 8, width, height, channels, ended = false, idatEnded = false, sawData = false, chunks = 0;
  const compressed = [];
  while (pos < bytes.length) {
    requireThat(++chunks <= 512, 'png_chunk_limit');
    requireThat(pos + 12 <= bytes.length, 'png_truncated');
    const length = bytes.readUInt32BE(pos); const type = bytes.subarray(pos + 4, pos + 8);
    requireThat([...type].every(byte => (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)) && type[2] >= 65 && type[2] <= 90, 'png_chunk_type');
    const name = type.toString('ascii');
    requireThat(length <= profile.max_member_bytes && pos + length + 12 <= bytes.length, 'png_chunk');
    const body = bytes.subarray(pos + 8, pos + 8 + length);
    requireThat(crc32(bytes.subarray(pos + 4, pos + 8 + length)) === bytes.readUInt32BE(pos + 8 + length), 'png_crc');
    if (!width) {
      requireThat(name === 'IHDR' && length === 13, 'png_header');
      width = body.readUInt32BE(0); height = body.readUInt32BE(4);
      requireThat(width > 0 && height > 0 && width <= profile.max_image_dimension && height <= profile.max_image_dimension && width * height <= profile.max_image_pixels, 'image_dimensions');
      requireThat(body[8] === 8 && [2, 6].includes(body[9]) && body[10] === 0 && body[11] === 0 && body[12] === 0, 'png_profile');
      channels = body[9] === 2 ? 3 : 4;
    } else if (name === 'IDAT') {
      requireThat(!idatEnded, 'png_noncontiguous_data'); compressed.push(body); sawData = true;
    } else if (name === 'IEND') {
      requireThat(length === 0 && sawData, 'png_end'); ended = true; pos += 12; break;
    } else {
      // No ancillary metadata, animation, unknown chunks, or alternate profiles.
      idatEnded = sawData;
      throw new Error('png_profile');
    }
    pos += length + 12;
  }
  requireThat(ended && pos === bytes.length, 'png_trailing_or_truncated');
  const packed = Buffer.concat(compressed); const rowBytes = width * channels; const expected = (rowBytes + 1) * height;
  let inflated;
  try { inflated = inflateSync(packed, { maxOutputLength: expected, info: true }); } catch { throw new Error('png_inflate'); }
  requireThat(inflated.buffer.length === expected && inflated.engine.bytesWritten === packed.length, 'png_deflate_extent');
  const decoded = Buffer.alloc(rowBytes * height);
  const paeth = (a, b, c) => { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); return pa <= pb && pa <= pc ? a : pb <= pc ? b : c; };
  for (let y = 0; y < height; y++) {
    const filter = inflated.buffer[y * (rowBytes + 1)]; requireThat(filter <= 4, 'png_filter');
    for (let x = 0; x < rowBytes; x++) {
      const a = x >= channels ? decoded[y * rowBytes + x - channels] : 0;
      const b = y > 0 ? decoded[(y - 1) * rowBytes + x] : 0;
      const c = y > 0 && x >= channels ? decoded[(y - 1) * rowBytes + x - channels] : 0;
      const prediction = [0, a, b, Math.floor((a + b) / 2), paeth(a, b, c)][filter];
      decoded[y * rowBytes + x] = (inflated.buffer[y * (rowBytes + 1) + x + 1] + prediction) & 255;
    }
  }
  const rgba = Buffer.alloc(width * height * 4);
  for (let i = 0; i < width * height; i++) { rgba[i * 4] = decoded[i * channels]; rgba[i * 4 + 1] = decoded[i * channels + 1]; rgba[i * 4 + 2] = decoded[i * channels + 2]; rgba[i * 4 + 3] = channels === 4 ? decoded[i * channels + 3] : 255; }
  return { width, height, rgba, bytes: encodePNG(width, height, rgba) };
}
