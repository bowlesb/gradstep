// Foreground browser PDF upload (docs/architecture/PDF_UPLOADS.md §2).
//
// This is intentionally the same authenticated, four-megabyte chunk protocol
// as the native queue. It keeps the title out of upload admission, seals the
// title in a library descriptor, refreshes the session revision after receipts,
// and freezes only the exact verified parts. The browser does not claim an
// offline/background queue yet: callers keep the File and the session id in
// memory and may retry the same session while this page remains open.
import { BackendError, functionPost, functionPutBytes, rpc } from './backend';
import { isUUID, sha256Hex, toBytea } from './bytes';
import { type KeyRing } from './wire';
import { sealLibraryDescriptor, type LibraryDescriptorEnvelope } from './library-descriptor';

export const PDF_CHUNK_BYTES = 4_194_304;
export const MAX_PDF_BYTES = 67_108_864;
export const MAX_PDF_PARTS = 16;

export interface BrowserPDFKeys { ring: KeyRing; deviceID: string }
export interface PDFUploadProgress { phase: 'checking' | 'starting' | 'uploading' | 'finishing'; fraction: number }
export interface PDFUploadOptions {
  account: string;
  cursor: number;
  keys: BrowserPDFKeys;
  /** Reuse the exact session after a foreground transport failure. */
  uploadID?: string;
  signal?: AbortSignal;
  onProgress?: (progress: PDFUploadProgress) => void;
  /** Called immediately after admission, before any descriptor/chunk request. */
  onSession?: (uploadID: string) => void;
}
export interface PDFUploadResult { uploadID: string; sourceID: string; state: string }

interface UploadPart { index: number; bytes: number; verified: boolean; attempts: number; uncertain: number }
interface UploadTicket {
  upload_id: string; state: string; revision: number; generation: number; byte_count: number;
  chunk_bytes: number; part_count: number; parts: UploadPart[]; descriptor_required: boolean; descriptor_ref: unknown;
}
interface Receipt { verified?: unknown; uncertain?: unknown }

const states = new Set(['receiving', 'frozen', 'checking', 'consumed', 'finalized']);
const integer = (value: unknown, minimum = 0): value is number => Number.isSafeInteger(value) && (value as number) >= minimum;
function invalid(): never { throw new BackendError('invalid_response'); }
function object(value: unknown): Record<string, unknown> { if (!value || typeof value !== 'object' || Array.isArray(value)) invalid(); return value as Record<string, unknown>; }

/** Validate the server ticket before using any generation, revision or part path. */
export function decodePDFUploadTicket(value: unknown): UploadTicket {
  const v = object(value);
  if (!isUUID(v.upload_id) || typeof v.state !== 'string' || !states.has(v.state)
    || !integer(v.revision, 1) || !integer(v.generation, 1) || !integer(v.byte_count, 1)
    || v.byte_count > MAX_PDF_BYTES || v.chunk_bytes !== PDF_CHUNK_BYTES
    || !integer(v.part_count, 1) || v.part_count > MAX_PDF_PARTS || !Array.isArray(v.parts)
    || v.parts.length !== v.part_count || typeof v.descriptor_required !== 'boolean') invalid();
  const parts: UploadPart[] = [];
  let total = 0;
  for (let i = 0; i < v.parts.length; i++) {
    const p = object(v.parts[i]);
    if (p.index !== i || !integer(p.bytes, 1) || p.bytes > PDF_CHUNK_BYTES || typeof p.verified !== 'boolean'
      || !integer(p.attempts) || !integer(p.uncertain)) invalid();
    total += p.bytes as number;
    parts.push({ index: i, bytes: p.bytes as number, verified: p.verified as boolean, attempts: p.attempts as number, uncertain: p.uncertain as number });
  }
  if (total !== v.byte_count) invalid();
  if (v.descriptor_ref !== null && v.descriptor_ref !== undefined && (typeof v.descriptor_ref !== 'object' || Array.isArray(v.descriptor_ref))) invalid();
  return { upload_id: v.upload_id.toLowerCase(), state: v.state, revision: v.revision as number, generation: v.generation as number,
    byte_count: v.byte_count as number, chunk_bytes: v.chunk_bytes as number, part_count: v.part_count as number, parts,
    descriptor_required: v.descriptor_required as boolean, descriptor_ref: v.descriptor_ref ?? null };
}

/** File checks shared by the Add sheet and tests. MIME is deliberately not trusted. */
export async function readPDF(file: Blob & { name?: string }, signal?: AbortSignal): Promise<Uint8Array<ArrayBuffer>> {
  if (!Number.isSafeInteger(file.size) || file.size < 5 || file.size > MAX_PDF_BYTES) throw new BackendError(file.size > MAX_PDF_BYTES ? 'upload_too_large' : 'invalid_upload');
  signal?.throwIfAborted();
  let data: Uint8Array<ArrayBuffer>;
  try { data = new Uint8Array(await file.arrayBuffer()) as Uint8Array<ArrayBuffer>; }
  catch { throw new BackendError('connection'); }
  signal?.throwIfAborted();
  if (data.length !== file.size || new TextDecoder('ascii').decode(data.subarray(0, 5)) !== '%PDF-') throw new BackendError('invalid_upload');
  return data;
}

export function titleForPDF(file: { name?: string }): { display_name: string; filename?: string } {
  const raw = typeof file.name === 'string' ? file.name.replace(/\.pdf$/i, '') : '';
  const displayName = raw.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 500) || 'Uploaded paper';
  const filename = typeof file.name === 'string' && file.name.length > 0
    ? file.name.replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, 255) : undefined;
  return { display_name: displayName, ...(filename ? { filename } : {}) };
}

function descriptorResponse(value: unknown, account: string): void {
  const v = object(value), result = object(v.result);
  if (v.format !== 1 || typeof v.account_id !== 'string' || v.account_id.toLowerCase() !== account.toLowerCase()
    || (result.status !== 'applied' && result.status !== 'revision_conflict')) invalid();
}

async function writeDescriptor(account: string, uploadID: string, file: { name?: string }, keys: BrowserPDFKeys, signal?: AbortSignal): Promise<void> {
  const sourceID = `upload:${uploadID}`;
  const binding = { accountID: account, sourceID, descriptorID: crypto.randomUUID(), revision: 1, mutationID: crypto.randomUUID(), deviceID: keys.deviceID };
  let envelope: LibraryDescriptorEnvelope;
  try { envelope = await sealLibraryDescriptor(titleForPDF(file), binding, keys.ring); }
  catch (error) { if (error instanceof BackendError) throw error; throw new BackendError('key_authority_required'); }
  const response = await rpc<unknown>('v1_put_library_descriptor', {
    p_source_id: sourceID, p_expected_revision: 0, p_caller_device_id: keys.deviceID,
    p_management_token: toBytea(keys.ring.managementToken), p_envelope: envelope,
  }, { account, signal, maximum: 65_536 });
  descriptorResponse(response, account);
}

async function status(account: string, uploadID: string, signal?: AbortSignal): Promise<UploadTicket> {
  const value = await functionPost('upload-pdf', { action: 'status', upload_id: uploadID }, { account, signal, maximum: 65_536, timeout: 40_000 });
  return decodePDFUploadTicket(value);
}

/** Upload one PDF. The server's idempotent session is exposed to the caller so
 * a network failure can resume without starting another admission. */
export async function uploadPDF(file: Blob & { name?: string }, options: PDFUploadOptions): Promise<PDFUploadResult> {
  if (!isUUID(options.account) || !integer(options.cursor) || !isUUID(options.keys.deviceID) || options.keys.ring.accountID.toLowerCase() !== options.account.toLowerCase()) invalid();
  const report = (phase: PDFUploadProgress['phase'], fraction: number) => options.onProgress?.({ phase, fraction: Math.max(0, Math.min(1, fraction)) });
  report('checking', 0);
  const data = await readPDF(file, options.signal);
  const partSHA256: string[] = [];
  for (let offset = 0; offset < data.length; offset += PDF_CHUNK_BYTES) {
    options.signal?.throwIfAborted();
    partSHA256.push(await sha256Hex(data.subarray(offset, Math.min(offset + PDF_CHUNK_BYTES, data.length))));
  }
  if (partSHA256.length < 1 || partSHA256.length > MAX_PDF_PARTS) throw new BackendError('invalid_upload');
  const uploadID = (options.uploadID ?? crypto.randomUUID()).toLowerCase();
  if (!isUUID(uploadID)) invalid();
  const digest = await sha256Hex(data);
  report('starting', 0);
  const body: Record<string, unknown> = { action: 'begin', upload_id: uploadID, sha256: digest, byte_count: data.length, part_sha256: partSHA256, target: 'paper' };
  const initial = decodePDFUploadTicket(await functionPost('upload-pdf', body, { account: options.account, signal: options.signal, maximum: 65_536, timeout: 40_000 }));
  if (initial.upload_id !== uploadID || initial.byte_count !== data.length || initial.part_count !== partSHA256.length) invalid();
  options.onSession?.(uploadID);
  let ticket = initial;
  if (ticket.descriptor_required && ticket.descriptor_ref === null) {
    await writeDescriptor(options.account, uploadID, file, options.keys, options.signal);
    ticket = await status(options.account, uploadID, options.signal);
  }
  if (ticket.state === 'receiving') {
    for (const part of ticket.parts) {
      options.signal?.throwIfAborted();
      const start = part.index * PDF_CHUNK_BYTES, bytes = data.subarray(start, start + part.bytes);
      if (part.verified) { report('uploading', (start + bytes.length) / data.length); continue; }
      const attemptID = crypto.randomUUID();
      const path = `upload-pdf?upload_id=${uploadID}&generation=${ticket.generation}&part=${part.index}&attempt_id=${attemptID}`;
      const receipt = object(await functionPutBytes<unknown>(path, bytes, { account: options.account, signal: options.signal, maximum: 65_536, timeout: 120_000 })) as Receipt;
      if (receipt.verified !== true || receipt.uncertain === true) throw new BackendError('upload_uncertain');
      report('uploading', (start + bytes.length) / data.length);
    }
    // Every positive part receipt advances revision. Never freeze with the begin revision.
    ticket = await status(options.account, uploadID, options.signal);
  }
  if (ticket.state !== 'finalized' && ticket.state !== 'consumed') {
    report('finishing', 0);
    await functionPost('upload-pdf', { action: 'finalize', upload_id: uploadID, generation: ticket.generation,
      revision: ticket.revision, observed_cursor: options.cursor }, { account: options.account, signal: options.signal, maximum: 262_144, timeout: 40_000 });
    report('finishing', 1);
  }
  return { uploadID, sourceID: `upload:${uploadID}`, state: 'finalized' };
}
