import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { captionNumbers, chooseStarters, methodHeading, starterPaper, starterRandom } from '../src/lib/chat-starters';

// The cases both clients reproduce (the native app runs the same file in ChatStartersTests).
const fixture = JSON.parse(readFileSync(new URL('../../../tests/fixtures/chat-starters-cases.json', import.meta.url), 'utf8'));

describe('starter questions (chat redesign 2026-10-16)', () => {
 it('reproduces every shared case', () => {
  const r = starterRandom(fixture.random.seed);
  expect([r(), r(), r()]).toEqual(fixture.random.first);
  for (const [headings, expected] of fixture.methodHeadings) expect(methodHeading(headings)).toBe(expected);
  for (const c of fixture.cases) {
   if (c.input) expect({ figures: captionNumbers(c.input.captions, 'Figure'), tables: captionNumbers(c.input.tableCaptions, 'Table') })
    .toEqual({ figures: c.paper.figures, tables: c.paper.tables });
   expect(chooseStarters(c.paper, c.seed)).toEqual(c.expected);
  }
 });

 it('draws three different categories, one about the paper itself when it has structure', () => {
  for (const c of fixture.cases.filter((c: { paper: unknown }) => c.paper)) {
   const categories = c.expected.map((s: { category: string }) => s.category);
   expect(new Set(categories).size).toBe(3);
   if (c.name === 'dpo') expect(categories.some((x: string) => ['method', 'figure', 'equation', 'table'].includes(x))).toBe(true);
   for (const s of c.expected) expect(s.text).not.toMatch(/\{/);
  }
 });

 it('builds its input from a verified reader index as the native app does', () => {
  // DPO's bundle as both apps ship it: four figures, 32 display equations; its tables' captions follow their cells, so
  // no block starts with "Table N" (the rule both clients share counts only captions that start with it).
  const dpo = JSON.parse(readFileSync(new URL('../../apple/ScienceReader/Resources/ReaderSamples/cd902bcdeeda373f6612f00221010f3fba918dcafbd500142d46ee53b2178a71/reader.json', import.meta.url), 'utf8'));
  const paper = starterPaper(dpo);
  expect(paper).toMatchObject({ figures: ['1', '2', '3', '4'], tables: [], equations: 32 });
  expect(paper.headings.slice(0, 5)).toEqual(['Abstract', '1 Introduction', '2 Related Work', '3 Preliminaries', '4 Direct Preference Optimization']);
  expect(methodHeading(paper.headings)).toBe('Direct Preference Optimization');
  // A table set as a figure, or a block that starts with its caption, names its number.
  expect(starterPaper({ figures: [{ caption: 'Table 3: Ablations' }], blocks: [{ text: 'Table 1. Main results 0.36' }, { text: 'cells Table 2: after' }],
    equations: [{ display: false }], headings: [] })).toEqual({ figures: [], tables: ['3', '1'], equations: 0, headings: [] });
  expect(chooseStarters(paper, 7)).toHaveLength(3);
 });

 it('ships the same pool in the native app', () => {
  const web = readFileSync(new URL('../src/lib/chat-starters.json', import.meta.url), 'utf8');
  const native = readFileSync(new URL('../../apple/ScienceReader/Resources/chat-starters.json', import.meta.url), 'utf8');
  expect(native).toBe(web);
 });
});
