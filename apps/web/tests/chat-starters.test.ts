import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { captionNumbers, chooseStarters, methodHeading, starterRandom } from '../src/lib/chat-starters';

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

 it('ships the same pool in the native app', () => {
  const web = readFileSync(new URL('../src/lib/chat-starters.json', import.meta.url), 'utf8');
  const native = readFileSync(new URL('../../apple/ScienceReader/Resources/chat-starters.json', import.meta.url), 'utf8');
  expect(native).toBe(web);
 });
});
