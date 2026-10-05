import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { PDFDocument } from 'pdf-lib';
import { contentType, countPages, fetchArxiv, loadRaw, PermanentFailure, PipelineRPCError, processPaper, RAW_FORMAT,
  type PaperEntry, type PipelineDeps, type PipelinePolicy } from '../../supabase/functions/_shared/pipeline.ts';
import { sha256 } from '../../supabase/functions/_shared/http.ts';

const fixtures = new URL('../fixtures/arxiv/', import.meta.url);
const atom = readFileSync(new URL('2305.18290-atom.xml', fixtures));
const oai = readFileSync(new URL('2305.18290-oai.xml', fixtures));
const policy: PipelinePolicy = { enabled: true, max_pdf_bytes: 64 * 1024 * 1024, max_ocr_pages: 80, renderer_version: 'timestep-mathpix-mathml-v1' };

async function pdf(pages = 3): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  for (let i = 0; i < pages; i++) doc.addPage();
  return doc.save();
}

function entry(stage: string, extra: Partial<PaperEntry> = {}): PaperEntry {
  return { id: '11111111-1111-4111-8111-111111111111', source_id: '2305.18290', requested_revision: 0, revision: 3, stage, generation: 7,
    claim_id: '22222222-2222-4222-8222-222222222222', state_revision: 3, failures: 0, document_id: null, document_sha256: null,
    original_path: null, original_bytes: null, page_count: null, attempt: null, ...extra };
}

type Call = { name: string; params: Record<string, unknown> };
function harness(responses: Record<string, (params: Record<string, unknown>) => unknown>, extra: Partial<PipelineDeps> = {}) {
  const calls: Call[] = []; const uploads = new Map<string, Uint8Array>(); const logs: string[] = [];
  const deps: PipelineDeps = {
    async rpc<T>(name: string, params: Record<string, unknown>): Promise<T> {
      calls.push({ name, params });
      const handler = responses[name];
      if (!handler) return null as T;
      return handler(params) as T;
    },
    storage: {
      async upload(path, bytes) { uploads.set(path, new Uint8Array(bytes)); },
      async download(path) { const b = uploads.get(path); if (!b) throw new Error('storage_download_failed'); return b; },
      async signedURL(path) { return `https://example.supabase.co/storage/v1/object/sign/paper-assets/${path}?token=t`; },
    },
    fetch: (async () => { throw new Error('unexpected fetch'); }) as typeof fetch,
    mathpix: {
      async submitOnce() { throw new Error('unexpected submit'); }, async submitURL() { throw new Error('unexpected submit'); },
      async status() { throw new Error('unexpected status'); }, async conversion() { throw new Error('unexpected conversion'); },
      async output() { throw new Error('unexpected output'); },
    },
    async render() { throw new Error('unexpected render'); },
    async sleep() {}, now: () => Date.parse('2026-10-05T06:00:00Z'), uuid: () => '33333333-3333-4333-8333-333333333333',
    log: event => { logs.push(event); }, ...extra,
  };
  return { deps, calls, uploads, logs };
}
const names = (calls: Call[]) => calls.map(c => c.name);
const deadline = Date.parse('2026-10-05T06:05:00Z');

test('content types and page counting', async () => {
  assert.equal(contentType('reader/x/index.html'), 'text/html; charset=utf-8');
  assert.equal(contentType('assets/a.jpg'), 'image/jpeg');
  assert.equal(await countPages(await pdf(4)), 4);
  await assert.rejects(countPages(new TextEncoder().encode('<html>not a pdf</html>')), (e: unknown) => e instanceof PermanentFailure && e.code === 'pdf_invalid');
  const real = '/Users/benbowlwes/science-reader/.artifacts/spike-2305.18290/original.pdf';
  if (existsSync(real)) assert.equal(await countPages(new Uint8Array(readFileSync(real))), 27);
});

test('arXiv fetch is bounded, host-restricted and follows only same-site redirects', async () => {
  const seen: string[] = [];
  const fetcher = (async (url: string) => {
    seen.push(url);
    if (url.endsWith('/redirect')) return new Response(null, { status: 302, headers: { location: 'https://arxiv.org/pdf/2305.18290v3' } });
    if (url.endsWith('/evil')) return new Response(null, { status: 302, headers: { location: 'https://evil.example/pdf' } });
    if (url.endsWith('/big')) return new Response(new Uint8Array(20), { headers: { 'content-length': '20' } });
    return new Response(new Uint8Array([1, 2, 3]));
  }) as unknown as typeof fetch;
  assert.deepEqual([...await fetchArxiv(fetcher, 'https://arxiv.org/redirect', 10, '*/*')], [1, 2, 3]);
  await assert.rejects(fetchArxiv(fetcher, 'https://arxiv.org/evil', 10, '*/*'), (e: unknown) => e instanceof PermanentFailure);
  await assert.rejects(fetchArxiv(fetcher, 'https://arxiv.org/big', 10, '*/*'), (e: unknown) => e instanceof PermanentFailure && e.code === 'too_large');
  await assert.rejects(fetchArxiv(fetcher, 'https://example.com/x', 10, '*/*'), (e: unknown) => e instanceof PermanentFailure);
});

test('metadata → download → fund → submit in one claim, then sync and release', async () => {
  const original = await pdf(27);
  const digest = await sha256(original);
  const posted: unknown[] = [];
  const { deps, calls, uploads } = harness({
    worker_pipeline_arxiv_slot: () => ({ reserved: true, wait_ms: 0, spacing_ms: 3000 }),
    worker_pipeline_admit_download: () => ({ admitted: true }),
    worker_pipeline_metadata: p => { assert.equal(p.p_eligible, true); assert.equal(p.p_revision, 3);
      assert.equal((p.p_metadata as { title: string }).title.startsWith('Direct Preference Optimization'), true);
      assert.equal(p.p_license_uri, 'https://creativecommons.org/licenses/by/4.0/'); return entry('download'); },
    worker_pipeline_original: p => { assert.equal(p.p_path, `originals/${digest}.pdf`); assert.equal(p.p_pages, 27);
      return entry('ocr_fund', { document_sha256: digest, page_count: 27, original_path: p.p_path as string, original_bytes: original.length }); },
    worker_pipeline_fund: p => { assert.equal(p.p_page_limit, 27); return { ...entry('ocr_submit', { document_sha256: digest, page_count: 27,
      original_path: `originals/${digest}.pdf`, original_bytes: original.length,
      attempt: { id: 'a', state: 'funded', page_limit: 27, provider_job_id: null, submitted_at: null, raw_manifest_path: null } }), funding: 'funded' }; },
    worker_pipeline_begin_submit: () => ({ ...entry('ocr_submit'), granted: true, attempt_id: '44444444-4444-4444-8444-444444444444' }),
    worker_pipeline_submitted: p => { assert.equal(p.p_provider_job_id, 'job-1'); return entry('ocr_wait'); },
  }, {
    fetch: (async (url: string) => new Response(url.includes('export.arxiv.org') ? atom : url.includes('oaipmh') ? oai : original)) as unknown as typeof fetch,
    mathpix: { ...harness({}).deps.mathpix, async submitOnce(bytes, checkpoint) { posted.push(checkpoint); assert.equal(await sha256(bytes), digest); return { state: 'accepted', providerJobID: 'job-1' }; } },
  });
  await processPaper(deps, entry('metadata', { revision: null }), policy, deadline);
  assert.deepEqual(names(calls).filter(n => n !== 'worker_pipeline_arxiv_slot'), ['worker_pipeline_metadata', 'worker_pipeline_admit_download', 'worker_pipeline_original', 'worker_pipeline_fund',
    'worker_pipeline_begin_submit', 'worker_pipeline_submitted', 'worker_pipeline_sync_imports', 'worker_pipeline_release']);
  assert.equal(posted.length, 1);
  assert.ok(uploads.has(`originals/${digest}.pdf`));
});

test('a refused grant never posts; a failed POST is recorded as uncertain', async () => {
  const base = { worker_pipeline_begin_submit: () => ({ ...entry('ocr_uncertain'), granted: false }) };
  const prepared = entry('ocr_submit', { document_sha256: 'x'.repeat(64), original_path: 'originals/x.pdf', original_bytes: 9 * 1024 * 1024, page_count: 10,
    attempt: { id: 'a', state: 'submitting', page_limit: 10, provider_job_id: null, submitted_at: null, raw_manifest_path: null } });
  const refused = harness(base);
  await processPaper(refused.deps, prepared, policy, deadline);
  assert.ok(!names(refused.calls).includes('worker_pipeline_submitted'));
  const flaky = harness({ worker_pipeline_begin_submit: () => ({ ...entry('ocr_submit'), granted: true, attempt_id: '44444444-4444-4444-8444-444444444444' }),
    worker_pipeline_submitted: p => { assert.equal(p.p_provider_job_id, null); assert.equal(p.p_uncertain_reason, 'provider_transport_failed'); return entry('ocr_uncertain'); } }, {
    mathpix: { ...harness({}).deps.mathpix, async submitURL(url) { assert.match(url, /^https:\/\/example\.supabase\.co\//); throw new Error('socket hang up'); } },
  });
  await processPaper(flaky.deps, prepared, policy, deadline);
  assert.ok(names(flaky.calls).includes('worker_pipeline_submitted'));
});

test('polling defers until complete, then captures raw output and settles on processed pages', async () => {
  const waiting = entry('ocr_wait', { document_sha256: 'd'.repeat(64), page_count: 30,
    attempt: { id: 'a', state: 'submitted', page_limit: 30, provider_job_id: 'job-9', submitted_at: '2026-10-05T05:59:50Z', raw_manifest_path: null } });
  const pending = harness({ worker_pipeline_defer: p => { assert.equal(p.p_seconds, 4); return entry('ocr_wait'); } }, {
    mathpix: { ...harness({}).deps.mathpix, async status(id) { return { providerJobID: id, state: 'split', pages: 30, completedPages: 3, pipelineVersion: null, deleted: false, errorCode: null }; } } });
  await processPaper(pending.deps, waiting, policy, deadline);
  assert.deepEqual(names(pending.calls), ['worker_pipeline_heartbeat', 'worker_pipeline_sync_imports', 'worker_pipeline_defer']);

  const lines = new TextEncoder().encode(JSON.stringify({ pages: Array.from({ length: 30 }, (_, i) => ({ page: i + 1 })) }));
  let collected: Record<string, unknown> = {};
  const done = harness({ worker_pipeline_collected: p => { collected = p; return entry('render'); } }, {
    mathpix: { ...harness({}).deps.mathpix,
      async status(id) { return { providerJobID: id, state: 'completed', pages: 30, completedPages: 30, pipelineVersion: 'v', deleted: false, errorCode: null }; },
      async conversion(id) { return { providerJobID: id, state: 'completed', errorCode: null }; },
      async output(_s, format) { return format === 'lines.json' ? lines : format === 'mmd' ? new TextEncoder().encode('# Paper') : new Uint8Array([0x50, 0x4b, 3, 4]); } },
    async render() { throw new Error('stop here'); } });
  await processPaper(done.deps, waiting, policy, deadline);
  assert.equal(collected.p_pages_reported, 30);
  const manifestSHA = String(collected.p_raw_manifest_sha256).slice(2);
  const raw = await loadRaw(done.deps, `raw/${manifestSHA}/manifest.json`);
  assert.equal(raw.manifest.format, RAW_FORMAT);
  assert.equal(raw.members.size, 3);
});

test('provider error settles without customer charge via ocr_failed', async () => {
  const { deps, calls } = harness({ worker_pipeline_ocr_failed: p => { assert.equal(p.p_pages_billed, 2); return entry('failed'); } }, {
    mathpix: { ...harness({}).deps.mathpix, async status(id) { return { providerJobID: id, state: 'error', pages: 5, completedPages: 2, pipelineVersion: null, deleted: false, errorCode: 'x' }; } } });
  await processPaper(deps, entry('ocr_wait', { document_sha256: 'd'.repeat(64),
    attempt: { id: 'a', state: 'submitted', page_limit: 5, provider_job_id: 'job-2', submitted_at: null, raw_manifest_path: null } }), policy, deadline);
  assert.deepEqual(names(calls), ['worker_pipeline_heartbeat', 'worker_pipeline_ocr_failed', 'worker_pipeline_sync_imports', 'worker_pipeline_release']);
});

test('transient errors back off; repeated failures fail resumably; lost claims do nothing', async () => {
  const transient = harness({ worker_pipeline_arxiv_slot: () => ({ reserved: true, wait_ms: 0, spacing_ms: 3000 }), worker_pipeline_admit_download: () => ({ admitted: true }), worker_pipeline_defer: p => p }, {
    fetch: (async () => new Response('busy', { status: 503 })) as unknown as typeof fetch });
  await processPaper(transient.deps, entry('download'), policy, deadline);
  const defer = transient.calls.find(c => c.name === 'worker_pipeline_defer')!.params;
  assert.equal(defer.p_fail, false); assert.equal(defer.p_seconds, 30); assert.equal(defer.p_error_code, 'rate_limited');

  const exhausted = harness({ worker_pipeline_arxiv_slot: () => ({ reserved: true, wait_ms: 0, spacing_ms: 3000 }), worker_pipeline_admit_download: () => ({ admitted: true }), worker_pipeline_defer: p => p }, {
    fetch: (async () => new Response('busy', { status: 503 })) as unknown as typeof fetch });
  await processPaper(exhausted.deps, entry('download', { failures: 4 }), policy, deadline);
  const failed = exhausted.calls.find(c => c.name === 'worker_pipeline_defer')!.params;
  assert.equal(failed.p_fail, true); assert.equal(failed.p_error_code, 'download_failed'); assert.equal(failed.p_resume_stage, 'download');

  const polling = harness({ worker_pipeline_defer: p => p }, {
    mathpix: { ...harness({}).deps.mathpix, async status() { throw new Error('provider_transport_failed'); } } });
  await processPaper(polling.deps, entry('ocr_wait', { failures: 9, document_sha256: 'd'.repeat(64),
    attempt: { id: 'a', state: 'submitted', page_limit: 5, provider_job_id: 'job-3', submitted_at: null, raw_manifest_path: null } }), policy, deadline);
  assert.equal(polling.calls.find(c => c.name === 'worker_pipeline_defer')!.params.p_fail, false, 'a held OCR job keeps polling');

  const stale = harness({ worker_pipeline_arxiv_slot: () => ({ reserved: true, wait_ms: 0, spacing_ms: 3000 }), worker_pipeline_metadata: () => { throw new PipelineRPCError('stale_pipeline_claim'); } }, {
    fetch: (async (url: string) => new Response(url.includes('export') ? atom : oai)) as unknown as typeof fetch });
  await processPaper(stale.deps, entry('metadata', { revision: null }), policy, deadline);
  assert.ok(!names(stale.calls).includes('worker_pipeline_defer'));
});

test('render integrity failure is permanent but resumable at render', async () => {
  const { deps, calls, uploads } = harness({ worker_pipeline_defer: p => p });
  uploads.set(`raw/${'a'.repeat(64)}/manifest.json`, new TextEncoder().encode('{"format":"other"}'));
  await processPaper(deps, entry('render', { document_sha256: 'd'.repeat(64),
    attempt: { id: 'a', state: 'collected', page_limit: 5, provider_job_id: 'j', submitted_at: null, raw_manifest_path: `raw/${'a'.repeat(64)}/manifest.json` } }), policy, deadline);
  const failed = calls.find(c => c.name === 'worker_pipeline_defer')!.params;
  assert.equal(failed.p_fail, true); assert.equal(failed.p_resume_stage, 'render'); assert.equal(failed.p_error_code, 'raw_integrity');
});

test('sync-only claims run no stage; arXiv pacing defers instead of sleeping long', async () => {
  const syncOnly = harness({});
  await processPaper(syncOnly.deps, entry('ocr_wait', { due: false }), policy, deadline);
  assert.deepEqual(names(syncOnly.calls), ['worker_pipeline_sync_imports', 'worker_pipeline_release']);
  let slept = 0;
  const paced = harness({ worker_pipeline_arxiv_slot: () => ({ reserved: false, wait_ms: 90_000 }), worker_pipeline_admit_download: () => ({ admitted: true }), worker_pipeline_defer: p => p }, { async sleep(ms) { slept += ms; } });
  await processPaper(paced.deps, entry('download'), policy, deadline);
  const defer = paced.calls.find(c => c.name === 'worker_pipeline_defer')!.params;
  assert.equal(slept, 0); assert.equal(defer.p_seconds, 90); assert.equal(defer.p_fail ?? false, false); assert.equal(defer.p_error_code, undefined);
});

test('funding that cannot be prepared is abandoned without a POST; low headroom defers before the grant', async () => {
  const funded = entry('ocr_submit', { failures: 2, document_sha256: 'd'.repeat(64), original_path: 'originals/missing.pdf', original_bytes: 100, page_count: 3,
    attempt: { id: 'a', state: 'funded', page_limit: 3, provider_job_id: null, submitted_at: null, raw_manifest_path: null } });
  const missing = harness({ worker_pipeline_abandon_funding: p => { assert.equal(p.p_error_code, 'download_failed'); return entry('failed'); } });
  await processPaper(missing.deps, funded, policy, deadline);
  assert.ok(names(missing.calls).includes('worker_pipeline_abandon_funding'));
  assert.ok(!names(missing.calls).includes('worker_pipeline_begin_submit'));
  const original = await pdf(3);
  const late = harness({ worker_pipeline_defer: p => p });
  late.uploads.set('originals/x.pdf', original);
  await processPaper(late.deps, { ...funded, failures: 0, original_path: 'originals/x.pdf', document_sha256: await sha256(original) }, policy, Date.parse('2026-10-05T06:01:00Z'));
  assert.deepEqual(names(late.calls), ['worker_pipeline_sync_imports', 'worker_pipeline_defer']);
});

test('unusable provider output fails the attempt (hold settles) instead of retrying forever', async () => {
  const { MathpixError } = await import('../../supabase/functions/_shared/mathpix.ts');
  const { deps, calls } = harness({ worker_pipeline_ocr_failed: p => { assert.equal(p.p_error_code, 'conversion_failed'); return entry('failed'); } }, {
    mathpix: { ...harness({}).deps.mathpix,
      async status(id) { return { providerJobID: id, state: 'completed', pages: 4, completedPages: 4, pipelineVersion: null, deleted: false, errorCode: null }; },
      async conversion(id) { return { providerJobID: id, state: 'completed', errorCode: null }; },
      async output() { throw new MathpixError('provider_body_limit'); } } });
  await processPaper(deps, entry('ocr_wait', { document_sha256: 'd'.repeat(64),
    attempt: { id: 'a', state: 'submitted', page_limit: 4, provider_job_id: 'job-4', submitted_at: null, raw_manifest_path: null } }), policy, deadline);
  assert.ok(names(calls).includes('worker_pipeline_ocr_failed'));
});

test('a billed job id is recorded even when the first record attempt fails', async () => {
  let tries = 0;
  const original = await pdf(2);
  const digest = await sha256(original);
  const { deps, calls, uploads } = harness({
    worker_pipeline_begin_submit: () => ({ ...entry('ocr_submit'), granted: true, attempt_id: '55555555-5555-4555-8555-555555555555' }),
    worker_pipeline_submitted: p => { tries++; if (tries < 3) throw new PipelineRPCError('database_error'); assert.equal(p.p_attempt_id, '55555555-5555-4555-8555-555555555555'); return entry('ocr_wait'); },
  }, { mathpix: { ...harness({}).deps.mathpix, async submitOnce() { return { state: 'accepted', providerJobID: 'job-5' }; } } });
  uploads.set('originals/y.pdf', original);
  await processPaper(deps, entry('ocr_submit', { document_sha256: digest, original_path: 'originals/y.pdf', original_bytes: original.length, page_count: 2,
    attempt: { id: 'a', state: 'funded', page_limit: 2, provider_job_id: null, submitted_at: null, raw_manifest_path: null } }), policy, deadline);
  assert.equal(tries, 3);
  assert.deepEqual(names(calls).slice(-2), ['worker_pipeline_sync_imports', 'worker_pipeline_release']);
});

test('render stage turns real retained Mathpix output into a valid reader bundle (DPO)', async (t) => {
  const dir = '/Users/benbowlwes/science-reader/.artifacts/spike-2305.18290';
  if (!existsSync(`${dir}/output.mmd.zip`)) { t.skip('real Mathpix capture not present'); return; }
  const { renderReader } = await import('../../supabase/functions/_shared/reader-adapter.ts');
  const { validateReaderBundle } = await import('../../supabase/functions/_shared/reader/index.ts');
  const members = new Map([['standalone.mmd', new Uint8Array(readFileSync(`${dir}/standalone.mmd`))],
    ['output.mmd.zip', new Uint8Array(readFileSync(`${dir}/output.mmd.zip`))], ['lines.json', new Uint8Array(readFileSync(`${dir}/lines.json`))]]);
  const ids: Record<string, { bytes: number; sha256: string }> = {};
  for (const [name, bytes] of members) ids[name] = { bytes: bytes.length, sha256: await sha256(bytes) };
  const manifest = new TextEncoder().encode(JSON.stringify({ format: RAW_FORMAT, provider: 'mathpix', provider_job_id: 'cc092181-9d12-4eb3-b5de-d2ca288fc556',
    api: 'v3/pdf', options_sha256: 'a'.repeat(64), page_limit: 27, pages: 27, document_sha256: 'b'.repeat(64), members: ids }) + '\n');
  const manifestSHA = await sha256(manifest);
  let published: Record<string, unknown> = {};
  const { deps, uploads } = harness({ worker_pipeline_published: p => { published = p; return entry('done'); } }, { render: renderReader });
  uploads.set(`raw/${manifestSHA}/manifest.json`, manifest);
  for (const [name, bytes] of members) uploads.set(`raw/${manifestSHA}/${name}`, bytes);
  await processPaper(deps, entry('render', { document_sha256: 'b'.repeat(64), page_count: 27, title: 'Direct Preference Optimization', authors: ['Rafael Rafailov'],
    license_uri: 'https://creativecommons.org/licenses/by/4.0/', raw_manifest_path: `raw/${manifestSHA}/manifest.json`, attempt: null }), policy, deadline);
  const bundleSHA = String(published.p_manifest_sha256).slice(2);
  assert.match(bundleSHA, /^[0-9a-f]{64}$/);
  const prefix = `reader/${bundleSHA}/`;
  const bundleMembers = new Map([...uploads].filter(([k]) => k.startsWith(prefix) && k !== `${prefix}manifest.json`).map(([k, v]) => [k.slice(prefix.length), v]));
  validateReaderBundle(uploads.get(`${prefix}manifest.json`)!, bundleMembers, bundleSHA);
  const notice = new TextDecoder().decode(bundleMembers.get('NOTICE.txt'));
  assert.match(notice, /Direct Preference Optimization/); assert.match(notice, /creativecommons\.org\/licenses\/by\/4\.0/);
  assert.ok([...bundleMembers.keys()].some(k => k.endsWith('.jpg')), 'JPEG figures published');
});

test('a job the provider no longer knows fails (hold settles) instead of polling forever', async () => {
  const { MathpixError } = await import('../../supabase/functions/_shared/mathpix.ts');
  const { deps, calls } = harness({ worker_pipeline_ocr_failed: p => { assert.equal(p.p_pages_billed, 6); return entry('failed'); } }, {
    mathpix: { ...harness({}).deps.mathpix, async status() { throw new MathpixError('provider_http_failure', 404); } } });
  await processPaper(deps, entry('ocr_wait', { document_sha256: 'd'.repeat(64),
    attempt: { id: 'a', state: 'submitted', page_limit: 6, provider_job_id: 'job-typo', submitted_at: null, raw_manifest_path: null } }), policy, deadline);
  assert.ok(names(calls).includes('worker_pipeline_ocr_failed'));
});

test('a download that is not admitted fetches nothing', async () => {
  let fetched = false;
  const { deps, calls } = harness({ worker_pipeline_admit_download: () => ({ admitted: false, reason: 'needs_credits' }) }, {
    fetch: (async () => { fetched = true; return new Response(''); }) as unknown as typeof fetch });
  await processPaper(deps, entry('download', { owner_id: '99999999-9999-4999-8999-999999999999' }), policy, deadline);
  assert.equal(fetched, false);
  assert.deepEqual(names(calls), ['worker_pipeline_admit_download', 'worker_pipeline_sync_imports', 'worker_pipeline_release']);
});
