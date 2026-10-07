// Verified reader bundles — a port of ScienceReaderCore ReaderBundle.swift (VerifiedReaderBundle),
// ReaderDelivery.swift (descriptor) and MathpixReaderProvenance.swift. Every byte is checked
// against the trusted manifest digest from `reader-artifact` before anything is shown.
import { type Bytes, canonicalJSON, fromBase64, fromUtf8, isUUID, sha256Hex } from './bytes';
import { auth, BackendError, config, functionGet, signedMember } from './backend';
import { cancellation } from './cancellation';

export class BundleError extends Error {}
const fail = (what: string): never => { throw new BundleError(what); };

export interface Member { path: string; role: string; media_type: string; bytes: number; sha256: string; width?: number; height?: number }
export interface Manifest { format: string; renderer: { id: string; build_sha256: string }; source: { kind: string; sha256: string; provenance_path: string };
  entrypoint: string; index_path: string; members: Member[] }
export interface ReaderIndex { format: string; title: string; headings: { id: string; level: number; title: string }[]; blocks: { id: string; kind: string; text: string }[];
  equations: { id: string; block_id: string; latex: string; display: boolean; source_form: string }[]; figures: { id: string; block_id: string; asset_paths: string[]; caption: string; alt: string }[] }
export interface VerifiedBundle { manifestSHA256: string; manifest: Manifest; index: ReaderIndex; contents: Map<string, Bytes> }

interface Profile { renderer: string; source: string; images: string[]; equations: number; figures: number; blocks: number; headings: number; indexBytes: number; pixels: number }
const PROFILES: Profile[] = [
  { renderer: 'timestep-mmd-v1', source: 'authored-mmd', images: ['image/png'], equations: 512, figures: 128, blocks: 5000, headings: 500, indexBytes: 2_097_152, pixels: 16_000_000 },
  { renderer: 'timestep-mathpix-mathml-v1', source: 'mathpix-mmd', images: ['image/png', 'image/jpeg'], equations: 4000, figures: 256, blocks: 20_000, headings: 1000, indexBytes: 4_194_304, pixels: 64_000_000 },
];
/** The frame bridge must admit every contents list accepted by the bundle verifier. */
export const MAXIMUM_READER_HEADINGS = Math.max(...PROFILES.map(profile => profile.headings));
const MATHPIX_OCR_API = 'v3/pdf', MATHPIX_PROFILE = 'science-reader-mmd-v1';

const isDigest = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{64}$/.test(v);
const utf8Length = (s: string) => new TextEncoder().encode(s).length;
const boundedText = (v: unknown, max = 20_000): v is string => typeof v === 'string' && utf8Length(v) <= max && !v.includes('\0');
const validID = (v: unknown): v is string => typeof v === 'string' && /^[0-9A-Za-z_-]{1,200}$/.test(v);
const validPath = (v: string) => utf8Length(v) >= 1 && utf8Length(v) <= 240 && v.split('/').every(p => /^[0-9A-Za-z][0-9A-Za-z_.-]*$/.test(p));
const integer = (v: unknown, lo: number, hi: number): number => typeof v === 'number' && Number.isInteger(v) && v >= lo && v <= hi ? v : fail('resource');
const json = (bytes: Uint8Array, what: string): unknown => { try { return JSON.parse(fromUtf8(bytes)); } catch { return fail(what); } };

function validateManifest(m: Manifest): Profile {
  if (m?.format !== 'reader-bundle-v1') return fail('incompatible_format');
  const profile = PROFILES.find(p => p.renderer === m.renderer?.id && p.source === m.source?.kind);
  if (!profile) return fail('incompatible_format');
  if (!isDigest(m.renderer.build_sha256) || !isDigest(m.source.sha256) || !Array.isArray(m.members) || m.members.length < 1 || m.members.length > 512) fail('manifest');
  const mime: Record<string, string[]> = { html: ['text/html'], index: ['application/json'], style: ['text/css'], image: profile.images,
    provenance: ['application/json'], notice: ['text/plain'] };
  const paths = new Set<string>();
  let total = 0, pixels = 0;
  for (const member of m.members) {
    if (typeof member.path !== 'string' || !validPath(member.path) || member.path.toLowerCase() === 'manifest.json' || paths.has(member.path.toLowerCase())
      || !mime[member.role]?.includes(member.media_type) || !Number.isInteger(member.bytes) || member.bytes < 0 || member.bytes > 16_777_216 || !isDigest(member.sha256)) fail('manifest');
    paths.add(member.path.toLowerCase());
    total += member.bytes;
    if (member.role === 'html' && member.bytes > 8_388_608) fail('manifest');
    if (m.source.kind === 'mathpix-mmd' && member.role === 'provenance' && (member.bytes < 1 || member.bytes > 262_144)) fail('manifest');
    if (member.role === 'image') {
      const w = member.width, h = member.height;
      if (!Number.isInteger(w) || !Number.isInteger(h) || w! < 1 || w! > 8192 || h! < 1 || h! > 8192 || w! * h! > 16_000_000) fail('manifest');
      pixels += w! * h!;
    } else if (member.width !== undefined || member.height !== undefined) fail('manifest');
  }
  const count = (role: string) => m.members.filter(x => x.role === role).length;
  const has = (path: string, role: string) => m.members.some(x => x.path === path && x.role === role);
  if (total > 33_554_432 || pixels > profile.pixels || count('html') !== 1 || count('index') !== 1 || count('provenance') !== 1
    || !has(m.entrypoint, 'html') || !has(m.index_path, 'index') || !has(m.source.provenance_path, 'provenance')) fail('manifest');
  for (const member of m.members) {
    const parts = member.path.toLowerCase().split('/');
    for (let n = 1; n < parts.length; n++) if (paths.has(parts.slice(0, n).join('/'))) fail('manifest');
  }
  return profile;
}

function validateIndex(index: ReaderIndex, manifest: Manifest, profile: Profile): void {
  if (index?.format !== 'reader-index-v1' || !boundedText(index.title, 2000) || !index.title || !Array.isArray(index.headings) || index.headings.length > profile.headings
    || !Array.isArray(index.blocks) || index.blocks.length < 1 || index.blocks.length > profile.blocks || !Array.isArray(index.equations)
    || index.equations.length > profile.equations || !Array.isArray(index.figures) || index.figures.length > profile.figures) fail('index');
  const kinds = new Set(['heading', 'paragraph', 'equation', 'figure', 'table', 'list', 'code']);
  const blocks = new Map<string, ReaderIndex['blocks'][number]>();
  for (const b of index.blocks) {
    if (!validID(b.id) || blocks.has(b.id) || !kinds.has(b.kind) || !boundedText(b.text)) fail('index');
    blocks.set(b.id, b);
  }
  const headings = new Set<string>(), equations = new Set<string>(), figures = new Set<string>();
  for (const h of index.headings) {
    if (headings.has(h.id) || blocks.get(h.id)?.kind !== 'heading' || !Number.isInteger(h.level) || h.level < 1 || h.level > 6 || !boundedText(h.title, 2000) || !h.title) fail('index');
    headings.add(h.id);
  }
  for (const e of index.equations) {
    if (!validID(e.id) || equations.has(e.id) || blocks.has(e.id) || !blocks.has(e.block_id) || !e.latex || !boundedText(e.latex)
      || !(e.source_form === 'body' || (e.source_form === 'environment' && e.display === true)) || typeof e.display !== 'boolean') fail('index');
    equations.add(e.id);
  }
  const images = new Set(manifest.members.filter(x => x.role === 'image').map(x => x.path));
  for (const f of index.figures) {
    if (f.id !== f.block_id || figures.has(f.id) || blocks.get(f.block_id)?.kind !== 'figure' || !boundedText(f.caption) || !boundedText(f.alt)
      || !Array.isArray(f.asset_paths) || f.asset_paths.length < 1 || f.asset_paths.length > 16 || new Set(f.asset_paths).size !== f.asset_paths.length
      || !f.asset_paths.every(p => images.has(p))) fail('index');
    figures.add(f.id);
  }
}

function validateProvenance(data: Bytes, manifest: Manifest, index: ReaderIndex): void {
  if (data.length < 1 || data.length > 262_144) fail('resource');
  const value = json(data, 'resource');
  const object = (v: unknown, keys: string[]) => {
    if (!v || typeof v !== 'object' || Array.isArray(v) || canonicalJSON(Object.keys(v).sort()) !== canonicalJSON([...keys].sort())) fail('resource');
    return v as Record<string, unknown>;
  };
  const root = object(value, ['format', 'ocr', 'provider_job_id', 'document', 'source', 'renderer', 'image_inputs']);
  // The exact sorted-key JSON plus LF rejects duplicate keys and alternate spellings.
  if (canonicalJSON(value) + '\n' !== fromUtf8(data) || root.format !== 'mathpix-reader-provenance-v2'
    || typeof root.provider_job_id !== 'string' || !/^[0-9A-Za-z_-]{1,160}$/.test(root.provider_job_id)) fail('resource');
  const ocr = object(root.ocr, ['api', 'profile', 'options_sha256']);
  if (ocr.api !== MATHPIX_OCR_API || ocr.profile !== MATHPIX_PROFILE || !isDigest(ocr.options_sha256)) fail('resource');
  const document = object(root.document, ['sha256', 'page_count']);
  if (!isDigest(document.sha256)) fail('resource');
  integer(document.page_count, 1, 250);
  // reader-zip-v1's canonical archive path subset (identities only; never opened or fetched).
  const archivePath = (p: unknown): p is string => {
    if (typeof p !== 'string' || utf8Length(p) < 1 || utf8Length(p) > 240) return false;
    const parts = p.split('/');
    return parts.length >= 1 && parts.length <= 8 && parts.every(part => {
      if (!/^[0-9A-Za-z_-][0-9A-Za-z_.-]*$/.test(part) || part.endsWith('.')) return false;
      const name = part.split('.')[0].toLowerCase();
      return !['con', 'prn', 'aux', 'nul'].includes(name) && !/^(com|lpt)[1-9]$/.test(name);
    });
  };
  const source = object(root.source, ['archive_path', 'bytes', 'sha256']);
  if (!archivePath(source.archive_path) || !source.archive_path.endsWith('.mmd') || source.sha256 !== manifest.source.sha256) fail('resource');
  integer(source.bytes, 1, 2_097_152);
  const renderer = object(root.renderer, ['id', 'build_sha256']);
  if (renderer.id !== manifest.renderer.id || renderer.build_sha256 !== manifest.renderer.build_sha256) fail('resource');
  if (!Array.isArray(root.image_inputs) || root.image_inputs.length > 512) fail('resource');
  const images = new Map(manifest.members.filter(x => x.role === 'image').map(x => [x.path, x]));
  let previous: string | null = null;
  const published = new Set<string>();
  for (const raw of root.image_inputs as unknown[]) {
    const row = object(raw, ['archive_path', 'input_sha256', 'published_path', 'published_sha256', 'media_type', 'width', 'height']);
    const suffix = ({ 'image/jpeg': 'jpg', 'image/png': 'png' } as Record<string, string>)[row.media_type as string];
    const image = images.get(row.published_path as string);
    if (!archivePath(row.archive_path) || row.archive_path === source.archive_path || (previous !== null && !(previous < row.archive_path))
      || !isDigest(row.input_sha256) || !isDigest(row.published_sha256) || !suffix || row.published_path !== `assets/${row.published_sha256}.${suffix}`
      || !image || image.media_type !== row.media_type || image.sha256 !== row.published_sha256) fail('resource');
    if (integer(row.width, 1, 8192) !== image!.width || integer(row.height, 1, 8192) !== image!.height) fail('resource');
    previous = row.archive_path as string;
    published.add(row.published_path as string);
  }
  const referenced = new Set(index.figures.flatMap(f => f.asset_paths));
  const sameSet = (a: Set<string>, b: Set<string>) => a.size === b.size && [...a].every(x => b.has(x));
  if (!sameSet(published, new Set(images.keys())) || !sameSet(referenced, published) || !index.figures.every(f => f.alt)) fail('resource');
}

export type ImageCheck = (bytes: Bytes, mediaType: string) => Promise<{ width: number; height: number }>;

/** Decodes a raster fully (the native admission) and returns its pixel size. */
export const browserImageCheck: ImageCheck = async (bytes, mediaType) => {
  const magic = mediaType === 'image/png' ? [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] : [0xff, 0xd8, 0xff];
  if (!magic.every((b, i) => bytes[i] === b)) fail('resource');
  const bitmap = await createImageBitmap(new Blob([bytes], { type: mediaType })).catch(() => fail('resource'));
  const size = { width: bitmap.width, height: bitmap.height };
  bitmap.close();
  return size;
};

/** VerifiedReaderBundle.verify: the manifest digest must come from a trusted descriptor. */
export async function verifyBundle(manifestBytes: Bytes, expectedSHA256: string, members: Map<string, Bytes>, imageCheck: ImageCheck = browserImageCheck): Promise<VerifiedBundle> {
  if (manifestBytes.length > 262_144 || !isDigest(expectedSHA256) || await sha256Hex(manifestBytes) !== expectedSHA256) fail('integrity');
  const manifest = json(manifestBytes, 'manifest') as Manifest;
  const profile = validateManifest(manifest);
  if (members.size !== manifest.members.length || !manifest.members.every(m => members.has(m.path))) fail('resource');
  for (const member of manifest.members) {
    const bytes = members.get(member.path)!;
    if (bytes.length !== member.bytes || await sha256Hex(bytes) !== member.sha256) fail('integrity');
  }
  const indexBytes = members.get(manifest.index_path)!;
  if (indexBytes.length > profile.indexBytes) fail('index');
  const index = json(indexBytes, 'index') as ReaderIndex;
  validateIndex(index, manifest, profile);
  if (manifest.source.kind === 'mathpix-mmd') validateProvenance(members.get(manifest.source.provenance_path)!, manifest, index);
  for (const member of manifest.members.filter(m => m.role === 'image')) {
    const size = await imageCheck(members.get(member.path)!, member.media_type);
    if (size.width !== member.width || size.height !== member.height) fail('resource');
  }
  return { manifestSHA256: expectedSHA256, manifest, index, contents: members };
}

interface Descriptor { item_id: string; document_id: string; artifact_id: string; renderer_version: string; manifest_sha256: string; manifest: string;
  members: { path: string; sha256: string; bytes: number; url: string }[] }

/** Authorizes the download (reader-artifact), fetches each signed member and verifies everything. */
export async function loadBundle(account: string, itemID: string, signal?: AbortSignal, onProgress?: (fraction: number) => void): Promise<VerifiedBundle> {
  const scope = cancellation([auth.snapshot().signal, signal]);
  try {
    const bundle = await downloadBundle(account, itemID, scope.signal, onProgress);
    scope.signal.throwIfAborted();
    return bundle;
  } finally { scope.abort(); }
}

async function downloadBundle(account: string, itemID: string, signal: AbortSignal, onProgress?: (fraction: number) => void): Promise<VerifiedBundle> {
  const d = await functionGet<Descriptor>(`reader-artifact?item_id=${itemID}`, { maximum: 1_048_576, account, signal });
  const origin = new URL(config.url).origin;
  if (!d || !isUUID(d.item_id) || d.item_id.toLowerCase() !== itemID || !isDigest(d.manifest_sha256) || typeof d.renderer_version !== 'string' || d.renderer_version.length > 64
    || !Array.isArray(d.members) || d.members.length < 1 || d.members.length > 512 || new Set(d.members.map(m => m.path)).size !== d.members.length) fail('descriptor');
  const manifestBytes = fromBase64(d.manifest);
  if (manifestBytes.length > 262_144) fail('descriptor');
  let total = 0;
  for (const m of d.members) {
    if (!isDigest(m.sha256) || !Number.isInteger(m.bytes) || m.bytes < 1 || m.bytes > 16_777_216 || typeof m.path !== 'string' || !m.path || m.path.includes('..')
      || m.path.startsWith('/') || typeof m.url !== 'string' || new URL(m.url).origin !== origin) fail('descriptor');
    total += m.bytes;
  }
  if (total > 33_554_432) fail('descriptor');
  const members = new Map<string, Bytes>();
  let done = 0, received = 0;
  const queue = [...d.members];
  const worker = async () => {
    for (let m = queue.shift(); m; m = queue.shift()) {
      const bytes = await signedMember(m.url, m.bytes, signal);
      if (await sha256Hex(bytes) !== m.sha256) throw new BundleError('integrity');
      members.set(m.path, bytes);
      done++; received += bytes.length; onProgress?.(received / total);
    }
  };
  await Promise.all(Array.from({ length: Math.min(6, d.members.length) }, worker));
  if (done !== d.members.length) throw new BackendError('reader_not_ready');
  return verifyBundle(manifestBytes, d.manifest_sha256, members);
}
