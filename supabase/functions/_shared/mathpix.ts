import { sha256 } from './http.ts';

const API = 'https://api.mathpix.com/v3';
export const MATHPIX_PROFILE = 'science-reader-mmd-v1';
// Renderer versions are deliberately separate from this OCR identity. A style,
// sanitizer or equation-renderer upgrade must reuse the durable raw OCR output.
const BASE_OPTIONS = {
  conversion_formats: { 'mmd.zip': true }, metadata: { improve_mathpix: false },
  rm_spaces: false, rm_fonts: false, include_equation_tags: true, idiomatic_eqn_arrays: true,
  math_inline_delimiters: ['\\(', '\\)'], math_display_delimiters: ['\\[', '\\]'],
  include_page_breaks: true, include_hyperlinks: true, include_page_info: ['margin_note'],
  preserve_section_numbering: true, auto_number_sections: false, remove_section_numbering: false,
  disable_lstlisting: false, disable_itemize: false,
};
const OPTIONS = JSON.stringify(BASE_OPTIONS);

/** Options JSON for a funded attempt. A page limit bounds the paid pages with
 * Mathpix `page_ranges`; it is part of the OCR identity (options hash). */
export function mathpixOptionsJSON(pageLimit?: number): string {
  if (pageLimit === undefined) return OPTIONS;
  if (!Number.isSafeInteger(pageLimit) || pageLimit < 1 || pageLimit > 250) throw new MathpixError('submission_checkpoint_mismatch');
  return JSON.stringify({ ...BASE_OPTIONS, page_ranges: `1-${pageLimit}` });
}

export async function mathpixProfile(pageLimit?: number): Promise<{ id: string; api: string; optionsJSON: string; sha256: string }> {
  const optionsJSON = mathpixOptionsJSON(pageLimit);
  return { id: MATHPIX_PROFILE, api: 'v3/pdf', optionsJSON,
    sha256: await sha256(new TextEncoder().encode(`science-reader/ocr-options/v1\nv3/pdf\n${MATHPIX_PROFILE}\n${optionsJSON}`)) };
}

export class MathpixError extends Error {
  readonly code: string;
  readonly httpStatus?: number;
  readonly retryAfterSeconds?: number;
  constructor(code: string, httpStatus?: number, retryAfterSeconds?: number) {
    super(code); this.code = code; this.httpStatus = httpStatus; this.retryAfterSeconds = retryAfterSeconds;
  }
}

function object(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new MathpixError('provider_response_invalid');
  return value as Record<string, unknown>;
}
function providerID(value: unknown): string {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,160}$/.test(value)) throw new MathpixError('provider_id_invalid');
  return value;
}
function optionalCount(value: unknown): number | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0 || value > 250) throw new MathpixError('provider_page_count_invalid');
  return value;
}
function errorCode(value: unknown): string | null {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return null;
  const id = (value as Record<string, unknown>).id;
  return typeof id === 'string' && /^[a-zA-Z0-9_-]{1,80}$/.test(id) ? id : null;
}

export interface MathpixStatus {
  providerJobID: string;
  state: 'received' | 'loaded' | 'split' | 'processing' | 'completed' | 'error';
  pages: number | null;
  completedPages: number | null;
  pipelineVersion: string | null;
  deleted: boolean;
  errorCode: string | null;
}
export interface MathpixConversion {
  providerJobID: string;
  state: 'received' | 'loaded' | 'processing' | 'completed' | 'error' | 'missing';
  errorCode: string | null;
}

export function mathpixStatus(value: unknown, expectedID: string): MathpixStatus {
  providerID(expectedID);
  const response = object(value);
  if (response.pdf_id !== expectedID || typeof response.status !== 'string' || !['received', 'loaded', 'split', 'processing', 'completed', 'error'].includes(response.status)) throw new MathpixError('provider_response_invalid');
  const pages = optionalCount(response.num_pages), completed = optionalCount(response.num_pages_completed);
  if ((pages !== null && completed !== null && completed > pages) || (response.status === 'completed' && pages === 0)) throw new MathpixError('provider_page_count_invalid');
  const version = response.version;
  if (version !== undefined && (typeof version !== 'string' || version.length > 128)) throw new MathpixError('provider_response_invalid');
  return { providerJobID: expectedID, state: response.status as MathpixStatus['state'], pages,
    completedPages: completed, pipelineVersion: typeof version === 'string' ? version : null,
    deleted: response.deleted_at !== undefined && response.deleted_at !== null, errorCode: errorCode(response.error_info) };
}

export function mathpixConversion(value: unknown, expectedID: string): MathpixConversion {
  providerID(expectedID);
  const response = object(value);
  if (response.pdf_id !== undefined && response.pdf_id !== expectedID) throw new MathpixError('provider_response_invalid');
  const formats = response.conversion_status === undefined ? {} : object(response.conversion_status);
  const format = formats['mmd.zip'] === undefined ? null : object(formats['mmd.zip']);
  if (!format) return { providerJobID: expectedID, state: 'missing', errorCode: null };
  if (typeof format.status !== 'string' || !['received', 'loaded', 'processing', 'completed', 'error'].includes(format.status)) throw new MathpixError('provider_response_invalid');
  return { providerJobID: expectedID, state: format.status as MathpixConversion['state'], errorCode: errorCode(format.error_info) };
}

export type MathpixSubmission =
  | { state: 'accepted'; providerJobID: string }
  | { state: 'submission_uncertain'; reason: string; httpStatus?: number };
export type MathpixOutput = 'mmd' | 'mmd.zip' | 'lines.json';
const outputLimits: Record<MathpixOutput, number> = { mmd: 8_388_608, 'mmd.zip': 33_554_432, 'lines.json': 16_777_216 };

function retryAfter(response: Response): number | undefined {
  const value = response.headers.get('retry-after');
  if (!value) return undefined;
  const seconds = /^\d+$/.test(value) ? Number(value) : Math.ceil((Date.parse(value) - Date.now()) / 1000);
  return Number.isFinite(seconds) ? Math.min(86_400, Math.max(1, seconds)) : undefined;
}

async function bodyBytes(response: Response, maximum: number, signal: AbortSignal): Promise<Uint8Array> {
  const length = response.headers.get('content-length');
  if (length && (!/^\d+$/.test(length) || Number(length) > maximum)) {
    void response.body?.cancel().catch(() => {}); throw new MathpixError('provider_body_limit');
  }
  if (!response.body) throw new MathpixError('provider_response_invalid');
  const reader = response.body.getReader();
  let abort: () => void = () => {};
  const aborted = new Promise<never>((_, reject) => {
    abort = () => { void reader.cancel().catch(() => {}); reject(new MathpixError('provider_transport_failed')); };
    signal.addEventListener('abort', abort, { once: true });
  });
  const parts: Uint8Array[] = []; let size = 0;
  try {
    signal.throwIfAborted();
    while (true) {
      const { done, value } = await Promise.race([reader.read(), aborted]);
      if (done) break;
      size += value.byteLength;
      if (size > maximum) { void reader.cancel().catch(() => {}); throw new MathpixError('provider_body_limit'); }
      parts.push(value);
    }
    signal.throwIfAborted();
    const encoding = response.headers.get('content-encoding')?.trim().toLowerCase();
    if (length && (!encoding || encoding === 'identity') && size !== Number(length)) throw new MathpixError('provider_response_incomplete');
    if (!size) throw new MathpixError('provider_response_invalid');
    const joined = new Uint8Array(size); let offset = 0;
    for (const part of parts) { joined.set(part, offset); offset += part.length; }
    return joined;
  } finally { signal.removeEventListener('abort', abort); reader.releaseLock(); }
}

function json(bytes: Uint8Array): unknown {
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
  catch { throw new MathpixError('provider_response_invalid'); }
}

// Transport only. The worker must durably reserve/authorize and transition its
// fenced attempt to submitting BEFORE calling submitOnce. This module neither
// authorizes a charge nor retries a paid POST. No public route calls it yet.
export class MathpixClient {
  #headers: Headers;
  #fetch: typeof fetch;
  constructor(credentials: { appID: string; appKey: string }, fetcher: typeof fetch = fetch) {
    if (typeof credentials.appID !== 'string' || typeof credentials.appKey !== 'string' ||
        !/^[\x21-\x7e]{1,2048}$/.test(credentials.appID) || !/^[\x21-\x7e]{1,2048}$/.test(credentials.appKey)) throw new MathpixError('provider_credentials_unavailable');
    this.#headers = new Headers({ app_id: credentials.appID, app_key: credentials.appKey });
    this.#fetch = fetcher;
  }

  async #request(path: string, init: RequestInit, limit: number, signal?: AbortSignal): Promise<{ response: Response; bytes: Uint8Array }> {
    const controller = new AbortController();
    const abort = () => controller.abort();
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) controller.abort();
    const timeout = setTimeout(abort, 30_000);
    try {
      const headers = new Headers(this.#headers);
      for (const [name, value] of new Headers(init.headers)) headers.set(name, value);
      const response = await this.#fetch(`${API}/${path}`, { ...init, headers, redirect: 'error', signal: controller.signal });
      if (response.status !== 200) {
        void response.body?.cancel().catch(() => {});
        throw new MathpixError(response.status === 202 ? 'provider_output_pending' : 'provider_http_failure', response.status, retryAfter(response));
      }
      return { response, bytes: await bodyBytes(response, limit, controller.signal) };
    } catch (error) {
      if (error instanceof MathpixError) throw error;
      throw new MathpixError('provider_transport_failed');
    } finally { clearTimeout(timeout); signal?.removeEventListener('abort', abort); }
  }

  async submitOnce(pdf: Uint8Array, checkpoint: { attemptID: string; documentSHA256: string; optionsSHA256: string; pageLimit?: number }, signal?: AbortSignal): Promise<MathpixSubmission> {
    const { attemptID, documentSHA256, optionsSHA256, pageLimit } = checkpoint;
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(attemptID) ||
        pdf.length < 8 || pdf.length > 67_108_864) throw new MathpixError('submission_checkpoint_mismatch');
    // Own the bytes and identities before the first suspension point. A caller
    // reusing its download buffer cannot alter the payload after hashing it.
    const capturedPDF = new Uint8Array(pdf);
    const profile = await mathpixProfile(pageLimit);
    if (new TextDecoder().decode(capturedPDF.subarray(0, 5)) !== '%PDF-' ||
        await sha256(capturedPDF) !== documentSHA256 || profile.sha256 !== optionsSHA256) throw new MathpixError('submission_checkpoint_mismatch');
    // PDF structure, page count, ownership and scope were verified at ingress.
    // Here the exact bytes/options are bound to the recorded submission attempt.
    const form = new FormData();
    form.append('file', new Blob([capturedPDF], { type: 'application/pdf' }), `${attemptID}.pdf`);
    form.append('options_json', profile.optionsJSON);
    return this.#submit({ method: 'POST', body: form }, signal);
  }

  /** Large originals: Mathpix fetches a short-lived signed Storage URL whose
   * content-addressed path already binds the verified bytes. */
  async submitURL(url: string, checkpoint: { attemptID: string; optionsSHA256: string; pageLimit?: number }, signal?: AbortSignal): Promise<MathpixSubmission> {
    const profile = await mathpixProfile(checkpoint.pageLimit);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(checkpoint.attemptID) ||
        profile.sha256 !== checkpoint.optionsSHA256 || !/^https:\/\/[^/@\s]+\/[^\s]{1,4000}$/.test(url)) throw new MathpixError('submission_checkpoint_mismatch');
    const body = JSON.stringify({ url, ...JSON.parse(profile.optionsJSON) });
    return this.#submit({ method: 'POST', body, headers: { 'content-type': 'application/json' } }, signal);
  }

  async #submit(init: RequestInit, signal?: AbortSignal): Promise<MathpixSubmission> {
    try {
      const { bytes } = await this.#request('pdf', init, 65_536, signal);
      const response = object(json(bytes));
      if (response.error || response.error_info) throw new MathpixError('provider_response_invalid');
      return { state: 'accepted', providerJobID: providerID(response.pdf_id) };
    } catch (error) {
      // Even a rejected/malformed HTTP response is not evidence of zero cost.
      // The durable worker reconciles this state; it must never loop this POST.
      const failure = error instanceof MathpixError ? error : new MathpixError('provider_transport_failed');
      return { state: 'submission_uncertain', reason: failure.code, httpStatus: failure.httpStatus };
    }
  }

  async status(id: string, signal?: AbortSignal): Promise<MathpixStatus> {
    const { bytes } = await this.#request(`pdf/${providerID(id)}`, { method: 'GET' }, 65_536, signal);
    return mathpixStatus(json(bytes), id);
  }

  async conversion(id: string, signal?: AbortSignal): Promise<MathpixConversion> {
    const { bytes } = await this.#request(`converter/${providerID(id)}`, { method: 'GET' }, 65_536, signal);
    return mathpixConversion(json(bytes), id);
  }

  async output(status: MathpixStatus, format: MathpixOutput, conversion?: MathpixConversion, signal?: AbortSignal): Promise<Uint8Array> {
    const id = providerID(status.providerJobID);
    if (!Object.hasOwn(outputLimits, format) || status.state !== 'completed' || status.deleted ||
        (format === 'mmd.zip' && (conversion?.providerJobID !== id || conversion.state !== 'completed'))) throw new MathpixError('provider_output_pending');
    const { bytes, response } = await this.#request(`pdf/${id}.${format}`, { method: 'GET' }, outputLimits[format], signal);
    if (format === 'mmd.zip') {
      if (bytes[0] !== 0x50 || bytes[1] !== 0x4b || bytes[2] !== 3 || bytes[3] !== 4) throw new MathpixError('provider_output_invalid');
    } else if (format === 'lines.json') {
      const data = object(json(bytes));
      if (!Array.isArray(data.pages) || !data.pages.length || data.pages.length > 250 ||
          data.pages.some(page => page === null || typeof page !== 'object' || Array.isArray(page))) throw new MathpixError('provider_output_invalid');
    }
    else {
      const media = response.headers.get('content-type')?.toLowerCase();
      if (media?.includes('application/json') || media?.includes('text/html')) throw new MathpixError('provider_output_invalid');
      try {
        const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
        if (text.includes('\0') || /^\s*<(?:!doctype\s+html|html|body)\b/i.test(text)) throw new Error();
      }
      catch { throw new MathpixError('provider_output_invalid'); }
    }
    // Still untrusted: the collector must validate ZIP paths/expansion, line
    // geometry and all assets before publishing a durable render manifest.
    return bytes;
  }
}
