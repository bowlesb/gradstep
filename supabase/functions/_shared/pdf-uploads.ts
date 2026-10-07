// PDF uploads (migration 031; docs/architecture/PDF_UPLOADS.md). functions/v1/upload-pdf begins a
// session (the database checks size, quota, limits and credits) and hands the reader a signed URL to
// upload the bytes straight to the private `paper-uploads` bucket; it finalizes only when the object
// is in Storage with the declared size, which creates or retries the import. The pipeline worker
// verifies the bytes. The worker's sweep deletes spent, abandoned and expired uploads.
// Dependencies are injected so Node tests drive the handler with fakes. Deno and Node compatible.
import { PublicError } from './http.ts';

export const MAX_TITLE_CHARS = 500;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface UploadDeps {
  /** Service-role RPC; throws the database's exception text (e.g. `upload_quota`). */
  rpc<T>(name: string, params: Record<string, unknown>): Promise<T>;
  /** A signed upload token for `path` in the uploads bucket (overwrites: a retried upload replaces a partial one). */
  signUpload(path: string): Promise<string>;
  /** The size of the object at `path` in the uploads bucket, or null when it isn't there. */
  objectSize(path: string): Promise<number | null>;
}

interface Session { id: string; bucket: string; path: string; state: string; byte_count: number; expires_at: string; result: unknown }

/** Database exceptions a reader can act on, as HTTP statuses. Anything else is a 503. */
const EXPOSED: Record<string, number> = {
  invalid_upload: 400, invalid_web_source_id: 400, upload_too_large: 413, upload_quota: 409, upload_limit: 429, upload_storage_full: 503,
  insufficient_credits: 402, upload_expired: 410, upload_id_conflict: 409, upload_target_unavailable: 409, upload_incomplete: 409,
  upload_unavailable: 404, request_rate_limit: 429, library_active_import_limit: 429, library_account_import_limit: 409,
  invalid_library_cursor: 400, import_not_retryable: 409, account_unavailable: 403,
};
export function uploadError(error: unknown): PublicError {
  if (error instanceof PublicError) return error;
  const code = error instanceof Error ? error.message : '';
  return EXPOSED[code] ? new PublicError(EXPOSED[code], code === 'request_rate_limit' ? 'rate_limited' : code) : new PublicError(503, 'service_unavailable');
}

/** One upload request from an authenticated reader: `begin` (returns a signed upload token while the
 * session is pending) or `finalize` (once the bytes are in Storage). */
export async function handleUpload(deps: UploadDeps, accountID: string, body: Record<string, unknown>): Promise<Record<string, unknown>> {
  const id = typeof body.upload_id === 'string' && UUID.test(body.upload_id) ? body.upload_id.toLowerCase() : null;
  if (!id) throw new PublicError(400, 'invalid_request');
  if (body.action === 'begin') {
    const sha = typeof body.sha256 === 'string' && /^[0-9a-f]{64}$/i.test(body.sha256) ? body.sha256.toLowerCase() : null;
    const bytes = Number.isSafeInteger(body.byte_count) ? body.byte_count as number : null;
    const target = typeof body.target === 'string' && ['paper', 'import', 'source'].includes(body.target) ? body.target : null;
    if (!sha || !bytes || bytes < 1 || !target) throw new PublicError(400, 'invalid_request');
    const title = typeof body.title === 'string' ? [...body.title].slice(0, MAX_TITLE_CHARS).join('') : null;
    const importID = typeof body.import_id === 'string' && UUID.test(body.import_id) ? body.import_id : null;
    const revision = Number.isSafeInteger(body.expected_revision) ? body.expected_revision as number : null;
    const sourceID = typeof body.source_id === 'string' && body.source_id.length <= 128 ? body.source_id : null;
    const session = await deps.rpc<Session>('worker_begin_pdf_upload', { p_account_id: accountID, p_upload_id: id, p_sha256: `\\x${sha}`,
      p_byte_count: bytes, p_target: target, p_import_id: target === 'import' ? importID : null, p_expected_revision: target === 'import' ? revision : null,
      p_source_id: target === 'source' ? sourceID : null, p_title: target === 'paper' ? title : null }).catch(error => { throw uploadError(error); });
    // A finalized (or spent) session needs no upload: the client goes straight to finalize, which replays.
    const token = session.state === 'pending' ? await deps.signUpload(session.path) : null;
    return { upload_id: session.id, state: session.state, bucket: session.bucket, path: session.path, token, expires_at: session.expires_at };
  }
  if (body.action === 'finalize') {
    const cursor = Number.isSafeInteger(body.observed_cursor) && (body.observed_cursor as number) >= 0 ? body.observed_cursor as number : null;
    if (cursor === null) throw new PublicError(400, 'invalid_request');
    // The object's path is fixed by the session; its size in Storage must be the declared size.
    const stored = await deps.objectSize(`${accountID}/${id}.pdf`);
    const receipt = await deps.rpc<Record<string, unknown>>('worker_finalize_pdf_upload', { p_account_id: accountID, p_upload_id: id,
      p_observed_cursor: cursor, p_stored_bytes: stored }).catch(error => { throw uploadError(error); });
    return receipt;
  }
  throw new PublicError(400, 'invalid_request');
}

/** Deletes spent, abandoned and expired upload objects, then records their deletion. Never throws. */
export async function sweepPdfUploads(rpc: UploadDeps['rpc'], remove: (paths: string[]) => Promise<void>,
  log: (fields: Record<string, unknown>) => void): Promise<number> {
  try {
    const stale = await rpc<{ id: string; bucket: string; path: string }[]>('worker_claim_stale_pdf_uploads', { p_limit: 100 });
    const objects = (Array.isArray(stale) ? stale : []).filter(o => o.bucket === 'paper-uploads' && /^[0-9a-f-]{36}\/[0-9a-f-]{36}\.pdf$/.test(o.path));
    if (!objects.length) return 0;
    await remove(objects.map(o => o.path));
    const deleted = await rpc<number>('worker_confirm_pdf_uploads_deleted', { p_object_ids: objects.map(o => o.id) });
    log({ event: 'pdf_uploads_swept', deleted });
    return deleted;
  } catch {
    log({ event: 'pdf_upload_sweep_failed' });
    return 0;
  }
}
