#!/usr/bin/env node
// Opt-in, offline audit of the equation display gate using recorded on-device model outputs.
// No model inference, PDF acquisition or substitute pixels: this runs only read/settle/gate.
// node scripts/device-pdf-math-audit.mjs --records DIR --out report.json [--baseline before.json]
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { gunzipSync } from 'node:zlib';
import { gate, read, settle } from '../supabase/functions/_shared/reader/device-pdf/convert.ts';
import { replayHost } from '../supabase/functions/_shared/reader/device-pdf/record.ts';
import { DEVICE_PDF_PORT_REVISION } from '../supabase/functions/_shared/reader/device-pdf/types.ts';

const arg = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv[i + 1]; };
if (!arg('--records') || !arg('--out')) throw new Error('Required: --records DIR --out report.json');
const records = resolve(arg('--records')), out = resolve(arg('--out'));
const papers = [];
for (const paper of readdirSync(records).sort()) {
  const plain = join(records, paper, 'record.json'), zipped = `${plain}.gz`;
  if (!existsSync(plain) && !existsSync(zipped)) continue;
  const bytes = existsSync(plain) ? readFileSync(plain) : gunzipSync(readFileSync(zipped));
  const record = JSON.parse(bytes.toString('utf8'));
  if (record.format !== 'device-pdf-record-v1') throw new Error(`Unknown record format: ${paper}`);
  const host = replayHost(record, () => { throw new Error('The gate audit must not render images'); });
  const reading = read(record.input, host);
  settle(reading, host);
  gate(reading);
  papers.push({ paper, recordSHA256: createHash('sha256').update(bytes).digest('hex'), pages: record.pages.length,
    models: record.input.models, misses: host.misses, blocks: reading.trace.blocks,
    formulas: reading.committed.map(id => {
      const f = reading.formulas.get(id);
      return { id, page: f.page, box: f.box, display: f.display, latex: f.latex, confidence: f.confidence,
        glyphs: f.glyphTexts, transcribed: !!f.transcribed, rendered: f.rendered };
    }) });
}
if (!papers.length) throw new Error('No records found');
const formulas = papers.flatMap(p => p.formulas);
const summary = { papers: papers.length, pages: papers.reduce((n, p) => n + p.pages, 0), formulas: formulas.length,
  rendered: formulas.filter(f => f.rendered).length, recognised: formulas.filter(f => f.latex && !f.transcribed).length,
  misses: papers.reduce((m, p) => ({ tags: m.tags + p.misses.tags, crops: m.crops + p.misses.crops }), { tags: 0, crops: 0 }) };
const report = { revision: DEVICE_PDF_PORT_REVISION, records, summary, papers };
if (arg('--baseline')) {
  const before = JSON.parse(readFileSync(arg('--baseline'), 'utf8'));
  const previous = new Map(before.papers.map(p => [p.paper, p]));
  const changed = [];
  if (previous.size !== papers.length) throw new Error('Paper set changed');
  for (const p of papers) {
    const old = previous.get(p.paper);
    if (!old || old.recordSHA256 !== p.recordSHA256) throw new Error(`Record changed: ${p.paper}`);
    if (JSON.stringify(old.blocks) !== JSON.stringify(p.blocks)) throw new Error(`Text or block identity changed: ${p.paper}`);
    if (JSON.stringify(old.misses) !== JSON.stringify(p.misses)) throw new Error(`Replay coverage changed: ${p.paper}`);
    if (old.formulas.length !== p.formulas.length) throw new Error(`Formula count changed: ${p.paper}`);
    p.formulas.forEach((f, i) => {
      const previous = old.formulas[i];
      const invariant = x => JSON.stringify({ ...x, rendered: undefined });
      if (invariant(f) !== invariant(previous)) throw new Error(`Equation content or source region changed: ${p.paper}/${f.id}`);
      if (f.rendered !== previous.rendered) changed.push({ paper: p.paper, before: previous.rendered, ...f });
    });
  }
  const removed = changed.filter(f => f.before && !f.rendered).length;
  report.comparison = { before: before.summary.rendered, after: summary.rendered, removed,
    added: changed.length - removed, retained: (before.summary.rendered - removed) / before.summary.rendered, changed };
}
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(report, null, 1) + '\n');
console.log(JSON.stringify({ ...summary, ...(report.comparison ? { comparison: { ...report.comparison, changed: report.comparison.changed.length } } : {}) }));
if (summary.misses.tags || summary.misses.crops) console.warn('Replay has missing model answers; inspect coverage before interpreting results.');
