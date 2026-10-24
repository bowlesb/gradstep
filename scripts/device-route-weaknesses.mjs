#!/usr/bin/env node
// The on-device PDF route's weaknesses, explained (docs/reviews/DEVICE_PDF_WEAKNESSES_20261024.md). Reads runs of the
// route made by `device-route-accuracy.mjs run … -- --record --trace` (or replays of them, `device-route-replay.mjs`)
// against the arXiv HTML reading of the same papers, and sorts every difference into an error taxonomy: what went
// wrong, how often, how badly, at which stage (layout, tagger, recogniser, text layer, converter rule), with the worst
// examples shown as the PDF page (rendered as the route renders it), the device's reading and the HTML's side by
// side, and the time each stage takes per page. Slow and opt-in (docs/TESTING.md); evaluation only, on this Mac.
//
//   node scripts/device-route-weaknesses.mjs --runs wk0-test@test,wk0-dev@dev[,wk0-venue@venue] --name base
//       [--baseline <name or report.json>] [--examples 6] [--no-crops] [--only id,…] [--tool <DevicePDFRouteTool>]
//
// A run is `<variant>@<label>`: the variant's directory under .artifacts/device-route/accuracy/, and the corpus it was
// read from (`test`, `dev`, `venue`, or a path). Writes .artifacts/device-route-weaknesses/<name>/index.html (the
// report, sorted by impact), report.json (for `--baseline` next time) and crops/. With `--baseline` every category
// and measure shows the change from that earlier report.
//
// Impact = severity-weighted incidents per 10 pages. Each incident has a severity from 0 to 1 (the category's rule is
// in CATEGORIES) and a stage. Truth that the PDF does not print (the arXiv revision differs from a venue PDF, HTML-only
// text) is reported but carries no impact.
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const argv = process.argv.slice(2);
const arg = (name, fallback) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : fallback; };
const flag = name => argv.includes(name);
const ACCURACY = join(ROOT, '.artifacts/device-route/accuracy');
const NAME = arg('--name', 'report');
const OUT = join(ROOT, '.artifacts/device-route-weaknesses', NAME);
const EXAMPLES = Number(arg('--examples', '6'));
const only = (arg('--only', '') ?? '').split(',').filter(Boolean);
const CORPORA = { test: 'device-route-corpus', dev: 'device-route-corpus-dev', venue: 'device-route-venue', noarxiv: 'device-route-noarxiv', scan: 'device-route-scan' };

const { parseHTML, serialize } = await import(`${ROOT}/supabase/functions/_shared/reader/html.ts`);
const { convertArxivHTML, arxivHTMLURL } = await import(`${ROOT}/supabase/functions/_shared/reader/arxiv-html.ts`);
const scorer = await import(`${ROOT}/scripts/device-route-accuracy.mjs`);
const { readBundle, compare, lcsPairs, texLeaves, normalizeTeX, editDistance } = scorer;
await scorer.loadScorer();

// ---- the taxonomy --------------------------------------------------------------------------------------------------
// id: [title, what it means, how severity is set]. Stages: layout (the detector's boxes and classes), tagger (inline
// math spans), recogniser (formula LaTeX and its confidence gate), text (the PDF's text layer or on-device OCR),
// converter (the rules in supabase/functions/_shared/reader/device-pdf), truth (the HTML differs from what the PDF
// prints, or the two readers follow different conventions: no impact).
export const CATEGORIES = {
  'text.missing': ['Text missing', 'Words of the HTML reading absent from the device reading (runs of 4+ words; shorter runs are word-level).', 'words / 30, at most 1'],
  'text.extra': ['Text added', 'Words of the device reading that the HTML reading does not have (not furniture, footnotes or front matter).', 'words / 30'],
  'text.duplicated': ['Text read twice', 'A run the device reading has twice (overlapping regions).', 'words / 30'],
  'text.misplaced': ['Text out of place', 'The same words on both sides, in a different place (part of a block moved, a column or float read in the wrong order).', 'words / 60'],
  'text.words': ['Words split, joined or misread', 'Word-level differences inside matched text: "repre sentation", "ofthe", ligatures and wrong letters.', '0.05 per word'],
  'order': ['Blocks out of order', 'A whole paragraph or block placed elsewhere in the reading (blocks off the longest in-order chain).', 'block words / 60'],
  'furniture': ['Page furniture in the text', 'Running heads, page numbers, venue lines and line numbers read as text.', 'words / 15'],
  'footnote.leak': ['Footnotes in the flow', 'Footnote text the HTML reading does not have where the device puts it, or splitting a paragraph.', 'words / 40'],
  'place.convention': ['Footnotes and floats placed differently (convention)', 'The HTML puts a footnote at its mark and a figure or table where the source defines it; the device where the page prints them. Reported, no impact.', '0'],
  'heading.missed': ['Headings missed', 'An HTML section heading the device reads as text or not at all.', '0.5'],
  'heading.spurious': ['Headings spurious', 'A device heading the HTML does not have (a caption, a label, a line of a list).', '0.4'],
  'heading.level': ['Heading at the wrong level', 'A matched heading nested at another depth than the HTML (relative to the paper\'s usual offset).', '0.2'],
  'display.missed': ['Display formula missed', 'An HTML display formula with no device display: read inline, as text or not at all.', '0.8'],
  'display.split': ['Display formula split or cut', 'The device display holds only part of the HTML\'s (rows boxed apart, crop cut).', '0.6'],
  'display.merged': ['Display formulas merged', 'The device display holds the HTML\'s and more (two displays as one, text with it).', '0.5'],
  'display.wrong': ['Display formula typeset wrong', 'Typeset (looks right) but its glyphs differ from the HTML\'s.', 'token error of the LaTeX, at least 0.3'],
  'display.image': ['Display formula left as image', 'Shown as the PDF\'s pixels (the gate held it back): readable, not selectable or explainable.', '0.25 (0.15 when it would have been right)'],
  'inline.missed': ['Inline math missed', 'An HTML inline formula the device reads as plain text or not at all.', '0.25 (0.05 when a longer device formula holds it, or it is only numbers with ± or ×)'],
  'inline.boundary': ['Inline math cut or overgrown', 'A device inline formula holding part of the HTML\'s, or more (the tagger\'s span).', '0.4; 0.1 when only digits or punctuation are outside'],
  'inline.wrong': ['Inline math typeset wrong', 'Same span, different glyphs (a misread or mistranscribed formula).', '0.6'],
  'inline.image': ['Inline math left as image', 'Shown as the PDF\'s pixels.', '0.08'],
  'table.missed': ['Table missed', 'An HTML table the device reading has neither as a table nor as its words.', '1'],
  'table.flattened': ['Table flattened to text', 'The table\'s words read as paragraphs.', '0.8'],
  'table.image': ['Table shown as image', 'The table is shown as the PDF\'s pixels (its cells could not be placed).', '0.4'],
  'table.cells': ['Table cells wrong', 'Read as a table, but its words in order differ (spans, multi-line cells): word F1 under 0.75.', '1 − word F1'],
  'figure.missed': ['Figure missed', 'An HTML figure (paired by caption) the device reading does not show.', '0.8'],
  'figure.crop': ['Figure badly cropped', 'The device crop against the picture the PDF draws there: cut (coverage under 0.9) or loose (IoU under 0.6).', '1 − IoU'],
  'figure.spurious': ['Figure spurious', 'A device figure with no HTML figure and no picture drawn under it.', '0.3'],
  'caption.detached': ['Caption detached', 'A figure or table caption read as a paragraph, apart from its figure.', '0.4'],
  'refs.merged': ['References merged', 'Two or more bibliography entries in one device entry.', '0.15'],
  'refs.split': ['References split', 'One bibliography entry across several device entries.', '0.15'],
  'refs.missing': ['Reference entry missing', 'An HTML bibliography entry with no device entry or paragraph holding half its words.', '0.3'],
  'front.title': ['Title wrong', 'The device\'s title is not the paper\'s.', '1'],
  'front.authors': ['Authors wrong', 'The author line missing, or holding under 70 % of the authors\' names.', '0.5'],
  'front.abstract': ['Abstract wrong', 'The abstract\'s words (F1) under 0.85, or no abstract.', '1 − F1'],
};
export const STAGES = ['layout', 'tagger', 'recogniser', 'text', 'converter', 'truth'];
const STAGE_TITLES = { layout: 'Layout detector', tagger: 'Inline tagger', recogniser: 'Formula recogniser', text: 'Text layer / OCR', converter: 'Converter rules', truth: 'Truth or convention (no impact)' };

// ---- inputs --------------------------------------------------------------------------------------------------------
const runs = (arg('--runs', '') ?? '').split(',').filter(Boolean).map(spec => {
  const [variant, label = 'test', corpus] = spec.split('@');
  return { variant, label, corpus: resolve(corpus ?? join(homedir(), 'gradstep-mac', CORPORA[label] ?? label)) };
});
if (!runs.length) { console.error('usage: device-route-weaknesses.mjs --runs <variant>@<label>,… [--name n] [--baseline n]'); process.exit(2); }
const readJSON = (path, fallback = null) => existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : fallback;
const round = (v, n = 3) => Number.isFinite(v) ? Math.round(v * 10 ** n) / 10 ** n : v;
const esc = s => String(s ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const WORD = /[\p{L}]+/gu;
const words = s => String(s ?? '').normalize('NFC').toLowerCase().match(WORD) ?? [];

/** The record of a run (its own, or the run a replay came from). */
function recordOf(dir) {
  if (existsSync(join(dir, 'record.json'))) return readJSON(join(dir, 'record.json'));
  const from = readJSON(join(dir, 'conversion.json'))?.replay?.from;
  return from ? readJSON(join(ACCURACY, from, basename(dir), 'record.json')) : null;
}

// ---- the PDF's words, to find where a run of words is on the page ---------------------------------------------------
/** Words of each page's text layer (as the host gave it), in stream order, each with its box in points. */
function pageWords(record) {
  const all = [];
  (record?.pages ?? []).forEach((page, p) => {
    if (!page) return;
    const g = page.glyphs;
    let cur = null;
    const flush = () => { if (cur) { all.push(cur); cur = null; } };
    for (let i = 0; i < g.text.length; i++) {
      const t = String(g.text[i] ?? '').normalize('NFC').toLowerCase();
      const letters = t.match(WORD);
      const size = Math.max(1, +g.size[i] || 1);
      if (!letters) { flush(); continue; }
      if (cur && (g.x0[i] - cur.box[2] > 0.25 * size || Math.abs(g.top[i] - cur.top) > 0.5 * size || g.x0[i] < cur.box[0] - 1)) flush();
      if (!cur) cur = { w: '', page: p, top: +g.top[i], box: [+g.x0[i], +g.top[i], +g.x1[i], +g.bottom[i]] };
      cur.w += letters.join('');
      cur.box = [Math.min(cur.box[0], g.x0[i]), Math.min(cur.box[1], g.top[i]), Math.max(cur.box[2], g.x1[i]), Math.max(cur.box[3], g.bottom[i])];
    }
    flush();
  });
  const index = new Map();
  all.forEach((w, i) => { const list = index.get(w.w) ?? []; list.push(i); index.set(w.w, list); });
  return { all, index };
}

/** Where a run of words is printed: the page and the box of the best-matching stretch of the text layer, or null. */
function locate(pw, run, hintPage = null) {
  const q = run.slice(0, 14);
  if (!q.length || !pw.all.length) return null;
  const starts = new Map();
  q.slice(0, 6).forEach((w, k) => {
    const list = pw.index.get(w);
    if (!list || list.length > 400) return;
    for (const pos of list) { const s = pos - k; if (s >= 0) starts.set(s, (starts.get(s) ?? 0) + 1); }
  });
  if (!starts.size) {
    // Every opening word is common: anchor on the rarest word of the run.
    const k = q.map((w, i) => [pw.index.get(w)?.length ?? 1e9, i]).sort((a, b) => a[0] - b[0])[0][1];
    for (const pos of pw.index.get(q[k]) ?? []) if (pos - k >= 0) starts.set(pos - k, 1);
  }
  let best = null;
  for (const s of [...starts.keys()].slice(0, 3000)) {
    let j = s, hits = [], limit = s + q.length * 2 + 4;
    for (const w of q) {
      let k = j;
      while (k < Math.min(limit, pw.all.length) && pw.all[k].w !== w) k++;
      if (k < Math.min(limit, pw.all.length)) { hits.push(k); j = k + 1; }
    }
    const score = hits.length + (hintPage !== null && pw.all[s]?.page === hintPage ? 0.5 : 0);
    if (!best || score > best.score) best = { score, hits };
  }
  if (!best || best.hits.length < Math.max(2, Math.ceil(q.length * 0.5))) return null;
  const pages = best.hits.map(h => pw.all[h].page);
  const page = pages.sort((a, b) => pages.filter(x => x === a).length - pages.filter(x => x === b).length).pop();
  const boxes = best.hits.filter(h => pw.all[h].page === page).map(h => pw.all[h].box);
  return { page, box: [Math.min(...boxes.map(b => b[0])), Math.min(...boxes.map(b => b[1])), Math.max(...boxes.map(b => b[2])), Math.max(...boxes.map(b => b[3]))], share: best.hits.length / q.length };
}

/** The layout's regions of a page in points. */
function regions(record, page) {
  const p = record?.pages?.[page];
  if (!p) return [];
  const s = 150 / 72;
  return (p.detections ?? []).map(d => ({ cls: d.cls, score: d.score, pt: d.box.map(v => v / p.scale / s) }));
}
const area = b => Math.max(0, b[2] - b[0]) * Math.max(0, b[3] - b[1]);
const intersect = (a, b) => [Math.max(a[0], b[0]), Math.max(a[1], b[1]), Math.min(a[2], b[2]), Math.min(a[3], b[3])];
const unionBox = boxes => boxes.length ? [Math.min(...boxes.map(b => b[0])), Math.min(...boxes.map(b => b[1])), Math.max(...boxes.map(b => b[2])), Math.max(...boxes.map(b => b[3]))] : null;
const iou = (a, b) => { const i = area(intersect(a, b)); return i / Math.max(1e-6, area(a) + area(b) - i); };
/** The class of the region holding most of a box (null: no region). */
function regionAt(record, loc) {
  if (!loc) return null;
  let best = null;
  for (const r of regions(record, loc.page)) {
    const share = area(intersect(r.pt, loc.box)) / Math.max(1e-6, area(loc.box));
    if (share >= 0.4 && (!best || share > best.share || (share === best.share && r.score > best.score))) best = { ...r, share };
  }
  return best;
}
const pageSize = (record, page) => ({ width: record?.pages?.[page]?.width ?? 612, height: record?.pages?.[page]?.height ?? 792 });
const inMarginBand = (record, loc) => { const { height } = pageSize(record, loc.page); return loc.box[3] < height * 0.085 || loc.box[1] > height * 0.915; };

// ---- one paper ------------------------------------------------------------------------------------------------------
/** The blocks of a bundle's page with their DOM nodes (for snippets) next to the scorer's tokens. */
function blocksWithNodes(html, device) {
  const blocks = readBundle(html, { device });
  const nodes = new Map(), parents = new Map();
  const walk = (n, parent) => { if (n.type === 'tag' && n.attribs['data-reader-block']) { nodes.set(n.attribs['data-reader-block'], n); parents.set(n.attribs['data-reader-block'], parent); return; } for (const c of n.children ?? []) walk(c, n); };
  walk(parseHTML(html), null);
  for (const b of blocks) {
    b.node = nodes.get(b.id); b.cls = b.node?.attribs?.class ?? ''; b.words = b.tokens.filter(t => t.w).map(t => t.w);
    // A bibliography entry (both readers list them under ul.reader-references).
    b.ref = b.kind === 'list' && /reader-references/.test(parents.get(b.id)?.attribs?.class ?? '');
  }
  // The truth's citations: words inside a link to a bibliography entry ("Evans (1979)" where the PDF prints "[12]").
  const refIDs = new Set(blocks.filter(b => b.ref).map(b => b.id));
  for (const b of blocks) {
    if (device || !b.node || b.ref) continue;
    const flags = [];
    const visit = (n, cite) => {
      if (n.type === 'text') { for (const w of n.data.normalize('NFC').toLowerCase().match(WORD) ?? []) flags.push(cite); return; }
      if (n.type !== 'tag' || n.attribs['data-reader-equation'] !== undefined || n.name === 'img' || (n.attribs.class ?? '').includes('reader-tag')) return;
      const inCite = cite || (n.name === 'a' && refIDs.has((n.attribs.href ?? '').replace(/^#/, '')));
      for (const c of n.children ?? []) visit(c, inCite);
    };
    for (const c of b.node.children ?? []) visit(c, false);
    const ws = b.tokens.filter(t => t.w);
    if (flags.length === ws.length) ws.forEach((t, i) => { if (flags[i]) t.cite = true; });
  }
  return blocks;
}

/** An index of a word list for finding runs in it (the same search as `locate`, over any list of words). */
function wordIndex(list) {
  const index = new Map();
  list.forEach((w, i) => { const l = index.get(w) ?? []; l.push(i); index.set(w, l); });
  return { all: list.map(w => ({ w })), index };
}
/** The share of a run found in order in an indexed list, and where. */
function findRun(ix, run) {
  const q = run.slice(0, 30);
  const starts = new Set();
  q.slice(0, 6).forEach((w, k) => { for (const pos of (ix.index.get(w) ?? []).slice(0, 400)) if (pos - k >= 0) starts.add(pos - k); });
  let best = { n: 0, at: -1, hits: [] };
  for (const s of [...starts].slice(0, 2000)) {
    let j = s, n = 0;
    const limit = Math.min(ix.all.length, s + q.length * 2 + 4);
    const hits = []; for (const w of q) { let k = j; while (k < limit && ix.all[k].w !== w) k++; if (k < limit) { n++; hits.push(k); j = k + 1; } }
    if (n > best.n) best = { n, at: s, hits };
  }
  return { share: best.n / Math.max(1, q.length), at: best.at, hits: best.hits };
}

function graphicsOf(pdf, cacheDir) {
  const path = join(cacheDir, 'graphics.json');
  if (!existsSync(path)) {
    const r = spawnSync('python3', ['-E', join(ROOT, 'scripts/device-route-graphics.py'), pdf, path], { encoding: 'utf8' });
    if (r.status !== 0) return null;
  }
  return readJSON(path);
}

function analysePaper(run, key) {
  const dir = join(ACCURACY, run.variant, key);
  const meta = readJSON(join(run.corpus, key, 'meta.json'), {});
  const [, sid, rev] = meta.arxiv_id ? [null, meta.arxiv_id, meta.revision] : (/^(.+?)v(\d+)$/.exec(key) ?? []);
  const stub = () => ({ path: `assets/${'0'.repeat(64)}.png`, width: 10, height: 10 });
  let truthHTML;
  try { truthHTML = convertArxivHTML(readFileSync(join(run.corpus, key, 'source.html'), 'utf8'), arxivHTMLURL(sid, Number(rev)), stub, { title: meta.title, authors: meta.authors }).html; }
  catch (e) { return { key, refused: String(e.message ?? e) }; }
  const deviceHTML = readFileSync(join(dir, 'index.html'), 'utf8');
  const tb = blocksWithNodes(truthHTML, false), db = blocksWithNodes(deviceHTML, true);
  const record = recordOf(dir);
  const provenance = readJSON(join(dir, 'provenance.json'), {});
  const conversion = readJSON(join(dir, 'conversion.json'), {});
  const pw = pageWords(record);
  const pdfName = run.pdfName ?? 'paper.pdf';
  const pdf = join(run.corpus, key, existsSync(join(run.corpus, key, pdfName)) ? pdfName : 'paper.pdf');
  const cache = join(OUT, 'cache', run.label, key); mkdirSync(cache, { recursive: true });
  const graphics = graphicsOf(pdf, cache);
  const metrics = compare(tb, db);
  const pages = conversion.pages ?? record?.pages?.length ?? 1;
  const incidents = [];
  const add = (cat, stage, severity, extra = {}) => incidents.push({ cat, stage, severity: round(Math.max(0, Math.min(1, severity))), paper: key, label: run.label, variant: run.variant, pdf, ...extra });
  const eqRows = new Map((provenance.equations ?? []).map(r => [r[0], { confidence: r[1], rendered: !!r[2], page: r[3], box: [r[4], r[5], r[6], r[7]] }]));

  // Flattened tokens, as the scorer flattens them (numbers set in math count as text on both sides).
  const numeric = t => t.f && !t.display && /^[0-9.,%\-+−\s]*$/.test(t.leaves ?? (t.parts ? 'x' : texLeaves(t.latex, false) || 'x'));
  const flat = blocks => blocks.flatMap((b, bi) => b.tokens.filter(t => !numeric(t)).map(t => ({ ...t, block: bi })));
  const T = flat(tb), D = flat(db);
  // The text's words without the bibliographies (their entries are compared one by one below: LaTeXML regenerates a
  // bibliography in its own order and format, so its words in order are not the paper's).
  const tw = T.map((t, i) => [t, i]).filter(([t]) => t.w && !tb[t.block].ref), dw = D.map((t, i) => [t, i]).filter(([t]) => t.w && !db[t.block].ref);
  const truthIndex = wordIndex(tw.map(([t]) => t.w));
  const dict = new Map(); const id = s => { let v = dict.get(s); if (v === undefined) { v = dict.size + 1; dict.set(s, v); } return v; };
  const pairs = lcsPairs(tw.map(([t]) => id(t.w)), dw.map(([t]) => id(t.w))) ?? null;
  const alignedT = new Set((pairs ?? []).map(([a]) => a));
  const ctx = (list, a, b, n = 10) => {
    const out = [];
    for (let i = Math.max(0, a - n); i < Math.min(list.length, b + n); i++) out.push(i >= a && i < b ? `<mark>${esc(list[i][0].w)}</mark>` : esc(list[i][0].w));
    return (a - n > 0 ? '… ' : '') + out.join(' ') + (b + n < list.length ? ' …' : '');
  };
  const deviceBlockOf = di => db[dw[di]?.[0].block];

  // 1. Text: the gaps between aligned words.
  const bigT = [], bigD = [];
  if (pairs) {
    const marks = [[-1, -1], ...pairs, [tw.length, dw.length]];
    for (let k = 0; k + 1 < marks.length; k++) {
      const [ta, da] = marks[k], [tb2, db2] = marks[k + 1];
      const nT = tb2 - ta - 1, nD = db2 - da - 1;
      if (nT <= 0 && nD <= 0) continue;
      if (nT <= 3 && nD <= 3) {
        const tWords = tw.slice(ta + 1, tb2).map(([t]) => t.w), dWords = dw.slice(da + 1, db2).map(([t]) => t.w);
        if (nT && nD) {
          const how = tWords.join('') === dWords.join('') ? 'split or joined' : 'misread';
          add('text.words', how === 'split or joined' ? 'converter' : 'text', 0.05 * Math.max(nT, nD), { sub: how, words: Math.max(nT, nD),
            truth: ctx(tw, ta + 1, tb2, 6), device: ctx(dw, da + 1, db2, 6), locWords: dWords.length ? dw.slice(Math.max(0, da - 2), db2 + 2).map(([t]) => t.w) : null });
          continue;
        }
      }
      if (nT > 0) bigT.push({ a: ta + 1, b: tb2, words: tw.slice(ta + 1, tb2).map(([t]) => t.w) });
      if (nD > 0) bigD.push({ a: da + 1, b: db2, words: dw.slice(da + 1, db2).map(([t]) => t.w) });
    }
  }
  // A run on one side whose words are a run on the other: moved, not lost.
  const bagOf = ws => ws.reduce((m, w) => m.set(w, (m.get(w) ?? 0) + 1), new Map());
  const overlap = (a, b) => { const bag = bagOf(b); let n = 0; for (const w of a) { const c = bag.get(w) ?? 0; if (c) { n++; bag.set(w, c - 1); } } return n; };
  const movedD = new Set();
  for (const r of bigT) {
    let best = null;
    if (r.words.length >= 3) for (const [j, d] of bigD.entries()) {
      if (movedD.has(j) || d.words.length < 3) continue;
      const n = overlap(r.words, d.words), share = n / Math.max(r.words.length, Math.min(d.words.length, r.words.length * 3));
      if (n >= 3 && share >= 0.5 && (!best || share > best.share)) best = { j, share, n };
    }
    if (best) { movedD.add(best.j); r.moved = bigD[best.j]; }
  }
  // A run whose words are, in order, among the device's unaligned words but spread over several places (a paragraph
  // split by a float, its first line orphaned): moved too.
  const unalignedD = []; { const alignedD = new Set((pairs ?? []).map(([, b]) => b)); dw.forEach((_, i) => { if (!alignedD.has(i)) unalignedD.push(i); }); }
  const unalignedIndex = wordIndex(unalignedD.map(i => dw[i][0].w));
  const consumed = new Set();
  for (const r of bigT) {
    if (r.moved || r.words.length < 4) continue;
    const found = findRun(unalignedIndex, r.words);
    if (found.share < 0.7) continue;
    const at = found.hits.map(h => unalignedD[h]);
    for (const i of at) consumed.add(i);
    r.moved = { a: Math.min(...at), b: Math.max(...at) + 1, words: at.map(i => dw[i][0].w) };
  }
  bigD.forEach((d, j) => { let n = 0; for (let i = d.a; i < d.b; i++) if (consumed.has(i)) n++; if (n >= 0.6 * (d.b - d.a)) movedD.add(j); });
  // Blocks out of order (the longest chain of in-order matched blocks; blocks off it are out of order).
  const tWordsOf = tb.map(b => b.words.map(id)), dWordsOf = db.map(b => b.words.map(id));
  const dsets = dWordsOf.map(ws => new Set(ws));
  const matches = [];
  tWordsOf.forEach((ws, ti) => {
    if (ws.length < 6 || ['figure', 'table', 'list'].includes(tb[ti].kind)) return;
    const set = new Set(ws);
    const cands = dsets.map((s, di) => { let n = 0; for (const w of set) if (s.has(w)) n++; return [n / set.size, di]; }).filter(([j]) => j >= 0.3).sort((a, b) => b[0] - a[0]).slice(0, 4);
    let best = null;
    for (const [, di] of cands) { const n = lcsPairs(ws, dWordsOf[di], 4000)?.length ?? 0; if (!best || n > best.n) best = { ti, di, n, covered: n / ws.length }; }
    if (best && best.covered >= 0.5) matches.push(best);
  });
  const lis = (() => { // longest non-decreasing subsequence of di over matches in truth order
    const tails = [], prev = new Array(matches.length).fill(-1), idx = [];
    matches.forEach((m, i) => {
      let lo = 0, hi = tails.length;
      while (lo < hi) { const mid = (lo + hi) >> 1; if (matches[tails[mid]].di <= m.di) lo = mid + 1; else hi = mid; }
      prev[i] = lo > 0 ? tails[lo - 1] : -1; tails[lo] = i;
    });
    const keep = new Set(); let k = tails.length ? tails[tails.length - 1] : -1;
    while (k >= 0) { keep.add(k); k = prev[k]; }
    return keep;
  })();
  const outOfOrderT = new Set();
  matches.forEach((m, i) => {
    if (lis.has(i)) return;
    outOfOrderT.add(m.ti);
    const b = db[m.di];
    add('order', 'converter', tWordsOf[m.ti].length / 60, { words: tWordsOf[m.ti].length, locWords: b.words.slice(0, 14), blockKind: tb[m.ti].kind,
      truth: esc(tb[m.ti].words.slice(0, 40).join(' ')) + ' …', device: `device block ${m.di + 1} of ${db.length}, after ${esc((db[m.di - 1]?.words ?? []).slice(-12).join(' '))}` });
  });
  for (const r of bigT) {
    const tBlock = tw[r.a]?.[0].block;
    const loc = locate(pw, r.words);
    if (r.moved) {
      if (outOfOrderT.has(tBlock)) continue; // counted as a block out of order
      const dBlock = deviceBlockOf(r.moved.a);
      const dloc = locate(pw, r.moved.words, loc?.page);
      const region = regionAt(record, dloc);
      const footnote = /reader-footnote/.test(dBlock?.cls ?? '') || region?.cls === 'footnote';
      // A float (figure, table, its caption): the HTML keeps it where the source defines it, the PDF where it is printed.
      const float = ['figure', 'table'].includes(tb[tBlock]?.kind) || ['figure', 'table'].includes(dBlock?.kind);
      const convention = footnote || float;
      add(convention ? 'place.convention' : 'text.misplaced', convention ? 'truth' : region && ['figure', 'table', 'caption'].includes(region.cls) ? 'layout' : 'converter',
        convention ? 0 : r.words.length / 60, { sub: footnote ? 'footnote' : float ? 'float' : undefined, words: r.words.length, loc: dloc ?? loc, region: region?.cls,
          truth: ctx(tw, r.a, r.b), device: ctx(dw, r.moved.a, r.moved.b) });
      continue;
    }
    // A citation the HTML writes as "Evans (1979)" where the PDF prints "[12]": the readers' conventions differ.
    const cites = tw.slice(r.a, r.b).filter(([t]) => t.cite).length;
    if (cites >= r.words.length * 0.5) { add('text.missing', 'truth', 0, { sub: 'citation written differently', words: r.words.length, truth: ctx(tw, r.a, r.b) }); continue; }
    // Missing: where is it printed, and what holds it there?
    if (r.words.length < 4) { add('text.missing', loc ? 'converter' : 'truth', loc ? r.words.length / 30 : 0, { sub: 'short', words: r.words.length, loc, truth: ctx(tw, r.a, r.b) }); continue; }
    const region = regionAt(record, loc);
    let stage, sub;
    if (!loc) { stage = 'truth'; sub = 'not printed in the PDF\'s text layer'; }
    else if (!region) { stage = 'layout'; sub = 'no layout region there'; }
    else if (['figure', 'table'].includes(region.cls)) { stage = 'layout'; sub = `inside a ${region.cls} box`; }
    else if (inMarginBand(record, loc)) { stage = 'converter'; sub = 'dropped as page furniture'; }
    else { stage = 'converter'; sub = `in a ${region.cls} region`; }
    const cut = tw[r.a]?.[0], kindT = tb[cut?.block]?.kind;
    add('text.missing', stage, stage === 'truth' ? 0 : r.words.length / 30, { sub, words: r.words.length, loc, region: region?.cls, blockKind: kindT, truth: ctx(tw, r.a, r.b) });
  }
  bigD.forEach((d, j) => {
    if (movedD.has(j)) return;
    const loc = locate(pw, d.words);
    const region = regionAt(record, loc);
    const dBlock = deviceBlockOf(d.a);
    // Read twice: the run is, in order, text the HTML has (once; the device's other copy is aligned to it).
    const found = d.words.length >= 4 ? findRun(truthIndex, d.words) : { share: 0, hits: [] };
    const matchedElsewhere = found.share >= 0.85 && found.hits.filter(h => alignedT.has(h)).length >= found.hits.length * 0.8 ? 1 : 0;
    const firstPage = loc?.page === 0;
    let cat, stage, sub;
    if (loc && inMarginBand(record, loc)) { cat = 'furniture'; stage = 'converter'; sub = 'top or bottom band'; }
    else if (/reader-footnote/.test(dBlock?.cls ?? '') || region?.cls === 'footnote') { cat = 'footnote.leak'; stage = 'converter'; sub = 'footnote text'; }
    else if (d.words.length >= 4 && matchedElsewhere >= 0.85) { cat = 'text.duplicated'; stage = region ? 'converter' : 'layout'; sub = 'read twice'; }
    else if (firstPage && dBlock && db.indexOf(dBlock) < 8) { cat = 'text.extra'; stage = 'converter'; sub = 'front matter (affiliations, notes)'; }
    else if (region && ['figure', 'table'].includes(region.cls)) { cat = 'text.extra'; stage = 'layout'; sub = `words of a ${region.cls}`; }
    else if (!loc) { cat = 'text.extra'; stage = 'text'; sub = 'not in the text layer as words (garbled or OCR)'; }
    else { cat = 'text.extra'; stage = 'truth'; sub = 'printed in the PDF, not in the HTML'; }
    const sev = cat === 'furniture' ? d.words.length / 15 : cat === 'footnote.leak' ? d.words.length / 40 : stage === 'truth' ? 0 : d.words.length / 30;
    if (d.words.length < 2 && cat === 'text.extra') return;
    add(cat, stage, sev, { sub, words: d.words.length, loc, region: region?.cls, device: ctx(dw, d.a, d.b) });
  });

  // 2. Headings.
  const normTitle = t => t.toLowerCase().replace(/[^a-z]+/g, '').replace(/^appendix/, '');
  const runIn = t => { t = t.trim(); return /[:.]$/.test(t) && t.split(/\s+/).length <= 6 && !/^([Aa]ppendix\s+)?(\d+(\.\d+)*|[A-Z](\.\d+)*)\.?\s/.test(t); };
  const paragraphStarts = db.filter(b => b.kind === 'paragraph').map(b => b.words.slice(0, 12).join(''));
  const opensParagraph = t => { const n = t.replace(/[^a-z]/g, ''); return n.length > 0 && paragraphStarts.some(s => s.startsWith(n)); };
  const th = tb.filter(b => b.kind === 'heading' && /^h[1-4]$/.test(b.tag)).filter(b => { const t = b.words.join(' '); return t && !runIn(textOf(b.node) || t) && !opensParagraph(t); });
  const dh = db.filter(b => b.kind === 'heading');
  const dhByTitle = new Map(dh.map(b => [normTitle(b.words.join(' ')), b]));
  const thByTitle = new Map(th.map(b => [normTitle(b.words.join(' ')), b]));
  const levelDiffs = [];
  for (const b of th) {
    const key2 = normTitle(b.words.join(' '));
    if (!key2) continue;
    const d = dhByTitle.get(key2);
    if (d) { levelDiffs.push([Number(b.tag[1]) - Number(d.tag[1]), b, d]); continue; }
    const loc = locate(pw, b.words);
    const region = regionAt(record, loc);
    const inText = db.find(x => x.kind !== 'heading' && x.words.join(' ').includes(b.words.join(' ')));
    add('heading.missed', region?.cls === 'heading' ? 'converter' : loc ? 'layout' : 'truth', loc ? 0.5 : 0, { sub: inText ? `read as ${inText.kind}` : loc ? 'not read' : 'not in the PDF',
      loc, region: region?.cls, truth: esc(b.words.join(' ')), device: inText ? esc(inText.words.slice(0, 30).join(' ')) : '' });
  }
  const mode = (() => { const m = new Map(); for (const [d] of levelDiffs) m.set(d, (m.get(d) ?? 0) + 1); return [...m.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] ?? 0; })();
  for (const [diff, t, d] of levelDiffs) if (diff !== mode && t.tag !== 'h1') add('heading.level', 'converter', 0.2, { truth: `${t.tag}: ${esc(t.words.join(' '))}`, device: `${d.tag}: ${esc(d.words.join(' '))}`, locWords: d.words });
  for (const d of dh) {
    const key2 = normTitle(d.words.join(' '));
    if (!key2 || thByTitle.has(key2) || d.tag === 'h1') continue;
    // A truth heading the scorer leaves out (run-in, h5/h6 theorem labels, Abstract) is not spurious.
    if (tb.some(b => b.kind === 'heading' && normTitle(b.words.join(' ')) === key2)) continue;
    if (tb.some(b => b.kind === 'paragraph' && normTitle(b.words.slice(0, d.words.length).join(' ')) === key2 && d.words.length <= 6 && /[.:]$/.test(textOf(d.node)))) continue;
    const loc = locate(pw, d.words);
    const region = regionAt(record, loc);
    const where = tb.find(b => b.kind !== 'heading' && b.words.join(' ').includes(d.words.join(' ')));
    add('heading.spurious', region?.cls === 'heading' || region?.cls === 'title' ? 'layout' : 'converter', 0.4, { sub: where ? `HTML: part of a ${where.kind}` : 'not in the HTML', loc, region: region?.cls,
      device: `${d.tag}: ${esc(d.words.join(' '))}`, truth: where ? esc(where.words.slice(0, 30).join(' ')) : '' });
  }

  // 3. Formulas: each truth formula paired with the device formula of its placement nearest in glyphs, between the
  // words aligned around it (as the scorer pairs them).
  const leafCache = new Map();
  const leaves = t => { if (!leafCache.has(t)) leafCache.set(t, (t.parts ?? [t]).map(x => x.leaves ?? texLeaves(x.latex, x.display)).join('')); return leafCache.get(t); };
  const tIndexOfWord = tw.map(([, i]) => i), dIndexOfWord = dw.map(([, i]) => i);
  const anchor = new Map((pairs ?? []).map(([a, b]) => [tIndexOfWord[a], dIndexOfWord[b]]));
  const anchoredT = [...anchor.keys()].sort((a, b) => a - b);
  const used = new Set();
  const tokenize = tex => normalizeTeX(tex).match(/\\[A-Za-z]+|\\.|[^\s]/g) ?? [];
  let k = 0, displayTokErr = 0, displayPaired = 0;
  const formulaStats = { display: { truth: 0, paired: 0, right: 0 }, inline: { truth: 0, paired: 0, right: 0 } };
  // A table's formulas first, by equal glyphs with the device's table formulas: the two readers may order a table's
  // cells differently (rows against columns), so the words around a cell do not anchor it.
  const tableRight = new Set();
  {
    const pool = new Map();
    D.forEach((c, j) => { if (c.f && db[c.block]?.kind === 'table') { const key = `${c.display}|${leaves(c)}`; pool.set(key, [...(pool.get(key) ?? []), j]); } });
    T.forEach((t, i) => {
      if (!t.f || tb[t.block]?.kind !== 'table') return;
      const list = pool.get(`${t.display}|${leaves(t)}`);
      const j = list?.find(x => !used.has(x));
      if (j !== undefined && leaves(t)) { used.add(j); tableRight.add(i); }
    });
  }
  for (let i = 0; i < T.length; i++) {
    const t = T[i];
    if (!t.f) continue;
    if (tableRight.has(i)) { const kind = t.display ? 'display' : 'inline'; formulaStats[kind].truth++; formulaStats[kind].paired++; formulaStats[kind].right++; continue; }
    while (k < anchoredT.length && anchoredT[k] < i) k++;
    const lo = k > 0 ? anchor.get(anchoredT[k - 1]) : -1, hi = k < anchoredT.length ? anchor.get(anchoredT[k]) : D.length;
    let best = -1, bestCost = Infinity;
    for (let j = lo + 1; j < hi; j++) {
      const c = D[j];
      if (!c.f || used.has(j) || c.display !== t.display) continue;
      const a = leaves(t), b = leaves(c);
      const cost = Math.min(1, editDistance(a, b) / Math.max(1, a.length, b.length));
      if (cost < bestCost) { bestCost = cost; best = j; }
    }
    // Not between its anchoring words (the words around it aligned elsewhere, or the formula moved): the same formula
    // nearby still counts as found.
    if (best < 0) {
      for (let j = Math.max(0, lo - 300); j < Math.min(D.length, hi + 300); j++) {
        const c = D[j];
        if (!c.f || used.has(j) || c.display !== t.display) continue;
        const a = leaves(t), b = leaves(c);
        const cost = Math.min(1, editDistance(a, b) / Math.max(1, a.length, b.length));
        if (cost <= 0.2 && cost < bestCost) { bestCost = cost; best = j; }
      }
    }
    const kind = t.display ? 'display' : 'inline';
    formulaStats[kind].truth++;
    const tBlock = tb[t.block];
    const truthSnippet = `<div class="math">${t.parts ? t.parts.map(p => mathHTML(tb, p)).join('') : mathHTML(tb, t)}</div><code>${esc(t.latex.slice(0, 400))}</code>`;
    const near = () => { // where the formula would be: the words just before it
      const before = T.slice(Math.max(0, i - 12), i).filter(x => x.w).map(x => x.w);
      return locate(pw, before.length >= 3 ? before : T.slice(i + 1, i + 14).filter(x => x.w).map(x => x.w));
    };
    if (best < 0) {
      const window = D.slice(lo + 1, hi);
      const inlineThere = window.filter(c => c.f && !c.display);
      const loc = near();
      if (t.display) {
        add('display.missed', 'layout', 0.8, { sub: inlineThere.length ? 'read as inline formulas' : window.some(c => c.w) ? 'read as text' : 'not read', loc, region: regionAt(record, loc)?.cls,
          truth: truthSnippet, device: inlineThere.length ? inlineThere.slice(0, 4).map(c => `<code>${esc(c.latex.slice(0, 160))}</code>`).join(' ') : esc(window.filter(c => c.w).slice(0, 25).map(c => c.w).join(' ')) });
      } else {
        // Inside a device formula that holds it and its neighbour ("N = N_a, w_m = c_m" as one): shown as math all the same.
        const a = leaves(t);
        const holder = a && D.slice(Math.max(0, lo - 2), Math.min(D.length, hi + 2)).find(c => c.f && !c.display && leaves(c).length > a.length && leaves(c).includes(a));
        if (!a) add('inline.missed', 'truth', 0, { sub: 'nothing visible (spacing or phantom)', truth: truthSnippet });
        // Numbers with ± or × ("93.4 ± 0.2", a table's usual cell) read as text: it reads the same.
        else if (/^[0-9.,%±×∓+\-−()^\s]*$/.test(a)) add('inline.missed', 'tagger', 0.05, { sub: 'numbers with ± or × read as text', loc, truth: truthSnippet, device: esc(window.filter(c => c.w).slice(0, 12).map(c => c.w).join(' ')) });
        else if (holder) add('inline.missed', 'tagger', 0.05, { sub: 'inside a longer device formula', loc, truth: truthSnippet, device: `<code>${esc(holder.latex.slice(0, 200))}</code>` });
        else add('inline.missed', 'tagger', 0.25, { sub: `in a ${tBlock?.kind ?? 'block'}`, loc, truth: truthSnippet, device: esc(window.filter(c => c.w).slice(0, 12).map(c => c.w).join(' ')) });
      }
      continue;
    }
    used.add(best);
    formulaStats[kind].paired++;
    const c = D[best], a = leaves(t), b = leaves(c);
    const right = !!a && a === b;
    if (right) formulaStats[kind].right++;
    const row = eqRows.get(c.id);
    const loc = row ? { page: row.page, box: row.box } : near();
    const deviceSnippet = `<div class="math">${mathHTML(db, c, run.variant, key)}</div><code>${esc(c.latex.slice(0, 400))}</code>${row ? ` <small>confidence ${row.confidence}</small>` : ''}`;
    const extra = { loc, truth: truthSnippet, device: deviceSnippet, deviceBox: row?.box };
    const transcribed = row?.confidence === 1;
    if (t.display) {
      const tt = tokenize(t.latex), dt = tokenize(c.latex);
      const tokErr = Math.min(1, editDistance(tt, dt) / Math.max(1, tt.length));
      displayTokErr += tokErr; displayPaired++;
      if (right) { if (c.shown === 'image') add('display.image', 'recogniser', 0.15, { sub: 'right, held back by the gate', ...extra }); continue; }
      const contains = (x, y) => x.length > y.length && y.length >= 3 && x.includes(y);
      const sub = (x, y) => { const n = lcsPairs([...x].map(ch => ch.codePointAt(0)), [...y].map(ch => ch.codePointAt(0)), 2000)?.length ?? 0; return n / Math.max(1, [...y].length); };
      if (b.length > a.length * 1.3 && (contains(b, a) || sub(b, a) >= 0.9)) add('display.merged', 'layout', 0.5, { sub: 'holds more than the HTML display', tokErr: round(tokErr), ...extra });
      else if (b.length < a.length * 0.8 && (contains(a, b) || sub(a, b) >= 0.9)) add('display.split', 'layout', 0.6, { sub: 'holds part of the HTML display', tokErr: round(tokErr), ...extra });
      else if (c.shown === 'image') add('display.image', 'recogniser', 0.25, { sub: 'wrong reading, held back by the gate', tokErr: round(tokErr), ...extra });
      else if (c.shown === 'typeset') add('display.wrong', 'recogniser', Math.max(0.3, tokErr), { sub: tokErr < 0.1 ? 'one or two symbols' : 'misread', tokErr: round(tokErr), ...extra });
      else add('display.image', 'converter', 0.25, { sub: 'shown as LaTeX text', ...extra });
    } else {
      if (c.shown === 'image') { add('inline.image', 'recogniser', 0.08, { sub: right ? 'right, held back by the gate' : 'held back by the gate', ...extra }); continue; }
      if (right) continue;
      const boundary = a && b && (a.includes(b) || b.includes(a));
      if (boundary) {
        // Two device formulas side by side (no words between) that together are the HTML's: one formula read as two
        // spans (a line break, an operator the tagger left out).
        const nextF = D[best + 1]?.f ? D[best + 1] : null, prevF = D[best - 1]?.f ? D[best - 1] : null;
        const joined = (nextF && a.startsWith(b) && a.includes(leaves(nextF))) || (prevF && a.endsWith(b) && a.includes(leaves(prevF)));
        // What one side has beyond the other: digits and punctuation only ("±" for "2.7% ± 1.8%") reads almost the same.
        const [long, short] = a.length >= b.length ? [a, b] : [b, a];
        const rest = long.replace(short, '');
        const cosmetic = /^[0-9.,;:%\s+\-−()]*$/.test(rest);
        add('inline.boundary', 'tagger', cosmetic ? 0.1 : 0.4, { sub: joined ? 'read as two formulas' : cosmetic ? 'numbers or punctuation outside' : b.length < a.length ? 'cut short' : 'overgrown', ...extra });
      }
      else add('inline.wrong', transcribed ? 'converter' : 'recogniser', 0.6, { sub: transcribed ? 'transcribed from the text layer' : 'recognised', ...extra });
    }
  }

  // 4. Tables.
  const tableWords = b => b.words;
  for (const t of tb.filter(b => b.kind === 'table')) {
    const ws = tableWords(t);
    if (ws.length < 4) continue;
    const scored = db.map((d, di) => [overlap(ws, d.words) / ws.length, di]).sort((a, b) => b[0] - a[0]);
    const asTable = scored.find(([s, di]) => s >= 0.3 && db[di].kind === 'table');
    const loc = locate(pw, ws.slice(0, 14));
    const truthSnippet = `<div class="table">${trimHTML(serialize(t.node), 3000)}</div>`;
    if (asTable) {
      const d = db[asTable[1]];
      const dloc = locate(pw, d.words.slice(0, 14)) ?? loc;
      if (d.tag === 'figure') { add('table.image', 'converter', 0.4, { sub: 'cells not placed', loc: dloc, truth: truthSnippet, device: deviceHTMLSnippet(d, run.variant, key) }); continue; }
      const n = lcsPairs(ws.map(id), d.words.map(id))?.length ?? 0, f1 = 2 * n / Math.max(1, ws.length + d.words.length);
      if (f1 < 0.75) add('table.cells', 'converter', 1 - f1, { sub: `word F1 ${round(f1, 2)}`, loc: dloc, truth: truthSnippet, device: deviceHTMLSnippet(d, run.variant, key) });
      continue;
    }
    const inText = scored.filter(([s, di]) => s >= 0.1 && db[di].kind !== 'table').slice(0, 3);
    const total = inText.reduce((n, [s]) => n + s, 0);
    const region = regionAt(record, loc);
    if (total >= 0.4) add('table.flattened', 'layout', 0.8, { sub: region ? `layout: ${region.cls}` : 'no table box', loc, region: region?.cls, truth: truthSnippet, device: inText.map(([, di]) => deviceHTMLSnippet(db[di], run.variant, key)).join('') });
    else add('table.missed', loc ? 'layout' : 'truth', loc ? 1 : 0, { sub: region?.cls === 'figure' ? 'boxed as a figure' : loc ? 'not read' : 'not in the PDF', loc, region: region?.cls, truth: truthSnippet });
  }

  // 5. Figures and captions: paired by their captions' words.
  const capWords = b => { const cap = b.node ? findTag(b.node, 'figcaption') : null; return cap ? words(textOf(cap)) : []; };
  const tFigs = tb.filter(b => b.kind === 'figure').map(b => ({ b, cap: capWords(b) })).filter(f => f.cap.length >= 3);
  const dFigs = db.filter(b => b.kind === 'figure' && b.tag === 'figure').map(b => ({ b, cap: capWords(b), crop: (provenance.figures ?? []).find(r => r[0] === b.id) }));
  const jacc = (a, b) => { const A = new Set(a), B = new Set(b); let n = 0; for (const w of A) if (B.has(w)) n++; return n / Math.max(1, A.size + B.size - n); };
  const pairedD = new Set();
  const gr = graphics?.pages ?? [];
  for (const f of tFigs) {
    let best = null;
    dFigs.forEach((d, j) => { if (pairedD.has(j)) return; const s = jacc(f.cap, d.cap); if (s >= 0.35 && (!best || s > best.s)) best = { s, j }; });
    if (!best) {
      // Its caption read as a paragraph?
      const asText = db.find(d => d.kind !== 'figure' && d.kind !== 'table' && overlap(f.cap.slice(0, 30), d.words) >= Math.min(25, f.cap.length) * 0.7);
      const loc = locate(pw, f.cap.slice(0, 14));
      if (asText) add('caption.detached', 'layout', 0.4, { sub: 'caption read as a paragraph', loc, truth: esc(f.cap.slice(0, 40).join(' ')), device: deviceHTMLSnippet(asText, run.variant, key) });
      // A figure the HTML shows that the device does not.
      const hasImage = dFigs.some((d, j) => !pairedD.has(j) && d.crop && loc && d.crop[1] === loc.page && !d.cap.length);
      if (!hasImage) add('figure.missed', loc ? 'layout' : 'truth', loc ? 0.8 : 0, { sub: asText ? 'caption read as text' : 'no figure there', loc, truth: esc(f.cap.slice(0, 40).join(' ')) });
      continue;
    }
    pairedD.add(best.j);
    const d = dFigs[best.j];
    if (!d.crop) continue;
    const [, page, x0, y0, x1, y1] = d.crop, crop = [x0, y0, x1, y1];
    const pics = (gr[page]?.graphics ?? []).filter(g => g[5] < 0.35 && area(g) <= 2 * area([x0, y0, x1, y1]) && area(intersect(g, [x0 - 16, y0 - 16, x1 + 16, y1 + 16])) > 0.2 * area(g));
    if (!pics.length) continue;
    const truthBox = unionBox(pics.map(g => g.slice(0, 4)));
    const coverage = area(intersect(truthBox, crop)) / Math.max(1e-6, area(truthBox));
    // The crop may hold the picture's labels (text outside the drawn box): IoU against the picture grown by 14 pt.
    const grown = [truthBox[0] - 14, truthBox[1] - 14, truthBox[2] + 14, truthBox[3] + 14];
    const score = Math.max(iou(crop, truthBox), iou(crop, grown));
    figureIoU.push(score);
    if (coverage < 0.9 || score < 0.6) add('figure.crop', 'layout', Math.max(1 - score, 1 - coverage), { sub: coverage < 0.5 ? 'cut: under half the picture inside' : coverage < 0.9 ? 'cut: 50–90 % of the picture inside' : 'loose (IoU under 0.6)', coverage: round(coverage, 2),
      loc: { page, box: unionBox([crop, truthBox]) }, deviceBox: crop, truthBox, truth: esc(f.cap.slice(0, 40).join(' ')), device: deviceHTMLSnippet(d.b, run.variant, key), iou: round(score) });
  }
  dFigs.forEach((d, j) => {
    if (pairedD.has(j) || !d.crop) return;
    const [, page, x0, y0, x1, y1] = d.crop;
    const pics = (gr[page]?.graphics ?? []).filter(g => area(intersect(g, [x0, y0, x1, y1])) > 0.2 * area(g));
    const capInTruth = d.cap.length >= 3 && tb.some(b => (b.kind === 'figure' || b.kind === 'table') && jacc(capWords(b), d.cap) >= 0.35);
    if (!pics.length && !capInTruth) add('figure.spurious', 'layout', 0.3, { sub: d.cap.length ? 'caption not an HTML figure\'s' : 'no caption, nothing drawn', loc: { page, box: [x0, y0, x1, y1] }, deviceBox: [x0, y0, x1, y1], device: deviceHTMLSnippet(d.b, run.variant, key) });
  });

  // 6. References: each HTML entry against the device entries.
  // (The truth's entry without its label, "Spohn (2014)", which the PDF's numbered list does not print.)
  const tRefs = tb.filter(b => b.ref).map(b => { const marker = b.node ? words(textOf(findClass(b.node, 'reader-marker'))).length : 0; return { b, ws: b.words.slice(marker) }; }).filter(r => r.ws.length >= 4);
  const dCands = db.map((b, i) => [b, i, bagOf(b.words)]).filter(([b]) => b.ref || b.kind === 'paragraph');
  const overlapBag = (ws, bag) => { const left = new Map(); let n = 0; for (const w of ws) { const c = left.has(w) ? left.get(w) : (bag.get(w) ?? 0); if (c > 0) { n++; left.set(w, c - 1); } else left.set(w, 0); } return n; };
  const holders = new Map();
  for (const { b: t, ws: all2 } of tRefs) {
    const ws = all2.slice(0, 40);
    let best = null;
    for (const [d, i, bag] of dCands) { const n = overlapBag(ws, bag); if (!best || n > best.n) best = { n, i, d }; }
    const snippet = { truth: esc(all2.slice(0, 30).join(' ')), device: best ? esc(best.d.words.slice(0, 40).join(' ')) : '', locWords: all2.slice(0, 12) };
    if (!best || best.n < ws.length * 0.5) {
      const loc = locate(pw, all2.slice(0, 12)), region = regionAt(record, loc);
      add('refs.missing', loc ? (region?.cls === 'bibitem' ? 'converter' : 'layout') : 'truth', loc ? 0.3 : 0, { sub: loc ? `printed in a ${region?.cls ?? 'place with no region'}` : 'not in the PDF', ...snippet, loc, locWords: undefined });
      continue;
    }
    const covered = best.n / ws.length;
    if (covered < 0.8) { add('refs.split', 'converter', 0.15, snippet); continue; }
    holders.set(best.i, [...(holders.get(best.i) ?? []), t]);
  }
  for (const [i, ts] of holders) if (ts.length > 1 || !db[i].ref) for (const t of ts.slice(db[i].ref ? 1 : 0))
    add('refs.merged', db[i].ref ? 'converter' : 'layout', 0.15, { sub: db[i].ref ? 'entries in one' : 'read as a paragraph', truth: esc(t.words.slice(0, 30).join(' ')), device: esc(db[i].words.slice(0, 50).join(' ')), locWords: t.words.slice(0, 12) });

  // 7. Front matter.
  const tTitle = tb.find(b => b.tag === 'h1'), dTitle = db.find(b => b.tag === 'h1');
  const f1 = (a, b) => 2 * overlap(a, b) / Math.max(1, a.length + b.length);
  if (tTitle && (!dTitle || f1(tTitle.words, dTitle.words) < 0.8)) add('front.title', 'converter', 1, { truth: esc(tTitle.words.join(' ')), device: esc(dTitle?.words.join(' ') ?? '(none)'), locWords: tTitle.words });
  const tAuth = tb.find(b => /reader-authors/.test(b.cls)), dAuth = db.find(b => /reader-authors/.test(b.cls));
  if (tAuth && tAuth.words.length) {
    const rec = dAuth ? overlap(tAuth.words, dAuth.words) / tAuth.words.length : 0;
    if (rec < 0.7) add('front.authors', dAuth ? 'converter' : 'layout', 0.5, { sub: dAuth ? `${Math.round(rec * 100)} % of the names` : 'no author line', truth: esc(tAuth.words.join(' ')), device: esc(dAuth?.words.join(' ') ?? '(none)'), locWords: tAuth.words.slice(0, 8) });
  }
  const abstractOf = (bs, device) => {
    const i = bs.findIndex(b => b.kind === 'heading' && /^abstract$/.test(b.words.join(' ')));
    const byClass = bs.filter(b => /reader-abstract/.test(b.cls));
    if (byClass.length) return byClass.flatMap(b => b.words);
    return i >= 0 && bs[i + 1] ? bs[i + 1].words : device ? null : null;
  };
  const tAbs = abstractOf(tb, false), dAbs = abstractOf(db, true);
  if (tAbs && tAbs.length >= 20) {
    const score = dAbs ? f1(tAbs, dAbs) : 0;
    if (score < 0.85) add('front.abstract', 'converter', 1 - score, { sub: dAbs ? `word F1 ${round(score, 2)}` : 'no abstract block', truth: esc(tAbs.slice(0, 50).join(' ')) + ' …', device: esc((dAbs ?? []).slice(0, 50).join(' ')) + ' …', locWords: tAbs.slice(0, 14) });
  }

  // Locations for incidents that carry only words.
  for (const inc of incidents) if (!inc.loc && inc.locWords) { inc.loc = locate(pw, inc.locWords); delete inc.locWords; } else delete inc.locWords;
  for (const inc of incidents) if (inc.loc && !inc.region) inc.region = regionAt(record, inc.loc)?.cls;

  // Timing per page and stage.
  const timing = { pages, wall: readJSON(join(dir, 'wall.json'))?.seconds ?? null, preview: readJSON(dir + '.preview.json')?.seconds ?? null,
    host: conversion.host_seconds ?? null, load: conversion.model_load_seconds ?? null, perPage: conversion.host_pages ?? null,
    formulasPerPage: (() => { const n = new Array(pages).fill(0), rec = new Array(pages).fill(0); for (const r of provenance.equations ?? []) { if (r[3] < pages) { n[r[3]]++; if (r[1] !== 1) rec[r[3]]++; } } return { all: n, recognised: rec }; })() };
  return { key, label: run.label, variant: run.variant, pages, template: meta.template ?? null, metrics: { text: metrics.text, order: metrics.order, headings: metrics.headings, equations: metrics.equations, tables: metrics.tables, figures: metrics.figures },
    displayTokenError: displayPaired ? round(displayTokErr / displayPaired) : null, formulaStats, incidents, timing, pdf };
}
const figureIoU = [];

function textOf(node) { if (!node) return ''; if (node.type === 'text') return node.data; return (node.children ?? []).map(textOf).join(''); }
function findClass(node, cls) { if (node.type === 'tag' && (node.attribs.class ?? '').split(/\s+/).includes(cls)) return node; for (const c of node.children ?? []) { const f = findClass(c, cls); if (f) return f; } return null; }
function findTag(node, name) { if (node.type === 'tag' && node.name === name) return node; for (const c of node.children ?? []) { const f = findTag(c, name); if (f) return f; } return null; }
function trimHTML(html, n) { return html.length > n ? html.slice(0, n).replace(/<[^>]*$/, '') + ' …' : html; }
/** A formula's HTML from its bundle (by id for the device; the truth's span has none: its MathML from the LaTeX's own node). */
function mathHTML(blocks, t, variant, key) {
  const block = blocks[t.block];
  if (!block?.node) return '';
  let found = null;
  const visit = n => { if (found || n.type !== 'tag') return; if (n.attribs['data-reader-equation'] !== undefined && (t.id ? n.attribs.id === t.id : n.attribs['data-latex'] === t.latex)) { found = n; return; } for (const c of n.children ?? []) visit(c); };
  visit(block.node);
  return found ? fixAssets(serialize(found), variant, key) : '';
}
function deviceHTMLSnippet(block, variant, key) { return `<div class="device-block">${fixAssets(trimHTML(serialize(block.node), 4000), variant, key)}</div>`; }
/** Bundle asset paths, relative to the report's page. */
function fixAssets(html, variant, key) {
  if (!variant) return html.replace(/<img[^>]*>/g, '');
  return html.replace(/src="assets\//g, `src="${relative(OUT, join(ACCURACY, variant, key))}/assets/`);
}

// ---- all papers ------------------------------------------------------------------------------------------------------
mkdirSync(OUT, { recursive: true });
const papers = [];
for (const run of runs) {
  const dir = join(ACCURACY, run.variant);
  if (!existsSync(dir)) { console.error(`no run ${dir}`); process.exit(2); }
  const keys = readdirSync(dir).filter(k => existsSync(join(dir, k, 'index.html')) && existsSync(join(run.corpus, k, 'source.html'))).filter(k => !only.length || only.includes(k)).sort();
  for (const key of keys) {
    const started = Date.now();
    let paper;
    try { paper = analysePaper(run, key); } catch (e) { console.log(`${run.label} ${key}: analysis failed: ${e.stack?.split('\n').slice(0, 3).join(' | ')}`); continue; }
    if (paper.refused) { console.log(`${run.label} ${key}: the HTML reader refuses this paper; not scored`); continue; }
    papers.push(paper);
    console.log(`${run.label} ${key}: ${paper.pages} pages, ${paper.incidents.length} incidents (${((Date.now() - started) / 1000).toFixed(1)} s)`);
  }
}

// ---- aggregate -------------------------------------------------------------------------------------------------------
const totalPages = papers.reduce((n, p) => n + p.pages, 0);
const all = papers.flatMap(p => p.incidents);
function summarise(incidents, pageCount, paperCount) {
  const out = {};
  for (const cat of Object.keys(CATEGORIES)) {
    const list = incidents.filter(i => i.cat === cat);
    const weighted = list.reduce((n, i) => n + i.severity, 0);
    const stages = {};
    for (const i of list) stages[i.stage] = (stages[i.stage] ?? 0) + 1;
    const subs = {};
    for (const i of list) if (i.sub) subs[i.sub] = (subs[i.sub] ?? 0) + 1;
    out[cat] = { incidents: list.length, per_paper: round(list.length / Math.max(1, paperCount), 2), per_10_pages: round(list.length * 10 / Math.max(1, pageCount), 2),
      papers: new Set(list.map(i => `${i.label}/${i.paper}`)).size, mean_severity: round(weighted / Math.max(1, list.length)), impact: round(weighted * 10 / Math.max(1, pageCount)),
      words: list.reduce((n, i) => n + (i.words ?? 0), 0), stages, subs };
  }
  return out;
}
const byLabel = Object.fromEntries([...new Set(papers.map(p => p.label))].map(l => { const ps = papers.filter(p => p.label === l); return [l, { papers: ps.length, pages: ps.reduce((n, p) => n + p.pages, 0), categories: summarise(ps.flatMap(p => p.incidents), ps.reduce((n, p) => n + p.pages, 0), ps.length) }]; }));
const categories = summarise(all, totalPages, papers.length);
const stages = Object.fromEntries(STAGES.map(s => { const list = all.filter(i => i.stage === s); return [s, { incidents: list.length, impact: round(list.reduce((n, i) => n + i.severity, 0) * 10 / Math.max(1, totalPages)) }]; }));
const order = Object.keys(CATEGORIES).sort((a, b) => categories[b].impact - categories[a].impact || categories[b].incidents - categories[a].incidents);

// Headline measures (the accuracy harness's, pooled over all runs) and the taxonomy's own.
const mean = f => round(papers.reduce((n, p) => n + f(p), 0) / Math.max(1, papers.length));
const pooled = (kind, key2) => papers.reduce((n, p) => n + (p.metrics.equations[kind][key2] ?? 0), 0);
function headline(ps) {
  const m = f => round(ps.reduce((n, p) => n + f(p), 0) / Math.max(1, ps.length));
  const pool = (kind, key2) => ps.reduce((n, p) => n + (p.metrics.equations[kind][key2] ?? 0), 0);
  const tok = ps.filter(p => p.displayTokenError !== null);
  return { papers: ps.length, pages: ps.reduce((n, p) => n + p.pages, 0), text_f1: m(p => p.metrics.text.f1), shared_f1: m(p => p.metrics.text.shared_f1 ?? 0), whole_blocks: m(p => p.metrics.order.whole_blocks),
    headings_recall: round(ps.reduce((n, p) => n + p.metrics.headings.matched, 0) / Math.max(1, ps.reduce((n, p) => n + p.metrics.headings.truth, 0))),
    headings_precision: round(ps.reduce((n, p) => n + p.metrics.headings.matched, 0) / Math.max(1, ps.reduce((n, p) => n + p.metrics.headings.device, 0))),
    inline_found: round(pool('inline', 'aligned') / Math.max(1, pool('inline', 'truth'))), inline_typeset_precision: round(pool('inline', 'typeset_glyphs_equal') / Math.max(1, pool('inline', 'typeset_aligned'))),
    display_found: round(pool('display', 'aligned') / Math.max(1, pool('display', 'truth'))), display_glyph_right: round(pool('display', 'glyphs_equal') / Math.max(1, pool('display', 'aligned'))),
    display_typeset_share: round(pool('display', 'typeset') / Math.max(1, pool('display', 'device'))), display_typeset_precision: round(pool('display', 'typeset_glyphs_equal') / Math.max(1, pool('display', 'typeset_aligned'))),
    display_token_error: tok.length ? round(tok.reduce((n, p) => n + p.displayTokenError, 0) / tok.length) : null, tables_word_f1: (() => { const t = ps.filter(p => p.metrics.tables.truth > 0); return round(t.reduce((n, p) => n + p.metrics.tables.word_f1, 0) / Math.max(1, t.length)); })() };
}
const headlines = { all: headline(papers), ...Object.fromEntries(Object.keys(byLabel).map(l => [l, headline(papers.filter(p => p.label === l))])) };
const figureIoUMean = figureIoU.length ? round(figureIoU.reduce((a, b) => a + b, 0) / figureIoU.length) : null;

// Timing: busy seconds per stage per page (pages read with per-page timings), and per paper.
const STAGE_KEYS = ['render', 'text', 'ocr', 'layout', 'tag', 'equations', 'images', 'read'];
const perPageRows = papers.flatMap(p => (p.timing.perPage ?? []).slice(0, p.pages).map((row, i) => ({ paper: p.key, label: p.label, page: i + 1, ...row,
  formulas: p.timing.formulasPerPage.all[i] ?? 0, recognised: p.timing.formulasPerPage.recognised[i] ?? 0 })));
const pct = (xs, q) => { if (!xs.length) return null; const s = [...xs].sort((a, b) => a - b); return round(s[Math.min(s.length - 1, Math.floor(q * s.length))]); };
const timing = {
  pages_timed: perPageRows.length,
  stages: Object.fromEntries(STAGE_KEYS.map(s => { const xs = perPageRows.map(r => r[s] ?? 0); return [s, { mean: round(xs.reduce((a, b) => a + b, 0) / Math.max(1, xs.length)), p50: pct(xs, 0.5), p90: pct(xs, 0.9), max: xs.length ? round(Math.max(...xs)) : null }]; })),
  per_paper: papers.map(p => ({ paper: p.key, label: p.label, pages: p.pages, wall: p.timing.wall, preview: p.timing.preview, total: p.timing.host?.total ?? null, finish: p.timing.host?.finish ?? null,
    per_page: p.timing.host?.total ? round(p.timing.host.total / p.pages) : null, recogniser: p.timing.host?.equations ?? null, load: p.timing.load ? round(Object.values(p.timing.load).reduce((a, b) => a + b, 0)) : null })),
  slowest_pages: [...perPageRows].sort((a, b) => (b.read ?? 0) + (b.equations ?? 0) - (a.read ?? 0) - (a.equations ?? 0)).slice(0, 12),
  recogniser_per_crop: (() => { const n = perPageRows.reduce((a, r) => a + r.recognised, 0); return n ? round(perPageRows.reduce((a, r) => a + (r.equations ?? 0), 0) / n) : null; })(),
};
const wallTotal = papers.reduce((n, p) => n + (p.timing.host?.total ?? 0), 0);
timing.seconds_per_page = round(wallTotal / Math.max(1, totalPages));
timing.median_preview = pct(papers.map(p => p.timing.preview).filter(x => x !== null), 0.5);

// ---- examples: the worst incidents per category, with their page crops -----------------------------------------------
const examples = {};
const jobs = [];
const COLORS = { incident: '#d62728', device: '#1f77b4', truth: '#2ca02c' };
const REGION_COLORS = { title: '#9467bd', abstract: '#8c564b', heading: '#e377c2', paragraph: '#7f7f7f', caption: '#bcbd22', footnote: '#17becf', bibitem: '#aec7e8', listing: '#ffbb78', display: '#ff7f0e', table: '#98df8a', figure: '#c5b0d5' };
const cropsDir = join(OUT, 'crops');
if (!flag('--no-crops')) { rmSync(cropsDir, { recursive: true, force: true }); mkdirSync(cropsDir, { recursive: true }); }
const recordCache = new Map();
for (const cat of order) {
  const list = all.filter(i => i.cat === cat && i.stage !== 'truth').sort((a, b) => b.severity - a.severity || (b.words ?? 0) - (a.words ?? 0));
  const picked = [], perPaper = new Map();
  for (const inc of list) {
    if ((perPaper.get(inc.paper) ?? 0) >= 2) continue;
    perPaper.set(inc.paper, (perPaper.get(inc.paper) ?? 0) + 1);
    picked.push(inc);
    if (picked.length >= EXAMPLES) break;
  }
  examples[cat] = picked;
  for (const [n, inc] of picked.entries()) {
    if (!inc.loc || flag('--no-crops')) continue;
    const rkey = `${inc.variant}/${inc.paper}`;
    if (!recordCache.has(rkey)) recordCache.set(rkey, recordOf(join(ACCURACY, inc.variant, inc.paper)));
    const record = recordCache.get(rkey);
    const { width, height } = pageSize(record, inc.loc.page);
    const b = inc.loc.box;
    const w = Math.max(360, b[2] - b[0] + 80), h = Math.max(150, b[3] - b[1] + 60);
    const cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
    const rect = [Math.max(0, cx - w / 2), Math.max(0, cy - h / 2), Math.min(width, cx + w / 2), Math.min(height, Math.min(cy + h / 2, cy - h / 2 + 520))];
    const boxes = regions(record, inc.loc.page).filter(r => area(intersect(r.pt, rect)) > 0).map(r => [...r.pt, REGION_COLORS[r.cls] ?? '#7f7f7f']);
    if (inc.truthBox) boxes.push([...inc.truthBox, COLORS.truth]);
    if (inc.deviceBox) boxes.push([...inc.deviceBox, COLORS.device]);
    boxes.push([b[0] - 2, b[1] - 2, b[2] + 2, b[3] + 2, COLORS.incident]);
    inc.crop = `crops/${cat.replace(/\./g, '-')}-${n + 1}.png`;
    jobs.push({ pdf: inc.pdf, page: inc.loc.page, rect, dpi: 110, out: join(OUT, inc.crop), boxes });
  }
}
if (jobs.length) {
  let tool = arg('--tool');
  if (!tool) {
    const core = join(ROOT, 'apps/apple/ScienceReaderCore');
    execFileSync('swift', ['build', '-c', 'release', '--product', 'DevicePDFRouteTool'], { cwd: core, stdio: ['ignore', 'ignore', 'inherit'] });
    tool = join(core, '.build/release/DevicePDFRouteTool');
  }
  writeFileSync(join(OUT, 'crops.json'), JSON.stringify(jobs));
  const r = spawnSync(tool, ['--render-crops', join(OUT, 'crops.json')], { encoding: 'utf8' });
  console.log((r.stdout || r.stderr || '').trim());
}

// ---- baseline ----------------------------------------------------------------------------------------------------------
const baselineArg = arg('--baseline');
const baseline = baselineArg ? readJSON(baselineArg.endsWith('.json') ? resolve(baselineArg) : join(ROOT, '.artifacts/device-route-weaknesses', baselineArg, 'report.json')) : null;
if (baselineArg && !baseline) { console.error(`no baseline report at ${baselineArg}`); process.exit(2); }

const report = { format: 'device-route-weaknesses-v1', when: new Date().toISOString(), name: NAME, runs, papers: papers.length, pages: totalPages,
  headlines, figure_iou_mean: figureIoUMean, categories, by_label: byLabel, stages, order, timing,
  per_paper: papers.map(p => ({ paper: p.key, label: p.label, template: p.template, pages: p.pages, text_f1: p.metrics.text.f1, impact: round(p.incidents.reduce((n, i) => n + i.severity, 0) * 10 / p.pages),
    top: Object.entries(p.incidents.reduce((m, i) => (m[i.cat] = (m[i.cat] ?? 0) + i.severity, m), {})).sort((a, b) => b[1] - a[1]).slice(0, 3).map(([c, v]) => [c, round(v, 2)]) })),
  examples: Object.fromEntries(Object.entries(examples).map(([c, list]) => [c, list.map(i => ({ ...i, truth: undefined, device: undefined, pdf: undefined }))])) };
writeFileSync(join(OUT, 'report.json'), JSON.stringify(report, null, 1));
writeFileSync(join(OUT, 'incidents.json'), JSON.stringify(all.map(i => ({ ...i, pdf: undefined }))));
writeFileSync(join(OUT, 'index.html'), page(report, examples, baseline));
console.log(`\n${papers.length} papers, ${totalPages} pages, ${all.length} incidents`);
for (const cat of order.slice(0, 12)) { const c = categories[cat]; console.log(`${cat.padEnd(18)} impact ${String(c.impact).padStart(6)}  incidents ${String(c.incidents).padStart(5)}  per 10 pages ${c.per_10_pages}  ${JSON.stringify(c.stages)}`); }
console.log(`report: ${join(OUT, 'index.html')}`);

// ---- the page ---------------------------------------------------------------------------------------------------------
function page(r, ex, base) {
  const delta = (now, then, better = 1) => {
    if (then === undefined || then === null || now === null || now === undefined) return '';
    const d = round(now - then, 3);
    if (!d) return ' <span class="d">±0</span>';
    return ` <span class="d ${d * better > 0 ? 'up' : 'down'}">${d > 0 ? '+' : ''}${d}</span>`;
  };
  const H = r.headlines.all, B = base?.headlines?.all;
  const measure = (label, key2, better = 1) => `<tr><td>${label}</td>${['all', ...Object.keys(r.by_label)].map(l => `<td>${r.headlines[l]?.[key2] ?? ''}${delta(r.headlines[l]?.[key2], base?.headlines?.[l]?.[key2], better)}</td>`).join('')}</tr>`;
  const catRows = r.order.map((cat, n) => {
    const c = r.categories[cat], b = base?.categories?.[cat];
    const stagesTxt = Object.entries(c.stages).sort((a, b2) => b2[1] - a[1]).map(([s, v]) => `${STAGE_TITLES[s] ?? s} ${v}`).join(', ');
    return `<tr><td>${n + 1}</td><td><a href="#${cat}">${esc(CATEGORIES[cat][0])}</a></td><td class="num">${c.impact}${delta(c.impact, b?.impact, -1)}</td><td class="num">${c.incidents}${delta(c.incidents, b?.incidents, -1)}</td><td class="num">${c.per_10_pages}</td><td class="num">${c.papers}/${r.papers}</td><td class="num">${c.mean_severity}</td><td>${esc(stagesTxt)}</td></tr>`;
  }).join('');
  const labelCols = Object.keys(r.by_label);
  const catByLabel = r.order.filter(c => r.categories[c].incidents).map(cat => `<tr><td>${esc(CATEGORIES[cat][0])}</td>${labelCols.map(l => `<td class="num">${r.by_label[l].categories[cat].impact} <small>(${r.by_label[l].categories[cat].per_10_pages})</small></td>`).join('')}</tr>`).join('');
  const stageRows = STAGES.map(s => `<tr><td>${STAGE_TITLES[s]}</td><td class="num">${r.stages[s].impact}${delta(r.stages[s].impact, base?.stages?.[s]?.impact, -1)}</td><td class="num">${r.stages[s].incidents}</td></tr>`).join('');
  const t = r.timing;
  const timingRows = STAGE_KEYS.map(s => `<tr><td>${s}</td><td class="num">${t.stages[s].mean}${delta(t.stages[s].mean, base?.timing?.stages?.[s]?.mean, -1)}</td><td class="num">${t.stages[s].p50}</td><td class="num">${t.stages[s].p90}</td><td class="num">${t.stages[s].max}</td></tr>`).join('');
  const slow = t.slowest_pages.map(p => `<tr><td>${esc(p.label)} ${esc(p.paper)} p.${p.page}</td><td class="num">${round(p.read ?? 0, 2)}</td><td class="num">${round(p.tag ?? 0, 2)}</td><td class="num">${round(p.equations ?? 0, 2)}</td><td class="num">${p.formulas}</td><td class="num">${p.recognised}</td></tr>`).join('');
  const paperRows = [...r.per_paper].sort((a, b) => b.impact - a.impact).map(p => `<tr><td>${esc(p.label)}</td><td>${esc(p.paper)}</td><td>${esc(p.template ?? '')}</td><td class="num">${p.pages}</td><td class="num">${p.text_f1}</td><td class="num">${p.impact}</td><td>${p.top.map(([c, v]) => `${esc(CATEGORIES[c][0])} ${v}`).join('; ')}</td></tr>`).join('');
  const exampleSections = r.order.filter(cat => r.categories[cat].incidents).map(cat => {
    const c = r.categories[cat];
    const subs = Object.entries(c.subs).sort((a, b) => b[1] - a[1]).map(([s, v]) => `${esc(s)} (${v})`).join(' · ');
    const cards = (ex[cat] ?? []).map(i => `<div class="card"><div class="meta"><b>${esc(i.label)} ${esc(i.paper)}</b>${i.loc ? ` · page ${i.loc.page + 1}` : ''} · ${esc(STAGE_TITLES[i.stage])} · severity ${i.severity}${i.sub ? ` · ${esc(i.sub)}` : ''}${i.region ? ` · layout: ${esc(i.region)}` : ''}${i.words ? ` · ${i.words} words` : ''}${i.tokErr !== undefined ? ` · token error ${i.tokErr}` : ''}${i.iou !== undefined ? ` · IoU ${i.iou}, coverage ${i.coverage}` : ''}</div>
      <div class="three"><div><h4>PDF</h4>${i.crop ? `<img loading="lazy" src="${i.crop}" alt="page crop">` : '<p class="none">no location</p>'}</div><div><h4>Device</h4>${i.device ?? '<p class="none">—</p>'}</div><div><h4>HTML truth</h4>${i.truth ?? '<p class="none">—</p>'}</div></div></div>`).join('');
    return `<section id="${cat}"><h3>${esc(CATEGORIES[cat][0])} <small>impact ${c.impact} · ${c.incidents} incidents · ${c.papers} papers</small></h3><p>${esc(CATEGORIES[cat][1])} Severity: ${esc(CATEGORIES[cat][2])}.</p><p class="subs">${subs}</p>${cards || '<p class="none">Only truth/convention incidents.</p>'}</section>`;
  }).join('');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Device route weaknesses</title>
<style>
:root{--link:#0b57d0;--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#d2d2d7;--card:#f5f5f7;--mark:#ffe08a;--up:#1a7f37;--down:#c62828}
@media (prefers-color-scheme:dark){:root{--link:#8ab4f8;--bg:#161618;--fg:#f2f2f2;--muted:#a1a1a6;--line:#3a3a3c;--card:#232326;--mark:#6b5300;--up:#4cc26b;--down:#ff6b6b}}
body{background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif;margin:0 auto;max-width:1400px;padding:16px}
a{color:var(--link)}
table{border-collapse:collapse;margin:8px 0 20px;font-size:13px}td,th{border-bottom:1px solid var(--line);padding:4px 8px;text-align:left;vertical-align:top}.num{text-align:right;font-variant-numeric:tabular-nums}
.d{font-size:11px;color:var(--muted)}.d.up{color:var(--up)}.d.down{color:var(--down)}small{color:var(--muted)}
.card{background:var(--card);border-radius:10px;padding:10px;margin:10px 0}.meta{font-size:12px;color:var(--muted);margin-bottom:6px}
.three{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(0,1fr) minmax(0,1fr);gap:12px}.three img{max-width:100%;border:1px solid var(--line);background:#fff}
@media (max-width:800px){.three{grid-template-columns:1fr}}
h4{margin:0 0 4px;font-size:12px;color:var(--muted)}mark{background:var(--mark);color:inherit}code{font-size:11px;word-break:break-all;display:block;color:var(--muted)}
.math{overflow-x:auto;font-size:16px}.device-block,.table{max-height:360px;overflow:auto;font-size:12px}.device-block img{max-width:100%;height:auto;background:#fff}.subs{font-size:12px;color:var(--muted)}.none{color:var(--muted)}
.legend span{display:inline-block;margin-right:12px}.legend i{display:inline-block;width:10px;height:10px;border:2px solid;margin-right:4px;vertical-align:middle}
.wrap{overflow-x:auto}
</style></head><body>
<h1>On-device PDF route: weaknesses</h1>
<p>${esc(r.name)} · ${esc(r.when)} · ${r.papers} papers, ${r.pages} pages · runs: ${r.runs.map(x => `${esc(x.variant)} (${esc(x.label)})`).join(', ')}${base ? ` · compared with <b>${esc(base.name)}</b> (${esc(base.when)})` : ''}</p>
<p>Impact = severity-weighted incidents per 10 pages; the categories below are sorted by it. Each incident is attributed to the stage that most likely caused it. Crops: the PDF as the route renders it (Core Graphics, font smoothing off); <span class="legend"><span><i style="border-color:#d62728"></i>the incident</span><span><i style="border-color:#1f77b4"></i>device crop or formula box</span><span><i style="border-color:#2ca02c"></i>what the PDF draws (figures)</span><span><i style="border-color:#7f7f7f"></i>layout regions (colour by class)</span></span></p>
<h2>Measures</h2><div class="wrap"><table><tr><th></th>${['all', ...Object.keys(r.by_label)].map(l => `<th>${esc(l)}</th>`).join('')}</tr>
${measure('text F1', 'text_f1')}${measure('shared-content F1', 'shared_f1')}${measure('whole blocks', 'whole_blocks')}${measure('headings recall', 'headings_recall')}${measure('headings precision', 'headings_precision')}${measure('inline found', 'inline_found')}${measure('inline typeset precision', 'inline_typeset_precision')}${measure('display found', 'display_found')}${measure('display glyph-right', 'display_glyph_right')}${measure('display typeset share', 'display_typeset_share')}${measure('display typeset precision', 'display_typeset_precision')}${measure('display token error (lower is better)', 'display_token_error', -1)}${measure('tables word F1', 'tables_word_f1')}
</table></div><p>Figure crops against what the PDF draws: mean IoU ${r.figure_iou_mean ?? '—'}${delta(r.figure_iou_mean, base?.figure_iou_mean)}.</p>
<h2>Categories by impact</h2><div class="wrap"><table><tr><th>#</th><th>Category</th><th>Impact</th><th>Incidents</th><th>per 10 pages</th><th>Papers</th><th>Mean severity</th><th>Stages</th></tr>${catRows}</table></div>
<h2>By stage</h2><table><tr><th>Stage</th><th>Impact</th><th>Incidents</th></tr>${stageRows}</table>
<h2>By corpus</h2><div class="wrap"><table><tr><th>Category</th>${labelCols.map(l => `<th>${esc(l)} impact <small>(per 10 pages)</small></th>`).join('')}</tr>${catByLabel}</table></div>
<h2>Time</h2><p>${t.pages_timed} pages with per-page timings; ${t.seconds_per_page} s a page of conversion (wall, model loading excluded); median reading on screen (preview) ${t.median_preview ?? '—'} s; recogniser ${t.recogniser_per_crop ?? '—'} busy s per recognised formula. Busy seconds per page by stage (stages overlap; <i>read</i> is the converter thread's wall time for the page, tagger and image calls included; <i>equations</i> is the page's share of its recogniser batches):</p>
<table><tr><th>Stage</th><th>Mean</th><th>p50</th><th>p90</th><th>Max</th></tr>${timingRows}</table>
<h3>Slowest pages</h3><table><tr><th>Page</th><th>read</th><th>tag</th><th>recogniser</th><th>formulas</th><th>recognised</th></tr>${slow}</table>
<h2>Papers by impact</h2><div class="wrap"><table><tr><th>Corpus</th><th>Paper</th><th>Template</th><th>Pages</th><th>Text F1</th><th>Impact</th><th>Top categories</th></tr>${paperRows}</table></div>
<h2>Worst examples</h2>${exampleSections}
</body></html>`;
}
