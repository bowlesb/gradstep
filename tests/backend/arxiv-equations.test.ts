import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { arxivHTMLURL, convertArxivHTML } from '../../supabase/functions/_shared/reader/arxiv-html.ts';
import { ARXIV_CSS, composeArxivReader } from '../../supabase/functions/_shared/reader/arxiv-bundle.ts';
import { admitReaderImage } from '../../supabase/functions/_shared/reader/images.ts';
import { validateReaderBundle } from '../../supabase/functions/_shared/reader/validate.ts';
import { render } from '../../supabase/functions/_shared/reader/html.ts';
import { MATH_TABLE_CSS } from '../../supabase/functions/_shared/reader/profile.ts';
import { renderMath } from '../../supabase/functions/_shared/reader/device-pdf/math.ts';
import { DEVICE_PDF_CSS } from '../../supabase/functions/_shared/reader/device-pdf/bundle.ts';
import { readerAccents } from '../../supabase/functions/_shared/reader/accents.ts';
import { sha256Hex, utf8 } from '../../supabase/functions/_shared/reader/util.ts';

// Revision 26 (owner, TestFlight 92, 2610.27450v1 "Ask to Distill"): an aligned group is one display equation per number,
// its relations aligned, instead of every LaTeXML cell on a centred line of its own (equation (2)); and accents are drawn
// over their letter in WebKit (equation (3)'s \bar{p}^U_M had its bar off to the left). Fragments are LaTeXML's own
// markup from the paper, reduced.

const url = arxivHTMLURL('2601.01234', 2);
const source = readFileSync(new URL('../fixtures/reader-arxiv/source.html', import.meta.url), 'utf8');
const raw = new Uint8Array(readFileSync(new URL('../fixtures/reader-mathpix/figure-exif.jpg', import.meta.url)));
const image = { ...admitReaderImage(raw), inputSHA256: sha256Hex(raw) };
const stub = () => ({ path: `assets/${'0'.repeat(64)}.png`, width: 10, height: 10 });
const insert = (html: string) => source.replace('<p id="p1">', html + '<p id="p1">');
const convert = (html: string) => convertArxivHTML(insert(html), url, stub);
const checked = (html: string) => {
  const b = composeArxivReader({ source: utf8(insert(html)), sourceID: '2601.01234', revision: 2, images: new Map([[url + '/figure.jpg', image]]) });
  return validateReaderBundle(b.manifestBytes, b.members, b.manifestSHA256);
};
/** The inserted table's equation block (the last one before the fixture's first paragraph): its content. */
const block = (out: { html: string }) => {
  const found = /<p data-reader-block="(b-[^"]+)" data-reader-kind="equation" id="\1">((?:(?!<\/p>).)*)<\/p>/gs;
  return [...out.html.split('An equation')[0].matchAll(found)].map(m => m[2]).pop() ?? '';
};
const spans = (html: string) => [...html.matchAll(/<span class="(reader-equation reader-display[^"]*)" data-latex="([^"]*)"/g)].map(m => ({ classes: m[1], latex: m[2].replace(/&amp;/g, '&') }));

const math = (id: string, tex: string, body: string) => `<math id="${id}" class="ltx_Math" alttext="${tex}" display="inline" intent=":literal">`
  + `<semantics>${body}<annotation encoding="application/x-tex">${tex}</annotation></semantics></math>`;
const pad = '<td class="ltx_eqn_cell ltx_eqn_center_padleft"></td>', padRight = '<td class="ltx_eqn_cell ltx_eqn_center_padright"></td>';
const cell = (align: string, content = '') => `<td class="ltx_td${align ? ` ltx_align_${align}` : ''} ltx_eqn_cell">${content}</td>`;
const number = (tag: string, rows = 1) => `<td rowspan="${rows}" class="ltx_eqn_cell ltx_eqn_eqno ltx_align_middle ltx_align_right">`
  + `<span class="ltx_tag ltx_tag_equationgroup ltx_align_right">${tag}</span></td>`;
const row = (id: string, cells: string, tag = '') => `<tr id="${id}" class="ltx_equation ltx_eqn_row ltx_align_baseline">${pad}${cells}${padRight}${tag}</tr>`;
const sub = (base: string, script: string) => `<msub><mi>${base}</mi><mi>${script}</mi></msub>`;
const rel = (op: string, rhs: string) => `<mrow><mrow><mphantom></mphantom><mo>${op}</mo>${rhs}</mrow><mo>,</mo></mrow>`;

// Equation (2) of 2610.27450v1: align with two column pairs, two rows, one number spanning both rows.
const equation2 = `<table id="S2.E2" class="ltx_equationgroup ltx_eqn_table"><tbody>`
  + row('S2.E2X', cell('right', math('S2.E2X.m2', '\\displaystyle A_{t}', sub('A', 't')))
    + cell('left', math('S2.E2X.m3', '\\displaystyle=\\mathrm{Top}\\text{-}K(p_{S}),', rel('=', `<mi>Top</mi><mtext>-</mtext><mi>K</mi>`)))
    + cell('right', math('S2.E2X.m5', '\\displaystyle B_{t}', sub('B', 't')))
    + cell('left', math('S2.E2X.m6', '\\displaystyle=\\mathrm{Top}\\text{-}K(p_{T}),', rel('=', `<mi>Top</mi><mtext>-</mtext><mi>K</mi>`))), number('(2)', 2))
  + row('S2.E2Xa', cell('right', math('S2.E2Xa.m2', '\\displaystyle U_{t}', sub('U', 't')))
    + cell('left', math('S2.E2Xa.m3', '\\displaystyle=A_{t}\\cup B_{t},', rel('=', sub('A', 't'))))
    + cell('right', math('S2.E2Xa.m5', '\\displaystyle|U_{t}|', `<mrow><mo stretchy="false">|</mo>${sub('U', 't')}<mo stretchy="false">|</mo></mrow>`))
    + cell('left', math('S2.E2Xa.m6', '\\displaystyle\\leq 2K.', rel('≤', '<mn>2</mn><mi>K</mi>'))))
  + '</tbody></table>';

test('an aligned group with two column pairs is one numbered display, rows and columns kept (2610.27450v1 equation (2))', () => {
  const before = convert('').index.equations.length;
  const out = convert(equation2 + '<p>See <a href="#S2.E2">(2)</a> and <a href="#S2.E2Xa.m3">its union</a>.</p>');
  assert.equal(out.index.equations.length, before + 1, 'eight cells, one equation');
  const html = block(out);
  const [eq] = spans(html);
  assert.equal(spans(html).length, 1);
  assert.equal(eq.classes, 'reader-equation reader-display reader-tagged');
  assert.equal(eq.latex, '\\begin{aligned}A_{t} & =\\mathrm{Top}\\text{-}K(p_{S}), & B_{t} & =\\mathrm{Top}\\text{-}K(p_{T}), \\\\ '
    + 'U_{t} & =A_{t}\\cup B_{t}, & |U_{t}| & \\leq 2K.\\end{aligned}');
  assert.match(html, /<math display="block"><mtable displaystyle="true"><mtr><mtd columnalign="right"><msub><mi>A<\/mi>/);
  assert.equal((html.match(/<mtr>/g) ?? []).length, 2);
  assert.deepEqual([...html.matchAll(/<mtd columnalign="(\w+)"/g)].map(m => m[1]),
    ['right', 'left', 'right', 'left', 'right', 'left', 'right', 'left']);
  assert.match(html, /<span class="reader-tag">\(2\)<\/span><\/span>$/);
  // The group's number and each cell's formula lead to the one equation's block.
  const target = (id: string) => new RegExp(`<a href="#([^"]+)">${id}</a>`).exec(out.html)?.[1];
  assert.ok(target('\\(2\\)')?.startsWith('b-'));
  assert.ok(target('its union')?.startsWith('e-'));
  const index = checked(equation2).index;
  assert.equal(index.equations.filter(e => e.latex.startsWith('\\begin{aligned}')).length, 1);
});

test('rows numbered apart are equations of their own, each with its number; a continued line stays with its number', () => {
  const group = `<table id="S2.EGx1" class="ltx_equationgroup ltx_eqn_align ltx_eqn_table">`
    + `<tbody id="S2.E4">${row('S2.E4.r', cell('right', math('S2.E4.m1', '\\displaystyle\\delta_{t}', sub('δ', 't')))
      + cell('left', math('S2.E4.m2', '\\displaystyle=a', rel('=', '<mi>a</mi>'))), number('(4)'))}`
    + row('S2.E4.c', cell('right') + cell('left', math('S2.E4.m3', '\\displaystyle+b', '<mrow><mo>+</mo><mi>b</mi></mrow>'))) + '</tbody>'
    + `<tbody id="S2.E5">${row('S2.E5.r', cell('right', math('S2.E5.m1', '\\displaystyle\\omega_{t}', sub('ω', 't')))
      + cell('left', math('S2.E5.m2', '\\displaystyle=c.', rel('=', '<mi>c</mi>'))), number('(5)'))}</tbody></table>`;
  const html = block(convert(group));
  const eqs = spans(html);
  assert.deepEqual(eqs.map(e => e.latex), ['\\begin{aligned}\\delta_{t} & =a \\\\  & +b\\end{aligned}', '\\omega_{t} =c.']);
  assert.ok(eqs.every(e => e.classes.endsWith('reader-tagged')));
  assert.deepEqual([...html.matchAll(/<span class="reader-tag">([^<]+)<\/span>/g)].map(m => m[1]), ['(4)', '(5)']);
  // The continued line's empty first column is aligned like the column (no shift of its "+"), and its "+" is spaced as
  // LaTeX spaces `&+` (MathML would read an opening operator as a sign).
  assert.match(html, /<mtr><mtd columnalign="right"><\/mtd><mtd columnalign="left"><mrow><mo form="infix">\+<\/mo>/);
  // "=" after LaTeXML's empty group is spaced already and keeps its form.
  assert.match(html, /<mrow><mphantom><\/mphantom><mo>=<\/mo>/);
  checked(group);
});

test('unnumbered lines belong to the next number; lines after the last number stay with it', () => {
  const line = (id: string, lhs: string, tag = '') => row(id, cell('right', math(`${id}.m1`, `\\displaystyle ${lhs}`, `<mi>${lhs}</mi>`))
    + cell('left', math(`${id}.m2`, '\\displaystyle=0', rel('=', '<mn>0</mn>'))), tag);
  const group = `<table id="G" class="ltx_equationgroup ltx_eqn_align ltx_eqn_table"><tbody>${line('G.a', 'a')}${line('G.b', 'b', number('(7)'))}`
    + `${line('G.c', 'c', number('(8)'))}${line('G.d', 'd')}</tbody></table>`;
  const eqs = spans(block(convert(group)));
  assert.deepEqual(eqs.map(e => e.latex), ['\\begin{aligned}a & =0 \\\\ b & =0\\end{aligned}', '\\begin{aligned}c & =0 \\\\ d & =0\\end{aligned}']);
});

test('eqnarray (right, centre, left) is an array naming its columns; words in a cell are kept as text', () => {
  const group = `<table id="E" class="ltx_equationgroup ltx_eqn_eqnarray ltx_eqn_table"><tbody>`
    + row('E.1', cell('right', math('E.1.m1', '\\displaystyle x', '<mi>x</mi>')) + cell('center', math('E.1.m2', '\\displaystyle=', '<mo>=</mo>'))
      + cell('left', math('E.1.m3', '\\displaystyle\\frac{1}{2}', '<mfrac><mn>1</mn><mn>2</mn></mfrac>'))
      + cell('left', '<span id="E.1.t" class="ltx_text ltx_markedasmath">// half &amp; more</span>'), number('(9)'))
    + '</tbody></table>';
  const html = block(convert(group));
  const [eq] = spans(html);
  assert.equal(eq.latex, '\\begin{array}{rcll}\\displaystyle x & \\displaystyle= & \\displaystyle\\frac{1}{2} & \\text{// half \\& more}\\end{array}');
  assert.deepEqual([...html.matchAll(/<mtd columnalign="(\w+)"/g)].map(m => m[1]), ['right', 'center', 'left', 'left']);
  assert.match(html, /<mtext>\/\/ half &amp; more<\/mtext>/);
  checked(group);
});

test('a cell holding anything but formulas and words keeps the previous reading: each formula its own line', () => {
  const group = `<table id="R" class="ltx_equationgroup ltx_eqn_align ltx_eqn_table"><tbody>`
    + row('R.1', cell('right', math('R.1.m1', '\\displaystyle y', '<mi>y</mi>'))
      + cell('left', `<div class="ltx_inline-block ltx_transformed_outer">${math('R.1.m2', '\\displaystyle=1', rel('=', '<mn>1</mn>'))}</div>`), number('(10)'))
    + '</tbody></table>';
  const eqs = spans(block(convert(group)));
  assert.deepEqual(eqs.map(e => e.latex), ['\\displaystyle y', '\\displaystyle=1']);
  assert.equal(eqs[1].classes, 'reader-equation reader-display reader-tagged');
});

test('gather with two numbers: each number follows its own line (it had followed the last)', () => {
  const line = (id: string, tex: string, tag: string) => `<tbody id="${id}"><tr class="ltx_equation ltx_eqn_row ltx_align_baseline">${pad}`
    + `<td class="ltx_eqn_cell ltx_align_center">${math(`${id}.m1`, tex, `<mi>${tex}</mi>`).replace('display="inline"', 'display="block"')}</td>${padRight}${number(tag)}</tr></tbody>`;
  const group = `<table id="Gx" class="ltx_equationgroup ltx_eqn_gather ltx_eqn_table">${line('Gx.1', 'u', '(11)')}${line('Gx.2', 'w', '(12)')}</table>`;
  const html = block(convert(group));
  assert.deepEqual(spans(html).map(e => [e.latex, e.classes.endsWith('tagged')]), [['u', true], ['w', true]]);
  assert.deepEqual([...html.matchAll(/<span class="reader-tag">([^<]+)<\/span>/g)].map(m => m[1]), ['(11)', '(12)']);
  // One equation with one number reads as before.
  const single = convert('').html;
  assert.match(single, /<span class="reader-tag">\(1\)<\/span>/);
});

test('accents sit over their letter: a bar is an en dash, a hat a caret, a dot a dot operator; over a group the stretched mark stays', () => {
  const accent = (base: string, mark: string, mo = '') => `<mover accent="true">${base}<mo${mo}>${mark}</mo></mover>`;
  const body = `<mrow><msubsup>${accent('<mi>p</mi>', '¯')}<mi>M</mi><mi>U</mi></msubsup>${accent('<mi>x</mi>', '˙')}${accent('<mi>y</mi>', '¨')}`
    + `${accent('<mi>z</mi>', '^')}${accent('<mi>w</mi>', '~')}${accent('<mi>v</mi>', '→', ' stretchy="false"')}`
    + `${accent('<mrow><mi>x</mi><mo>+</mo><mi>y</mi></mrow>', '¯', ' stretchy="true"')}${accent('<mi>q</mi>', '¯', ' stretchy="true"')}`
    + `${accent('<mrow><mi>x</mi><mi>y</mi></mrow>', '^')}${accent('<mi>A</mi>', '^', ' stretchy="true"')}</mrow>`;
  const tex = '\\bar{p}_{M}^{U}\\dot{x}\\ddot{y}\\hat{z}\\tilde{w}\\vec{v}\\overline{x+y}\\overline{q}\\widehat{xy}\\widehat{A}';
  const html = convert(`<table id="S2.E3" class="ltx_equation ltx_eqn_table"><tbody><tr class="ltx_equation ltx_eqn_row ltx_align_baseline">${pad}`
    + `<td class="ltx_eqn_cell ltx_align_center">${math('S2.E3.m1', tex, body).replace('display="inline"', 'display="block"')}</td>${padRight}</tr></tbody></table>`).html;
  const marks = [...html.matchAll(/<mover accent="true">(?:(?!<mover).)*?(<mo [^>]*>[^<]*<\/mo>)<\/mover>/g)].map(m => m[1]);
  const zero = 'lspace="0em" rspace="0em"';
  assert.deepEqual(marks, [`<mo ${zero} stretchy="false">–</mo>`, `<mo ${zero} stretchy="false">⋅</mo>`, `<mo ${zero} stretchy="false">⋅⋅</mo>`,
    `<mo ${zero} stretchy="false">‸</mo>`, `<mo ${zero} stretchy="false">~</mo>`, `<mo ${zero} stretchy="false">→</mo>`, `<mo ${zero} stretchy="true">¯</mo>`,
    `<mo ${zero} stretchy="false">–</mo>`, `<mo ${zero}>^</mo>`, `<mo ${zero} stretchy="true">^</mo>`]);
  assert.match(html, new RegExp(`data-latex="${tex.replace(/\\/g, '\\\\').replace(/[{}+^]/g, c => `\\${c}`)}"`), 'the LaTeX is the paper\'s own');
});

test('the on-device PDF route aligns Temml\'s tables and draws its accents as the arXiv reader does', () => {
  const aligned = render(renderMath('\\begin{aligned} a &= b \\\\ cc &= d \\end{aligned}', true)!);
  assert.deepEqual([...aligned.matchAll(/<mtd columnalign="(\w+)"/g)].map(m => m[1]), ['right', 'left', 'right', 'left']);
  const cases = render(renderMath('f = \\begin{cases} 1 & x > 0 \\\\ 0 & \\text{otherwise} \\end{cases}', true)!);
  assert.deepEqual([...cases.matchAll(/<mtd columnalign="(\w+)"/g)].map(m => m[1]), ['left', 'left', 'left', 'left']);
  const accents = render(readerAccents(renderMath('\\bar{p}_M^U + \\hat{x} + \\dot{y} + \\vec{v}', true)!, true));
  assert.match(accents, /<mover accent="true"><mi>p<\/mi><mo lspace="0em" rspace="0em" stretchy="false">–<\/mo><\/mover>/);
  assert.match(accents, /<mover accent="true"><mi>x<\/mi><mo lspace="0em" rspace="0em" stretchy="false">‸<\/mo><\/mover>/);
  // Temml's \hat over a group is stretched over it, as LaTeXML's.
  assert.match(render(readerAccents(renderMath('\\hat{xy}', true)!, true)), /<mover accent="true"><mrow><mi>x<\/mi><mi>y<\/mi><\/mrow><mo lspace="0em" rspace="0em">\^<\/mo><\/mover>/);
  assert.match(accents, /<mover accent="true"><mi>y<\/mi><mo lspace="0em" rspace="0em" stretchy="false">⋅<\/mo><\/mover>/);
  assert.match(accents, /<mover accent="true"><mi>v<\/mi><mo lspace="0em" rspace="0em" stretchy="false">→<\/mo><\/mover>/);
  // Before the gate's glyph check the formula is Temml's own (its glyphs are compared with the page's).
  assert.match(render(renderMath('\\bar{p}', true)!), /<mover><mi>p<\/mi><mo stretchy="false">‾<\/mo><\/mover>/);
});

test('both stylesheets align table cells by column and join a relation\'s two sides', () => {
  for (const css of [ARXIV_CSS, DEVICE_PDF_CSS]) assert.ok(css.endsWith(MATH_TABLE_CSS));
  assert.match(MATH_TABLE_CSS, /mtd\[columnalign=right\]\{text-align:right;justify-items:end\}/);
  assert.match(MATH_TABLE_CSS, /mtd\[columnalign=right\]\+mtd\[columnalign=left\]\{padding-left:0\}/);
});
