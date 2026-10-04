import { arxivReference, arxivURLs, type ArxivReference } from './arxiv.ts';

export interface MetadataSourceRequest {
  readonly reference: ArxivReference;
  readonly stage: 'atom' | 'license';
  readonly byteCeiling: number;
  readonly deadline: number;
}
export type MetadataSourceResult =
  | { kind: 'complete'; status: number; bytes: Uint8Array; retryAfterSeconds: number }
  | { kind: 'uncertain'; reason: 'transport' | 'deadline' | 'size' | 'encoding' | 'redirect' | 'incomplete' };

/** A new connection owner for each fetch. Its close implementation must be
 * proved on the eventual runtime; EOF alone does not close a pooled socket.
 * This file creates no default/live connection and confers no source permit. */
export interface SourceConnection {
  fetch(url: string, init: RequestInit): Promise<Response>;
  close(): Promise<void> | void;
}

function retryAfter(value: string | null, now: number): number {
  if (!value || value.length > 128) return 0;
  const seconds = /^\d+$/.test(value) ? Number(value) : Math.ceil((Date.parse(value) - now) / 1000);
  return Number.isFinite(seconds) ? Math.min(86_400, Math.max(0, seconds)) : 0;
}

export function createMetadataSourceTransport(open: () => SourceConnection, now: () => number = Date.now) {
  return async (input: MetadataSourceRequest, parent: AbortSignal): Promise<MetadataSourceResult> => {
    // Own identity and limits before opening a connection or awaiting anything.
    const reference = arxivReference(`${input.reference.sourceID}${input.reference.revision === null ? '' : `v${input.reference.revision}`}`);
    const stage = input.stage, limit = input.byteCeiling, deadline = input.deadline;
    if (reference.sourceID !== input.reference.sourceID || reference.revision !== input.reference.revision ||
        !['atom', 'license'].includes(stage) || !Number.isSafeInteger(limit) || limit < 1 || limit > 1_048_576 ||
        !Number.isFinite(deadline)) throw new Error('invalid_source_request');
    if (parent.aborted || deadline <= now()) return { kind: 'uncertain', reason: 'deadline' };
    const url = arxivURLs(reference)[stage === 'atom' ? 'atom' : 'raw'];
    const controller = new AbortController();
    const abort = () => controller.abort();
    parent.addEventListener('abort', abort, { once: true });
    const timer = setTimeout(abort, Math.min(30_000, deadline - now()));
    let connection: SourceConnection | undefined, reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    let closed = false, reason: MetadataSourceResult & { kind: 'uncertain' } = { kind: 'uncertain', reason: 'transport' };
    let rejectAbort: () => void = () => {};
    const aborted = new Promise<never>((_, reject) => {
      rejectAbort = () => { void reader?.cancel().catch(() => {}); reject(new Error('source_deadline')); };
      controller.signal.addEventListener('abort', rejectAbort, { once: true });
    });
    try {
      controller.signal.throwIfAborted();
      connection = open();
      const response = await Promise.race([connection.fetch(url, {
        method: 'GET', redirect: 'error', signal: controller.signal,
        headers: { Accept: 'application/atom+xml, application/xml, text/xml', 'Accept-Encoding': 'identity' },
      }), aborted]);
      const retry = retryAfter(response.headers.get('retry-after'), now());
      if (response.redirected) { reason.reason = 'redirect'; throw new Error('source_redirect'); }
      const encoding = response.headers.get('content-encoding')?.trim().toLowerCase();
      if (encoding && encoding !== 'identity') { reason.reason = 'encoding'; throw new Error('source_encoding'); }
      const declared = response.headers.get('content-length');
      if (declared !== null && (!/^\d+$/.test(declared) || !Number.isSafeInteger(Number(declared)) || Number(declared) > limit)) {
        reason.reason = 'size'; throw new Error('source_size');
      }
      const parts: Uint8Array[] = []; let size = 0;
      if (response.body) {
        reader = response.body.getReader();
        while (true) {
          const { done, value } = await Promise.race([reader.read(), aborted]);
          if (done) break;
          size += value.byteLength;
          if (size > limit) { reason.reason = 'size'; throw new Error('source_size'); }
          parts.push(new Uint8Array(value));
        }
      }
      if (declared !== null && size !== Number(declared)) { reason.reason = 'incomplete'; throw new Error('source_incomplete'); }
      controller.signal.throwIfAborted();
      if (now() >= deadline) { reason.reason = 'deadline'; throw new Error('source_deadline'); }
      // Only complete EOF plus successful, runtime-proven connection closure
      // permits the caller to report actual bytes and release the DB gate.
      await Promise.race([Promise.resolve(connection.close()), aborted]);
      closed = true;
      controller.signal.throwIfAborted();
      if (now() >= deadline) return { kind: 'uncertain', reason: 'deadline' };
      const bytes = new Uint8Array(size); let offset = 0;
      for (const part of parts) { bytes.set(part, offset); offset += part.length; }
      return { kind: 'complete', status: response.status, bytes, retryAfterSeconds: retry };
    } catch {
      if (controller.signal.aborted) reason.reason = 'deadline';
      return reason;
    } finally {
      clearTimeout(timer); parent.removeEventListener('abort', abort);
      controller.signal.removeEventListener('abort', rejectAbort);
      if (!closed) {
        controller.abort();
        void reader?.cancel().catch(() => {});
        // A failed/aborted cleanup never manufactures closure evidence. Do not
        // let a broken close promise extend this invocation's public deadline.
        try { void Promise.resolve(connection?.close()).catch(() => {}); } catch { /* remains uncertain */ }
      }
      reader?.releaseLock();
    }
  };
}
