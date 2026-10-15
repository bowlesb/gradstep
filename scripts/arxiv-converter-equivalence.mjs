#!/usr/bin/env node
// Behaviour-preserving changes to the arXiv converter (docs/proposals/READER_ARCHITECTURE_RETHINK.md, step 2) are
// proven here: the converter at a git revision (default HEAD) and the working tree compile every cached arXiv HTML
// source on this machine, and every output is compared byte for byte: the asset plan (arxivHTMLAssets), the inline
// pictures (arxivInlineImages), the compiled HTML, the index, the image URLs, the uncovered-math diagnostics and any
// refusal code. Each source runs with the catalog title and authors the sweep recorded for it (when known) and without.
//
//   node scripts/arxiv-converter-equivalence.mjs [--rev=HEAD] [--only=<substring>] [--verbose] [--ignore-ids]
//
// `--ignore-ids`: block and equation ids hash ARXIV_RENDERER_REVISION, so after a bump every id differs; this compares
// with the 12-character digest in `b-…-n` and `e-…-n` masked, to prove the ids are the only difference.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const arg = (name, fallback) => process.argv.find(a => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const REV = arg('rev', 'HEAD'), ONLY = arg('only', ''), VERBOSE = process.argv.includes('--verbose'), IGNORE_IDS = process.argv.includes('--ignore-ids');

// The reference: the shared tree at REV, extracted inside the repository so its imports find node_modules.
const ref = join(ROOT, '.artifacts/converter-equivalence', REV.replace(/[^\w.-]/g, '_'));
rmSync(ref, { recursive: true, force: true }); mkdirSync(ref, { recursive: true });
execFileSync('/bin/sh', ['-c', `git -C "${ROOT}" archive "${REV}" supabase/functions/_shared | tar -x -C "${ref}"`]);
const load = base => import(pathToFileURL(join(base, 'supabase/functions/_shared/reader/arxiv-html.ts')).href);
const before = await load(ref), after = await load(ROOT);

// Every cached source, with what is known about its paper.
const meta = new Map();
const reports = join(ROOT, '.artifacts/reader-sweep');
if (existsSync(reports)) for (const f of readdirSync(reports).filter(f => /^sweep-.*\.json$/.test(f)).sort()) {
  try { for (const r of JSON.parse(readFileSync(join(reports, f), 'utf8')).results ?? []) if (r.meta) meta.set(r.key, r.meta); } catch { /* a partial report */ }
}
for (const set of ['reader', 'owner-20261014']) {
  const p = join(ROOT, 'tests/corpus', `${set}.json`);
  if (existsSync(p)) for (const paper of JSON.parse(readFileSync(p, 'utf8')).papers ?? []) {
    const key = `${paper.id}v${paper.revision}`; if (!meta.has(key)) meta.set(key, { revision: paper.revision, title: paper.title, authors: [] });
  }
}
const sources = [];
const add = (path, key) => { if (existsSync(path) && statSync(path).isFile()) sources.push({ path, key }); };
const keyOf = name => /^(\d{4}\.\d{4,5}v\d+)/.exec(name)?.[1];
const sweepSources = join(ROOT, '.artifacts/reader-sweep/sources');
if (existsSync(sweepSources)) for (const f of readdirSync(sweepSources).filter(f => f.endsWith('.html')).sort()) add(join(sweepSources, f), f.replace(/\.html$/, ''));
const corpus = join(ROOT, '.artifacts/reader-corpus');
if (existsSync(corpus)) for (const d of readdirSync(corpus).sort()) add(join(corpus, d, 'source.html'), keyOf(d) ?? d);
const older = join(ROOT, '.artifacts/arxiv-html');
if (existsSync(older)) for (const f of readdirSync(older).sort()) {
  const p = join(older, f);
  if (statSync(p).isDirectory()) add(join(p, 'source.html'), `${f}v1`);
  else if (f.endsWith('-html.html')) add(p, `${f.replace(/-html\.html$/, '')}v1`);
}
for (const f of ['source.html', 'figures.html']) add(join(ROOT, 'tests/fixtures/reader-arxiv', f), '2601.01234v2');

const sha = s => createHash('sha256').update(s).digest('hex');
// A deterministic admission: the path and size follow from the URL alone.
const stub = url => { const h = sha(url); return { path: `assets/${h}.png`, width: 16 + parseInt(h.slice(0, 4), 16) % 1500, height: 16 + parseInt(h.slice(4, 8), 16) % 1500 }; };
const outcome = (fn) => { try { return { ok: fn() }; } catch (e) { return { error: e?.message ?? String(e) }; } };
const run = (converter, source, url, options) => {
  const uncovered = [];
  const opts = options ? { ...options, onUncoveredMath: list => uncovered.push(list.length, ...list.slice(0, 5).map(m => {
    const chain = []; for (let p = m.parent; p && chain.length < 6; p = p.parent) chain.push(`${p.name}.${p.attribs?.class ?? ''}`); return chain.join('<');
  })) } : { onUncoveredMath: list => uncovered.push(list.length) };
  const assets = outcome(() => converter.arxivHTMLAssets(source, url, options ?? {}));
  const inline = outcome(() => [...converter.arxivInlineImages(source, url, options ?? {})].map(([k, v]) => [k, sha(v)]));
  const compiled = outcome(() => { const r = converter.convertArxivHTML(source, url, stub, opts); return { html: r.html, index: JSON.stringify(r.index), imageURLs: r.imageURLs }; });
  const out = JSON.stringify({ assets, inline, compiled, uncovered });
  return IGNORE_IDS ? out.replace(/\b([be])-[0-9a-f]{12}-(\d+)/g, '$1-#-$2') : out;
};

let total = 0, same = 0, refusals = 0;
const differences = [];
for (const { path, key } of sources) {
  if (ONLY && !path.includes(ONLY) && !key.includes(ONLY)) continue;
  const source = readFileSync(path, 'utf8');
  const m = /^(.+)v(\d+)$/.exec(key);
  let url; try { url = after.arxivHTMLURL(m[1], Number(m[2])); } catch { url = 'https://arxiv.org/html/2601.01234v1'; }
  const known = meta.get(key);
  const variants = [null, ...(known ? [{ title: known.title, authors: known.authors ?? [] }] : [])];
  for (const options of variants) {
    total += 1;
    const a = run(before, source, url, options), b = run(after, source, url, options);
    if (a === b) { same += 1; if (JSON.parse(a).compiled.error) refusals += 1; }
    else differences.push({ path: path.replace(ROOT + '/', ''), options: !!options, a, b });
    if (VERBOSE) console.log(`${a === b ? 'same' : 'DIFF'} ${path.replace(ROOT + '/', '')}${options ? ' (catalog)' : ''}`);
  }
}
for (const d of differences.slice(0, 10)) {
  const a = JSON.parse(d.a), b = JSON.parse(d.b);
  const field = ['assets', 'inline', 'compiled', 'uncovered'].find(f => JSON.stringify(a[f]) !== JSON.stringify(b[f]));
  let detail = '';
  if (field === 'compiled' && a.compiled.ok && b.compiled.ok) {
    for (const part of ['html', 'index', 'imageURLs']) {
      const x = JSON.stringify(a.compiled.ok[part]), y = JSON.stringify(b.compiled.ok[part]);
      if (x !== y) { let i = 0; while (i < x.length && x[i] === y[i]) i += 1; detail = `${part} at ${i}: …${x.slice(Math.max(0, i - 80), i + 120)}… vs …${y.slice(Math.max(0, i - 80), i + 120)}…`; break; }
    }
  } else detail = `${JSON.stringify(a[field]).slice(0, 200)} vs ${JSON.stringify(b[field]).slice(0, 200)}`;
  console.log(`DIFF ${d.path}${d.options ? ' (catalog)' : ''} in ${field}: ${detail}`);
}
console.log(`${sources.length} sources, ${total} runs against ${REV}: ${same} identical, ${total - same} different (${refusals} identical refusals)`);
process.exit(same === total ? 0 : 1);
