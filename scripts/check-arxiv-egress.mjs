#!/usr/bin/env node
// "No server request to arXiv" (docs/architecture/ARXIV_DEVICE_ONLY.md §6.5): a static scan of everything that runs on
// our servers for arXiv host names. A line may name an arXiv host without being a request when it says why with a
// marker: `egress-ok: link` (a link shown to people), `parse` (recognizing input or checking a host), `namespace` (an
// XML namespace name), `prompt` (words for a model), `tavily-filter` (a search provider's domain filter) or `device`
// (code that runs only on readers' devices). SQL that builds links is allowed unless its statement calls pg_net/http.
//
//   node scripts/check-arxiv-egress.mjs            report: list today's call sites; fail only on a site not in the baseline
//   node scripts/check-arxiv-egress.mjs --block    block: fail on any call site (after the cutover, step 6)
//   node scripts/check-arxiv-egress.mjs --json     machine-readable findings
//   node scripts/check-arxiv-egress.mjs --write-baseline   record today's sites (report mode's ratchet)
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const SCOPE = ['supabase/functions', 'services', 'workers', 'supabase/migrations', 'infra',
  // The hosted workflow job runs these on Cloud Run (services/workflow-checks/Dockerfile).
  'scripts/workflow-checks.mjs', 'scripts/reader-workflow.mjs'];
export const REASONS = ['link', 'parse', 'namespace', 'prompt', 'tavily-filter', 'device'];
const HOST = /(?:^|[^a-z0-9.-])((?:[a-z0-9-]+\.)*arxiv\.org)(?![a-z0-9-])/gi;
const CODE = /\.(?:ts|tsx|js|mjs|cjs|py|sql|json|yaml|yml|toml|sh)$/;
const MARKER = new RegExp(`egress-ok:\\s*(${REASONS.join('|')})\\b`);

function files(root, path) {
  const absolute = join(root, path);
  let stat; try { stat = statSync(absolute); } catch { return []; }
  if (stat.isFile()) return CODE.test(path) ? [path] : [];
  return readdirSync(absolute).flatMap(name => name === 'node_modules' || name.startsWith('.') ? [] : files(root, join(path, name)));
}

/** Code comments never make a request: a whole-line comment is skipped. */
const isComment = (line, sql) => sql ? /^\s*--/.test(line) : /^\s*(?:\/\/|\*|\/\*|#)/.test(line);

/** SQL statements (split at `;` outside quotes) with the line each starts on. */
function sqlStatements(text) {
  const out = []; let start = 0, line = 1, startLine = 1, quote = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '\n') line++;
    if (c === "'") quote = !quote;
    if (c === ';' && !quote) { out.push({ text: text.slice(start, i + 1), line: startLine }); start = i + 1; startLine = line; }
  }
  if (start < text.length) out.push({ text: text.slice(start), line: startLine });
  return out;
}

/** Every unexplained arXiv host in one file: { path, line, host, text }. */
export function scanText(path, text) {
  const findings = [], sql = path.endsWith('.sql');
  if (sql) {
    // pg_net and the http extension are the only ways SQL could make a request.
    for (const statement of sqlStatements(text)) {
      if (!/\b(?:net\.http_(?:get|post|delete)|extensions\.http\w*|http_(?:get|post)\s*\()/i.test(statement.text)) continue;
      statement.text.split('\n').forEach((line, index) => {
        if (isComment(line, true) || MARKER.test(line)) return;
        for (const match of line.matchAll(HOST)) findings.push({ path, line: statement.line + index, host: match[1].toLowerCase(), text: line.trim().slice(0, 160) });
      });
    }
    return findings;
  }
  text.split('\n').forEach((line, index) => {
    if (isComment(line, false) || MARKER.test(line)) return;
    for (const match of line.matchAll(HOST)) findings.push({ path, line: index + 1, host: match[1].toLowerCase(), text: line.trim().slice(0, 160) });
  });
  return findings;
}

export function scan(root) {
  return SCOPE.flatMap(path => files(root, path)).sort().flatMap(path => scanText(path, readFileSync(join(root, path), 'utf8')));
}

/** Findings per file (line numbers move; counts per file are what the ratchet compares). */
export const counts = findings => findings.reduce((out, f) => ({ ...out, [f.path]: (out[f.path] ?? 0) + 1 }), {});

/** Findings beyond the recorded baseline: a new call site, or more of them in a file. */
export function beyondBaseline(findings, baseline) {
  const now = counts(findings);
  return Object.entries(now).filter(([path, n]) => n > (baseline[path] ?? 0)).map(([path, n]) => ({ path, count: n, baseline: baseline[path] ?? 0 }));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const root = fileURLToPath(new URL('../', import.meta.url));
  const baselinePath = join(root, 'scripts/arxiv-egress-baseline.json');
  const findings = scan(root);
  const block = process.argv.includes('--block') || process.env.EGRESS_ARXIV === 'block';
  if (process.argv.includes('--write-baseline')) {
    writeFileSync(baselinePath, JSON.stringify({ note: 'Server call sites to arXiv still to retire (docs/architecture/ARXIV_DEVICE_ONLY.md). Report mode fails only on sites beyond these.', sites: counts(findings) }, null, 1) + '\n');
  }
  let baseline = {};
  try { baseline = JSON.parse(readFileSync(baselinePath, 'utf8')).sites ?? {}; } catch { baseline = {}; }
  const grown = beyondBaseline(findings, baseline);
  if (process.argv.includes('--json')) console.log(JSON.stringify({ mode: block ? 'block' : 'report', findings, grown }, null, 1));
  else {
    console.log(`arXiv egress scan (${block ? 'block' : 'report'}): ${findings.length} server call site${findings.length === 1 ? '' : 's'} naming an arXiv host`);
    for (const f of findings) console.log(`  ${f.path}:${f.line}  ${f.host}  ${f.text}`);
    for (const g of grown) console.log(`  NEW: ${g.path} has ${g.count} (baseline ${g.baseline})`);
  }
  if (block ? findings.length > 0 : grown.length > 0) {
    console.error(block ? 'Refusing: servers must not contact arXiv.' : 'Refusing: a new server call site names an arXiv host (mark it egress-ok with a reason, or move the request to the device).');
    process.exitCode = 1;
  }
}
