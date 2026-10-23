// Converter rules added after the port kit (docs/reviews/DEVICE_PDF_ROUTE_20261021.md), each measured on real papers
// against their arXiv HTML before it became the default.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { contentsAsText, equationNumber, extendSpans, frontMatterRoles, lineOwners, mergeOverlapping, referenceEntries } from '../../supabase/functions/_shared/reader/device-pdf/convert.ts';
import { composeDevicePDFReader } from '../../supabase/functions/_shared/reader/device-pdf/bundle.ts';
import { validateHTML } from '../../supabase/functions/_shared/reader/html-validate.ts';
import { det, extent, host, input, line, page } from './device-pdf/synthetic.ts';
import { renderMath, tidyLatex } from '../../supabase/functions/_shared/reader/device-pdf/math.ts';
import { venueNotice } from '../../supabase/functions/_shared/reader/device-pdf/structure.ts';
import { aliasFont } from '../../supabase/functions/_shared/reader/device-pdf/tagger.ts';
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

test('a formula the tagger cut short grows over touching digits, operators and an operator name', () => {
  // Glyphs at x (points), 5 pt wide unless given, in stream order.
  const gl = (text: string, font: string, x: number, w = 5): Glyph => ({ text, x0: x, x1: x + w, top: 90, bottom: 100, size: 10, font: `ABCDEF+${font}`, upright: true });
  const cos = [gl('c', 'CMR10', 0, 4), gl('o', 'CMR10', 4, 5), gl('s', 'CMR10', 9, 4), gl('θ', 'CMMI10', 14.5)];
  assert.deepEqual(extendSpans(cos, [[3, 4]]), [[0, 4]]);
  const pm = [...'63.6'].map((c, i) => gl(c, 'CMR10', i * 5)).concat([gl('±', 'CMSY10', 20)], [...'3.9'].map((c, i) => gl(c, 'CMR10', 25 + i * 5)));
  assert.deepEqual(extendSpans(pm, [[4, 5]]), [[0, 8]]);
  const word = [gl('a', 'CMR10', 0), gl('n', 'CMR10', 5), gl('d', 'CMR10', 10), gl('x', 'CMMI10', 18), gl('.', 'CMR10', 23, 2)];
  assert.deepEqual(extendSpans(word, [[3, 4]]), [[3, 4]], 'a word before a space and a closing full stop stay outside');
  const two = [gl('x', 'CMMI10', 0), gl('=', 'CMR10', 5), gl('y', 'CMMI10', 10)];
  assert.deepEqual(extendSpans(two, [[0, 1], [2, 3]]), [[0, 3]], 'x = y tagged as two meets as one');
  const apart = [gl('x', 'CMMI10', 0), gl(',', 'CMMI10', 5, 2), gl('y', 'CMMI10', 12)];
  assert.deepEqual(extendSpans(apart, [[0, 1], [2, 3]]), [[0, 1], [2, 3]], 'formulas set apart stay apart');
});

test('a heading line split between two boxes goes whole to the box holding most of it', () => {
  const glyphs = words('Electrostatic droplet size', 100, 12);
  const heading = region('heading', 98, 114), paragraph = region('paragraph', 98, 300);
  // The heading's box starts at the 12th character; the paragraph box beside it holds the first eleven.
  const owner = glyphs.map((_, i) => (i < 11 ? paragraph : heading));
  assert.deepEqual(lineOwners(glyphs, owner).map(o => o?.cls), glyphs.map(() => 'heading'));
  const columns = [...words('left column text', 100), ...words('right', 100).map(g => ({ ...g, x0: g.x0 + 260, x1: g.x1 + 260 }))];
  const split = columns.map((_, i) => (i < 16 ? paragraph : heading));
  assert.deepEqual(lineOwners(columns, split), split, 'a gutter ends the run');
});

test('a references region holding several entries reads as its entries', () => {
  const at = (text: string, x: number, top: number) => words(text, top).map(g => ({ ...g, x0: g.x0 + x, x1: g.x1 + x }));
  // Author–year with a hanging indent: entries start 1 em further left than their continuation lines.
  const hanging = [at('Adams, J. and Brown, K. Learning to read', 0, 100), at('papers. In Proc. NeurIPS, 2024.', 10, 112),
    at('Chen, L. Formulas from pixels. arXiv,', 0, 124), at('2025.', 10, 136)];
  assert.deepEqual(referenceEntries(hanging, ['Adams, J. and Brown, K. Learning to read', 'papers. In Proc. NeurIPS, 2024.', 'Chen, L. Formulas from pixels. arXiv,', '2025.']),
    ['Adams, J. and Brown, K. Learning to read papers. In Proc. NeurIPS, 2024.', 'Chen, L. Formulas from pixels. arXiv, 2025.']);
  // Numbered: the labels decide, whatever the indents.
  const numbered = ['[1] A. Author. A title that runs', 'over two lines. 2024.', '[2] B. Author. Another. 2025.'];
  assert.deepEqual(referenceEntries(numbered.map((t, i) => at(t, 0, 100 + 12 * i)), numbered), ['[1] A. Author. A title that runs over two lines. 2024.', '[2] B. Author. Another. 2025.']);
});

test('a printed contents list is text, not three more sections', () => {
  const h = (text: string, trace: string) => ({ kind: 'heading' as const, level: 2, marked: text, text, trace });
  const p = (text: string) => ({ kind: 'paragraph' as const, marked: text, text, role: '' as const });
  const blocks = [h('Contents', 'b1'), h('1 Introduction 2', 'b2'), h('2 Method 5', 'b3'), h('3 Results 9', 'b4'), p('We study …'),
    h('1 Introduction', 'b5'), p('…'), h('2 Method', 'b6'), p('…'), h('3 Results', 'b7')];
  const trace = { format: 'reader-index-v1', title: '', figures: [], equations: [],
    blocks: blocks.map((b, i) => ({ id: `b${i + 1}`, kind: b.kind, text: b.text })),
    headings: blocks.filter(b => b.kind === 'heading').map(b => ({ id: (b as { trace: string }).trace, level: 2, title: b.text })) };
  contentsAsText(blocks, trace);
  assert.deepEqual(blocks.map(b => b.kind), ['heading', 'paragraph', 'paragraph', 'paragraph', 'paragraph', 'heading', 'paragraph', 'heading', 'paragraph', 'heading']);
  assert.deepEqual(trace.headings.map(x => x.id), ['b1', 'b5', 'b6', 'b7']);
  assert.equal(trace.blocks[1].kind, 'paragraph');
  const two = [h('1 Introduction', 'c1'), h('2 Method', 'c2'), p('…'), h('1 Introduction', 'c3'), h('2 Method', 'c4')];
  contentsAsText(two, { ...trace, blocks: [], headings: [] });
  assert.equal(two[0].kind, 'heading', 'two repeated headings in a row are not a contents list');
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

test('a display\'s equation number set apart at its right is left out of the formula and kept as its tag', () => {
  const display = [...words('y = W x + b', 100), ...words('(12)', 100).map(g => ({ ...g, x0: g.x0 + 300, x1: g.x1 + 300 }))];
  const found = equationNumber(display);
  assert.equal(found?.tag, '(12)');
  assert.equal(found?.body.map(g => g.text).join('').trim(), 'y = W x + b');
  assert.equal(equationNumber(words('f(x) = (12)', 100)), null, 'a parenthesis in the formula is not a number');
  const rows = [...words('a = b', 100), ...words('(3a)', 100).map(g => ({ ...g, x0: g.x0 + 300, x1: g.x1 + 300 })),
    ...words('c = d', 115), ...words('(3b)', 115).map(g => ({ ...g, x0: g.x0 + 300, x1: g.x1 + 300 }))];
  assert.equal(equationNumber(rows)?.tag, '(3a) (3b)');
  const centred = [...words('a = b', 100), ...words('c = d', 125), ...words('(4)', 112).map(g => ({ ...g, x0: g.x0 + 300, x1: g.x1 + 300 }))];
  assert.equal(equationNumber(centred)?.tag, '(4)', 'a number centred between two rows');
  // Two-column REVTeX: "…+ f_p], (7)" with little more than half an em before the number, flush with the column's edge.
  const tight = [...words('F = x + y,', 100), ...words('(7)', 100).map(g => ({ ...g, x0: g.x0 + 66, x1: g.x1 + 66 }))];
  assert.equal(equationNumber(tight), null, 'not set apart enough without the box edge');
  assert.equal(equationNumber(tight, 72 + 66 + 3 * 6 + 2)?.tag, '(7)', 'flush with the display box\'s right edge');
});

test('overlapping reference boxes in one column are read as one region; columns stay apart', () => {
  const at = (cls: string, x0: number, top: number, x1: number, bottom: number): Region => ({ cls, score: 0.8, box: [x0, top, x1, bottom].map(v => v * 150 / 72), pt: [x0, top, x1, bottom] });
  const merged = mergeOverlapping([at('bibitem', 54, 100, 290, 600), at('bibitem', 56, 300, 288, 700), at('paragraph', 54, 100, 290, 200),
    at('bibitem', 315, 100, 550, 700)], 'bibitem');
  assert.deepEqual(merged.map(r => [r.cls, Math.round(r.pt[1]), Math.round(r.pt[3])]), [['paragraph', 100, 200], ['bibitem', 100, 700], ['bibitem', 100, 700]]);
  assert.equal(merged.filter(r => r.cls === 'bibitem').length, 2);
});

test('rules end to end: caption math, an equation number as a tag, a bibliography without a heading', () => {
  const L = 54;
  const para = line('A paragraph with $x$ in it, and more words follow here.', L, 100);
  const display = line('$y = W x + b$', 110, 130), tag = line('(7)', 400, 130);
  const caption = line('Figure 1: The loss $L$ falls with $k$ experts.', L, 330, 9);
  const refs = [line('[1] A. Author. A first paper on routing. 2020.', L, 400), line('[2] B. Author. A second paper,', L, 415),
    line('with a long title. 2021.', L + 10, 430), line('[3] C. Author. A third. 2022.', L, 445)];
  const pages = [page([...para, ...display, ...tag, ...caption, ...refs.flat()], [
    det('paragraph', extent(para), 0.9), det('display', extent([...display, ...tag], 3), 0.9), det('figure', [L, 160, 400, 320], 0.9),
    det('caption', extent(caption), 0.9), det('bibitem', extent([...refs[0], ...refs[1], ...refs[2]]), 0.8), det('bibitem', extent([...refs[2], ...refs[3]]), 0.8),
  ])];
  const read = (rules: object) => {
    const bundle = composeDevicePDFReader(input(1, { title: 'T', displayGate: 0.9, ...rules }), host(pages));
    const index = JSON.parse(new TextDecoder().decode(bundle.members.get('reader.json')!));
    return { html: new TextDecoder().decode(bundle.members.get('index.html')!), index, bundle };
  };
  const off = read({});
  assert.ok(!/<figcaption>[^<]*<span class="reader-equation/.test(off.html));
  const on = read({ captionMath: true, equationNumbers: true, bibliography: true, splitReferences: true });
  assert.match(on.html, /<figcaption>Figure 1: The loss <span class="reader-equation reader-inline"/);
  assert.match(on.html, /class="reader-equation reader-display reader-tagged"[^>]*><math display="block">.*?<\/math><span class="reader-tag">\(7\)<\/span>/);
  assert.match(on.html, /<ul class="reader-references"><li[^>]*>\[1\] A\. Author[^<]*<\/li><li[^>]*>\[2\] B\. Author\. A second paper, with a long title\. 2021\.<\/li><li[^>]*>\[3\]/);
  const figure = on.index.figures[0];
  assert.match(figure.caption, /^Figure 1: The loss .+ falls with .+ experts\.$/);
  assert.ok(on.index.equations.some((e: { block_id: string }) => e.block_id === figure.block_id), 'caption formulas belong to the figure');
});

test('the venue\'s notice on a first page is found: the proceedings line at the foot, the watermark at the head', () => {
  const body = Array.from({ length: 20 }, (_, i) => words('We study the problem of routing and find that it matters.', 200 + i * 14, 11)).flat();
  const affiliation = words('1Department of Things. Correspondence to: A. Author.', 690, 9);
  const notice = [...words('Proceedings of the 41st International Conference on Machine', 702, 9), ...words('Learning, Vienna, Austria. PMLR 235, 2024.', 713, 9)];
  const watermark = words('This CVPR paper is the Open Access version, provided by the Computer Vision Foundation.', 20, 8);
  const found = new Set(venueNotice([...watermark, ...body, ...affiliation, ...notice], 792));
  assert.ok([...notice, ...watermark].every(g => found.has(g) || !g.text.trim()));
  assert.ok(![...body, ...affiliation].some(g => found.has(g)), 'the text and the affiliation line above the notice stay');
  const ownText = words('as presented at the Conference on Learning Theory.', 700, 11);
  assert.equal(venueNotice([...body, ...ownText], 792).length, 0, 'the paper\'s own text at the foot, in its own size, stays');
});

test('fonts the tagger does not know read as the ones they stand for', () => {
  const vocab = { font_vocab: { CMMI: 12, CMSY: 20, CMEX: 94, CMR: 2, MSBM: 102, 'LMMathItalic10-Regular': 64 } };
  assert.equal(aliasFont('ABCDEF+CMMI10', vocab), 'ABCDEF+CMMI10', 'a known font is kept');
  assert.equal(aliasFont('ABCDEF+LMMathItalic6-Regular', vocab), 'LMMathItalic10-Regular', 'a Latin Modern size as its 10 pt design');
  assert.equal(aliasFont('ABCDEF+MathDesign-CH-Regular-Italic-MathItalic-10', vocab), 'CMMI10');
  assert.equal(aliasFont('ABCDEF+MathDesign-CH-Regular-Symbol-10', vocab), 'CMSY10');
  assert.equal(aliasFont('ABCDEF+MathDesign-CH-Regular-Extension-10', vocab), 'CMEX10');
  assert.equal(aliasFont('ABCDEF+MathDesign-CH-Regular-OT1-10', vocab), 'CMR10');
  assert.equal(aliasFont('ABCDEF+TeX-matha', vocab), 'CMSY10');
  assert.equal(aliasFont('ABCDEF+GoogleSans-Regular', vocab), 'ABCDEF+GoogleSans-Regular', 'a text font it cannot place is kept');
});
