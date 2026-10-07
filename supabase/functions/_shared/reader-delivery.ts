import { PublicError, sha256, uuid } from './http.ts';

export interface ReaderDeliveryDeps {
  account(request: Request): Promise<string>;
  rpc<T>(name: string, parameters: Record<string, unknown>): Promise<T>;
  download(bucket: string, path: string, maximum: number, observed?: (bytes: number) => void): Promise<Uint8Array>;
}
interface Redemption { grant_id: string; bucket: string; path: string; bytes: number; sha256: string; media_type: string }

/** Actual delivery, not URL issuance, consumes the one-use grant. No retry or
 * redirect to replayable Storage URLs is allowed after that transaction. */
export async function deliverReaderMember(request: Request, deps: ReaderDeliveryDeps, headers: Record<string, string>): Promise<Response> {
  if (request.method !== 'GET') throw new PublicError(405, 'method_unavailable');
  if (request.headers.has('range')) throw new PublicError(416, 'reader_range_unavailable');
  const url = new URL(request.url), token = url.searchParams.get('grant');
  if (!token || !/^[0-9a-f]{64}$/.test(token) || url.searchParams.size !== 2) throw new PublicError(400, 'invalid_reader_grant');
  const objectID = uuid(url.searchParams.get('member'));
  const accountID = await deps.account(request);
  const tokenSHA = await sha256(new TextEncoder().encode(token));
  const admitted = await deps.rpc<Redemption>('worker_reader_delivery_redeem', { p_account_id: accountID, p_token_sha256: '\\x' + tokenSHA, p_object_id: objectID });
  if (!admitted || admitted.bucket !== 'paper-assets' || !Number.isSafeInteger(admitted.bytes) || admitted.bytes < 1 || admitted.bytes > 16_777_216
    || !/^[0-9a-f]{64}$/.test(admitted.sha256) || !admitted.path.startsWith('reader/')) throw new PublicError(503, 'reader_integrity_failed');
  let received = 0, observation: 'response_created' | 'upstream_failed' | 'integrity_failed' | 'cancelled' = 'upstream_failed';
  try {
    request.signal.throwIfAborted();
    const bytes = await deps.download(admitted.bucket, admitted.path, admitted.bytes, bytes => { received = Math.min(bytes, admitted.bytes); });
    received = Math.min(bytes.length, admitted.bytes);
    if (bytes.length !== admitted.bytes || await sha256(bytes) !== admitted.sha256) {
      observation = 'integrity_failed'; throw new PublicError(503, 'reader_integrity_failed');
    }
    request.signal.throwIfAborted();
    observation = 'response_created';
    // This is the body offered to the transport, not proof the client received
    // every byte. The committed authorized ceiling remains the cost bound.
    return new Response(new Uint8Array(bytes), { headers: { ...headers, 'Content-Type': admitted.media_type,
      'Content-Length': String(bytes.length), 'Cache-Control': 'private, no-store', 'Referrer-Policy': 'no-referrer',
      'X-Content-Type-Options': 'nosniff' } });
  } catch (error) {
    if (request.signal.aborted) observation = 'cancelled';
    throw error;
  } finally {
    await deps.rpc('worker_reader_delivery_observed', { p_grant_id: admitted.grant_id, p_object_id: objectID,
      p_upstream_bytes: received, p_response_bytes: observation === 'response_created' ? received : 0, p_observation: observation }).catch(() => {});
  }
}

/** Read a trusted Storage object with a transport bound, before concatenation.
 * Callers make one request; automatic retries would need another admission. */
export async function boundedStorageDownload(url: string, key: string, bucket: string, path: string, maximum: number,
  fetcher: typeof fetch = fetch, observed?: (bytes: number) => void): Promise<Uint8Array> {
  if (!Number.isSafeInteger(maximum) || maximum < 1 || maximum > 67_108_864) throw new Error('storage_download_bound');
  const target = `${url.replace(/\/$/, '')}/storage/v1/object/${encodeURIComponent(bucket)}/${path.split('/').map(encodeURIComponent).join('/')}`;
  const response = await fetcher(target, { headers: { Authorization: `Bearer ${key}`, apikey: key }, redirect: 'error',
    signal: AbortSignal.timeout(60_000) });
  if (response.status !== 200 || !response.body) { await response.body?.cancel(); throw new Error('storage_download_failed'); }
  const length = response.headers.get('content-length');
  if (length && (!/^\d+$/.test(length) || Number(length) > maximum)) { await response.body.cancel(); throw new Error('storage_object_too_large'); }
  const reader = response.body.getReader(), parts: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const next = await reader.read(); if (next.done) break;
      size += next.value.length;
      observed?.(Math.min(size, maximum));
      if (size > maximum) { await reader.cancel(); throw new Error('storage_object_too_large'); }
      parts.push(next.value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const part of parts) { bytes.set(part, offset); offset += part.length; }
  return bytes;
}
