// The on-device PDF converter (docs/architecture/DEVICE_PDF_ROUTE.md): parity with the desktop's Python reference
// on a recorded synthetic paper, each rule on hand-made glyphs, the gate, the image budget, the validator's
// device-pdf extension, and the built JavaScriptCore bundle in a context without Node's globals.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { assign, growLines, joinLines, lineText, linesOf, orphanRegions, recogniserRect } from '../../supabase/functions/_shared/reader/device-pdf/geometry.ts';
import { furniture, isFrontMatter, readingOrder, structure } from '../../supabase/functions/_shared/reader/device-pdf/structure.ts';
import { cellSpanOk, tableCells } from '../../supabase/functions/_shared/reader/device-pdf/tables.ts';
import { charClass, fontFamily, spansOf, tagInput } from '../../supabase/functions/_shared/reader/device-pdf/tagger.ts';
import { confidence, renderMath } from '../../supabase/functions/_shared/reader/device-pdf/math.ts';
import { composeDevicePDFReader } from '../../supabase/functions/_shared/reader/device-pdf/bundle.ts';
import { UNTRANSCRIBED_LATEX } from '../../supabase/functions/_shared/reader/device-pdf/emit.ts';
import { decodeBase64, encodeBase64 } from '../../supabase/functions/_shared/reader/device-pdf/base64.ts';
import { validateHTML } from '../../supabase/functions/_shared/reader/html-validate.ts';
import { htmlPrefix, HTML_SUFFIX } from '../../supabase/functions/_shared/reader/html.ts';
import type { Glyph, Region } from '../../supabase/functions/_shared/reader/device-pdf/types.ts';
import { det, extent, host, input, line, lines, page, png, TAGGER, type G } from './device-pdf/synthetic.ts';
import { syntheticPaper } from './device-pdf/paper.ts';

const decoder = new TextDecoder();
const region = (cls: string, pt: number[], extra: Partial<Region> = {}): Region => ({ cls, score: 0.9, box: pt.map(v => v * 150 / 72), pt: pt as Region['pt'], ...extra });

/** Every field of two reference-shaped indexes, numbers within 0.051; image paths aside (the reference numbers
 * them, this reader names them by content). */
function sameIndex(a: unknown, b: unknown, path = ''): string[] {
  if (path.endsWith('.asset_paths')) return [];
  if (Array.isArray(a) && Array.isArray(b)) return a.length !== b.length ? [`${path}: ${a.length} vs ${b.length}`] : a.flatMap((x, i) => sameIndex(x, b[i], `${path}[${i}]`));
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    return [...keys].flatMap(k => !(k in (a as object)) || !(k in (b as object)) ? [`${path}.${k}: missing`] : sameIndex((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k], `${path}.${k}`));
  }
  if (typeof a === 'number' && typeof b === 'number') return Math.abs(a - b) <= 0.051 ? [] : [`${path}: ${a} vs ${b}`];
  return a === b ? [] : [`${path}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`];
}

test('the synthetic paper reads exactly as the Python reference read it', () => {
  const fixture = JSON.parse(readFileSync(new URL('../fixtures/device-pdf/synthetic-reference.json', import.meta.url), 'utf8'));
  const { signals, reference } = fixture;
  // The fixture was recorded from paper.ts: a change to the generator must re-record it, not drift silently.
  assert.deepEqual(signals.pages, JSON.parse(JSON.stringify(syntheticPaper())));
  const h = host(signals.pages, { vocab: signals.tagger });
  const bundle = composeDevicePDFReader({ pdf: signals.pdf, pages: signals.pages.length, models: [], tagger: signals.tagger, trace: true }, h);
  assert.deepEqual(sameIndex(reference, bundle.trace), []);
  // One tagger call per page with lines, one recogniser call per page with formulas.
  assert.ok(h.log.tagCalls <= signals.pages.length && h.log.recogniseCalls <= signals.pages.length);
  assert.equal(reference.equations.length, 7);
});

test('the bundle is this reader\'s vocabulary and passes the shared validator', () => {
  const pages = syntheticPaper();
  const h = host(pages);
  const bundle = composeDevicePDFReader(input(pages.length, { title: 'Catalog title', paper: { source_id: '2610.00001', revision: 2 } }), h);
  const manifest = JSON.parse(decoder.decode(bundle.manifestBytes));
  assert.equal(manifest.renderer.id, 'gradstep-device-pdf-mathml-v1');
  assert.deepEqual(manifest.source, { kind: 'device-pdf', sha256: input(1).pdf.sha256, provenance_path: 'provenance.json' });
  assert.deepEqual(manifest.members.map((m: { path: string }) => m.path).filter((p: string) => !p.startsWith('assets/')), ['NOTICE.txt', 'index.html', 'provenance.json', 'reader.css', 'reader.json']);
  const index = JSON.parse(decoder.decode(bundle.members.get('reader.json')!));
  const html = bundle.members.get('index.html')!;
  const images = new Map(manifest.members.filter((m: { role: string }) => m.role === 'image').map((m: { path: string; width: number; height: number }) => [m.path, { width: m.width, height: m.height }]));
  assert.doesNotThrow(() => validateHTML(html, index, images as Map<string, { width: number; height: number }>, false, true));
  assert.throws(() => validateHTML(html, index, images as Map<string, { width: number; height: number }>, false, false), 'the arXiv judgement is unchanged');
  const text = decoder.decode(html);
  assert.equal(index.title, 'Sparse Experts at Scale');
  assert.match(text, /<p class="reader-authors"[^>]*>Ada Lovelace/);
  assert.match(text, /class="reader-equation reader-inline reader-math-image"[^>]*><img alt="[^"]+" height="\d+" src="assets\/[0-9a-f]{64}\.png" style="height:[0-9.]+em;vertical-align:-[0-9.]+em" width="\d+">/);
  assert.match(text, /<math display="block">/, 'a confident display renders as MathML');
  assert.match(text, /<ul class="reader-references"><li data-reader-block="[^"]+" data-reader-kind="list"[^>]*>\[1\] A. Author/);
  assert.match(text, /<p class="reader-footnote"/);
  assert.match(text, /<div class="reader-table"[^>]*><p class="reader-caption">Table 1: Results on the benchmark.<\/p><table><tbody><tr><td>Model<\/td>/);
  assert.match(text, /<figure[^>]*><img alt="Figure 1: Routing tokens to experts." height="\d+" src="assets\//);
  assert.ok(!text.includes('￼') && !text.includes('__EQ_'), 'no placeholder or marker is left in the page');
  assert.ok(!/Preprint under review|Received 1 May/.test(text), 'running heads and the front-matter strip are gone');
  const provenance = JSON.parse(decoder.decode(bundle.members.get('provenance.json')!));
  assert.equal(provenance.format, 'device-pdf-reader-provenance-v1');
  assert.deepEqual(provenance.source.paper, { source_id: '2610.00001', revision: 2 });
  assert.equal(provenance.source.pdf_sha256, manifest.source.sha256);
  assert.equal(provenance.adapter.id, manifest.renderer.id);
  assert.equal(provenance.adapter.build_sha256, manifest.renderer.build_sha256);
  assert.equal(provenance.equations.length, index.equations.length);
  assert.ok(index.equations.every((e: { latex: string }) => e.latex.length > 0));
  // Each figure's crop on its page in points (port revision 10): the apps zoom out of the crop onto the PDF. The image is
  // exactly the rectangle the host was asked to cut, at its dpi.
  assert.equal(provenance.figures.length, index.figures.length);
  assert.ok(index.figures.length > 0);
  const figureRequests = h.log.images.filter(r => !r.clean);
  for (const [id, pageIndex, x0, y0, x1, y1, width, height] of provenance.figures) {
    assert.ok(index.figures.some((f: { id: string }) => f.id === id), `figure ${id} is in the index`);
    const request = figureRequests.find(r => r.page === pageIndex);
    assert.ok(request, `the figure was cut from page ${pageIndex}`);
    const k = 72 / request.dpi;
    assert.deepEqual([x0, y0, x1, y1].map(v => Math.round(v * 10)), request.rect.map(v => Math.round(v * k * 10)));
    assert.deepEqual([width, height], [pages[pageIndex].width, pages[pageIndex].height], 'the page as shown, in points');
    assert.ok(x0 >= 0 && y0 >= 0 && x1 <= width && y1 <= height);
  }
  // Where each block's text sits (port revision 11, Show in PDF): rows [block id, page, x0, y0, x1, y1] in points, for
  // the blocks the reading emitted, each box on its page and holding glyphs whose text is the block's.
  assert.ok(Array.isArray(provenance.blocks) && provenance.blocks.length > 0);
  const blockIDs = new Set(index.blocks.map((b: { id: string }) => b.id));
  const placedIDs = new Set<string>();
  for (const [id, pageIndex, x0, y0, x1, y1] of provenance.blocks) {
    assert.ok(blockIDs.has(id), `block ${id} is in the index`);
    assert.ok(Number.isInteger(pageIndex) && pageIndex >= 0 && pageIndex < pages.length);
    assert.ok(x1 > x0 && y1 > y0 && x0 >= -1 && y0 >= -1 && x1 <= pages[pageIndex].width + 1 && y1 <= pages[pageIndex].height + 1, `${id}'s box is on its page`);
    placedIDs.add(id);
  }
  // Every paragraph, heading (but the title made from the library's), equation, table and figure has a place.
  const placedKinds = index.blocks.filter((b: { id: string; kind: string }) => placedIDs.has(b.id)).map((b: { kind: string }) => b.kind);
  for (const kind of ['paragraph', 'heading', 'equation']) assert.ok(placedKinds.includes(kind), `a ${kind} has a place`);
  const paragraph = index.blocks.find((b: { kind: string; text: string }) => b.kind === 'paragraph' && b.text.length > 40 && placedIDs.has((b as { id: string }).id));
  assert.ok(paragraph, 'a placed paragraph');
  const [, pageIndex, x0, y0, x1, y1] = provenance.blocks.find((row: unknown[]) => row[0] === paragraph.id);
  const inside = pages[pageIndex].glyphs.text.filter((_: string, i: number) => {
    const g = pages[pageIndex].glyphs, cx = (g.x0[i] + g.x1[i]) / 2, cy = (g.top[i] + g.bottom[i]) / 2;
    return cx >= x0 && cx <= x1 && cy >= y0 && cy <= y1;
  }).join('').replace(/\s+/g, '');
  const words = paragraph.text.split(/\s+/).filter((w: string) => /^[A-Za-z]{4,}$/.test(w)).slice(0, 5);
  assert.ok(words.length > 0 && words.every((w: string) => inside.includes(w)), `the box holds the paragraph's words: ${words}`);
});

test('lines: overlap joins scripts to their base; a jump back below the band starts a line', () => {
  const g = (text: string, x0: number, top: number, size = 10): Glyph => ({ text, x0, top, x1: x0 + 5, bottom: top + size, size, font: 'CMR10', upright: true });
  const ls = linesOf([g('a', 0, 100), g('2', 5, 96, 7), g('b', 10, 100), g('c', 0, 112), g('d', 5, 112)]);
  assert.deepEqual(ls.map(l => l.map(x => x.text).join('')), ['a2b', 'cd']);
  assert.deepEqual(linesOf([g('a', 100, 100), g('b', 0, 105)]).length, 1, 'overlapping and only slightly below: same line');
  assert.equal(joinLines(['experi-', 'ments follow']), 'experiments follow');
  assert.equal(joinLines(['Table-', 'Of']), 'Table- Of');
  const [text, formulas] = lineText(line('a $xy$ b', 0, 0), [[1, 3]]);
  assert.equal(text, 'a ￼ b'); assert.equal(formulas[0].map(x => x.text).join(''), 'xy');
});

test('ownership: smallest box, edge margin, growth along the line, orphans as paragraphs', () => {
  const words = line('abc def ghi', 100, 100);
  const small = region('caption', [99, 99, 116, 111]), big = region('paragraph', [90, 90, 300, 200]);
  assert.deepEqual(assign(words, [big, small]).slice(0, 3), [small, small, small], 'the smallest region holding the centre');
  const edge = region('paragraph', [101.5, 99, 300, 111]);
  assert.equal(assign(words, [edge])[0], edge, 'a glyph just outside the box, within half its height');
  const shortBox = region('paragraph', [99, 99, 117, 111]);
  const grown = growLines(words, assign(words, [shortBox]));
  assert.ok(grown.every(o => o === shortBox), 'the rest of the line joins across word gaps');
  const far = [...line('abc', 100, 100), ...line('xyz', 200, 100)];
  assert.equal(growLines(far, assign(far, [region('paragraph', [99, 99, 116, 111])]))[3], null, 'not across a gutter');
  const free = [...line('(3)', 300, 100), ...line('a list item', 60, 200), ...line('second line', 60, 211), ...line('xy', 60, 300)];
  const orphans = orphanRegions(free, free.map(() => null), 150 / 72);
  assert.equal(orphans.length, 1, 'equation numbers and short pieces stay out; stacked lines are one block');
  assert.deepEqual(orphans[0].pt.map(Math.round), [60, 200, 115, 221]);
});

test('furniture needs three pages; front matter needs three markers', () => {
  const pageOf = (n: number) => ({ height: 792, glyphs: [...line('Journal of Things', 200, 20, 8), ...line(String(n), 300, 760, 8), ...line('body text', 60, 300)] });
  assert.deepEqual([...furniture([pageOf(1), pageOf(2), pageOf(3)])], ['Journal of Things']);
  assert.equal(furniture([pageOf(1), pageOf(2)]).size, 0);
  const strip = lines(['Received 1 May; accepted 2 June.', 'Copyright the authors.'], 60, 40, 7);
  assert.equal(isFrontMatter(region('paragraph', extent(strip)), strip), true);
  assert.equal(isFrontMatter(region('paragraph', extent(strip.slice(0, 20))), strip), false);
  assert.equal(isFrontMatter(region('table', extent(strip)), strip), false);
});

test('reading order: full-width regions cut bands, narrow ones read column by column', () => {
  const r = (name: string, box: number[]) => ({ ...region('paragraph', [0, 0, 1, 1]), box, name }) as Region & { name: string };
  const order = readingOrder([r('right1', [660, 300, 1180, 400]), r('left2', [100, 420, 620, 500]), r('full', [100, 100, 1180, 200]),
    r('left1', [100, 300, 620, 400]), r('below', [100, 700, 1180, 800]), r('right2', [660, 420, 1180, 500])], 1275) as (Region & { name: string })[];
  assert.deepEqual(order.map(x => x.name), ['full', 'left1', 'left2', 'right1', 'right2', 'below']);
});

test('structure: the author block, captions on their floats or as paragraphs, floats after the text above them', () => {
  const title = region('title', [200, 70, 400, 87]), authors = region('paragraph', [180, 100, 420, 112]), note = region('footnote', [200, 114, 400, 124]);
  const abs = region('abstract', [90, 150, 520, 180]), fig = region('figure', [315, 300, 545, 410]), cap = region('caption', [315, 420, 500, 430]);
  const lone = region('caption', [60, 600, 200, 610]), p = region('paragraph', [315, 200, 545, 290]);
  const seq = structure([title, authors, note, abs, fig, cap, lone, p], 1275, true);
  const authorBlock = seq.find(r => r.cls === 'authors')!;
  assert.deepEqual(authorBlock.parts, [authors, note]);
  assert.deepEqual(fig.captions, [cap]); assert.equal(lone.cls, 'paragraph', 'a caption with no float near it is a paragraph');
  assert.ok(seq.indexOf(fig) === seq.indexOf(p) + 1, 'the figure follows the paragraph above it');
  // Two detections of one box under different classes read as the later one, twice (the reference's by_box).
  const a = region('paragraph', [100, 100, 600, 200]), b = region('heading', [100, 100, 600, 200]);
  assert.deepEqual(structure([a, b], 1275, false), [b, b]);
});

test('table cells: gaps make cells, narrow runs make columns, wide runs span, wrapped entries join', () => {
  const t = [...line('Model', 60, 100), ...line('Acc', 160, 100), ...line('Cost', 240, 100),
    ...line('Dense', 60, 115), ...line('91.0', 160, 115), ...line('1.0', 240, 115),
    ...line('A very long spanning row of text here', 60, 130),
    ...line('Sparse', 60, 145), ...line('91.5', 160, 145), ...line('0.4', 240, 145), ...line('net', 60, 156)];
  const cells = tableCells(t)!;
  const text = (row: [Glyph[], number][]) => row.map(([gl, span]) => gl.map(g => g.text).join('') + (span > 1 ? `/${span}` : ''));
  assert.deepEqual(cells.map(text), [['Model', 'Acc', 'Cost'], ['Dense', '91.0', '1.0'], ['Averylongspanningrowoftexthere/3'], ['Sparsenet', '91.5', '0.4']]);
  assert.equal(tableCells(lines(['one column', 'only here'], 60, 100)), null);
  assert.equal(cellSpanOk(line('†', 0, 0)), false); assert.equal(cellSpanOk(line('$x$', 0, 0)), true); assert.equal(cellSpanOk(line('a', 0, 0)), true);
});

test('tagger inputs: the reference features, vocabulary ids and code points', () => {
  const l = line('a $x$+1', 0, 100);
  const t = tagInput(l, TAGGER);
  assert.deepEqual(t.font, [2, 7, 2, 2]); assert.deepEqual(t.cls, [2, 2, 7, 1]); assert.deepEqual(t.char, [0, 5, 0, 0]);
  // Glyph 1 ("x" in CMMI): size/med 1, mid offset 0, gap_prev (10-5)/10 = 0.5, gap_next 0, upright, width 0.5,
  // its prior 0.9, the previous glyph's 0.01, the next one's 0.01, not the previous glyph's family.
  assert.deepEqual(t.x.slice(10, 20), [1, 0, 0.5, 0, 1, 0.5, 0.9, 0.01, 0.01, 0]);
  assert.deepEqual(t.x.slice(0, 4), [1, 0, 2, 0.5]);
  assert.equal(fontFamily('ABCDEF+CMMI10'), 'CMMI'); assert.equal(fontFamily('NimbusRomNo9L-Regu'), 'NimbusRomNo9L-Regu');
  assert.equal(charClass('𝑑'), 2, 'math italic d is lowercase, as Python reads it'); assert.equal(charClass('α'), 4); assert.equal(charClass('²'), 1);
  assert.deepEqual(spansOf([-5, 5, 5, -5, 0.9, 0.8], 0.7), [[1, 3], [4, 5]]);
  assert.equal(tagInput(line('x'.repeat(450), 0, 0), TAGGER).font.length, 400);
});

test('the gate: lowest token for inline, second lowest for display; Temml must render without a backslash', () => {
  assert.equal(confidence([0.9, 0.5, 0.99], false), 0.5); assert.equal(confidence([0.9, 0.5, 0.99], true), 0.9); assert.equal(confidence([], true), 0);
  assert.ok(renderMath('\\frac{a}{b}', false)); assert.equal(renderMath('\\foo{x}', false), null); assert.equal(renderMath('\\frac{a', false), null);
  const display = renderMath('\\sum_i x_i', true)!;
  assert.equal(display.attribs.display, 'block');
  assert.deepEqual(recogniserRect([10, 10, 20.2, 15], 150 / 72, 1275, 1650), [19, 19, 44, 33]);
});

test('degrade, never refuse: without images untranscribed formulas point to the PDF and figures keep captions', () => {
  const pages = syntheticPaper();
  const bundle = composeDevicePDFReader(input(pages.length), host(pages, { failImages: true }));
  const text = decoder.decode(bundle.members.get('index.html')!);
  assert.match(text, /reader-math-fallback/); assert.ok(!text.includes('<figure'));
  assert.match(text, /<p class="reader-caption"[^>]*>Figure 1: Routing tokens to experts.<\/p>/);
  const s = bundle.summary as { degraded: { imageFailures: number; formulaText: number } };
  assert.ok(s.degraded.imageFailures > 0 && s.degraded.formulaText > 0);
  const failed = composeDevicePDFReader(input(pages.length), host(pages, { failRecognition: true }));
  assert.deepEqual((failed.summary as { warnings: string[] }).warnings.slice(0, 1), ['equations: Error']);
});

test('the image budget: past 507 images rejected guesses never become formula text', () => {
  // One page, 600 inline formulas the gate refuses (every crop read with a confidence of 0.1).
  const rows: G[] = [];
  for (let i = 0; i < 60; i++) rows.push(...line(Array.from({ length: 10 }, (_, k) => `$${'v'.repeat(1 + ((i + k) % 5))}$`).join(' and '), 10, 40 + i * 12, 6));
  const pages = [page(rows, [det('paragraph', extent(rows, 2))])];
  const h = host(pages);
  h.recognise = crops => crops.map(() => ({ latex: 'q', probs: [0.1] }));
  const bundle = composeDevicePDFReader(input(1), h);
  const manifest = JSON.parse(decoder.decode(bundle.manifestBytes));
  assert.ok(manifest.members.length <= 512);
  const s = bundle.summary as { degraded: { formulaText: number }; equations: number };
  assert.equal(s.equations, 600); assert.ok(s.degraded.formulaText >= 90, `${s.degraded.formulaText} fell back`);
  const index = JSON.parse(decoder.decode(bundle.members.get('reader.json')!));
  assert.ok(index.equations.every((e: { latex: string }) => e.latex === UNTRANSCRIBED_LATEX));
  assert.ok(index.blocks.every((b: { text: string }) => !/\bq\b/.test(b.text)));
  assert.doesNotMatch(decoder.decode(bundle.members.get('index.html')!), /data-latex="q"|alt="q"|>q</);
});

test('a math-image representation outside its renderer, or with a free style, is refused', () => {
  const title = 'T', h1 = '<h1 data-reader-block="b1" data-reader-kind="heading" id="b1">T</h1>';
  const make = (style: string) => new TextEncoder().encode(htmlPrefix(title) + h1 +
    `<p data-reader-block="b2" data-reader-kind="paragraph" id="b2">a <span class="reader-equation reader-inline reader-math-image" data-latex="x" data-reader-equation="e1" id="e1"><img alt="x" height="3" src="assets/a.png" style="${style}" width="4"></span></p>` + HTML_SUFFIX);
  const index = { format: 'reader-index-v1', title, headings: [], figures: [], equations: [{ id: 'e1', block_id: 'b2', latex: 'x', display: false, source_form: 'body' as const }],
    blocks: [{ id: 'b1', kind: 'heading', text: 'T' }, { id: 'b2', kind: 'paragraph', text: 'a x' }] };
  const images = new Map([['assets/a.png', { width: 4, height: 3 }]]);
  assert.doesNotThrow(() => validateHTML(make('height:1.2em;vertical-align:-0.42em'), index, images, false, true));
  assert.throws(() => validateHTML(make('height:1.2em;vertical-align:-0.42em'), index, images, false, false));
  assert.throws(() => validateHTML(make('background:url(x)'), index, images, false, true));
  assert.throws(() => validateHTML(make('width:3em'), index, images, false, true), 'an inline image is sized by its height');
});

test('base64 round trip', () => {
  for (const n of [0, 1, 2, 3, 4, 5, 255, 1000]) {
    const bytes = Uint8Array.from({ length: n }, (_, i) => (i * 37 + 11) & 255);
    assert.equal(encodeBase64(bytes), Buffer.from(bytes).toString('base64'));
    assert.deepEqual(decodeBase64(Buffer.from(bytes).toString('base64'), 10_000), bytes);
  }
  assert.throws(() => decodeBase64('abc', 100)); assert.throws(() => decodeBase64('ab!d', 100)); assert.throws(() => decodeBase64(png(10, 10), 10));
});

test('the built converter runs in a bare JavaScript context (no TextEncoder, atob or crypto) and matches the source', () => {
  const code = readFileSync(new URL('../../apps/apple/ScienceReader/Resources/device-pdf-reader.js', import.meta.url), 'utf8');
  const sandbox: Record<string, unknown> = {};
  vm.createContext(sandbox);
  assert.equal(vm.runInContext('typeof TextEncoder + typeof atob + typeof crypto', sandbox), 'undefinedundefinedundefined');
  vm.runInContext(code, sandbox);
  const pages = syntheticPaper();
  sandbox.input = JSON.parse(JSON.stringify(input(pages.length, { trace: true })));
  sandbox.host = host(JSON.parse(JSON.stringify(pages)));
  const out = vm.runInContext('GradstepDevicePDF.convert(input, host)', sandbox) as { manifest_sha256: string; members: Record<string, string>; trace: string };
  const direct = composeDevicePDFReader(input(pages.length, { trace: true }), host(pages));
  assert.equal(out.manifest_sha256, direct.manifestSHA256, 'the bundle and the source make the same bytes');
  assert.deepEqual(JSON.parse(out.trace), JSON.parse(JSON.stringify(direct.trace)));
  const failure = (() => { try { vm.runInContext('GradstepDevicePDF.convert({ pdf: {} }, host)', sandbox); return null; } catch (e) { return e as { code: string }; } })();
  assert.equal(failure?.code, 'device_pdf_input');
});

test('formula crops are cleaned by the host and shown where the cleaned image sits (owner, build 62)', () => {
  const pages = syntheticPaper();
  const base = host(pages);
  const requests: { clean?: { em: number; margin: number }; rect: number[] }[] = [];
  let made = 0;
  // A host that cleans: each formula image loses 4 px of a neighbour's tails at the top and 30 px at the bottom (so an
  // inline image ends above its box and rises from the baseline), and comes back with its place on the page.
  const cleaning = { ...base, image: (r: Parameters<typeof base.image>[0]) => {
    requests.push(r);
    if (!r.clean) return base.image(r);
    const rect: [number, number, number, number] = [r.rect[0] + 3, r.rect[1] + 4, r.rect[2] - 3, r.rect[3] - 30];
    const w = rect[2] - rect[0], h = rect[3] - rect[1];
    return { png: png(w, h, 9000 + made++), width: w, height: h, rect };
  } };
  const bundle = composeDevicePDFReader(input(pages.length), cleaning);
  const formulas = requests.filter(r => r.clean), figures = requests.filter(r => !r.clean);
  assert.ok(formulas.length > 0 && figures.length > 0, 'formula crops ask for cleaning, figures do not');
  for (const r of formulas) {
    assert.ok(r.clean!.em >= 15 && r.clean!.em <= 60, 'the em is the font size at 216 dpi');
    assert.ok([Math.round(r.clean!.em * 0.12), Math.round(r.clean!.em * 0.25)].includes(r.clean!.margin), 'inline 0.12 em, display 0.25 em');
  }
  const html = decoder.decode(bundle.members.get('index.html')!);
  const manifest = JSON.parse(decoder.decode(bundle.manifestBytes));
  const index = JSON.parse(decoder.decode(bundle.members.get('reader.json')!));
  const images = new Map(manifest.members.filter((m: { role: string }) => m.role === 'image').map((m: { path: string; width: number; height: number }) => [m.path, { width: m.width, height: m.height }]));
  assert.doesNotThrow(() => validateHTML(bundle.members.get('index.html')!, index, images as Map<string, { width: number; height: number }>, false, true));
  // Sized from the cleaned image: its height in points over the font size; an image ending 30 px (10 pt) above its
  // box's bottom rises from the baseline (a positive vertical-align, no minus).
  const inline = [...html.matchAll(/class="reader-equation reader-inline reader-math-image"[^>]*><img [^>]*height="(\d+)"[^>]*style="height:([0-9.]+)em;vertical-align:(-?)([0-9.]+)em"/g)];
  assert.ok(inline.length > 0);
  for (const [, pixels, em] of inline) {
    const r = formulas.find(q => q.rect[3] - 30 - (q.rect[1] + 4) === Number(pixels) && q.clean!.margin === Math.round(q.clean!.em * 0.12))!;
    assert.ok(r, 'an inline image is one of the cleaned crops');
    assert.ok(Math.abs(Number(em) - Number(pixels) / 3 / (r.clean!.em / 3)) < 0.002, 'height = cleaned pixels / 3 / font size');
  }
  assert.ok(inline.some(([, , , sign]) => sign === ''), 'an image ending well above its box rises: no minus');
  // A host whose rectangle disagrees with its image is an image failure: the formula shows its LaTeX instead.
  const lying = { ...base, image: (r: Parameters<typeof base.image>[0]) => {
    if (!r.clean) return base.image(r);
    return { png: png(10, 10, 99), width: 10, height: 10, rect: [0, 0, 11, 10] as [number, number, number, number] };
  } };
  const fallback = decoder.decode(composeDevicePDFReader(input(pages.length), lying).members.get('index.html')!);
  assert.doesNotMatch(fallback, /reader-math-image/);
  assert.match(fallback, /reader-math-fallback/);
});

test('a background recogniser (submit, collect) gives the same bundle, and a preview with every formula as its image comes first', () => {
  const pages = syntheticPaper();
  const plain = composeDevicePDFReader(input(pages.length, { title: 'Catalog title' }), host(pages));
  type Crop = { page: number; rect: [number, number, number, number]; display?: boolean };
  const queued: Crop[][] = [];
  let collected = 0;
  const backgroundHost = () => {
    const h = host(pages);
    return { ...h, submit: (crops: Crop[]) => { queued.push(crops); return queued.length - 1; },
      collect: (ticket: number) => { collected += 1; return h.recognise(queued[ticket].map(({ page, rect }) => ({ page, rect }))); } };
  };
  const same = composeDevicePDFReader(input(pages.length, { title: 'Catalog title' }), backgroundHost());
  assert.equal(same.manifestSHA256, plain.manifestSHA256, 'the same bundle as one-call recognition');
  assert.equal(collected, queued.length);
  // With a preview the stand-in host numbers its images differently (it counts calls), so the readings are compared.
  const previews: ReturnType<typeof composeDevicePDFReader>[] = [];
  const bundle = composeDevicePDFReader(input(pages.length, { title: 'Catalog title' }), backgroundHost(), b => previews.push(b));
  const index = (b: typeof plain) => JSON.parse(decoder.decode(b.members.get('reader.json')!));
  assert.deepEqual(index(bundle).blocks, index(plain).blocks);
  assert.deepEqual(index(bundle).equations, index(plain).equations);
  assert.equal(bundle.summary.rendered, plain.summary.rendered);
  assert.ok(queued.flat().some(c => c.display === true) && queued.flat().some(c => c.display === false), 'placements travel with the crops');
  assert.equal(previews.length, 1);
  const preview = decoder.decode(previews[0].members.get('index.html')!);
  assert.ok(!preview.includes('<math'), 'no formula is typeset before it is read');
  assert.match(preview, /reader-math-image/);
  assert.equal(previews[0].summary.rendered, 0);
});
