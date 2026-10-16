// The Feed's pool from DataCite (feed-datacite.ts, migration 074), against DataCite answers recorded once on
// 2026-10-15 (tests/backend/fixtures/feed/, trimmed to their first records).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DataCiteError } from '../../supabase/functions/_shared/datacite.ts';
import { DATACITE_POOL_LAG_HOURS, DATACITE_POOL_MAX_PAGES, dataCiteCategoryURL, dataCitePoolSince, dataCitePoolSource, dataCitePoolURL,
  parseDataCitePool } from '../../supabase/functions/_shared/feed-datacite.ts';
import { POOL_BATCH, runRefresh, withTopics, type PoolItem, type RefreshClaim, type RefreshDeps, type RefreshStatus } from '../../supabase/functions/_shared/feed-pool.ts';
import { FEED_TOPICS_VERSION } from '../../supabase/functions/_shared/feed-topics.ts';
import { parseDataCiteSearch } from '../../supabase/functions/_shared/paper-search.ts';

const fixture = (name: string) => JSON.parse(readFileSync(new URL(`fixtures/feed/${name}`, import.meta.url), 'utf8'));
const POOL = ['cs.LG', 'cs.CL', 'cs.CV', 'cs.AI', 'stat.ML', 'cs.RO', 'cs.IR', 'cs.NE', 'cs.MA', 'cs.SD', 'eess.AS', 'eess.IV'];
const page = fixture('datacite-pool-page.json');
const lastPage = { ...page, data: page.data.slice(10), links: { self: page.links.self } };

test('one query for the pool: its categories, a created window, arXiv\'s records only, newest first, bounded pages', () => {
  const url = new URL(dataCitePoolURL(['cs.LG', 'stat.ML'], '2026-10-12', 3));
  assert.equal(url.origin, 'https://api.datacite.org');
  assert.equal(url.pathname, '/dois');
  assert.equal(url.searchParams.get('query'), '(subjects.subject:"cs.LG" OR subjects.subject:"stat.ML") AND created:[2026-10-12T00:00:00Z TO *]');
  assert.deepEqual([url.searchParams.get('provider-id'), url.searchParams.get('sort'), url.searchParams.get('page[size]'), url.searchParams.get('page[number]')],
    ['arxiv', '-created', '100', '3']);
  assert.match(url.searchParams.get('fields[dois]')!, /^doi,titles,creators,descriptions,subjects,version/);
  assert.match(dataCitePoolURL(['cs.LG'], '2026-10-14T09:30:00Z', 1), /created%3A%5B2026-10-14T09%3A30%3A00Z\+TO/);
  for (const bad of [() => dataCitePoolURL([], '2026-10-12', 1), () => dataCitePoolURL(['cs.LG") OR (x'], '2026-10-12', 1),
    () => dataCitePoolURL(['cs.LG'], '2026-10-12] OR [', 1), () => dataCitePoolURL(['cs.LG'], '2026-10-12', 0), () => dataCitePoolURL(['cs.LG'], '2026-10-12', 1, 500)]) {
    assert.throws(bad, /invalid_categories/);
  }
  const chip = new URL(dataCiteCategoryURL('math.OC', '2026-10-15'));
  assert.equal(chip.searchParams.get('query'), '(subjects.subject:"math.OC") AND created:[2026-10-08T00:00:00Z TO *]');
  assert.equal(chip.searchParams.get('page[size]'), '25');
});

test('the recorded page parses into pool items: primary in the pool is new, a cross-list is cross, the DOI day is the announcement day', () => {
  const parsed = parseDataCitePool(page, { categories: POOL, today: '2026-10-15', limit: 3000 });
  assert.deepEqual([parsed.items.length, parsed.skipped, parsed.more], [14, 0, true]);
  const first = parsed.items[0];
  assert.deepEqual({ ...first, title: first.title.slice(0, 32), abstract: null, authors: first.authors.length }, { source_id: '2610.20610', revision: 1,
    title: 'Can Learning to Answer Spatial Q', authors: 7, abstract: null, categories: ['cs.CV'], topics: [], announced_on: '2026-10-15',
    announce_type: 'new' });
  assert.ok(first.abstract && first.abstract.length > 500);
  const auction = parsed.items.find(item => item.source_id === '2610.20587')!;
  assert.deepEqual([auction.announce_type, auction.categories[0]], ['cross', 'cs.GT'], 'its primary category (cs.GT) is outside the pool');
  for (const item of parsed.items) {
    assert.ok(item.authors.length >= 1 && item.authors.length <= 12, item.source_id);
    assert.ok(!item.abstract || item.abstract.length <= 2000);
    assert.ok(item.categories.length <= 12 && item.categories.some(c => POOL.includes(c)));
  }
  // The same keys the RSS source writes, so worker_feed_upsert (migration 043) reads both alike.
  assert.deepEqual(Object.keys(withTopics(parsed.items)[0]).sort(),
    ['abstract', 'announce_type', 'announced_on', 'authors', 'categories', 'revision', 'source_id', 'title', 'topics']);
});

test('records that are not arXiv papers in the pool, or outside the window, are skipped; the limit holds', () => {
  const [one] = page.data;
  const other = { ...one, attributes: { ...one.attributes, doi: '10.5281/zenodo.1' } };
  const outside = { ...one, attributes: { ...one.attributes, doi: '10.48550/arxiv.2610.99999', subjects: [{ subject: 'Number Theory (math.NT)', subjectScheme: 'arXiv' }] } };
  const old = { ...one, attributes: { ...one.attributes, doi: '10.48550/arxiv.2601.00001', created: '2026-01-02T03:00:00Z' } };
  const undated = { ...one, attributes: { ...one.attributes, doi: '10.48550/arxiv.2610.99998', created: 'yesterday' } };
  const parsed = parseDataCitePool({ data: [other, outside, old, undated, one], links: {} }, { categories: POOL, today: '2026-10-15', limit: 3000 });
  assert.deepEqual([parsed.items.map(item => item.source_id), parsed.skipped, parsed.more], [['2610.20610'], 4, false]);
  assert.equal(parseDataCitePool(page, { categories: POOL, today: '2026-10-15', limit: 3 }).items.length, 3);
  assert.deepEqual(parseDataCitePool(null, { categories: POOL, today: '2026-10-15', limit: 3 }), { items: [], skipped: 0, more: false });
});

test('a refresh reads from the last mark, never before the three-day window', () => {
  assert.equal(dataCitePoolSince('2026-10-15', null), '2026-10-12T00:00:00Z');
  assert.equal(dataCitePoolSince('2026-10-15', '2026-10-15T01:20:00Z'), '2026-10-15T01:20:00Z');
  assert.equal(dataCitePoolSince('2026-10-15', '2026-10-01T01:20:00Z'), '2026-10-12T00:00:00Z');
  assert.equal(dataCitePoolSince('2026-10-15', 'Thu, 15 Oct 2026 04:31:42 GMT'), '2026-10-12T00:00:00Z', 'an RSS validator is not a mark');
  assert.equal(dataCitePoolSince('2026-10-15', '2027-01-01T00:00:00Z'), '2026-10-16T00:00:00Z', 'a mark in the future is bounded');
});

// ---- The refresh with the DataCite source --------------------------------------------------------

const claim: RefreshClaim = { claim_id: '0a2b5c7e-0000-4000-8000-000000000002', source: 'datacite-ml', kind: 'datacite', categories: POOL,
  etag: null, last_modified: null, max_items: 3000 };
const NOW = Date.parse('2026-10-15T09:00:00Z');

function dataCiteDeps(options: { failFinish?: boolean } = {}) {
  const calls = { upserts: [] as PoolItem[][], sleeps: [] as number[],
    finishes: [] as { status: RefreshStatus; etag: string | null; lastModified: string | null; items: number | null }[] };
  const deps: RefreshDeps = {
    slot: async () => { throw new Error('the DataCite source never takes the arXiv slot'); },
    fetch: (async () => { throw new Error('no direct request'); }) as typeof fetch,
    upsert: async (claimID, items, version) => {
      assert.equal(claimID, claim.claim_id); assert.equal(version, FEED_TOPICS_VERSION); calls.upserts.push(items);
      return { inserted: items.length, updated: 0 };
    },
    finish: async (claimID, status, etag, lastModified, items) => {
      assert.equal(claimID, claim.claim_id); calls.finishes.push({ status, etag, lastModified, items });
      if (options.failFinish) throw new Error('database_unavailable');
      return { pruned: 0, pool: 99 };
    },
    sleep: async ms => { calls.sleeps.push(ms); },
    today: () => '2026-10-15',
  };
  return { deps, calls };
}

test('DataCite pages are read a second apart, tagged, written and recorded with the next mark', async () => {
  const { deps, calls } = dataCiteDeps();
  const urls: string[] = [];
  const pages = [page, lastPage];
  const source = dataCitePoolSource({ get: async url => { urls.push(url); return pages[urls.length - 1]; }, now: () => NOW });
  const outcome = await runRefresh(deps, claim, source);
  assert.deepEqual({ status: outcome.status, items: outcome.items, inserted: outcome.inserted, pool: outcome.pool },
    { status: 'updated', items: 14, inserted: 14, pool: 99 }, 'the second page repeats four papers: each is written once');
  assert.deepEqual(urls.map(url => new URL(url).searchParams.get('page[number]')), ['1', '2']);
  assert.ok(urls.every(url => new URL(url).origin === 'https://api.datacite.org' && !/arxiv\.org/.test(url)));
  assert.match(new URL(urls[0]).searchParams.get('query')!, /created:\[2026-10-12T00:00:00Z TO \*\]$/);
  assert.deepEqual(calls.sleeps, [1000]);
  assert.ok(calls.upserts[0].some(item => item.topics.length > 0), 'keyword topics are added as for RSS');
  const mark = new Date(NOW - DATACITE_POOL_LAG_HOURS * 3_600_000).toISOString().slice(0, 19) + 'Z';
  assert.deepEqual(calls.finishes, [{ status: 'updated', etag: null, lastModified: mark, items: 14 }]);
});

test('the next refresh starts at the mark; nothing new there is not modified and keeps the mark', async () => {
  const { deps, calls } = dataCiteDeps();
  const urls: string[] = [];
  const source = dataCitePoolSource({ get: async url => { urls.push(url); return { data: [], meta: { total: 0 }, links: { self: url } }; }, now: () => NOW });
  const outcome = await runRefresh(deps, { ...claim, last_modified: '2026-10-15T04:00:00Z' }, source);
  assert.equal(outcome.status, 'not_modified');
  assert.equal(urls.length, 1);
  assert.match(new URL(urls[0]).searchParams.get('query')!, /created:\[2026-10-15T04:00:00Z TO \*\]$/);
  assert.deepEqual(calls.finishes, [{ status: 'not_modified', etag: null, lastModified: null, items: null }], 'the database keeps the mark (migration 043)');
});

test('bounded: max_items and the page limit stop the reading', async () => {
  let run = dataCiteDeps();
  let requests = 0;
  const full = (url: string) => ({ ...page, data: page.data.map((record: { attributes: Record<string, unknown> }, i: number) =>
    ({ ...record, attributes: { ...record.attributes, doi: `10.48550/arxiv.2610.${String(30000 + Number(new URL(url).searchParams.get('page[number]')) * 20 + i)}` } })) });
  let outcome = await runRefresh(run.deps, { ...claim, max_items: 20 }, dataCitePoolSource({ get: async url => { requests++; return full(url); }, now: () => NOW }));
  assert.deepEqual([outcome.items, requests], [20, 2]);
  run = dataCiteDeps(); requests = 0;
  outcome = await runRefresh(run.deps, claim, dataCitePoolSource({ get: async url => { requests++; return full(url); }, now: () => NOW }));
  assert.deepEqual([requests, outcome.items], [DATACITE_POOL_MAX_PAGES, DATACITE_POOL_MAX_PAGES * 14]);
  assert.ok(run.calls.upserts.every(batch => batch.length <= POOL_BATCH));
});

test('DataCite\'s failures and bad categories are recorded, never thrown', async () => {
  let run = dataCiteDeps();
  let outcome = await runRefresh(run.deps, claim, dataCitePoolSource({ get: async () => { throw new DataCiteError('datacite_unavailable'); }, now: () => NOW }));
  assert.deepEqual([outcome.status, outcome.code, run.calls.finishes[0].status], ['failed', 'datacite_unavailable', 'failed']);
  run = dataCiteDeps();
  outcome = await runRefresh(run.deps, { ...claim, categories: ['../x'] }, dataCitePoolSource({ get: async () => { throw new Error('unused'); } }));
  assert.equal(outcome.code, 'invalid_categories');
  run = dataCiteDeps({ failFinish: true });
  outcome = await runRefresh(run.deps, claim, dataCitePoolSource({ get: async () => lastPage, now: () => NOW }));
  assert.equal(outcome.code, 'finish_failed');
});

test('the default transport identifies Gradstep to DataCite (not the reader) and refuses redirects', async () => {
  const { deps } = dataCiteDeps();
  const seen: { url: string; init?: RequestInit }[] = [];
  deps.fetch = (async (url: string, init?: RequestInit) => { seen.push({ url, init }); return new Response(JSON.stringify(lastPage), { status: 200 }); }) as typeof fetch;
  const outcome = await runRefresh(deps, claim, dataCitePoolSource({ now: () => NOW }));
  assert.deepEqual([outcome.status, outcome.items], ['updated', 4]);
  const headers = seen[0].init?.headers as Record<string, string>;
  assert.equal(new URL(seen[0].url).origin, 'https://api.datacite.org');
  assert.match(headers['user-agent'], /mailto:hello@gradstep\.ai/);
  assert.equal(seen[0].init?.redirect, 'error');
});

test('a Feed chip outside the pool reads the category\'s newest papers from DataCite in the search contract', () => {
  const results = parseDataCiteSearch(fixture('datacite-chip-math.OC.json'));
  assert.equal(results.length, 6);
  for (const result of results) {
    assert.ok(result.categories.includes('math.OC'), result.source_id);
    assert.equal(result.year, 2026);
    assert.ok(result.authors.length >= 1 && result.title.length > 0);
  }
  assert.deepEqual(results.map(r => r.source_id), [...results.map(r => r.source_id)].sort().reverse(), 'newest first');
});
