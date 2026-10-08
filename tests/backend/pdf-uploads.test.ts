import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { PDFDocument } from 'pdf-lib';
import { handleUpload, handleUploadPart, writePdfChunkOnce, reconcilePdfUploads, sweepPdfUploads, type UploadDeps } from '../../supabase/functions/_shared/pdf-uploads.ts';
import { processPaper, readerAttribution, type PaperEntry, type PipelineDeps, type PipelinePolicy } from '../../supabase/functions/_shared/pipeline.ts';
import { sha256, PublicError } from '../../supabase/functions/_shared/http.ts';

const account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const uploadID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

function control(rpc: (name: string, params: Record<string, unknown>) => unknown) {
  const calls: { name: string; params: Record<string, unknown> }[] = [];
  const deps: UploadDeps = { async rpc<T>(name: string, params: Record<string, unknown>) { calls.push({ name, params }); return await rpc(name, params) as T; },
    async writeOnce() { throw new Error('unexpected physical write'); } };
  return { deps, calls };
}
const begin = { action: 'begin', upload_id: uploadID, sha256: 'ab'.repeat(32), byte_count: 1000, part_sha256: ['ab'.repeat(32)], target: 'paper' };

test('begin sends exact chunk digests and rejects plaintext titles and impossible part counts', async () => {
  const response = { protocol: 'upload-chunks-v1', state: 'receiving', upload_id: uploadID };
  const { deps, calls } = control(() => response);
  assert.deepEqual(await handleUpload(deps, account, begin), response);
  assert.deepEqual(calls[0].params.p_part_sha256, ['\\x' + 'ab'.repeat(32)]);
  assert.ok(!('p_title' in calls[0].params));
  for (const bad of [{ title: 'private' }, { byte_count: 4194305 }, { part_sha256: ['bad'] }, { import_id: uploadID }, { byte_count: 1.5 }])
    await assert.rejects(handleUpload(deps, account, { ...begin, ...bad }), (e: unknown) => e instanceof PublicError && e.status === 400);
  assert.equal(calls.length, 1);
});

test('finalize freezes before attachment, so an attach timeout can repeat the same identity', async () => {
  const receipt = { result: { status: 'applied' } }; let fail = true;
  const { deps, calls } = control(name => {
    if (name === 'worker_freeze_pdf_upload') return { state: 'frozen' };
    if (fail) throw new Error('lost acknowledgment');
    return receipt;
  });
  const body = { action: 'finalize', upload_id: uploadID, generation: 1, revision: 2, observed_cursor: 0 };
  await assert.rejects(handleUpload(deps, account, body), /service_unavailable/);
  fail = false; assert.deepEqual(await handleUpload(deps, account, body), receipt);
  assert.deepEqual(calls.map(c => c.name), ['worker_freeze_pdf_upload', 'worker_finalize_pdf_upload', 'worker_freeze_pdf_upload', 'worker_finalize_pdf_upload']);
  assert.deepEqual(calls[1], calls[3]);
});

function chunkRequest(bytes: Uint8Array, attempt = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', headers: Record<string, string> = {}) {
  return new Request(`https://fixture.invalid/upload-pdf?upload_id=${uploadID}&generation=1&part=0&attempt_id=${attempt}`,
    { method: 'PUT', headers: { 'Content-Type': 'application/octet-stream', ...headers }, body: new Uint8Array(bytes) });
}

test('chunk reads/hash-checks before the single-send grant, and replay never writes twice', async () => {
  const bytes = new Uint8Array([1, 2, 3]), digest = await sha256(bytes), events: string[] = []; let sent = false;
  const deps: UploadDeps = {
    async rpc<T>(name: string) {
      events.push(name);
      if (name === 'worker_pdf_upload_part') return { receive: !sent, verified: sent, bytes: 3, sha256: digest } as T;
      if (name === 'worker_pdf_upload_write') { sent = true; return { write: true, bucket: 'paper-uploads', path: `${account}/${uploadID}/0/cccccccc-cccc-4ccc-8ccc-cccccccccccc.chunk` } as T; }
      return undefined as T;
    }, async writeOnce(_path, got) { events.push('physical PUT'); assert.deepEqual(got, bytes); },
  };
  assert.deepEqual(await handleUploadPart(deps, account, chunkRequest(bytes)), { verified: true, uncertain: false });
  assert.deepEqual(events, ['worker_pdf_upload_part', 'worker_pdf_upload_write', 'physical PUT', 'worker_pdf_upload_written']);
  assert.deepEqual(await handleUploadPart(deps, account, chunkRequest(bytes)), { verified: true, uncertain: false });
  assert.equal(events.filter(x => x === 'physical PUT').length, 1);
});

test('wrong bodies never obtain a write grant, and a lost PUT outcome remains uncertain', async () => {
  const bytes = new Uint8Array([1, 2, 3]), digest = await sha256(bytes); let grants = 0, writes = 0, receipts = 0;
  const deps: UploadDeps = {
    async rpc<T>(name: string) {
      if (name === 'worker_pdf_upload_part') return { receive: true, bytes: 3, sha256: digest } as T;
      if (name === 'worker_pdf_upload_write') { grants++; return { write: true, bucket: 'paper-uploads', path: `${account}/${uploadID}/0/cccccccc-cccc-4ccc-8ccc-cccccccccccc.chunk` } as T; }
      receipts++; return undefined as T;
    }, async writeOnce() { writes++; throw new Error('lost PUT acknowledgment'); },
  };
  await assert.rejects(handleUploadPart(deps, account, chunkRequest(new Uint8Array([9, 9, 9]))), /upload_mismatch/);
  await assert.rejects(handleUploadPart(deps, account, chunkRequest(new Uint8Array([1, 2, 3, 4]))), /upload_too_large/);
  await assert.rejects(handleUploadPart(deps, account, chunkRequest(bytes, undefined, { 'Content-Encoding': 'gzip' })), /invalid_request/);
  assert.equal(grants, 0);
  assert.deepEqual(await handleUploadPart(deps, account, chunkRequest(bytes)), { verified: false, uncertain: true });
  assert.equal(grants, 1); assert.equal(writes, 1); assert.equal(receipts, 0);
});

test('raw Storage transport forbids redirect/retry/upsert and never returns its response body', async () => {
  let count = 0;
  await assert.rejects(writePdfChunkOnce('https://fixture.invalid', 'fixture-key', `${account}/${uploadID}/0/cccccccc-cccc-4ccc-8ccc-cccccccccccc.chunk`, new Uint8Array([1]),
    (async (_url, options) => { count++; assert.equal(options?.redirect, 'error'); assert.equal((options?.headers as Record<string, string>)['x-upsert'], 'false'); return new Response('conflict', { status: 409 }); }) as typeof fetch), /storage_upload_failed/);
  assert.equal(count, 1);
});

test('cleanup validates the complete exact batch before removal, and never confirms partial/malformed batches', async () => {
  const object = { id: randomUUID(), bucket: 'paper-uploads', path: `${account}/${uploadID}/0/${randomUUID()}.chunk` }, batch = randomUUID();
  const removed: string[][] = [], confirmed: unknown[] = [], logs: Record<string, unknown>[] = [];
  let malformed = false;
  const rpc = async <T>(name: string, parameters: Record<string, unknown>) => {
    if (name === 'worker_claim_stale_pdf_uploads') return [{ batch_id: batch, objects: [object, ...(malformed ? [{ ...object, id: randomUUID(), path: '../x' }] : [])] }] as T;
    confirmed.push(parameters); return 1 as T;
  };
  assert.equal(await sweepPdfUploads(rpc, async paths => { removed.push(paths); }, f => logs.push(f)), 1);
  assert.deepEqual(confirmed, [{ p_batch_id: batch }]);
  malformed = true; assert.equal(await sweepPdfUploads(rpc, async paths => { removed.push(paths); }, f => logs.push(f)), 0);
  assert.equal(removed.length, 1); assert.equal(confirmed.length, 1);
});

test('one failing deletion batch preserves its liability while later batches complete and report partial progress', async () => {
  const batches = [0, 1].map(index => ({ batch_id: randomUUID(), objects: [{ id: randomUUID(), bucket: 'paper-uploads', path: `${account}/${uploadID}/${index}/${randomUUID()}.chunk` }] }));
  const confirmed: unknown[] = [], logs: Record<string, unknown>[] = [];
  const rpc = async <T>(name: string, parameters: Record<string, unknown>) => {
    if (name === 'worker_claim_stale_pdf_uploads') return batches as T;
    confirmed.push(parameters); return 1 as T;
  };
  let attempted = 0;
  assert.equal(await sweepPdfUploads(rpc, async paths => {
    attempted++; if (paths[0] === batches[0].objects[0].path) throw new Error('storage_remove_failed');
  }, fields => logs.push(fields)), 1);
  assert.equal(attempted, 2); assert.deepEqual(confirmed, [{ p_batch_id: batches[1].batch_id }]);
  assert.ok(logs.some(value => value.event === 'pdf_upload_batch_sweep_failed'));
  assert.ok(logs.some(value => value.event === 'pdf_uploads_swept' && value.deleted === 1));
  assert.ok(!JSON.stringify(logs).includes(batches[0].objects[0].path));
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
function harness(responses: Record<string, (params: Record<string, unknown>) => unknown>, stored: Map<string, Uint8Array>, options: { transient?: boolean; declared?: { bytes: number; sha256: string } } = {}) {
  const calls: { name: string; params: Record<string, unknown> }[] = []; const originals = new Map<string, Uint8Array>(); const removed: string[] = [];
  const unexpected = async () => { throw new Error('unexpected'); };
  const deps: PipelineDeps = {
    async rpc<T>(name: string, params: Record<string, unknown>): Promise<T> {
      calls.push({ name, params });
      if (responses[name]) {
        const value = responses[name](params) as Record<string, unknown>;
        if (name === 'worker_pipeline_admit_download' && !('upload' in value)) {
          const bytes = [...stored.values()][0], declared = options.declared ?? (bytes ? { bytes: bytes.length, sha256: await sha256(bytes) } : null);
          return { ...value, upload: declared ? { id: uploadID, generation: 1, parts: Math.ceil(declared.bytes / 4_194_304), ...declared } : null } as T;
        }
        return value as T;
      }
      if (name === 'worker_pdf_upload_read') {
        const path = `${owner}/${uploadID}/0/66666666-6666-4666-8666-666666666666.chunk`;
        const bytes = stored.get(path), declared = options.declared ?? { bytes: bytes!.length, sha256: await sha256(bytes!) };
        return { read: true, objects: [{ index: 0, id: randomUUID(), bucket: 'paper-uploads', path, bytes: declared.bytes, sha256: declared.sha256 }] } as T;
      }
      if (name === 'worker_pipeline_asset_plan') return { upload_id: params.p_upload_id,
        objects: (params.p_objects as { path: string }[]).map(o => ({ id: randomUUID(), path: o.path, verified: false })) } as T;
      if (name === 'worker_pipeline_asset_write') return { write: true, verified: false } as T;
      return null as T;
    },
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
    render: unexpected, async sleep() {}, now: () => Date.parse('2026-10-05T06:00:00Z'), uuid: randomUUID,
    log() {}, resolveHost: async () => ['93.184.215.14'],
  };
  return { deps, calls, originals, removed };
}
const failure = (calls: { name: string; params: Record<string, unknown> }[]) => calls.find(c => c.name === 'worker_pipeline_defer')?.params;

test('an uploaded paper assembles admitted chunks and leaves cleanup to fenced batches', async () => {
  const bytes = await pdf(4); const digest = await sha256(bytes); const path = `${owner}/${uploadID}/0/66666666-6666-4666-8666-666666666666.chunk`;
  const upload = { id: uploadID, generation: 1, parts: 1, sha256: digest, bytes: bytes.length };
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
  assert.deepEqual(removed, []);
  assert.ok(!calls.some(c => c.name === 'worker_confirm_pdf_uploads_deleted'));
  assert.equal(calls.find(c => c.name === 'worker_pdf_upload_read_observed')?.params.p_bytes, bytes.length);
  assert.ok(!failure(calls)?.p_fail);
});

test('a web paper a reader supplied uses their upload and never fetches its locations', async () => {
  const bytes = await pdf(2); const digest = await sha256(bytes); const path = `${owner}/${uploadID}/0/66666666-6666-4666-8666-666666666666.chunk`;
  const { deps, calls } = harness({
    worker_pipeline_admit_download: () => ({ admitted: true }),
    worker_pipeline_upload_original: () => entry('ocr_fund', { source_kind: 'web', source_id: 'openalex:W1', document_sha256: digest, page_count: 2 }),
    worker_pipeline_fund: () => ({ ...entry('ocr_fund'), funding: 'paused' }),
  }, new Map([[path, bytes]]));
  await processPaper(deps, entry('download', { source_id: 'openalex:W1', source_kind: 'web', pdf_urls: ['https://blocked.example.org/a.pdf'],
    upload: { id: uploadID, generation: 1, parts: 1, sha256: digest, bytes: bytes.length } }), policy, deadline);
  assert.ok(calls.some(c => c.name === 'worker_pipeline_upload_original'));
  assert.ok(!failure(calls)?.p_fail);
});

test('bytes that are not what was declared, or not a readable PDF, spend the upload and fail the paper resumably', async () => {
  const bytes = await pdf(2); const digest = await sha256(bytes); const path = `${owner}/${uploadID}/0/66666666-6666-4666-8666-666666666666.chunk`;
  const upload = { id: uploadID, generation: 1, parts: 1, sha256: digest, bytes: bytes.length };
  const cases: [string, Map<string, Uint8Array>, typeof upload, string][] = [
    ['different bytes', new Map([[path, new Uint8Array(bytes.length).fill(7)]]), upload, 'upload_failed'],
    ['missing object', new Map(), upload, 'upload_failed'],
    ['larger than declared', new Map([[path, new Uint8Array(bytes.length + 10)]]), upload, 'upload_failed'],
    ['not a PDF', new Map([[path, new TextEncoder().encode('<html>not a pdf</html>')]]), { ...upload, sha256: await sha256(new TextEncoder().encode('<html>not a pdf</html>')), bytes: 22 }, 'pdf_invalid'],
  ];
  for (const [name, stored, declared, code] of cases) {
    const { deps, calls, originals } = harness({ worker_pipeline_admit_download: () => ({ admitted: true }) }, stored, { declared });
    await processPaper(deps, entry('download', { upload: declared }), policy, deadline);
    assert.deepEqual(calls.find(c => c.name === 'worker_pipeline_upload_rejected')?.params.p_upload_id, uploadID, name);
    assert.equal(failure(calls)?.p_fail, true, name); assert.equal(failure(calls)?.p_error_code, code, name);
    assert.equal(failure(calls)?.p_resume_stage, 'download', name);
    assert.equal(originals.size, 0, name);
  }
  // A Storage outage is not the reader's fault: retried, the upload kept.
  const outage = harness({ worker_pipeline_admit_download: () => ({ admitted: true }) }, new Map(), { transient: true, declared: upload });
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

test('reconciliation charges a new read, settles matching bytes only, and never treats absence as not-written', async () => {
  const bytes = new Uint8Array([1, 2, 3]), digest = await sha256(bytes), attempt = randomUUID();
  for (const outcome of ['matching', 'missing', 'mismatch']) {
    const calls: { name: string; params: Record<string, unknown> }[] = [];
    const rpc = async <T>(name: string, params: Record<string, unknown>) => {
      calls.push({ name, params });
      if (name === 'worker_pdf_upload_reconciliation') return [{ attempt_id: attempt, upload_id: uploadID, generation: 1 }] as T;
      if (name === 'worker_pdf_upload_read') return { read: true, objects: [{ bucket: 'paper-uploads', path: `${account}/${uploadID}/0/${attempt}.chunk`, bytes: 3, sha256: digest }] } as T;
      return null as T;
    };
    const recovered = await reconcilePdfUploads(rpc, async () => {
      if (outcome === 'missing') throw new Error('404');
      return outcome === 'matching' ? bytes : new Uint8Array([9, 9, 9]);
    }, () => {});
    assert.equal(recovered, outcome === 'matching' ? 1 : 0);
    assert.ok(calls.some(c => c.name === 'worker_pdf_upload_read_observed'));
    const terminal = calls.find(c => c.name === 'worker_pdf_upload_written');
    assert.equal(!!terminal, outcome === 'matching');
    if (terminal) assert.equal(terminal.params.p_evidence, 'matching_object');
    assert.ok(!calls.some(c => c.params.p_verified === false || c.name.includes('delete')));
  }
});

test('an exhausted candidate allowance does not prevent another account from recovering its PUT', async () => {
  const bytes = new Uint8Array([1, 2, 3]), digest = await sha256(bytes);
  const blocked = randomUUID(), eligible = randomUUID(), otherUpload = randomUUID();
  const calls: { name: string; params: Record<string, unknown> }[] = [], logs: Record<string, unknown>[] = [];
  const rpc = async <T>(name: string, params: Record<string, unknown>) => {
    calls.push({ name, params });
    if (name === 'worker_pdf_upload_reconciliation') return [
      { attempt_id: blocked, upload_id: uploadID, generation: 1 },
      { attempt_id: eligible, upload_id: otherUpload, generation: 1 },
    ] as T;
    if (name === 'worker_pdf_upload_read') {
      if (params.p_attempt_id === blocked) throw new Error('reader_transfer_limit');
      return { read: true, objects: [{ bucket: 'paper-uploads', path: `${account}/${otherUpload}/0/${eligible}.chunk`, bytes: 3, sha256: digest }] } as T;
    }
    return null as T;
  };
  assert.equal(await reconcilePdfUploads(rpc, async () => bytes, value => logs.push(value)), 1);
  assert.equal(calls.find(c => c.name === 'worker_pdf_upload_written')?.params.p_attempt_id, eligible);
  assert.ok(!calls.some(c => c.name === 'worker_pdf_upload_written' && c.params.p_attempt_id === blocked));
  assert.ok(logs.some(v => v.event === 'pdf_upload_reconciliation_candidate_failed'));
  assert.ok(!JSON.stringify(logs).includes(blocked));
});

test('multi-chunk assembly accounts for a successful first GET and a partial second failure', async () => {
  const base = await pdf(2), bytes = new Uint8Array(4_194_304 + base.length);
  bytes.set(base); const digest = await sha256(bytes), pieces = [bytes.slice(0, 4_194_304), bytes.slice(4_194_304)];
  const paths = pieces.map((_, index) => `${owner}/${uploadID}/${index}/${randomUUID()}.chunk`);
  const objects = await Promise.all(pieces.map(async (part, index) => ({ index, id: randomUUID(), bucket: 'paper-uploads', path: paths[index], bytes: part.length, sha256: await sha256(part) })));
  const { deps, calls, originals } = harness({ worker_pipeline_admit_download: () => ({ admitted: true, upload: { id: uploadID, generation: 1, parts: 2, bytes: bytes.length, sha256: digest } }), worker_pdf_upload_read: () => ({ read: true, objects }) }, new Map());
  let requests = 0;
  deps.uploads!.download = async (path, maximum, observed) => {
    requests++;
    if (path === paths[0]) { assert.equal(maximum, 4_194_304); observed?.(maximum); return pieces[0]; }
    observed?.(7); throw new Error('storage_download_failed');
  };
  await processPaper(deps, entry('download', { upload: { id: uploadID, generation: 1, parts: 2, bytes: bytes.length, sha256: digest } }), policy, deadline);
  assert.equal(requests, 2); assert.equal(originals.size, 0);
  assert.equal(calls.find(c => c.name === 'worker_pdf_upload_read_observed')?.params.p_bytes, 4_194_304 + 7);
  assert.ok(!calls.some(c => c.name === 'worker_pipeline_upload_rejected'));
});


test('a supplied PDF attached after the claim snapshot drives the admitted download instead of stale web locations', async () => {
  const bytes = await pdf(2), digest = await sha256(bytes), path = `${owner}/${uploadID}/0/66666666-6666-4666-8666-666666666666.chunk`;
  const supplied = { id: uploadID, generation: 1, parts: 1, bytes: bytes.length, sha256: digest };
  const { deps, calls, originals } = harness({
    worker_pipeline_admit_download: () => ({ admitted: true, upload: supplied }),
    worker_pipeline_upload_original: () => entry('ocr_fund', { document_sha256: digest, page_count: 2 }),
    worker_pipeline_fund: () => ({ ...entry('ocr_fund'), funding: 'paused' }),
  }, new Map([[path, bytes]]));
  // deps.fetch throws: any use of this stale web source would fail the journey.
  await processPaper(deps, entry('download', { source_kind: 'web', source_id: 'openalex:W3901', upload: null,
    pdf_urls: ['https://public.example/old.pdf'] }), policy, deadline);
  assert.equal(originals.size, 1);
  assert.ok(calls.some(c => c.name === 'worker_pipeline_upload_original'));
  assert.ok(!calls.some(c => c.name === 'worker_pipeline_original'));
  assert.ok(!failure(calls));
});
