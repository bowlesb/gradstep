#!/usr/bin/env node
// Deletes the server's historical paper copies on staging (owner, 2026-10-16: "Yes, we can even delete them now, so
// it's obvious we have zero on our system"). Design: docs/architecture/DATA_HANDLING_AND_COSTS.md "Server paper copies:
// retired"; database side: migration 080 (worker_paper_copies_*).
//
//   node scripts/delete-paper-copies.mjs            # dry run (the default): what Storage holds, per bucket and prefix
//   node scripts/delete-paper-copies.mjs --apply    # retire, tell devices, delete, confirm, list again
//
// --apply, in order: (1) worker_paper_copies_retire: the fence goes on (no paper copy can be registered again), every
// paper copy's availability becomes unavailable and every tracked one is scheduled for deletion; (2) worker_paper_copies
// _project: library rows say the server copy is unavailable (devices stop asking reader-artifact; arXiv papers open from
// arXiv on the device); (3) each page of scheduled objects is removed from Storage, the page's folders are listed again
// to prove the files are gone, and only then worker_paper_copies_deleted records them; (4) anything left in the paper
// buckets that the database never tracked is removed the same way if its path is a pipeline path (anything else stops
// the run); (5) Storage is listed again: the paper buckets must hold zero objects and the control buckets (podcast audio,
// episode text, report screenshots) exactly what they held before. Counts only are printed and saved
// (.artifacts/paper-copies/); secrets come from .env.staging (a git worktree reads the main checkout's) and are never
// printed. Staging only. No dependencies beyond Node 24.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CONTROL_BUCKETS, PAPER_BUCKETS, isPaperCopyPath, listBucket, megabytes, removeObjects, summarize } from './paper-copies.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PROJECT_REF = 'coxhjvqpflgxkleydati';
const args = new Set(process.argv.slice(2));
for (const a of args) if (!['--apply', '--dry-run'].includes(a)) { console.error(`Unknown argument ${a}. Use --dry-run (default) or --apply.`); process.exit(2); }
if (args.has('--apply') && args.has('--dry-run')) { console.error('Choose --dry-run or --apply.'); process.exit(2); }
const apply = args.has('--apply');

function secretsRoot() {
  if (existsSync(join(ROOT, '.env.staging'))) return ROOT;
  try { // A git worktree: the secrets stay in the main checkout.
    const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (existsSync(join(dirname(common), '.env.staging'))) return dirname(common);
  } catch { /* not a git checkout */ }
  return null;
}
const dir = secretsRoot();
const env = !dir ? {} : Object.fromEntries(readFileSync(join(dir, '.env.staging'), 'utf8').split('\n')
  .filter(l => l.includes('=') && !l.trimStart().startsWith('#'))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]; }));
// Staging only, as scripts/live-journey.mjs asserts.
if (env.SUPABASE_PROJECT_REF !== PROJECT_REF || !env.SUPABASE_URL?.startsWith(`https://${PROJECT_REF}.`)) {
  console.error('Staging only: .env.staging must name project coxhjvqpflgxkleydati.'); process.exit(2);
}
const URL_ = env.SUPABASE_URL, KEY = env.SUPABASE_SERVICE_ROLE_KEY;
if (!KEY) { console.error('Needs SUPABASE_SERVICE_ROLE_KEY in .env.staging.'); process.exit(2); }
const redact = text => String(text).split(KEY).join('[redacted]');

async function rpc(name, params = {}) {
  const response = await fetch(`${URL_}/rest/v1/rpc/${name}`, { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(120_000),
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'content-type': 'application/json' }, body: JSON.stringify(params) });
  const text = await response.text();
  let json = null; try { json = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  if (response.status >= 300) { const e = new Error(`${name}: HTTP ${response.status} ${json?.message ?? json?.code ?? ''}`.trim()); e.status = response.status; e.code = json?.code; throw e; }
  return json;
}
async function inventory(buckets) {
  const all = [];
  for (const bucket of buckets) all.push(...await listBucket(URL_, KEY, bucket));
  return all;
}
function print(label, objects, buckets) {
  const s = summarize(objects);
  console.log(label);
  for (const bucket of buckets) {
    const b = s[bucket] ?? { objects: 0, bytes: 0, prefixes: {} };
    console.log(`  ${bucket.padEnd(16)} ${String(b.objects).padStart(5)} objects  ${megabytes(b.bytes).padStart(9)}  (${b.bytes} bytes)`);
    for (const [prefix, p] of Object.entries(b.prefixes).sort()) console.log(`    ${(prefix + '/').padEnd(14)} ${String(p.objects).padStart(5)} objects  ${megabytes(p.bytes).padStart(9)}`);
  }
  return s;
}
const counts = s => Object.fromEntries(Object.entries(s).map(([b, v]) => [b, { objects: v.objects, bytes: v.bytes,
  prefixes: Object.fromEntries(Object.entries(v.prefixes).map(([p, x]) => [p, { objects: x.objects, bytes: x.bytes }])) }]));
// Every file of a page must be gone: list each folder the page touched again.
async function stillPresent(page) {
  const folders = new Map();
  for (const o of page) { const k = `${o.bucket}\u0000${o.path.slice(0, o.path.lastIndexOf('/'))}`; if (!folders.has(k)) folders.set(k, new Set()); folders.get(k).add(o.path); }
  const left = [];
  for (const [key, paths] of folders) {
    const [bucket, folder] = key.split('\u0000');
    const response = await fetch(`${URL_}/storage/v1/object/list/${encodeURIComponent(bucket)}`, { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(30_000),
      headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'content-type': 'application/json' },
      body: JSON.stringify({ prefix: folder, limit: 1000, offset: 0, sortBy: { column: 'name', order: 'asc' } }) });
    if (response.status !== 200) throw new Error(`${bucket}: listing answered HTTP ${response.status}`);
    for (const entry of await response.json()) if (entry.id && paths.has(`${folder}/${entry.name}`)) left.push(`${bucket}/${folder}/${entry.name}`);
  }
  return left;
}

async function main() {
  console.log(`Server paper copies on staging (${PROJECT_REF}) — ${apply ? 'APPLY' : 'dry run; nothing changes (--apply to delete)'}`);
  const papers = await inventory(PAPER_BUCKETS), controls = await inventory(CONTROL_BUCKETS);
  const before = print('Storage now, paper copies:', papers, PAPER_BUCKETS);
  const controlBefore = print('Storage now, not paper copies (never touched):', controls, CONTROL_BUCKETS);
  const unexpected = papers.filter(o => !isPaperCopyPath(o.bucket, o.path));
  if (unexpected.length) console.log(`  ${unexpected.length} object(s) in the paper buckets outside the pipeline's paths: the run stops before deleting them.`);
  let status = null;
  try { status = await rpc('worker_paper_copies_status'); } catch (error) { console.log(`Database: ${error.status === 404 ? 'migration 080 is not applied (worker_paper_copies_status missing)' : redact(error.message)}`); }
  if (status) {
    console.log(`Database: retired ${status.retired_at ?? 'no'}; ${status.live} tracked copies live; ${status.objects_deleted} deleted so far; ${status.open_writes} unresolved writes`);
    for (const t of status.tracked) console.log(`  tracked ${t.bucket.padEnd(14)} ${t.state.padEnd(9)} ${String(t.objects).padStart(5)} objects  ${megabytes(Number(t.bytes))}`);
  }
  const report = { at: new Date().toISOString(), project_ref: PROJECT_REF, mode: apply ? 'apply' : 'dry-run', before: counts(before),
    controls_before: counts(controlBefore), unexpected: unexpected.length, database_before: status && { ...status, tracked: status.tracked } };
  if (!apply) { save(report); return; }
  if (!status) throw new Error('Apply needs migration 080 on staging.');
  if (unexpected.length) throw new Error('Objects outside the pipeline paths are in a paper bucket; review them before deleting.');

  // (1) Retire, (2) tell devices.
  let page = await rpc('worker_paper_copies_retire', { p_limit: 1000 });
  console.log(`Retired at ${page.retired_at}: ${page.availability_marked} availability rows marked unavailable, ${page.scheduled} objects scheduled, ${page.deleting} deleting`);
  let projected = 0;
  for (let round = 0; round < 50; round++) {
    const r = await rpc('worker_paper_copies_project', { p_limit: 100 });
    projected += r.projected;
    if (r.remaining === 0) break;
    if (r.projected === 0) throw new Error(`${r.remaining} library rows could not be projected`);
  }
  console.log(`Library: ${projected} rows now say the server copy is unavailable`);

  // (3) Delete page by page; record only what a fresh listing proves gone.
  let deleted = 0, deletedBytes = 0;
  while (page.objects.length) {
    for (const bucket of PAPER_BUCKETS) {
      const paths = page.objects.filter(o => o.bucket === bucket).map(o => o.path);
      if (paths.length) await removeObjects(URL_, KEY, bucket, paths);
    }
    const left = await stillPresent(page.objects);
    if (left.length) throw new Error(`${left.length} object(s) still listed after delete; nothing recorded for this page`);
    for (let i = 0; i < page.objects.length; i += 1000) {
      const r = await rpc('worker_paper_copies_deleted', { p_object_ids: page.objects.slice(i, i + 1000).map(o => o.id) });
      deleted += r.confirmed; deletedBytes += Number(r.bytes);
    }
    console.log(`  deleted and confirmed ${deleted} (${megabytes(deletedBytes)})`);
    page = await rpc('worker_paper_copies_retire', { p_limit: 1000 });
  }

  // (4) Files the database never tracked.
  const untracked = (await inventory(PAPER_BUCKETS));
  if (untracked.some(o => !isPaperCopyPath(o.bucket, o.path))) throw new Error('An object outside the pipeline paths appeared in a paper bucket; stopped');
  for (const bucket of PAPER_BUCKETS) {
    const paths = untracked.filter(o => o.bucket === bucket).map(o => o.path);
    if (paths.length) await removeObjects(URL_, KEY, bucket, paths);
  }
  if (untracked.length) console.log(`  removed ${untracked.length} untracked object(s) (${megabytes(untracked.reduce((n, o) => n + o.bytes, 0))})`);

  // (5) Proof.
  const after = await inventory(PAPER_BUCKETS), controlsAfter = await inventory(CONTROL_BUCKETS);
  const afterSummary = print('Storage after, paper copies:', after, PAPER_BUCKETS);
  const controlAfterSummary = print('Storage after, not paper copies:', controlsAfter, CONTROL_BUCKETS);
  const final = await rpc('worker_paper_copies_status');
  console.log(`Database: ${final.live} tracked copies live; ${final.objects_deleted} deleted (${megabytes(Number(final.bytes_deleted))}); complete ${final.completed_at ?? 'no'}`);
  const controlsSame = CONTROL_BUCKETS.every(b => (controlBefore[b]?.objects ?? 0) === (controlAfterSummary[b]?.objects ?? 0)
    && (controlBefore[b]?.bytes ?? 0) === (controlAfterSummary[b]?.bytes ?? 0));
  Object.assign(report, { library_rows_projected: projected, deleted_tracked: deleted, deleted_tracked_bytes: deletedBytes, deleted_untracked: untracked.length,
    after: counts(afterSummary), controls_after: counts(controlAfterSummary), controls_unchanged: controlsSame, database_after: final });
  save(report);
  if (after.length || final.live !== 0) throw new Error(`Not zero: ${after.length} objects in Storage, ${final.live} tracked`);
  if (!controlsSame) throw new Error('A control bucket changed during the run (an episode or report may have been added meanwhile); compare the report');
  console.log('Zero paper copies in Storage; control buckets unchanged.');
}
function save(report) {
  const out = join(ROOT, '.artifacts/paper-copies'); mkdirSync(out, { recursive: true });
  const file = join(out, `${report.at.replace(/[:.]/g, '-')}-${report.mode}.json`);
  writeFileSync(file, JSON.stringify(report, null, 1) + '\n');
  console.log(`Report: ${file.slice(ROOT.length + 1)}`);
}
main().catch(error => { console.error(redact(error.stack ?? error.message)); process.exit(1); });
