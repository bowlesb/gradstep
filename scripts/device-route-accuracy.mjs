#!/usr/bin/env node
// The on-device PDF route against the arXiv HTML reading of the same paper (docs/architecture/DEVICE_PDF_ROUTE.md,
// docs/reviews/DEVICE_PDF_ROUTE_20261021.md). Ground truth is this app's own arXiv HTML reader (convertArxivHTML) on
// the exact revision; the candidate is the device route's bundle from the Mac tool on that revision's PDF. Slow and
// opt-in (docs/TESTING.md): it fetches from arXiv on this Mac (paced like the app, cached), never from a server.
//
//   node scripts/device-route-accuracy.mjs fetch --ids 2610.15542v1,… | --recent N [--cats cs.LG,…] [--corpus <dir>]
//   node scripts/device-route-accuracy.mjs run   --variant <name> [--corpus <dir>] [--only id,…] [--tool <binary>] [--skip-done] [-- <tool flags>]
//   node scripts/device-route-accuracy.mjs score --variant <name> [--corpus <dir>] [--only id,…] [--json out.json]
//
// --pdf <file> (run): the PDF in each paper's directory to read (default paper.pdf; the venue corpus also keeps the
// arXiv revision's own PDF as arxiv.pdf, the control). A venue paper's key is not an arXiv id: its meta.json names the
// arXiv revision whose HTML is the truth (`arxiv_id`, `revision`) and its `template` (acl, cvf, pmlr, …); scores are
// then also given per template.
//
// The corpus holds <key>/paper.pdf, <key>/source.html and <key>/meta.json; runs land in
// .artifacts/device-route/accuracy/<variant>/<key>/ (bundle members, conversion.json with the stage timings).
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const argv = process.argv.slice(2);
const command = argv[0];
const passthrough = argv.includes('--') ? argv.slice(argv.indexOf('--') + 1) : [];
const own = argv.includes('--') ? argv.slice(0, argv.indexOf('--')) : argv;
const arg = (name, fallback) => { const i = own.indexOf(name); return i > 0 ? own[i + 1] : fallback; };
const CORPUS = resolve(arg('--corpus', join(homedir(), 'gradstep-mac/device-route-corpus')));
const VARIANT = arg('--variant', 'baseline');
const OUT = join(ROOT, '.artifacts/device-route/accuracy', VARIANT);
const only = (arg('--only', '') ?? '').split(',').filter(Boolean);
const UA = 'Gradstep device-route evaluation (research paper reader; +https://gradstep.ai; mailto:hello@gradstep.ai)';
const sleep = ms => new Promise(r => setTimeout(r, ms));
const keys = () => readdirSync(CORPUS).filter(k => existsSync(join(CORPUS, k, 'paper.pdf')) && existsSync(join(CORPUS, k, 'source.html')))
  .filter(k => !only.length || only.includes(k) || only.includes(k.replace(/v\d+$/, ''))).sort();

// ---- fetch ---------------------------------------------------------------------------------------------------------
async function fetchCorpus() {
  mkdirSync(CORPUS, { recursive: true });
  const { arxivHTMLURL } = await import(`${ROOT}/supabase/functions/_shared/reader/arxiv-html.ts`);
  const decode = s => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
  const norm = s => decode(String(s ?? '')).replace(/\s+/g, ' ').trim();
  const atom = async query => {
    const r = await fetch(`https://export.arxiv.org/api/query?${query}`, { headers: { 'user-agent': UA }, signal: AbortSignal.timeout(60_000) });
    if (!r.ok) throw new Error(`arXiv API ${r.status}`);
    const xml = await r.text();
    return xml.split('<entry>').slice(1).map(entry => {
      const m = /<id>http:\/\/arxiv\.org\/abs\/([^<]+?)v(\d+)<\/id>/.exec(entry);
      return m && { id: m[1], revision: Number(m[2]), title: norm(/<title>([\s\S]*?)<\/title>/.exec(entry)?.[1]),
        authors: [...entry.matchAll(/<author>\s*<name>([\s\S]*?)<\/name>/g)].map(x => norm(x[1])),
        categories: [...entry.matchAll(/<category term="([^"]+)"/g)].map(x => x[1]) };
    }).filter(Boolean);
  };
  let papers = [];
  const ids = (arg('--ids', '') ?? '').split(',').filter(Boolean);
  if (ids.length) {
    papers = await atom(`id_list=${ids.join(',')}&max_results=${ids.length}`);
    for (const given of ids) { const m = /^(.+?)v(\d+)$/.exec(given); const p = m && papers.find(x => x.id === m[1]); if (p) p.revision = Number(m[2]); }
  }
  const recent = Number(arg('--recent', '0'));
  if (recent > 0) {
    const cats = arg('--cats', 'cs.LG,cs.CL,cs.CV,stat.ML,math.OC,quant-ph,hep-th,cond-mat.stat-mech').split(',');
    const per = Math.ceil(recent / cats.length);
    for (const cat of cats) { papers.push(...await atom(`search_query=cat:${cat}&sortBy=submittedDate&sortOrder=descending&start=${Number(arg('--start', '0'))}&max_results=${per}`)); await sleep(3000); }
  }
  const seen = new Set(); papers = papers.filter(p => !seen.has(p.id) && seen.add(p.id));
  let last = 0;
  const paced = async url => {
    const wait = 3000 - (Date.now() - last); if (wait > 0) await sleep(wait); last = Date.now();
    const r = await fetch(url, { headers: { 'user-agent': UA }, signal: AbortSignal.timeout(120_000) });
    return r.ok ? Buffer.from(await r.arrayBuffer()) : null;
  };
  for (const p of papers) {
    const key = `${p.id}v${p.revision}`, dir = join(CORPUS, key);
    mkdirSync(dir, { recursive: true });
    if (!existsSync(join(dir, 'source.html'))) {
      const html = await paced(arxivHTMLURL(p.id, p.revision));
      if (!html || !/ltx_document|ltx_page_main/.test(html.toString('utf8', 0, 200_000))) { console.log(`${key}: no HTML`); writeFileSync(join(dir, 'meta.json'), JSON.stringify({ ...p, html: false })); continue; }
      writeFileSync(join(dir, 'source.html'), html);
    }
    if (!existsSync(join(dir, 'paper.pdf'))) {
      const pdf = await paced(`https://arxiv.org/pdf/${key}`);
      if (!pdf || pdf.subarray(0, 5).toString() !== '%PDF-') { console.log(`${key}: no PDF`); continue; }
      writeFileSync(join(dir, 'paper.pdf'), pdf);
    }
    writeFileSync(join(dir, 'meta.json'), JSON.stringify({ ...p, html: true }, null, 1));
    console.log(`${key}: ${p.title.slice(0, 70)}`);
  }
}

// ---- run -----------------------------------------------------------------------------------------------------------
function runRoute() {
  // --tool <binary>: a DevicePDFRouteTool built elsewhere (the baseline's sources), instead of building this checkout's.
  let tool = arg('--tool');
  if (!tool) {
    const core = join(ROOT, 'apps/apple/ScienceReaderCore');
    execFileSync('swift', ['build', '-c', 'release', '--product', 'DevicePDFRouteTool'], { cwd: core, stdio: ['ignore', 'ignore', 'inherit'] });
    tool = join(core, '.build/release/DevicePDFRouteTool');
  }
  const models = resolve(ROOT, arg('--models', 'apps/apple/DeviceModels'));
  const compiler = resolve(ROOT, arg('--compiler', 'apps/apple/ScienceReader/Resources/device-pdf-reader.js'));
  mkdirSync(OUT, { recursive: true });
  for (const key of keys()) {
    const out = join(OUT, key);
    if (own.includes('--skip-done') && existsSync(join(out, 'wall.json'))) continue;
    const meta = JSON.parse(readFileSync(join(CORPUS, key, 'meta.json'), 'utf8'));
    const started = Date.now();
    const run = spawnSync(tool, [join(CORPUS, key, arg('--pdf', 'paper.pdf')), out, '--models', models, '--compiler', compiler, '--title', meta.title ?? key, ...passthrough.map(a => a.replaceAll('{out}', out).replaceAll('{authors}', (meta.authors ?? []).join(';')))],
      { encoding: 'utf8', maxBuffer: 256 << 20, env: { ...process.env, ...(process.env.DEVICE_ROUTE_ENV ? JSON.parse(process.env.DEVICE_ROUTE_ENV) : {}) } });
    const seconds = (Date.now() - started) / 1000;
    writeFileSync(out + '.log', (run.stdout ?? '') + (run.stderr ?? ''));
    if (run.status !== 0) { console.log(`${key}\tFAILED ${seconds.toFixed(1)} s\t${(run.stderr || '').trim().split('\n').slice(-2).join(' | ')}`); continue; }
    const summary = JSON.parse(readFileSync(join(out, 'conversion.json'), 'utf8'));
    writeFileSync(join(out, 'wall.json'), JSON.stringify({ seconds }));
    const h = summary.host_seconds ?? {};
    console.log(`${key}\t${summary.pages} pages\t${seconds.toFixed(1)} s wall\t` + Object.entries(h).map(([k, v]) => `${k} ${v}`).join(' '));
  }
}

// ---- score ---------------------------------------------------------------------------------------------------------
const { parseHTML } = await import(`${ROOT}/supabase/functions/_shared/reader/html.ts`);
let temml = null;
const MATH_LEAVES = new Set(['mi', 'mn', 'mo', 'mtext', 'ms']);
/** Glyph content of a formula: its MathML leaves, NFKC-folded (math italic 𝑥 → x), without spacing or invisible operators. */
function leafText(node) {
  const out = [];
  const visit = n => {
    if (n.type === 'tag' && n.name === 'annotation') return;
    if (n.type === 'tag' && MATH_LEAVES.has(n.name)) { out.push(n.children.map(c => c.type === 'text' ? c.data : '').join('')); return; }
    for (const c of n.children ?? []) visit(c);
  };
  visit(node);
  return foldLeaves(out.join(''));
}
const foldLeaves = s => s.normalize('NFKC').replace(/[\u0305\u00af\u203e]/g, '\u0304').replace(/[\s⁡-⁤​︎️]/g, '').replace(/∥/g, '‖').replace(/[−–]/g, '-').replace(/[′’]/g, "'").replace(/[∣]/g, '|').replace(/[⋅·]/g, '⋅');
const { tidyLatex } = await import(`${ROOT}/supabase/functions/_shared/reader/device-pdf/math.ts`);
/** The glyphs a recognition would show (as read, else tidied as the converter tidies it); '' when Temml refuses both. */
function texLeaves(latex, display) {
  if (!latex) return '';
  for (const tex of [latex, tidyLatex(latex)]) {
    try { return leafText(parseHTML(temml.renderToString(tex, { displayMode: display, throwOnError: true, xml: true, trust: false }), true)); }
    catch { /* the tidied form next */ }
  }
  return '';
}
// LaTeX normalisation: the desktop's scorer (gradstep/eval/equations.py `normalize`), ported.
function normalizeTeX(tex) {
  let t = String(tex ?? '').trim();
  for (const [a, b] of [['\\[', '\\]'], ['$$', '$$'], ['\\(', '\\)'], ['$', '$']]) if (t.startsWith(a) && t.endsWith(b) && t.length >= a.length + b.length) { t = t.slice(a.length, t.length - b.length).trim(); break; }
  t = t.replace(/\\(?:displaystyle|textstyle|scriptstyle|scriptscriptstyle|nonumber|notag|allowbreak|limits|nolimits|label\{[^}]*\})(?![a-zA-Z])/g, '');
  t = t.replace(/\\[,;:!> ]|\\(?:quad|qquad|thinspace|medspace|thickspace|negthinspace|enspace)(?![a-zA-Z])|~|\\(?:hskip|kern|mskip|mkern)\s*-?[0-9.]+\s*(?:pt|em|ex|mu|cm|mm|in|bp)\b|\\hspace\*?\{[^{}]*\}/g, '');
  t = t.replace(/\\(?:left|right|big|Big|bigg|Bigg|bigl|bigr|Bigl|Bigr|biggl|biggr|Biggl|Biggr)(?![a-zA-Z])/g, '');
  t = t.replace(/\\mbox\{\\boldmath\$([^$]*)\$\}/g, '\\bm{$1}');
  t = t.replace(/(?<![A-Za-z])\{\\(cal|bf|it|rm|sf|tt)\s+([^{}]*)\}/g, (_, f, body) => (f === 'cal' ? '\\mathcal{' : f === 'bf' ? '\\bm{' : '\\mathrm{') + body + '}');
  t = t.replace(/\\(?:operatorname\*?|text|textrm|textit|textbf|textsf|texttt|textnormal|mathrm|mathit|mathsf|mathtt|mathnormal|mbox|hbox)\s*\{/g, '\\mathrm{');
  t = t.replace(/\\(?:boldsymbol|pmb|mathbf|bm)\s*\{/g, '\\bm{');
  t = t.replace(/\\(?:it|rm|bf|sf|tt|em)\s+/g, '');
  t = t.replace(/\\(?:lVert|rVert|Vert)(?![A-Za-z])/g, '\\|').replace(/\\(?:lvert|rvert|vert)(?![A-Za-z])/g, '|').replace(/\\mid(?![A-Za-z])/g, '|');
  t = t.replace(/,\\dots(?![A-Za-z])/g, ',\\ldots');
  t = t.replace(/\^(\{[^{}]*\}|[A-Za-z0-9])_(\{[^{}]*\}|[A-Za-z0-9])/g, '_$2^$1');
  t = t.replace(/\\operatorname\*?\{arg\\[,;: ]?(min|max)\}|\\arg\\(min|max)|\\arg(min|max)(?![A-Za-z])/g, (_, a, b, c) => '\\mathrm{arg' + (a || b || c) + '}');
  t = t.replace(/\\(?:begin|end)\{(?:split|aligned|gathered|multlined)\}/g, '').replaceAll('&', '');
  t = t.replace(/\s+/g, '');
  for (let prev = null; prev !== t;) { prev = t; t = t.replace(/\{([A-Za-z0-9()[\]|])\}/g, '$1'); }
  return t.replace(/[.,;]+$/, '');
}
function editDistance(a, b) {
  if (a === b) return 0; if (!a.length || !b.length) return Math.max(a.length, b.length);
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) cur.push(Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)));
    prev = cur;
  }
  return prev[b.length];
}

/** Myers' O((N+M)D) diff over integer sequences: the matched index pairs (a longest common subsequence). */
export function lcsPairs(a, b, maxD = 12000) {
  const n = a.length, m = b.length, max = Math.min(n + m, maxD), offset = max + 1;
  const v = new Int32Array(2 * max + 3), trace = [];
  let found = -1;
  for (let d = 0; d <= max && found < 0; d++) {
    trace.push(v.slice(offset - d - 1, offset + d + 2));
    for (let k = -d; k <= d; k += 2) {
      let x = (k === -d || (k !== d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) { x++; y++; }
      v[offset + k] = x;
      if (x >= n && y >= m) { found = d; break; }
    }
  }
  if (found < 0) return null; // too different to align within maxD
  const pairs = [];
  let x = n, y = m;
  for (let d = found; d > 0; d--) {
    const t = trace[d], at = k => t[k + d + 1];
    const k = x - y;
    const prevK = (k === -d || (k !== d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1;
    const prevX = at(prevK), prevY = prevX - prevK;
    while (x > prevX && y > prevY) { x--; y--; pairs.push([x, y]); }
    x = prevX; y = prevY;
  }
  while (x > 0 && y > 0) { x--; y--; pairs.push([x, y]); }
  return pairs.reverse();
}

const WORD = /[\p{L}]+/gu;
/** A bundle's page as blocks of tokens in reading order: words (letters only, lower case) and formulas. */
export function readBundle(html, { device = false } = {}) {
  const root = parseHTML(html);
  const blocks = [];
  const visitBlock = (node) => {
    const tokens = [];
    const visit = n => {
      if (n.type === 'text') { for (const w of n.data.normalize("NFC").toLowerCase().match(WORD) ?? []) tokens.push({ w }); return; }
      if (n.type !== 'tag') return;
      if (n.attribs['data-reader-equation'] !== undefined) {
        const cls = (n.attribs.class ?? '').split(/\s+/);
        const display = cls.includes('reader-display') || (!cls.includes('reader-inline') && n.parent?.attribs?.['data-reader-kind'] === 'equation');
        const math = n.children.find(c => c.type === 'tag' && c.name === 'math');
        const shown = math ? 'typeset' : cls.includes('reader-math-image') ? 'image' : 'text';
        tokens.push({ f: true, id: n.attribs.id, display, latex: n.attribs['data-latex'] ?? '', shown, leaves: math ? leafText(math) : null });
        return;
      }
      if (n.name === 'img' || (n.attribs.class ?? '').includes('reader-tag')) return;
      for (const c of n.children) visit(c);
    };
    for (const c of node.children) visit(c);
    return tokens;
  };
  const walk = n => {
    if (n.type !== 'tag' && n.type !== 'root') { return; }
    if (n.type === 'tag' && n.attribs['data-reader-block']) {
      let tokens = visitBlock(n);
      const kind = n.attribs['data-reader-kind'] ?? n.name;
      // arXiv's HTML adds back-references and link labels to each bibliography entry ("Cited by: …", "External
      // Links: …") that the PDF does not print: the truth's entries end before them.
      if (!device && kind === 'list') {
        const cut = tokens.findIndex((t, i) => (t.w === 'cited' && tokens[i + 1]?.w === 'by') || (t.w === 'external' && tokens[i + 1]?.w === 'links'));
        if (cut >= 0) tokens = tokens.slice(0, cut);
      }
      blocks.push({ id: n.attribs['data-reader-block'], kind, tag: n.name, tokens });
      return;
    }
    for (const c of n.children ?? []) walk(c);
  };
  walk(root);
  // Display formulas carry their placement from their block when the class does not say. The HTML reader writes an
  // aligned group's rows (or cells) as separate formulas in one block; the device reads the group as one: consecutive
  // display formulas of a block are one formula on both sides (rows joined by \\, glyphs concatenated).
  for (const b of blocks) {
    for (const t of b.tokens) if (t.f && b.kind === 'equation') t.display = true;
    const merged = [];
    for (const t of b.tokens) {
      const last = merged[merged.length - 1];
      if (t.f && t.display && last?.f && last.display) {
        merged[merged.length - 1] = { ...last, latex: `${last.latex} \\\\ ${t.latex}`, parts: [...(last.parts ?? [last]), t],
          shown: last.shown === t.shown ? last.shown : 'image', leaves: last.leaves !== null && t.leaves !== null ? last.leaves + t.leaves : null };
      } else merged.push(t);
    }
    b.tokens = merged;
  }
  return blocks;
}

const normTitle = t => t.toLowerCase().replace(/[^a-z]+/g, '').replace(/^appendix/, '');
const runIn = t => { t = t.trim(); return /[:.]$/.test(t) && t.split(/\s+/).length <= 6 && !/^([Aa]ppendix\s+)?(\d+(\.\d+)*|[A-Z](\.\d+)*)\.?\s/.test(t); };
const headingText = b => b.tokens.filter(t => t.w).map(t => t.w).join(' ');

/** One paper: the device bundle's page against the HTML reader's page. */
export function compare(truthBlocks, deviceBlocks) {
  const dict = new Map(); const id = s => { let v = dict.get(s); if (v === undefined) { v = dict.size + 1; dict.set(s, v); } return v; };
  // A number set in math mode ($48$, $85\%$) reads the same as text: it is not counted as a formula on either side.
  const numeric = t => t.f && !t.display && /^[0-9.,%\-+−\s]*$/.test(t.leaves ?? (t.parts ? 'x' : texLeaves(t.latex, false) || 'x'));
  const flat = blocks => blocks.flatMap((b, bi) => b.tokens.filter(t => !numeric(t)).map(t => ({ ...t, block: bi })));
  const T = flat(truthBlocks), D = flat(deviceBlocks);
  // Words alone: the text fidelity (order-sensitive alignment, and the order-free bag).
  const tw = T.filter(t => t.w), dw = D.filter(t => t.w);
  const wordPairs = lcsPairs(tw.map(t => id(t.w)), dw.map(t => id(t.w))) ?? [];
  const bag = new Map(); for (const t of tw) bag.set(t.w, (bag.get(t.w) ?? 0) + 1);
  let bagHits = 0; for (const t of dw) { const c = bag.get(t.w) ?? 0; if (c > 0) { bagHits++; bag.set(t.w, c - 1); } }
  const text = { truth_words: tw.length, device_words: dw.length, matched_in_order: wordPairs.length,
    recall: round(wordPairs.length / Math.max(1, tw.length)), precision: round(wordPairs.length / Math.max(1, dw.length)),
    f1: round(2 * wordPairs.length / Math.max(1, tw.length + dw.length)),
    bag_recall: round(bagHits / Math.max(1, tw.length)), bag_precision: round(bagHits / Math.max(1, dw.length)) };
  // Reading order: each substantial truth block's best device block (word LCS ratio), then the pairs kept in order.
  const blockWords = bs => bs.map(b => b.tokens.filter(t => t.w).map(t => id(t.w)));
  const tbw = blockWords(truthBlocks), dbw = blockWords(deviceBlocks);
  const dsets = dbw.map(ws => new Set(ws));
  const matches = [];
  tbw.forEach((ws, ti) => {
    if (ws.length < 6 || truthBlocks[ti].kind === 'figure') return;
    const set = new Set(ws);
    const candidates = dsets.map((s, di) => { let n = 0; for (const w of set) if (s.has(w)) n++; return [n / set.size, di]; })
      .filter(([j]) => j >= 0.3).sort((a, b) => b[0] - a[0]).slice(0, 4);
    let best = null;
    for (const [, di] of candidates) {
      const pairs = lcsPairs(ws, dbw[di], 4000)?.length ?? 0;
      const covered = pairs / ws.length;
      if (!best || covered > best.covered) best = { ti, di, covered, ratio: 2 * pairs / (ws.length + dbw[di].length) };
    }
    if (best && best.covered >= 0.5) matches.push(best);
  });
  const substantial = tbw.filter((ws, ti) => ws.length >= 6 && truthBlocks[ti].kind !== 'figure').length;
  // Text within shared content: the words of the truth's blocks that were found and of the device blocks that hold
  // them, in order. A venue PDF and the arXiv revision can differ by whole sections (a checklist, a supplement, a new
  // version); this measure leaves those out and keeps what the reading did to the text both have.
  const tKept = [...new Set(matches.map(m => m.ti))].sort((a, b) => a - b), dKept = [...new Set(matches.map(m => m.di))].sort((a, b) => a - b);
  const tShared = tKept.flatMap(i => tbw[i]), dShared = dKept.flatMap(i => dbw[i]);
  text.shared_f1 = round(2 * (lcsPairs(tShared, dShared)?.length ?? 0) / Math.max(1, tShared.length + dShared.length));
  // Order leaves the bibliography's entries out: LaTeXML may regenerate a bibliography in its own (alphabetical) order
  // where the PDF prints citation order (REVTeX, 2610.25953v1), so their order in the truth is not the paper's.
  const ordered = matches.filter(m => truthBlocks[m.ti].kind !== 'list');
  let concordant = 0, pairsN = 0, adjacentOK = 0;
  for (let i = 0; i < ordered.length; i++) {
    if (i + 1 < ordered.length) adjacentOK += ordered[i + 1].di >= ordered[i].di ? 1 : 0;
    for (let j = i + 1; j < ordered.length; j++) { pairsN++; if (ordered[j].di >= ordered[i].di) concordant++; }
  }
  const order = { truth_blocks: substantial, found: matches.length, block_recall: round(matches.length / Math.max(1, substantial)),
    whole_blocks: round(matches.filter(m => m.ratio >= 0.8).length / Math.max(1, substantial)),
    // Not whole: the device block holds this one and more (merged with a neighbour), or only part of it (split).
    merged: matches.filter(m => m.ratio < 0.8 && m.covered >= 0.8).length, split: matches.filter(m => m.covered < 0.8).length,
    by_kind: matches.reduce((acc, m) => { const k = truthBlocks[m.ti].kind, c = m.ratio >= 0.8 ? 'whole' : m.covered >= 0.8 ? 'merged' : 'split';
      acc[k] ??= { whole: 0, merged: 0, split: 0 }; acc[k][c]++; return acc; }, {}),
    adjacent_in_order: round(adjacentOK / Math.max(1, ordered.length - 1)), pairs_in_order: round(concordant / Math.max(1, pairsN)) };
  // Headings (the desktop's comparison: letters only; run-in paragraph titles and the HTML reader's h5/h6 theorem and proof
  // labels left out of the truth).
  // A \paragraph{…} title is set run-in in the PDF ("Baselines. We compare …") and the HTML reader makes it a heading:
  // a truth heading that opens a device paragraph is run-in, not missed.
  const paragraphStarts = deviceBlocks.filter(b => b.kind === 'paragraph').map(b => b.tokens.filter(t => t.w).slice(0, 12).map(t => t.w).join(''));
  const opensParagraph = t => { const n = t.replace(/[^a-z]/g, ''); return n.length > 0 && paragraphStarts.some(s => s.startsWith(n)); };
  const th = new Set(truthBlocks.filter(b => b.kind === 'heading' && /^h[1-4]$/.test(b.tag)).map(headingText).filter(t => t && !runIn(t) && !opensParagraph(t)).map(normTitle));
  // Device headings as a list: a title or "Abstract" made twice is a heading too many.
  const dh = deviceBlocks.filter(b => b.kind === 'heading').map(headingText).map(normTitle).filter(Boolean);
  const headHits = new Set(dh.filter(h => th.has(h))).size;
  const headings = { truth: th.size, device: dh.length, matched: headHits, recall: round(headHits / Math.max(1, th.size)), precision: round(headHits / Math.max(1, dh.length)) };
  // Formulas: each truth formula is paired within the stretch of the device's page between the words matched just before
  // and just after it (the word alignment above), with the device formula of the same placement whose glyphs are
  // nearest; then each pair's LaTeX (normalised) and glyph content (MathML leaves) are compared.
  const leafCache = new Map();
  const leaves = t => { if (!leafCache.has(t)) leafCache.set(t, (t.parts ?? [t]).map(x => x.leaves ?? texLeaves(x.latex, x.display)).join('')); return leafCache.get(t); };
  const tWordAt = [], dWordAt = [];
  T.forEach((t, i) => { if (t.w) tWordAt.push(i); });
  D.forEach((t, i) => { if (t.w) dWordAt.push(i); });
  const anchor = new Map(wordPairs.map(([a, b]) => [tWordAt[a], dWordAt[b]])); // truth token index -> device token index
  const anchoredT = [...anchor.keys()].sort((a, b) => a - b);
  const used = new Set(), allPairs = [], unpaired = [];
  let k = 0;
  for (let i = 0; i < T.length; i++) {
    if (!T[i].f) continue;
    while (k < anchoredT.length && anchoredT[k] < i) k++;
    const lo = k > 0 ? anchor.get(anchoredT[k - 1]) : -1, hi = k < anchoredT.length ? anchor.get(anchoredT[k]) : D.length;
    let best = -1, bestCost = Infinity;
    for (let j = lo + 1; j < hi; j++) {
      const c = D[j];
      if (!c.f || used.has(j) || c.display !== T[i].display) continue;
      const a = leaves(T[i]), b = leaves(c);
      const cost = Math.min(1, editDistance(a, b) / Math.max(1, a.length, b.length));
      if (cost < bestCost) { bestCost = cost; best = j; }
    }
    if (best >= 0) { used.add(best); allPairs.push([i, best]); }
    else if (unpaired.length < 200) unpaired.push({ display: T[i].display, kind: truthBlocks[T[i].block].kind, truth: T[i].latex.slice(0, 120) });
  }
  const eq = {};
  for (const kind of ['inline', 'display']) eq[kind] = { truth: 0, device: 0, aligned: 0, latex_equal: 0, glyphs_equal: 0, cer_sum: 0,
    typeset: 0, typeset_glyphs_equal: 0, image: 0, text: 0 };
  for (const t of T) if (t.f) eq[t.display ? 'display' : 'inline'].truth++;
  for (const t of D) if (t.f) { const e = eq[t.display ? 'display' : 'inline']; e.device++; e[t.shown]++; }
  const misses = [], pairRecords = [];
  for (const [i, j] of allPairs) {
    const a = T[i], b = D[j];
    if (!a.f) continue;
    const e = eq[a.display ? 'display' : 'inline'];
    e.aligned++;
    const aLeaves = leaves(a), bLeaves = leaves(b);
    const glyphs = !!aLeaves && aLeaves === bLeaves;
    e.latex_equal += normalizeTeX(a.latex) === normalizeTeX(b.latex) ? 1 : 0;
    e.glyphs_equal += glyphs ? 1 : 0;
    e.cer_sum += Math.min(1, editDistance(aLeaves, bLeaves) / Math.max(1, aLeaves.length));
    if (b.shown === 'typeset') { e.typeset_aligned = (e.typeset_aligned ?? 0) + 1; e.typeset_glyphs_equal += glyphs ? 1 : 0; }
    if (!glyphs) misses.push({ display: a.display, shown: b.shown, truth: a.latex.slice(0, 160), device: b.latex.slice(0, 160), truth_glyphs: aLeaves.slice(0, 400), device_glyphs: bLeaves.slice(0, 400) });
    if (b.id) pairRecords.push([b.id, a.display ? 1 : 0, glyphs ? 1 : 0, b.shown]);
  }
  for (const e of Object.values(eq)) {
    e.recall = round(e.aligned / Math.max(1, e.truth));
    e.glyph_accuracy = round(e.glyphs_equal / Math.max(1, e.aligned));
    e.cer = round(e.cer_sum / Math.max(1, e.aligned)); delete e.cer_sum;
    e.typeset_share = round(e.typeset / Math.max(1, e.device));
    e.typeset_precision = round(e.typeset_glyphs_equal / Math.max(1, e.typeset_aligned ?? 0));
  }
  // Tables and figures: counts, and the words inside tables.
  const tables = { truth: truthBlocks.filter(b => b.kind === 'table').length,
    device_cells: deviceBlocks.filter(b => b.kind === 'table' && b.tag !== 'figure').length,
    device_images: deviceBlocks.filter(b => b.kind === 'table' && b.tag === 'figure').length };
  const tableWords = bs => bs.filter(b => b.kind === 'table').flatMap(b => b.tokens.filter(t => t.w).map(t => id(t.w)));
  const ttw = tableWords(truthBlocks), dtw = tableWords(deviceBlocks);
  tables.word_f1 = round(2 * (lcsPairs(ttw, dtw)?.length ?? 0) / Math.max(1, ttw.length + dtw.length));
  const figures = { truth: truthBlocks.filter(b => b.kind === 'figure').length, device: deviceBlocks.filter(b => b.kind === 'figure').length };
  return { text, order, headings, equations: eq, tables, figures, misses, unpaired, pairs: pairRecords };
}
const round = v => Math.round(v * 1000) / 1000;

async function score() {
  temml = (await import('temml')).default;
  const { convertArxivHTML, arxivHTMLURL } = await import(`${ROOT}/supabase/functions/_shared/reader/arxiv-html.ts`);
  const stub = () => ({ path: `assets/${'0'.repeat(64)}.png`, width: 10, height: 10 });
  const rows = [];
  for (const key of keys()) {
    const dir = join(OUT, key);
    if (!existsSync(join(dir, 'index.html'))) continue;
    const meta = JSON.parse(readFileSync(join(CORPUS, key, 'meta.json'), 'utf8'));
    const [, sid, rev] = meta.arxiv_id ? [null, meta.arxiv_id, meta.revision] : /^(.+?)v(\d+)$/.exec(key);
    let truth;
    try { truth = convertArxivHTML(readFileSync(join(CORPUS, key, 'source.html'), 'utf8'), arxivHTMLURL(sid, Number(rev)), stub, { title: meta.title, authors: meta.authors }); }
    catch (e) { console.log(`${key}: the HTML reader refuses this paper (${e.message}); not scored`); continue; }
    const result = compare(readBundle(truth.html), readBundle(readFileSync(join(dir, 'index.html'), 'utf8'), { device: true }));
    const summary = JSON.parse(readFileSync(join(dir, 'conversion.json'), 'utf8'));
    const wall = existsSync(join(dir, 'wall.json')) ? JSON.parse(readFileSync(join(dir, 'wall.json'), 'utf8')).seconds : null;
    const preview = existsSync(dir + '.preview.json') ? JSON.parse(readFileSync(dir + '.preview.json', 'utf8')).seconds : null;
    rows.push({ key, template: meta.template ?? null, pages: summary.pages, wall, preview, host: summary.host_seconds, load: summary.model_load_seconds, ...result });
  }
  const aggregateOf = rows => {
    const sum = (f) => rows.reduce((n, r) => n + f(r), 0);
    const mean = f => round(sum(f) / Math.max(1, rows.length));
    const total = {};
    for (const kind of ['inline', 'display']) {
      const g = k => sum(r => r.equations[kind][k] ?? 0);
      total[kind] = { truth: g('truth'), device: g('device'), aligned: g('aligned'), recall: round(g('aligned') / Math.max(1, g('truth'))),
        latex_equal: round(g('latex_equal') / Math.max(1, g('aligned'))), glyph_accuracy: round(g('glyphs_equal') / Math.max(1, g('aligned'))),
        typeset_share: round(g('typeset') / Math.max(1, g('device'))), typeset_precision: round(g('typeset_glyphs_equal') / Math.max(1, g('typeset_aligned'))),
        images: g('image'), text: g('text') };
    }
    const pages = sum(r => r.pages);
    const stage = k => round(sum(r => r.host?.[k] ?? 0));
    return { variant: VARIANT, papers: rows.length, pages,
      seconds: { total: stage('total'), per_page: round(stage('total') / Math.max(1, pages)), render: stage('render'), layout: stage('layout'), text: stage('text'),
        tag: stage('tag'), equations: stage('equations'), images: stage('images'), converter: stage('converter') },
      text_f1: mean(r => r.text.f1), shared_f1: mean(r => r.text.shared_f1 ?? 0), text_recall: mean(r => r.text.recall), text_precision: mean(r => r.text.precision), bag_recall: mean(r => r.text.bag_recall),
      block_recall: mean(r => r.order.block_recall), whole_blocks: mean(r => r.order.whole_blocks), adjacent_in_order: mean(r => r.order.adjacent_in_order),
      pairs_in_order: mean(r => r.order.pairs_in_order), headings_recall: round(sum(r => r.headings.matched) / Math.max(1, sum(r => r.headings.truth))),
      headings_precision: round(sum(r => r.headings.matched) / Math.max(1, sum(r => r.headings.device))),
      equations: total, tables: { truth: sum(r => r.tables.truth), cells: sum(r => r.tables.device_cells), images: sum(r => r.tables.device_images), word_f1: mean(r => r.tables.word_f1) },
      figures: { truth: sum(r => r.figures.truth), device: sum(r => r.figures.device) } };
  };
  const aggregate = aggregateOf(rows);
  const templates = [...new Set(rows.map(r => r.template).filter(Boolean))].sort();
  if (templates.length) aggregate.by_template = Object.fromEntries(templates.map(t => [t, aggregateOf(rows.filter(r => r.template === t))]));
  const fmt = v => v === undefined || v === null ? '' : typeof v === 'number' ? (Number.isInteger(v) ? String(v) : v.toFixed(3)) : String(v);
  console.log(['paper', 'pages', 's', 's/page', 'text F1', 'bag rec', 'blocks', 'order', 'heads', 'inl rec', 'inl glyph', 'inl typeset', 'inl prec', 'disp rec', 'disp glyph', 'disp typeset', 'disp prec', 'tables', 'figs'].join('\t'));
  for (const r of rows) {
    const i = r.equations.inline, d = r.equations.display;
    console.log([r.key, r.pages, fmt(r.host?.total), fmt((r.host?.total ?? 0) / r.pages), fmt(r.text.f1), fmt(r.text.bag_recall), fmt(r.order.block_recall), fmt(r.order.pairs_in_order),
      `${r.headings.matched}/${r.headings.truth}`, fmt(i.recall), fmt(i.glyph_accuracy), fmt(i.typeset_share), fmt(i.typeset_precision), fmt(d.recall), fmt(d.glyph_accuracy),
      fmt(d.typeset_share), fmt(d.typeset_precision), `${r.tables.device_cells}+${r.tables.device_images}/${r.tables.truth}`, `${r.figures.device}/${r.figures.truth}`].join('\t'));
  }
  console.log(JSON.stringify(aggregate, null, 1));
  const path = arg('--json', join(OUT, 'accuracy.json'));
  writeFileSync(path, JSON.stringify({ when: new Date().toISOString(), aggregate, rows }, null, 1));
}

if (command === 'fetch') await fetchCorpus();
else if (command === 'run') runRoute();
else if (command === 'score') await score();
else if (import.meta.url === `file://${process.argv[1]}`) { console.error('usage: device-route-accuracy.mjs fetch|run|score …'); process.exit(2); }
