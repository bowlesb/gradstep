// Converter rules added after the port kit (docs/reviews/DEVICE_PDF_ROUTE_20261021.md), each measured on real papers
// against their arXiv HTML before it became the default.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { frontMatterRoles } from '../../supabase/functions/_shared/reader/device-pdf/convert.ts';
import { renderMath, tidyLatex } from '../../supabase/functions/_shared/reader/device-pdf/math.ts';
import type { Glyph, Region } from '../../supabase/functions/_shared/reader/device-pdf/types.ts';

/** A line of text as glyphs from x = 72 at `top` (points), 6 pt per character. */
function words(text: string, top: number, size = 10): Glyph[] {
  return [...text].map((ch, i) => ({ text: ch, x0: 72 + i * 6, x1: 72 + i * 6 + (ch === ' ' ? 0 : 5), top, bottom: top + size, size, font: 'ABCDEF+CMR10', upright: true }));
}
const region = (cls: string, top: number, bottom: number): Region => ({ cls, score: 0.9, box: [72 * 150 / 72, top * 150 / 72, 540 * 150 / 72, bottom * 150 / 72], pt: [72, top, 540, bottom] });

test('a REVTeX title page: the title read as a heading becomes the title, author lines join the author block', () => {
  const glyphs = [...words('Chirality destroys oriented active solids', 80, 14), ...words('S. J. Kole,1, *', 110), ...words('Gareth P. Alexander,2 and Sriram Ramaswamy5', 125),
    ...words('1 Introduction', 300), ...words('We construct a hydrodynamic theory', 160)];
  const regions = [region('heading', 78, 96), region('heading', 108, 120), region('heading', 123, 136), region('abstract', 158, 172), region('heading', 298, 312)];
  frontMatterRoles(regions, glyphs, { title: 'Chirality Destroys Oriented Active Solids', authors: ['S. J. Kole', 'Gareth P. Alexander', 'Ananyo Maitra', 'Sriram Ramaswamy'] });
  assert.deepEqual(regions.map(r => r.cls), ['title', 'paragraph', 'paragraph', 'abstract', 'heading']);
});

test('nothing changes without the library\'s title and authors, or when the layout found the title', () => {
  const glyphs = [...words('A Title', 80, 14), ...words('Ada Lovelace', 110), ...words('2 Method', 125)];
  const regions = [region('title', 78, 96), region('heading', 108, 120), region('heading', 123, 136), region('paragraph', 160, 170)];
  frontMatterRoles(regions, glyphs, {});
  assert.deepEqual(regions.map(r => r.cls), ['title', 'heading', 'heading', 'paragraph']);
  frontMatterRoles(regions, glyphs, { title: 'Another Title', authors: ['Ada Lovelace', 'Charles Method'] });
  assert.deepEqual(regions.map(r => r.cls), ['title', 'paragraph', 'heading', 'paragraph'], 'a numbered section keeps its heading even when a name matches');
});

test('the recogniser\'s LaTeXML-style rows and package commands are tidied into what Temml renders', () => {
  const rows = '\\displaystyle a & \\displaystyle=b+c, \\\\ \\displaystyle d & \\displaystyle=e.';
  assert.equal(renderMath(rows, true), null, 'Temml refuses a bare &');
  assert.equal(tidyLatex(rows), `\\begin{aligned}${rows}\\end{aligned}`);
  assert.ok(renderMath(tidyLatex(rows), true));
  assert.equal(tidyLatex('\\mathbbm{1}(x>0)'), '\\mathbb{1}(x>0)');
  assert.equal(tidyLatex('\\overset{\\text{\\scalebox{0.6}{$\\circ$}}}{\\lambda}'), '\\overset{\\text{{$\\circ$}}}{\\lambda}', 'its argument stays in its group');
  assert.equal(tidyLatex('\\begin{cases}a & b\\end{cases}'), '\\begin{cases}a & b\\end{cases}', 'an environment is left as it is');
});
