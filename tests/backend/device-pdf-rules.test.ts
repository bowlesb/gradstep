// Converter rules added after the port kit (docs/reviews/DEVICE_PDF_ROUTE_20261021.md), each measured on real papers
// against their arXiv HTML before it became the default.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { contentsAsText, equationNumber, extendSpans, frontMatterRoles, lineOwners, mergeOverlapping, referenceEntries } from '../../supabase/functions/_shared/reader/device-pdf/convert.ts';
import { composeDevicePDFReader } from '../../supabase/functions/_shared/reader/device-pdf/bundle.ts';
import { validateHTML } from '../../supabase/functions/_shared/reader/html-validate.ts';
import { det, extent, host, input, line, page } from './device-pdf/synthetic.ts';
import { glyphsAgree, renderMath, tidyLatex } from '../../supabase/functions/_shared/reader/device-pdf/math.ts';
import { venueNotice } from '../../supabase/functions/_shared/reader/device-pdf/structure.ts';
import { aliasFont, aliasText } from '../../supabase/functions/_shared/reader/device-pdf/tagger.ts';
import { composeAccents, lineText, linesOf, typicalGap, useLineBands, useWordGaps } from '../../supabase/functions/_shared/reader/device-pdf/geometry.ts';
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

test('PLOS\'s renamed Computer Modern symbols read as the characters they print', () => {
  assert.equal(aliasText('ð', 'TeX_CM_Maths_Symbols'), '(');
  assert.equal(aliasText('¼', 'TeX_CM_Maths_Symbols'), '=');
  assert.equal(aliasText('ð', 'ABCDEF+CMR10'), 'ð', 'only in that font');
});

test('word gaps: justified lines and negatively tracked text still split into words', () => {
  // Letters 5 pt wide touching (gap 0), words 1.6 pt apart: under a fifth of an em (2 pt at 10 pt).
  const line = (gap: number, word: number): Glyph[] => {
    const out: Glyph[] = []; let x = 72;
    for (const w of ['routing', 'tokens', 'between', 'experts']) {
      for (const ch of w) { out.push({ text: ch, x0: x, x1: x + 5, top: 100, bottom: 110, size: 10, font: 'ABCDEF+MinionPro-Regular', upright: true }); x += 5 + gap; }
      x += word - gap;
    }
    return out;
  };
  const tight = line(0, 1.6);
  useWordGaps(null);
  assert.equal(lineText(tight, [])[0], 'routingtokensbetweenexperts', 'a fifth of an em is too wide a test for this line');
  useWordGaps(typicalGap([{ glyphs: tight }]));
  assert.equal(lineText(tight, [])[0], 'routing tokens between experts');
  const tracked = line(-0.17, 1.8); // PLOS: letters overlap by 0.017 em, words 0.18 em apart
  useWordGaps(typicalGap([{ glyphs: tracked }]));
  assert.equal(lineText(tracked, [])[0], 'routing tokens between experts');
  useWordGaps(null);
});

test('TeX\'s text accents compose with their letters; a math accent over another font stays', () => {
  const g = (text: string, x0: number, top: number, font = 'ABCDEF+CMR10'): Glyph => ({ text, x0, x1: x0 + 5, top, bottom: top + (text === '¨' ? 3 : 10), size: 10, font, upright: true });
  const naive = [g('N', 0, 100), g('a', 5, 100), g('¨', 10, 99), g('ı', 10, 100), g('v', 15, 100), g('e', 20, 100)];
  composeAccents(naive);
  assert.equal(naive.map(x => x.text).join(''), 'Naïve');
  // As the text layer gives it: the accent's box is the font's full height, like its letter's (PMLR's "Na¨ıve").
  const layer = [g('a', 150.5, 138.8), { ...g('¨', 154.3, 138.8), bottom: 148.8 }, { ...g('ı', 155.4, 138.8), x1: 158.2 }, g('v', 158.2, 138.8)];
  composeAccents(layer);
  assert.equal(layer.map(x => x.text).join(''), 'aïv');
  const hat = [g('ˆ', 0, 98), g('Z', 0, 100, 'ABCDEF+CMBX10')];
  composeAccents(hat);
  assert.deepEqual(hat.map(x => x.text), ['ˆ', 'Z'], '\\hat{\\mathbf{Z}}: the accent is the roman font\'s');
});

test('line bands: a lowered delimiter that reaches the next line does not join the two lines', () => {
  const at = (text: string, x0: number, top: number, h = 10.9): Glyph => ({ text, x0, x1: x0 + 5, top, bottom: top + h, size: 10, font: 'ABCDEF+CMR10', upright: true });
  // JMLR's venue PDF: "… function X_ij(·) at a finite level," with the parentheses' boxes 8 pt low, then the next line.
  const glyphs = [at('X', 0, 134.3), at('i', 6, 138.1, 8), at('p', 10, 142.1), at('q', 16, 142.1), at('a', 25, 134.3), at('t', 30, 134.3),
    at('u', 0, 147.8), at('s', 6, 147.8), at('e', 12, 147.8)];
  useLineBands(false);
  assert.equal(linesOf(glyphs).length, 1, 'the port kit\'s rule reads them as one line');
  useLineBands(true);
  assert.deepEqual(linesOf(glyphs).map(l => l.map(x => x.text).join('')), ['Xipqat', 'use']);
  // A line that opens with the line above's subscript keeps its own superscript ("N = 10^4"), and an accent joins.
  const scripts = [at('1', 0, 134.8, 7.6), at('N', 6, 131.0, 10), at('=', 12, 130.0, 10.4), at('1', 18, 131.2, 10), at('0', 24, 131.2, 10),
    at('4', 30, 129.3, 7.6), at('ˆ', 36, 128.5, 3), at('x', 36, 131.2, 10)];
  assert.equal(linesOf(scripts).length, 1);
  useLineBands(false);
});

test('verify glyphs: a reading whose letters, digits, accents and operators are the page\'s own passes the gate', () => {
  const math = (tex: string, display = false) => renderMath(tex, display)!;
  assert.ok(glyphsAgree(['y', '=', 'W', 'x', '+', 'b'], math('y=Wx+b')));
  assert.ok(!glyphsAgree(['y', '=', 'W', 'x', '+', 'b'], math('y=Wx-b')), 'an operator misread');
  assert.ok(!glyphsAgree(['y', '=', 'W', 'x', '+', 'b'], math('y=Wx+c')), 'a letter misread');
  assert.ok(glyphsAgree(['ˆ', 'x', '¯', 'y', '2'], math('\\hat{x}\\bar{y}^{2}')), 'accents as the text layer names them');
  assert.ok(!glyphsAgree(['ˆ', 'x', 'y'], math('\\tilde{x}y')), 'the wrong accent');
  assert.ok(glyphsAgree(['𝑥', '(cid:18)', 'ℝ', '∈'], math('x\\in\\mathbb{R}')), 'unnamed glyphs and styled letters');
  assert.ok(!glyphsAgree(['x'], math('x')), 'too little to tell');
  // End to end: a display read under the gate is typeset only when the rule is on and its glyphs agree.
  const L = 54, display = line('$y = W x + b$', 150, 130);
  const pages = [page([...line('Some words to read before it.', L, 100), ...display], [det('paragraph', extent(line('Some words to read before it.', L, 100))), det('display', extent(display, 3))])];
  const read = (latex: string, rules: object) => {
    const h = host(pages);
    h.recognise = crops => crops.map(() => ({ latex, probs: [0.6, 0.7, 0.99, 0.99] }));
    return new TextDecoder().decode(composeDevicePDFReader(input(1, { title: 'T', ...rules }), h).members.get('index.html')!);
  };
  assert.match(read('y=Wx+b', {}), /reader-display reader-math-image/);
  assert.match(read('y=Wx+b', { verifyGlyphs: true }), /reader-display"[^>]*><math display="block">/);
  assert.match(read('y=Wx-b', { verifyGlyphs: true }), /reader-display reader-math-image/);
  assert.match(read('y=Wx+b', { verifyGlyphs: 0.8 }), /reader-display reader-math-image/, 'under the floor');
});

test('display lines: a numbered display the layout read as a paragraph\'s line becomes a display', () => {
  const L = 54;
  const before = line('We minimise the loss over all of the weights and biases, giving', L, 100);
  const display = line('$y = W x + b$', 200, 125), tag = line('(3)', 520, 125);
  const after = line('where the weights are found by gradient descent on the data.', L, 150);
  const all = [...before, ...display, ...tag, ...after];
  const pages = [page(all, [det('paragraph', [L - 1, 99, 541, 161])])];
  const read = (rules: object) => new TextDecoder().decode(composeDevicePDFReader(input(1, { title: 'T', ...rules }), host(pages)).members.get('index.html')!);
  assert.doesNotMatch(read({}), /reader-display/);
  const on = read({ displayLines: true, equationNumbers: true });
  assert.match(on, /<p[^>]*data-reader-kind="paragraph"[^>]*>We minimise[^<]*giving<\/p><p[^>]*data-reader-kind="equation"[^>]*><span class="reader-equation reader-display/);
  assert.doesNotMatch(on, /\(3\)/, "the number goes with the display (its image keeps it), not into the text");
  assert.match(on, /data-reader-kind="paragraph"[^>]*>where the weights/);
  // A line of prose, or math without a number at the column's edge, stays in its paragraph.
  const prose = [...before, ...line('$x$ and $y$ are vectors here in this short line', 200, 125), ...tag, ...after];
  assert.doesNotMatch(new TextDecoder().decode(composeDevicePDFReader(input(1, { title: 'T', displayLines: true }), host([page(prose, [det('paragraph', [L - 1, 99, 541, 161])])])).members.get('index.html')!), /reader-display/);
  const unnumbered = [...before, ...display, ...after];
  assert.doesNotMatch(new TextDecoder().decode(composeDevicePDFReader(input(1, { title: 'T', displayLines: true }), host([page(unnumbered, [det('paragraph', [L - 1, 99, 541, 161])])])).members.get('index.html')!), /reader-display/);
});

test('reuse recognitions: a formula whose glyphs repeat an earlier one is not recognised again and reads the same', () => {
  const L = 54;
  // The same display twice on one page and once on the next, at different places; a different one beside them.
  const shown = (x: number, y: number, text = '$y = W x + b$') => line(text, x, y);
  const d1 = shown(L + 40, 200), d2 = shown(L + 40, 300), d3 = shown(L + 80, 150), other = shown(L + 40, 400, '$y = W x - c$');
  const para = line('A paragraph of plain words to read here.', L, 100);
  const pages = [page([...para, ...d1, ...d2, ...other], [det('paragraph', extent(para)), det('display', extent(d1, 3)), det('display', extent(d2, 3)), det('display', extent(other, 3))]),
    page([...d3], [det('display', extent(d3, 3))])];
  const read = (rules: object) => {
    const h = host(pages);
    const bundle = composeDevicePDFReader(input(2, { title: 'T', ...rules }), h);
    const index = JSON.parse(new TextDecoder().decode(bundle.members.get('reader.json')!));
    return { crops: h.log.crops.length, latex: index.equations.map((e: { latex: string }) => e.latex), html: new TextDecoder().decode(bundle.members.get('index.html')!) };
  };
  const off = read({}), on = read({ reuseRecognitions: true });
  assert.equal(off.crops, 4);
  assert.equal(on.crops, 2, 'the repeated display is read once');
  assert.equal(on.latex.length, 4);
  assert.equal(on.latex[1], on.latex[0]);
  assert.equal(on.latex[3], on.latex[0]);
  assert.equal(on.html.match(/reader-equation reader-display/g)?.length, off.html.match(/reader-equation reader-display/g)?.length);
});
