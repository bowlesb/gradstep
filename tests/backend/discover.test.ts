// Server-side paper lookups without arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md, rollout steps 5–7): the shared result
// row's abstract bounds, strict citation matching, OpenAlex candidates, and DataCite lookups by arXiv DOI and by title,
// answered from recorded DataCite responses (tests/backend/fixtures/lookup).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dataciteIDURL, dataciteTitleURLs, discoveryAbstract, lookupDataCite, matchPaper, openAlexCandidates, openAlexFindURL, titleSimilarity }
  from '../../supabase/functions/_shared/discover.ts';

const recorded = (name: string) => readFileSync(new URL(`fixtures/lookup/${name}`, import.meta.url), 'utf8');
/** A fetch that answers DataCite URLs from recordings and refuses everything else (arXiv above all). */
function dataciteFetch(answers: Record<string, string | number>, seen: string[] = []): typeof fetch {
  return (async (input: RequestInfo | URL) => {
    const url = String(input);
    seen.push(url);
    if (new URL(url).hostname !== 'api.datacite.org') throw new Error(`unexpected host ${new URL(url).hostname}`);
    const answer = answers[url];
    if (answer === undefined) throw new Error(`unrecorded ${url}`);
    return typeof answer === 'number' ? new Response('{}', { status: answer }) : new Response(answer, { status: 200, headers: { 'content-type': 'application/vnd.api+json' } });
  }) as typeof fetch;
}

test('abstracts: previews stay at 700 characters for older clients; full abstracts are opt-in and bounded', () => {
  const long = 'λ'.repeat(24_001);
  assert.deepEqual(discoveryAbstract(long, true), { abstract: long.slice(0, 700), full_abstract: long.slice(0, 24_000), abstract_truncated: true });
  assert.deepEqual(discoveryAbstract(long), { abstract: long.slice(0, 700) }, 'old client payload unchanged');
  assert.deepEqual(discoveryAbstract(null, true), { abstract: null, full_abstract: null, abstract_truncated: false });
  for (const limit of [700, 24_000]) {
    const mathematical = 'x'.repeat(limit - 1) + '𝛼';
    const result = discoveryAbstract(mathematical, true);
    const bounded = limit === 700 ? result.abstract : result.full_abstract;
    assert.equal(bounded, 'x'.repeat(limit - 1), 'Never emit half a mathematical Unicode character to Swift');
    assert.ok(bounded!.isWellFormed());
  }
});

test('DataCite title lookups: the earliest papers titled with the phrase, then every title word; no query syntax passes', () => {
  const urls = dataciteTitleURLs('Direct Preference Optimization: Your Language Model is Secretly a Reward Model');
  assert.equal(urls.length, 2);
  const [phrase, words] = urls.map(u => new URL(u));
  for (const url of [phrase, words]) {
    assert.equal(url.origin, 'https://api.datacite.org');
    assert.equal(url.searchParams.get('provider-id'), 'arxiv');
  }
  assert.equal(phrase.searchParams.get('query'), 'titles.title:"direct preference optimization your language model is secretly a reward model"');
  assert.equal(phrase.searchParams.get('sort'), 'name');
  assert.equal(words.searchParams.get('query'), 'titles.title:(direct AND preference AND optimization AND your AND language AND model AND secretly AND reward AND model)');
  assert.equal(words.searchParams.get('sort'), 'relevance');
  assert.deepEqual(dataciteTitleURLs('Adam'), []);
  assert.equal(new URL(dataciteTitleURLs('A "quoted" title) OR (x:*')[0]).searchParams.get('query'), 'titles.title:"a quoted title or x"');
});

test('DataCite ID lookups: one record by its DOI, several in one request, invalid identifiers dropped', () => {
  assert.equal(dataciteIDURL(['1706.03762']), 'https://api.datacite.org/dois/10.48550/arXiv.1706.03762');
  const batch = new URL(dataciteIDURL(['2201.11903', '2305.18290', '2201.11903', 'not an id'])!);
  assert.equal(batch.searchParams.get('ids'), '10.48550/arXiv.2201.11903,10.48550/arXiv.2305.18290');
  assert.equal(dataciteIDURL(['nope']), null);
  assert.equal(dataciteIDURL([]), null);
});

test('recorded DataCite answers become result rows: by DOI, in a batch and by title; a missing DOI is no result', async () => {
  const one = dataciteIDURL(['1706.03762'])!, both = dataciteIDURL(['2201.11903', '2305.18290'])!;
  const [phrase, words] = dataciteTitleURLs('Direct Preference Optimization: Your Language Model is Secretly a Reward Model');
  const missing = dataciteIDURL(['2610.99999'])!;
  const seen: string[] = [];
  const fetcher = dataciteFetch({ [one]: recorded('datacite-id-1706.03762.json'), [both]: recorded('datacite-ids-cot-dpo.json'),
    [phrase]: recorded('datacite-title-dpo-phrase.json'), [words]: recorded('datacite-title-dpo-words.json'), [missing]: 404 }, seen);
  const attention = await lookupDataCite([one], fetcher);
  assert.deepEqual(attention.map(r => [r.source_id, r.revision, r.title, r.year, r.authors[0]]), [['1706.03762', 7, 'Attention Is All You Need', 2017, 'Ashish Vaswani']]);
  assert.equal('topics' in attention[0] || 'citations' in attention[0], false, 'the server row, not the search row');
  assert.deepEqual((await lookupDataCite([both], fetcher)).map(r => r.source_id).sort(), ['2201.11903', '2305.18290']);
  const titled = await lookupDataCite([phrase, words, missing], fetcher);
  assert.deepEqual(titled.map(r => r.source_id), ['2305.18290'], 'in order, without duplicates; the 404 adds nothing');
  assert.equal(matchPaper({ title: 'Direct preference optimization: your language model is secretly a reward model', year: 2023, firstAuthor: 'R. Rafailov', arxivID: null },
    titled)?.source_id, '2305.18290');
  assert.ok(seen.every(url => url.startsWith('https://api.datacite.org/')), 'only DataCite was asked');
  await assert.rejects(lookupDataCite([one], dataciteFetch({ [one]: 503 })), /datacite_unavailable/, 'a busy DataCite is a failure, never retried here');
});

test('ingest matching needs title, year window, first author and no negation difference', () => {
  assert.equal(titleSimilarity('Attention Is All You Need', 'Attention is all you need.'), 1);
  const q = (title: string, year: number | null, firstAuthor: string | null, arxivID: string | null = null) => ({ title, year, firstAuthor, arxivID });
  const attention = [
    { source_id: '2405.00001', title: 'Attention Is Not All You Need', year: 2024, authors: ['A. Other'] },
    { source_id: '1706.03762', title: 'Attention Is All You Need', year: 2017, authors: ['Ashish Vaswani', 'Noam Shazeer'] },
  ];
  assert.equal(matchPaper(q('Attention is all you need', 2017, 'A. Vaswani'), attention)?.source_id, '1706.03762');
  assert.equal(matchPaper(q('Attention mechanisms survey', null, null), attention), null);
  // Negation, wrong author and implausible year are rejected.
  const reasoners = [{ source_id: '2401.1', title: 'Large Language Models are not Zero-Shot Reasoners', year: 2024, authors: ['X. Y'] }];
  assert.equal(matchPaper(q('Large Language Models are Zero-Shot Reasoners', 2022, 'T. Kojima'), reasoners), null);
  const ppo = [{ source_id: '1707.06347', title: 'Proximal Policy Optimization Algorithms', year: 2017, authors: ['John Schulman', 'Filip Wolski'] }];
  assert.equal(matchPaper(q('Proximal policy optimization algorithms', 2017, 'J. Schulman'), ppo)?.source_id, '1707.06347');
  assert.equal(matchPaper(q('Proximal policy optimization algorithms', 2017, 'Schulman, John'), ppo)?.source_id, '1707.06347');
  assert.equal(matchPaper(q('Proximal policy optimization algorithms', 2017, 'R. Sutton'), ppo), null);
  assert.equal(matchPaper(q('Proximal policy optimization algorithms', 2022, 'J. Schulman'), ppo), null);
  // Without an author the title must be exact.
  assert.equal(matchPaper(q('Proximal policy optimization algorithm', null, null), ppo), null);
  assert.equal(matchPaper(q('Proximal Policy Optimization Algorithms', null, null), ppo)?.source_id, '1707.06347');
  // A citation without the subtitle matches an exact main title of 3+ words.
  const dpo = [{ source_id: '2305.18290', title: 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model', year: 2023, authors: ['Rafael Rafailov'] }];
  assert.equal(matchPaper(q('Direct Preference Optimization', 2023, 'R. Rafailov'), dpo)?.source_id, '2305.18290');
  assert.equal(matchPaper(q('Preference Optimization', 2023, 'R. Rafailov'), dpo), null);
  // Short titles need author and year (or the id); "Deep Learning" 2015 is not a 2018 namesake.
  const deep = [{ source_id: '1801.1', title: 'Deep Learning', year: 2018, authors: ['Someone Else'] }];
  assert.equal(matchPaper(q('Deep learning', 2015, 'Y. LeCun'), deep), null);
  assert.equal(matchPaper(q('Deep learning', null, null), deep), null);
  assert.equal(matchPaper(q('Adam: A Method for Stochastic Optimization', 2015, 'D. P. Kingma'),
    [{ source_id: '1412.6980', title: 'Adam: A Method for Stochastic Optimization', year: 2014, authors: ['Diederik P. Kingma', 'Jimmy Ba'] }])?.source_id, '1412.6980');
});


test('Ingest finds an arXiv copy or an open-access PDF through OpenAlex', () => {
  const url = new URL(openAlexFindURL({ title: 'Deep Residual Learning for Image Recognition', year: 2016, firstAuthor: 'Kaiming He', arxivID: null })!);
  assert.equal(url.searchParams.get('search'), 'Deep Residual Learning for Image Recognition');
  assert.equal(url.searchParams.get('filter'), 'publication_year:2015-2017');
  assert.equal(openAlexFindURL({ title: '..', year: null, firstAuthor: null, arxivID: null }), null);
  const candidates = openAlexCandidates({ results: [
    { id: 'https://openalex.org/W2194775991', doi: 'https://doi.org/10.1109/cvpr.2016.90', title: 'Deep Residual Learning for Image Recognition', publication_year: 2016,
      authorships: [{ author: { display_name: 'Kaiming He' } }], best_oa_location: { pdf_url: 'https://arxiv.org/pdf/1512.03385', license: null },
      locations: [{ landing_page_url: 'https://doi.org/10.1109/cvpr.2016.90' }, { landing_page_url: 'https://arxiv.org/abs/1512.03385' }] },
    { id: 'https://openalex.org/W3000000001', doi: 'https://doi.org/10.18653/v1/2020.acl-main.1', title: 'An ACL Paper Without arXiv', publication_year: 2020,
      authorships: [{ author: { display_name: 'Ada Lovelace' } }], best_oa_location: { pdf_url: 'https://aclanthology.org/2020.acl-main.1.pdf', landing_page_url: 'https://aclanthology.org/2020.acl-main.1', license: 'cc-by' },
      locations: [] },
    { id: 'https://openalex.org/W3000000002', title: 'Paywalled', publication_year: 2019, authorships: [], best_oa_location: null, locations: [] },
    { id: 'not-openalex', title: 'Bad id' },
  ] });
  assert.equal(candidates.length, 3);
  assert.deepEqual([candidates[0].arxivID, candidates[0].source_id, candidates[0].doi], ['1512.03385', '1512.03385', '10.1109/cvpr.2016.90']);
  assert.deepEqual([candidates[1].arxivID, candidates[1].source_id, candidates[1].pdfURL, candidates[1].license],
    [null, 'W3000000001', 'https://aclanthology.org/2020.acl-main.1.pdf', 'cc-by']);
  assert.deepEqual([candidates[2].pdfURL, candidates[2].landingURL], [null, null]);
  assert.equal(matchPaper({ title: 'Deep residual learning for image recognition', year: 2016, firstAuthor: 'K. He', arxivID: null }, candidates)?.arxivID, '1512.03385');
});
