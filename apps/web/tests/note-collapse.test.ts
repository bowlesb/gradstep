// Collapsed snippets (NOTES_AND_SNIPPETS.md "Collapsible snippet cards"): the one-line form against the cases the apps
// also read (tests/fixtures/notes/collapsed-lines.json), and this browser's memory, including storage that throws.
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { COLLAPSE_KEY_PREFIX, collapsedEntries, collapsedLine, rememberCollapsed } from '../src/lib/note-collapse';

const fixture = JSON.parse(readFileSync(new URL('../../../tests/fixtures/notes/collapsed-lines.json', import.meta.url), 'utf8')) as {
  cases: { name: string; time: string; title: string; comment: string; quote: string | null; label: string | null; titleLimit?: number; line: string }[];
};

function memoryStorage() {
  const map = new Map<string, string>();
  return { map, getItem: (k: string) => map.get(k) ?? null, setItem: (k: string, v: string) => { map.set(k, v); }, removeItem: (k: string) => { map.delete(k); } };
}

describe('collapsed snippet line', () => {
  it('matches every shared case', () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(8);
    for (const c of fixture.cases) expect(collapsedLine(c.time, c.title, c.comment, c.quote, c.label, c.titleLimit), c.name).toBe(c.line);
  });
});

describe('collapse memory', () => {
  it('is per collection and drops entries that are gone', () => {
    const store = memoryStorage();
    expect(collapsedEntries('n1', store).size).toBe(0);
    rememberCollapsed('n1', new Set(['b', 'a', 'gone']), ['a', 'b'], store);
    expect([...collapsedEntries('n1', store)].sort()).toEqual(['a', 'b']);
    expect(store.map.get(`${COLLAPSE_KEY_PREFIX}n1`)).toBe('["a","b"]');
    expect(collapsedEntries('n2', store).size).toBe(0);
    rememberCollapsed('n1', new Set(), undefined, store);
    expect(store.map.has(`${COLLAPSE_KEY_PREFIX}n1`)).toBe(false);
  });
  it('survives storage that throws or holds garbage', () => {
    const broken = { getItem: () => { throw new Error('blocked'); }, setItem: () => { throw new Error('blocked'); }, removeItem: () => { throw new Error('blocked'); } };
    expect(collapsedEntries('n1', broken).size).toBe(0);
    expect(() => rememberCollapsed('n1', new Set(['a']), undefined, broken)).not.toThrow();
    const store = memoryStorage(); store.map.set(`${COLLAPSE_KEY_PREFIX}n1`, '{not json');
    expect(collapsedEntries('n1', store).size).toBe(0);
    store.map.set(`${COLLAPSE_KEY_PREFIX}n1`, '[1,"a",null]');
    expect([...collapsedEntries('n1', store)]).toEqual(['a']);
  });
});
