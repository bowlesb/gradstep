// Local PDF file checks for the Add sheet and the device PDF membership (docs/architecture/HTML_FIRST_READER.md).
// A chosen file is read and inspected only in this browser; nothing here sends bytes anywhere. The former
// chunked upload protocol is gone: the server refuses PDF ingress (HTTP 410 `pdf_device_only`).
import { BackendError } from './backend';

export const MAX_PDF_BYTES = 67_108_864;

/** File checks shared by the Add sheet and tests. MIME is deliberately not trusted. */
export async function readPDF(file: Blob & { name?: string }, signal?: AbortSignal): Promise<Uint8Array<ArrayBuffer>> {
  if (!Number.isSafeInteger(file.size) || file.size < 5 || file.size > MAX_PDF_BYTES) throw new BackendError(file.size > MAX_PDF_BYTES ? 'upload_too_large' : 'invalid_upload');
  signal?.throwIfAborted();
  let data: Uint8Array<ArrayBuffer>;
  try { data = new Uint8Array(await file.arrayBuffer()) as Uint8Array<ArrayBuffer>; }
  catch { throw new BackendError('connection'); }
  signal?.throwIfAborted();
  if (data.length !== file.size || new TextDecoder('ascii').decode(data.subarray(0, 5)) !== '%PDF-') throw new BackendError('invalid_upload');
  return data;
}

export function titleForPDF(file: { name?: string }): { display_name: string; filename?: string } {
  const raw = typeof file.name === 'string' ? file.name.replace(/\.pdf$/i, '') : '';
  const displayName = raw.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 500) || 'Uploaded paper';
  const filename = typeof file.name === 'string' && file.name.length > 0
    ? file.name.replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, 255) : undefined;
  return { display_name: displayName, ...(filename ? { filename } : {}) };
}
