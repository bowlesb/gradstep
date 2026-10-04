import { ARCHIVE_LIMITS, ArchiveError, unpackReaderZip } from './archive.ts';
import { sha256 } from './http.ts';
import { MATHPIX_PROFILE, mathpixProfile } from './mathpix.ts';
import type { MathpixConversion, MathpixStatus } from './mathpix.ts';

// Pure retained-output boundary. No submission, fetch, storage or settlement
// authority is accepted here. These are payload limits, not host-memory limits.
export const MATHPIX_OPTIONS_SHA256 = '1e817fa114840383c016f89f51a562ca8c90afb07d0cae3673036e8ce1b931b3';
export const MATHPIX_RESULT_LIMITS = Object.freeze({
  manifestBytes: 262_144, standaloneBytes: 8_388_608,
  archiveBytes: 33_554_432, linesBytes: 16_777_216,
});
export type MathpixResultErrorCode = 'binding_mismatch' | 'output_incomplete' | 'output_limit' |
  'archive_invalid' | 'mmd_ambiguous' | 'unsupported_content' | 'cancelled';
export class MathpixResultError extends Error {
  readonly code: MathpixResultErrorCode;
  constructor(code: MathpixResultErrorCode) { super(code); this.name = 'MathpixResultError'; this.code = code; }
}
export interface MathpixFileIdentity { path: string; bytes: number; sha256: string; }
export interface MathpixOutputIdentity extends MathpixFileIdentity {
  role: 'standalone_mmd' | 'mmd_archive' | 'auxiliary_lines';
}
export interface MathpixRawManifest {
  format: 'mathpix-raw-result-v1';
  document: { id: string; original_object_id: string; sha256: string; bytes: number; page_count: number };
  attempt: { ocr_run_id: string; id: string; provider_scope_id: string; provider_job_id: string };
  ocr: { api: 'v3/pdf'; profile: 'science-reader-mmd-v1'; options_sha256: string };
  completion: { status: MathpixStatus; conversion: MathpixConversion };
  outputs: MathpixOutputIdentity[];
  archive_entries: MathpixFileIdentity[];
  render_source: MathpixFileIdentity;
}
export type MathpixResultBinding = Pick<MathpixRawManifest, 'document' | 'attempt' | 'ocr'>;
export interface MathpixRawResult {
  manifestBytes: Uint8Array;
  manifestSHA256: string;
  rawMembers: Map<string, Uint8Array>;
}
export interface MathpixRenderInput {
  rawManifestBytes: Uint8Array;
  expectedRawManifestSHA256: string;
  archiveMembers: Map<string, Uint8Array>;
}
export interface CaptureMathpixResultInput {
  binding: MathpixResultBinding;
  status: MathpixStatus;
  conversion: MathpixConversion;
  standaloneMMD: Uint8Array;
  archive: Uint8Array;
  linesJSON: Uint8Array;
}
export interface OpenMathpixResultInput {
  manifestBytes: Uint8Array;
  expectedSHA256: string;
  rawMembers: Map<string, Uint8Array>;
}

const encoder = new TextEncoder();
const typedArrayByteLength = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), 'byteLength')!.get!;
const HEX = /^[a-f0-9]{64}$/;
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const OUTPUTS = [
  { path: 'lines.json', role: 'auxiliary_lines', maximum: MATHPIX_RESULT_LIMITS.linesBytes },
  { path: 'output.mmd.zip', role: 'mmd_archive', maximum: MATHPIX_RESULT_LIMITS.archiveBytes },
  { path: 'standalone.mmd', role: 'standalone_mmd', maximum: MATHPIX_RESULT_LIMITS.standaloneBytes },
] as const;
function fail(code: MathpixResultErrorCode = 'binding_mismatch'): never { throw new MathpixResultError(code); }
function finiteError(error: unknown): never {
  if (error instanceof MathpixResultError) throw error;
  if (error instanceof ArchiveError) {
    if (error.code === 'archive_cancelled') fail('cancelled');
    if (error.code === 'archive_limit') fail('output_limit');
    fail('archive_invalid');
  }
  fail();
}
function cancelled(signal?: AbortSignal): void { if (signal?.aborted) fail('cancelled'); }
function record(value: unknown, keys: readonly string[]): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
    ![Object.prototype, null].includes(Object.getPrototypeOf(value))) fail();
  const descriptors = Object.getOwnPropertyDescriptors(value), names = Reflect.ownKeys(descriptors);
  if (names.length !== keys.length || names.some(key => typeof key !== 'string' || !keys.includes(key))) fail();
  const owned: Record<string, unknown> = {};
  for (const key of keys) {
    const field = descriptors[key];
    if (!field || !('value' in field) || !field.enumerable) fail();
    owned[key] = field.value;
  }
  return owned;
}
function text(value: unknown, pattern: RegExp): string {
  if (typeof value !== 'string' || !pattern.test(value)) fail();
  return value;
}
function integer(value: unknown, minimum: number, maximum: number, code: MathpixResultErrorCode = 'binding_mismatch'): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || Object.is(value, -0) || value < minimum || value > maximum) fail(code);
  return value;
}
function array(value: unknown, maximum: number): unknown[] {
  if (!Array.isArray(value)) fail();
  if (value.length > maximum) fail('output_limit');
  // Only dense ordinary JSON arrays. Capture each data slot before any await.
  const descriptors = Object.getOwnPropertyDescriptors(value);
  if (Reflect.ownKeys(descriptors).length !== value.length + 1) fail();
  return Array.from({ length: value.length }, (_, n) => {
    const field = descriptors[String(n)];
    if (!field || !('value' in field) || !field.enumerable) fail();
    return field.value;
  });
}
function byteLength(value: unknown, maximum: number, minimum = 1): number {
  if (!(value instanceof Uint8Array)) fail('output_incomplete');
  // Instance/subclass getters cannot shrink the extent used for admission.
  const length = typedArrayByteLength.call(value) as number;
  if (length < minimum) fail('output_incomplete');
  if (length > maximum) fail('output_limit');
  return length;
}
function bytes(value: unknown, maximum: number): Uint8Array {
  const length = byteLength(value, maximum), owned = new Uint8Array(value as Uint8Array);
  if (owned.byteLength !== length) fail();
  return owned; // Buffer.slice() would alias caller storage.
}

// Exact file-name subset used by reader-zip-v1 (directories are not members of
// the expanded file map). Kept public for renderer token/provenance validation.
export function isMathpixArchivePath(value: unknown): value is string {
  if (typeof value !== 'string' || !value.length || value.length > ARCHIVE_LIMITS.pathBytes || /[^\x00-\x7f]/.test(value)) return false;
  const parts = value.split('/');
  return parts.length <= ARCHIVE_LIMITS.depth && parts.every(part =>
    /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(part) && !part.endsWith('.') &&
    !/^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part));
}
function file(value: unknown): MathpixFileIdentity {
  const entry = record(value, ['path', 'bytes', 'sha256']);
  if (!isMathpixArchivePath(entry.path)) fail();
  return { path: entry.path, bytes: integer(entry.bytes, 0, ARCHIVE_LIMITS.fileBytes, 'output_limit'), sha256: text(entry.sha256, HEX) };
}
function checkPaths(paths: string[]): void {
  const folded = new Set<string>();
  for (const path of paths) {
    if (!isMathpixArchivePath(path) || folded.has(path.toLowerCase())) fail();
    folded.add(path.toLowerCase());
  }
  for (const path of folded) {
    const parts = path.split('/');
    for (let n = 1; n < parts.length; n++) if (folded.has(parts.slice(0, n).join('/'))) fail();
  }
}
function binding(value: unknown): MathpixResultBinding {
  const top = record(value, ['document', 'attempt', 'ocr']);
  const d = record(top.document, ['id', 'original_object_id', 'sha256', 'bytes', 'page_count']);
  const a = record(top.attempt, ['ocr_run_id', 'id', 'provider_scope_id', 'provider_job_id']);
  const o = record(top.ocr, ['api', 'profile', 'options_sha256']);
  if (o.api !== 'v3/pdf' || o.profile !== MATHPIX_PROFILE || o.options_sha256 !== MATHPIX_OPTIONS_SHA256) fail();
  return {
    document: { id: text(d.id, UUID), original_object_id: text(d.original_object_id, UUID), sha256: text(d.sha256, HEX),
      bytes: integer(d.bytes, 8, 33_554_432), page_count: integer(d.page_count, 1, 250) },
    attempt: { ocr_run_id: text(a.ocr_run_id, UUID), id: text(a.id, UUID),
      provider_scope_id: text(a.provider_scope_id, /^[A-Za-z0-9_-]{1,128}$/), provider_job_id: text(a.provider_job_id, /^[A-Za-z0-9_-]{1,160}$/) },
    ocr: { api: 'v3/pdf', profile: MATHPIX_PROFILE, options_sha256: MATHPIX_OPTIONS_SHA256 },
  };
}
function completion(status: unknown, conversion: unknown, b: MathpixResultBinding): MathpixRawManifest['completion'] {
  const s = record(status, ['providerJobID', 'state', 'pages', 'completedPages', 'pipelineVersion', 'deleted', 'errorCode']);
  const c = record(conversion, ['providerJobID', 'state', 'errorCode']);
  if (s.providerJobID !== b.attempt.provider_job_id || c.providerJobID !== b.attempt.provider_job_id ||
    typeof s.state !== 'string' || !['received', 'loaded', 'split', 'processing', 'completed', 'error'].includes(s.state) ||
    typeof c.state !== 'string' || !['received', 'loaded', 'processing', 'completed', 'error', 'missing'].includes(c.state) ||
    typeof s.deleted !== 'boolean' ||
    (s.pipelineVersion !== null && (typeof s.pipelineVersion !== 'string' || s.pipelineVersion.length > 128))) fail();
  for (const error of [s.errorCode, c.errorCode]) if (error !== null) text(error, /^[a-zA-Z0-9_-]{1,80}$/);
  const pages = s.pages === null ? null : integer(s.pages, 0, 250);
  const completedPages = s.completedPages === null ? null : integer(s.completedPages, 0, 250);
  if (s.state !== 'completed' || c.state !== 'completed' || s.deleted || s.errorCode !== null || c.errorCode !== null) fail('output_incomplete');
  if ([pages, completedPages].some(count => count !== null && count !== b.document.page_count)) fail();
  return {
    status: { providerJobID: b.attempt.provider_job_id, state: 'completed', pages, completedPages,
      pipelineVersion: s.pipelineVersion as string | null, deleted: false, errorCode: null },
    conversion: { providerJobID: b.attempt.provider_job_id, state: 'completed', errorCode: null },
  };
}
function source(entries: MathpixFileIdentity[]): MathpixFileIdentity {
  const candidates = entries.filter(entry => entry.path.endsWith('.mmd'));
  if (candidates.length !== 1) fail('mmd_ambiguous');
  if (!candidates[0].bytes) fail('unsupported_content');
  return { ...candidates[0] };
}
function sameFile(a: MathpixFileIdentity, b: MathpixFileIdentity): boolean {
  return a.path === b.path && a.bytes === b.bytes && a.sha256 === b.sha256;
}
function schema(value: unknown): MathpixRawManifest {
  const m = record(value, ['format', 'document', 'attempt', 'ocr', 'completion', 'outputs', 'archive_entries', 'render_source']);
  if (m.format !== 'mathpix-raw-result-v1') fail();
  const b = binding({ document: m.document, attempt: m.attempt, ocr: m.ocr });
  const done = record(m.completion, ['status', 'conversion']);
  const outputs = array(m.outputs, 3).map((value, n): MathpixOutputIdentity => {
    const output = record(value, ['path', 'role', 'bytes', 'sha256']), expected = OUTPUTS[n];
    if (output.path !== expected.path || output.role !== expected.role) fail();
    return { path: expected.path, role: expected.role, bytes: integer(output.bytes, 1, expected.maximum, 'output_limit'), sha256: text(output.sha256, HEX) };
  });
  if (outputs.length !== 3) fail('output_incomplete');
  const entries = array(m.archive_entries, ARCHIVE_LIMITS.entries).map(file);
  let total = 0;
  for (let n = 0; n < entries.length; n++) {
    total += entries[n].bytes;
    if (n && entries[n - 1].path >= entries[n].path) fail();
  }
  if (total > ARCHIVE_LIMITS.expandedBytes) fail('output_limit');
  checkPaths(entries.map(entry => entry.path));
  const selected = file(m.render_source);
  if (!sameFile(selected, source(entries))) fail();
  return { format: 'mathpix-raw-result-v1', ...b, completion: completion(done.status, done.conversion, b),
    outputs, archive_entries: entries, render_source: selected };
}

// Called only with our closed typed schema, never with arbitrary auxiliary JSON.
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map(key => `${JSON.stringify(key)}:${canonical(object[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}
function encodeManifest(manifest: MathpixRawManifest): Uint8Array {
  const raw = encoder.encode(`${canonical(manifest)}\n`);
  if (raw.length > MATHPIX_RESULT_LIMITS.manifestBytes) fail('output_limit');
  return raw;
}
function utf8(raw: Uint8Array): string {
  try { return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(raw); }
  catch { fail('unsupported_content'); }
}
function mmd(raw: Uint8Array): void {
  const value = utf8(raw);
  if (!value.length || value.includes('\0')) fail('unsupported_content');
}
function lines(raw: Uint8Array, pageCount: number): void {
  let value: unknown;
  try { value = JSON.parse(utf8(raw)); } catch { fail('unsupported_content'); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail('unsupported_content');
  const pages = (value as Record<string, unknown>).pages;
  if (!Array.isArray(pages) || pages.length !== pageCount || pages.some(page => !page || typeof page !== 'object' || Array.isArray(page))) fail('unsupported_content');
  // Geometry/text remain untrusted retained bytes. Do not return this tree.
}
function parseManifest(raw: Uint8Array): MathpixRawManifest {
  let value: unknown;
  try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(raw)); } catch { fail(); }
  const parsed = schema(value), canonicalBytes = encodeManifest(parsed);
  if (raw.length !== canonicalBytes.length || raw.some((byte, n) => byte !== canonicalBytes[n])) fail();
  return parsed;
}
function ownMap(value: unknown, expanded: boolean): Map<string, Uint8Array> {
  if (!(value instanceof Map)) fail('output_incomplete');
  const size = Object.getOwnPropertyDescriptor(Map.prototype, 'size')!.get!.call(value);
  if (size > (expanded ? ARCHIVE_LIMITS.entries : 3)) fail('output_limit');
  const entries = [...Map.prototype.entries.call(value)] as [unknown, unknown][];
  if (!expanded && size !== 3) fail('output_incomplete');
  let total = 0;
  const lengths: number[] = [];
  for (const [path, data] of entries) {
    const output = OUTPUTS.find(output => output.path === path);
    if (expanded ? !isMathpixArchivePath(path) : !output) fail();
    const length = byteLength(data, expanded ? ARCHIVE_LIMITS.fileBytes : output!.maximum, expanded ? 0 : 1);
    lengths.push(length); total += length;
  }
  if (expanded && total > ARCHIVE_LIMITS.expandedBytes) fail('output_limit');
  checkPaths(entries.map(([path]) => path as string));
  return new Map(entries.map(([path, data], n) => {
    const owned = new Uint8Array(data as Uint8Array);
    if (owned.byteLength !== lengths[n]) fail();
    return [path as string, owned];
  }));
}
async function hash(raw: Uint8Array, signal?: AbortSignal): Promise<string> {
  cancelled(signal);
  const digest = await sha256(raw);
  cancelled(signal);
  return digest;
}
async function profile(signal?: AbortSignal): Promise<void> {
  cancelled(signal);
  const actual = await mathpixProfile();
  cancelled(signal);
  if (actual.api !== 'v3/pdf' || actual.id !== MATHPIX_PROFILE || actual.sha256 !== MATHPIX_OPTIONS_SHA256) fail();
}
async function inventory(members: Map<string, Uint8Array>, signal?: AbortSignal): Promise<MathpixFileIdentity[]> {
  const result: MathpixFileIdentity[] = [];
  for (const path of [...members.keys()].sort()) {
    const raw = members.get(path)!;
    result.push({ path, bytes: raw.length, sha256: await hash(raw, signal) });
  }
  return result;
}
async function expanded(archive: Uint8Array, signal?: AbortSignal): Promise<Map<string, Uint8Array>> {
  return new Map((await unpackReaderZip(archive, signal)).map(file => [file.path, file.bytes]));
}
async function checkInventory(manifest: MathpixRawManifest, members: Map<string, Uint8Array>, signal?: AbortSignal): Promise<void> {
  const actual = await inventory(members, signal);
  if (actual.length !== manifest.archive_entries.length || actual.some((entry, n) => !sameFile(entry, manifest.archive_entries[n]))) fail();
  mmd(members.get(manifest.render_source.path)!);
}

export async function captureMathpixResult(input: CaptureMathpixResultInput, signal?: AbortSignal): Promise<MathpixRawResult> {
  try {
    cancelled(signal);
    const captured = record(input, ['binding', 'status', 'conversion', 'standaloneMMD', 'archive', 'linesJSON']);
    const b = binding(captured.binding), done = completion(captured.status, captured.conversion, b);
    const rawMembers = ownMap(new Map([
      ['lines.json', captured.linesJSON], ['output.mmd.zip', captured.archive], ['standalone.mmd', captured.standaloneMMD],
    ]), false);
    // Every byte and checkpoint scalar above is now owned before the first await.
    mmd(rawMembers.get('standalone.mmd')!);
    lines(rawMembers.get('lines.json')!, b.document.page_count);
    await profile(signal);
    const members = await expanded(rawMembers.get('output.mmd.zip')!, signal);
    const entries = await inventory(members, signal), selected = source(entries);
    mmd(members.get(selected.path)!);
    const outputs: MathpixOutputIdentity[] = [];
    for (const item of OUTPUTS) {
      const raw = rawMembers.get(item.path)!;
      outputs.push({ path: item.path, role: item.role, bytes: raw.length, sha256: await hash(raw, signal) });
    }
    const manifest: MathpixRawManifest = { format: 'mathpix-raw-result-v1', ...b, completion: done, outputs, archive_entries: entries, render_source: selected };
    const manifestBytes = encodeManifest(schema(manifest));
    return { manifestBytes, manifestSHA256: await hash(manifestBytes, signal), rawMembers };
  } catch (error) { finiteError(error); }
}

export async function openMathpixResult(input: OpenMathpixResultInput, signal?: AbortSignal): Promise<MathpixRenderInput> {
  try {
    cancelled(signal);
    const captured = record(input, ['manifestBytes', 'expectedSHA256', 'rawMembers']);
    const rawManifestBytes = bytes(captured.manifestBytes, MATHPIX_RESULT_LIMITS.manifestBytes);
    const expectedRawManifestSHA256 = text(captured.expectedSHA256, HEX), rawMembers = ownMap(captured.rawMembers, false);
    const manifest = parseManifest(rawManifestBytes);
    await profile(signal);
    if (await hash(rawManifestBytes, signal) !== expectedRawManifestSHA256) fail();
    for (const output of manifest.outputs) {
      const raw = rawMembers.get(output.path)!;
      if (raw.length !== output.bytes || await hash(raw, signal) !== output.sha256) fail();
    }
    mmd(rawMembers.get('standalone.mmd')!);
    lines(rawMembers.get('lines.json')!, manifest.document.page_count);
    const archiveMembers = await expanded(rawMembers.get('output.mmd.zip')!, signal);
    await checkInventory(manifest, archiveMembers, signal);
    cancelled(signal);
    return { rawManifestBytes, expectedRawManifestSHA256, archiveMembers };
  } catch (error) { finiteError(error); }
}

// Receiving-process seam: an in-memory DTO is not trusted merely because another
// caller opened it. Copy ALL entries (including unused files), then revalidate.
export async function validateMathpixRenderInput(input: MathpixRenderInput, signal?: AbortSignal): Promise<MathpixRenderInput & { manifest: MathpixRawManifest }> {
  try {
    cancelled(signal);
    const captured = record(input, ['rawManifestBytes', 'expectedRawManifestSHA256', 'archiveMembers']);
    const rawManifestBytes = bytes(captured.rawManifestBytes, MATHPIX_RESULT_LIMITS.manifestBytes);
    const expectedRawManifestSHA256 = text(captured.expectedRawManifestSHA256, HEX), archiveMembers = ownMap(captured.archiveMembers, true);
    const manifest = parseManifest(rawManifestBytes);
    await profile(signal);
    if (await hash(rawManifestBytes, signal) !== expectedRawManifestSHA256) fail();
    await checkInventory(manifest, archiveMembers, signal);
    cancelled(signal);
    return { manifest, rawManifestBytes, expectedRawManifestSHA256, archiveMembers };
  } catch (error) { finiteError(error); }
}
