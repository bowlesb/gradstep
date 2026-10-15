import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { arxivSearchRequests, BROAD_BELOW, dataciteSearchRequests, explainSearch, formEncode, KNOWN_CITATIONS, parseArxivAtom, parseDataCiteSearch,
  planSearch, rankSearch, runSearch, SearchNotFound, type SearchRequest } from '../../supabase/functions/_shared/paper-search.ts';

// Search without OpenAlex (docs/architecture/ARXIV_DEVICE_ONLY.md §5.6): the query builders, the two decoders and the
// explainable order. Answers recorded by scripts/search-eval.mjs on 2026-10-15 (tests/backend/fixtures/search/README.md).
const fixture = (name: string) => readFileSync(new URL(`./fixtures/search/${name}`, import.meta.url), 'utf8');
const params = (url: string) => Object.fromEntries(new URL(url).searchParams);

test('a query is an arXiv ID or link, or bounded words without index syntax', () => {
  for (const id of ['2305.18290', 'arXiv:2305.18290', 'https://arxiv.org/abs/2305.18290', 'arxiv.org/pdf/2305.18290.pdf']) {
    assert.deepEqual(planSearch(id), { kind: 'id', sourceID: '2305.18290', revision: null }, id);
  }
  assert.deepEqual(planSearch('https://arxiv.org/abs/2305.18290v3'), { kind: 'id', sourceID: '2305.18290', revision: 3 });
  assert.deepEqual(planSearch('hep-th/9711200'), { kind: 'id', sourceID: 'hep-th/9711200', revision: null });
  assert.deepEqual(planSearch('Attention Is All You Need'), { kind: 'text', text: 'Attention Is All You Need', words: ['attention', 'all', 'you', 'need'], phrase: 'attention is all you need' });
  // Query syntax and punctuation never reach an index; hyphenated words stay one word.
  const plan = planSearch('ti:"x" OR (in-context) AND* learning~2 \u0000');
  assert.deepEqual(plan, { kind: 'text', text: 'ti:"x" OR (in-context) AND* learning~2', words: ['ti', 'in-context', 'learning', '2'], phrase: 'ti or in-context and learning 2' });
  assert.equal(planSearch('   '), null);
  assert.equal(planSearch('a ! ?'), null);
  assert.equal((planSearch(Array.from({ length: 40 }, (_, i) => `term${i}`).join(' ')) as { words: string[] }).words.length, 12);
});

test('the device asks arXiv for relevance and the oldest titles with the phrase, DataCite for the most cited and near spellings', () => {
  const plan = planSearch('direct preference optimization')!;
  const { requests, broad } = arxivSearchRequests(plan);
  assert.deepEqual(requests.map(r => [r.role, r.source]), [['relevance', 'arxiv'], ['cited', 'datacite'], ['phrase', 'arxiv']]);
  for (const r of requests.filter(r => r.source === 'arxiv')) assert.equal(new URL(r.url).origin + new URL(r.url).pathname, 'https://export.arxiv.org/api/query');
  assert.deepEqual(params(requests[0].url), { search_query: 'all:direct AND all:preference AND all:optimization', max_results: '50', sortBy: 'relevance', sortOrder: 'descending' });
  assert.equal(params(requests[1].url).sort, '-citation-count');
  assert.equal(params(requests[1].url)['page[size]'], '10');
  assert.match(params(requests[1].url)['fields[dois]'], /citationCount/);
  assert.deepEqual(params(requests[2].url), { search_query: 'ti:"direct preference optimization"', max_results: '3', sortBy: 'submittedDate', sortOrder: 'ascending' });
  // arXiv's API has no near-spelling search: the device asks DataCite (tuning 1, ARXIV_DEVICE_ONLY.md §5.6.1).
  assert.equal(broad!.source, 'datacite');
  assert.equal(new URL(broad!.url).origin, 'https://api.datacite.org');
  assert.equal(params(broad!.url).query, 'direct~1 preference~1 optimization~1');
  assert.equal(params(arxivSearchRequests(planSearch('in-context learning')!).requests[0].url).search_query, 'all:"in-context" AND all:learning');
  assert.deepEqual(arxivSearchRequests(planSearch('2305.18290v3')!), { requests: [{ role: 'id', source: 'arxiv', url: 'https://export.arxiv.org/api/query?id_list=2305.18290v3&max_results=1' }], broad: null });
  // One word: no phrase.
  assert.deepEqual(arxivSearchRequests(planSearch('mamba')!).requests.map(r => r.role), ['relevance', 'cited']);
});

test('the browser asks DataCite for arXiv records only, near spellings only when short, IDs by DOI', () => {
  const { requests, broad } = dataciteSearchRequests(planSearch('in-context learning')!);
  const relevance = params(requests[0].url);
  assert.equal(new URL(requests[0].url).origin, 'https://api.datacite.org');
  assert.equal(relevance.query, 'in\\-context learning');
  assert.equal(relevance['provider-id'], 'arxiv');
  assert.equal(relevance.sort, 'relevance');
  assert.deepEqual(requests.map(r => [r.role, r.source]), [['relevance', 'datacite'], ['cited', 'datacite'], ['phrase', 'datacite']]);
  assert.equal(params(requests[1].url).query, 'in\\-context learning');
  assert.equal(params(requests[1].url).sort, '-citation-count');
  assert.equal(params(requests[2].url).query, 'titles.title:"in-context learning"');
  assert.equal(params(requests[2].url).sort, 'name', 'DOI order is arXiv numbering: oldest first');
  assert.equal(params(broad!.url).query, 'in\\-context learning~1');
  assert.equal(params(dataciteSearchRequests(planSearch('atention is all you ned')!).broad!.url).query, 'atention~1 all~1 you~1 ned~1');
  assert.equal(dataciteSearchRequests(planSearch('4o 7b')!).broad, null, 'nothing to spell differently');
  assert.deepEqual(dataciteSearchRequests(planSearch('arXiv:2305.18290')!).requests, [{ role: 'id', source: 'datacite', url: 'https://api.datacite.org/dois/10.48550/arXiv.2305.18290' }]);
});

test('URLs are encoded byte for byte as URLSearchParams would (JavaScriptCore has no URL APIs)', () => {
  const sample = { q: 'ti:"a b" AND (c) ~*!\'', z: 'é 漢 + & = / %' };
  assert.equal(formEncode(sample), new URLSearchParams(sample).toString());
});

test('arXiv Atom answers decode to the discover contract; an empty answer is empty', () => {
  const results = parseArxivAtom(fixture('arxiv-dpo-phrase.xml'));
  assert.equal(results.length, 3);
  const dpo = results[0];
  assert.equal(dpo.source_id, '2305.18290');
  assert.equal(dpo.revision, 3);
  assert.equal(dpo.title, 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model');
  assert.equal(dpo.authors[0], 'Rafael Rafailov');
  assert.ok(dpo.authors.length <= 9);
  assert.equal(dpo.year, 2023);
  assert.equal(dpo.categories[0], 'cs.LG');
  assert.ok(dpo.abstract!.length <= 700 && dpo.full_abstract!.startsWith(dpo.abstract!.slice(0, 100)));
  assert.equal(dpo.abstract_truncated, false);
  assert.ok(dpo.topics.length > 0);
  assert.equal(parseArxivAtom(fixture('arxiv-dpo-relevance.xml')).length, 12);
  assert.deepEqual(parseArxivAtom(fixture('arxiv-misspelling-relevance.xml')), []);
  assert.throws(() => parseArxivAtom('<html>not a feed</html>'), /invalid_feed/);
  assert.throws(() => parseArxivAtom('<?xml version="1.0"?><!DOCTYPE feed [<!ENTITY x "y">]><feed></feed>'), /invalid_feed/);
});

test('DataCite answers decode to the same contract: latest version, first-version year, arXiv subjects', () => {
  const results = parseDataCiteSearch(JSON.parse(fixture('datacite-dpo-phrase.json')));
  assert.equal(results[0].source_id, '2305.18290');
  assert.equal(results[0].revision, 3);
  assert.equal(results[0].year, 2023);
  assert.deepEqual(results[0].categories.slice(0, 2), ['cs.LG', 'cs.AI']);
  assert.equal(parseDataCiteSearch(JSON.parse(fixture('datacite-dpo-relevance.json'))).length, 12);
  assert.equal(parseDataCiteSearch(JSON.parse(fixture('datacite-id-id.json')))[0].source_id, '2305.18290');
  assert.deepEqual(parseDataCiteSearch(JSON.parse(fixture('datacite-misspelling-relevance.json'))), []);
  assert.deepEqual(parseDataCiteSearch({ data: [{ attributes: { doi: '10.1234/not-arxiv' } }, null, 7] }), []);
  // A broken character in an abstract becomes U+FFFD; the preview never ends half a character.
  const record = JSON.parse(fixture('datacite-id-id.json'));
  const description = record.data.attributes.descriptions.find((d: { descriptionType: string }) => d.descriptionType === 'Abstract');
  description.description = `${'x'.repeat(699)}😀 lone \ud800 end`;
  const odd = parseDataCiteSearch(record)[0];
  assert.equal(odd.abstract, 'x'.repeat(699));
  assert.ok(odd.full_abstract!.includes('lone � end') && odd.full_abstract!.includes('😀'));
});

test('the order: the original paper first, each factor named, every engine the same', () => {
  for (const [engine, relevance, phrase, parse] of [
    ['arxiv', 'arxiv-dpo-relevance.xml', 'arxiv-dpo-phrase.xml', parseArxivAtom],
    ['datacite', 'datacite-dpo-relevance.json', 'datacite-dpo-phrase.json', (t: string) => parseDataCiteSearch(JSON.parse(t))],
  ] as const) {
    const plan = planSearch('direct preference optimization')!;
    const ranked = explainSearch(plan, { relevance: parse(fixture(relevance)), phrase: parse(fixture(phrase)) });
    assert.equal(ranked[0].result.source_id, '2305.18290', engine);
    // Its main title is the query (exact ×3) and the earliest paper titled with the phrase (original ×2).
    assert.deepEqual({ ...ranked[0].factors, known: 1 }, { relevance: 1, title: 2, field: 1.15, exact: 3, original: 2, known: 1 }, engine);
    assert.ok(ranked.every(r => !('citations' in r.result)), 'citation counts never leave the order');
    assert.ok(ranked.every((r, i) => i === 0 || r.score <= ranked[i - 1].score));
    assert.equal(new Set(ranked.map(r => r.result.source_id)).size, ranked.length, 'no paper twice');
  }
  // An exact title triples; a paper outside computing and statistics weighs less.
  const paper = (id: string, title: string, categories: string[]) => ({ source_id: id, revision: 1, title, authors: ['A'], year: 2020, abstract: null,
    full_abstract: null, abstract_truncated: false, categories, topics: [] });
  const plan = planSearch('scaling laws')!;
  const order = rankSearch(plan, { relevance: [paper('2101.00001', 'Scaling laws in physics', ['physics.gen-ph']), paper('2101.00002', 'Scaling laws in learning', ['cs.LG']),
    paper('2101.00003', 'Scaling Laws', ['cs.LG'])] });
  assert.deepEqual(order.map(r => r.source_id), ['2101.00003', '2101.00002', '2101.00001']);
  assert.deepEqual(rankSearch(planSearch('2305.18290')!, { id: parseArxivAtom(fixture('arxiv-id-id.xml')) }).map(r => r.source_id), ['2305.18290']);
});

test('well known (rule 6): DataCite\'s most cited match the words missed joins when it is about the query, and cited papers gain', () => {
  const plan = planSearch('vision transformer')!;
  const cited = parseDataCiteSearch(JSON.parse(fixture('vit-datacite-cited.json')));
  const vit = cited.find(r => r.source_id === '2010.11929')!;
  assert.equal(vit.citations, 16);
  const relevance = parseArxivAtom(fixture('vit-arxiv-relevance.xml'));
  assert.ok(!relevance.some(r => r.source_id === '2010.11929'), 'arXiv\'s word matching misses ViT');
  const ranked = explainSearch(plan, { relevance, phrase: parseArxivAtom(fixture('vit-arxiv-phrase.xml')), cited });
  const at = ranked.findIndex(r => r.result.source_id === '2010.11929');
  assert.ok(at >= 0 && at <= 1, `An Image is Worth 16x16 Words is in the first two (at ${at})`);
  assert.equal(ranked[at].factors.known, 1 + Math.log2(17) / 4);
  // Well cited but not about the query (titles without its words, no phrase in the abstract): not admitted.
  for (const r of cited.filter(r => (r.citations ?? 0) >= KNOWN_CITATIONS && !/vision|transformer/i.test(r.title))) {
    assert.ok(!ranked.some(x => x.result.source_id === r.source_id), r.title);
  }
  // Without the most cited list the order is rules 1–5 alone.
  assert.ok(explainSearch(plan, { relevance }).every(r => r.factors.known === 1));
  // A paper cited once gains nothing; a match the words already found keeps its place and gains.
  const paper = (id: string, title: string, citations?: number) => ({ source_id: id, revision: 1, title, authors: ['A'], year: 2021, abstract: null, full_abstract: null,
    abstract_truncated: false, categories: ['cs.CV'], topics: [], ...(citations === undefined ? {} : { citations }) });
  const order = explainSearch(plan, { relevance: [paper('2101.00001', 'A vision transformer for X', 1), paper('2101.00002', 'Another vision transformer', 9)] });
  assert.deepEqual(order.map(r => [r.result.source_id, Number(r.factors.known.toFixed(3))]), [['2101.00002', 1.83], ['2101.00001', 1]]);
});

test('runSearch: the broad request only when the strict one is short; a missing ID is no results; a failed search fails', async () => {
  const answers: Record<string, string> = {
    relevance: fixture('datacite-misspelling-relevance.json'), phrase: fixture('datacite-misspelling-phrase.json'), broad: fixture('datacite-misspelling-broad.json'),
  };
  const asked: SearchRequest[] = [];
  const results = await runSearch('datacite', 'difusion model distilation', async request => { asked.push(request); return answers[request.role] ?? '{"data":[]}'; });
  assert.deepEqual(asked.map(r => r.role), ['relevance', 'cited', 'phrase', 'broad']);
  assert.ok(results.length > 0 && results.length <= 25);
  assert.ok(results.slice(0, 3).every(r => /distill/i.test(r.title) && /diffusion/i.test(r.title)));
  assert.ok(BROAD_BELOW > 0);

  const dpo: SearchRequest[] = [];
  await runSearch('arxiv', 'direct preference optimization', async request => { dpo.push(request);
    return request.source === 'datacite' ? '{"data":[]}' : fixture(`arxiv-dpo-${request.role}.xml`); });
  assert.deepEqual(dpo.map(r => r.role), ['relevance', 'cited', 'phrase'], 'twelve strict results: no broad request');
  // The device's misspelling: arXiv finds nothing, so DataCite's near spellings are asked (tuning 1).
  const native: SearchRequest[] = [];
  const misspelled = await runSearch('arxiv', 'difusion model distilation', async request => {
    native.push(request);
    if (request.role === 'broad') return fixture('datacite-misspelling-broad.json');
    return request.source === 'datacite' ? '{"data":[]}' : fixture(`arxiv-misspelling-${request.role}.xml`);
  });
  assert.deepEqual(native.map(r => [r.role, r.source]), [['relevance', 'arxiv'], ['cited', 'datacite'], ['phrase', 'arxiv'], ['broad', 'datacite']]);
  assert.ok(misspelled.slice(0, 3).every(r => /distill/i.test(r.title) && /diffusion/i.test(r.title)));
  // A failed cited request leaves the others.
  assert.equal((await runSearch('arxiv', 'direct preference optimization', async request => {
    if (request.role === 'cited') throw new Error('datacite_unavailable');
    return fixture(`arxiv-dpo-${request.role}.xml`);
  }))[0].source_id, '2305.18290');

  assert.deepEqual(await runSearch('datacite', '2399.99999', async () => { throw new SearchNotFound(); }), []);
  await assert.rejects(runSearch('arxiv', 'speculative decoding', async () => { throw new Error('arxiv_503'); }), /arxiv_503/);
  // A failed phrase request leaves the relevance results.
  const partial = await runSearch('arxiv', 'direct preference optimization', async request => {
    if (request.role === 'phrase') throw new Error('timeout');
    return fixture('arxiv-dpo-relevance.xml');
  });
  assert.equal(partial.length, 12);
  assert.deepEqual(await runSearch('arxiv', ' ', async () => { throw new Error('never asked'); }), []);
});
