// Encrypted note images (docs/architecture/NOTES_AND_SNIPPETS.md "Implementation contract", migration 095).
//
//   PUT /note-assets/{blobID}   body = the stored blob (nonce ‖ AES-256-GCM ciphertext ‖ tag), header x-content-sha256
//   GET /note-assets/{blobID}   the stored blob, application/octet-stream
//
// Clients never touch Storage: this function is the only writer and reader of `note-assets/{account}/{blob}`. The
// server cannot read a blob; it checks only length and SHA-256. Quotas and monthly transfer live in the database
// (app_private.note_asset_policy), checked in one SQL call before any write or read. Logs carry counts only: no
// account, blob, digest or byte content.
import { PublicError, readBounded, sha256, uuid } from './http.ts';

export const NOTE_ASSET_BUCKET = 'note-assets';
/** AES-256-GCM output around a 2 MiB image: 12-byte nonce + ciphertext + 16-byte tag. The transport bound; the
 * database policy's max_blob_bytes holds the same value and is authoritative. */
export const NOTE_BLOB_MAX_BYTES = 2 * 1024 * 1024 + 28;
/** Nonce and tag around an empty plaintext. */
export const NOTE_BLOB_MIN_BYTES = 28;
const DIGEST = /^[0-9a-f]{64}$/;
const PATH = /^\/(?:functions\/v1\/)?note-assets\/([^/]+)$/;

export interface NoteAssetDeps {
  /** The caller's open account, from their access token (the same check as every user function). */
  account(request: Request): Promise<string>;
  /** A service-role RPC. A database refusal rejects with an Error whose message is the SQL exception. */
  rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T>;
  /** Writes with the service key. Its outcome is not trusted: the stored object is always read back. */
  upload(path: string, bytes: Uint8Array, upsert: boolean): Promise<void>;
  /** Reads with the service key, refusing more than `maximum` bytes while receiving. */
  download(path: string, maximum: number): Promise<Uint8Array>;
  log?(entry: Record<string, unknown>): void;
}

interface Reservation { state: 'pending' | 'ready'; bytes: number; path: string; retry: boolean }
interface Admission { path: string; bytes: number; sha256: string }

const SQL_ERRORS: Record<string, [number, string]> = {
  note_asset_conflict: [409, 'conflict'],
  note_asset_quota: [429, 'quota'],
  note_asset_unavailable: [404, 'not_found'],
  invalid_note_asset: [400, 'invalid_blob'],
  request_rate_limit: [429, 'rate_limited'],
  authentication_required: [401, 'authentication_required'],
  account_unavailable: [403, 'account_unavailable'],
};

/** CORS for the reader origins (the shared allow-list), with the two methods and the digest header this API uses. */
export function noteAssetHeaders(base: Record<string, string>): Record<string, string> {
  return { ...base, 'Access-Control-Allow-Methods': 'GET, PUT, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, x-content-sha256',
    'Access-Control-Expose-Headers': 'Retry-After, X-Content-SHA256',
    'Cache-Control': 'private, no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' };
}

/** Seconds until the next UTC month, when a monthly download allowance renews. */
export function secondsUntilNextMonth(now = new Date()): number {
  const next = Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1);
  return Math.max(1, Math.ceil((next - now.getTime()) / 1000));
}

/** A monthly transfer allowance is used up (it renews with the UTC month, unlike stored capacity). */
class MonthlyLimit extends PublicError { constructor() { super(429, 'quota'); } }

function sqlFailure(error: unknown): PublicError {
  if (error instanceof PublicError) return error;
  const message = error instanceof Error ? error.message : '';
  if (message === 'note_transfer_limit') return new MonthlyLimit();
  const known = SQL_ERRORS[message];
  return known ? new PublicError(...known) : new PublicError(503, 'service_unavailable');
}

function reply(failure: PublicError, headers: Record<string, string>): Response {
  // A full store does not empty by waiting (objects stay until account deletion); a monthly allowance renews.
  const wait = failure.code === 'rate_limited' ? 60 : failure instanceof MonthlyLimit ? secondsUntilNextMonth()
    : failure.status === 503 ? 10 : undefined;
  return Response.json(wait === undefined ? { code: failure.code } : { code: failure.code, retry_after: wait },
    { status: failure.status, headers: wait === undefined ? headers : { ...headers, 'Retry-After': String(wait) } });
}

/** Ends an upload body the handler will not read (an early refusal). Supabase's gateway holds a response to an
 * unread body of more than a few hundred KiB until it times out (504 after 160 s, measured on staging 2026-10-21);
 * cancelling the stream lets the refusal through. */
export async function releaseBody(request: Request, limit = 2 * NOTE_BLOB_MAX_BYTES): Promise<void> {
  if (!request.body || request.bodyUsed || request.body.locked) return;
  const reader = request.body.getReader();
  const deadline = Date.now() + 15_000;
  try {
    // Read and discard (never buffered) up to a bound, then cancel whatever remains.
    for (let read = 0; read <= limit && Date.now() < deadline;) {
      const next = await Promise.race([reader.read(), new Promise<null>(resolve => setTimeout(() => resolve(null), Math.max(1, deadline - Date.now())))]);
      if (!next || next.done) break;
      read += next.value.byteLength;
    }
    await reader.cancel();
  } catch { /* already closed */ } finally { try { reader.releaseLock(); } catch { /* released */ } }
}

export async function handleNoteAsset(request: Request, deps: NoteAssetDeps, headers: Record<string, string>): Promise<Response> {
  const started = Date.now();
  let bytes = 0;
  const finish = (response: Response, code?: string) => {
    try { deps.log?.({ function: 'note-assets', method: request.method, status: response.status, ...(code ? { code } : {}), bytes, ms: Date.now() - started }); }
    catch { /* diagnostics never change the response */ }
    return response;
  };
  try {
    if (request.method !== 'GET' && request.method !== 'PUT') throw new PublicError(405, 'method_unavailable');
    const match = PATH.exec(new URL(request.url).pathname);
    if (!match) throw new PublicError(404, 'not_found');
    const blobID = uuid(match[1]);
    if (request.method === 'GET') {
      if (request.headers.has('range')) throw new PublicError(416, 'range_unavailable');
      const accountID = await deps.account(request);
      await deps.rpc('worker_consume_request', { p_account_id: accountID, p_route: 'note-download' }).catch(error => { throw sqlFailure(error); });
      // Charged in full before Storage is read; a failed read keeps its charge.
      const admitted = await deps.rpc<Admission>('worker_note_asset_download', { p_account_id: accountID, p_blob_id: blobID })
        .catch(error => { throw sqlFailure(error); });
      if (!admitted || admitted.path !== `${accountID}/${blobID}` || !Number.isSafeInteger(admitted.bytes)
        || admitted.bytes < NOTE_BLOB_MIN_BYTES || admitted.bytes > NOTE_BLOB_MAX_BYTES || !DIGEST.test(admitted.sha256)) {
        throw new PublicError(503, 'service_unavailable');
      }
      let stored: Uint8Array;
      try { stored = await deps.download(admitted.path, admitted.bytes); } catch { throw new PublicError(503, 'asset_unavailable'); }
      if (stored.length !== admitted.bytes || await sha256(stored) !== admitted.sha256) throw new PublicError(503, 'integrity_failed');
      bytes = stored.length;
      return finish(new Response(new Uint8Array(stored), { headers: { ...headers, 'Content-Type': 'application/octet-stream',
        'Content-Length': String(stored.length), 'X-Content-SHA256': admitted.sha256 } }));
    }

    const declared = (request.headers.get('x-content-sha256') ?? '').toLowerCase();
    if (!DIGEST.test(declared)) throw new PublicError(400, 'digest_required');
    const accountID = await deps.account(request);
    await deps.rpc('worker_consume_request', { p_account_id: accountID, p_route: 'note-upload' }).catch(error => { throw sqlFailure(error); });
    let body: Uint8Array;
    try { body = await readBounded(request, NOTE_BLOB_MAX_BYTES); } catch (error) {
      if (error instanceof PublicError && error.status === 413) throw new PublicError(413, 'too_large');
      throw error;
    }
    bytes = body.length;
    if (body.length < NOTE_BLOB_MIN_BYTES) throw new PublicError(400, 'invalid_blob');
    if (await sha256(body) !== declared) throw new PublicError(400, 'digest_mismatch');
    // One SQL call: idempotency, conflict and every quota (pending objects included) before any write.
    const reservation = await deps.rpc<Reservation>('worker_note_asset_reserve', { p_account_id: accountID, p_blob_id: blobID,
      p_sha256: '\\x' + declared, p_bytes: body.length }).catch(error => { throw sqlFailure(error); });
    if (!reservation || reservation.path !== `${accountID}/${blobID}` || reservation.bytes !== body.length) throw new PublicError(503, 'service_unavailable');
    if (reservation.state === 'ready') return finish(Response.json({ state: 'ready', bytes: body.length }, { headers }));
    if (reservation.state !== 'pending') throw new PublicError(503, 'service_unavailable');
    // Overwrite only the same pending object again (an earlier attempt may have stored some or all of these bytes).
    try { await deps.upload(reservation.path, body, reservation.retry === true); } catch { /* the read-back decides */ }
    let stored: Uint8Array;
    try { stored = await deps.download(reservation.path, body.length); } catch { throw new PublicError(503, 'not_ready'); }
    if (stored.length !== body.length || await sha256(stored) !== declared) throw new PublicError(503, 'not_ready');
    await deps.rpc('worker_note_asset_confirm', { p_account_id: accountID, p_blob_id: blobID, p_sha256: '\\x' + declared, p_bytes: body.length })
      .catch(error => { throw sqlFailure(error); });
    return finish(Response.json({ state: 'ready', bytes: body.length }, { headers }));
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    const allow = failure.status === 405 ? { ...headers, Allow: 'GET, PUT, OPTIONS' } : headers;
    await releaseBody(request);
    return finish(reply(failure, allow), failure.code);
  }
}
