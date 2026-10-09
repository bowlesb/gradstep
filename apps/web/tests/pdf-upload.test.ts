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

describe('browser PDF upload protocol', () => {
  it('admits exact part hashes, uploads authenticated chunks, refreshes revision, and finalizes', async () => {
    const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const bytes = new Uint8Array(4_194_309).fill(7); bytes.set([37, 80, 68, 70, 45]);
    const source = file(bytes);
    calls.post.mockImplementation(async (_path: string, body: Record<string, unknown>) => {
      if (body.action === 'begin') return ticket(id, 1, false, null, [4_194_304, 5]);
      if (body.action === 'status') return ticket(id, 3, false, null, [4_194_304, 5]);
      if (body.action === 'finalize') return { format: 1, result: { status: 'applied' } };
      throw new Error('unexpected_post');
    });
    calls.put.mockResolvedValue({ verified: true, uncertain: false });
    const { uploadPDF } = await import('../src/lib/pdf-upload');
    const ring = await keyRing(generateBundle(account));
    const sessions: string[] = [], phases: string[] = [];
    const result = await uploadPDF(source, { account, cursor: 41, keys: { ring, deviceID: device }, uploadID: id, onSession: value => sessions.push(value), onProgress: p => phases.push(p.phase) });
    expect(result).toMatchObject({ uploadID: id, sourceID: `upload:${id}`, state: 'finalized' });
    expect(sessions).toEqual([id]);
    const begin = calls.post.mock.calls[0][1] as Record<string, unknown>;
    expect(begin).toMatchObject({ action: 'begin', upload_id: id, byte_count: 4_194_309, target: 'paper' });
    expect(begin).toHaveProperty('part_sha256');
    expect(begin).not.toHaveProperty('title');
    expect(begin).not.toHaveProperty('import_id');
    expect(calls.put).toHaveBeenCalledTimes(2);
    expect(calls.put.mock.calls[0][0]).toMatch(new RegExp(`^upload-pdf\\?upload_id=${id}&generation=1&part=0&attempt_id=[0-9a-f-]{36}$`));
    const finalize = calls.post.mock.calls.at(-1)![1] as Record<string, unknown>;
    expect(finalize).toEqual({ action: 'finalize', upload_id: id, generation: 1, revision: 3, observed_cursor: 41 });
    expect(phases).toContain('uploading');
  });

  it('seals a private descriptor before the first chunk and never sends the title to upload admission', async () => {
    const id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    calls.post.mockImplementation(async (_path: string, body: Record<string, unknown>) => {
      if (body.action === 'begin') return ticket(id, 1, true);
      if (body.action === 'status') return ticket(id, 3, true, { descriptor_id: device, revision: 1, epoch: 1, sha256: 'a'.repeat(64) });
      if (body.action === 'finalize') return { format: 1, result: { status: 'applied' } };
      throw new Error('unexpected_post');
    });
    calls.put.mockResolvedValue({ verified: true, uncertain: false });
    calls.rpc.mockResolvedValue({ format: 1, account_id: account, result: { status: 'applied' } });
    const { uploadPDF } = await import('../src/lib/pdf-upload');
    const ring = await keyRing(generateBundle(account));
    await uploadPDF(file([37, 80, 68, 70, 45, 9, 8, 7, 6, 5]), { account, cursor: 2, keys: { ring, deviceID: device }, uploadID: id });
    expect(calls.rpc).toHaveBeenCalledTimes(1);
    const descriptor = calls.rpc.mock.calls[0][1] as Record<string, unknown>;
    expect(descriptor).toMatchObject({ p_source_id: `upload:${id}`, p_expected_revision: 0, p_caller_device_id: device });
    expect(descriptor.p_management_token).toMatch(/^\\x[0-9a-f]{64}$/);
    expect(descriptor.p_envelope).toMatchObject({ format: 1, revision: 1 });
    expect((descriptor.p_envelope as Record<string, unknown>).ciphertext).not.toContain('Attention');
    expect(calls.post.mock.calls[0][1]).not.toHaveProperty('title');
    expect(calls.put).not.toHaveBeenCalled();
  });

  it('rejects non-PDF and over-limit input before server admission', async () => {
    const { uploadPDF } = await import('../src/lib/pdf-upload');
    const ring = await keyRing(generateBundle(account));
    await expect(uploadPDF(file([1, 2, 3, 4, 5]), { account, cursor: 0, keys: { ring, deviceID: device } })).rejects.toMatchObject({ code: 'invalid_upload' });
    expect(calls.post).not.toHaveBeenCalled();
  });
});
