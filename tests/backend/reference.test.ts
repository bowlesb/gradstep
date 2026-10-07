import test from 'node:test';
import assert from 'node:assert/strict';
import { arxivIDs, candidateTitles, citationText, crossrefCandidates, dois, referenceYear, resolveReference, titleInReference, type ReferenceDeps } from '../../supabase/functions/_shared/reference.ts';
import type { FindResult } from '../../supabase/functions/_shared/chat.ts';

const palm = '[11] A. Chowdhery, S. Narang, J. Devlin, et al. Palm: Scaling language modeling with pathways. arXiv preprint arXiv:2204.02311, 2022.';
const eusipco = '3S. Gepshtein, A. Shtainman, and B. Fishbain, "Restoration of atmospheric turbulent video containing real motion using rank filtering and elastic image registration," in Proceedings of EUSIPCO, (Vienna, Austria) (2004).';
const book = 'Gerald E Farin. Curves and surfaces for CAGD: a practical guide. Morgan Kaufmann, 2002. 3';

test('reference parsing: arXiv ids, DOIs, citation text and the title check', () => {
  assert.deepEqual(arxivIDs(palm), ['2204.02311']);
  assert.deepEqual(arxivIDs('see arXiv:1706.03762v5 and 1706.03762'), ['1706.03762']);
  assert.deepEqual(arxivIDs('pages 1234.56789012'), []);
  assert.deepEqual(dois('J. Doe. A paper. Nature 521, 436 (2015). doi:10.1038/nature14539.'), ['10.1038/nature14539']);
  assert.deepEqual(dois('https://doi.org/10.1145/3292500.3330701)'), ['10.1145/3292500.3330701']);
  assert.equal(citationText('[24] D. P. Kingma. Adam. https://arxiv.org/abs/1412.6980 ICLR 2015'), 'D. P. Kingma. Adam. ICLR 2015');
  assert.ok(titleInReference('PaLM: Scaling Language Modeling with Pathways', palm));
  assert.ok(titleInReference('Restoration Of Atmospheric Turbulent Video Containing Real Motion Using Rank Filtering And Elastic Image Registration', eusipco));
  assert.ok(!titleInReference('Atmospheric turbulence mitigation with deep networks', eusipco), 'a different paper on the same topic is refused');
  assert.ok(!titleInReference('Adam', palm), 'one-word titles are never enough');
  const items = crossrefCandidates({ message: { items: [
    { DOI: '10.1/X', title: ['Curves and surfaces for CAGD'], author: [{ given: 'Gerald', family: 'Farin' }], issued: { 'date-parts': [[2002]] }, score: 88 },
    { title: ['no doi'] }] } });
  assert.deepEqual(items, [{ doi: '10.1/x', title: 'Curves and surfaces for CAGD', year: 2002, firstAuthor: 'Gerald Farin', score: 88 }]);
  assert.deepEqual(crossrefCandidates(null), []);
});

test('the title is read from common citation styles (authors, then title, then venue)', () => {
  const cases: [string, string][] = [
    ['[24] D. P. Kingma and J. Ba. Adam: A method for stochastic optimization. In ICLR, 2015.', 'Adam: A method for stochastic optimization'],
    ['N. Srivastava, G. Hinton, A. Krizhevsky, I. Sutskever, and R. Salakhutdinov. Dropout: a simple way to prevent neural networks from overfitting. JMLR, 15(1):1929–1958, 2014.', 'Dropout: a simple way to prevent neural networks from overfitting'],
    [eusipco, 'Restoration of atmospheric turbulent video containing real motion using rank filtering and elastic image registration'],
    ['Ashish Vaswani, Noam Shazeer, Niki Parmar, Jakob Uszkoreit, Llion Jones, Aidan N Gomez, Łukasz Kaiser, and Illia Polosukhin. Attention is all you need. In NeurIPS, 2017.', 'Attention is all you need'],
    ['He, K., Zhang, X., Ren, S., & Sun, J. (2016). Deep residual learning for image recognition. In CVPR (pp. 770-778).', 'Deep residual learning for image recognition'],
    ['Silver D, Huang A, Maddison CJ, et al. Mastering the game of Go with deep neural networks and tree search. Nature. 2016;529(7587):484-489.', 'Mastering the game of Go with deep neural networks and tree search'],
    [book, 'Curves and surfaces for CAGD: a practical guide'],
  ];
  for (const [reference, title] of cases) assert.equal(candidateTitles(reference)[0], title, reference);
  assert.equal(referenceYear(eusipco), 2004);
});

const atom = (id: string, title: string) => `<feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom"><entry><id>http://arxiv.org/abs/${id}v1</id><title>${title}</title>
  <published>2022-04-05T17:57:34Z</published><updated>2022-04-05T17:57:34Z</updated><author><name>Aakanksha Chowdhery</name></author>
  <summary>Abstract.</summary><category term="cs.CL"/></entry></feed>`;
const openAlexWork = (extra: Record<string, unknown>) => ({ id: 'https://openalex.org/W1572676502', doi: null, publication_year: 2004,
  title: 'Restoration Of Atmospheric Turbulent Video Containing Real Motion Using Rank Filtering And Elastic Image Registration',
  authorships: [{ author: { display_name: 'Shai Gepshtein' } }], locations: [], best_oa_location: null, ...extra });

function deps(routes: Record<string, (url: URL) => Response>, findPaper?: ReferenceDeps['findPaper']): ReferenceDeps & { calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    fetch: (async (input: string | URL) => {
      const url = new URL(String(input)); calls.push(url.hostname + url.pathname);
      const route = Object.entries(routes).find(([prefix]) => (url.hostname + url.pathname).startsWith(prefix));
      if (!route) throw new Error('unexpected ' + url.href);
      return route[1](url);
    }) as typeof fetch,
    slot: async () => ({ reserved: true, wait_ms: 0 }),
    findPaper: findPaper ?? (async (): Promise<FindResult> => ({ status: 'not_found' })),
  };
}
const json = (body: unknown) => new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json' } });

test('an arXiv id in the entry is used directly, but only when the title matches the entry', async () => {
  const ok = deps({ 'export.arxiv.org/api/query': () => new Response(atom('2204.02311', 'PaLM: Scaling Language Modeling with Pathways')) });
  const found = await resolveReference(ok, palm, true, new AbortController().signal);
  assert.equal(found.route, 'arxiv_id');
  assert.deepEqual(found.result, { status: 'found', paper: { source_id: '2204.02311', title: 'PaLM: Scaling Language Modeling with Pathways', year: 2022, kind: 'arxiv' } });
  assert.deepEqual(ok.calls, ['export.arxiv.org/api/query'], 'no citation search needed');
  // A mistyped id that resolves to another paper is not accepted; the entry falls through to Crossref.
  const wrong = deps({ 'export.arxiv.org/api/query': () => new Response(atom('2204.02311', 'Unrelated Protein Folding Results')),
    'api.crossref.org/works': () => json({ message: { items: [] } }), 'api.openalex.org/works': () => json({ results: [] }) });
  assert.equal((await resolveReference(wrong, palm, true, new AbortController().signal)).result.status, 'not_found');
});

test('Crossref matches the entry, then the finder looks for an open copy; a book with none is reported closed', async () => {
  const conference = deps({
    'api.crossref.org/works': () => json({ message: { items: [{ DOI: '10.5281/zenodo.38240', title: ['Restoration of atmospheric turbulent video containing real motion using rank filtering and elastic image registration'], author: [{ family: 'Gepshtein', given: 'S.' }], issued: { 'date-parts': [[2004]] }, score: 120 }] } }),
    'api.openalex.org/works/doi:': () => json(openAlexWork({ best_oa_location: { pdf_url: 'https://zenodo.org/record/38240', landing_page_url: 'https://zenodo.org/record/38240', is_oa: true } })),
  });
  const found = await resolveReference(conference, eusipco, true, new AbortController().signal);
  assert.equal(found.route, 'crossref');
  assert.equal(found.result.status, 'found');
  assert.equal(('paper' in found.result && found.result.paper.kind), 'web');
  // The same paper for a build that can't show web papers.
  assert.equal((await resolveReference(conference, eusipco, false, new AbortController().signal)).result.status, 'needs_update');

  const textbook = deps({
    'api.crossref.org/works': () => json({ message: { items: [{ DOI: '10.1016/b978-1-55860-737-8.x5000-5', title: ['Curves and Surfaces for CAGD'], author: [{ family: 'Farin' }], issued: { 'date-parts': [[2002]] }, score: 95 }] } }),
    'api.openalex.org/works/doi:': () => json({ ...openAlexWork({}), title: 'Curves and Surfaces for CAGD', locations: [] }),
  }, async () => ({ status: 'not_found' }));
  const closed = await resolveReference(textbook, book, true, new AbortController().signal);
  assert.equal(closed.result.status, 'closed');
});

test('without a citation match, OpenAlex search is accepted only for a title the entry contains; otherwise not found', async () => {
  const seen: string[] = [];
  const fallback = deps({
    'api.crossref.org/works': () => json({ message: { items: [{ DOI: '10.1/other', title: ['A completely different study'], score: 30 }] } }),
    'api.openalex.org/works': () => json({ results: [openAlexWork({ title: 'Palm: Scaling Language Modeling With Pathways', locations: [{ landing_page_url: 'https://arxiv.org/abs/2204.02311' }] })] }),
  }, async wanted => {
    seen.push(wanted.title);
    // Only OpenAlex's exact title is known to the (fake) finder: the entry's own title misses first.
    return wanted.title === 'Palm: Scaling Language Modeling With Pathways'
      ? { status: 'found', paper: { source_id: '2204.02311', title: wanted.title, year: 2022, kind: 'arxiv' } } : { status: 'not_found' };
  });
  const reference = 'A. Chowdhery et al. Palm: Scaling language modeling with pathways. JMLR 2023.';
  const found = await resolveReference(fallback, reference, true, new AbortController().signal);
  assert.equal(found.route, 'openalex'); assert.equal(found.result.status, 'found');
  assert.deepEqual(seen, ['Palm: Scaling language modeling with pathways', 'Palm: Scaling Language Modeling With Pathways'], 'the entry title first, then OpenAlex');
  const nothing = deps({ 'api.crossref.org/works': () => json({ message: { items: [] } }), 'api.openalex.org/works': () => json({ results: [] }) });
  assert.deepEqual(await resolveReference(nothing, 'Some Author. A paper nobody wrote about anything. 2031.', true, new AbortController().signal),
    { route: 'none', result: { status: 'not_found' } });
  const offline = deps({ 'api.crossref.org/works': () => new Response('down', { status: 503 }), 'api.openalex.org/works': () => new Response('down', { status: 503 }) },
    async () => ({ status: 'unavailable' }));
  assert.equal((await resolveReference(offline, 'Some Author. A paper nobody wrote. 2031.', true, new AbortController().signal)).result.status, 'unavailable');
});
