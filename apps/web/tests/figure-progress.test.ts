// The figure explainer's progress bar (figure-progress.ts): the shared cases both clients reproduce
// (tests/fixtures/figure-progress.json; Swift FigureProgressTests). UPDATE_PROGRESS_FIXTURE=1 rewrites the expectations
// from this implementation (review the labels and values in the diff).
import { describe, expect, it } from 'vitest';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { expectedParts, figureProgress, FIGURE_PROGRESS, type FigureProgressInput } from '../src/lib/figure-progress';

const FIXTURE = resolve(__dirname, '../../../tests/fixtures/figure-progress.json');
const base: FigureProgressInput = { stage: 'writing', summary: false, parts: 0, characters: 0, charactersAtLast: 0, expected: 3, previous: null };
const CASES: [string, Partial<FigureProgressInput>][] = [
  ['preparing', { stage: 'preparing' }],
  ['reading', { stage: 'reading' }],
  ['summary started', { characters: 120 }],
  ['summary nearly written', { characters: 480 }],
  ['summary over its estimate stays within its share', { characters: 2_000 }],
  ['summary in, part 1 begun', { summary: true, characters: 700, charactersAtLast: 520 }],
  ['part 1 halfway', { summary: true, characters: 1_270, charactersAtLast: 520 }],
  ['part 1 long: capped below the part', { summary: true, characters: 9_000, charactersAtLast: 520 }],
  ['part 2 begun', { summary: true, parts: 1, characters: 2_100, charactersAtLast: 2_050, previous: 0.4 }],
  ['never goes back', { summary: true, parts: 1, characters: 2_100, charactersAtLast: 2_100, previous: 0.5 }],
  ['last part', { summary: true, parts: 2, characters: 4_000, charactersAtLast: 3_700, previous: 0.7 }],
  ['more parts than expected: indeterminate', { summary: true, parts: 3, characters: 5_000, charactersAtLast: 4_900, previous: 0.97 }],
  ['unknown count', { summary: true, parts: 1, characters: 2_100, charactersAtLast: 2_000, expected: null }],
  ['unknown count, summary', { expected: null, characters: 100 }],
  ['a part before any summary', { parts: 1, characters: 1_600, charactersAtLast: 1_550 }],
  ['done', { stage: 'done', summary: true, parts: 3 }],
  ['two expected, first part', { summary: true, expected: 2, characters: 1_300, charactersAtLast: 500 }],
];

describe('figure progress', () => {
  it('reproduces the shared cases', () => {
    const cases = CASES.map(([name, change]) => { const input = { ...base, ...change }; return { name, input, expected: figureProgress(input) }; });
    if (process.env.UPDATE_PROGRESS_FIXTURE) writeFileSync(FIXTURE, JSON.stringify({ parameters: FIGURE_PROGRESS, expectedParts: [
      [null, 0, null], [3, 0, 3], [1, 4, 4], [null, 2, 2], [null, 1, null], [2, 5, 2]], cases }, null, 1) + '\n');
    const fixture = JSON.parse(readFileSync(FIXTURE, 'utf8'));
    expect(fixture.parameters).toEqual(FIGURE_PROGRESS);
    for (const c of fixture.cases) expect(figureProgress(c.input), c.name).toEqual(c.expected);
    expect(fixture.cases.map((c: { name: string }) => c.name)).toEqual(CASES.map(c => c[0]));
    for (const [subfigures, letters, n] of fixture.expectedParts) expect(expectedParts(subfigures, letters)).toBe(n);
  });
  it('is honest: indeterminate without a count, never backwards, never stuck below done', () => {
    let previous: number | null = null;
    const seen: (number | null)[] = [];
    // A walkthrough of three parts arriving as the server reports characters.
    const steps: Partial<FigureProgressInput>[] = [{ characters: 200 }, { characters: 500, summary: true, charactersAtLast: 500 },
      { summary: true, characters: 1_200, charactersAtLast: 500 }, { summary: true, parts: 1, characters: 2_000, charactersAtLast: 2_000 },
      { summary: true, parts: 2, characters: 3_600, charactersAtLast: 3_500 }, { summary: true, parts: 2, characters: 4_900, charactersAtLast: 3_500 }];
    for (const step of steps) { const s = figureProgress({ ...base, ...step, previous }); seen.push(s.value); previous = s.value; }
    expect(seen.every((v, i) => v !== null && (i === 0 || v >= seen[i - 1]!))).toBe(true);
    expect(seen.at(-1)!).toBeLessThan(1);
    expect(figureProgress({ ...base, stage: 'done' }).value).toBe(1);
    expect(figureProgress({ ...base, expected: null, summary: true, parts: 2 }).value).toBeNull();
  });
});
