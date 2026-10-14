import { describe, expect, it } from 'vitest';
import { MAX_PDF_BYTES, readPDF, titleForPDF } from '../src/lib/pdf-upload';

const file = (bytes: number[] | Uint8Array, name = 'Attention.pdf') => Object.assign(new Blob([Array.isArray(bytes) ? new Uint8Array(bytes) : bytes], { type: 'application/pdf' }), { name }) as Blob & { name: string };

describe('device-only PDF file checks', () => {
  it('reads a PDF by its bytes, never its declared type', async () => {
    const bytes = await readPDF(file([37, 80, 68, 70, 45, 1, 2]));
    expect(Array.from(bytes)).toEqual([37, 80, 68, 70, 45, 1, 2]);
    await expect(readPDF(file([1, 2, 3, 4, 5]))).rejects.toMatchObject({ code: 'invalid_upload' });
    await expect(readPDF(file([37, 80, 68, 70]))).rejects.toMatchObject({ code: 'invalid_upload' });
  });
  it('refuses oversized input before reading it', async () => {
    await expect(readPDF(new Blob([new Uint8Array(MAX_PDF_BYTES + 1)]))).rejects.toMatchObject({ code: 'upload_too_large' });
  });
  it('derives a bounded display title from the file name', () => {
    expect(titleForPDF({ name: 'Attention Is All\tYou Need.pdf' })).toEqual({ display_name: 'Attention Is All You Need', filename: 'Attention Is All You Need.pdf' });
    expect(titleForPDF({})).toEqual({ display_name: 'Uploaded paper' });
    expect(titleForPDF({ name: 'x'.repeat(600) + '.pdf' }).display_name).toHaveLength(500);
  });
  it('exposes no upload transport', async () => {
    const module = await import('../src/lib/pdf-upload');
    expect(Object.keys(module).sort()).toEqual(['MAX_PDF_BYTES', 'readPDF', 'titleForPDF']);
  });
});
