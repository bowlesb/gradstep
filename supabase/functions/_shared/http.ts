export class PublicError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string) { super(code); this.status = status; this.code = code; }
}

export function uuid(value: string | null): string {
  if (!value || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) throw new PublicError(400, 'invalid_id');
  return value.toLowerCase();
}

export async function readBounded(request: Request, maximum: number): Promise<Uint8Array> {
  const declared = request.headers.get('content-length');
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > maximum)) throw new PublicError(413, 'attachment_too_large');
  if (!request.body) throw new PublicError(400, 'empty_body');
  const reader = request.body.getReader();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => { timer = setTimeout(() => { void reader.cancel(); reject(new PublicError(408, 'upload_timeout')); }, 30_000); });
  try {
    const parts: Uint8Array[] = []; let length = 0;
    while (true) {
      const { done, value } = await Promise.race([reader.read(), deadline]);
      if (done) break;
      length += value.byteLength;
      if (length > maximum) { void reader.cancel(); throw new PublicError(413, 'attachment_too_large'); }
      parts.push(value);
    }
    if (!length) throw new PublicError(400, 'empty_body');
    const joined = new Uint8Array(length); let offset = 0;
    for (const part of parts) { joined.set(part, offset); offset += part.byteLength; }
    return joined;
  } finally { if (timer) clearTimeout(timer); reader.releaseLock(); }
}

/** A small JSON request body (add-paper, add-reference): at most `maximum` bytes whether or not the client declared a
 * length, read before anything is parsed (review A24). Oversize answers 413, anything unreadable 400, both `invalid_request`. */
export async function readRequestJSON(request: Request, maximum: number): Promise<unknown> {
  let bytes: Uint8Array;
  try { bytes = await readBounded(request, maximum); }
  catch (error) { throw new PublicError(error instanceof PublicError && error.status === 413 ? 413 : 400, 'invalid_request'); }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
  catch { throw new PublicError(400, 'invalid_request'); }
}

/** A third party's JSON answer (OpenAlex, Crossref, DNS over HTTPS), read up to `maximum` bytes, declared or streamed
 * (review A24). Throws on a larger or unparsable body; the caller treats that like any failed lookup. */
export async function readJSONCapped(response: Response, maximum: number): Promise<unknown> {
  const declared = response.headers.get('content-length');
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > maximum)) {
    await response.body?.cancel().catch(() => {}); throw new Error('response_too_large');
  }
  if (!response.body) throw new Error('response_empty');
  const reader = response.body.getReader(); const parts: Uint8Array[] = []; let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maximum) { await reader.cancel().catch(() => {}); throw new Error('response_too_large'); }
      parts.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
  return JSON.parse(new TextDecoder().decode(bytes));
}

export async function sha256(bytes: Uint8Array): Promise<string> {
  const owned = new Uint8Array(bytes);
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', owned)), b => b.toString(16).padStart(2, '0')).join('');
}

export function exposedDatabaseError(message: string): PublicError {
  const states: Record<string, number> = {
    authentication_required: 401, account_unavailable: 403, report_unavailable: 403,
    attachment_unavailable: 403, owner_mfa_required: 403, operator_required: 403,
    attachment_id_conflict: 409, attachment_expired: 410, invalid_attachment: 400,
    attachment_count_limit: 422, attachment_storage_limit: 429, request_rate_limit: 429,
    attachment_verification_failed: 409, reader_unavailable: 403, document_unavailable: 403, route_unavailable: 503,
    reader_upgrade_required: 426, reader_transfer_limit: 429, reader_grant_unavailable: 403, reader_grant_consumed: 409,
    asset_inventory_incomplete: 503, invalid_reader_transport: 400,
  };
  return new PublicError(states[message] ?? 503, states[message] ? message : 'service_unavailable');
}
