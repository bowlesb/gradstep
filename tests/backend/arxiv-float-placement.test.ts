// Revision 27 (owner, TestFlight 92, WorldCast 2610.20731v2: "Is the Figure displayed in the right place"): a float
// written before the first section reads after the paragraph of the first section that first cites it, not between the
// abstract and the Introduction; floats keep their order and ids (float-placement.ts, arxiv/floats.ts,
// docs/JUDGMENT_LOG.md 43). Model readings do the same (device port revision 15, device-pdf/floats.ts). And the reader
// bridge puts the Gradstep Keywords row right after the abstract, before any figure the paper keeps there. Fragments are
// LaTeXML's markup, reduced.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { arxivHTMLURL, convertArxivHTML } from '../../supabase/functions/_shared/reader/arxiv-html.ts';
import { el, outText, parseHTML, textContent, type DomNode, type OutNode } from '../../supabase/functions/_shared/reader/html.ts';
import { validateHTML } from '../../supabase/functions/_shared/reader/html-validate.ts';
import { floatsNearMentions } from '../../supabase/functions/_shared/reader/device-pdf/floats.ts';

const url = arxivHTMLURL('2601.01234', 2);
const stub = () => ({ path: `assets/${'0'.repeat(64)}.png`, width: 10, height: 10 });
const unshown = () => null;

const figure = (n: number, words = 'A picture.', id = `S0.F${n}`) => `<figure id="${id}" class="ltx_figure"><img src="2601.01234v2/f${n}.png" id="${id}.g1" class="ltx_graphics" alt="">`
  + `<figcaption class="ltx_caption"><span class="ltx_tag ltx_tag_figure">Figure ${n}: </span>${words}</figcaption></figure>`;
const tableFloat = (n: number) => `<figure id="S0.T${n}" class="ltx_table"><figcaption class="ltx_caption"><span class="ltx_tag ltx_tag_table">Table ${n}: </span>Scores.</figcaption>`
  + `<table class="ltx_tabular"><tbody><tr><td>Model</td><td>Score</td></tr></tbody></table></figure>`;
const cite = (target: string, label: string) => `<a href="#${target}" class="ltx_ref">${label}</a>`;
const para = (id: string, words: string) => `<div id="${id}" class="ltx_para"><p class="ltx_p">${words}</p></div>`;
const section = (n: number | string, title: string, body: string, cls = 'ltx_section') => `<section id="S${n}" class="${cls}"><h2 class="ltx_title ltx_title_section">${title}</h2>${body}</section>`;
const references = '<section id="bib" class="ltx_bibliography"><h2 class="ltx_title ltx_title_bibliography">References</h2>'
  + '<ul class="ltx_biblist"><li id="bib.bib1" class="ltx_bibitem">[1] A. Author. A paper. 2020.</li></ul></section>';
const page = (front: string, body: string, after = '') => '<html><body><article class="ltx_document">'
  + '<h1 class="ltx_title ltx_title_document">Where floats read</h1><div class="ltx_authors">A. Author</div>'
  + '<div class="ltx_abstract"><h6 class="ltx_title ltx_title_abstract">Abstract</h6><p class="ltx_p">We study where floats read.</p></div>'
  + front + body + references + after + '</article></body></html>';

const convert = (html: string, resolve: typeof stub | typeof unshown = stub) => {
  const out = convertArxivHTML(html, url, resolve);
  validateHTML(new TextEncoder().encode(out.html), out.index, new Map([[stub().path, { width: 10, height: 10 }]]), true);
  return out;
};
/** The page's top-level blocks as short names: a heading's words, a float's label, a paragraph's first words. */
const order = (out: { html: string }) => {
  const find = (n: DomNode): DomNode | null => n.name === 'body' ? n : (n.children ?? []).map(find).find(Boolean) ?? null;
  return find(parseHTML(out.html))!.children.filter(n => n.type === 'tag').map(n => {
    const text = textContent(n).replace(/\s+/g, ' ').trim();
    if (n.name === 'figure' || n.attribs.class === 'reader-table' || n.attribs.class === 'reader-caption') return /(?:Figure|Table) \d+/.exec(text)?.[0] ?? `${n.name}:${text.slice(0, 20)}`;
    return text.slice(0, 20);
  });
};

test('a figure the Introduction cites reads after the paragraph citing it; one cited nowhere follows it (2610.20731v2)', () => {
  const out = convert(page(figure(1, 'Our capability tree.') + figure(2, 'Evaluation scope.'), section(1, '1 Introduction',
    para('S1.p1', 'Multimodal systems advance.') + para('S1.p2', `We organize levels, illustrated in Figure ${cite('S0.F1', '1')}.`) + para('S1.p3', 'Despite progress, gaps remain.'))
    + section(2, '2 WorldCast', para('S2.p1', 'The benchmark.'))));
  assert.deepEqual(order(out), ['Where floats read', 'A. Author', 'Abstract', 'We study where float', '1 Introduction',
    'Multimodal systems a', 'We organize levels, ', 'Figure 1', 'Figure 2', 'Despite progress, ga', '2 WorldCast', 'The benchmark.', 'References', '[1] A. Author. A pap']);
  // Ids are issued in source order, before the move: the figures keep theirs, the link still opens Figure 1, and the
  // index lists blocks and figures in page order.
  const ids = out.index.figures.map(f => f.id), heading = out.index.headings.find(h => h.title === '1 Introduction')!.id;
  const n = (id: string) => Number(id.split('-').pop());
  assert.ok(ids.every(id => n(id) < n(heading)), 'the figures were numbered before the Introduction');
  assert.match(out.html, new RegExp(`<a href="#${ids[0]}">1</a>`));
  const pageOrder = [...out.html.matchAll(/data-reader-block="([^"]+)"/g)].map(m => m[1]);
  assert.deepEqual(out.index.blocks.map(b => b.id), pageOrder);
  assert.deepEqual(ids, pageOrder.filter(id => ids.includes(id)));
});

test('a teaser cited only later, or never, stays under the abstract; the body keeps its own placement', () => {
  const later = convert(page(figure(1), section(1, '1 Introduction', para('S1.p1', 'We begin.'))
    + section(2, '2 Results', figure(2, 'Body figure.', 'S2.F2') + para('S2.p1', `Samples in Figure ${cite('S0.F1', '1')} and Figure ${cite('S2.F2', '2')}.`))));
  assert.deepEqual(order(later).slice(3), ['We study where float', 'Figure 1', '1 Introduction', 'We begin.', '2 Results', 'Figure 2', 'Samples in Figure 1 ', 'References', '[1] A. Author. A pap']);
  const never = convert(page(figure(1), section(1, '1 Introduction', para('S1.p1', 'We begin.'))));
  assert.deepEqual(order(never).slice(4, 6), ['Figure 1', '1 Introduction']);
  // Cited where it already is (front matter that refers to it) is near enough.
  const front = convert(page(para('S0.p1', `Code and Figure ${cite('S0.F1', '1')} online.`) + figure(1), section(1, '1 Introduction', para('S1.p1', `As Figure ${cite('S0.F1', '1')} shows.`))));
  assert.deepEqual(order(front).slice(4, 7), ['Code and Figure 1 on', 'Figure 1', '1 Introduction']);
});

test('the figure lands after the whole LaTeX paragraph: the citing sentence, its display and the words after it', () => {
  const display = '<table id="S1.E1" class="ltx_equation ltx_eqn_table"><tbody><tr class="ltx_equation ltx_eqn_row"><td class="ltx_eqn_cell">'
    + '<math alttext="x^2" display="block"><semantics><msup><mi>x</mi><mn>2</mn></msup><annotation encoding="application/x-tex">x^2</annotation></semantics></math>'
    + '</td><td class="ltx_eqn_cell ltx_eqn_eqno"><span class="ltx_tag ltx_tag_equation">(1)</span></td></tr></tbody></table>';
  const out = convert(page(figure(1), section(1, '1 Introduction', `<div id="S1.p1" class="ltx_para"><p class="ltx_p">As Figure ${cite('S0.F1', '1')} shows, the loss is</p>`
    + `${display}<p class="ltx_p">where x is the input.</p></div>` + para('S1.p2', 'Next paragraph.'))));
  assert.deepEqual(order(out).slice(4), ['1 Introduction', 'As Figure 1 shows, t', 'x2(1)', 'where x is the input', 'Figure 1', 'Next paragraph.', 'References', '[1] A. Author. A pap']);
});

test('floats keep their order: later floats before the first section go to their own citations, never past a body float or into the references', () => {
  // ViewCraft (2610.15915v1) wrote all its floats before the Introduction. Figure 3 is cited after the body's Figure 4
  // begins its section, so it waits just above it.
  const out = convert(page(figure(1) + tableFloat(1) + figure(2) + figure(3), section(1, '1 Introduction',
    para('S1.p1', `Overview in Figure ${cite('S0.F1', '1')}.`) + para('S1.p2', 'More introduction.'))
    + section(2, '2 Method', para('S2.p1', `Scores in Table ${cite('S0.T1', '1')}.`) + para('S2.p2', `Method in Figure ${cite('S0.F2', '2')}.`) + para('S2.p3', 'Method text.'))
    + section(3, '3 Results', figure(4, 'Body figure.', 'S3.F4') + para('S3.p1', `See Figures ${cite('S0.F3', '3')} and ${cite('S3.F4', '4')}.`))));
  assert.deepEqual(order(out).slice(4), ['1 Introduction', 'Overview in Figure 1', 'Figure 1', 'More introduction.', '2 Method',
    'Scores in Table 1.', 'Table 1', 'Method in Figure 2.', 'Figure 2', 'Method text.', '3 Results', 'Figure 3', 'Figure 4', 'See Figures 3 and 4.', 'References', '[1] A. Author. A pap']);
  // Order wins over nearness: Figure 3, cited before Figure 2, still reads after it.
  const crossed = convert(page(figure(1) + figure(2) + figure(3), section(1, '1 Introduction', para('S1.p1', `See Figure ${cite('S0.F1', '1')}.`))
    + section(2, '2 Method', para('S2.p1', `Figure ${cite('S0.F3', '3')} first.`) + para('S2.p2', `Then Figure ${cite('S0.F2', '2')}.`))));
  assert.deepEqual(order(crossed).slice(4), ['1 Introduction', 'See Figure 1.', 'Figure 1', '2 Method', 'Figure 3 first.', 'Then Figure 2.', 'Figure 2', 'Figure 3', 'References', '[1] A. Author. A pap']);
  // A front float cited only in the appendix follows the float before it.
  const appendix = convert(page(figure(1) + figure(2), section(1, '1 Introduction', para('S1.p1', `See Figure ${cite('S0.F1', '1')}.`) + para('S1.p2', 'More.')),
    section('A1', 'Appendix A Details', para('A1.p1', `Details of Figure ${cite('S0.F2', '2')}.`), 'ltx_appendix')));
  assert.deepEqual(order(appendix).slice(4, 9), ['1 Introduction', 'See Figure 1.', 'Figure 1', 'Figure 2', 'More.']);
});

test('the Introduction\'s own figure is not passed; a table float the Introduction cites moves like a figure', () => {
  const out = convert(page(figure(1) + tableFloat(1), section(1, '1 Introduction', figure(2, 'Intro figure.', 'S1.F2')
    + para('S1.p1', `Figure ${cite('S1.F2', '2')} first.`) + para('S1.p2', `Then Figure ${cite('S0.F1', '1')} and Table ${cite('S0.T1', '1')}.`))));
  assert.deepEqual(order(out).slice(4), ['1 Introduction', 'Figure 1', 'Table 1', 'Figure 2', 'Figure 2 first.', 'Then Figure 1 and Ta', 'References', '[1] A. Author. A pap']);
});

test('a caption set apart from its picture moves with it, whichever images this device shows; one whose picture became text holds the floats before it', () => {
  // \captionof after an unwrapped \includegraphics (2610.17288v1): the picture is a paragraph, the caption a float.
  const captionOf = `<div class="ltx_para" id="S0.p1"><p class="ltx_p"><img src="2601.01234v2/f1.png" class="ltx_graphics" alt=""></p></div>`
    + `<figure id="S0.F1" class="ltx_figure"><figcaption class="ltx_caption"><span class="ltx_tag ltx_tag_figure">Figure 1: </span>Benchmark.</figcaption></figure>`;
  const body = section(1, '1 Introduction', para('S1.p1', `As Figure ${cite('S0.F1', '1')} shows.`) + para('S1.p2', 'More.'));
  for (const resolve of [stub, unshown]) {
    const out = convert(page(captionOf, body), resolve);
    const names = order(out);
    assert.equal(names[4], '1 Introduction');
    assert.deepEqual(names.slice(5, 9).map(name => name.replace(/^(figure|p):.*$/, 'picture')), ['As Figure 1 shows.', 'picture', 'Figure 1', 'More.']);
  }
  // A float of captions alone with no picture above it (2610.07591v1's Figure 1, a diagram read as its labels) can't move,
  // so the figure before it stays too (it would pass it); a float after it still moves.
  const labels = `<figure id="S0.F2" class="ltx_figure"><figcaption class="ltx_caption"><span class="ltx_tag ltx_tag_figure">Figure 2: </span>Diagram.</figcaption></figure>`;
  const out = convert(page(figure(1) + labels + figure(3), section(1, '1 Introduction',
    para('S1.p1', `Figures ${cite('S0.F1', '1')}, ${cite('S0.F2', '2')} and ${cite('S0.F3', '3')}.`) + para('S1.p2', 'More.'))));
  assert.deepEqual(order(out).slice(4), ['Figure 1', 'Figure 2', '1 Introduction', 'Figures 1, 2 and 3.', 'Figure 3', 'More.', 'References', '[1] A. Author. A pap']);
});

// The reader bridge's keywords row (apps/apple/ScienceReader/Resources/reader-bridge.js, PAPER TAGS PLACE).
const bridge = readFileSync(new URL('../../apps/apple/ScienceReader/Resources/reader-bridge.js', import.meta.url), 'utf8');
const place = (() => {
  const match = /\/\/ BEGIN PAPER TAGS PLACE\n([\s\S]*?)\/\/ END PAPER TAGS PLACE/.exec(bridge);
  assert.ok(match, 'the bridge has a PAPER TAGS PLACE section');
  return new Function(`${match[1]}\nreturn paperTagsPlace;`)() as (nodes: unknown[]) => { name: string } | null;
})();
const node = (tagName: string, textContent: string, className = '') => ({ tagName, textContent, className, name: `${tagName}:${textContent}` });

test('the keywords row sits right after the abstract, before figures the paper keeps there (TestFlight 92)', () => {
  const header = [node('H1', 'WorldCast'), node('P', 'Wenhao Yan', 'reader-authors'), node('H6', 'Abstract'), node('P', 'Humans interpret…')];
  // Before this revision's move, or with a teaser the paper keeps: before the figures, not under them.
  assert.equal(place([...header, node('FIGURE', 'Figure 1: …'), node('FIGURE', 'Figure 2: …'), node('H2', '1 Introduction')])?.name, 'FIGURE:Figure 1: …');
  // A caption paragraph or a table there counts too; paragraphs after the abstract (a note, a code link) stay above.
  assert.equal(place([...header, node('P', '* Equal contribution'), node('P', 'Figure 1: …', 'reader-caption'), node('H2', '1 Introduction')])?.name, 'P:Figure 1: …');
  assert.equal(place([...header, node('DIV', 'Model Score', 'reader-table'), node('H2', '1 Introduction')])?.name, 'DIV:Model Score');
  // Nothing between the abstract and the first section: before the section, as before.
  assert.equal(place([...header, node('P', '* Equal contribution'), node('H2', '1 Introduction')])?.name, 'H2:1 Introduction');
  // An abstract set as a bold paragraph over a one-item list (FDE-Gym).
  assert.equal(place([node('H1', 'FDE-Gym'), node('P', 'Abstract'), node('UL', 'We…'), node('FIGURE', 'Figure 1'), node('H2', '1 Introduction')])?.name, 'FIGURE:Figure 1');
  // A model reading's abstract paragraph without a heading, under a figure printed above it.
  assert.equal(place([node('H1', 'HELPD'), node('P', 'Fan Yuan', 'reader-authors'), node('FIGURE', 'Figure 1'), node('P', 'Large Vision-Language Models…', 'reader-abstract'),
    node('FIGURE', 'Figure 2'), node('H2', '1 Introduction')])?.name, 'FIGURE:Figure 2');
  // No abstract heading before the first section: null, and the row goes before the first section as it always has.
  assert.equal(place([node('H1', 'Letter'), node('P', 'We study…'), node('H2', '1 Introduction')]), null);
  assert.equal(place([node('H1', 'Odd'), node('H2', '1 Introduction'), node('H3', 'Abstract'), node('FIGURE', 'Figure 1')]), null);
});

// On-device model readings (port revision 15): the reading follows the pages, so the same floats sat in the same place;
// a float is a figure or table block its caption names, and a paragraph cites it by naming it.
const p = (words: string, cls = '') => el('p', { 'data-reader-kind': 'paragraph', ...(cls ? { class: cls } : {}) }, [words]);
const fig = (words: string) => el('figure', { 'data-reader-kind': 'figure' }, [el('img', { src: 'assets/x.png' }), ...(words ? [el('figcaption', {}, [words])] : [])]);
const names = (top: OutNode[]) => top.map(n => outText(n).replace(/\s+/g, ' ').trim().slice(0, 16));
const reading = (...middle: OutNode[]) => [el('h1', {}, ['WorldCast']), p('Wenhao Yan', 'reader-authors'), p('Humans interpret…', 'reader-abstract'), ...middle,
  el('h2', {}, ['References']), el('ul', { class: 'reader-references' }, [el('li', {}, ['[1] A paper.'])])];

test('a model reading moves the same floats: named in the Introduction, after that paragraph; a logo or a later teaser stays', () => {
  const top = reading(fig('Figure 1: Capability tree.'), fig('Figure 2: Evaluation scope.'), el('h2', {}, ['1 Introduction']), p('Systems advance.'),
    p('We organize levels, illustrated in Figure 1.'), p('Despite progress.'), el('h2', {}, ['2 WorldCast']), p('The benchmark.'));
  assert.equal(floatsNearMentions(top), 2);
  assert.deepEqual(names(top).slice(3, 9), ['1 Introduction', 'Systems advance.', 'We organize leve', 'Figure 1: Capabi', 'Figure 2: Evalua', 'Despite progress']);
  // "Figs. 1 and 3" before a display: the figure follows the sentence's equation and the words after it.
  const display = reading(fig('Fig. 1. Overview.'), el('h2', {}, ['1 Introduction']), p('As Figs. 1 and 3 show, the loss is'),
    el('p', { 'data-reader-kind': 'equation' }, ['x^2']), p('where x is the input.'), p('Next.'));
  assert.equal(floatsNearMentions(display), 1);
  assert.deepEqual(names(display).slice(3, 9), ['1 Introduction', 'As Figs. 1 and 3', 'x^2', 'where x is the i', 'Fig. 1. Overview', 'Next.']);
  // A paragraph a column break cut mid-sentence (ACL 2024.acl-long.42, a recorded model reading) is not split by the figure.
  const cut = reading(fig('Figure 1: Overview.'), el('h2', {}, ['1 Introduction']), p('Using several source languages (Figure 1), Multi-Source Language'),
    p('Training helps.'), p('Next.'));
  floatsNearMentions(cut);
  assert.deepEqual(names(cut).slice(3, 8), ['1 Introduction', 'Using several so', 'Training helps.', 'Figure 1: Overvi', 'Next.']);
  const stays = reading(fig(''), fig('Figure 1: Samples.'), el('h2', {}, ['1 Introduction']), p('We begin.'), el('h2', {}, ['2 Results']), p('Samples in Figure 1.'));
  assert.equal(floatsNearMentions(stays), 0);
  const logo = reading(fig('Figure 1: Tree.'), fig(''), el('h2', {}, ['1 Introduction']), p('See Figure 1.'), p('More.'));
  assert.equal(floatsNearMentions(logo), 1);
  assert.deepEqual(names(logo).slice(3, 8), ['', '1 Introduction', 'See Figure 1.', 'Figure 1: Tree.', 'More.']);
});
