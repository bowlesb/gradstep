import { test } from 'node:test';
import assert from 'node:assert/strict';
import { completeRelations } from '../../scripts/device-pdf-models/relation_completion.ts';
import type { Glyph } from '../../supabase/functions/_shared/reader/device-pdf/types.ts';

const glyphs = (text: string): Glyph[] => {
  let x = 0;
  return [...text].flatMap(text => {
    if (text === ' ') { x += 3; return []; }
    const g = { text, font: 'Times-Roman', x0: x, x1: x + 5, top: 100, bottom: 110, size: 10, upright: true };
    x += 5; return [g];
  });
};
const span = (line: Glyph[], text: string): [number, number] => {
  const start = line.map(g => g.text).join('').indexOf(text);
  assert.ok(start >= 0); return [start, start + text.length];
};

test('model-supported scalar relations retain a cut variable, operator, number and uncertainty', () => {
  for (const [text, detected, complete] of [
    ['At each step, t > 1, the input', '>', 't>1'],
    ['feature layers. t = 0.25; next', '=0.25', 't=0.25'],
    ['β = 0.3).', '.3', 'β=0.3'],
    ['correlation r = 0.35 ± 0.03.', 'r=0.35', 'r=0.35±0.03'],
    ['p < 1e-3.', '1e', 'p<1e-3'],
  ]) {
    const line = glyphs(text), before = [span(line, detected)], copy = structuredClone(line);
    assert.deepEqual(completeRelations(line, before), [span(line, complete)]);
    assert.deepEqual(line, copy, 'original source glyphs and coordinates are retained');
    assert.deepEqual(before, [span(line, detected)], 'original spans are not mutated');
  }
});

test('scalar completion abstains on missing model support, word suffixes and larger expressions', () => {
  for (const [text, detected] of [
    ['context=5', '=5'], ['prefix + x=1', '=1'], ['x=1+y', '=1'], ['x=1/2', '=1'],
    ['x=1²', '=1'], ['x=1.2.3', '=1.2'], ['x=1,234', '=1'], ['x=1kg', '=1'],
  ]) {
    const line = glyphs(text), before = [span(line, detected)];
    assert.deepEqual(completeRelations(line, before), before, text);
  }
  assert.deepEqual(completeRelations(glyphs('p<0.001'), []), []);
});

test('completion preserves a neighboring accepted formula including its trailing separator', () => {
  const line = glyphs('t=0.2; C=5;');
  const before = [span(line, 't=0.2;'), span(line, '=5')];
  assert.deepEqual(completeRelations(line, before), [span(line, 't=0.2;'), span(line, 'C=5')]);
  const broader = [span(line, 't=0.2;C=5')];
  assert.deepEqual(completeRelations(line, broader), broader);
});

test('completion rejects unreliable glyph geometry and OCR rather than inventing a source span', () => {
  for (const change of [
    (g: Glyph) => { g.x0 += 40; g.x1 += 40; },
    (g: Glyph) => { g.top += 30; g.bottom += 30; },
    (g: Glyph) => { g.font = 'DevicePDFOCR'; },
    (g: Glyph) => { g.upright = false; },
    (g: Glyph) => { g.x0 = NaN; },
  ]) {
    const line = glyphs('t=1'), before: [number, number][] = [[1, 3]];
    change(line[0]); assert.deepEqual(completeRelations(line, before), before);
  }
});
