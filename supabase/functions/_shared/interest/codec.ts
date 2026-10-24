// Interest index artifact formats (docs/architecture/INTEREST_INDEX.md §3–4). Every artifact is one gzip stream (iOS
// Compression, the browser's DecompressionStream and Node all read it) holding:
//   "GSI1" · u32 LE header length · UTF-8 JSON header · binary body
// The header names the kind (`map`, `terms` or `shard`) and its format version; the body layout is per kind:
//   shard  per paper: u8 id length · id (ASCII) · u16 LE announcement day (days since 1970-01-01) · q8 fingerprint
//   map    q8 centroids, one per header node, in header order
//   terms  per phrase, sorted bytewise: u8 shared-prefix length · suffix (UTF-8) · 0x00 · varint df · i8 conceptness×1000
// q8 = f32 LE scale (max |x| / 127) · 384 × i8 round(x / scale). Against halfvec: min cos 0.99987 on the pool.

export const DIM = 384;
export const Q8_BYTES = 4 + DIM;
const MAGIC = [0x47, 0x53, 0x49, 0x31]; // "GSI1"

export function quantize(v: ArrayLike<number>): Uint8Array {
  if (v.length !== DIM) throw new Error('interest_dimension');
  let max = 0;
  for (let i = 0; i < DIM; i++) max = Math.max(max, Math.abs(v[i]));
  const out = new Uint8Array(Q8_BYTES);
  const view = new DataView(out.buffer);
  const scale = max / 127;
  view.setFloat32(0, scale, true);
  for (let i = 0; i < DIM; i++) view.setInt8(4 + i, scale > 0 ? Math.max(-127, Math.min(127, Math.round(v[i] / scale))) : 0);
  return out;
}

export function dequantize(q: Uint8Array, offset = 0, out = new Float32Array(DIM)): Float32Array {
  const view = new DataView(q.buffer, q.byteOffset + offset, Q8_BYTES);
  const scale = view.getFloat32(0, true);
  for (let i = 0; i < DIM; i++) out[i] = view.getInt8(4 + i) * scale;
  return out;
}

export function normalize(v: Float32Array): Float32Array {
  let n = 0;
  for (let i = 0; i < v.length; i++) n += v[i] * v[i];
  n = Math.sqrt(n);
  if (n > 0) for (let i = 0; i < v.length; i++) v[i] /= n;
  return v;
}

export function base64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export function fromBase64(text: string): Uint8Array {
  const s = atob(text);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

/** pgvector `halfvec_send`: i16 BE dimension · i16 unused · dim × IEEE half (big-endian). */
export function fromHalfvecSend(bytes: Uint8Array): Float32Array {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const dim = view.getInt16(0, false);
  if (dim !== DIM || bytes.byteLength !== 4 + 2 * dim) throw new Error('interest_halfvec_invalid');
  const out = new Float32Array(dim);
  for (let i = 0; i < dim; i++) out[i] = halfToFloat(view.getUint16(4 + 2 * i, false));
  return out;
}

export function halfToFloat(h: number): number {
  const sign = h & 0x8000 ? -1 : 1, exp = (h >> 10) & 0x1f, frac = h & 0x3ff;
  if (exp === 0) return sign * 2 ** -14 * (frac / 1024);
  if (exp === 31) return frac ? NaN : sign * Infinity;
  return sign * 2 ** (exp - 15) * (1 + frac / 1024);
}

/** A vector as pgvector text ('[x,y,…]'), rounded to what halfvec keeps. */
export function vectorText(v: ArrayLike<number>): string {
  const parts = new Array<string>(v.length);
  for (let i = 0; i < v.length; i++) parts[i] = Number(v[i].toPrecision(6)).toString();
  return '[' + parts.join(',') + ']';
}

class Writer {
  private chunks: Uint8Array[] = [];
  private size = 0;
  bytes(b: Uint8Array) { this.chunks.push(b); this.size += b.length; }
  u8(n: number) { this.bytes(Uint8Array.of(n)); }
  u16(n: number) { this.bytes(Uint8Array.of(n & 0xff, (n >> 8) & 0xff)); }
  u32(n: number) { this.bytes(Uint8Array.of(n & 0xff, (n >>> 8) & 0xff, (n >>> 16) & 0xff, (n >>> 24) & 0xff)); }
  varint(n: number) { const out: number[] = []; do { let b = n & 0x7f; n = Math.floor(n / 128); if (n) b |= 0x80; out.push(b); } while (n); this.bytes(Uint8Array.from(out)); }
  finish(): Uint8Array { const out = new Uint8Array(this.size); let o = 0; for (const c of this.chunks) { out.set(c, o); o += c.length; } return out; }
}

class Reader {
  offset = 0;
  readonly data: Uint8Array;
  private view: DataView;
  constructor(data: Uint8Array) { this.data = data; this.view = new DataView(data.buffer, data.byteOffset, data.byteLength); }
  get done() { return this.offset >= this.data.length; }
  u8() { return this.data[this.offset++]; }
  i8() { return this.view.getInt8(this.offset++); }
  u16() { const v = this.view.getUint16(this.offset, true); this.offset += 2; return v; }
  u32() { const v = this.view.getUint32(this.offset, true); this.offset += 4; return v; }
  take(n: number) { if (this.offset + n > this.data.length) throw new Error('interest_artifact_truncated'); const v = this.data.subarray(this.offset, this.offset + n); this.offset += n; return v; }
  varint() { let n = 0, mul = 1, b: number; do { b = this.u8(); n += (b & 0x7f) * mul; mul *= 128; } while (b & 0x80); return n; }
}

async function pipe(bytes: Uint8Array, stream: CompressionStream | DecompressionStream): Promise<Uint8Array> {
  const body = new Blob([bytes as BlobPart]).stream().pipeThrough(stream);
  return new Uint8Array(await new Response(body).arrayBuffer());
}
export const gzip = (bytes: Uint8Array) => pipe(bytes, new CompressionStream('gzip'));
export const gunzip = (bytes: Uint8Array) => pipe(bytes, new DecompressionStream('gzip'));

export interface ArtifactHeader { kind: 'map' | 'terms' | 'shard'; format: 1; [key: string]: unknown }

export async function pack(header: ArtifactHeader, body: Uint8Array): Promise<Uint8Array> {
  const w = new Writer();
  const json = new TextEncoder().encode(JSON.stringify(header));
  w.bytes(Uint8Array.from(MAGIC)); w.u32(json.length); w.bytes(json); w.bytes(body);
  return gzip(w.finish());
}

export async function unpack(artifact: Uint8Array): Promise<{ header: ArtifactHeader; body: Uint8Array }> {
  const raw = await gunzip(artifact);
  const r = new Reader(raw);
  if (MAGIC.some(b => r.u8() !== b)) throw new Error('interest_artifact_magic');
  const length = r.u32();
  const header = JSON.parse(new TextDecoder().decode(r.take(length))) as ArtifactHeader;
  if (header.format !== 1) throw new Error('interest_artifact_format');
  return { header, body: raw.subarray(r.offset) };
}

// ---------- shards ----------

export interface ShardPaper { sourceID: string; announcedOn: string; q8: Uint8Array }
const DAY = 86_400_000;
const dayNumber = (iso: string) => Math.round(Date.parse(iso + 'T00:00:00Z') / DAY);
const dayString = (n: number) => new Date(n * DAY).toISOString().slice(0, 10);

export function shardBody(papers: ShardPaper[]): Uint8Array {
  const w = new Writer();
  for (const p of papers) {
    if (!/^[\x21-\x7e]{1,128}$/.test(p.sourceID) || p.q8.length !== Q8_BYTES) throw new Error('interest_shard_paper');
    w.u8(p.sourceID.length); w.bytes(new TextEncoder().encode(p.sourceID)); w.u16(dayNumber(p.announcedOn)); w.bytes(p.q8);
  }
  return w.finish();
}

export function readShard(body: Uint8Array): ShardPaper[] {
  const r = new Reader(body), out: ShardPaper[] = [];
  while (!r.done) {
    const sourceID = new TextDecoder().decode(r.take(r.u8()));
    const announcedOn = dayString(r.u16());
    out.push({ sourceID, announcedOn, q8: r.take(Q8_BYTES).slice() });
  }
  return out;
}

// ---------- term statistics ----------

export interface TermStat { term: string; df: number; conceptness: number }

/** Phrases sorted bytewise (UTF-8), front-coded. Conceptness is stored in thousandths, clamped to ±0.127. */
export function termsBody(terms: TermStat[]): Uint8Array {
  const enc = new TextEncoder();
  const sorted = terms.map(t => ({ ...t, bytes: enc.encode(t.term) })).sort((a, b) => compareBytes(a.bytes, b.bytes));
  const w = new Writer();
  let prev = new Uint8Array(0);
  for (const t of sorted) {
    if (t.bytes.includes(0)) throw new Error('interest_term_invalid');
    let p = 0;
    while (p < 255 && p < t.bytes.length && p < prev.length && t.bytes[p] === prev[p]) p++;
    w.u8(p); w.bytes(t.bytes.subarray(p)); w.u8(0); w.varint(t.df);
    w.u8(Math.max(-127, Math.min(127, Math.round(t.conceptness * 1000))) & 0xff);
    prev = t.bytes;
  }
  return w.finish();
}

export function readTerms(body: Uint8Array): TermStat[] {
  const r = new Reader(body), dec = new TextDecoder(), out: TermStat[] = [];
  let prev = new Uint8Array(0);
  while (!r.done) {
    const shared = r.u8();
    const start = r.offset;
    while (r.data[r.offset] !== 0) r.offset++;
    const suffix = r.data.subarray(start, r.offset);
    r.offset++;
    const bytes = new Uint8Array(shared + suffix.length);
    bytes.set(prev.subarray(0, shared)); bytes.set(suffix, shared);
    const df = r.varint();
    const conceptness = r.i8() / 1000;
    out.push({ term: dec.decode(bytes), df, conceptness });
    prev = bytes;
  }
  return out;
}

function compareBytes(a: Uint8Array, b: Uint8Array): number {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return a[i] - b[i];
  return a.length - b.length;
}

// ---------- map ----------

export interface MapNode {
  id: number; level: 1 | 2 | 3; parent: number | null; size: number; terms: string[];
  central: { source_id: string; title: string }[]; name: string | null;
}

export function mapBody(centroids: ArrayLike<number>[]): Uint8Array {
  const w = new Writer();
  for (const c of centroids) w.bytes(quantize(c));
  return w.finish();
}

export function readMapCentroids(body: Uint8Array, count: number): Float32Array[] {
  if (body.length !== count * Q8_BYTES) throw new Error('interest_map_body');
  return Array.from({ length: count }, (_, i) => normalize(dequantize(body, i * Q8_BYTES)));
}
