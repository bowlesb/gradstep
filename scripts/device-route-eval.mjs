#!/usr/bin/env node
// The on-device PDF route against the desktop's fixtures (docs/architecture/DEVICE_PDF_ROUTE.md): builds the Mac
// tool, converts each fixture PDF with the app's code (text layer, Core ML models, converter), and runs the desktop's
// bundle_conformance.py on the trace index. Prints one row per paper and writes .artifacts/device-route/summary.json.
//
//   node scripts/device-route-eval.mjs --fixtures <dir with <id>/paper.pdf and <id>/bundle> --conformance <bundle_conformance.py>
//       [--models apps/apple/DeviceModels] [--python ~/.coreml-venv/bin/python] [--only id,id] [--max-pages N]
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const arg = (name, fallback) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : fallback; };
const FIXTURES = arg('--fixtures'), CONFORMANCE = arg('--conformance');
if (!FIXTURES || !CONFORMANCE) { console.error('need --fixtures and --conformance'); process.exit(2); }
const MODELS = resolve(ROOT, arg('--models', 'apps/apple/DeviceModels'));
const COMPILER = join(ROOT, 'apps/apple/ScienceReader/Resources/device-pdf-reader.js');
const PYTHON = arg('--python', join(homedir(), '.coreml-venv/bin/python'));
const OUT = join(ROOT, '.artifacts/device-route');
const only = arg('--only', '')?.split(',').filter(Boolean) ?? [];
mkdirSync(OUT, { recursive: true });

const core = join(ROOT, 'apps/apple/ScienceReaderCore');
execFileSync('swift', ['build', '-c', 'release', '--product', 'DevicePDFRouteTool'], { cwd: core, stdio: ['ignore', 'ignore', 'inherit'] });
const tool = join(core, '.build/release/DevicePDFRouteTool');

const rows = [];
for (const id of readdirSync(FIXTURES).filter(d => existsSync(join(FIXTURES, d, 'paper.pdf'))).sort()) {
  if (only.length && !only.includes(id)) continue;
  const out = join(OUT, id);
  const args = [join(FIXTURES, id, 'paper.pdf'), out, '--models', MODELS, '--compiler', COMPILER, '--trace'];
  if (arg('--max-pages')) args.push('--max-pages', arg('--max-pages'));
  const started = Date.now();
  const run = spawnSync(tool, args, { encoding: 'utf8', maxBuffer: 64 << 20 });
  const seconds = (Date.now() - started) / 1000;
  writeFileSync(join(out + '.log'), (run.stdout ?? '') + (run.stderr ?? ''));
  if (run.status !== 0) { rows.push({ id, error: (run.stderr || run.stdout || '').trim().split('\n').slice(-3).join(' | '), seconds }); continue; }
  const verified = /verified [0-9a-f]{64}/.test(run.stdout);
  const conformance = spawnSync(PYTHON, ['-I', CONFORMANCE, out, join(FIXTURES, id, 'bundle'), '--json', join(out, 'conformance.json')], { encoding: 'utf8' });
  const c = existsSync(join(out, 'conformance.json')) ? JSON.parse(readFileSync(join(out, 'conformance.json'), 'utf8')) : {};
  const summary = JSON.parse(readFileSync(join(out, 'conversion.json'), 'utf8'));
  rows.push({ id, verified, seconds, pages: summary.pages, ...c, host_seconds: summary.host_seconds, unowned: summary.unowned,
    pass: conformance.status === 0 });
}
const fmt = v => typeof v === 'number' ? (Number.isInteger(v) ? String(v) : v.toFixed(3)) : String(v ?? '');
console.log(['paper', 'ok', 'pages', 's', 'blocks', 'order', 'heads', 'eq', 'latex=', 'rendered=', 'figs', 'tables', 'failed'].join('\t'));
for (const r of rows) {
  if (r.error) { console.log(`${r.id}\tFAILED\t\t${fmt(r.seconds)}\t${r.error}`); continue; }
  console.log([r.id, r.verified ? 'yes' : 'NO', r.pages, fmt(r.seconds), fmt(r.block_match), fmt(r.order), fmt(r.headings), fmt(r.equation_match),
    fmt(r.latex_equal), fmt(r.rendered_flag_equal), `${r.figures?.candidate}/${r.figures?.fixture}`, `${r.tables?.candidate}/${r.tables?.fixture}`,
    (r.failed ?? []).join(',')].join('\t'));
}
writeFileSync(join(OUT, 'summary.json'), JSON.stringify({ when: new Date().toISOString(), rows }, null, 1));
