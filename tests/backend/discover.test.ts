import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { discoveryAbstract } from '../../supabase/functions/_shared/discover.ts';
import { arxivIDListURL, arxivRecentURL, arxivTitleURLs, exactTitleMatches, matchPaper, openAlexArxivWorkURL, openAlexCandidates, openAlexFindURL, openAlexResult, openAlexSearchURLs, orderByRanking, parseArxivRSS, arxivSearchURL, arxivSearchURLs, mergeDiscovery, parseArxivSearch, rankOpenAlex, titleSimilarity } from '../../supabase/functions/_shared/discover.ts';

test('search URLs: ids look up one paper, text matches all words, junk is refused', () => {
  assert.match(arxivSearchURL('https://arxiv.org/abs/2305.18290v3')!, /id_list=2305.18290v3&max_results=1/);
  assert.match(arxivSearchURL('2106.09685')!, /id_list=2106.09685&/);
  const text = new URL(arxivSearchURL('  Direct preference   optimization!! ')!);
  assert.equal(text.searchParams.get('search_query'), 'all:direct AND all:preference AND all:optimization');
  assert.equal(text.hostname, 'export.arxiv.org');
  assert.equal(arxivSearchURL('   '), null);
  assert.equal(arxivSearchURL('!!! ?'), null);
});

test('parses a real arXiv Atom feed into compact results', () => {
  const results = parseArxivSearch(new Uint8Array(readFileSync(new URL('../fixtures/arxiv/2305.18290-atom.xml', import.meta.url))));
  assert.equal(results.length, 1);
  assert.equal(results[0].source_id, '2305.18290'); assert.equal(results[0].revision, 3);
  assert.match(results[0].title, /^Direct Preference Optimization/);
  assert.equal(results[0].year, 2023);
  assert.ok(results[0].authors.length >= 1 && results[0].abstract!.length <= 700);
});

test('full abstracts are opt-in, preserve the end of real metadata, and mark oversized excerpts', () => {
  const bytes = new Uint8Array(readFileSync(new URL('../fixtures/arxiv/2305.18290-atom.xml', import.meta.url)));
  const legacy = parseArxivSearch(bytes)[0], full = parseArxivSearch(bytes, true)[0];
  assert.ok(full.full_abstract!.length > 700);
  assert.ok(full.full_abstract!.endsWith('.'));
  assert.equal(full.abstract, legacy.abstract);
  assert.equal(full.abstract_truncated, false);
  assert.equal('full_abstract' in legacy, false, 'old client payload unchanged');
  const rss = new Uint8Array(readFileSync(new URL('../fixtures/arxiv/rss-cs.LG-sample.xml', import.meta.url)));
  assert.ok(parseArxivRSS(rss, 25, true).every(r => r.full_abstract?.startsWith(r.abstract ?? '') ?? r.abstract === null));
  const long = 'λ'.repeat(24_001);
  assert.deepEqual(discoveryAbstract(long, true), { abstract: long.slice(0, 700), full_abstract: long.slice(0, 24_000), abstract_truncated: true });
  assert.deepEqual(discoveryAbstract(null, true), { abstract: null, full_abstract: null, abstract_truncated: false });
  for (const limit of [700, 24_000]) {
    const mathematical = 'x'.repeat(limit - 1) + '𝛼';
    const result = discoveryAbstract(mathematical, true);
    const bounded = limit === 700 ? result.abstract : result.full_abstract;
    assert.equal(bounded, 'x'.repeat(limit - 1), 'Never emit half a mathematical Unicode character to Swift');
    assert.ok(bounded!.isWellFormed());
  }
  const incomplete = openAlexResult({ title: 'Long source', locations: [{ landing_page_url: 'https://arxiv.org/abs/2305.18290' }],
    abstract_inverted_index: { x: Array.from({ length: 5001 }, (_, i) => i) } }, true)!;
  assert.equal(incomplete.abstract_truncated, true, 'Upstream reconstruction limits are excerpts, even below the character cap');
});

test('rejects non-feed XML and skips malformed entries', () => {
  assert.throws(() => parseArxivSearch(new TextEncoder().encode('<html/>')));
  const feed = '<feed xmlns="http://www.w3.org/2005/Atom"><entry><id>not-an-id</id><title>x</title></entry></feed>';
  assert.deepEqual(parseArxivSearch(new TextEncoder().encode(feed)), []);
});

test('multi-word searches add an oldest-first title phrase query and merge without duplicates', () => {
  const urls = arxivSearchURLs('Direct Preference Optimization');
  assert.equal(urls.length, 2);
  const phrase = new URL(urls[0]);
  assert.equal(phrase.searchParams.get('search_query'), 'ti:"direct preference optimization"');
  assert.equal(phrase.searchParams.get('sortOrder'), 'ascending');
  assert.equal(arxivSearchURLs('2305.18290').length, 1);
  assert.equal(arxivSearchURLs('mamba').length, 1);
  const r = (id: string) => ({ source_id: id, revision: 1, title: id, authors: [], year: null, abstract: null, categories: [] });
  assert.deepEqual(mergeDiscovery([[r('a'), r('b')], [r('b'), r('c')]]).map(x => x.source_id), ['a', 'b', 'c']);
});

test('feed URLs use the daily RSS for a validated category', () => {
  assert.equal(arxivRecentURL('cs.LG'), 'https://rss.arxiv.org/rss/cs.LG');
  assert.ok(arxivRecentURL('stat.ML') && arxivRecentURL('hep-th') && arxivRecentURL('math.OC'));
  for (const bad of ['cs.LG OR all:x', '', 'CS.lg', 'cs.LG&x=1']) assert.equal(arxivRecentURL(bad), null, bad);
});

test('parses new announcements from a real arXiv RSS sample', () => {
  const results = parseArxivRSS(new Uint8Array(readFileSync(new URL('../fixtures/arxiv/rss-cs.LG-sample.xml', import.meta.url))));
  assert.ok(results.length >= 1);
  assert.match(results[0].source_id, /^\d{4}\.\d{4,5}$/);
  assert.ok(results[0].title.length > 5 && results[0].revision >= 1 && results[0].authors.length >= 1);
  assert.ok(!results[0].abstract!.startsWith('arXiv:'));
  assert.throws(() => parseArxivRSS(new TextEncoder().encode('<!DOCTYPE x><rss></rss>')));
});

test('ingest title lookups: optional id, then title phrase and title words', () => {
  const urls = arxivTitleURLs('Direct Preference Optimization: Your Language Model is Secretly a Reward Model', 'arXiv:2305.18290v2');
  assert.equal(urls.length, 3);
  assert.equal(new URL(urls[0]).searchParams.get('id_list'), '2305.18290');
  assert.equal(new URL(urls[1]).searchParams.get('search_query'), 'ti:"direct preference optimization your language model is secretly a reward model"');
  assert.equal(new URL(urls[2]).searchParams.get('search_query'), 'ti:direct AND ti:preference AND ti:optimization AND ti:your AND ti:language AND ti:model AND ti:secretly AND ti:reward AND ti:model');
  assert.equal(arxivTitleURLs('Adam', 'not an id').length, 0);
  assert.ok(arxivTitleURLs('Adam: A Method', 'not an id').every(url => !new URL(url).searchParams.has('id_list')));
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

test('topic search: OpenAlex relevance and citations decide, ML papers and exact titles lead', () => {
  const [relevantURL, citedURL] = openAlexSearchURLs('CNN').map(u => new URL(u));
  assert.equal(relevantURL.hostname, 'api.openalex.org');
  assert.equal(relevantURL.searchParams.get('search'), 'CNN');
  assert.equal(relevantURL.searchParams.get('filter'), 'locations.source.id:S4306400194');
  assert.equal(citedURL.searchParams.get('filter'), 'locations.source.id:S4306400194,title_and_abstract.search:CNN');
  assert.equal(citedURL.searchParams.get('sort'), 'cited_by_count:desc');
  assert.deepEqual(openAlexSearchURLs('2305.18290'), [], 'an arXiv ID is looked up directly');
  assert.deepEqual(openAlexSearchURLs('   '), []);
  const work = (relevance: number, citations: number, ...urls: string[]) => ({ relevance_score: relevance, cited_by_count: citations,
    locations: urls.map(u => ({ landing_page_url: u, pdf_url: null })) });
  const ranking = rankOpenAlex({ results: [
    work(129, 3, 'http://arxiv.org/abs/2411.11001'),                 // mentions CNN, rarely cited
    work(125, 1741, 'https://arxiv.org/abs/1504.08083v2'),          // Fast R-CNN
    work(117, 283, 'https://arxiv.org/abs/1504.08083'),             // the same paper again
    work(140, 9000, 'https://example.org/not-arxiv'),               // no arXiv location: skipped
    work(0, 50, 'https://arxiv.org/abs/2001.00001'),                // no relevance in the relevance list: skipped
  ] }, { results: [work(0, 51629, 'https://arxiv.org/abs/1506.02640'), work(0, 1741, 'https://arxiv.org/abs/1504.08083'),
    work(0, 900, 'https://arxiv.org/abs/2401.02954')] });
  assert.deepEqual(ranking.map(r => r.sourceID), ['1506.02640', '1504.08083', '2411.11001'],
    'a classic found only by citations leads; one cited less than the best relevant match (2401.02954) is dropped');
  assert.throws(() => rankOpenAlex({ error: 'x' }), /invalid_openalex/);
  assert.equal(new URL(arxivIDListURL(ranking.map(r => r.sourceID))!).searchParams.get('id_list'), '1506.02640,1504.08083,2411.11001');
  assert.equal(arxivIDListURL([]), null);
  const r = (id: string, title: string, categories: string[]) => ({ source_id: id, revision: 1, title, authors: [], year: null, abstract: null, categories });
  const metadata = [r('2411.11001', 'Elliptic flow with CNNs', ['nucl-th']), r('1506.02640', 'You Only Look Once', ['cs.CV']),
    r('1504.08083', 'Fast R-CNN', ['cs.CV']), r('9999.99999', 'Unranked', ['cs.LG'])];
  assert.deepEqual(orderByRanking(metadata, ranking, 'cnn').map(x => x.source_id), ['1506.02640', '1504.08083', '2411.11001']);
  assert.deepEqual(orderByRanking(metadata, ranking, 'fast r-cnn').map(x => x.source_id)[0], '1504.08083', 'exact title leads');
  const titles = [r('a', 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model', ['cs.LG']), r('b', 'Diffusion models of growth', ['cond-mat'])];
  assert.deepEqual(exactTitleMatches(titles, 'direct preference optimization').map(x => x.source_id), ['a']);
  assert.deepEqual(exactTitleMatches(titles, 'diffusion models'), [], 'a phrase inside a longer title is not an exact title');
});

test('when arXiv is throttled, results come from OpenAlex metadata in the same ranking', () => {
  const work = { title: 'Attention Is  All You Need', publication_year: 2017, relevance_score: 120, cited_by_count: 100000,
    authorships: [{ author: { display_name: 'Ashish Vaswani' } }, { author: { display_name: 'Noam Shazeer' } }, { author: {} }],
    abstract_inverted_index: { The: [0], dominant: [1], sequence: [2], 'models.': [3] },
    locations: [{ landing_page_url: 'https://doi.org/10.48550/arxiv.1706.03762' }, { landing_page_url: 'https://arxiv.org/abs/1706.03762v7' }] };
  assert.deepEqual(openAlexResult(work), { source_id: '1706.03762', revision: 7, title: 'Attention Is All You Need', authors: ['Ashish Vaswani', 'Noam Shazeer'],
    year: 2017, abstract: 'The dominant sequence models.', categories: [] });
  assert.equal(openAlexResult({ ...work, locations: [{ landing_page_url: 'https://arxiv.org/abs/1706.03762' }] })!.revision, 1, 'unknown version shows v1; adding ignores it');
  assert.equal(openAlexResult({ ...work, locations: [] }), null);
  assert.equal(openAlexResult({ ...work, title: '' }), null);
  const ranking = rankOpenAlex({ results: [work] });
  assert.equal(ranking[0].result?.title, 'Attention Is All You Need');
  assert.equal(openAlexArxivWorkURL('1706.03762'), 'https://api.openalex.org/works/doi:10.48550/arXiv.1706.03762');
  assert.ok(new URL(openAlexSearchURLs('cnn')[0]).searchParams.get('select')!.includes('abstract_inverted_index'));
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
