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
    attachment_verification_failed: 409,
  };
  return new PublicError(states[message] ?? 503, states[message] ? message : 'service_unavailable');
}
