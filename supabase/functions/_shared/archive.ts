import { inflateRawSync } from 'node:zlib';

// Narrow, versioned ZIP profile for provider result collection. This validates
// the container, not HTML, image pixels, MMD references or artifact completeness.
// No archive name is ever used to write a filesystem or storage path here.
export const ARCHIVE_PROFILE = 'reader-zip-v1';
export const ARCHIVE_LIMITS = Object.freeze({
  compressedBytes: 33_554_432, expandedBytes: 33_554_432, fileBytes: 16_777_216,
  entries: 512, pathBytes: 240, depth: 8, extraBytes: 4096, commentBytes: 1024,
});
export class ArchiveError extends Error {
  readonly code: string;
  constructor(code: string) { super(code); this.code = code; }
}
export interface ArchiveFile { path: string; bytes: Uint8Array; }
interface Member {
  path: string; directory: boolean; flags: number; method: number; crc: number;
  compressed: number; expanded: number; local: number; start: number;
  rawName: Uint8Array;
}
function fail(code = 'archive_invalid'): never { throw new ArchiveError(code); }
const crcTable = Uint32Array.from({ length: 256 }, (_, n) => {
  for (let bit = 0; bit < 8; bit++) n = (n >>> 1) ^ ((n & 1) ? 0xedb88320 : 0);
  return n >>> 0;
});
function crcPart(crc: number, bytes: Uint8Array): number {
  for (const byte of bytes) crc = (crc >>> 8) ^ crcTable[(crc ^ byte) & 255];
  return crc;
}
function name(bytes: Uint8Array): { path: string; directory: boolean } {
  if (!bytes.length || bytes.length > ARCHIVE_LIMITS.pathBytes || bytes.some(byte => byte > 127)) fail('archive_path_invalid');
  const path = new TextDecoder().decode(bytes), directory = path.endsWith('/');
  const parts = (directory ? path.slice(0, -1) : path).split('/');
  if (parts.length > ARCHIVE_LIMITS.depth || parts.some(part =>
    !/^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(part) || part.endsWith('.') ||
    /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part))) fail('archive_path_invalid');
  return { path, directory };
}

function index(data: Uint8Array): Member[] {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const u16 = (offset: number) => view.getUint16(offset, true);
  const u32 = (offset: number) => view.getUint32(offset, true);
  const within = (offset: number, length: number, end = data.length) => {
    if (!Number.isSafeInteger(offset) || offset < 0 || length < 0 || offset + length > end) fail();
  };
  const extras = (offset: number, length: number) => {
    if (length > ARCHIVE_LIMITS.extraBytes) fail('archive_limit');
    const end = offset + length;
    while (offset < end) {
      within(offset, 4, end);
      const kind = u16(offset), size = u16(offset + 2); offset += 4;
      within(offset, size, end);
      // Only inert timestamp/UID fields. Reject ZIP64, encryption and alternate
      // filename fields instead of letting another parser choose a new identity.
      if (![0x5455, 0x000a, 0x7875].includes(kind)) fail('archive_unsupported');
      offset += size;
    }
  };
  // A bounded comment may follow EOCD. Central-directory bounds and every
  // contiguous local record are then checked before any decompression occurs.
  let end = -1;
  for (let at = data.length - 22; at >= Math.max(0, data.length - 22 - ARCHIVE_LIMITS.commentBytes); at--) {
    if (u32(at) === 0x06054b50 && at + 22 + u16(at + 20) === data.length) { end = at; break; }
  }
  if (end < 0) fail();
  const count = u16(end + 10), centralSize = u32(end + 12), centralStart = u32(end + 16);
  if (u16(end + 4) || u16(end + 6) || u16(end + 8) !== count) fail('archive_unsupported');
  if (!count || count > ARCHIVE_LIMITS.entries) fail('archive_limit');
  if (centralStart + centralSize !== end) fail();
  within(centralStart, centralSize, end);
  const members: Member[] = [], paths = new Map<string, boolean>();
  let cursor = centralStart, expanded = 0;
  for (let n = 0; n < count; n++) {
    within(cursor, 46, end);
    if (u32(cursor) !== 0x02014b50) fail();
    const flags = u16(cursor + 8), method = u16(cursor + 10), crc = u32(cursor + 16);
    const compressed = u32(cursor + 20), size = u32(cursor + 24);
    const nameLength = u16(cursor + 28), extraLength = u16(cursor + 30), commentLength = u16(cursor + 32);
    const local = u32(cursor + 42), attributes = u32(cursor + 38), mode = (attributes >>> 16) & 0xf000;
    if (u16(cursor + 6) > 20 || u16(cursor + 34) || (flags & ~0x080e) || ![0, 8].includes(method) ||
      (method === 0 && (flags & 6))) fail('archive_unsupported');
    within(cursor + 46, nameLength + extraLength + commentLength, end);
    if (commentLength > ARCHIVE_LIMITS.commentBytes) fail('archive_limit');
    const rawName = data.subarray(cursor + 46, cursor + 46 + nameLength);
    const identity = name(rawName);
    if (mode && mode !== (identity.directory ? 0x4000 : 0x8000)) fail('archive_unsupported');
    if ((attributes & 0x10) && !identity.directory) fail();
    const folded = identity.path.replace(/\/$/, '').toLowerCase();
    if (paths.has(folded)) fail('archive_duplicate_path');
    paths.set(folded, identity.directory);
    expanded += size;
    if (compressed > ARCHIVE_LIMITS.compressedBytes || size > ARCHIVE_LIMITS.fileBytes ||
      expanded > ARCHIVE_LIMITS.expandedBytes || size > compressed * 200 + 4096) fail('archive_limit');
    if ((identity.directory && (size !== 0 || crc !== 0)) || (method === 0 && compressed !== size)) fail();
    extras(cursor + 46 + nameLength, extraLength);
    members.push({ ...identity, flags, method, crc, compressed, expanded: size, local, start: 0, rawName });
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  if (cursor !== end) fail();
  for (const [path] of paths) {
    const parts = path.split('/');
    for (let n = 1; n < parts.length; n++) {
      if (paths.get(parts.slice(0, n).join('/')) === false) fail('archive_path_conflict');
    }
  }
  members.sort((a, b) => a.local - b.local);
  if (members[0].local !== 0) fail(); // no self-extractor or hidden prefix
  for (let n = 0; n < members.length; n++) {
    const member = members[n], local = member.local, next = members[n + 1]?.local ?? centralStart;
    within(local, 30, next);
    if (u32(local) !== 0x04034b50 || u16(local + 4) > 20 || u16(local + 6) !== member.flags || u16(local + 8) !== member.method) fail();
    const length = u16(local + 26), extraLength = u16(local + 28);
    within(local + 30, length + extraLength, next);
    if (length !== member.rawName.length || member.rawName.some((byte, i) => byte !== data[local + 30 + i])) fail('archive_path_conflict');
    extras(local + 30 + length, extraLength);
    member.start = local + 30 + length + extraLength;
    within(member.start, member.compressed, next);
    const payloadEnd = member.start + member.compressed, descriptor = (member.flags & 8) !== 0;
    for (const [offset, expected] of [[14, member.crc], [18, member.compressed], [22, member.expanded]]) {
      const actual = u32(local + offset);
      if (actual !== expected && !(descriptor && actual === 0)) fail();
    }
    if (descriptor) {
      const length = next - payloadEnd;
      if (length !== 12 && length !== 16) fail();
      if (length === 16 && u32(payloadEnd) !== 0x08074b50) fail();
      const at = payloadEnd + (length === 16 ? 4 : 0);
      if (u32(at) !== member.crc || u32(at + 4) !== member.compressed || u32(at + 8) !== member.expanded) fail();
    } else if (payloadEnd !== next) fail();
  }
  return members;
}

export async function unpackReaderZip(input: Uint8Array, signal?: AbortSignal): Promise<ArchiveFile[]> {
  if (signal?.aborted) fail('archive_cancelled');
  if (input.length < 22 || input.length > ARCHIVE_LIMITS.compressedBytes) fail('archive_limit');
  // A caller cannot mutate identity/size fields while asynchronous extraction
  // yields. Node Buffer.slice aliases its input, so explicitly own this copy.
  const data = new Uint8Array(input), members = index(data), files: ArchiveFile[] = [];
  const cancelled = () => { if (signal?.aborted) fail('archive_cancelled'); };
  cancelled();
  for (const member of members) {
    cancelled();
    let output: Uint8Array;
    try {
      const compressed = data.subarray(member.start, member.start + member.compressed);
      if (member.method === 0) output = new Uint8Array(compressed);
      else {
        // Public zlib API: cap actual output inside the decoder, require strict
        // stream completion (default Z_FINISH), and reject trailing input using
        // consumed bytes. The archive's advertised size is never allocation
        // authority above our per-file and aggregate caps. Abort is cooperative
        // between bounded entries; hosted CPU/memory admission is still required.
        // Node's type declaration omits the documented `info:true` return shape.
        const decoded = inflateRawSync(compressed, { info: true, maxOutputLength: Math.max(1, member.expanded) }) as unknown as
          { buffer: Uint8Array; engine: { bytesWritten: number } };
        if (!(decoded.buffer instanceof Uint8Array) || decoded.engine?.bytesWritten !== member.compressed) fail('archive_compression_invalid');
        output = new Uint8Array(decoded.buffer);
      }
    } catch (error) {
      if (error instanceof ArchiveError) throw error;
      if (error && typeof error === 'object' && 'code' in error && error.code === 'ERR_BUFFER_TOO_LARGE') fail('archive_expansion_mismatch');
      fail('archive_compression_invalid');
    }
    cancelled();
    if (output.length !== member.expanded || ((crcPart(0xffffffff, output) ^ 0xffffffff) >>> 0) !== member.crc) fail('archive_checksum_mismatch');
    if (!member.directory) files.push({ path: member.path, bytes: output });
    await new Promise<void>(resolve => setTimeout(resolve, 0));
  }
  cancelled();
  return files;
}
