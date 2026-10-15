import type { PublicError } from './http.ts';

// Our own 429s and 503s say when to ask again (docs/architecture/RESILIENCE.md, fix 6): a `Retry-After` header and
// `retry_after` in the JSON body. Kept out of http.ts on purpose: the device compiler bundles http.ts, and its bytes are
// the compiler's identity.

/** Seconds a client should wait before asking again, by error code. Rate limits are hourly windows on the server; a
 * busy or unavailable service usually recovers within seconds. */
export const RETRY_AFTER_SECONDS: Record<string, number> = {
  request_rate_limit: 60, rate_limited: 60, attachment_storage_limit: 3600, reader_transfer_limit: 3600,
  search_busy: 5, service_unavailable: 10, provider_unavailable: 10, route_unavailable: 30, asset_inventory_incomplete: 60,
};
export function retryAfterFor(failure: PublicError): number | undefined {
  if (failure.status !== 429 && failure.status !== 503) return undefined;
  return RETRY_AFTER_SECONDS[failure.code] ?? (failure.status === 429 ? 60 : 10);
}
/** A JSON error: `{ code }`, plus Retry-After and `retry_after` when waiting will help (429, 503). */
export function errorResponse(failure: PublicError, headers: Record<string, string>): Response {
  const wait = retryAfterFor(failure);
  return wait === undefined ? Response.json({ code: failure.code }, { status: failure.status, headers })
    : Response.json({ code: failure.code, retry_after: wait }, { status: failure.status, headers: { ...headers, 'Retry-After': String(wait) } });
}
