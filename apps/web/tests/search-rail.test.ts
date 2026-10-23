import { describe, expect, it } from 'vitest';
import { RAIL_CLOSED, type RailSearch, carriedQuery, enterAction, escapeStep, libraryMatches, matchRank, railReducer, restoreLeft } from '../src/lib/search-rail';

const paper = (title: string, extra: Partial<{ authors: string[]; tags: string[]; source: string; venue: string; added: number; archived: boolean }> = {}) => ({
  title, authors: extra.authors ?? [], tags: extra.tags ?? [], source: extra.source ?? '', venue: extra.venue ?? null, added: extra.added ?? 0, archived: extra.archived ?? false,
});

describe('library matches in the search list', () => {
  it('ranks a title that starts with the words, then a title word, then anywhere in the title, then authors, then tags and the rest', () => {
    const rows = [
      paper('Tagged only', { tags: ['sparse methods'], added: 9 }),
      paper('By the author', { authors: ['Ada Sparsely'], added: 8 }),
      paper('Unsparsified nets', { added: 7 }),
      paper('Making models sparse', { added: 6 }),
      paper('Sparse attention', { added: 1 }),
    ];
    expect(libraryMatches(rows, '  SPARS ').shown.map(r => r.title)).toEqual(['Sparse attention', 'Making models sparse', 'Unsparsified nets', 'By the author', 'Tagged only']);
    expect(matchRank(paper('Sparse attention'), 'attention')).toBe(1);
    expect(matchRank(paper('Unrelated'), 'attention')).toBeNull();
  });

  it('breaks ties by the newest added, then by title; caps the list; counts every match; leaves archived papers out', () => {
    const rows = Array.from({ length: 9 }, (_, i) => paper(`Attention ${String.fromCharCode(97 + (i % 3))} ${i}`, { added: i < 3 ? 100 : i }));
    rows.push(paper('Attention archived', { archived: true, added: 1000 }));
    const found = libraryMatches(rows, 'attention', 6);
    expect(found.total).toBe(9);
    expect(found.shown).toHaveLength(6);
    expect(found.shown.slice(0, 3).map(r => r.title)).toEqual(['Attention a 0', 'Attention b 1', 'Attention c 2']);
    expect(found.shown[3].title).toBe('Attention c 8');
    expect(found.shown.some(r => r.archived)).toBe(false);
    expect(libraryMatches(rows, '   ')).toEqual({ shown: [], total: 0 });
  });
});

describe('the field', () => {
  it('Enter opens the best library match; with none it asks ML papers; in ML papers it searches again; nothing when empty', () => {
    expect(enterAction({ ml: false, query: 'sparse', matches: 3 })).toBe('open-first');
    expect(enterAction({ ml: false, query: 'zzz', matches: 0 })).toBe('search-ml');
    expect(enterAction({ ml: true, query: 'sparse', matches: 3 })).toBe('run-ml');
    expect(enterAction({ ml: true, query: '  ', matches: 0 })).toBeNull();
  });

  it('Esc clears the words, then ends search', () => {
    expect(escapeStep('sparse')).toBe('clear');
    expect(escapeStep('')).toBe('close');
  });

  it('switching sides carries the words only to a side that has none', () => {
    expect(carriedQuery('sparse', '')).toBe('sparse');
    expect(carriedQuery('sparse', 'dense')).toBe('dense');
  });
});

describe('search mode of the left panel', () => {
  const run = (...events: Parameters<typeof railReducer>[1][]) => events.reduce<RailSearch>(railReducer, RAIL_CLOSED);

  it('opens off the Library route, remembering how the panel was; never on the Library (its table is its list)', () => {
    expect(run({ type: 'open', route: 'paper', leftOpen: false })).toEqual({ open: true, ml: false, restore: { route: 'paper', leftOpen: false } });
    expect(run({ type: 'open', route: 'library', leftOpen: true })).toBe(RAIL_CLOSED);
    // Opening again (/ while searching) keeps the first record, so the panel still goes back to how it was.
    expect(run({ type: 'open', route: 'paper', leftOpen: false }, { type: 'open', route: 'paper', leftOpen: true }).restore).toEqual({ route: 'paper', leftOpen: false });
  });

  it('the scope switch: ML papers and back to the library', () => {
    const ml = run({ type: 'open', route: 'feed', leftOpen: true }, { type: 'ml' });
    expect(ml.ml).toBe(true);
    expect(railReducer(ml, { type: 'library' }).ml).toBe(false);
    expect(railReducer(RAIL_CLOSED, { type: 'ml' })).toBe(RAIL_CLOSED);
  });

  it('a result opened beside the list keeps the list (and ML papers); opened from a drawer, search ends (R1: nothing outlives it)', () => {
    const ml = run({ type: 'open', route: 'paper', leftOpen: true }, { type: 'ml' });
    expect(railReducer(ml, { type: 'opened', inline: true })).toBe(ml);
    expect(railReducer(ml, { type: 'opened', inline: false })).toEqual(RAIL_CLOSED);
    expect(railReducer(ml, { type: 'route', route: 'paper' })).toBe(ml);
    expect(railReducer(ml, { type: 'route', route: 'library' })).toEqual(RAIL_CLOSED);
    expect(railReducer(ml, { type: 'close' })).toEqual(RAIL_CLOSED);
  });

  it('ending search puts the panel back as it was on its route (Contents or closed, R2)', () => {
    const fromClosed = run({ type: 'open', route: 'paper', leftOpen: false });
    expect(restoreLeft(fromClosed, 'paper', true)).toBe(false);
    expect(restoreLeft(run({ type: 'open', route: 'paper', leftOpen: true }), 'paper', true)).toBe(true);
    // Opened from the Feed, ended beside a paper it opened: the panel stays as it is there.
    expect(restoreLeft(run({ type: 'open', route: 'feed', leftOpen: false }), 'paper', true)).toBeNull();
    expect(restoreLeft(run({ type: 'open', route: 'feed', leftOpen: false }), 'paper', false)).toBe(false);
  });
});
