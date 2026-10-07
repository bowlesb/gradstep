import test from 'node:test';
import assert from 'node:assert/strict';
import { PDFDocument } from 'pdf-lib';
import { handleUpload, sweepPdfUploads, uploadError, type UploadDeps } from '../../supabase/functions/_shared/pdf-uploads.ts';
import { processPaper, readerAttribution, type PaperEntry, type PipelineDeps, type PipelinePolicy } from '../../supabase/functions/_shared/pipeline.ts';
import { sha256, PublicError } from '../../supabase/functions/_shared/http.ts';

const account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const uploadID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

function uploadDeps(rpc: (name: string, params: Record<string, unknown>) => unknown, size: number | null = 1000) {
  const calls: { name: string; params: Record<string, unknown> }[] = []; const signed: string[] = []; const sized: string[] = [];
  const deps: UploadDeps = {
    async rpc<T>(name: string, params: Record<string, unknown>) { calls.push({ name, params }); return await rpc(name, params) as T; },
    async signUpload(path) { signed.push(path); return 'signed-token'; },
    async objectSize(path) { sized.push(path); return size; },
  };
  return { deps, calls, signed, sized };
}
const session = (state: string) => ({ id: uploadID, bucket: 'paper-uploads', path: `${account}/${uploadID}.pdf`, state, byte_count: 1000, expires_at: '2026-10-08T00:00:00Z', result: null });

test('begin: the database decides; a pending session gets a signed upload token for its own path', async () => {
  const { deps, calls, signed } = uploadDeps(() => session('pending'));
  const begun = await handleUpload(deps, account, { action: 'begin', upload_id: uploadID.toUpperCase(), sha256: 'AB'.repeat(32), byte_count: 1000,
    target: 'paper', title: 'A workshop draft', source_id: 'openalex:W1', import_id: uploadID, expected_revision: 3 });
  assert.deepEqual(begun, { upload_id: uploadID, state: 'pending', bucket: 'paper-uploads', path: `${account}/${uploadID}.pdf`, token: 'signed-token', expires_at: '2026-10-08T00:00:00Z' });
  assert.deepEqual(signed, [`${account}/${uploadID}.pdf`]);
  assert.deepEqual(calls[0], { name: 'worker_begin_pdf_upload', params: { p_account_id: account, p_upload_id: uploadID, p_sha256: '\\x' + 'ab'.repeat(32),
    p_byte_count: 1000, p_target: 'paper', p_import_id: null, p_expected_revision: null, p_source_id: null, p_title: 'A workshop draft' } }, 'only the target\'s own fields are sent');
  // Attaching to a failed import, and to a closed web paper.
  await handleUpload(deps, account, { action: 'begin', upload_id: uploadID, sha256: 'ab'.repeat(32), byte_count: 1000, target: 'import', import_id: uploadID, expected_revision: 3, title: 'ignored' });
  assert.equal(calls[1].params.p_import_id, uploadID); assert.equal(calls[1].params.p_expected_revision, 3); assert.equal(calls[1].params.p_title, null);
  await handleUpload(deps, account, { action: 'begin', upload_id: uploadID, sha256: 'ab'.repeat(32), byte_count: 1000, target: 'source', source_id: 'openalex:W2963403868' });
  assert.equal(calls[2].params.p_source_id, 'openalex:W2963403868');

  // Already finalized: no new token; the client finalizes again (a replay).
  const done = uploadDeps(() => session('finalized'));
  assert.equal((await handleUpload(done.deps, account, { action: 'begin', upload_id: uploadID, sha256: 'ab'.repeat(32), byte_count: 1000, target: 'paper', title: 'x' })).token, null);
  assert.deepEqual(done.signed, []);

  for (const bad of [{ upload_id: 'nope' }, { sha256: 'ab' }, { byte_count: 0 }, { byte_count: 1.5 }, { target: 'elsewhere' }]) {
    await assert.rejects(handleUpload(deps, account, { action: 'begin', upload_id: uploadID, sha256: 'ab'.repeat(32), byte_count: 1000, target: 'paper', title: 'x', ...bad }),
      (error: unknown) => error instanceof PublicError && error.status === 400);
  }
  await assert.rejects(handleUpload(deps, account, { action: 'delete', upload_id: uploadID }), (error: unknown) => error instanceof PublicError && error.code === 'invalid_request');
});

test('begin refusals the reader can act on are exposed; anything else is a 503', async () => {
  const cases: [string, number, string][] = [['upload_quota', 409, 'upload_quota'], ['insufficient_credits', 402, 'insufficient_credits'],
    ['upload_too_large', 413, 'upload_too_large'], ['upload_limit', 429, 'upload_limit'], ['request_rate_limit', 429, 'rate_limited'],
    ['upload_target_unavailable', 409, 'upload_target_unavailable'], ['some internal detail', 503, 'service_unavailable']];
  for (const [message, status, code] of cases) {
    const { deps } = uploadDeps(() => { throw new Error(message); });
    await assert.rejects(handleUpload(deps, account, { action: 'begin', upload_id: uploadID, sha256: 'ab'.repeat(32), byte_count: 1000, target: 'paper', title: 'x' }),
      (error: unknown) => error instanceof PublicError && error.status === status && error.code === code, message);
  }
  assert.equal(uploadError(new PublicError(401, 'authentication_required')).status, 401);
});

test('finalize passes the size Storage holds for the session\'s fixed path; a missing object is null', async () => {
  const receipt = { result: { status: 'applied', kind: 'import', id: uploadID }, replayed: false, entry: { source: 'upload' } };
  const { deps, calls, sized } = uploadDeps(() => receipt, 1000);
  assert.deepEqual(await handleUpload(deps, account, { action: 'finalize', upload_id: uploadID, observed_cursor: 42 }), receipt);
  assert.deepEqual(sized, [`${account}/${uploadID}.pdf`]);
  assert.deepEqual(calls[0], { name: 'worker_finalize_pdf_upload', params: { p_account_id: account, p_upload_id: uploadID, p_observed_cursor: 42, p_stored_bytes: 1000 } });
  const missing = uploadDeps(() => { throw new Error('upload_incomplete'); }, null);
  await assert.rejects(handleUpload(missing.deps, account, { action: 'finalize', upload_id: uploadID, observed_cursor: 0 }),
    (error: unknown) => error instanceof PublicError && error.status === 409 && error.code === 'upload_incomplete');
  assert.equal(missing.calls[0].params.p_stored_bytes, null);
  await assert.rejects(handleUpload(deps, account, { action: 'finalize', upload_id: uploadID, observed_cursor: -1 }), (error: unknown) => error instanceof PublicError && error.status === 400);
});

test('the sweep deletes claimed upload objects and records it; failures are logged, never thrown', async () => {
  const removed: string[][] = []; const logs: Record<string, unknown>[] = []; const confirmed: unknown[] = [];
  const objects = [{ id: '1', bucket: 'paper-uploads', path: `${account}/${uploadID}.pdf` }, { id: '2', bucket: 'paper-assets', path: 'originals/x.pdf' },
    { id: '3', bucket: 'paper-uploads', path: '../escape.pdf' }];
  const rpc = async <T>(name: string, params: Record<string, unknown>) => {
    if (name === 'worker_claim_stale_pdf_uploads') return objects as T;
    confirmed.push(params.p_object_ids); return 1 as T;
  };
  assert.equal(await sweepPdfUploads(rpc, async paths => { removed.push(paths); }, f => logs.push(f)), 1);
  assert.deepEqual(removed, [[`${account}/${uploadID}.pdf`]], 'only upload objects at upload paths');
  assert.deepEqual(confirmed, [['1']]);
  assert.equal(await sweepPdfUploads(rpc, async () => { throw new Error('storage down'); }, f => logs.push(f)), 0);
  assert.equal(logs.at(-1)?.event, 'pdf_upload_sweep_failed');
});

async function pdf(pages = 3): Promise<Uint8Array> {
  const document = await PDFDocument.create();
  for (let i = 0; i < pages; i++) document.addPage([200, 200]);
  return document.save();
}
const policy: PipelinePolicy = { enabled: true, max_pdf_bytes: 64 * 1024 * 1024, max_ocr_pages: 80, renderer_version: 'timestep-mathpix-mathml-v1' };
const deadline = Date.parse('2026-10-05T06:05:00Z');
const owner = '55555555-5555-4555-8555-555555555555';
function entry(stage: string, extra: Partial<PaperEntry> = {}): PaperEntry {
  return { id: '11111111-1111-4111-8111-111111111111', source_id: `upload:${uploadID}`, source_kind: 'upload', requested_revision: 0, revision: 1, stage, owner_id: owner,
    generation: 7, claim_id: '22222222-2222-4222-8222-222222222222', state_revision: 3, failures: 0, document_id: null, document_sha256: null,
    original_path: null, original_bytes: null, page_count: null, attempt: null, ...extra };
}
function harness(responses: Record<string, (params: Record<string, unknown>) => unknown>, stored: Map<string, Uint8Array>, options: { transient?: boolean } = {}) {
  const calls: { name: string; params: Record<string, unknown> }[] = []; const originals = new Map<string, Uint8Array>(); const removed: string[] = [];
  const unexpected = async () => { throw new Error('unexpected'); };
  const deps: PipelineDeps = {
    async rpc<T>(name: string, params: Record<string, unknown>): Promise<T> { calls.push({ name, params }); return (responses[name]?.(params) ?? null) as T; },
    storage: { async upload(path, bytes) { originals.set(path, bytes); }, download: unexpected, signedURL: unexpected },
    uploads: {
      async download(path, maximum) {
        if (options.transient) throw new Error('storage_download_failed');
        const bytes = stored.get(path); if (!bytes) throw new Error('storage_object_missing');
        if (bytes.length > maximum) throw new Error('storage_object_too_large');
        return bytes;
      },
      async remove(paths) { removed.push(...paths); },
    },
    fetch: (async () => { throw new Error('no fetch for an upload'); }) as unknown as typeof fetch,
    mathpix: { submitOnce: unexpected, submitURL: unexpected, status: unexpected, conversion: unexpected, output: unexpected },
    render: unexpected, async sleep() {}, now: () => Date.parse('2026-10-05T06:00:00Z'), uuid: () => '33333333-3333-4333-8333-333333333333',
    log() {}, resolveHost: async () => ['93.184.215.14'],
  };
  return { deps, calls, originals, removed };
}
const failure = (calls: { name: string; params: Record<string, unknown> }[]) => calls.find(c => c.name === 'worker_pipeline_defer')?.params;

test('an uploaded paper: verified bytes become the private original, the upload is spent and deleted', async () => {
  const bytes = await pdf(4); const digest = await sha256(bytes); const path = `${owner}/${uploadID}.pdf`;
  const upload = { id: uploadID, object_id: '66666666-6666-4666-8666-666666666666', path, sha256: digest, bytes: bytes.length };
  const { deps, calls, originals, removed } = harness({
    worker_pipeline_admit_download: () => ({ admitted: true }),
    worker_pipeline_upload_original: p => {
      assert.equal(p.p_upload_id, uploadID); assert.equal(p.p_sha256, '\\x' + digest); assert.equal(p.p_pages, 4);
      assert.equal(p.p_path, `private/${owner}/originals/${digest}.pdf`);
      return entry('ocr_fund', { document_sha256: digest, page_count: 4 });
    },
    worker_pipeline_fund: () => ({ ...entry('ocr_fund'), funding: 'paused' }),
  }, new Map([[path, bytes]]));
  await processPaper(deps, entry('download', { upload }), policy, deadline);
  assert.ok(originals.has(`private/${owner}/originals/${digest}.pdf`), 'stored as the owner-private original');
  assert.ok(!calls.some(c => c.name === 'worker_pipeline_original' || c.name === 'worker_pipeline_arxiv_slot'));
  assert.deepEqual(removed, [path]);
  assert.deepEqual(calls.find(c => c.name === 'worker_confirm_pdf_uploads_deleted')?.params.p_object_ids, [upload.object_id]);
  assert.ok(!failure(calls)?.p_fail);
});

test('a web paper a reader supplied uses their upload and never fetches its locations', async () => {
  const bytes = await pdf(2); const digest = await sha256(bytes); const path = `${owner}/${uploadID}.pdf`;
  const { deps, calls } = harness({
    worker_pipeline_admit_download: () => ({ admitted: true }),
    worker_pipeline_upload_original: () => entry('ocr_fund', { source_kind: 'web', source_id: 'openalex:W1', document_sha256: digest, page_count: 2 }),
    worker_pipeline_fund: () => ({ ...entry('ocr_fund'), funding: 'paused' }),
  }, new Map([[path, bytes]]));
  await processPaper(deps, entry('download', { source_id: 'openalex:W1', source_kind: 'web', pdf_urls: ['https://blocked.example.org/a.pdf'],
    upload: { id: uploadID, object_id: '6', path, sha256: digest, bytes: bytes.length } }), policy, deadline);
  assert.ok(calls.some(c => c.name === 'worker_pipeline_upload_original'));
  assert.ok(!failure(calls)?.p_fail);
});

test('bytes that are not what was declared, or not a readable PDF, spend the upload and fail the paper resumably', async () => {
  const bytes = await pdf(2); const digest = await sha256(bytes); const path = `${owner}/${uploadID}.pdf`;
  const upload = { id: uploadID, object_id: '6', path, sha256: digest, bytes: bytes.length };
  const cases: [string, Map<string, Uint8Array>, typeof upload, string][] = [
    ['different bytes', new Map([[path, new Uint8Array(bytes.length).fill(7)]]), upload, 'upload_failed'],
    ['missing object', new Map(), upload, 'upload_failed'],
    ['larger than declared', new Map([[path, new Uint8Array(bytes.length + 10)]]), upload, 'upload_failed'],
    ['not a PDF', new Map([[path, new TextEncoder().encode('<html>not a pdf</html>')]]), { ...upload, sha256: await sha256(new TextEncoder().encode('<html>not a pdf</html>')), bytes: 22 }, 'pdf_invalid'],
  ];
  for (const [name, stored, declared, code] of cases) {
    const { deps, calls, originals } = harness({ worker_pipeline_admit_download: () => ({ admitted: true }) }, stored);
    await processPaper(deps, entry('download', { upload: declared }), policy, deadline);
    assert.deepEqual(calls.find(c => c.name === 'worker_pipeline_upload_rejected')?.params.p_upload_id, uploadID, name);
    assert.equal(failure(calls)?.p_fail, true, name); assert.equal(failure(calls)?.p_error_code, code, name);
    assert.equal(failure(calls)?.p_resume_stage, 'download', name);
    assert.equal(originals.size, 0, name);
  }
  // A Storage outage is not the reader's fault: retried, the upload kept.
  const outage = harness({ worker_pipeline_admit_download: () => ({ admitted: true }) }, new Map(), { transient: true });
  await processPaper(outage.deps, entry('download', { upload }), policy, deadline);
  assert.ok(!outage.calls.some(c => c.name === 'worker_pipeline_upload_rejected'));
  assert.equal(failure(outage.calls)?.p_fail, false);
  // An uploaded paper whose upload is gone waits for a new one.
  const gone = harness({ worker_pipeline_admit_download: () => ({ admitted: true }) }, new Map());
  await processPaper(gone.deps, entry('download', { upload: null }), policy, deadline);
  assert.equal(failure(gone.calls)?.p_error_code, 'upload_failed');
});

test('an uploaded paper\'s reader credits its reader, with no original link; others unchanged', () => {
  assert.equal(readerAttribution(entry('render', { title: 'A workshop draft' })),
    '"A workshop draft" uploaded by its reader. Converted for the personal use of one Gradstep account; not redistributed.');
  assert.ok(!readerAttribution(entry('render', { title: null })).includes('Original:'));
  assert.throws(() => readerAttribution(entry('render', { owner_id: null })), /render_failed/);
  assert.equal(readerAttribution(entry('render', { source_id: 'openalex:W1', source_kind: 'web', title: 'T', landing_url: 'https://doi.org/10.1/x' })),
    '"T". Converted for the personal use of one Gradstep account; not redistributed. Original: https://doi.org/10.1/x');
  assert.ok(readerAttribution(entry('render', { source_id: '2305.18290', source_kind: 'arxiv', owner_id: null, title: 'DPO', license_uri: 'https://creativecommons.org/licenses/by/4.0/' }))
    .startsWith('"DPO", arXiv:2305.18290v1. Licensed under https://creativecommons.org/licenses/by/4.0/.'));
});
