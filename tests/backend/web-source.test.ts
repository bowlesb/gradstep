import test from 'node:test';
import assert from 'node:assert/strict';
import { fetchOpenAlexWork, isPublicAddress, openAlexWork, openAlexWorkURL, openPDFLocations, publicHTTPS, WebSourceError } from '../../supabase/functions/_shared/web-source.ts';
import { runMetadataPipeline, type MetadataDeps } from '../../supabase/functions/_shared/metadata-pipeline.ts';

const permanent = (code: string) => (e: unknown) => e instanceof WebSourceError && e.permanent && e.code === code;
const transient = (code: string) => (e: unknown) => e instanceof WebSourceError && !e.permanent && e.code === code;

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

test('web metadata stage records OpenAlex metadata and locations, stops at source_only and never touches arXiv', async () => {
  const fetched: string[] = [], calls: string[] = [];
  const deps: MetadataDeps = {
    rpc: async <T>(name: string, params: Record<string, unknown> = {}): Promise<T> => {
      calls.push(name);
      if (name === 'worker_pipeline_policy') return { enabled: true } as T;
      if (name === 'worker_pipeline_claim') return { id: 'paper', stage: 'metadata', claim_id: 'claim', generation: 7, source_id: 'openalex:W1000000001',
        source_kind: 'web', requested_revision: 0, failures: 0 } as T;
      if (name === 'worker_pipeline_web_metadata') {
        assert.equal((params.p_metadata as { title: string }).title, 'Deep learning');
        assert.deepEqual(params.p_pdf_urls, ['https://repository.example.org/deep.pdf', 'https://jmlr.csail.mit.edu/papers/volume15/srivastava14a/srivastava14a.pdf',
          'https://mirror-a.example.net/deep.pdf']);
        assert.equal(params.p_landing_url, 'https://www.nature.com/articles/nature14539');
        assert.equal(params.p_doi, '10.1038/NATURE14539');
      }
      return null as T;
    },
    fetch: (async (url: string) => { fetched.push(url); return Response.json(work); }) as unknown as typeof fetch,
    sleep: async () => {}, now: () => 0, uuid: () => 'claim', log: () => {},
  };
  assert.deepEqual(await runMetadataPipeline(deps, 60_000), { processed: 1 });
  assert.ok(fetched.length > 0 && fetched.every(url => url.startsWith('https://api.openalex.org/works/W1000000001?')));
  // The recorded locations are for the reader's own device; no server download, split, OCR or asset stage follows.
  assert.deepEqual(calls, ['worker_pipeline_policy', 'worker_expire_stale_chat_operations', 'worker_pipeline_claim', 'worker_pipeline_web_metadata',
    'worker_pipeline_sync_imports', 'worker_pipeline_release']);
});
