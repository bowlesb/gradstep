import { test } from 'node:test';
import assert from 'node:assert/strict';
import { longMarginGlyphs } from '../../supabase/functions/_shared/reader/device-pdf/structure.ts';
import { composeDevicePDFReader } from '../../supabase/functions/_shared/reader/device-pdf/bundle.ts';
import { type Box } from '../../supabase/functions/_shared/reader/device-pdf/types.ts';
import { det, extent, host, input, line, page } from './device-pdf/synthetic.ts';

const header = 'Research article Computational and Systems Biology | Evolutionary Biology';
const footer = 'Author and Colleague et al. Journal of Scientific Research DOI: example.test/paper';
const sample = (text = header, y = 30, size = 8) => ({
  height: 792, protected: [] as Box[],
  glyphs: [...line(text, 60, y, size), ...line('The actual body text starts here.', 60, 80), ...line('The body ends here.', 60, 700)],
});

test('long margin lines and their page counters recur at the same place on three distinct pages', () => {
  const pages = [1, 2, 3].map(n => sample(`${footer} ${n} of 3`, 750));
  const found = longMarginGlyphs(pages);
  assert.ok(found.every((gs, i) => gs.size === line(`${footer} ${i + 1} of 3`, 60, 750, 8).length));
  assert.ok(longMarginGlyphs(pages.slice(0, 2)).every(gs => gs.size === 0));
});

test('the same header text in the body stays, as does every other body glyph', () => {
  const pages = [1, 2, 3].map(() => {
    const p = sample(); p.glyphs.push(...line(header, 60, 300, 8)); return p;
  });
  const found = longMarginGlyphs(pages);
  found.forEach((gs, i) => {
    assert.equal(gs.size, line(header, 60, 30, 8).length);
    assert.ok(pages[i].glyphs.filter(g => g.top >= 80).every(g => !gs.has(g)));
  });
});

test('matching words alone do not remove lines with inconsistent position or typography', () => {
  for (const pages of [[15, 28, 40].map(y => sample(header, y)), [7, 8, 9].map(size => sample(header, 30, size))]) {
    assert.ok(longMarginGlyphs(pages).every(gs => gs.size === 0));
  }
  assert.ok(longMarginGlyphs([1, 2, 3].map(() => sample(header, 30, 14))).every(gs => gs.size === 0), 'large headings stay');
});

test('an inner margin line or a line closely stacked with body text is not a running header', () => {
  assert.ok(longMarginGlyphs([1, 2, 3].map(() => sample(header, 55))).every(gs => gs.size === 0));
  const close = [1, 2, 3].map(() => {
    const p = sample(); p.glyphs.push(...line('The sentence continues directly below this line.', 60, 41)); return p;
  });
  assert.ok(longMarginGlyphs(close).every(gs => gs.size === 0));
});

test('figure/table/caption regions, rotated text and OCR lines are protected', () => {
  const protectedPages = [1, 2, 3].map(() => ({ ...sample(), protected: [[50, 20, 600, 50]] as Box[] }));
  assert.ok(longMarginGlyphs(protectedPages).every(gs => gs.size === 0));
  for (const patch of [{ upright: false }, { font: 'GradstepOCR' }]) {
    const pages = [1, 2, 3].map(() => { const p = sample(); p.glyphs = p.glyphs.map(g => ({ ...g, ...patch })); return p; });
    assert.ok(longMarginGlyphs(pages).every(gs => gs.size === 0));
  }
});

test('different numbers within the sentence are not treated as equivalent running text', () => {
  for (const text of [(n: number) => `We measured ${n} cells in each of the experimental samples today.`,
    (n: number) => `The results of the experiment give a total cell count of ${n}`]) {
    assert.ok(longMarginGlyphs([1, 2, 3].map(n => sample(text(n)))).every(gs => gs.size === 0));
  }
});

test('removing a header from a shared layout region preserves body text and its PDF location', () => {
  const bodies = ['The first body passage is intact.', 'The second body passage is intact.', 'The third body passage is intact.'];
  const pages = bodies.map(text => {
    const h = line(header, 60, 30, 8), b = line(text, 60, 80), f = line(footer, 60, 750, 8);
    return page([...h, ...b, ...f], [det('paragraph', extent([...h, ...b])), det('paragraph', extent(f))]);
  });
  const bundle = composeDevicePDFReader(input(3, { title: 'Margin text' }), host(pages));
  const reader = JSON.parse(new TextDecoder().decode(bundle.members.get('reader.json')!));
  const provenance = JSON.parse(new TextDecoder().decode(bundle.members.get('provenance.json')!));
  assert.deepEqual(reader.blocks.filter((b: { kind: string }) => b.kind === 'paragraph').map((b: { text: string }) => b.text), bodies);
  assert.ok(provenance.blocks.every((r: number[]) => r[3] >= 79 && r[5] <= 91), 'only the original body region remains');
});
