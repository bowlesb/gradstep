import { describe, expect, it, beforeEach, vi } from 'vitest';
import { generateBundle, keyRing } from '../src/lib/wire';

const account = '11111111-2222-4333-8444-555555555555';
const device = '22222222-3333-4444-8555-666666666666';
const calls = vi.hoisted(() => {
  class MockBackendError extends Error { constructor(readonly code: string, readonly status = 0) { super(code); } }
  return { post: vi.fn(), put: vi.fn(), rpc: vi.fn(), MockBackendError };
});
vi.mock('../src/lib/backend', () => ({ BackendError: calls.MockBackendError, functionPost: calls.post, functionPutBytes: calls.put, rpc: calls.rpc }));

const file = (bytes: number[] | Uint8Array, name = 'Attention.pdf') => Object.assign(new Blob([Array.isArray(bytes) ? new Uint8Array(bytes) : bytes], { type: 'application/pdf' }), { name }) as Blob & { name: string };
const ticket = (id: string, revision: number, descriptor: boolean, ref: unknown = null, bytes = [10]) => ({
  upload_id: id, protocol: 'upload-chunks-v1', state: 'receiving', revision, generation: 1, byte_count: bytes.reduce((a, b) => a + b, 0),
  chunk_bytes: 4_194_304, part_count: bytes.length, expires_at: '2026-10-10T00:00:00Z', result: null,
  descriptor_required: descriptor, descriptor_ref: ref,
  parts: bytes.map((size, index) => ({ index, bytes: size, verified: revision > 1, attempts: revision > 1 ? 1 : 0, uncertain: 0 })),
});

beforeEach(() => { calls.post.mockReset(); calls.put.mockReset(); calls.rpc.mockReset(); });

describe('device-only PDF cutover',()=>{
 it('blocks the former upload API before any admission, descriptor or byte request',async()=>{
  const {uploadPDF}=await import('../src/lib/pdf-upload');
  const ring=await keyRing(generateBundle(account));
  await expect(uploadPDF(file([37,80,68,70,45,1,2]),{account,cursor:0,keys:{ring,deviceID:device}})).rejects.toMatchObject({code:'pdf_device_only'});
  expect(calls.post).not.toHaveBeenCalled();expect(calls.put).not.toHaveBeenCalled();expect(calls.rpc).not.toHaveBeenCalled();
 });
 it('rejects non-PDF and oversized input locally',async()=>{
  const {readPDF}=await import('../src/lib/pdf-upload');
  await expect(readPDF(file([1,2,3,4,5]))).rejects.toMatchObject({code:'invalid_upload'});
  await expect(readPDF(new Blob([new Uint8Array(67108865)]))).rejects.toMatchObject({code:'upload_too_large'});
  expect(calls.post).not.toHaveBeenCalled();
 });
});
