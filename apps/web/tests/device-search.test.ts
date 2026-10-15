import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { browserSearch, SEARCH_CACHE_MS, type BrowserSearchDeps } from '../src/lib/device-search';

// Search from the browser (docs/architecture/ARXIV_DEVICE_ONLY.md §5.6): DataCite from this browser, only while the server
// says so, one search's requests at a time, cached for a day, decoded like every other paper list. Answers recorded by
// scripts/search-eval.mjs (tests/backend/fixtures/search).
const fixture = (name: string) => readFileSync(new URL(`../../../tests/backend/fixtures/search/${name}`, import.meta.url), 'utf8');

function harness(enabled: boolean | 'v2' = true) {
  const requests: { url: string; init?: RequestInit }[] = [];
  let clock = 1_800_000_000_000, inFlight = 0, peak = 0, capabilityCalls = 0;
  const deps: BrowserSearchDeps = {
    capabilities: async () => { capabilityCalls++; return { device_search: { enabled: enabled !== false, format: enabled === 'v2' ? 'device-search-v2' : 'device-search-v1' } }; },
    fetch: async (url, init) => {
      requests.push({ url, init }); inFlight++; peak = Math.max(peak, inFlight);
      await new Promise(resolve => setTimeout(resolve, 1));
      inFlight--;
      const query = new URL(url).searchParams.get('query') ?? '';
      const path = new URL(url).pathname;
      const body = path.startsWith('/dois/10.48550/arXiv.2305.18290') ? fixture('datacite-id-id.json')
        : path.startsWith('/dois/') ? null
        : query.startsWith('titles.title:') ? fixture(query.includes('difusion') ? 'datacite-misspelling-phrase.json' : 'datacite-dpo-phrase.json')
        : query.includes('~1') ? fixture('datacite-misspelling-broad.json')
        : fixture(query.includes('difusion') ? 'datacite-misspelling-relevance.json' : 'datacite-dpo-relevance.json');
      return body === null ? new Response('{"errors":[{"status":"404"}]}', { status: 404 }) : new Response(body, { status: 200, headers: { 'content-type': 'application/vnd.api+json' } });
    },
    now: () => clock,
  };
  return { search: browserSearch('acct', deps), requests, peak: () => peak, capabilityCalls: () => capabilityCalls, advance: (ms: number) => { clock += ms; } };
}

describe('search from the browser', () => {
  it('is refused while the server hasn\'t switched it on (off, or another format), and asks nobody', async () => {
    for (const setting of [false, 'v2'] as const) {
      const h = harness(setting);
      await expect(h.search.search('direct preference optimization')).rejects.toMatchObject({ code: 'device_search_disabled' });
      expect(h.requests).toEqual([]);
    }
  });

  it('asks DataCite directly, identified by mailto and without credentials, and orders the original first', async () => {
    const h = harness();
    const results = await h.search.search('Direct Preference Optimization');
    expect(results[0].source_id).toBe('2305.18290');
    expect(results[0].revision).toBe(3);
    expect(results[0].topics.length).toBeGreaterThan(0);
    expect(h.requests).toHaveLength(2);
    for (const { url, init } of h.requests) {
      expect(new URL(url).origin).toBe('https://api.datacite.org');
      expect(new URL(url).searchParams.get('mailto')).toBe('hello@gradstep.ai');
      expect(init?.credentials).toBe('omit');
      expect(init?.referrerPolicy).toBe('no-referrer');
      expect(new Headers(init?.headers).has('user-agent')).toBe(false);
    }
  });

  it('keeps each query for a day in this tab; a misspelling asks for near spellings; an unknown ID is no results', async () => {
    const h = harness();
    await h.search.search('direct preference optimization');
    await h.search.search('  Direct   Preference Optimization ');
    expect(h.requests).toHaveLength(2);
    h.advance(SEARCH_CACHE_MS + 1);
    await h.search.search('direct preference optimization');
    expect(h.requests).toHaveLength(4);
    const fuzzy = await h.search.search('difusion model distilation');
    expect(new URL(h.requests.at(-1)!.url).searchParams.get('query')).toBe('difusion~1 model~1 distilation~1');
    expect(fuzzy.slice(0, 3).every(r => /distill/i.test(r.title))).toBe(true);
    expect(await h.search.search('2399.99999')).toEqual([]);
    expect((await h.search.search('arXiv:2305.18290'))[0].source_id).toBe('2305.18290');
    expect(h.capabilityCalls(), 'asked again only once ten minutes had passed').toBe(2);
  });

  it('runs one search\'s requests at a time, even when searches overlap', async () => {
    const h = harness();
    await Promise.all([h.search.search('direct preference optimization'), h.search.search('difusion model distilation')]);
    expect(h.peak()).toBe(1);
  });
});
