// Revision 28: pictures LaTeXML set apart from their sub-captions or labels read as panels with their captions. In
// 2610.20608v1 Figure 2 the source draws three plots in one row and captions them in the next; LaTeXML wrote a paragraph of
// pictures (an `img` and two SVG `object`s), then three sub-figures holding only "(a) …", "(b) …", "(c) …". The flow read
// the paragraph as text, where a graphic is left out and counted, so the reader showed only the captions and the closing
// note counted the plots as left-out graphics. Batch Normalization's Figure 1 (1502.03167v3) is the tabular form: a row of
// three plots, then a row of their labels. Fragments are LaTeXML's markup, reduced (arxiv/figures.ts `panelsApart`,
// `labelledPanels`; docs/JUDGMENT_LOG.md 54).
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { arxivHTMLAssets, arxivHTMLURL, convertArxivHTML } from '../../supabase/functions/_shared/reader/arxiv-html.ts';
import { composeArxivReader, type ArxivImage } from '../../supabase/functions/_shared/reader/arxiv-bundle.ts';
import { parseHTML, textContent, type DomNode } from '../../supabase/functions/_shared/reader/html.ts';
import { validateHTML } from '../../supabase/functions/_shared/reader/html-validate.ts';
import { admitReaderImage } from '../../supabase/functions/_shared/reader/images.ts';
import { validateReaderBundle } from '../../supabase/functions/_shared/reader/validate.ts';
import { sha256Hex, utf8 } from '../../supabase/functions/_shared/reader/util.ts';

const url = arxivHTMLURL('2601.01234', 2);
// Each image its own published path, so the index's asset paths say which pictures the figure holds.
const pathOf = (asset: string) => `assets/${createHash('sha256').update(asset).digest('hex')}.png`;
const resolve = (asset: string) => ({ path: pathOf(asset), width: 10, height: 10 });
const convert = (html: string, admit: (asset: string) => ReturnType<typeof resolve> | null = resolve) => {
  const out = convertArxivHTML(html, url, admit);
  const images = new Map(out.imageURLs.map(u => [pathOf(u), { width: 10, height: 10 }]));
  validateHTML(new TextEncoder().encode(out.html), out.index, images, true);
  return out;
};
// The paragraph links to Figure 2's panel (b) and to its row of pictures when the page holds that figure.
const page = (body: string) => '<html><body><article class="ltx_document"><h1 class="ltx_title ltx_title_document">Panels</h1>'
  + '<div class="ltx_authors">A. Author</div><section id="S1" class="ltx_section"><h2 class="ltx_title">1 Introduction</h2>'
  + '<div id="S1.p1" class="ltx_para"><p class="ltx_p">' + (body.includes('id="S0.F2"') ? 'Alignment is shown in Fig. '
    + '<a href="#S0.F2.sf2" class="ltx_ref">2b</a>; the row is <a href="#S0.F2.2" class="ltx_ref">here</a>.' : 'We study panels.')
  + '</p></div>' + body + '</section></article></body></html>';
/** The compiled figure's parts in order: `img` for a picture, a paragraph's or caption's words. */
const parts = (html: string, caption: string) => {
  const find = (n: DomNode): DomNode[] => n.name === 'figure' ? [n] : (n.children ?? []).flatMap(find);
  const figure = find(parseHTML(html)).find(f => textContent(f).includes(caption));
  assert.ok(figure, `a figure captioned ${caption}`);
  return figure.children.filter(c => c.type === 'tag').map(c => c.name === 'img' ? 'img' : `${c.name}: ${textContent(c).replace(/\s+/g, ' ').trim()}`);
};
const note = /left out \d+ inline graphics?/;

// 2610.20608v1 Figure 2, reduced: the pictures in one `ltx_figure_panel` paragraph, each raised in a span, then the
// caption-only sub-figures in flex cells, then the figure's caption.
const subfigure = (n: number, words: string) => `<div class="ltx_flex_cell ltx_flex_size_2"><figure id="S0.F2.sf${n}" class="ltx_figure ltx_figure_panel ltx_align_center">`
  + `<figcaption class="ltx_caption"><span class="ltx_tag ltx_tag_figure">(${'abc'[n - 1]}) </span>${words}</figcaption></figure></div>`;
const row = (pictures: string[]) => `<div class="ltx_flex_cell ltx_flex_size_1"><p id="S0.F2.2" class="ltx_p ltx_figure_panel ltx_align_center">`
  + pictures.map((p, i) => `<span id="S0.F2.2.${i + 1}" class="ltx_text" style="position:relative; bottom:-15.2pt;">${p}</span>`).join(' ') + '</p></div>';
const img = '<img src="2601.01234v2/gfid_vs_cknna.png" id="S0.F2.g1" class="ltx_graphics ltx_img_landscape" width="206" height="158" alt="Refer to caption">';
const object = (name: string, n: number) => `<object type="image/svg+xml" data="2601.01234v2/${name}.svg" id="S0.F2.g${n}" class="ltx_graphics ltx_img_landscape" width="162" height="118"></object>`;
const gphi = '<math id="S0.F2.sf2.m2" class="ltx_Math" alttext="g_{\\phi}" display="inline"><semantics><msub><mi>g</mi><mi>ϕ</mi></msub>'
  + '<annotation encoding="application/x-tex">g_{\\phi}</annotation></semantics></math>';
const caption = '<figcaption class="ltx_caption ltx_centering"><span class="ltx_tag ltx_tag_figure">Figure 2: </span>Alignment with the vision encoder.</figcaption>';
const figure2 = (pictures: string[], subfigures = [subfigure(1, 'Strong correlation of gFID and CKNNA'), subfigure(2, `${gphi} output has more semantics than any layer`),
  subfigure(3, 'RECON improves CKNNA across layers')], picturesFirst = true) => '<figure id="S0.F2" class="ltx_figure"><div class="ltx_flex_figure">'
  + (picturesFirst ? row(pictures) + '<div class="ltx_flex_break"></div>' + subfigures.join('') : subfigures.join('') + '<div class="ltx_flex_break"></div>' + row(pictures))
  + '</div>' + caption + '</figure>';
const three = [img, object('cknna_vs_block_t025', 2), object('dynamics_cknna', 3)];

test('a row of pictures above caption-only sub-figures reads as panels, each picture over its caption (2610.20608v1 Figure 2)', () => {
  const out = convert(page(figure2(three)));
  assert.deepEqual(parts(out.html, 'Figure 2:'), ['img', 'p: (a) Strong correlation of gFID and CKNNA', 'img', 'p: (b) gϕ output has more semantics than any layer',
    'img', 'p: (c) RECON improves CKNNA across layers', 'figcaption: Figure 2: Alignment with the vision encoder.']);
  // Every picture is planned, fetched and published: the PNG and both SVGs.
  const assets = [url + '/gfid_vs_cknna.png', url + '/cknna_vs_block_t025.svg', url + '/dynamics_cknna.svg'];
  assert.deepEqual(arxivHTMLAssets(page(figure2(three)), url), [...assets].sort());
  const [entry] = out.index.figures;
  assert.equal(out.index.figures.length, 1);
  assert.deepEqual(entry.asset_paths, assets.map(pathOf));
  assert.equal(entry.caption, 'Figure 2: Alignment with the vision encoder.');
  // Nothing is left out, the sub-caption's formula is an equation of the figure, and links to a panel or to the row of
  // pictures open the figure.
  assert.doesNotMatch(out.html, note);
  assert.deepEqual(out.index.equations.map(e => [e.latex, e.block_id]), [['g_{\\phi}', entry.id]]);
  assert.match(out.html, new RegExp(`<a href="#${entry.id}">2b</a>; the row is <a href="#${entry.id}">here</a>`));
  assert.equal(out.index.blocks.filter(b => b.kind === 'paragraph' && /^\((a|b|c)\)/.test(b.text)).length, 0, 'no sub-caption is a paragraph of its own');
});

test('a row of pictures with words beside them (a legend) is not this layout and keeps its reading', () => {
  const legend = figure2([img + ' gFID against CKNNA', object('cknna_vs_block_t025', 2), object('dynamics_cknna', 3)]);
  const out = convert(page(legend));
  assert.equal(out.index.figures.length, 0);
  assert.match(out.html, /left out 3 inline graphics/);
});

test('sub-captions over their pictures keep that order; pictures and captions that don\'t pair stay in page order', () => {
  const above = convert(page(figure2(three, undefined, false)));
  assert.deepEqual(parts(above.html, 'Figure 2:').slice(0, 2), ['p: (a) Strong correlation of gFID and CKNNA', 'img']);
  assert.equal(above.index.figures[0].asset_paths.length, 3);
  const two = convert(page(figure2(three.slice(0, 2))));
  assert.deepEqual(parts(two.html, 'Figure 2:'), ['img', 'img', 'p: (a) Strong correlation of gFID and CKNNA',
    'p: (b) gϕ output has more semantics than any layer', 'p: (c) RECON improves CKNNA across layers', 'figcaption: Figure 2: Alignment with the vision encoder.']);
  assert.doesNotMatch(two.html, note);
});

test('a panel this device couldn\'t prepare leaves its note above its caption; the other panels show', () => {
  const out = convert(page(figure2(three)), asset => asset.endsWith('cknna_vs_block_t025.svg') ? null : resolve(asset));
  assert.deepEqual(parts(out.html, 'Figure 2:').slice(0, 4), ['img', 'p: (a) Strong correlation of gFID and CKNNA',
    'p: Part of this figure couldn’t be shown here; the PDF has it.', 'p: (b) gϕ output has more semantics than any layer']);
  assert.equal(out.index.figures[0].asset_paths.length, 2);
});

// 1502.03167v3 Figure 1, reduced: a tabular whose first row holds the plots and whose second row labels them.
const tabular = (rows: string[][], id = 'S4.F1') => `<figure id="${id}" class="ltx_figure"><table id="${id}.1" class="ltx_tabular ltx_centering ltx_align_middle"><tbody class="ltx_tbody">`
  + rows.map((cells, r) => `<tr id="${id}.1.${r + 1}" class="ltx_tr">` + cells.map((c, i) => `<td id="${id}.1.${r + 1}.${i + 1}" class="ltx_td ltx_align_center">${c}</td>`).join('') + '</tr>').join('')
  + `</tbody></table><figcaption class="ltx_caption"><span class="ltx_tag ltx_tag_figure">Figure 1: </span>(a) Test accuracy. (b, c) Input distributions.</figcaption></figure>`;
const plot = (name: string) => `<img src="2601.01234v2/${name}.png" id="S4.F1.g-${name}" class="ltx_graphics" width="134" height="101" alt="Refer to caption">`;

test('a tabular of plots with a row of labels under them reads as panels, each plot over its label (Batch Normalization Figure 1)', () => {
  const out = convert(page(tabular([[plot('mnist'), plot('evo'), plot('evo-bn')], ['(a)', '(b) Without BN', '(c) With BN']])));
  assert.deepEqual(parts(out.html, 'Figure 1:'), ['img', 'p: (a)', 'img', 'p: (b) Without BN', 'img', 'p: (c) With BN',
    'figcaption: Figure 1: (a) Test accuracy. (b, c) Input distributions.']);
  assert.deepEqual(out.index.figures[0].asset_paths, ['mnist', 'evo', 'evo-bn'].map(n => pathOf(`${url}/${n}.png`)));
  assert.equal(out.index.blocks.filter(b => b.kind === 'table').length, 0);
  assert.doesNotMatch(out.html, note);
  // Labels over their plots (a row of names, then the pictures), and rows of both repeated, pair the same way.
  const over = convert(page(tabular([['GT', 'Ours'], [plot('gt'), plot('ours')], ['Input', 'Baseline'], [plot('input'), plot('baseline')]])));
  assert.deepEqual(parts(over.html, 'Figure 1:').slice(0, 8), ['p: GT', 'img', 'p: Ours', 'img', 'p: Input', 'img', 'p: Baseline', 'img']);
});

test('a grid with row headings, a table float of icons and a tabular of words stay tables', () => {
  // A comparison grid: column names, then each row a method's name and its pictures. Its structure is the table's.
  const grid = convert(page(tabular([['', 'Venice', 'Kidney'], ['GT', plot('v-gt'), plot('k-gt')], ['SIREN', plot('v-s'), plot('k-s')]])));
  assert.equal(grid.index.figures.length, 0);
  assert.equal(grid.index.blocks.filter(b => b.kind === 'table').length, 1);
  assert.match(grid.html, /left out 4 inline graphics/);
  // A table float whose rows are icons and names is a table, as before.
  const icons = tabular([[plot('a'), plot('b')], ['Yes', 'No']]).replace('class="ltx_figure"', 'class="ltx_table"');
  assert.equal(convert(page(icons)).index.blocks.filter(b => b.kind === 'table').length, 1);
  // Labels whose row has a different length than the pictures' don't pair.
  const uneven = convert(page(tabular([[plot('a'), plot('b')], ['(a) and (b)']])));
  assert.equal(uneven.index.figures.length, 0);
});

test('the panels compose into a bundle the shared validator admits', () => {
  const raw = new Uint8Array(readFileSync(new URL('../fixtures/reader-mathpix/figure-exif.jpg', import.meta.url)));
  const jpeg: ArxivImage = { ...admitReaderImage(raw), inputSHA256: sha256Hex(raw) };
  const source = page(figure2(three) + tabular([[plot('mnist'), plot('evo')], ['(a)', '(b) Without BN']]));
  const images = new Map(arxivHTMLAssets(source, url).map(u => [u, jpeg] as [string, ArxivImage]));
  assert.equal(images.size, 5);
  const bundle = composeArxivReader({ source: utf8(source), sourceID: '2601.01234', revision: 2, images });
  const checked = validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
  assert.deepEqual(checked.index.figures.map(f => f.caption.slice(0, 9)), ['Figure 2:', 'Figure 1:']);
});
