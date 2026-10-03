import test from 'node:test';
import assert from 'node:assert/strict';
import { zipSync, Zip, ZipDeflate, ZipPassThrough } from 'fflate';
import { ARCHIVE_LIMITS, ArchiveError, unpackReaderZip } from '../../supabase/functions/_shared/archive.ts';

const bytes = (text: string) => new TextEncoder().encode(text);
const view = (data: Uint8Array) => new DataView(data.buffer, data.byteOffset, data.byteLength);
const central = (data: Uint8Array) => view(data).getUint32(data.length - 6, true);
function memberStarts(data: Uint8Array): number[] {
  const result: number[] = [], v = view(data); let at = central(data);
  while (v.getUint32(at, true) === 0x02014b50) {
    result.push(at); at += 46 + v.getUint16(at + 28, true) + v.getUint16(at + 30, true) + v.getUint16(at + 32, true);
  }
  return result;
}
function reject(code: string | RegExp) {
  return (error: unknown) => error instanceof ArchiveError && (typeof code === 'string' ? error.code === code : code.test(error.code));
}

test('stored and deflated entries preserve opaque bytes and explicit directory hierarchy', async () => {
  const text = bytes('A paper with \\(x^2\\) and Unicode λ.');
  const archive = zipSync({ 'paper.mmd': text, 'images/': new Uint8Array(), 'images/figure.png': [bytes('opaque image bytes'), { level: 0 }] });
  const files = await unpackReaderZip(archive);
  assert.deepEqual(files.map(file => file.path), ['paper.mmd', 'images/figure.png']);
  assert.deepEqual(files[0].bytes, text);
  assert.equal(new TextDecoder().decode(files[1].bytes), 'opaque image bytes');
});

test('streamed ZIP data descriptors validate for compressed and stored entries', async () => {
  const chunks: Uint8Array[] = [];
  const zip = new Zip((error, chunk) => { if (error) throw error; chunks.push(chunk); });
  const a = new ZipDeflate('paper.mmd'), b = new ZipPassThrough('images/one.jpg');
  zip.add(a); a.push(bytes('Part one ')); a.push(bytes('and two'), true);
  zip.add(b); b.push(bytes('image fixture'), true); zip.end();
  const joined = Uint8Array.from(Buffer.concat(chunks));
  const files = await unpackReaderZip(joined);
  assert.equal(files.length, 2);
  assert.equal(new TextDecoder().decode(files[0].bytes), 'Part one and two');
  const bad = new Uint8Array(joined), second = view(bad).getUint32(memberStarts(bad)[1] + 42, true);
  bad[second - 12] ^= 1; // first descriptor CRC no longer agrees with directory
  await assert.rejects(unpackReaderZip(bad), reject('archive_invalid'));
});

test('unsafe names, alternate case, duplicate names, and file/directory collisions fail', async () => {
  for (const path of ['../escape', '/absolute', 'a/../b', 'a\\b', 'a//b', 'C:/b', '%2e%2e/b', '.hidden', 'a.', 'a/CON.txt', 'λ.mmd']) {
    await assert.rejects(unpackReaderZip(zipSync({ [path]: bytes('x') })), reject('archive_path_invalid'), path);
  }
  await assert.rejects(unpackReaderZip(zipSync({ 'A.mmd': bytes('a'), 'a.mmd': bytes('b') })), reject('archive_duplicate_path'));
  await assert.rejects(unpackReaderZip(zipSync({ a: bytes('x'), 'a/b': bytes('y') })), reject('archive_path_conflict'));
  const duplicate = zipSync({ 'a.mmd': bytes('a'), 'b.mmd': bytes('b') });
  const second = memberStarts(duplicate)[1], local = view(duplicate).getUint32(second + 42, true);
  duplicate[second + 46] = duplicate[local + 30] = 'a'.charCodeAt(0);
  await assert.rejects(unpackReaderZip(duplicate), reject('archive_duplicate_path'));
});

test('encrypted, unsupported compression, symlink and split archive headers fail before extraction', async () => {
  const fixtures = [
    (data: Uint8Array) => { view(data).setUint16(central(data) + 8, 1, true); },
    (data: Uint8Array) => { view(data).setUint16(central(data) + 10, 14, true); },
    (data: Uint8Array) => { view(data).setUint32(central(data) + 38, (0o120777 << 16) >>> 0, true); },
    (data: Uint8Array) => { view(data).setUint16(data.length - 18, 1, true); },
    (data: Uint8Array) => { view(data).setUint16(central(data) + 6, 45, true); },
  ];
  for (const mutate of fixtures) {
    const archive = zipSync({ 'paper.mmd': bytes('fixture') }); mutate(archive);
    await assert.rejects(unpackReaderZip(archive), reject('archive_unsupported'));
  }
});

test('local identity mismatches, overlapping records, hidden prefix, and truncated archives fail', async () => {
  const fixtures = [
    (data: Uint8Array) => { data[30] = 0x78; return data; },
    (data: Uint8Array) => { view(data).setUint32(central(data) + 42, 1, true); return data; },
    (data: Uint8Array) => { view(data).setUint32(central(data) + 20, data.length, true); return data; },
    (data: Uint8Array) => data.subarray(0, data.length - 3),
    (data: Uint8Array) => Uint8Array.from([1, ...data]),
  ];
  for (const mutate of fixtures) {
    await assert.rejects(unpackReaderZip(mutate(zipSync({ 'paper.mmd': bytes('fixture') }))), reject(/^archive_(?:invalid|path_conflict)$/));
  }
});

test('actual content CRC is checked and no partially extracted result is returned', async () => {
  const archive = zipSync({ 'a.mmd': bytes('first'), 'b.mmd': [bytes('second'), { level: 0 }] });
  const second = memberStarts(archive)[1], local = view(archive).getUint32(second + 42, true);
  archive[local + 30 + 'b.mmd'.length] ^= 1;
  await assert.rejects(unpackReaderZip(archive), reject('archive_checksum_mismatch'));
});

test('declared expansion, entry-count and archive byte limits are enforced before inflation', async () => {
  const large = zipSync({ 'paper.mmd': new Uint8Array(1_048_576) });
  await assert.rejects(unpackReaderZip(large), reject('archive_limit'));
  const count = zipSync({ 'paper.mmd': bytes('small') });
  view(count).setUint16(count.length - 14, ARCHIVE_LIMITS.entries + 1, true);
  view(count).setUint16(count.length - 12, ARCHIVE_LIMITS.entries + 1, true);
  await assert.rejects(unpackReaderZip(count), reject('archive_limit'));
  const size = zipSync({ 'paper.mmd': bytes('small') });
  view(size).setUint32(central(size) + 24, ARCHIVE_LIMITS.fileBytes + 1, true);
  await assert.rejects(unpackReaderZip(size), reject('archive_limit'));
  await assert.rejects(unpackReaderZip(new Uint8Array(ARCHIVE_LIMITS.compressedBytes + 1)), reject('archive_limit'));
});

test('a compressed bomb lying about expanded size fails on actual output', async () => {
  const archive = zipSync({ 'paper.mmd': new Uint8Array(1_048_576) });
  view(archive).setUint32(central(archive) + 24, 1, true);
  view(archive).setUint32(22, 1, true);
  await assert.rejects(unpackReaderZip(archive), reject('archive_expansion_mismatch'));
});

test('DEFLATE must end completely, consume all bytes, and validate stored-block lengths', async () => {
  const original = zipSync({ 'paper.mmd': bytes('a paper') });
  function replaceCompressed(replace: (value: Uint8Array) => Uint8Array) {
    const centralAt = central(original), localStart = 30 + 'paper.mmd'.length;
    const originalSize = view(original).getUint32(18, true);
    const data = replace(original.subarray(localStart, localStart + originalSize));
    const delta = data.length - originalSize;
    const changed = Uint8Array.from(Buffer.concat([original.subarray(0, localStart), data, original.subarray(centralAt)]));
    view(changed).setUint32(18, data.length, true);
    view(changed).setUint32(centralAt + delta + 20, data.length, true);
    view(changed).setUint32(changed.length - 6, centralAt + delta, true);
    return changed;
  }
  const trailing = replaceCompressed(value => Uint8Array.from([...value, 1, 2, 3, 4]));
  const truncated = replaceCompressed(value => value.subarray(0, value.length - 1));
  // One raw DEFLATE stored block, BFINAL=1, LEN=7 and an invalid NLEN=0.
  const invalidLength = replaceCompressed(() => Uint8Array.from([1, 7, 0, 0, 0, ...bytes('a paper')]));
  for (const archive of [trailing, truncated, invalidLength]) {
    await assert.rejects(unpackReaderZip(archive), reject('archive_compression_invalid'));
  }
});

test('caller mutation, including Node Buffer aliasing, cannot change an in-progress extraction', async () => {
  const original = bytes('second original');
  const archive = Buffer.from(zipSync({ 'a.mmd': bytes('first'), 'b.mmd': original }));
  const result = unpackReaderZip(archive);
  archive.fill(0);
  const files = await result;
  assert.deepEqual(files[1].bytes, original);
});

test('cancellation before or during extraction publishes no result', async () => {
  const controller = new AbortController(), archive = zipSync({ 'a.mmd': bytes('one'), 'b.mmd': bytes('two') });
  const result = unpackReaderZip(archive, controller.signal); controller.abort();
  await assert.rejects(result, reject('archive_cancelled'));
  await assert.rejects(unpackReaderZip(archive, controller.signal), reject('archive_cancelled'));
});
