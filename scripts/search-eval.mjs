// Paper search quality, device against DataCite (ARXIV_DEVICE_ONLY.md §5.6, §5.6.1). LOCAL DEVELOPER SCRIPT: run by hand on a
// developer machine, never deployed, never run by a server or the hosted checks; it is not server code (the egress
// scan covers server trees only). Its arXiv requests are the device engine's, made as one device would (paced, cached).
// Runs a fixed set of queries through
//   arxiv     the native device search: arXiv's API, as `paper-search.ts` builds and orders it;
//   datacite  the browser search and the server's discover?q= for older builds: DataCite, as `paper-search.ts` orders it;
// records each engine's top 10 in .artifacts/search-eval/<date>.json with overlap@10 against the device search and the
// expected paper's rank, and writes a side-by-side HTML report. The retired server engine (OpenAlex ranking with arXiv
// metadata) was removed with rollout step 7; its 2026-10-15 results are summarized in §5.6.1. Relevance judgments (relevant / partly / not, for each query's top
// 5) are read from scripts/search-eval-judgments.json (Claude's, 2026-10-15); a paper not judged there counts as not
// relevant, so judge new results after changing the order.
//
// Every response is cached (.artifacts/search-eval/cache), so a rerun reorders offline; `--refresh` fetches again.
// Live requests are paced: arXiv one at a time at least 3.2 s apart, DataCite 1 s.
//   node scripts/search-eval.mjs [--refresh] [--offline] [--only=<query substring>]
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { explainSearch, parseSearchResponse, planSearch, searchRequests, BROAD_BELOW, SearchNotFound } from '../supabase/functions/_shared/paper-search.ts';

const root = fileURLToPath(new URL('../', import.meta.url));
const out = `${root}.artifacts/search-eval`, cacheDir = `${out}/cache`;
mkdirSync(cacheDir, { recursive: true });
const args = process.argv.slice(2);
const refresh = args.includes('--refresh'), offline = args.includes('--offline');
const only = args.find(a => a.startsWith('--only='))?.slice(7);
// `--without-known`: the same answers ordered without rule 6 (no citation counts, no most-cited list), to see what it adds.
const withoutKnown = args.includes('--without-known');
const variant = withoutKnown ? '-without-known' : '';
const UA = 'Gradstep/0.1 (search evaluation, developer machine; +https://gradstep.ai; mailto:hello@gradstep.ai)';

/** kind, the query, and the arXiv IDs a reader would expect near the top (any one counts). */
export const QUERIES = [
  ['topic', 'direct preference optimization', ['2305.18290']],
  ['topic', 'sparse attention long context', []],
  ['topic', 'diffusion model distillation', []],
  ['topic', 'vision transformer', ['2010.11929']],
  ['topic', 'mixture of experts routing', []],
  ['topic', 'retrieval augmented generation', ['2005.11401']],
  ['topic', 'chain of thought prompting', ['2201.11903']],
  ['topic', 'contrastive learning', []],
  ['topic', 'reinforcement learning from human feedback', ['2203.02155', '1706.03741', '2009.01325']],
  ['topic', 'speculative decoding', ['2211.17192', '2302.01318']],
  ['topic', 'state space models', ['2111.00396', '2312.00752']],
  ['topic', 'neural radiance fields', ['2003.08934']],
  ['topic', 'kv cache compression', []],
  ['topic', 'in-context learning', []],
  ['topic', 'test time compute scaling', ['2408.03314']],
  ['topic', 'graph neural networks for molecules', []],
  ['short', 'mamba ssm', ['2312.00752']],
  ['long', 'how to make large language models reason better', []],
  ['long', 'low rank adaptation of large language models', ['2106.09685']],
  ['author', 'Tri Dao', []],
  ['author', 'Percy Liang', []],
  ['author', 'Yann LeCun', []],
  ['title', 'Attention Is All You Need', ['1706.03762']],
  ['title', 'Denoising Diffusion Probabilistic Models', ['2006.11239']],
  ['title', 'Language Models are Few-Shot Learners', ['2005.14165']],
  ['title', 'FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness', ['2205.14135']],
  ['title', 'Scaling Laws for Neural Language Models', ['2001.08361']],
  ['id', '2305.18290', ['2305.18290']],
  ['id', 'https://arxiv.org/abs/1706.03762', ['1706.03762']],
  ['misspelling', 'difusion model distilation', []],
  ['misspelling', 'reinforcment lerning from human feedback', ['2203.02155', '1706.03741', '2009.01325']],
  ['misspelling', 'atention is all you ned', ['1706.03762']],
].map(([kind, q, expect]) => ({ kind, q, expect }));

// --- fetching: cached, paced per host, timed.
const spacing = { arxiv: 3200, datacite: 1000 };
const lastStart = {};
const hostGroup = url => /arxiv\.org$/.test(new URL(url).hostname) ? 'arxiv' : 'datacite';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let liveRequests = 0;
const stopped = {};
async function get(url, headers = {}) {
  const key = createHash('sha256').update(url).digest('hex').slice(0, 32), file = `${cacheDir}/${key}.json`;
  if (!refresh && existsSync(file)) return JSON.parse(readFileSync(file, 'utf8'));
  if (offline) throw new Error(`not cached: ${url}`);
  const group = hostGroup(url);
  if (stopped[group]) throw new Error(`${group} stopped after ${stopped[group]}`);
  const wait = (lastStart[group] ?? 0) + spacing[group] - Date.now();
  if (wait > 0) await sleep(wait);
  lastStart[group] = Date.now();
  const start = performance.now();
  liveRequests++;
  const response = await fetch(url, { headers: { 'user-agent': UA, ...headers }, redirect: 'error', signal: AbortSignal.timeout(30_000) });
  const body = await response.text();
  const record = { url, status: response.status, ms: Math.round(performance.now() - start), body, fetchedAt: new Date().toISOString() };
  // A refusal or a busy answer stops every further request to that host for this run (owner's rule 3).
  if (response.status === 429 || response.status === 503 || response.status === 403) { stopped[group] = response.status; throw new Error(`${group} answered ${response.status}; stopping`); }
  writeFileSync(file, JSON.stringify(record));
  return record;
}

// --- the engines: paper-search.ts, as the device and the browser run it.
async function sharedEngine(engine, query) {
  const plan = planSearch(query);
  if (!plan) return { results: [], requests: 0, latency: 0, explain: [] };
  const { requests, broad } = searchRequests(engine, plan);
  const lists = {}, timings = [];
  const fetchOne = async (request, stage) => {
    const url = request.source === 'datacite' ? `${request.url}${request.url.includes('?') ? '&' : '?'}mailto=hello%40gradstep.ai` : request.url;
    const r = await get(url, { accept: request.source === 'arxiv' ? 'application/atom+xml' : 'application/vnd.api+json' });
    timings.push({ ms: r.ms, source: request.source, stage });
    if (r.status === 404 && request.role === 'id') throw new SearchNotFound();
    if (r.status !== 200) throw new Error(`status ${r.status}`);
    return parseSearchResponse(request.source, r.body);
  };
  for (const request of requests) {
    try { lists[request.role] = await fetchOne(request, 1); }
    catch (error) { lists[request.role] = []; if (!(error instanceof SearchNotFound)) console.warn(`  ${engine} ${request.role} failed: ${error.message}`); }
  }
  if (broad && (lists.relevance?.length ?? 0) < BROAD_BELOW) {
    try { lists.broad = await fetchOne(broad, 2); } catch (error) { console.warn(`  ${engine} broad failed: ${error.message}`); }
  }
  if (withoutKnown) { delete lists.cited; for (const role of Object.keys(lists)) lists[role] = lists[role].map(({ citations: _, ...r }) => r); }
  const ranked = explainSearch(plan, lists, 25);
  // Time to results: the first requests run together, except that arXiv request starts are 3 s apart; the broad request
  // follows them.
  const first = timings.filter(t => t.stage === 1), arxiv = first.filter(t => t.source === 'arxiv');
  const arxivChain = arxiv.reduce((sum, t, i) => sum + (i < arxiv.length - 1 ? Math.max(t.ms, 3000) : t.ms), 0);
  const latency = Math.max(arxivChain, ...first.filter(t => t.source !== 'arxiv').map(t => t.ms), 0) + timings.filter(t => t.stage === 2).reduce((sum, t) => sum + t.ms, 0);
  return { results: ranked.map(r => r.result), requests: timings.length, latency,
    explain: ranked.slice(0, 10).map(r => ({ id: r.result.source_id, score: Number(r.score.toFixed(4)), factors: r.factors })),
    raw: Object.fromEntries(Object.entries(lists).map(([role, list]) => [role, list.slice(0, 10).map(r => r.source_id)])) };
}

const top = list => list.slice(0, 10).map(r => ({ id: r.source_id, title: r.title, year: r.year, authors: r.authors.slice(0, 3), categories: r.categories.slice(0, 3) }));
const judgmentsFile = `${root}scripts/search-eval-judgments.json`;
const judgments = existsSync(judgmentsFile) ? JSON.parse(readFileSync(judgmentsFile, 'utf8')) : {};
const SCORE = { r: 1, p: 0.5, n: 0 };

const date = new Date().toISOString().slice(0, 10);
const rows = [];
for (const item of QUERIES.filter(q => !only || q.q.includes(only))) {
  console.log(`${item.kind.padEnd(11)} ${item.q}`);
  const engines = {};
  for (const [name, run] of [['arxiv', () => sharedEngine('arxiv', item.q)], ['datacite', () => sharedEngine('datacite', item.q)]]) {
    try { const r = await run(); engines[name] = { top: top(r.results), count: r.results.length, requests: r.requests, latency_ms: r.latency, explain: r.explain, raw: r.raw }; }
    catch (error) { engines[name] = { top: [], count: 0, requests: 0, latency_ms: null, error: String(error.message ?? error) }; console.warn(`  ${name}: ${error.message}`); }
  }
  const reference = new Set(engines.arxiv.top.map(p => p.id));
  for (const [name, engine] of Object.entries(engines)) {
    const ids = engine.top.map(p => p.id);
    engine.overlap10 = name === 'arxiv' ? null : ids.filter(id => reference.has(id)).length;
    const at = ids.findIndex(id => item.expect.includes(id));
    engine.expected_rank = item.expect.length ? (at >= 0 ? at + 1 : null) : undefined;
    const judged = engine.top.slice(0, 5).map(p => judgments[item.q]?.[p.id]);
    engine.judged5 = judged.filter(Boolean).length;
    // Over the papers shown (up to 5): an ID lookup's single right answer is a full score; no results score 0.
    const shown = engine.top.slice(0, 5);
    engine.relevance5 = shown.length ? shown.reduce((sum, p) => sum + (SCORE[judgments[item.q]?.[p.id]] ?? 0), 0) / shown.length : 0;
    engine.relevant_in_top3 = engine.top.slice(0, 3).some(p => judgments[item.q]?.[p.id] === 'r');
  }
  rows.push({ ...item, engines });
}

const names = ['arxiv', 'datacite'];
const mean = values => values.length ? values.reduce((a, b) => a + b, 0) / values.length : null;
const summary = Object.fromEntries(names.map(name => {
  const list = rows.map(r => r.engines[name]);
  const expected = rows.filter(r => r.expect.length);
  return [name, {
    queries: list.length,
    empty: list.filter(e => !e.top.length).length,
    mean_overlap10: name === 'arxiv' ? null : Number(mean(list.map(e => e.overlap10 ?? 0)).toFixed(2)),
    expected_found_top10: `${expected.filter(r => r.engines[name].expected_rank).length}/${expected.length}`,
    expected_first: `${expected.filter(r => r.engines[name].expected_rank === 1).length}/${expected.length}`,
    mean_relevance_at5: Number(mean(list.map(e => e.relevance5)).toFixed(3)),
    relevant_in_top3: `${list.filter(e => e.relevant_in_top3).length}/${list.length}`,
    fully_judged: `${list.filter(e => e.judged5 === Math.min(5, e.top.length)).length}/${list.length}`,
    median_latency_ms: (() => { const v = list.map(e => e.latency_ms).filter(x => x !== null).sort((a, b) => a - b); return v.length ? v[Math.floor(v.length / 2)] : null; })(),
    mean_requests: Number(mean(list.map(e => e.requests)).toFixed(2)),
    relevance_by_kind: Object.fromEntries([...new Set(rows.map(r => r.kind))].map(kind =>
      [kind, Number(mean(rows.filter(r => r.kind === kind).map(r => r.engines[name].relevance5)).toFixed(2))])),
  }];
}));
writeFileSync(`${out}/${date}${variant}.json`, JSON.stringify({ date, live_requests: liveRequests, summary, queries: rows }, null, 1) + '\n');

// --- the side-by-side report.
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const badge = j => j ? `<span class="j ${j}">${{ r: 'relevant', p: 'partly', n: 'not' }[j]}</span>` : '';
const cell = (row, name) => {
  const e = row.engines[name], reference = new Set(row.engines.arxiv.top.map(p => p.id));
  if (e.error) return `<td class="err">${esc(e.error)}</td>`;
  const items = e.top.map((p, i) => `<li class="${row.expect.includes(p.id) ? 'hit' : ''}"><span class="rk">${i + 1}</span> <a href="https://arxiv.org/abs/${esc(p.id)}">${esc(p.title)}</a>
    <span class="meta">${esc(p.id)} · ${esc(p.year ?? '')}${name !== 'arxiv' && reference.has(p.id) ? ' · <b class="same">in the device top 10</b>' : ''}${row.expect.includes(p.id) ? ' · <b class="exp">expected</b>' : ''}</span>
    ${i < 5 ? badge(judgments[row.q]?.[p.id]) : ''}</li>`).join('');
  const facts = [name !== 'arxiv' ? `overlap ${e.overlap10}/10` : null, e.expected_rank !== undefined ? `expected at ${e.expected_rank ?? '—'}` : null,
    `rel@5 ${e.relevance5.toFixed(2)}`, `${e.requests} req`, e.latency_ms !== null ? `≈${(e.latency_ms / 1000).toFixed(1)} s` : null].filter(Boolean).join(' · ');
  return `<td><div class="facts">${facts}</div><ol>${items || '<li class="none">No results</li>'}</ol></td>`;
};
const label = { arxiv: 'arXiv API (native device)', datacite: 'DataCite (browser; server for older builds)' };
const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Search evaluation ${date}</title><style>
:root{--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--hit:#e8f5e9;--r:#1b7f3b;--p:#9a6700;--n:#b42318}
@media (prefers-color-scheme:dark){:root{--bg:#141416;--fg:#f2f2f7;--muted:#a1a1a6;--line:#2c2c2e;--hit:#16301d;--r:#5fd38a;--p:#e3b341;--n:#ff8a80}}
body{margin:0;padding:24px 16px;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif}
h1{font-size:20px}table{border-collapse:collapse;width:100%}th,td{border-top:1px solid var(--line);padding:8px;vertical-align:top;text-align:left}
td{width:30%}td.q{width:10%;font-weight:600}.kind{display:block;color:var(--muted);font-weight:400;font-size:12px}ol{margin:4px 0;padding-left:0;list-style:none}
li{margin:0 0 6px}li.hit{background:var(--hit)}.rk{color:var(--muted);display:inline-block;width:1.6em}.meta{display:block;color:var(--muted);font-size:12px;padding-left:1.6em}
.facts{color:var(--muted);font-size:12px;margin-bottom:4px}.same{font-weight:600}.exp{color:var(--r)}.j{font-size:11px;margin-left:1.6em}.j.r{color:var(--r)}.j.p{color:var(--p)}.j.n{color:var(--n)}
a{color:inherit}.summary td,.summary th{width:auto}.wrap{overflow-x:auto}
</style></head><body><h1>Paper search, device and DataCite side by side, ${date}</h1>
<p>Top 10 per engine. Green rows are the paper a reader would expect; “in the device top 10” marks overlap with the native search. Judgments cover each engine's top 5.</p>
<div class="wrap"><table class="summary"><tr><th>Engine</th>${Object.keys(summary.arxiv).map(k => `<th>${esc(k.replaceAll('_', ' '))}</th>`).join('')}</tr>
${names.map(n => `<tr><td>${esc(label[n])}</td>${Object.values(summary[n]).map(v => `<td>${esc(v && typeof v === 'object'
  ? Object.entries(v).map(([k, x]) => `${k} ${Number(x).toFixed(2)}`).join(' · ') : v ?? '—')}</td>`).join('')}</tr>`).join('')}</table></div>
<div class="wrap"><table><tr><th>Query</th>${names.map(n => `<th>${esc(label[n])}</th>`).join('')}</tr>
${rows.map(row => `<tr><td class="q">${esc(row.q)}<span class="kind">${esc(row.kind)}</span></td>${names.map(n => cell(row, n)).join('')}</tr>`).join('\n')}
</table></div></body></html>\n`;
writeFileSync(`${out}/${date}${variant}.html`, html);
console.log(JSON.stringify(summary, null, 1));
console.log(`live requests: ${liveRequests}; wrote ${out}/${date}${variant}.json and .html`);
