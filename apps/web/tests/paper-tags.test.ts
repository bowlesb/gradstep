import { describe, expect, it } from 'vitest';
import { decodeEntry, type Item } from '../src/lib/library';
import { deriveKeywords, effectiveTags, rows } from '../src/lib/paper';
import { containsTag, editedTags, normalizeTag, ownTagsInLibrary, tagSuggestions, validTags } from '../src/lib/paper-tags';

const item = (extra: Partial<Item> = {}): Item => ({ kind: 'item', id: 'aaaaaaaa-0000-4000-8000-000000000001', document_id: 'dddddddd-0000-4000-8000-000000000001',
  created_seq: 1, state_seq: 1, membership_revision: 1, visible: true, added_at: 0, last_remove_seq: 0, scope: 'shared_catalog', page_count: 1, readiness: 'unverified', ...extra });

describe('native paper tag parity', () => {
  it('derives specific keywords, never the generic ones (builds 70 and 75; PaperDiscoveryTests.genericKeywordsNeverDescribeAPaper)', () => {
    const tags = deriveKeywords('Interactive Learning for LLM Reasoning with TreeCut',
      'Large language models show strong reasoning. We evaluate mathematical reasoning and tool use on a benchmark.');
    for (const generic of ['LLM', 'Reasoning', 'Large language models', 'Evaluation']) expect(tags).not.toContain(generic);
    for (const specific of ['TreeCut', 'Mathematical reasoning', 'Tool use']) expect(tags).toContain(specific);
  });
  it('normalizes whitespace and Unicode controls without changing spelling', () => {
    expect(normalizeTag(' \tMy\n  Research\u200b\u0085Tag\r ')).toBe('My Research Tag');
    expect(normalizeTag('  \t\u200e\n')).toBeNull();
    expect(normalizeTag('é')).toBe('é');
    expect(normalizeTag('e\u0301')).toBe('e\u0301'); // no unsupported normalization contract
    expect(containsTag(['Research'], 'research')).toBe(true);
  });
  it('counts Unicode scalars and UTF-8 bytes, rejecting lone surrogates', () => {
    expect(normalizeTag('界'.repeat(40))).toBe('界'.repeat(40)); // 40 scalars, 120 bytes
    expect(normalizeTag('界'.repeat(41))).toBeNull();
    expect(normalizeTag('😀'.repeat(30))).toBe('😀'.repeat(30));
    expect(normalizeTag('😀'.repeat(31))).toBeNull(); // 31 scalars but 124 bytes
    expect(normalizeTag('e\u0301'.repeat(20))).toBe('e\u0301'.repeat(20));
    expect(normalizeTag('e\u0301'.repeat(21))).toBeNull();
    expect(normalizeTag('a'.repeat(41))).toBeNull();
    expect(normalizeTag('\ud800')).toBeNull(); expect(normalizeTag('x\udfff')).toBeNull();
  });
  it('validates stored lists and deduplicates the chosen display list', () => {
    expect(validTags(['One', 'one'], 12)).toBe(false);
    expect(validTags([' padded'], 12)).toBe(false);
    expect(validTags(['two  spaces'], 12)).toBe(false);
    expect(validTags(['line\nbreak'], 12)).toBe(false);
    expect(editedTags(['Machine learning', 'Vision'], [' machine\nlearning ', 'My tag', 'my TAG']))
      .toEqual({ own: ['My tag'], hidden: ['Vision'] });
  });
  it('enforces own and hidden limits and rejects rather than silently dropping an invalid edit', () => {
    expect(editedTags([], Array.from({ length: 12 }, (_, i) => `Mine ${i}`)).own).toHaveLength(12);
    expect(() => editedTags([], Array.from({ length: 13 }, (_, i) => `Mine ${i}`))).toThrow('invalid_tags');
    expect(editedTags(Array.from({ length: 8 }, (_, i) => `Catalog ${i}`), []).hidden).toHaveLength(8);
    expect(() => editedTags(Array.from({ length: 9 }, (_, i) => `Catalog ${i}`), [])).toThrow('invalid_tags');
    expect(() => editedTags([], ['valid', ' '.repeat(20)])).toThrow('invalid_tags');
  });
  it('keeps deliberately empty projected tags empty in the row', () => {
    const paper = item({ metadata: { title: 'Paper', authors: [], categories: ['cs.LG'] }, tags: ['Machine learning'], hidden_tags: ['machine LEARNING'] });
    expect(effectiveTags(paper)).toEqual([]);
    expect(rows([paper])[0].tags).toEqual([]);
    expect(rows([item({ metadata: paper.metadata })])[0].tags).toEqual([]); // Generic categories are not paper keywords.
    expect(rows([item({ metadata: paper.metadata, hidden_tags: ['Machine learning'] })])[0].tags).toEqual([]);
  });
  it('uses only other visible papers’ personal tags, ranked by use', () => {
    const tags = ownTagsInLibrary([item({ user_tags: ['Excluded'] }), item({ id: 'two', user_tags: ['Review', 'Methods', 'review'] }),
      item({ id: 'three', archived: true, user_tags: ['review'] }), item({ id: 'four', visible: false, user_tags: ['Removed'] })], item().id);
    expect(tags).toEqual(['Review', 'Methods']);
  });
  it('offers removed catalog/category/own tags, avoiding chosen tags and case duplicates', () => {
    expect(tagSuggestions(['Alignment', 'Machine learning'], ['cs.LG', 'cs.CL'], ['machine LEARNING'], ['alignment', 'Reading list'], '')
      .map(t => t.name)).toEqual(['Alignment', 'Natural language processing', 'Reading list']);
    const result = tagSuggestions([], [], [], ['Learning to read', 'My learning notes'], 'learning');
    expect(result.at(-1)?.detail).toBe('Your tag');
    expect(result.length).toBeLessThanOrEqual(8);
    expect(result.every(tag => tag.name.toLowerCase().includes('learning'))).toBe(true);
    expect(tagSuggestions([], [], ['Machine learning'], [], 'machine').some(t => t.name === 'Machine learning')).toBe(false);
  });
  it('keeps live mapped imports visible after removal without reviving hidden completed imports', () => {
    const paper = item();
    const base = { kind: 'import', created_seq: 2, state_seq: 2, intent_revision: 1, source: 'arxiv', source_id: '1706.03762', source_url: 'https://arxiv.org/abs/1706.03762',
      retryable: false, library_item_id: paper.id, document_id: paper.document_id };
    const live = decodeEntry({ ...base, id: 'bbbbbbbb-0000-4000-8000-000000000001', visible: true, phase: 'acquiring' });
    const completed = decodeEntry({ ...base, id: 'bbbbbbbb-0000-4000-8000-000000000002', visible: false, phase: 'ready' });
    expect(rows([paper, live, completed]).map(r => r.entry.id)).toEqual([paper.id]);
    expect(rows([{ ...paper, visible: false, membership_revision: 2, state_seq: 3 }, live, completed]).map(r => r.entry.id)).toEqual([live.id]);
  });
});
