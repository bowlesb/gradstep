// Interest index delivery (docs/architecture/INTEREST_INDEX.md §4):
//   GET /interest-index                 the manifest: model, map, term statistics and pool shards (identical for every reader)
//   GET /interest-index?artifact=<id>   one immutable artifact's bytes (gzip container; ETag = its SHA-256)
// Readers must be signed in and served (interest_policy.serving); requests count against `interest-index`. The
// database decides everything; this handler only shapes HTTP. Nothing about the reader is logged.
import { PublicError, uuid } from './http.ts';

export interface InterestIndexDeps {
  account(request: Request): Promise<string>;
  /** A service-role RPC; a database refusal rejects with an Error whose message is the SQL exception. */
  rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T>;
}

const SQL_ERRORS: Record<string, [number, string]> = {
  interest_unavailable: [404, 'interest_unavailable'],
  interest_artifact_unavailable: [404, 'not_found'],
  request_rate_limit: [429, 'rate_limited'],
  account_unavailable: [403, 'account_unavailable'],
  authentication_required: [401, 'authentication_required'],
};

function refusal(error: unknown): PublicError {
  if (error instanceof PublicError) return error;
  const message = error instanceof Error ? error.message : '';
  const known = SQL_ERRORS[message];
  return known ? new PublicError(known[0], known[1]) : new PublicError(503, 'service_unavailable');
}

function bytesOf(text: string): Uint8Array {
  const s = atob(text);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as BufferSource));
  return Array.from(digest, b => b.toString(16).padStart(2, '0')).join('');
}

export async function handleInterestIndex(request: Request, deps: InterestIndexDeps, headers: Record<string, string>): Promise<Response> {
  if (request.method !== 'GET') throw new PublicError(405, 'method_unavailable');
  const query = new URL(request.url).searchParams;
  const accountID = await deps.account(request);
  const id = query.get('artifact');
  try {
    if (id === null) {
      const manifest = await deps.rpc<Record<string, unknown>>('worker_interest_manifest', { p_account_id: accountID });
      return Response.json(manifest, { headers: { ...headers, 'Cache-Control': 'private, max-age=600' } });
    }
    const artifactID = uuid(id);
    const artifact = await deps.rpc<{ sha256: string; bytes: number; content: string }>('worker_interest_artifact',
      { p_account_id: accountID, p_id: artifactID });
    const etag = `"${artifact.sha256}"`;
    const cache = { ...headers, ETag: etag, 'Cache-Control': 'private, max-age=31536000, immutable' };
    if (request.headers.get('if-none-match') === etag) return new Response(null, { status: 304, headers: cache });
    const body = bytesOf(artifact.content);
    // The database checked the digest when it stored the artifact; check the bytes we send match it.
    if (body.length !== artifact.bytes || await sha256Hex(body) !== artifact.sha256) throw new PublicError(503, 'interest_integrity_failed');
    return new Response(body as BodyInit, { headers: { ...cache, 'Content-Type': 'application/octet-stream', 'Content-Length': String(body.length) } });
  } catch (error) {
    throw refusal(error);
  }
}
