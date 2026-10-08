import test from 'node:test';
import assert from 'node:assert/strict';
import { addPaper, type AddPaperDeps } from '../../supabase/functions/_shared/add-paper.ts';
import { doiInURL, doiOf, landingForPDF, pageFacts, parseAddInput, probeLink } from '../../supabase/functions/_shared/identify.ts';
import type { FindResult, FoundPaper } from '../../supabase/functions/_shared/chat.ts';

const signal = () => new AbortController().signal;
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const html = (body: string, status = 200, headers: Record<string, string> = {}) => new Response(body, { status, headers: { 'content-type': 'text/html', ...headers } });
const pdf = () => new Response(new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode('%PDF-1.7\n')); c.enqueue(new Uint8Array(4096)); } }),
  { headers: { 'content-type': 'application/pdf' } });

test('the Add input: arXiv IDs and links, DOIs in any common form, links, references', () => {
  assert.deepEqual(parseAddInput(' 2305.18290v2 '), { kind: 'arxiv', sourceID: '2305.18290', revision: 2 });
  assert.deepEqual(parseAddInput('https://arxiv.org/pdf/1706.03762'), { kind: 'arxiv', sourceID: '1706.03762', revision: null });
  for (const doi of ['10.1145/3292500.3330701', 'doi:10.1145/3292500.3330701', 'https://doi.org/10.1145/3292500.3330701', 'http://dx.doi.org/10.1145%2F3292500.3330701', 'DOI: 10.1145/3292500.3330701.']) {
    assert.deepEqual(parseAddInput(doi), { kind: 'doi', doi: '10.1145/3292500.3330701' }, doi);
  }
  const link = parseAddInput('http://proceedings.mlr.press/v202/kirchenbauer23a/kirchenbauer23a.pdf');
  assert.equal(link?.kind, 'url');
  assert.equal(link?.kind === 'url' && link.url.href, 'https://proceedings.mlr.press/v202/kirchenbauer23a/kirchenbauer23a.pdf', 'http is upgraded');
  assert.equal(parseAddInput('www.nature.com/articles/nature14539')?.kind, 'url');
  for (const refused of ['https://192.168.1.1/paper.pdf', 'https://localhost/x.pdf', 'https://intranet.corp/x.pdf', 'ftp://example.org/x.pdf', 'https://example.org:8443/x.pdf', '']) {
    assert.equal(parseAddInput(refused), null, refused);
  }
  assert.equal(parseAddInput('Attention is all you need')?.kind, 'text');
  assert.equal(parseAddInput('short'), null);
  assert.equal(parseAddInput('x'.repeat(2001)), null);
  assert.equal(doiOf('10.1000/abc).'), '10.1000/abc');
});

test('DOIs in publisher links; landing pages for proceedings PDFs', () => {
  const cases: [string, string | null][] = [
    ['https://dl.acm.org/doi/10.1145/3292500.3330701', '10.1145/3292500.3330701'],
    ['https://dl.acm.org/doi/pdf/10.1145/3292500.3330701', '10.1145/3292500.3330701'],
    ['https://onlinelibrary.wiley.com/doi/full/10.1002/aisy.202000001', '10.1002/aisy.202000001'],
    ['https://link.springer.com/article/10.1007/s10994-021-06063-x', '10.1007/s10994-021-06063-x'],
    ['https://www.nature.com/articles/s41586-021-03819-2', '10.1038/s41586-021-03819-2'],
    ['https://www.science.org/doi/10.1126/science.aar6404', '10.1126/science.aar6404'],
    ['https://proceedings.mlr.press/v202/kirchenbauer23a.html', null],
  ];
  for (const [url, doi] of cases) assert.equal(doiInURL(new URL(url)), doi, url);
  const landing: [string, string | null][] = [
    ['https://proceedings.neurips.cc/paper_files/paper/2023/file/a85b405ed65c6477a4fe8302b5e06ce7-Paper-Conference.pdf',
      'https://proceedings.neurips.cc/paper_files/paper/2023/hash/a85b405ed65c6477a4fe8302b5e06ce7-Abstract-Conference.html'],
    ['https://proceedings.neurips.cc/paper/2017/file/3f5ee243547dee91fbd053c1c4a845aa-Paper.pdf',
      'https://proceedings.neurips.cc/paper/2017/hash/3f5ee243547dee91fbd053c1c4a845aa-Abstract.html'],
    ['https://proceedings.mlr.press/v202/kirchenbauer23a/kirchenbauer23a.pdf', 'https://proceedings.mlr.press/v202/kirchenbauer23a.html'],
    ['https://proceedings.mlr.press/v37/ioffe15.pdf', 'https://proceedings.mlr.press/v37/ioffe15.html'],
    ['https://aclanthology.org/2023.acl-long.1.pdf', 'https://aclanthology.org/2023.acl-long.1/'],
    ['https://openaccess.thecvf.com/content/CVPR2023/papers/Kirillov_Segment_Anything_ICCV_2023_paper.pdf',
      'https://openaccess.thecvf.com/content/CVPR2023/html/Kirillov_Segment_Anything_ICCV_2023_paper.html'],
    ['https://jmlr.org/papers/volume15/srivastava14a/srivastava14a.pdf', 'https://jmlr.org/papers/v15/srivastava14a.html'],
    ['https://openreview.net/pdf?id=HPuSIXJaa9', 'https://openreview.net/forum?id=HPuSIXJaa9'],
    ['https://ojs.aaai.org/index.php/AAAI/article/download/16826/16633', 'https://ojs.aaai.org/index.php/AAAI/article/view/16826'],
    ['https://example.org/paper.pdf', null],
  ];
  for (const [url, page] of landing) assert.equal(landingForPDF(new URL(url))?.href ?? null, page, url);
});

test('a landing page names its paper: citation tags, Dublin Core, then its title', () => {
  const base = new URL('https://proceedings.mlr.press/v202/kirchenbauer23a.html');
  const facts = pageFacts(`<head><meta name="citation_title" content="A Watermark for Large Language Models">
    <meta name="citation_pdf_url" content="https://proceedings.mlr.press/v202/kirchenbauer23a/kirchenbauer23a.pdf"></head>`, base);
  assert.equal(facts.title, 'A Watermark for Large Language Models');
  assert.equal(facts.pdfURL?.href, 'https://proceedings.mlr.press/v202/kirchenbauer23a/kirchenbauer23a.pdf');
  assert.equal(facts.doi, null);
  const dc = pageFacts(`<meta name="dc.identifier" content="doi:10.1145/3292500.3330701"><meta property="og:title" content="Fast &amp; accurate &#8211; a study">`, base);
  assert.equal(dc.doi, '10.1145/3292500.3330701');
  assert.equal(dc.title, 'Fast & accurate – a study');
  assert.equal(pageFacts('<meta name="citation_arxiv_id" content="2305.18290">', base).arxiv?.sourceID, '2305.18290');
  assert.equal(pageFacts('<title>\n  Deep residual learning\n</title>', base).title, 'Deep residual learning');
});

type Routes = Record<string, (url: URL) => Response>;
function fetcher(routes: Routes, calls: string[] = []): typeof fetch {
  return (async (input: string | URL) => {
    const url = new URL(String(input)); calls.push(url.hostname + url.pathname + url.search);
    const route = Object.entries(routes).sort((a, b) => b[0].length - a[0].length).find(([prefix]) => (url.hostname + url.pathname + url.search).startsWith(prefix));
    if (!route) throw new Error('unexpected ' + url.href);
    return route[1](url);
  }) as typeof fetch;
}
const publicDNS = async () => ['93.184.216.34'];

test('probing a link: every hop resolved and checked, a PDF is recognised without reading it, refusals told apart', async () => {
  const resolve = async (host: string) => host === 'internal.example.org' ? ['10.0.0.7'] : ['93.184.216.34'];
  const go = (routes: Routes, url: string) => probeLink(fetcher(routes), new URL(url), resolve, signal());
  assert.deepEqual(await go({ 'repo.example.org/p': () => new Response(null, { status: 302, headers: { location: 'https://internal.example.org/x.pdf' } }) }, 'https://repo.example.org/p'),
    { kind: 'refused', url: new URL('https://internal.example.org/x.pdf'), code: 'download_failed' }, 'a redirect to a private address is refused');
  assert.equal((await go({ 'repo.example.org/p': () => new Response(null, { status: 302, headers: { location: 'http://repo.example.org/x.pdf' } }),
    'repo.example.org/x.pdf': () => pdf() }, 'https://repo.example.org/p')).kind, 'pdf', 'http redirects are followed over https');
  assert.deepEqual(await go({ 'repo.example.org/p': () => new Response(null, { status: 301, headers: { location: 'https://arxiv.org/abs/2305.18290v3' } }) }, 'https://repo.example.org/p'),
    { kind: 'arxiv', sourceID: '2305.18290', revision: 3 });
  const blocked = await go({ 'dl.acm.org/doi': () => html('<title>Just a moment...</title><div class="cf-turnstile"></div>', 403) }, 'https://dl.acm.org/doi/10.1145/1');
  assert.equal(blocked.kind === 'refused' && blocked.code, 'source_blocked');
  const challenged = await go({ 'openreview.net/forum': () => html('<title>Just a moment...</title><script src="/cdn-cgi/challenge-platform/x.js"></script>') }, 'https://openreview.net/forum?id=X');
  assert.equal(challenged.kind === 'refused' && challenged.code, 'source_blocked', 'a challenge served with 200');
  const login = await go({ 'publisher.example.com/a': () => new Response(null, { status: 302, headers: { location: 'https://idp.example.com/login?next=a' } }),
    'idp.example.com/login': () => html('<form><input type="password"></form>') }, 'https://publisher.example.com/a');
  assert.equal(login.kind === 'refused' && login.code, 'pdf_restricted');
  const busy = await go({ 'repo.example.org/p': () => new Response('busy', { status: 503 }) }, 'https://repo.example.org/p');
  assert.equal(busy.kind === 'refused' && busy.code, 'source_unavailable');
  const page = await go({ 'repo.example.org/p': () => html('<meta name="citation_title" content="A paper">') }, 'https://repo.example.org/p');
  assert.equal(page.kind, 'page');
});

const found = (paper: FoundPaper): FindResult => ({ status: 'found', paper });
function deps(routes: Routes, options: { findPaper?: AddPaperDeps['findPaper']; imported?: FoundPaper[]; calls?: string[] } = {}): AddPaperDeps {
  return {
    fetch: fetcher(routes, options.calls), resolveHost: publicDNS,
    findPaper: options.findPaper ?? (async () => ({ status: 'not_found' })),
    slot: async () => ({ reserved: true, wait_ms: 0 }),
    importPaper: async paper => { options.imported?.push(paper); return 'added'; },
  };
}
const work = (extra: Record<string, unknown>) => ({ id: 'https://openalex.org/W2963403868', doi: 'https://doi.org/10.1145/3292500.3330701', title: 'Optuna: A Next-generation Hyperparameter Optimization Framework',
  publication_year: 2019, authorships: [{ author: { display_name: 'Takuya Akiba' } }], locations: [], best_oa_location: null, ...extra });

test('a DOI: its arXiv copy, an open copy, or closed with its landing page; OpenAlex first, Crossref for the rest', async () => {
  const imported: FoundPaper[] = [];
  const arxiv = await addPaper(deps({ 'api.openalex.org/works/doi:': () => json(work({ locations: [{ landing_page_url: 'https://arxiv.org/abs/1907.10902', source: { display_name: 'arXiv' } }] })) }, { imported }),
    '10.1145/3292500.3330701', true, signal());
  assert.equal(arxiv.status, 'added'); assert.equal(arxiv.route, 'doi');
  assert.equal(imported[0].source_id, '1907.10902'); assert.equal(imported[0].kind, 'arxiv');

  const open = await addPaper(deps({ 'api.openalex.org/works/doi:': () => json(work({ best_oa_location: { pdf_url: 'https://repository.example.org/optuna.pdf', landing_page_url: 'https://repository.example.org/optuna', is_oa: true } })) }, { imported }),
    'https://doi.org/10.1145/3292500.3330701', true, signal());
  assert.equal(open.status, 'added'); assert.equal(open.paper?.kind, 'web'); assert.equal(open.paper?.source_id, 'openalex:W2963403868');
  assert.equal(open.paper?.host, 'repository.example.org');

  const closed = await addPaper(deps({ 'api.openalex.org/works/doi:': () => json(work({})) }), 'doi:10.1145/3292500.3330701', true, signal());
  assert.equal(closed.status, 'closed');
  assert.equal(closed.paper?.source_id, 'openalex:W2963403868', 'an upload can attach to the paper');
  assert.equal(closed.link, 'https://doi.org/10.1145/3292500.3330701', 'the device can try the landing page');

  // A journal DOI without an open copy, whose arXiv preprint the finder knows.
  const preprint = await addPaper(deps({ 'api.openalex.org/works/doi:': () => json(work({})) },
    { findPaper: async wanted => found({ source_id: '1907.10902', title: wanted.title, year: 2019, kind: 'arxiv' }) }), '10.1145/3292500.3330701', true, signal());
  assert.equal(preprint.status, 'added'); assert.equal(preprint.paper?.source_id, '1907.10902');

  // OpenAlex doesn't know it: Crossref names it, the finder looks for it by title.
  const crossref = await addPaper(deps({ 'api.openalex.org/works/doi:': () => json({}, 404),
    'api.crossref.org/works/10.5555': () => json({ message: { title: ['A Workshop Paper'], issued: { 'date-parts': [[2024]] }, author: [{ family: 'Doe' }] } }) }),
    '10.5555/workshop.1', true, signal());
  assert.equal(crossref.status, 'closed'); assert.equal(crossref.paper?.source_id, 'doi:10.5555/workshop.1');
  assert.equal(crossref.paper?.title, 'A Workshop Paper');
  const unknown = await addPaper(deps({ 'api.openalex.org/works/doi:': () => json({}, 404), 'api.crossref.org/works/': () => json({}, 404) }), '10.5555/nothing', true, signal());
  assert.equal(unknown.status, 'not_found');
  const down = await addPaper(deps({ 'api.openalex.org/works/doi:': () => json({}, 503), 'api.crossref.org/works/': () => json({}, 503) }), '10.5555/nothing', true, signal());
  assert.equal(down.status, 'unavailable');
});

test('a link: proceedings PDFs through their landing page, DOIs in the path, citation tags, or the device', async () => {
  const imported: FoundPaper[] = [];
  const pmlr = await addPaper(deps({
    'proceedings.mlr.press/v202/kirchenbauer23a.html': () => html('<meta name="citation_title" content="A Watermark for Large Language Models"><meta name="citation_pdf_url" content="https://proceedings.mlr.press/v202/kirchenbauer23a/kirchenbauer23a.pdf">'),
  }, { imported, findPaper: async wanted => found({ source_id: '2301.10226', title: wanted.title, year: 2023, kind: 'arxiv' }) }),
  'https://proceedings.mlr.press/v202/kirchenbauer23a/kirchenbauer23a.pdf', true, signal());
  assert.equal(pmlr.status, 'added'); assert.equal(pmlr.route, 'title'); assert.equal(imported[0].source_id, '2301.10226');

  // Not on arXiv or OpenAlex: the PDF the page declares, for the reader's device to fetch and upload.
  const workshop = await addPaper(deps({
    'proceedings.mlr.press/v202/kirchenbauer23a.html': () => html('<meta name="citation_title" content="A Watermark for Large Language Models"><meta name="citation_pdf_url" content="https://proceedings.mlr.press/v202/kirchenbauer23a/kirchenbauer23a.pdf">'),
  }), 'https://proceedings.mlr.press/v202/kirchenbauer23a/kirchenbauer23a.pdf', true, signal());
  assert.deepEqual({ status: workshop.status, link: workshop.link, title: workshop.title },
    { status: 'link_only', link: 'https://proceedings.mlr.press/v202/kirchenbauer23a/kirchenbauer23a.pdf', title: 'A Watermark for Large Language Models' });

  const plainPDF = await addPaper(deps({ 'files.example.org/draft.pdf': () => pdf() }), 'https://files.example.org/draft.pdf', true, signal());
  assert.deepEqual({ status: plainPDF.status, link: plainPDF.link }, { status: 'link_only', link: 'https://files.example.org/draft.pdf' });

  // A publisher page that challenges our servers: the DOI in its path still identifies the paper.
  const acm = await addPaper(deps({ 'api.openalex.org/works/doi:': () => json(work({})), 'dl.acm.org/doi': () => html('<title>Just a moment...</title>', 403, { 'cf-mitigated': 'challenge' }) }),
    'https://dl.acm.org/doi/10.1145/3292500.3330701', true, signal());
  assert.equal(acm.status, 'closed'); assert.equal(acm.paper?.source_id, 'openalex:W2963403868');

  // OpenReview challenges every automated request: blocked, and the device is offered the link.
  const openreview = await addPaper(deps({ 'openreview.net/forum': () => html('<title>Just a moment...</title>', 403, { 'cf-mitigated': 'challenge' }) }),
    'https://openreview.net/pdf?id=HPuSIXJaa9', true, signal());
  assert.deepEqual({ status: openreview.status, reason: openreview.reason, link: openreview.link },
    { status: 'blocked', reason: 'source_blocked', link: 'https://openreview.net/pdf?id=HPuSIXJaa9' });

  const citationDOI = await addPaper(deps({ 'www.example-journal.org/article/42': () => html('<meta name="citation_doi" content="10.1145/3292500.3330701">'),
    'api.openalex.org/works/doi:': () => json(work({ locations: [{ landing_page_url: 'https://arxiv.org/abs/1907.10902' }] })) }, { imported }),
  'https://www.example-journal.org/article/42', true, signal());
  assert.equal(citationDOI.status, 'added'); assert.equal(citationDOI.route, 'page');

  const nothing = await addPaper(deps({ 'blog.example.org/post': () => html('<title>My blog</title><p>hello</p>') }), 'https://blog.example.org/post', true, signal());
  assert.equal(nothing.status, 'not_found');
  const gone = await addPaper(deps({ 'repo.example.org/gone': () => new Response('', { status: 404 }) }), 'https://repo.example.org/gone', true, signal());
  assert.equal(gone.status, 'not_found');
});

test('arXiv input is queued directly; a reference goes through add-reference resolution; nonsense is invalid', async () => {
  const imported: FoundPaper[] = [];
  const arxiv = await addPaper(deps({}, { imported }), 'arXiv:2305.18290', true, signal());
  assert.equal(arxiv.status, 'added'); assert.equal(imported[0].source_id, '2305.18290');
  const reference = await addPaper(deps({ 'api.crossref.org/works': () => json({ message: { items: [] } }), 'api.openalex.org/works': () => json({ results: [] }) },
    { findPaper: async wanted => wanted.title.startsWith('Attention') ? found({ source_id: '1706.03762', title: 'Attention Is All You Need', year: 2017, kind: 'arxiv' }) : { status: 'not_found' } }),
  'A. Vaswani et al. Attention is all you need. In NeurIPS, 2017.', true, signal());
  assert.equal(reference.status, 'added'); assert.equal(reference.route, 'reference');
  assert.equal((await addPaper(deps({}), 'https://10.0.0.1/x.pdf', true, signal())).status, 'invalid');
  const failing = { ...deps({}, {}), importPaper: async () => 'failed' as const };
  assert.equal((await addPaper(failing, '2305.18290', true, signal())).status, 'failed');
});
