#!/usr/bin/env node
// Reader sweep: compile fresh real arXiv papers with the device compiler and check the header and structure
// invariants the owner has hit (docs/TESTING.md "Slow, reader sweep"; owner, 2026-10-15: "the first paper I opened
// … literally my first interaction with the app failed"). No browser, no account, no server: the exact HTML the
// device would fetch (paced like the app), the exact compiler the apps ship, and the index they would read.
//
//   node scripts/reader-sweep.mjs --recent=25 [--cats=cs.LG,cs.CL,cs.CV,cs.AI]   newest listings in those categories
//   node scripts/reader-sweep.mjs --ids=2610.18356,2305.18290v3                 named papers (latest revision unless given)
//   node scripts/reader-sweep.mjs --from-staging=40                             the papers in the staging library (read-only SQL)
//
// Sources are cached under .artifacts/reader-sweep/sources/; a JSON report lands in .artifacts/reader-sweep/. Exit 1
// when any check fails. Reproduce one paper with `node .artifacts/back-repro/blocks-check.mjs <id> <rev>` or by
// reading the report's `blocks` excerpt.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const arg = (name, fallback) => { const hit = process.argv.find(a => a === `--${name}` || a.startsWith(`--${name}=`)); return hit ? (hit.includes('=') ? hit.slice(name.length + 3) : 'true') : fallback; };
const RECENT = Number(arg('recent', '0')), CATS = arg('cats', 'cs.LG,cs.CL,cs.CV,cs.AI').split(',').filter(Boolean);
const IDS = arg('ids', '').split(',').map(s => s.trim()).filter(Boolean), STAGING = Number(arg('from-staging', '0'));
const UA = 'Gradstep reader sweep (research paper reader; mailto:ben.bowles@gmail.com)';
const DIR = join(ROOT, '.artifacts/reader-sweep'), SOURCES = join(DIR, 'sources');
mkdirSync(SOURCES, { recursive: true });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const { convertArxivHTML, arxivHTMLURL } = await import(`${ROOT}/supabase/functions/_shared/reader/arxiv-html.ts`);
const stub = () => ({ path: `assets/${'0'.repeat(64)}.png`, width: 10, height: 10 });

// ---- paper lists --------------------------------------------------------------------------------------------------
const decode = s => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
const norm = s => decode(String(s ?? '')).replace(/\s+/g, ' ').trim();
function parseAtom(xml) {
  const out = [];
  for (const entry of xml.split('<entry>').slice(1)) {
    const id = /<id>http:\/\/arxiv\.org\/abs\/([^<]+)<\/id>/.exec(entry)?.[1];
    const m = /^(.+?)v(\d+)$/.exec(id ?? '');
    if (!m) continue;
    const title = norm(/<title>([\s\S]*?)<\/title>/.exec(entry)?.[1]);
    const summary = norm(/<summary>([\s\S]*?)<\/summary>/.exec(entry)?.[1]);
    const authors = [...entry.matchAll(/<author>\s*<name>([\s\S]*?)<\/name>/g)].map(x => norm(x[1]));
    out.push({ id: m[1], revision: Number(m[2]), title, summary, authors });
  }
  return out;
}
async function atom(query) {
  for (let attempt = 0; ; attempt++) {
    const r = await fetch(`https://export.arxiv.org/api/query?${query}`, { headers: { 'user-agent': UA }, signal: AbortSignal.timeout(60_000) });
    if (r.ok) return parseAtom(await r.text());
    if ((r.status === 429 || r.status >= 500) && attempt < 3) { const wait = Number(r.headers.get('retry-after')) || 15; console.log(`arXiv API ${r.status}; waiting ${wait} s`); await sleep(wait * 1000); continue; }
    throw new Error(`arXiv API ${r.status}`);
  }
}
const REPLAY = arg('replay', '');
let papers = [];
if (REPLAY) {
  // The same papers as an earlier report (their metadata travels in the report), from the cached sources: no API calls.
  const earlier = JSON.parse(readFileSync(REPLAY, 'utf8'));
  papers.push(...earlier.results.filter(r => r.meta).map(r => ({ id: r.key.replace(/v\d+$/, ''), revision: r.meta.revision, title: r.meta.title, summary: r.meta.summary, authors: r.meta.authors })));
}
if (RECENT > 0) {
  const per = Math.ceil(RECENT / CATS.length);
  for (const cat of CATS) {
    papers.push(...await atom(`search_query=cat:${cat}&sortBy=submittedDate&sortOrder=descending&max_results=${per}`));
    await sleep(3000);
  }
}
if (IDS.length) {
  papers.push(...await atom(`id_list=${IDS.join(',')}&max_results=${IDS.length}`));
  for (const given of IDS) { const m = /^(.+?)v(\d+)$/.exec(given); if (m) { const p = papers.find(x => x.id === m[1]); if (p) p.revision = Number(m[2]); } }
}
if (STAGING > 0) {
  const token = execFileSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w']).toString().trim();
  const query = `select source_id, max(source_revision) revision from app_private.catalog_metadata where source_id ~ '^[0-9]{4}\\.[0-9]{4,5}$' group by source_id order by max(id::text) desc limit ${STAGING}`;
  const r = await fetch('https://api.supabase.com/v1/projects/coxhjvqpflgxkleydati/database/query', { method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify({ query, read_only: true }) });
  const rows = await r.json();
  if (!Array.isArray(rows)) throw new Error(`staging query: ${JSON.stringify(rows).slice(0, 200)}`);
  const ids = rows.map(x => `${x.source_id}v${x.revision}`);
  for (let i = 0; i < ids.length; i += 20) { papers.push(...await atom(`id_list=${ids.slice(i, i + 20).join(',')}&max_results=20`)); await sleep(3000); }
}
const seen = new Set(); papers = papers.filter(p => !seen.has(p.id) && seen.add(p.id));
if (!papers.length) { console.error('no papers: pass --recent=N, --ids=…, --from-staging=N or --replay=<report.json>'); process.exit(2); }
console.log(`${papers.length} papers`);

// ---- checks -------------------------------------------------------------------------------------------------------
const fold = s => norm(s).toLowerCase().replace(/[^\p{L}\p{N} ]+/gu, ' ').replace(/\s+/g, ' ').trim();
const family = name => { const words = norm(name).split(' ').filter(Boolean); return (words[words.length - 1] ?? '').toLowerCase(); };
const DATE = /^(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.? \d{1,2},? \d{4}|\d{1,2} (?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.? \d{4}|\d{4}-\d{2}-\d{2})$/i;
function checks(paper, out, html) {
  const f = [];
  const fail = (check, detail) => f.push({ check, severity: 'fail', detail });
  const warn = (check, detail) => f.push({ check, severity: 'warn', detail });
  const info = (check, detail) => f.push({ check, severity: 'info', detail });
  const blocks = out.index.blocks;
  const titleIndex = blocks.findIndex(b => b.kind === 'heading' && new RegExp(`<h1[^>]*id="${b.id}"`).test(html));
  if (titleIndex !== 0) fail('title_first', titleIndex < 0 ? 'no h1 title block' : `${titleIndex} block(s) before the title: ${JSON.stringify(blocks[0].text.slice(0, 80))}`);
  const title = blocks[titleIndex >= 0 ? titleIndex : 0];
  if (fold(title.text) !== fold(paper.title) && !fold(title.text).includes(fold(paper.title).slice(0, 40))) warn('title_matches', `reader "${title.text.slice(0, 60)}" vs arXiv "${paper.title.slice(0, 60)}"`);
  const authorsBlock = blocks[titleIndex + 1];
  const authorsHTML = /<p class="reader-authors"[^>]*>(.*?)<\/p>/s.exec(html)?.[1] ?? null;
  if (!authorsBlock || !authorsHTML || !new RegExp(`class="reader-authors" data-reader-block="${authorsBlock.id}"`).test(html)) {
    if (paper.authors.length) warn('authors_block', `no author block right after the title (next block: ${JSON.stringify((authorsBlock?.text ?? '').slice(0, 60))})`);
  } else {
    const text = authorsBlock.text;
    if (paper.authors[0] && !fold(text).includes(family(paper.authors[0]))) warn('authors_first', `first author "${paper.authors[0]}" not in "${text.slice(0, 80)}"`);
    if (/footnotemark|affiliation:|thanks:|\S+@\S+\.\S+/i.test(text)) fail('authors_clean', `markup leaked: ${JSON.stringify(text.slice(0, 120))}`);
    if (/<sup><\/sup>|<sup>[,\s]*<\/sup>/.test(authorsHTML)) fail('authors_marks', 'an empty mark');
    if (/(^|\s)[\[\]{}()|]+(\s|$)/.test(text.replace(/·/g, ' '))) fail('authors_punctuation', `stray punctuation: ${JSON.stringify(text.slice(0, 120))}`);
    if (text.length > 2500) warn('authors_length', `${text.length} characters`);
    if (paper.authors.length <= 3 && paper.authors.length) {
      const missing = paper.authors.filter(a => !fold(text).includes(family(a)));
      if (missing.length) warn('authors_all', `missing ${missing.join(', ')}`);
    }
  }
  if (paper.summary) {
    const head = fold(paper.summary).slice(0, 40);
    const at = blocks.findIndex(b => fold(b.text).includes(head));
    if (at < 0) warn('abstract_present', 'the arXiv summary\'s opening is in no block');
    else if (at < titleIndex) fail('abstract_position', `abstract at block ${at}, before the title`);
    else if (at > titleIndex + 6) warn('abstract_position', `abstract at block ${at}`);
    else if (!(blocks[at - 1]?.kind === 'heading' && /abstract/i.test(blocks[at - 1].text))) info('abstract_heading', 'abstract paragraph without an "Abstract" heading before it');
  }
  for (const b of blocks.slice(0, 8)) {
    if (b.kind === 'paragraph' && DATE.test(norm(b.text))) fail('date_only', `a date-only paragraph: ${b.text}`);
    if (b.kind === 'paragraph' && /^[\[\]{}()|,.;:\s]+$/.test(b.text)) fail('punctuation_only', `block ${b.id}: ${JSON.stringify(b.text)}`);
  }
  if (out.index.headings.length < 3) warn('headings', `${out.index.headings.length} headings (Contents)`);
  // A LaTeX command in running text (outside equations, which the index text writes as LaTeX by design).
  const prose = html.replace(/<span class="reader-equation[\s\S]*?<\/span><\/span>|<span class="reader-equation[^>]*>[\s\S]*?<\/math><\/span>|<pre[\s\S]*?<\/pre>|<[^>]+>/g, ' ');
  const leaked = [...prose.matchAll(/(^|\s)(\\[A-Za-z]{3,})\b/g)].map(m => m[2]).slice(0, 5);
  if (leaked.length) warn('macro_leak', [...new Set(leaked)].join(' '));
  const note = /left out (\d+) unsupported command/.exec(html);
  if (note && Number(note[1]) > 50) warn('dropped_commands', `${note[1]} unsupported commands`);
  else if (note) info('dropped_commands', `${note[1]} unsupported commands`);
  if (/<figure/.test(html) === false && out.index.figures.length === 0 && /class="ltx_figure"/.test(paper.source ?? '')) warn('figures', 'source has figures, reader has none');
  return f;
}

// ---- run ----------------------------------------------------------------------------------------------------------
const results = []; let lastFetch = 0;
for (const paper of papers) {
  const key = `${paper.id}v${paper.revision}`, path = join(SOURCES, `${key}.html`);
  let source = existsSync(path) ? readFileSync(path, 'utf8') : null, status = 'cached';
  if (!source) {
    const wait = 3000 - (Date.now() - lastFetch); if (wait > 0) await sleep(wait);
    lastFetch = Date.now();
    try {
      const r = await fetch(arxivHTMLURL(paper.id, paper.revision), { headers: { 'user-agent': UA }, signal: AbortSignal.timeout(90_000) });
      status = String(r.status);
      if (r.status === 200) { source = await r.text(); if (source.length <= 8_388_608) writeFileSync(path, source); }
    } catch (e) { status = e.name; }
  }
  const row = { key, title: paper.title, authors: paper.authors.length, status, findings: [], blocks: [], meta: { revision: paper.revision, title: paper.title, authors: paper.authors, summary: paper.summary } };
  if (!source) { row.findings.push({ check: 'html', severity: 'unavailable', detail: `no HTML (${status}); the app offers the PDF` }); results.push(row); continue; }
  if (Buffer.byteLength(source) > 8_388_608) { row.findings.push({ check: 'limit', severity: 'fail', detail: `${Buffer.byteLength(source)} bytes of HTML, over the device source limit` }); results.push(row); continue; }
  try {
    const out = convertArxivHTML(source, arxivHTMLURL(paper.id, paper.revision), stub, { authors: paper.authors, title: paper.title });
    row.blocks = out.index.blocks.slice(0, 5).map(b => `${b.kind}: ${b.text.slice(0, 70)}`);
    row.findings = checks({ ...paper, source }, out, out.html);
  } catch (e) {
    row.findings.push({ check: 'compile', severity: /^arxiv_article$/.test(e.message) ? 'unavailable' : 'fail', detail: e.message });
  }
  results.push(row);
  const worst = row.findings.some(x => x.severity === 'fail') ? 'FAIL' : row.findings.some(x => x.severity === 'warn') ? 'warn' : row.findings.some(x => x.severity === 'unavailable') ? 'n/a ' : 'ok  ';
  console.log(`${worst} ${key.padEnd(14)} ${paper.title.slice(0, 60)}${row.findings.length ? '\n     ' + row.findings.map(x => `${x.severity}:${x.check} ${x.detail}`).join('\n     ') : ''}`);
}
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const report = join(DIR, `sweep-${stamp}.json`);
writeFileSync(report, JSON.stringify({ at: new Date().toISOString(), args: process.argv.slice(2), results }, null, 1));
const fails = results.filter(r => r.findings.some(x => x.severity === 'fail')).length, warns = results.filter(r => r.findings.some(x => x.severity === 'warn')).length;
const unavailable = results.filter(r => r.findings.some(x => x.severity === 'unavailable')).length;
console.log(`\n${results.length} papers: ${fails} fail, ${warns} warn, ${unavailable} without HTML. Report ${report}`);
process.exit(fails ? 1 : 0);
