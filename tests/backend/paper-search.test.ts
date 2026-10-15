import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { arxivSearchRequests, BROAD_BELOW, dataciteSearchRequests, explainSearch, formEncode, parseArxivAtom, parseDataCiteSearch, planSearch,
  rankSearch, runSearch, SearchNotFound, type SearchRequest } from '../../supabase/functions/_shared/paper-search.ts';

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

test('the device asks arXiv for relevance, the oldest titles with the phrase, and any word only when short', () => {
  const plan = planSearch('direct preference optimization')!;
  const { requests, broad } = arxivSearchRequests(plan);
  assert.deepEqual(requests.map(r => r.role), ['relevance', 'phrase']);
  for (const r of [...requests, broad!]) assert.equal(new URL(r.url).origin + new URL(r.url).pathname, 'https://export.arxiv.org/api/query');
  assert.deepEqual(params(requests[0].url), { search_query: 'all:direct AND all:preference AND all:optimization', max_results: '50', sortBy: 'relevance', sortOrder: 'descending' });
  assert.deepEqual(params(requests[1].url), { search_query: 'ti:"direct preference optimization"', max_results: '3', sortBy: 'submittedDate', sortOrder: 'ascending' });
  assert.equal(params(broad!.url).search_query, 'all:direct OR all:preference OR all:optimization');
  assert.equal(params(arxivSearchRequests(planSearch('in-context learning')!).requests[0].url).search_query, 'all:"in-context" AND all:learning');
  assert.deepEqual(arxivSearchRequests(planSearch('2305.18290v3')!), { requests: [{ role: 'id', url: 'https://export.arxiv.org/api/query?id_list=2305.18290v3&max_results=1' }], broad: null });
  // One word: no phrase and no broader form.
  assert.deepEqual(arxivSearchRequests(planSearch('mamba')!).requests.map(r => r.role), ['relevance']);
  assert.equal(arxivSearchRequests(planSearch('mamba')!).broad, null);
});

test('the browser asks DataCite for arXiv records only, near spellings only when short, IDs by DOI', () => {
  const { requests, broad } = dataciteSearchRequests(planSearch('in-context learning')!);
  const relevance = params(requests[0].url);
  assert.equal(new URL(requests[0].url).origin, 'https://api.datacite.org');
  assert.equal(relevance.query, 'in\\-context learning');
  assert.equal(relevance['provider-id'], 'arxiv');
  assert.equal(relevance.sort, 'relevance');
  assert.equal(params(requests[1].url).query, 'titles.title:"in-context learning"');
  assert.equal(params(requests[1].url).sort, 'name', 'DOI order is arXiv numbering: oldest first');
  assert.equal(params(broad!.url).query, 'in\\-context learning~1');
  assert.equal(params(dataciteSearchRequests(planSearch('atention is all you ned')!).broad!.url).query, 'atention~1 all~1 you~1 ned~1');
  assert.deepEqual(dataciteSearchRequests(planSearch('arXiv:2305.18290')!).requests, [{ role: 'id', url: 'https://api.datacite.org/dois/10.48550/arXiv.2305.18290' }]);
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
    assert.deepEqual(ranked[0].factors, { relevance: 1, title: 2, field: 1.15, exact: 3, original: 2 }, engine);
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

test('runSearch: the broad request only when the strict one is short; a missing ID is no results; a failed search fails', async () => {
  const answers: Record<string, string> = {
    relevance: fixture('datacite-misspelling-relevance.json'), phrase: fixture('datacite-misspelling-phrase.json'), broad: fixture('datacite-misspelling-broad.json'),
  };
  const asked: SearchRequest[] = [];
  const results = await runSearch('datacite', 'difusion model distilation', async request => { asked.push(request); return answers[request.role]; });
  assert.deepEqual(asked.map(r => r.role), ['relevance', 'phrase', 'broad']);
  assert.ok(results.length > 0 && results.length <= 25);
  assert.ok(results.slice(0, 3).every(r => /distill/i.test(r.title) && /diffusion/i.test(r.title)));
  assert.ok(BROAD_BELOW > 0);

  const dpo: SearchRequest[] = [];
  await runSearch('arxiv', 'direct preference optimization', async request => { dpo.push(request); return fixture(`arxiv-dpo-${request.role}.xml`); });
  assert.deepEqual(dpo.map(r => r.role), ['relevance', 'phrase'], 'twelve strict results: no broad request');

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
