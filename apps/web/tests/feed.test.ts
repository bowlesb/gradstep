import { describe, expect, it } from 'vitest';
import { arxivMonth, decodeFeed, orderFeed, resultTopics } from '../src/lib/feed';
import { parseFeedColumns } from '../src/lib/feed-columns';

const paper = (source_id: string, fields: Record<string, unknown> = {}) => ({ source_id, revision: 1, title: 'Paper', authors: ['Ada Example'], year: 2026, categories: ['cs.LG'], abstract: 'Preview', ...fields });
describe('feed response boundary', () => {
  it('accepts additive native topics, reasons and popularity while retaining complete abstracts', () => {
    const full = 'A '.repeat(500);
    const page = decodeFeed({ results: [paper('2610.00001', { full_abstract: full, abstract_truncated: false, topics: ['RL for reasoning', 'Policy optimization'], upvotes: 0,
      reason: { kind: 'future_reason', text: 'Because you added “A paper”' }, first_seen: '2026-10-08T12:13:14+00:00' })],
      feed: { for_you: true, refreshed_at: '2026-10-08T12:13:14.123456+00:00', topics: [{ name: 'RL for reasoning', kind: 'combined', papers: 12 }] } });
    expect(page.forYou).toBe(true); expect(page.topics).toEqual([{ name: 'RL for reasoning', kind: 'combined', papers: 12 }]);
    expect(page.results[0]).toMatchObject({ upvotes: 0, reason: 'Because you added “A paper”', abstract: full.trim(), abstractTruncated: false });
    expect(page.refreshedAt).toBe('2026-10-08T12:13:14.123456+00:00');
    expect(page.results[0].firstSeen).toBe('2026-10-08T12:13:14+00:00');
  });
  it('keeps legacy category browsing, unknown popularity and fallback topics', () => {
    const page = decodeFeed({ results: [paper('2305.18290')] });
    expect(page).toMatchObject({ forYou: false, topics: null, coldStart: false });
    expect(page.results[0]).toMatchObject({ upvotes: null, topics: [], reason: null });
    expect(resultTopics(page.results[0])).toEqual(['Machine learning']);
  });
  it('bounds optional server fields and refuses unsafe or duplicate Add identities', () => {
    const page = decodeFeed({ results: [paper('../malicious'), paper('2610.00001'), paper('2610.00001'), paper('2610.00002', {
      topics: ['x'.repeat(81), 'Reasoning', 'Reasoning', '\u0000bad'], upvotes: -1, reason: { text: 'x'.repeat(601) }, year: 10_000,
    })], feed: { for_you: true, topics: [{ name: 'x'.repeat(41), kind: 'own', papers: 2 }, { name: 'A', kind: 'own', papers: 2 }, { name: 'A', kind: 'own', papers: 3 }] } });
    expect(page.results).toHaveLength(2); expect(page.results[1]).toMatchObject({ upvotes: null, topics: ['Reasoning'], reason: null, year: null });
    expect(page.topics).toEqual([{ name: 'A', kind: 'own', papers: 2 }]);
    expect(() => decodeFeed({ results: Array(201).fill(paper('2610.00001')) })).toThrow();
    expect(() => decodeFeed(null)).toThrow();
  });
});

describe('native feed ordering and presentation', () => {
  it('preserves suggestion/tie order and puts unknown popularity last in both directions', () => {
    const items = decodeFeed({ results: [paper('2610.00001'), paper('2610.00002', { upvotes: 12 }), paper('2610.00003', { upvotes: 0 }), paper('2610.00004', { upvotes: 12 })] }).results;
    const ids = (ascending = false) => orderFeed(items, 'popularity', ascending).map(p => p.source_id);
    expect(ids()).toEqual(['2610.00002', '2610.00004', '2610.00003', '2610.00001']);
    expect(ids(true)).toEqual(['2610.00003', '2610.00002', '2610.00004', '2610.00001']);
    expect(orderFeed(items, 'suggested')).toEqual(items);
    expect(items[0].source_id).toBe('2610.00001'); // sorting never mutates cached server order
  });
  it('orders real submission months and serials, including historical identifiers', () => {
    expect(arxivMonth('hep-th/9901001')).toEqual({ year: 1999, month: 1, serial: 1 });
    expect(arxivMonth('2610.00002v3')).toEqual({ year: 2026, month: 10, serial: 2 });
    expect(arxivMonth('2613.00001')).toBeNull();
    const items = decodeFeed({ results: [paper('2305.18290'), paper('2610.00002'), paper('hep-th/9901001'), paper('2610.00001')] }).results;
    expect(orderFeed(items, 'newest').map(p => p.source_id)).toEqual(['2610.00002', '2610.00001', '2305.18290', 'hep-th/9901001']);
  });
  it('persists only bounded, known columns, including a deliberate title-and-actions-only choice', () => {
    expect(parseFeedColumns('{"version":1,"columns":[]}')).toEqual([]);
    expect(parseFeedColumns('{"version":1,"columns":["abstract","popularity"]}')).toEqual(['popularity', 'abstract']);
    for (const columns of [['title'], ['popularity', 'popularity'], [12], ['a'.repeat(600)]]) expect(parseFeedColumns(JSON.stringify({ version: 1, columns }))).toBeNull();
  });
});
