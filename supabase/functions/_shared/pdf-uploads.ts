// Bounded authenticated PDF chunks (039). No reader receives Storage credentials.
import { PublicError, readBounded, sha256 } from './http.ts';

export const PDF_CHUNK_BYTES = 4_194_304;
export const MAX_PDF_BYTES = 67_108_864;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HASH = /^[0-9a-f]{64}$/i;
const CHUNK_PATH = /^[0-9a-f-]{36}\/[0-9a-f-]{36}\/(?:[0-9]|1[0-5])\/[0-9a-f-]{36}\.chunk$/;
export interface UploadDeps {
  rpc<T>(name: string, params: Record<string, unknown>): Promise<T>;
  /** Exactly one immutable PUT; no HTTP/SDK automatic retry and no upsert. */
  writeOnce(path: string, bytes: Uint8Array): Promise<void>;
}
const EXPOSED: Record<string, number> = {
  invalid_upload: 400, invalid_web_source_id: 400, invalid_upload_part: 400,
  upload_too_large: 413, paper_owner_storage_capacity: 409, paper_storage_capacity: 503,
  insufficient_credits: 402, upload_expired: 410, upload_id_conflict: 409, upload_revision_conflict: 409,
  upload_target_unavailable: 409, upload_target_busy: 409, upload_incomplete: 409, upload_mismatch: 409, upload_limit: 429,
  upload_attempt_limit: 429, upload_receipt_capacity: 429, library_descriptor_required: 409, upload_not_receiving: 409, upload_not_frozen: 409, upload_already_attached: 409,
  upload_unavailable: 404, upload_disabled: 503, asset_inventory_reconciling: 503,
  request_rate_limit: 429, library_active_import_limit: 429, library_account_import_limit: 409,
  invalid_library_cursor: 400, import_not_retryable: 409, account_unavailable: 403,
};
export function uploadError(error: unknown): PublicError {
  if (error instanceof PublicError) return error;
  const code = error instanceof Error ? error.message : '';
  return EXPOSED[code] ? new PublicError(EXPOSED[code], code === 'request_rate_limit' ? 'rate_limited' : code) : new PublicError(503, 'service_unavailable');
}
function invalid(): never { throw new PublicError(400, 'invalid_request'); }
function id(value: unknown): string { return typeof value === 'string' && UUID.test(value) ? value.toLowerCase() : invalid(); }
function integer(value: unknown, minimum = 1): number { return Number.isSafeInteger(value) && (value as number) >= minimum ? value as number : invalid(); }
function hash(value: unknown): string { return typeof value === 'string' && HASH.test(value) ? value.toLowerCase() : invalid(); }
function fields(body: Record<string, unknown>, allowed: string[]) { if (Object.keys(body).some(k => !allowed.includes(k))) invalid(); }

/** Durable control operations. Freeze and attach commit independently; a retry
 * of finalize safely repeats the same frozen selection and command identity. */
export async function handleUpload(deps: UploadDeps, accountID: string, body: Record<string, unknown>): Promise<Record<string, unknown>> {
  const uploadID = id(body.upload_id);
  const rpc = async (name: string, params: Record<string, unknown>) => deps.rpc<Record<string, unknown>>(name, {
    p_account_id: accountID, p_upload_id: uploadID, ...params,
  }).catch(error => { throw uploadError(error); });
  if (body.action === 'begin') {
    fields(body, ['action', 'upload_id', 'sha256', 'byte_count', 'part_sha256', 'target', 'import_id', 'expected_revision', 'source_id']);
    const bytes = integer(body.byte_count), digest = hash(body.sha256);
    if (bytes > MAX_PDF_BYTES) throw new PublicError(413, 'upload_too_large');
    if (!Array.isArray(body.part_sha256) || body.part_sha256.length !== Math.ceil(bytes / PDF_CHUNK_BYTES)) invalid();
    const parts = body.part_sha256.map(v => '\\x' + hash(v));
    const target = body.target;
    if (!['paper', 'import', 'source'].includes(String(target))) invalid();
    if ((target !== 'import' && (body.import_id !== undefined || body.expected_revision !== undefined)) ||
        (target !== 'source' && body.source_id !== undefined)) invalid();
    const importID = target === 'import' ? id(body.import_id) : null;
    const revision = target === 'import' ? integer(body.expected_revision) : null;
    const source = target === 'source' && typeof body.source_id === 'string' && /^openalex:W[1-9][0-9]{0,19}$/.test(body.source_id) ? body.source_id : null;
    if (target === 'source' && !source) invalid();
    return rpc('worker_begin_pdf_upload', { p_sha256: '\\x' + digest, p_byte_count: bytes, p_part_sha256: parts,
      p_target: target, p_import_id: importID, p_expected_revision: revision, p_source_id: source });
  }
  if (body.action === 'status') {
    fields(body, ['action', 'upload_id']);
    return rpc('worker_pdf_upload_status', {});
  }
  if (body.action === 'cancel') {
    fields(body, ['action', 'upload_id', 'generation']);
    return rpc('worker_cancel_pdf_upload', { p_generation: integer(body.generation) });
  }
  if (body.action === 'finalize') {
    fields(body, ['action', 'upload_id', 'generation', 'revision', 'observed_cursor']);
    const generation = integer(body.generation), revision = integer(body.revision), cursor = integer(body.observed_cursor, 0);
    await rpc('worker_freeze_pdf_upload', { p_generation: generation, p_revision: revision, p_observed_cursor: cursor });
    return rpc('worker_finalize_pdf_upload', { p_generation: generation });
  }
  return invalid();
}

/** A fixed 4MiB (or exact final) chunk. Admission occurs before reading the
 * body. Exact length/hash precede the durable one-shot Storage grant. */
export async function handleUploadPart(deps: UploadDeps, accountID: string, request: Request): Promise<Record<string, unknown>> {
  if (request.method !== 'PUT') throw new PublicError(405, 'method_unavailable');
  if (request.headers.has('content-encoding') || request.headers.has('content-range') ||
      request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/octet-stream') invalid();
  const q = new URL(request.url).searchParams;
  if (q.size !== 4 || [...q.keys()].some(k => !['upload_id', 'generation', 'part', 'attempt_id'].includes(k))) invalid();
  const decimal = (key: string, minimum: number) => {
    const value = q.get(key); if (value === null || !/^(0|[1-9][0-9]*)$/.test(value)) invalid();
    return integer(Number(value), minimum);
  };
  const uploadID = id(q.get('upload_id')), attemptID = id(q.get('attempt_id'));
  const generation = decimal('generation', 1), part = decimal('part', 0);
  if (part > 15) invalid();
  const params = { p_account_id: accountID, p_upload_id: uploadID, p_generation: generation, p_part_index: part, p_attempt_id: attemptID };
  const rpc = <T>(name: string, values: Record<string, unknown>) => deps.rpc<T>(name, values).catch(error => { throw uploadError(error); });
  const admission = await rpc<{ receive: boolean; verified?: boolean; uncertain?: boolean; bytes?: number; sha256?: string }>('worker_pdf_upload_part', params);
  if (!admission.receive) { await request.body?.cancel(); return { verified: admission.verified === true, uncertain: admission.uncertain === true }; }
  if (!Number.isSafeInteger(admission.bytes) || admission.bytes! < 1 || admission.bytes! > PDF_CHUNK_BYTES || !HASH.test(admission.sha256 ?? '')) throw new PublicError(503, 'service_unavailable');
  let bytes: Uint8Array;
  try { bytes = await readBounded(request, admission.bytes!); }
  catch (error) {
    if (error instanceof PublicError && error.code === 'attachment_too_large') throw new PublicError(413, 'upload_too_large');
    throw error;
  }
  if (bytes.length !== admission.bytes || await sha256(bytes) !== admission.sha256) throw new PublicError(409, 'upload_mismatch');
  const grant = await rpc<{ write: boolean; verified?: boolean; uncertain?: boolean; bucket?: string; path?: string }>('worker_pdf_upload_write', {
    ...params, p_sha256: '\\x' + admission.sha256, p_byte_count: bytes.length,
  });
  if (!grant.write) return { verified: grant.verified === true, uncertain: grant.uncertain === true };
  const exactPath = `${accountID}/${uploadID}/${part}/${attemptID}.chunk`;
  if (grant.bucket !== 'paper-uploads' || grant.path !== exactPath) throw new PublicError(503, 'service_unavailable');
  // A timeout, conflict, or lost RPC reply retains liability. Never issue a
  // second PUT here, never mark absent/not-written, never return Storage paths.
  try {
    await deps.writeOnce(exactPath, bytes);
    await rpc('worker_pdf_upload_written', { p_attempt_id: attemptID, p_sha256: '\\x' + admission.sha256, p_byte_count: bytes.length });
  } catch { return { verified: false, uncertain: true }; }
  return { verified: true, uncertain: false };
}

/** Exact server-generated batches only. Malformed/partial batch validation
 * fails closed; no subset may be confirmed as if the whole batch was erased. */
export async function sweepPdfUploads(rpc: UploadDeps['rpc'], remove: (paths: string[]) => Promise<void>, log: (fields: Record<string, unknown>) => void): Promise<number> {
  try {
    const batches = await rpc<{ batch_id: string; objects: { id: string; bucket: string; path: string }[] }[]>('worker_claim_stale_pdf_uploads', { p_limit: 50 });
    if (!Array.isArray(batches) || batches.length > 50) throw new Error('invalid_upload_deletion');
    let deleted = 0;
    for (const batch of batches) {
      try {
        if (!UUID.test(batch.batch_id) || !Array.isArray(batch.objects) || batch.objects.length < 1 || batch.objects.length > 128 ||
          batch.objects.some(o => !UUID.test(o.id) || o.bucket !== 'paper-uploads' || !CHUNK_PATH.test(o.path)) ||
          new Set(batch.objects.map(o => o.id)).size !== batch.objects.length || new Set(batch.objects.map(o => o.path)).size !== batch.objects.length)
          throw new Error('invalid_upload_deletion');
        await remove(batch.objects.map(o => o.path));
        deleted += await rpc<number>('worker_confirm_pdf_uploads_deleted', { p_batch_id: batch.batch_id });
      } catch { log({ event: 'pdf_upload_batch_sweep_failed' }); }
    }
    if (deleted) log({ event: 'pdf_uploads_swept', deleted });
    return deleted;
  } catch { log({ event: 'pdf_upload_sweep_failed' }); return 0; }
}

/** Explicit raw fetch keeps the send grant one-shot: redirects and automatic
 * retry/upsert are prohibited. Never include credential-bearing errors in logs. */
export async function writePdfChunkOnce(url: string, key: string, path: string, bytes: Uint8Array, fetcher: typeof fetch = fetch): Promise<void> {
  if (!CHUNK_PATH.test(path) || bytes.length < 1 || bytes.length > PDF_CHUNK_BYTES) throw new Error('invalid_upload_write');
  const response = await fetcher(`${url.replace(/\/$/, '')}/storage/v1/object/paper-uploads/${path}`, {
    method: 'POST', headers: { Authorization: `Bearer ${key}`, apikey: key, 'Content-Type': 'application/octet-stream', 'x-upsert': 'false' },
    body: new Uint8Array(bytes), redirect: 'error', signal: AbortSignal.timeout(60_000),
  });
  await response.body?.cancel();
  if (!response.ok) throw new Error('storage_upload_failed');
}

/** Positive-only recovery of a one-shot PUT with a lost acknowledgement.
 * An absent/mismatched object remains uncertain and fully charged. */
export async function reconcilePdfUploads(rpc: UploadDeps['rpc'],
  download: (path: string, maximum: number, observed?: (bytes: number) => void) => Promise<Uint8Array>,
  log: (fields: Record<string, unknown>) => void): Promise<number> {
  let recovered = 0;
  try {
    const candidates = await rpc<{ attempt_id: string; upload_id: string; generation: number }[]>('worker_pdf_upload_reconciliation', { p_limit: 3 });
    if (!Array.isArray(candidates) || candidates.length > 3) throw new Error('invalid_upload_reconciliation');
    for (const candidate of candidates) {
      try {
        if (!UUID.test(candidate.attempt_id) || !UUID.test(candidate.upload_id) || !Number.isSafeInteger(candidate.generation) || candidate.generation < 1)
          throw new Error('invalid_upload_reconciliation');
        const readID = crypto.randomUUID();
        const grant = await rpc<{ read: boolean; objects?: { bucket: string; path: string; bytes: number; sha256: string }[] }>('worker_pdf_upload_read', {
          p_read_id: readID, p_upload_id: candidate.upload_id, p_upload_generation: candidate.generation, p_attempt_id: candidate.attempt_id,
        });
        if (!grant.read) continue;
        if (!Array.isArray(grant.objects) || grant.objects.length !== 1) throw new Error('invalid_upload_reconciliation');
        const object = grant.objects[0];
        if (object.bucket !== 'paper-uploads' || !CHUNK_PATH.test(object.path) || !object.path.includes(`/${candidate.upload_id}/`) ||
          !object.path.endsWith(`/${candidate.attempt_id}.chunk`) || !Number.isSafeInteger(object.bytes) || object.bytes < 1 || object.bytes > PDF_CHUNK_BYTES || !HASH.test(object.sha256))
          throw new Error('invalid_upload_reconciliation');
        let observed = 0, matching = false;
        try {
          const bytes = await download(object.path, object.bytes, count => { observed = Math.min(count, object.bytes); });
          observed = Math.min(bytes.length, object.bytes);
          matching = bytes.length === object.bytes && await sha256(bytes) === object.sha256;
        } catch { /* Absence or failure is not terminal proof of a PUT. */ }
        await rpc('worker_pdf_upload_read_observed', { p_read_id: readID, p_bytes: observed });
        if (matching) {
          await rpc('worker_pdf_upload_written', { p_attempt_id: candidate.attempt_id, p_sha256: '\\x' + object.sha256,
            p_byte_count: object.bytes, p_evidence: 'matching_object', p_read_id: readID });
          recovered++;
        }
      } catch { log({ event: 'pdf_upload_reconciliation_candidate_failed' }); }
    }
    if (recovered) log({ event: 'pdf_uploads_reconciled', recovered });
  } catch { log({ event: 'pdf_upload_reconciliation_deferred' }); }
  return recovered;
}
