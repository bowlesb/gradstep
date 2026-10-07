import test from 'node:test';
import assert from 'node:assert/strict';
import { PDFDocument } from 'pdf-lib';
import { fetchFirstWebPDF, fetchOpenAlexWork, fetchWebPDF, isPublicAddress, openAlexWork, openAlexWorkURL, openPDFLocations, publicHTTPS, WebSourceError,
  type ResolveHost } from '../../supabase/functions/_shared/web-source.ts';
import { PermanentFailure, processPaper, type PaperEntry, type PipelineDeps, type PipelinePolicy } from '../../supabase/functions/_shared/pipeline.ts';
import { sha256 } from '../../supabase/functions/_shared/http.ts';

async function pdf(pages = 3): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  for (let i = 0; i < pages; i++) doc.addPage();
  return doc.save();
}
const permanent = (code: string) => (e: unknown) => e instanceof WebSourceError && e.permanent && e.code === code;
const transient = (code: string) => (e: unknown) => e instanceof WebSourceError && !e.permanent && e.code === code;
const publicDNS: ResolveHost = async () => ['93.184.215.14'];

test('web URLs: https on a public DNS name only', () => {
  assert.equal(publicHTTPS('https://repository.example.org/paper.pdf?download=1')?.href, 'https://repository.example.org/paper.pdf?download=1');
  for (const url of ['http://repository.example.org/a.pdf', 'https://127.0.0.1/a.pdf', 'https://0x7f.1/a.pdf', 'https://2130706433/a.pdf',
    'https://[::1]/a.pdf', 'https://repository.example.org:8443/a.pdf', 'https://user:pw@repository.example.org/a.pdf', 'https://localhost/a.pdf',
    'https://metadata.google.internal/a.pdf', 'https://intranet/a.pdf', 'https://printer.local/a.pdf', 'ftp://repository.example.org/a.pdf',
    'https://repository.example.org/a.pdf#x', 'not a url']) {
    assert.equal(publicHTTPS(url), null, url);
  }
});

test('addresses: only public unicast', () => {
  for (const address of ['93.184.215.14', '8.8.8.8', '2606:4700::6810:84e5', '2a00:1450:4009:81f::200e']) assert.ok(isPublicAddress(address), address);
  for (const address of ['10.0.0.1', '127.0.0.1', '169.254.169.254', '172.16.0.1', '172.31.255.255', '192.168.1.1', '100.64.0.1', '0.0.0.0',
    '224.0.0.1', '255.255.255.255', '198.18.0.1', '::1', '::', 'fe80::1', 'fc00::1', 'fd12:3456::1', '::ffff:127.0.0.1', '::ffff:10.0.0.1',
    '2001:db8::1', '64:ff9b::a00:1', 'ff02::1', 'nonsense']) assert.ok(!isPublicAddress(address), address);
});

const work = {
  id: 'https://openalex.org/W1000000001', doi: 'https://doi.org/10.1038/NATURE14539', title: '  Deep   learning ', publication_date: '2015-05-27',
  authorships: [{ author: { display_name: 'Yann LeCun' } }, { author: { display_name: 'Yoshua Bengio' } }, { author: {} }],
  abstract_inverted_index: { Deep: [0], learning: [1, 4], allows: [2], models: [3] },
  primary_location: { source: { display_name: 'Nature' } },
  best_oa_location: { pdf_url: 'http://repository.example.org/deep.pdf', landing_page_url: 'https://www.nature.com/articles/nature14539', is_oa: true },
  locations: [
    { pdf_url: 'https://arxiv.org/pdf/1234.5678', is_oa: true },
    { pdf_url: 'https://paywalled.example.com/deep.pdf', is_oa: false },
    { pdf_url: 'http://jmlr.csail.mit.edu/papers/volume15/srivastava14a/srivastava14a.pdf', is_oa: false },
    { pdf_url: 'https://repository.example.org/deep.pdf', is_oa: true },
    { pdf_url: 'https://127.0.0.1/deep.pdf', is_oa: true },
    { pdf_url: 'https://mirror-a.example.net/deep.pdf', is_oa: true },
    { pdf_url: 'https://mirror-b.example.net/deep.pdf', is_oa: true },
    { pdf_url: 'https://mirror-c.example.net/deep.pdf', is_oa: true },
  ],
};

test('OpenAlex work: catalog metadata and open-access PDF locations', () => {
  const parsed = openAlexWork(work)!;
  assert.deepEqual(parsed.metadata, { title: 'Deep learning', authors: ['Yann LeCun', 'Yoshua Bengio'], abstract: 'Deep learning allows models learning',
    published_at: '2015-05-27', updated_at: null, categories: [], venue: 'Nature' });
  assert.equal(parsed.doi, '10.1038/NATURE14539');
  // Best OA first, then open venues (whatever OpenAlex's label), then other OA copies; http upgraded,
  // arXiv/closed/IP-literal locations skipped, duplicates removed, at most three.
  assert.deepEqual(parsed.pdfURLs, ['https://repository.example.org/deep.pdf', 'https://jmlr.csail.mit.edu/papers/volume15/srivastava14a/srivastava14a.pdf',
    'https://mirror-a.example.net/deep.pdf']);
  assert.deepEqual(openPDFLocations({ locations: [{ pdf_url: 'https://evil-jmlr.org/x.pdf', is_oa: false }, { pdf_url: 'https://proceedings.mlr.press/v37/x.pdf' }] }),
    ['https://proceedings.mlr.press/v37/x.pdf']);
  // OpenAlex's actual Dropout record: the JMLR PDF is the landing page, pdf_url is null, nothing is labelled open.
  assert.deepEqual(openPDFLocations({ best_oa_location: null, locations: [
    { is_oa: false, landing_page_url: 'http://citeseerx.ist.psu.edu/viewdoc/summary?doi=10.1.1.669.8604', pdf_url: null },
    { is_oa: false, landing_page_url: 'https://jmlr.csail.mit.edu/papers/volume15/srivastava14a/srivastava14a.pdf', pdf_url: null },
    { is_oa: true, landing_page_url: 'https://repository.example.org/item/7', pdf_url: null }] }),
    ['https://jmlr.csail.mit.edu/papers/volume15/srivastava14a/srivastava14a.pdf']);
  assert.equal(parsed.landingURL, 'https://www.nature.com/articles/nature14539');
  const bare = openAlexWork({ ...work, best_oa_location: null, locations: [], publication_date: '2015-02-30' })!;
  assert.deepEqual(bare.pdfURLs, []);
  assert.equal(bare.landingURL, 'https://doi.org/10.1038/NATURE14539');
  assert.equal(bare.metadata.published_at, null);
  assert.equal(openAlexWork({ ...work, id: 'https://evil.example/W1' }), null);
  assert.equal(openAlexWork({ ...work, title: ' ', display_name: null }), null);
  assert.equal(openAlexWorkURL('openalex:W1000000001').startsWith('https://api.openalex.org/works/W1000000001?select='), true);
  assert.throws(() => openAlexWorkURL('2305.18290'), permanent('metadata_unavailable'));
});

test('OpenAlex fetch stays on api.openalex.org', async () => {
  const seen: string[] = [];
  const fetcher = (async (url: string) => {
    seen.push(url);
    if (url.includes('W1?')) return new Response(null, { status: 301, headers: { location: '/works/W2?select=id' } });
    if (url.includes('W3')) return new Response(null, { status: 302, headers: { location: 'https://evil.example/works/W3' } });
    if (url.includes('W4')) return new Response('missing', { status: 404 });
    if (url.includes('W5')) return new Response('busy', { status: 503 });
    return Response.json({ id: 'https://openalex.org/W2' });
  }) as unknown as typeof fetch;
  assert.deepEqual(await fetchOpenAlexWork(fetcher, 'https://api.openalex.org/works/W1?select=id'), { id: 'https://openalex.org/W2' });
  assert.equal(seen[1], 'https://api.openalex.org/works/W2?select=id');
  await assert.rejects(fetchOpenAlexWork(fetcher, 'https://api.openalex.org/works/W3'), permanent('metadata_unavailable'));
  await assert.rejects(fetchOpenAlexWork(fetcher, 'https://api.openalex.org/works/W4'), permanent('metadata_unavailable'));
  await assert.rejects(fetchOpenAlexWork(fetcher, 'https://api.openalex.org/works/W5'), transient('metadata_unavailable'));
});

test('web PDF download: every hop checked, landing pages and blocks refused, bounded', async () => {
  const body = await pdf(2);
  const fetcher = (async (url: string, init?: RequestInit) => {
    const path = new URL(url).pathname;
    if (path === '/ok.pdf') return new Response(body, { headers: { 'content-type': 'application/pdf' } });
    if (path === '/hop') return new Response(null, { status: 302, headers: { location: '/ok.pdf' } });
    if (path === '/to-http') return new Response(null, { status: 302, headers: { location: 'http://repository.example.org/ok.pdf' } });
    if (path === '/to-ip') return new Response(null, { status: 307, headers: { location: 'https://169.254.169.254/latest/meta-data' } });
    if (path === '/to-internal') return new Response(null, { status: 302, headers: { location: 'https://internal.example.net/ok.pdf' } });
    if (path === '/loop') return new Response(null, { status: 302, headers: { location: '/loop' } });
    if (path === '/html') return new Response('<html>Sign in</html>', { headers: { 'content-type': 'text/html; charset=utf-8' } });
    if (path === '/challenge') return new Response('<!doctype html><title>Just a moment</title>', { headers: { 'content-type': 'application/octet-stream' } });
    if (path === '/forbidden') return new Response('no', { status: 403 });
    if (path === '/busy') return new Response('later', { status: 503 });
    if (path === '/big') return new Response(body, { headers: { 'content-length': String(10 * 1024 * 1024) } });
    // A repository record page (Zenodo's pattern) that declares its PDF.
    const page = (meta: string) => new Response(`<!doctype html><html><head><title>Record</title>${meta}</head><body>Files</body></html>`,
      { headers: { 'content-type': 'text/html; charset=utf-8' } });
    // Zenodo answers 406 to a PDF-only Accept header: HTML must be acceptable too.
    if (path === '/record/38240') return /text\/html/.test(String((init?.headers as Record<string, string>)?.accept)) ? page('<meta name="citation_pdf_url" content="https://repository.example.org/records/38240/files/cr1175.pdf"/>')
      : new Response('{"status":406}', { status: 406, headers: { 'content-type': 'application/json' } });
    if (path === '/records/38240/files/cr1175.pdf') return new Response(body, { headers: { 'content-type': 'application/pdf' } });
    if (path === '/record/relative') return page(`<meta content='/ok.pdf' name='CITATION_PDF_URL'>`);
    if (path === '/record/alternate') return page('<link rel="alternate" type="application/pdf" href="/ok.pdf?download=1&amp;v=2">');
    if (path === '/ok.pdf' && new URL(url).search) return new Response(body, { headers: { 'content-type': 'application/pdf' } });
    if (path === '/record/internal') return page('<meta name="citation_pdf_url" content="https://internal.example.net/ok.pdf">');
    if (path === '/record/to-page') return page('<meta name="citation_pdf_url" content="https://repository.example.org/record/38240">');
    if (path === '/record/none') return page('<meta name="citation_title" content="A paper">');
    throw new Error('unexpected ' + url);
  }) as unknown as typeof fetch;
  const resolve: ResolveHost = async host => host === 'internal.example.net' ? ['10.1.2.3'] : ['93.184.215.14'];
  const base = 'https://repository.example.org';
  assert.deepEqual(await fetchWebPDF(fetcher, `${base}/hop`, 1024 * 1024, resolve), body);
  // A redirect to http is followed over https (never in the clear).
  assert.deepEqual(await fetchWebPDF(fetcher, `${base}/to-http`, 1024 * 1024, resolve), body);
  await assert.rejects(fetchWebPDF(fetcher, `${base}/to-ip`, 1024 * 1024, resolve), permanent('download_failed'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/to-internal`, 1024 * 1024, resolve), permanent('download_failed'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/loop`, 1024 * 1024, resolve), permanent('download_failed'));
  // A page that declares no PDF (a "Sign in" link alone is not a paywall).
  await assert.rejects(fetchWebPDF(fetcher, `${base}/html`, 1024 * 1024, resolve), permanent('not_pdf'));
  // Landing pages: the declared PDF is followed once, with the same checks; never a second page.
  assert.deepEqual(await fetchWebPDF(fetcher, `${base}/record/38240`, 1024 * 1024, resolve), body);
  assert.deepEqual(await fetchWebPDF(fetcher, `${base}/record/relative`, 1024 * 1024, resolve), body);
  assert.deepEqual(await fetchWebPDF(fetcher, `${base}/record/alternate`, 1024 * 1024, resolve), body);
  await assert.rejects(fetchWebPDF(fetcher, `${base}/record/internal`, 1024 * 1024, resolve), permanent('download_failed'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/record/to-page`, 1024 * 1024, resolve), permanent('not_pdf'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/record/none`, 1024 * 1024, resolve), permanent('not_pdf'));
  // A bot check is told apart from a missing PDF, whatever type it claims.
  await assert.rejects(fetchWebPDF(fetcher, `${base}/challenge`, 1024 * 1024, resolve), permanent('source_blocked'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/forbidden`, 1024 * 1024, resolve), permanent('source_blocked'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/busy`, 1024 * 1024, resolve), transient('rate_limited'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/big`, 1024 * 1024, resolve), permanent('too_large'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/ok.pdf`, 100, resolve), permanent('too_large'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/ok.pdf`, 1024 * 1024, async () => { throw new Error('nxdomain'); }), permanent('download_failed'));
  // Locations are tried in order; a transient failure anywhere keeps the import retrying.
  assert.equal((await fetchFirstWebPDF(fetcher, [`${base}/forbidden`, `${base}/ok.pdf`], 1024 * 1024, resolve)).url, `${base}/ok.pdf`);
  await assert.rejects(fetchFirstWebPDF(fetcher, [`${base}/forbidden`, `${base}/busy`], 1024 * 1024, resolve), transient('rate_limited'));
  // Every location failed for good: the most telling reason wins (blocked over no PDF over gone).
  await assert.rejects(fetchFirstWebPDF(fetcher, [`${base}/html`, `${base}/forbidden`], 1024 * 1024, resolve), permanent('source_blocked'));
  await assert.rejects(fetchFirstWebPDF(fetcher, [`${base}/to-ip`, `${base}/html`], 1024 * 1024, resolve), permanent('not_pdf'));
});

const policy: PipelinePolicy = { enabled: true, max_pdf_bytes: 64 * 1024 * 1024, max_ocr_pages: 80, renderer_version: 'timestep-mathpix-mathml-v1' };
const deadline = Date.parse('2026-10-05T06:05:00Z');
function entry(stage: string, extra: Partial<PaperEntry> = {}): PaperEntry {
  return { id: '11111111-1111-4111-8111-111111111111', source_id: 'openalex:W1000000001', source_kind: 'web', requested_revision: 0, revision: null, stage,
    generation: 7, claim_id: '22222222-2222-4222-8222-222222222222', state_revision: 3, failures: 0, document_id: null, document_sha256: null,
    original_path: null, original_bytes: null, page_count: null, attempt: null, ...extra };
}
function harness(responses: Record<string, (params: Record<string, unknown>) => unknown>, fetcher: (url: string) => Promise<Response>) {
  const calls: { name: string; params: Record<string, unknown> }[] = []; const uploads = new Map<string, Uint8Array>();
  const unexpected = async () => { throw new Error('unexpected'); };
  const deps: PipelineDeps = {
    async rpc<T>(name: string, params: Record<string, unknown>): Promise<T> { calls.push({ name, params }); return (responses[name]?.(params) ?? null) as T; },
    storage: { async upload(path, bytes) { uploads.set(path, bytes); }, download: unexpected, signedURL: unexpected },
    fetch: fetcher as unknown as typeof fetch,
    mathpix: { submitOnce: unexpected, submitURL: unexpected, status: unexpected, conversion: unexpected, output: unexpected },
    render: unexpected, async sleep() {}, now: () => Date.parse('2026-10-05T06:00:00Z'), uuid: () => '33333333-3333-4333-8333-333333333333',
    log() {}, resolveHost: publicDNS,
  };
  return { deps, calls, uploads };
}

test('web metadata stage records OpenAlex metadata and locations; never touches arXiv', async () => {
  const fetched: string[] = [];
  const { deps, calls } = harness({
    worker_pipeline_web_metadata: p => {
      assert.equal((p.p_metadata as { title: string }).title, 'Deep learning');
      assert.deepEqual(p.p_pdf_urls, ['https://repository.example.org/deep.pdf', 'https://jmlr.csail.mit.edu/papers/volume15/srivastava14a/srivastava14a.pdf',
        'https://mirror-a.example.net/deep.pdf']);
      assert.equal(p.p_landing_url, 'https://www.nature.com/articles/nature14539');
      assert.equal(p.p_doi, '10.1038/NATURE14539');
      return entry('private_split', { revision: 1 });
    },
  }, async url => { fetched.push(url); return Response.json(work); });
  await processPaper(deps, entry('metadata'), policy, deadline);
  assert.ok(fetched.every(url => url.startsWith('https://api.openalex.org/works/W1000000001?')));
  assert.ok(!calls.some(c => c.name === 'worker_pipeline_arxiv_slot' || c.name === 'worker_pipeline_metadata'));
  assert.ok(calls.some(c => c.name === 'worker_pipeline_web_metadata'));
});

test('a work without an open-access PDF keeps its metadata and fails at download as not_open (migration 039)', async () => {
  const closed = { ...work, best_oa_location: null, locations: [] };
  const { deps, calls } = harness({ worker_pipeline_web_metadata: p => { assert.deepEqual(p.p_pdf_urls, []); return entry('private_split', { revision: 1 }); } },
    async () => Response.json(closed));
  await processPaper(deps, entry('metadata'), policy, deadline);
  assert.ok(calls.some(c => c.name === 'worker_pipeline_web_metadata'), 'metadata recorded');
  assert.ok(!calls.some(c => c.name === 'worker_pipeline_defer' && c.params.p_fail), 'not failed at metadata');
  // Its private paper finds no location (recorded or fresh) and fails resumably at download.
  const owner = '55555555-5555-4555-8555-555555555555';
  const download = harness({ worker_pipeline_admit_download: () => ({ admitted: true }) }, async () => Response.json(closed));
  await processPaper(download.deps, entry('download', { revision: 1, owner_id: owner, pdf_urls: null }), policy, deadline);
  const defer = download.calls.find(c => c.name === 'worker_pipeline_defer')!;
  assert.equal(defer.params.p_fail, true);
  assert.equal(defer.params.p_error_code, 'not_open');
  assert.equal(defer.params.p_resume_stage, 'download');
});

test('web download stores the private original; a blocked location falls through to the next', async () => {
  const body = await pdf(9);
  const digest = await sha256(body);
  const owner = '55555555-5555-4555-8555-555555555555';
  const { deps, calls, uploads } = harness({
    worker_pipeline_admit_download: () => ({ admitted: true }),
    worker_pipeline_original: p => { assert.equal(p.p_path, `private/${owner}/originals/${digest}.pdf`); assert.equal(p.p_pages, 9);
      return entry('ocr_fund', { revision: 1, owner_id: owner, document_sha256: digest, page_count: 9 }); },
    worker_pipeline_fund: () => ({ ...entry('ocr_fund'), funding: 'paused' }),
  }, async url => url.includes('blocked') ? new Response('denied', { status: 403 }) : new Response(body));
  await processPaper(deps, entry('download', { revision: 1, owner_id: owner,
    pdf_urls: ['https://blocked.example.org/a.pdf', 'https://repository.example.org/a.pdf'] }), policy, deadline);
  assert.ok(uploads.has(`private/${owner}/originals/${digest}.pdf`));
  assert.ok(!calls.some(c => c.name === 'worker_pipeline_arxiv_slot'));
});

test('web download failures: blocked everywhere is permanent and retryable by the reader; unshared only', async () => {
  const owner = '55555555-5555-4555-8555-555555555555';
  const blocked = harness({ worker_pipeline_admit_download: () => ({ admitted: true }) }, async () => new Response('denied', { status: 403 }));
  await processPaper(blocked.deps, entry('download', { revision: 1, owner_id: owner, pdf_urls: ['https://repository.example.org/a.pdf'] }), policy, deadline);
  const defer = blocked.calls.find(c => c.name === 'worker_pipeline_defer')!;
  assert.deepEqual([defer.params.p_fail, defer.params.p_error_code, defer.params.p_resume_stage], [true, 'source_blocked', 'download']);
  const busy = harness({ worker_pipeline_admit_download: () => ({ admitted: true }) }, async () => new Response('later', { status: 503 }));
  await processPaper(busy.deps, entry('download', { revision: 1, owner_id: owner, pdf_urls: ['https://repository.example.org/a.pdf'] }), policy, deadline);
  assert.equal(busy.calls.find(c => c.name === 'worker_pipeline_defer')!.params.p_fail, false);
  // A shared (owner-less) web paper is never downloaded.
  const shared = harness({ worker_pipeline_admit_download: () => ({ admitted: true }) }, async () => { throw new Error('fetched'); });
  await processPaper(shared.deps, entry('download', { revision: 1, pdf_urls: ['https://repository.example.org/a.pdf'] }), policy, deadline);
  assert.ok(!shared.calls.some(c => c.name === 'worker_pipeline_original'));
  assert.ok(new PermanentFailure('x') instanceof Error);
});

test('review fixes: body resets fall through, one overall budget, arXiv redirects refused, odd IDs and text', async () => {
  const body = await pdf(2);
  const resolve: ResolveHost = async () => ['93.184.215.14'];
  const fetcher = (async (url: string, init?: RequestInit) => {
    const path = new URL(url).pathname;
    if (path === '/reset') {
      // Headers arrive, then the connection drops mid-body.
      return new Response(new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode('%PDF-1.5\n')); c.error(new TypeError('connection reset')); } }));
    }
    if (path === '/stall') return await new Promise<Response>((_, reject) => init?.signal?.addEventListener('abort', () => reject(new DOMException('timeout', 'TimeoutError'))));
    if (path === '/to-arxiv') return new Response(null, { status: 302, headers: { location: 'https://arxiv.org/pdf/1207.0580' } });
    return new Response(body);
  }) as unknown as typeof fetch;
  const base = 'https://repository.example.org';
  assert.equal((await fetchFirstWebPDF(fetcher, [`${base}/reset`, `${base}/ok.pdf`], 1024 * 1024, resolve)).url, `${base}/ok.pdf`);
  await assert.rejects(fetchWebPDF(fetcher, `${base}/reset`, 1024 * 1024, resolve), transient('download_failed'));
  await assert.rejects(fetchWebPDF(fetcher, `${base}/to-arxiv`, 1024 * 1024, resolve), permanent('download_failed'));
  const started = Date.now();
  await assert.rejects(fetchFirstWebPDF(fetcher, [`${base}/stall`, `${base}/stall`, `${base}/ok.pdf`], 1024 * 1024, resolve, AbortSignal.timeout(50)),
    transient('download_failed'));
  assert.ok(Date.now() - started < 2000, 'the budget covers every location');
  assert.ok(!isPublicAddress('2001:0:4136:e378:8000:63bf:3fff:fdd2'), 'Teredo');
  assert.throws(() => openAlexWorkURL('openalex:W0001'), permanent('metadata_unavailable'));
  const noisy = openAlexWork({ ...work, title: 'Deep\u0002 learning\u0085', authorships: [{ author: { display_name: 'Yann\u0000 LeCun' } }] })!;
  assert.equal(noisy.metadata.title, 'Deep learning');
  assert.deepEqual(noisy.metadata.authors, ['Yann LeCun']);
});

test('web download re-reads locations from OpenAlex; too little time left defers before admission', async () => {
  const body = await pdf(3);
  const owner = '55555555-5555-4555-8555-555555555555';
  const moved = { ...work, best_oa_location: { pdf_url: 'https://new-home.example.org/deep.pdf', is_oa: true }, locations: [] };
  const fetched: string[] = [];
  const { deps, calls } = harness({
    worker_pipeline_admit_download: () => ({ admitted: true }),
    worker_pipeline_web_locations: p => { assert.deepEqual(p.p_pdf_urls, ['https://new-home.example.org/deep.pdf']); return entry('download', { pdf_urls: p.p_pdf_urls as string[] }); },
    worker_pipeline_original: () => entry('ocr_fund', { revision: 1, owner_id: owner }),
    worker_pipeline_fund: () => ({ ...entry('ocr_fund'), funding: 'paused' }),
  }, async url => { fetched.push(url); return url.startsWith('https://api.openalex.org/') ? Response.json(moved) : url.includes('new-home') ? new Response(body) : new Response('gone', { status: 404 }); });
  await processPaper(deps, entry('download', { revision: 1, owner_id: owner, pdf_urls: ['https://old-home.example.org/deep.pdf'] }), policy, deadline);
  assert.ok(calls.some(c => c.name === 'worker_pipeline_web_locations'));
  assert.ok(fetched.includes('https://new-home.example.org/deep.pdf') && !fetched.includes('https://old-home.example.org/deep.pdf'));
  assert.ok(calls.some(c => c.name === 'worker_pipeline_original'));

  const late = harness({ worker_pipeline_admit_download: () => { throw new Error('must not admit'); } }, async () => { throw new Error('must not fetch'); });
  await processPaper(late.deps, entry('download', { revision: 1, owner_id: owner, pdf_urls: ['https://repository.example.org/a.pdf'] }), policy,
    Date.parse('2026-10-05T06:00:00Z') + 60_000);
  assert.deepEqual(late.calls.filter(c => c.name !== 'worker_pipeline_sync_imports').map(c => [c.name, c.params.p_seconds]), [['worker_pipeline_defer', 0]]);
});
