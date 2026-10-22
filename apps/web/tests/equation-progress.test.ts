// The equation explainer's progress bar (equation-progress.ts): the shared cases both clients reproduce
// (tests/fixtures/equation-progress.json; Swift FigureProgressTests). UPDATE_PROGRESS_FIXTURE=1 rewrites the expectations
// from this implementation (review the labels and values in the diff).
import { describe, expect, it } from 'vitest';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { EQUATION_PROGRESS, equationProgress } from '../src/lib/equation-progress';
import type { FigureProgressInput } from '../src/lib/figure-progress';

const FIXTURE = resolve(__dirname, '../../../tests/fixtures/equation-progress.json');
const base: FigureProgressInput = { stage: 'writing', summary: false, parts: 0, characters: 0, charactersAtLast: 0, expected: 10, previous: null };
const CASES: [string, Partial<FigureProgressInput>][] = [
  ['preparing', { stage: 'preparing' }],
  ['reading', { stage: 'reading' }],
  ['count not yet announced', { expected: null, characters: 8 }],
  ['summary started', { characters: 120 }],
  ['summary over its estimate stays within its share', { characters: 900 }],
  ['summary in, symbol 1 begun', { summary: true, characters: 400, charactersAtLast: 330 }],
  ['symbol 1 long: capped below the symbol', { summary: true, characters: 2_000, charactersAtLast: 330 }],
  ['symbol 5', { summary: true, parts: 4, characters: 1_200, charactersAtLast: 1_130, previous: 0.4 }],
  ['never goes back', { summary: true, parts: 4, characters: 1_130, charactersAtLast: 1_130, previous: 0.5 }],
  ['last symbol', { summary: true, parts: 9, characters: 2_100, charactersAtLast: 2_000, previous: 0.9 }],
  ['more symbols than announced: indeterminate', { summary: true, parts: 10, characters: 2_300, charactersAtLast: 2_200, previous: 0.99 }],
  ['no count: symbol 3', { summary: true, parts: 2, characters: 800, charactersAtLast: 700, expected: null }],
  ['done', { stage: 'done', summary: true, parts: 10 }],
];

describe('equation progress', () => {
  it('reproduces the shared cases', () => {
    const cases = CASES.map(([name, change]) => { const input = { ...base, ...change }; return { name, input, expected: equationProgress(input) }; });
    if (process.env.UPDATE_PROGRESS_FIXTURE) writeFileSync(FIXTURE, JSON.stringify({ parameters: EQUATION_PROGRESS, cases }, null, 1) + '\n');
    const fixture = JSON.parse(readFileSync(FIXTURE, 'utf8'));
    expect(fixture.parameters).toEqual(EQUATION_PROGRESS);
    for (const c of fixture.cases) expect(equationProgress(c.input), c.name).toEqual(c.expected);
    expect(fixture.cases.map((c: { name: string }) => c.name)).toEqual(CASES.map(c => c[0]));
  });
  it('says "Explaining symbol k of N" only when N is known, and never goes back', () => {
    expect(equationProgress({ ...base, stage: 'reading' }).label).toBe('Reading the equation…');
    expect(equationProgress({ ...base, summary: true, parts: 2 }).label).toBe('Explaining symbol 3 of 10…');
    expect(equationProgress({ ...base, summary: true, parts: 2, expected: null })).toEqual({ label: 'Explaining symbol 3…', value: null });
    expect(equationProgress({ ...base, summary: true, parts: 10 })).toEqual({ label: 'Explaining symbol 11…', value: null });
    let previous: number | null = null; const seen: number[] = [];
    for (const step of [{ characters: 100 }, { summary: true, characters: 330, charactersAtLast: 330 }, { summary: true, parts: 1, characters: 540, charactersAtLast: 530 },
      { summary: true, parts: 1, characters: 600, charactersAtLast: 530 }, { summary: true, parts: 2, characters: 700, charactersAtLast: 700 }]) {
      const s = equationProgress({ ...base, ...step, previous }); seen.push(s.value!); previous = s.value;
    }
    expect(seen.every((v, i) => i === 0 || v >= seen[i - 1])).toBe(true);
  });
});
