// Bounded JSON bodies (review A24, 2026-10-21). Kept apart from http.ts on purpose: http.ts is bundled into the device
// reader compiler (scripts/build-arxiv-compiler.mjs), whose compiled bytes are the shipped reader's identity, so server
// helpers are added here instead of changing that module.
import { PublicError, readBounded } from './http.ts';

/** A small JSON request body (add-paper, add-reference): at most `maximum` bytes whether or not the client declared a
 * length, read before anything is parsed. Oversize answers 413, anything unreadable 400, both `invalid_request`. */
export async function readRequestJSON(request: Request, maximum: number): Promise<unknown> {
  let bytes: Uint8Array;
  try { bytes = await readBounded(request, maximum); }
  catch (error) { throw new PublicError(error instanceof PublicError && error.status === 413 ? 413 : 400, 'invalid_request'); }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
  catch { throw new PublicError(400, 'invalid_request'); }
}

/** A third party's JSON answer (OpenAlex, Crossref, DNS over HTTPS), read up to `maximum` bytes, declared or streamed.
 * Throws on a larger or unparsable body; the caller treats that like any failed lookup. */
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
