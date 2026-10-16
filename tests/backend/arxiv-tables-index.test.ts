import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { arxivHTMLURL } from '../../supabase/functions/_shared/reader/arxiv-html.ts';
import { composeArxivReader } from '../../supabase/functions/_shared/reader/arxiv-bundle.ts';
import { admitReaderImage } from '../../supabase/functions/_shared/reader/images.ts';
import { validateReaderBundle } from '../../supabase/functions/_shared/reader/validate.ts';
import { canonicalBytes, sha256Hex, utf8 } from '../../supabase/functions/_shared/reader/util.ts';

// Revision 16: the index lists the paper's captioned tables (id and caption) for Contents › Tables. The Tables tab
// listed only tables arXiv published as images (figures), so most papers said "No tables" (browser parity, build 59).

const url = arxivHTMLURL('2601.01234', 2);
const source = readFileSync(new URL('../fixtures/reader-arxiv/source.html', import.meta.url), 'utf8');
const raw = new Uint8Array(readFileSync(new URL('../fixtures/reader-mathpix/figure-exif.jpg', import.meta.url)));
const image = { ...admitReaderImage(raw), inputSHA256: sha256Hex(raw) };
const build = (text: string) => composeArxivReader({ source: utf8(text), sourceID: '2601.01234', revision: 2, images: new Map([[url + '/figure.jpg', image]]) });
const checked = (text: string) => { const b = build(text); return validateReaderBundle(b.manifestBytes, b.members, b.manifestSHA256); };
const insert = (html: string) => source.replace('<p id="p1">', html + '<p id="p1">');
const cell = (text: string) => `<table class="ltx_tabular"><tr><td>${text}</td><td>1</td></tr></table>`;

test('a table with its own caption is listed by it; the caption is the figure caption text', () => {
  const index = checked(source).index;
  const table = index.blocks.find(b => b.kind === 'table')!;
  assert.deepEqual(index.tables, [{ id: table.id, caption: 'Table 1: Values.' }]);
});

test('captions in a row above tables in a row pair in order (2610.20608 Tables 1 and 2)', () => {
  const caption = (n: number, words: string) => `<div class="ltx_flex_cell"><figure id="T${n}.fig" class="ltx_figure ltx_figure_panel"><figcaption class="ltx_caption"><span class="ltx_tag ltx_tag_figure">Table ${n}: </span>${words}</figcaption></figure></div>`;
  const float = `<figure id="S5.T2" class="ltx_table"><div class="ltx_flex_figure ltx_flex_table">${caption(2, 'Left.')}${caption(3, 'Right.')}`
    + `<div class="ltx_flex_cell">${cell('Left cell')}</div><div class="ltx_flex_cell">${cell('Right cell')}</div></div></figure>`;
  const index = checked(insert(float)).index;
  const byText = (words: string) => index.blocks.find(b => b.kind === 'table' && b.text.startsWith(words))!.id;
  assert.deepEqual(index.tables!.slice(0, 2), [{ id: byText('Left cell'), caption: 'Table 2: Left.' }, { id: byText('Right cell'), caption: 'Table 3: Right.' }]);
});

test('one caption over sub-tables names the first; the others are not listed alone', () => {
  const float = `<figure id="S5.T4" class="ltx_table"><figcaption class="ltx_caption">Table 4: Two parts.</figcaption>`
    + `<figure id="S5.T4.a" class="ltx_table ltx_figure_panel">${cell('Part a')}</figure><figure id="S5.T4.b" class="ltx_table ltx_figure_panel">${cell('Part b')}</figure></figure>`;
  const index = checked(insert(float)).index;
  const part = (words: string) => index.blocks.find(b => b.kind === 'table' && b.text.startsWith(words))!.id;
  assert.ok(index.tables!.some(t => t.id === part('Part a') && t.caption === 'Table 4: Two parts.'));
  assert.ok(!index.tables!.some(t => t.id === part('Part b')));
});

test('a caption set inside a minipage (\\captionof) names its table, math as its LaTeX (2610.20608 Table 6)', () => {
  const float = `<figure id="S6.T8" class="ltx_table"><p class="ltx_p"><span class="ltx_block ltx_minipage"><span class="ltx_caption"><span class="ltx_tag ltx_tag_block">Table 6: </span>Ablation on <math alttext="256\\times 256" display="inline"><semantics><mrow><mn>256</mn><mo>×</mo><mn>256</mn></mrow><annotation encoding="application/x-tex">256\\times 256</annotation></semantics></math>.</span></span></p>${cell('Depth')}</figure>`;
  const index = checked(insert(float)).index;
  const table = index.blocks.find(b => b.kind === 'table' && b.text.includes('Depth'))!;
  assert.deepEqual(index.tables!.find(t => t.id === table.id), { id: table.id, caption: 'Table 6: Ablation on 256\\times 256 .' });
});

test('a table without a caption (a layout box, a listing) is not listed', () => {
  const index = checked(insert(`<div class="ltx_inline-block"><span class="ltx_transformed_outer"><span class="ltx_transformed_inner">${cell('Layout')}</span></span></div>`)).index;
  const layout = index.blocks.find(b => b.kind === 'table' && b.text.startsWith('Layout'))!;
  assert.ok(!index.tables!.some(t => t.id === layout.id));
  assert.equal(index.tables!.length, 1);
});

test('the validator: tables are optional; each names a table block once, with a caption', () => {
  const bundle = build(source);
  const resign = (edit: (index: Record<string, unknown>) => void) => {
    const members = new Map(bundle.members);
    const index = JSON.parse(new TextDecoder().decode(members.get('reader.json')));
    edit(index); members.set('reader.json', canonicalBytes(index));
    const manifest = JSON.parse(new TextDecoder().decode(bundle.manifestBytes));
    for (const m of manifest.members) { m.sha256 = sha256Hex(members.get(m.path)!); m.bytes = members.get(m.path)!.length; }
    const bytes = canonicalBytes(manifest);
    return () => validateReaderBundle(bytes, members, sha256Hex(bytes));
  };
  assert.equal(resign(index => { delete index.tables; })().index.tables, undefined, 'an index without tables still reads');
  const paragraph = (index: Record<string, unknown>) => (index.blocks as { id: string; kind: string }[]).find(b => b.kind === 'paragraph')!.id;
  assert.throws(resign(index => { index.tables = [{ id: paragraph(index), caption: 'Table 9: Not a table.' }]; }), /index_table/);
  assert.throws(resign(index => { index.tables = [{ id: (index.tables as { id: string }[])[0].id, caption: ' ' }]; }), /index_table/);
  assert.throws(resign(index => { const t = (index.tables as unknown[])[0]; index.tables = [t, t]; }), /index_collection/);
  assert.throws(resign(index => { (index.tables as Record<string, unknown>[])[0].extra = 1; }), /index_table/);
});
