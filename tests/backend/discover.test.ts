import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { arxivRecentURL, arxivTitleURLs, bestTitleMatch, parseArxivRSS, arxivSearchURL, arxivSearchURLs, mergeDiscovery, parseArxivSearch, titleSimilarity } from '../../supabase/functions/_shared/discover.ts';

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

test('ingest title matching is strict', () => {
  assert.equal(titleSimilarity('Attention Is All You Need', 'Attention is all you need.'), 1);
  const candidates = [
    { source_id: '2405.00001', title: 'Attention Is Not All You Need', year: 2024 },
    { source_id: '1706.03762', title: 'Attention Is All You Need', year: 2017 },
  ];
  assert.equal(bestTitleMatch('Attention is all you need', 2017, candidates)?.source_id, '1706.03762');
  assert.equal(bestTitleMatch('Attention mechanisms survey', null, candidates), null);
  assert.equal(bestTitleMatch('LoRA: Low-Rank Adaptation of Large Language Models', 2021,
    [{ source_id: '2106.09685', title: 'LoRA: Low-Rank Adaptation of Large Language Models', year: 2021 }])?.source_id, '2106.09685');
  // A citation without the subtitle matches an exact main title of 3+ words only.
  const dpo = [{ source_id: '2305.18290', title: 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model', year: 2023 }];
  assert.equal(bestTitleMatch('Direct Preference Optimization', 2023, dpo)?.source_id, '2305.18290');
  assert.equal(bestTitleMatch('Preference Optimization', 2023, dpo), null);
  assert.equal(bestTitleMatch('Mamba', 2023, [{ source_id: '2312.00752', title: 'Mamba: Linear-Time Sequence Modeling with Selective State Spaces', year: 2023 }]), null);
});
