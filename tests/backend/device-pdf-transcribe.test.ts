// Simple inline formulas written from the PDF's text layer (device-pdf/transcribe.ts, docs/reviews/DEVICE_PDF_ROUTE_20261021.md):
// what is written, and every shape that must go to the recogniser instead.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mathStyle, transcribe } from '../../supabase/functions/_shared/reader/device-pdf/transcribe.ts';
import { renderMath } from '../../supabase/functions/_shared/reader/device-pdf/math.ts';
import type { Glyph } from '../../supabase/functions/_shared/reader/device-pdf/types.ts';

/** A glyph at x (points) on a 10 pt line whose baseline is at 100: `dy` moves its centre (positive is lower). */
function g(text: string, font: string, x: number, size = 10, dy = 0, width = 0.5 * size): Glyph {
  const centre = 97.5 + dy;
  return { text, x0: x, x1: x + width, top: centre - size / 2, bottom: centre + size / 2, size, font: `ABCDEF+${font}`, upright: true };
}

test('letters, digits and symbols in Computer Modern are written as TeX writes them', () => {
  assert.equal(transcribe([g('x', 'CMMI10', 0)], 10), 'x');
  assert.equal(transcribe([g('α', 'CMMI10', 0)], 10), '\\alpha');
  assert.equal(transcribe([g('Γ', 'CMR10', 0)], 10), '\\Gamma');
  assert.equal(transcribe([g('x', 'CMMI10', 0), g('∈', 'CMSY10', 6), g('R', 'MSBM10', 14)], 10), 'x\\in\\mathbb{R}');
  assert.equal(transcribe([g('n', 'CMMI10', 0), g('=', 'CMR10', 6), g('1', 'CMR10', 14), g('0', 'CMR10', 19)], 10), 'n=10');
  assert.equal(transcribe([g('l', 'CMR10', 0, 10, 0, 3), g('o', 'CMR10', 3), g('g', 'CMR10', 8), g('p', 'CMMI10', 15)], 10), '\\log p');
  assert.equal(transcribe([g('D', 'CMSY10', 0)], 10), '\\mathcal{D}');
  assert.equal(transcribe([g('∈', 'CMSY10', 0), g('x', 'CMMI10', 8)], 10), '\\in x', 'a control word never runs into a letter');
});

test('one level of sub- and superscripts attached to the glyph before them', () => {
  assert.equal(transcribe([g('x', 'CMMI10', 0), g('i', 'CMMI7', 5.2, 7, 2)], 10), 'x_{i}');
  assert.equal(transcribe([g('R', 'MSBM10', 0), g('d', 'CMMI7', 5.2, 7, -3.5)], 10), '\\mathbb{R}^{d}');
  assert.equal(transcribe([g('x', 'CMMI10', 0), g('i', 'CMMI7', 5.2, 7, 2), g('2', 'CMR7', 5.4, 7, -3.5)], 10), 'x_{i}^{2}');
  assert.equal(transcribe([g('x', 'CMMI10', 0), g('′', 'CMSY7', 5.3, 7, -3.5)], 10), 'x^{\\prime}');
  assert.equal(transcribe([g('W', 'CMMI10', 0), g('m', 'CMR7', 5.1, 7, 2), g('a', 'CMR7', 9, 7, 2), g('x', 'CMR7', 12.5, 7, 2)], 10), 'W_{\\max}');
  for (const tex of ['x_{i}^{2}', '\\mathbb{R}^{d}', 'W_{\\max}', '\\log p']) assert.ok(renderMath(tex, false), `${tex} renders`);
});

test('anything else goes to the recogniser', () => {
  assert.equal(transcribe([g('x', 'SomeSans-Italic', 0)], 10), null, 'a font that does not say its role');
  assert.equal(transcribe([g('∑', 'CMEX10', 0)], 10), null, 'a big operator');
  assert.equal(transcribe([g('√', 'CMSY10', 0), g('x', 'CMMI10', 8)], 10), null, 'a radical (its bar is a rule, not a glyph)');
  assert.equal(transcribe([g('a', 'CMMI7', 1, 7, -3.5), g('b', 'CMMI7', 1, 7, 2)], 10), null, 'a text-style fraction: scripts with no base');
  assert.equal(transcribe([g('y', 'CMMI10', 0), g('a', 'CMMI7', 7.5, 7, -3.5), g('b', 'CMMI7', 7.5, 7, 2)], 10), null, 'a fraction after a letter stands apart');
  assert.equal(transcribe([g('x', 'CMMI10', 0), g('ˆ', 'CMR10', 0.5)], 10), null, 'an accent');
  assert.equal(transcribe([g('x', 'CMMI10', 0), g('i', 'CMMI7', 5.2, 7, 2), g('j', 'CMMI5', 8.5, 5, 3)], 10), null, 'a script of a script');
  assert.equal(transcribe([g('x', 'CMMI10', 0), g('y', 'CMMI10', 0.5, 10, 4)], 10), null, 'stacked full-size glyphs');
  assert.equal(transcribe([g(',', 'CMMI10', 0)], 10), null, 'punctuation alone is not a formula');
  assert.equal(transcribe([g('A', 'CMMI10', 0, 10)], 6), null, 'a glyph far larger than its line');
});

test('font roles by name', () => {
  assert.equal(mathStyle('XYZABC+CMMI10'), 'italic');
  assert.equal(mathStyle('CMMIB10'), 'boldItalic');
  assert.equal(mathStyle('CMBX12'), 'bold');
  assert.equal(mathStyle('LMRoman10-Regular'), 'roman');
  assert.equal(mathStyle('MSBM10'), 'blackboard');
  assert.equal(mathStyle('CMSY10'), 'symbol');
  assert.equal(mathStyle('Helvetica'), null);
});
