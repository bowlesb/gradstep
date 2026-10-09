import { describe, expect, it } from 'vitest';
import { addOutcome, decodeAddResult } from '../src/lib/add';
import { feedCategories, topicName } from '../src/lib/feed';
import type { Entry, Item } from '../src/lib/library';
import { readFrameMessage } from '../src/reader/frame';

describe('add-paper outcomes', () => {
  it('decodes bounded fields and refuses unknown statuses', () => {
    expect(() => decodeAddResult({ status: 'uploaded' })).toThrow();
    expect(() => decodeAddResult(null)).toThrow();
    const result = decodeAddResult({ status: 'added', route: 'doi', paper: { title: 'Attention Is All You Need', year: 2017, source_id: '1706.03762', kind: 'arxiv' }, link: null, reason: null, title: null });
    expect(result.paper).toEqual({ title: 'Attention Is All You Need', year: 2017, source_id: '1706.03762' });
    // Only https links without credentials are ever offered.
    expect(decodeAddResult({ status: 'blocked', link: 'http://example.com/a.pdf' }).link).toBeNull();
    expect(decodeAddResult({ status: 'blocked', link: 'https://user:pw@example.com/a.pdf' }).link).toBeNull();
    expect(decodeAddResult({ status: 'blocked', link: 'javascript:alert(1)' }).link).toBeNull();
    expect(decodeAddResult({ status: 'blocked', link: 'https://example.com/a.pdf' }).link).toBe('https://example.com/a.pdf');
    expect(decodeAddResult({ status: 'added', paper: { title: 'x', source_id: 'y', year: 99_999 } }).paper?.year).toBeNull();
  });

  it('words each outcome for the browser, which can upload a user-selected PDF', () => {
    const outcome = (v: Record<string, unknown>) => addOutcome(decodeAddResult(v));
    expect(outcome({ status: 'added', paper: { title: 'A paper', source_id: '1', year: 2020 } })).toMatchObject({ finished: true, message: 'Added “A paper”. It’s being prepared to read.' });
    expect(outcome({ status: 'present' }).finished).toBe(true);
    expect(outcome({ status: 'blocked', reason: 'pdf_restricted', link: 'https://x.example/p' }).message).toContain('needs a sign-in or subscription');
    expect(outcome({ status: 'link_only', title: 'Notes' }).message).toContain('choose the PDF');
    expect(outcome({ status: 'closed' }).message).toContain('choose the PDF');
    expect(outcome({ status: 'failed' }).message).toBe('Couldn’t add it right now. Check your connection and try again.');
    for (const status of ['closed', 'blocked', 'link_only', 'not_found', 'needs_update', 'invalid', 'unavailable']) expect(outcome({ status }).finished).toBe(false);
  });
});

describe('feed topics', () => {
  const paper = (id: number, categories: string[]): Entry => ({ kind: 'item', id: `p${id}`, visible: true, metadata: { title: 't', authors: [], categories } } as unknown as Item);
  it('picks the library’s frequent categories, one per friendly name, at most six', () => {
    const entries = [paper(1, ['cs.LG', 'stat.ML']), paper(2, ['cs.LG']), paper(3, ['hep-ph']), paper(4, ['cs.CV']), paper(5, ['math.OC']), paper(6, ['math.OC'])];
    const topics = feedCategories(entries);
    expect(topics[0]).toBe('cs.LG');
    expect(topics).toContain('math.OC'); // two papers
    expect(topics).toContain('cs.CV'); // core ML, one paper is enough
    expect(topics).not.toContain('hep-ph'); // a single cross-listing
    expect(topics.length).toBeLessThanOrEqual(6);
    expect(feedCategories([])).toEqual(['cs.LG', 'cs.CL', 'cs.AI', 'cs.CV']);
  });
  it('names categories from the tag vocabulary, then the Feed labels, then the archive', () => {
    expect(topicName('cs.RO')).toBeTruthy();
    expect(topicName('math.OC')).toBe('Optimization');
    expect(topicName('physics.optics')).toBe('Physics');
    expect(topicName('zz.XX')).toBe('zz.XX');
  });
});

describe('frame messages added for the large-screen reader', () => {
  it('keeps outline depths within the bridge’s range', () => {
    expect(readFrameMessage({ type: 'headings', items: [{ id: 'a', title: 'A', depth: 2 }, { id: 'b', title: 'B', depth: 9 }] }))
      .toEqual({ type: 'headings', items: [{ id: 'a', title: 'A', depth: 2 }, { id: 'b', title: 'B' }] });
  });
  it('validates find results and forwarded shortcuts', () => {
    expect(readFrameMessage({ type: 'find', count: 12, index: 3 })).toEqual({ type: 'find', count: 12, index: 3 });
    expect(readFrameMessage({ type: 'find', count: 0, index: 0 })).toEqual({ type: 'find', count: 0, index: -1 });
    expect(readFrameMessage({ type: 'find', count: 2, index: 2 })).toBeNull();
    expect(readFrameMessage({ type: 'find', count: 5000, index: 1 })).toBeNull();
    expect(readFrameMessage({ type: 'key', key: 'find' })).toEqual({ type: 'key', key: 'find' });
    expect(readFrameMessage({ type: 'key', key: 'reload' })).toBeNull();
  });
});
