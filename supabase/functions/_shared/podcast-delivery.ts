// Single-use bounded audio delivery (docs/architecture/PAPER_PODCASTS.md "Storage,
// bounded delivery and offline sync"). Redemption commits the byte charge before
// Storage is read; no Range, no redirect to a replayable Storage URL, no retry.
import { PublicError, sha256, uuid } from './http.ts';

export interface PodcastDeliveryDeps {
  account(request: Request): Promise<string>;
  rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T>;
  download(bucket: string, path: string, maximum: number, observed?: (bytes: number) => void): Promise<Uint8Array>;
}
interface Redemption { grant_id: string; bucket: string; path: string; bytes: number; sha256: string; media_type: string }

export async function deliverPodcastMember(request: Request, deps: PodcastDeliveryDeps, headers: Record<string, string>): Promise<Response> {
  if (request.method !== 'GET') throw new PublicError(405, 'method_unavailable');
  if (request.headers.has('range')) throw new PublicError(416, 'podcast_range_unavailable');
  const url = new URL(request.url), token = url.searchParams.get('grant');
  if (!token || !/^[0-9a-f]{64}$/.test(token) || url.searchParams.size !== 2) throw new PublicError(400, 'invalid_podcast_grant');
  const objectID = uuid(url.searchParams.get('member'));
  const accountID = await deps.account(request);
  const admitted = await deps.rpc<Redemption>('worker_podcast_delivery_redeem', { p_account_id: accountID,
    p_token_sha256: '\\x' + await sha256(new TextEncoder().encode(token)), p_object_id: objectID });
  if (!admitted || admitted.bucket !== 'podcast-assets' || !Number.isSafeInteger(admitted.bytes) || admitted.bytes < 1 || admitted.bytes > 16_777_216
    || !/^[0-9a-f]{64}$/.test(admitted.sha256) || !/^(shared|private\/[0-9a-f-]{36})\/[0-9a-f]{64}\/audio\.m4a$/.test(admitted.path)
    || admitted.media_type !== 'audio/mp4') throw new PublicError(503, 'podcast_integrity_failed');
  let received = 0, observation: 'response_created' | 'upstream_failed' | 'integrity_failed' | 'cancelled' = 'upstream_failed';
  try {
    request.signal.throwIfAborted();
    const bytes = await deps.download(admitted.bucket, admitted.path, admitted.bytes, n => { received = Math.min(n, admitted.bytes); });
    received = Math.min(bytes.length, admitted.bytes);
    if (bytes.length !== admitted.bytes || await sha256(bytes) !== admitted.sha256) {
      observation = 'integrity_failed'; throw new PublicError(503, 'podcast_integrity_failed');
    }
    request.signal.throwIfAborted();
    observation = 'response_created';
    // The authorized ceiling, not this body, is the cost bound: the client may not receive every byte.
    return new Response(new Uint8Array(bytes), { headers: { ...headers, 'Content-Type': admitted.media_type,
      'Content-Length': String(bytes.length), 'Cache-Control': 'private, no-store', 'Referrer-Policy': 'no-referrer',
      'X-Content-Type-Options': 'nosniff', 'Accept-Ranges': 'none' } });
  } catch (error) {
    if (request.signal.aborted) observation = 'cancelled';
    throw error;
  } finally {
    await deps.rpc('worker_podcast_delivery_observed', { p_grant_id: admitted.grant_id, p_object_id: objectID,
      p_upstream_bytes: received, p_response_bytes: observation === 'response_created' ? received : 0, p_observation: observation }).catch(() => {});
  }
}
