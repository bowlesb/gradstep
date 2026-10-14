// Historical Mathpix OCR identity and provider record shapes. They remain so that retained
// mathpix-mmd reader bundles and their provenance stay verifiable. There is no provider client:
// the server submits nothing to Mathpix (docs/architecture/HTML_FIRST_READER.md).
import { sha256 } from './http.ts';

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
