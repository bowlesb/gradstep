import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { arxivSearchURL, arxivSearchURLs, mergeDiscovery, parseArxivSearch } from '../../supabase/functions/_shared/discover.ts';

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
