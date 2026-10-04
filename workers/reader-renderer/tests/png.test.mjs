import test from 'node:test';
import assert from 'node:assert/strict';
import { deflateSync } from 'node:zlib';
import { encodePNG, decodePNG, crc32 } from '../png.mjs';
const pixels = Buffer.from([255, 0, 0, 255, 0, 255, 0, 255]);
const original = encodePNG(2, 1, pixels);
function chunk(name, data) { const body = Buffer.concat([Buffer.from(name), data]); const result = Buffer.alloc(body.length + 8); result.writeUInt32BE(data.length); body.copy(result, 4); result.writeUInt32BE(crc32(body), body.length + 4); return result; }
function rebuildIDAT(data) { return Buffer.concat([original.subarray(0, 33), chunk('IDAT', data), chunk('IEND', Buffer.alloc(0))]); }
test('PNG pixel decoding and deterministic canonical encoding preserve pixels', () => { const result = decodePNG(original); assert.equal(result.width, 2); assert.equal(result.height, 1); assert.deepEqual(result.rgba, pixels); assert.deepEqual(result.bytes, original); });
test('PNG CRC, truncation, trailing input and wrong dimensions fail', () => {
  const badCRC = Buffer.from(original); badCRC[29] ^= 1;
  const badDimensions = Buffer.from(original); badDimensions.writeUInt32BE(9000, 16); badDimensions.writeUInt32BE(crc32(badDimensions.subarray(12, 29)), 29);
  for (const bad of [badCRC, original.subarray(0, -1), Buffer.concat([original, Buffer.from([0])]), badDimensions]) assert.throws(() => decodePNG(bad));
});
test('high-bit chunk names cannot alias ASCII chunk names even with a matching CRC', () => {
  const bad = Buffer.from(original); bad[12] = 0xc9; bad.writeUInt32BE(crc32(bad.subarray(12, 29)), 29); assert.throws(() => decodePNG(bad), /png_chunk_type/);
});
test('inflated size and compressed extent are checked rather than trusting IHDR', () => {
  const scanline = Buffer.concat([Buffer.from([0]), pixels]);
  const encoded = deflateSync(scanline);
  for (const data of [encoded.subarray(0, -1), Buffer.concat([encoded, Buffer.from([0])]), deflateSync(Buffer.alloc(100000)), deflateSync(Buffer.from([0, 1]))]) assert.throws(() => decodePNG(rebuildIDAT(data)));
});
test('invalid filter types, unsupported profile and unknown ancillary chunks fail', () => {
  assert.throws(() => decodePNG(rebuildIDAT(deflateSync(Buffer.concat([Buffer.from([5]), pixels])))), /png_filter/);
  const interlaced = Buffer.from(original); interlaced[28] = 1; interlaced.writeUInt32BE(crc32(interlaced.subarray(12, 29)), 29); assert.throws(() => decodePNG(interlaced), /png_profile/);
  assert.throws(() => decodePNG(Buffer.concat([original.subarray(0, 33), chunk('tEXt', Buffer.from('x')), original.subarray(33)])), /png_profile/);
});
