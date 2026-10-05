import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { arxivRecentURL, arxivTitleURLs, matchPaper, parseArxivRSS, arxivSearchURL, arxivSearchURLs, mergeDiscovery, parseArxivSearch, titleSimilarity } from '../../supabase/functions/_shared/discover.ts';

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
