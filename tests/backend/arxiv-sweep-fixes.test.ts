// Revision 29: the fresh-paper sweep of 2026-10-28 found three papers refused on first open and two author lines with
// leaked marks. Each test is the construct reduced to LaTeXML's own markup (docs/architecture/HTML_FIRST_READER.md,
// "Sweep failures, revision 29"): a citation inside a formula (2610.37645v1, `arxiv_math_element`), a formula without
// any LaTeX (2610.37481v1, `arxiv_math_source`), a back-reference to an id the HTML lacks (2610.37633v1,
// `arxiv_unresolved_fragment`), names with their own marks run together in one creator (2610.37651v1) and a \thanks of
// TeX-typed marks, affiliations, split e-mail addresses and a project page (2610.37619v1, 2407.04620v1). Every page is
// checked by the shared validator the device runs before showing a paper.
import test from 'node:test';
import assert from 'node:assert/strict';
import { arxivHTMLURL, convertArxivHTML } from '../../supabase/functions/_shared/reader/arxiv-html.ts';
import { validateHTML } from '../../supabase/functions/_shared/reader/html-validate.ts';

const url = arxivHTMLURL('2601.01234', 2);
const asset = { path: `assets/${'0'.repeat(64)}.png`, width: 10, height: 10 };
const convert = (html: string, options: { authors?: string[]; title?: string } = {}) => {
  const out = convertArxivHTML(html, url, () => asset, options);
  validateHTML(new TextEncoder().encode(out.html), out.index, new Map([[asset.path, { width: 10, height: 10 }]]), true);
  return out;
};
const page = (body: string, authors = '<div class="ltx_authors">A. Author</div>') => '<html><body><article class="ltx_document">'
  + `<h1 class="ltx_title ltx_title_document">Sweep fixes</h1>${authors}<section id="S1" class="ltx_section">`
  + `<h2 class="ltx_title">1 Introduction</h2>${body}</section></article></body></html>`;
const authorsOf = (html: string) => /<p class="reader-authors"[^>]*>(.*?)<\/p>/s.exec(html)?.[1] ?? '';
const plain = (html: string) => html.replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();

// 2610.37645v1, reduced: "\text{\color{gray}{Attention} \citep{vaswani2017attention}:}\quad O = …" as a display.
const citedDisplay = '<table id="S2.Ex1" class="ltx_equation ltx_eqn_table"><tbody><tr class="ltx_equation ltx_eqn_row">'
  + '<td class="ltx_eqn_cell ltx_eqn_center_padleft"></td><td class="ltx_eqn_cell ltx_align_center">'
  + '<math id="S2.Ex1.m1" class="ltx_math_unparsed" alttext="\\text{{Attention} \\cite[citep]{vaswani2017attention}:}\\quad O=V," display="block">'
  + '<semantics><mrow><mrow><mtext class="ltx_mathvariant_bold">Attention</mtext><mrow><mtext> </mtext>'
  + '<mtext class="ltx_citemacro_citep"><cite class="ltx_cite ltx_citemacro_citep">(<a href="#bib.bib17" class="ltx_ref">Vaswani et al., 2017</a>)</cite></mtext>'
  + '<mtext>:</mtext></mrow></mrow><mi>O</mi><mo>=</mo><mi>V</mi><mo>,</mo></mrow>'
  + '<annotation encoding="application/x-tex">\\text{{Attention} \\cite[citep]{vaswani2017attention}:}\\quad O=V,</annotation></semantics></math></td>'
  + '<td class="ltx_eqn_cell ltx_eqn_center_padright"></td></tr></tbody></table>';
const bibliography = '<section id="bib" class="ltx_bibliography"><h2 class="ltx_title">References</h2><ul class="ltx_biblist">'
  + '<li id="bib.bib17" class="ltx_bibitem">A. Vaswani et al. (2017) Attention is all you need.</li></ul></section>';

test('a citation inside a formula\'s text reads as words in the formula (2610.37645v1 refused arxiv_math_element)', () => {
  const out = convert(page(`<div class="ltx_para"><p class="ltx_p">Full attention computes:</p></div>${citedDisplay}${bibliography}`));
  assert.match(out.html, /<mtext>\(Vaswani et al\., 2017\)<\/mtext>/);
  assert.doesNotMatch(out.html, /<cite|reader-math-fallback/);
  assert.equal(out.index.equations.length, 1);
  assert.ok(out.index.equations[0].display);
  // Outside a token, the citation's words become a text token of their own (text directly in an mrow is invalid MathML).
  const bare = convert(page(`<div class="ltx_para"><p class="ltx_p">See <math alttext="x \\cite{a}" display="inline"><mrow><mi>x</mi>`
    + '<cite class="ltx_cite">[1]</cite></mrow></math>.</p></div>'));
  assert.match(bare.html, /<mi>x<\/mi><mtext>\[1\]<\/mtext>/);
});

test('a formula holding what the reader cannot draw shows its LaTeX instead of refusing the paper', () => {
  const unknown = '<math alttext="a \\tooltip{b}" display="inline"><semantics><mrow><mi>a</mi><maction actiontype="tooltip"><mi>b</mi>'
    + '<mtext>tip</mtext></maction></mrow><annotation encoding="application/x-tex">a \\tooltip{b}</annotation></semantics></math>';
  const out = convert(page(`<div class="ltx_para"><p class="ltx_p">Inline ${unknown} here.</p></div>`));
  assert.match(out.html, /<span class="reader-equation reader-inline reader-math-fallback" data-latex="a \\tooltip\{b\}"[^>]*>\\\(a \\tooltip\{b\}\\\)<\/span>/);
  assert.doesNotMatch(out.html, /maction/);
  assert.equal(out.index.equations[0].latex, 'a \\tooltip{b}');
  // A numbered display the reader can't draw keeps its number beside its LaTeX (a fallback holds only its LaTeX).
  const numbered = '<table id="S1.E1" class="ltx_equation ltx_eqn_table"><tbody><tr><td class="ltx_eqn_cell ltx_align_center">'
    + unknown.replace('display="inline"', 'display="block"') + '</td><td class="ltx_eqn_cell ltx_eqn_eqno"><span class="ltx_tag ltx_tag_equation">(1)</span></td></tr></tbody></table>';
  const shown = convert(page(numbered));
  assert.match(shown.html, /reader-display reader-math-fallback"[^>]*>a \\tooltip\{b\}<\/span> \(1\)<\/p>/);
});

test('a formula LaTeXML wrote without LaTeX takes it from its MathML (2610.37481v1 refused arxiv_math_source)', () => {
  // Table 4's boxed answer: a block formula in a cell with neither alttext nor annotation.
  const boxed = '<math id="S13.T4.m12" class="ltx_Math ltx_framed ltx_framed_rectangle" display="block"><mn mathsize="0.900em">15</mn></math>';
  const table = `<figure id="S13.T4" class="ltx_table"><table class="ltx_tabular"><tbody><tr class="ltx_tr"><td class="ltx_td">“…10+5=15…” ${boxed}”</td></tr></tbody></table>`
    + '<figcaption class="ltx_caption"><span class="ltx_tag ltx_tag_table">Table 4: </span>Answers.</figcaption></figure>';
  const out = convert(page(table));
  assert.deepEqual(out.index.equations.map(e => e.latex), ['15']);
  assert.match(out.html, /data-latex="15"[^>]*><math display="block"><mn mathsize="0.900em">15<\/mn><\/math>/);
  // Scripts, fractions and words read back as LaTeX.
  const read = convert(page('<div class="ltx_para"><p class="ltx_p">Then <math display="inline"><mrow><msup><mi>x</mi><mn>2</mn></msup><mo>+</mo>'
    + '<mfrac><mn>1</mn><mi>n</mi></mfrac><mtext>if odd</mtext></mrow></math>.</p></div>'));
  assert.equal(read.index.equations[0].latex, 'x^2 + \\frac{1}{n} \\text{if odd}');
});

test('a link to an id the HTML lacks goes to the element LaTeXML named it after, or reads as words (2610.37633v1)', () => {
  // The bibliography's back-references: "Cited by: §1, Figure 1, Table 9". LaTeXML pointed "Figure 1" at S1.F1.2, the
  // citation inside the figure's caption, and wrote no element with that id.
  const figure = '<figure id="S1.F1" class="ltx_figure"><img src="2601.01234v2/x1.png" id="S1.F1.g1" class="ltx_graphics" width="10" height="10" alt="">'
    + '<figcaption class="ltx_caption"><span class="ltx_tag ltx_tag_figure">Figure 1: </span>Results <cite class="ltx_cite"><a href="#bib.bib3" class="ltx_ref">(Grauman, 2024)</a></cite>.</figcaption></figure>';
  const bib = '<section id="bib" class="ltx_bibliography"><h2 class="ltx_title">References</h2><ul class="ltx_biblist"><li id="bib.bib3" class="ltx_bibitem">'
    + 'K. Grauman (2024) Ego-Exo4D. Cited by: <a href="#S1.p1" class="ltx_ref">§1</a>, <a href="#S1.F1.2" class="ltx_ref">Figure 1</a>, '
    + '<a href="#X9.T9.2" class="ltx_ref">Table 9</a>.</li></ul></section>';
  const out = convert(page(`<div id="S1.p1" class="ltx_para"><p class="ltx_p">Words.</p></div>${figure}${bib}`));
  const figureID = out.index.figures[0].id;
  assert.match(out.html, new RegExp(`<a href="#${figureID}">Figure 1</a>`));
  // Nothing on the page is X9 or inside it: the words stay, without a link.
  assert.match(out.html, /, Table 9\./);
  assert.doesNotMatch(out.html, /<a[^>]*>Table 9<\/a>/);
});

// 2610.37651v1, reduced: one creator holding every name with its own marks, lines broken by `\\`, then the affiliations.
const runTogether = '<div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname">'
  + '<span id="id1" class="ltx_inline-block ltx_minipage ltx_align_top"><span id="id1.1" class="ltx_p ltx_align_center"><span class="ltx_text ltx_font_bold">'
  + 'Zack Yu<sup class="ltx_sup">1*</sup>, Nicholas Lee<sup class="ltx_sup">1*</sup>, Minjae Lee<sup class="ltx_sup">4</sup>'
  + '<br class="ltx_break">Wonjun Kang<sup class="ltx_sup">4</sup>, Amir Gholami<sup class="ltx_sup">1,2</sup>'
  + '<br class="ltx_break"><sup class="ltx_sup"><span class="ltx_text ltx_font_medium">1</span></sup></span>UC Berkeley <sup class="ltx_sup">2</sup>ICSI '
  + '<sup class="ltx_sup">4</sup>Furiosa AI</span></span></span></span></div>';

test('names with their own marks in one creator keep their marks with the library\'s names (2610.37651v1)', () => {
  const out = convert(page('<div class="ltx_para"><p class="ltx_p">Words.</p></div>', runTogether),
    { authors: ['Zack Yu', 'Nicholas Lee', 'Minjae Lee', 'Wonjun Kang', 'Amir Gholami'], title: 'Sweep fixes' });
  const header = authorsOf(out.html);
  assert.ok(header.startsWith('Zack Yu<sup>1*</sup>, Nicholas Lee<sup>1*</sup>, Minjae Lee<sup>4</sup>, Wonjun Kang<sup>4</sup>, Amir Gholami<sup>1,2</sup> '), header);
  assert.match(header, /<span class="reader-affiliations"><sup>1<\/sup>UC Berkeley<br><sup>2<\/sup>ICSI<br><sup>4<\/sup>Furiosa AI<\/span>/);
  // On revision 28 the library's first name took every mark of the line and the other names became an affiliation.
  assert.doesNotMatch(plain(header), /Zack Yu1\*,4/);
});

// 2610.37619v1, reduced: \thanks notes on the last author; TeX marks typed as text, e-mail names as mailto links inside
// braces, the project page in its own note. And 2407.04620v1's "˜$ˆ†$ Joint advising" and "Correspondence to:" line.
const thanks = (id: string, body: string) => `<span id="${id}" class="ltx_note ltx_note_frontmatter ltx_role_thanks"><sup class="ltx_note_mark">†</sup>`
  + `<span class="ltx_note_outer"><span class="ltx_note_content"><sup class="ltx_note_mark">†</sup><span class="ltx_note_type">thanks: </span>${body}</span></span></span>`;
const mail = (name: string, host: string) => `<a href="mailto:${name}@${host}" class="ltx_ref ltx_href">${name}</a>`;
const noted = '<div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname">Tudor Braicu\n</span></span>'
  + '<span class="ltx_author_before">  </span><span class="ltx_creator ltx_role_author"><span class="ltx_personname">Daniela Rus\n</span>'
  + thanks('id1', ' <sup class="ltx_sup">*</sup> These authors contributed equally to this work. ˜$ˆ†$ Joint advising.\n<br class="ltx_break">Corresponding author: Tudor Braicu.')
  + thanks('id2', ' $ˆ1$ Massachusetts Institute of Technology (MIT), Cambridge, MA 02139 USA.\n<br class="ltx_break">$ˆ{2}$ Cornell University, Ithaca, NY 14853 USA.')
  + thanks('id3', ` E-mail:\n<span class="ltx_text">{${mail('delpreto', 'csail.mit.edu')}, ${mail('rus', 'csail.mit.edu')}}@csail.mit.edu</span>;\n`
    + `<br class="ltx_break"><span class="ltx_text">{${mail('jaredb', 'mit.edu')}}@mit.edu</span>; ${mail('tb574@cornell.edu', 'x')}.`)
  + thanks('id4', ' Correspondence to: <span class="ltx_text ltx_font_typewriter">rus@mit.edu</span>.')
  + thanks('id5', ' <span class="ltx_text ltx_font_bold">Project website and video:</span> <a href="https://tennis-vision.csail.mit.edu" class="ltx_ref ltx_href">https://tennis-vision.csail.mit.edu</a>')
  + '</span></div>';

test('a \\thanks reads as its marks, affiliations, notes and project page, without TeX or address pieces (2610.37619v1)', () => {
  for (const options of [{}, { authors: ['Tudor Braicu', 'Daniela Rus'], title: 'Sweep fixes' }]) {
    const out = convert(page('<div class="ltx_para"><p class="ltx_p">Words.</p></div>', noted), options);
    const header = authorsOf(out.html), text = out.index.blocks[1].text;
    assert.ok(header.startsWith('Tudor Braicu, Daniela Rus<sup>†</sup> <span class="reader-affiliations">'), header);
    // TeX-typed marks are marks, and numbered lines in a note are the affiliations.
    assert.match(header, /<span class="reader-affiliations"><sup>1<\/sup>Massachusetts Institute of Technology \(MIT\), Cambridge, MA 02139 USA<br><sup>2<\/sup>Cornell University, Ithaca, NY 14853 USA<\/span>/);
    // A symbol mark after words starts a line; the tie is a space.
    assert.match(header, /<sup>\*<\/sup>These authors contributed equally to this work\. <br><sup>†<\/sup>Joint advising\./);
    assert.match(header, /Corresponding author: Tudor Braicu\./);
    // The project page stays with its words, in its note.
    assert.match(header, /Project website and video: <a href="https:\/\/tennis-vision\.csail\.mit\.edu\/" rel="noopener noreferrer">https:\/\/tennis-vision\.csail\.mit\.edu<\/a><\/span>$/);
    // The e-mail notes went whole: no label left alone, no "{, }@csail.mit.edu".
    assert.doesNotMatch(text, /\$|ˆ|˜|@|E-mail|Correspondence to|\{|\}/);
    assert.doesNotMatch(header, /<br>\s*<br>|<sup><\/sup>/);
  }
});

test('a parbox of names and marked affiliation paragraphs reads as names, then affiliations (2610.13166v1)', () => {
  const p = (body: string) => `<span class="ltx_p ltx_align_left">${body}</span>`;
  const parbox = '<div class="ltx_authors"><span class="ltx_creator ltx_role_author"><span class="ltx_personname">'
    + '<span id="id1" class="ltx_inline-block ltx_parbox ltx_align_top">'
    + p('<span class="ltx_text ltx_font_bold">Shun Zou<sup class="ltx_sup"><span class="ltx_text ltx_font_italic">1,2∗</span></sup>  '
      + 'Ziyu Ma<sup class="ltx_sup"><span class="ltx_text ltx_font_italic">2∗</span></sup>  Feng Zhao<sup class="ltx_sup"><span class="ltx_text ltx_font_italic">1‡</span></sup></span>')
    + '\n' + p('<sup class="ltx_sup"><span class="ltx_text ltx_font_italic">1</span></sup>University of Science and Technology of China')
    + '\n' + p('<sup class="ltx_sup"><span class="ltx_text ltx_font_italic">2</span></sup>AMAP, Alibaba Group')
    + '</span></span></span></div>';
  const header = authorsOf(convert(page('<div class="ltx_para"><p class="ltx_p">Words.</p></div>', parbox)).html);
  assert.equal(header, 'Shun Zou<sup>1,2∗</sup>, Ziyu Ma<sup>2∗</sup>, Feng Zhao<sup>1‡</sup> <span class="reader-affiliations"><sup>1</sup>University of Science and Technology of China<br><sup>2</sup>AMAP, Alibaba Group</span>');
});
