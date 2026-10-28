#!/usr/bin/env node
// Complete recorded-paper A/B for the delivered transcription boundary. No PDF fetch or model calls.
// Manifest: [{ group, directory }] where each directory contains paper folders with record.json[.gz].
// node .../audit_transcription_boundary.mjs BASELINE_CHECKOUT MANIFEST.json REPORT.json
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, existsSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { gunzipSync } from 'node:zlib';
import { parseDocument } from 'htmlparser2';
import { composeDevicePDFReader as candidate } from '../../supabase/functions/_shared/reader/device-pdf/bundle.ts';
import { replayHost } from '../../supabase/functions/_shared/reader/device-pdf/record.ts';
import { png } from '../../tests/backend/device-pdf/synthetic.ts';

const [baselineRoot, manifestPath, reportPath] = process.argv.slice(2);
assert.ok(baselineRoot && manifestPath && reportPath, 'BASELINE_CHECKOUT MANIFEST.json REPORT.json required');
const { composeDevicePDFReader: baseline } = await import(pathToFileURL(resolve(baselineRoot, 'supabase/functions/_shared/reader/device-pdf/bundle.ts')).href);
const text = 'Equation in PDF (transcription unavailable)', marker = `\\text{${text}}`;
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const decode = bytes => new TextDecoder().decode(bytes);
const jsonMember = (b, name) => JSON.parse(decode(b.members.get(name)));
const walk = (node, fn) => { fn(node); for (const c of node.children ?? []) walk(c, fn); };

function normalizedDOM(html, rejected) {
  const tree = parseDocument(decode(html));
  walk(tree, node => {
    if (!rejected.has(node.attribs?.['data-reader-equation'])) return;
    node.attribs['data-latex'] = marker;
    if (node.attribs.class.includes('reader-math-fallback')) node.children = [{ type: 'text', data: node.attribs.class.includes('reader-display') ? marker : `\\(${marker}\\)` }];
    else for (const c of node.children) if (c.name === 'img') c.attribs.alt = text;
  });
  const shape = n => [n.type, n.name ?? '', n.data ?? '', Object.entries(n.attribs ?? {}).sort(), (n.children ?? []).map(shape)];
  return shape(tree);
}

function run(converter, record) {
  let sequence = 0;
  const images = [];
  const host = replayHost(record, r => {
    images.push(r);
    // Image pixels are stand-ins; identical requests and bytes protect crop/asset behavior.
    const width = Math.max(1, r.rect[2] - r.rect[0]), height = Math.max(1, r.rect[3] - r.rect[1]);
    return { png: png(width, height, sequence++), width, height, ...(r.clean ? { rect: r.rect } : {}) };
  });
  const bundle = converter({ ...record.input, trace: true }, host);
  assert.deepEqual(host.misses, { tags: 0, crops: 0 }, 'incomplete model record');
  return { bundle, images, index: jsonMember(bundle, 'reader.json'), provenance: jsonMember(bundle, 'provenance.json') };
}

const report = { metric: 'rejected recognizer guesses exposed in delivered equations (not recognition accuracy)',
  converters: Object.fromEntries([['baseline', resolve(baselineRoot)], ['candidate', fileURLToPath(new URL('../../', import.meta.url))]]
    .map(([name, root]) => [name, JSON.parse(readFileSync(join(root, 'apps/apple/ScienceReader/Resources/device-pdf-reader-build.json'), 'utf8'))])),
  manifest_sha256: sha(readFileSync(manifestPath)), papers: [], totals: { papers: 0, pages: 0, equations: 0, accepted: 0, rejected: 0, exposed_before: 0, exposed_after: 0, nonempty_guesses_before: 0 } };
const seen = new Set();
mkdirSync(dirname(resolve(reportPath)), { recursive: true });
for (const source of JSON.parse(readFileSync(manifestPath, 'utf8'))) {
  for (const key of readdirSync(source.directory).sort()) {
    const dir = join(source.directory, key), plain = join(dir, 'record.json'), zipped = plain + '.gz';
    if (!existsSync(plain) && !existsSync(zipped)) continue;
    const file = existsSync(plain) ? plain : zipped, bytes = readFileSync(file);
    const record = JSON.parse(decode(file.endsWith('.gz') ? gunzipSync(bytes) : bytes));
    assert.ok(!seen.has(record.input.pdf.sha256), 'duplicate PDF in evaluation manifest');
    seen.add(record.input.pdf.sha256);
    const a = run(baseline, record), b = run(candidate, record);
    const rejected = new Set(a.provenance.equations.filter(r => r[2] === 0).map(r => r[0]));
    assert.deepEqual(a.provenance.equations, b.provenance.equations, 'gates/IDs/locations changed');
    assert.deepEqual(a.provenance.blocks, b.provenance.blocks, 'block locations changed');
    assert.deepEqual(a.provenance.figures, b.provenance.figures, 'figure locations changed');
    assert.deepEqual(a.images, b.images, 'crop requests changed');
    assert.deepEqual(a.bundle.trace, b.bundle.trace, 'raw diagnostic/model outputs changed');
    assert.deepEqual(normalizedDOM(a.bundle.members.get('index.html'), rejected), normalizedDOM(b.bundle.members.get('index.html'), rejected), 'content outside rejected equation representations changed');
    assert.deepEqual(a.index.equations.map(({ latex, ...r }) => r), b.index.equations.map(({ latex, ...r }) => r));
    let before = 0, after = 0, guesses = 0;
    for (let i = 0; i < a.index.equations.length; i++) {
      const x = a.index.equations[i], y = b.index.equations[i];
      if (!rejected.has(x.id)) { assert.equal(x.latex, y.latex, 'accepted transcription changed'); continue; }
      if (x.latex !== marker) before++;
      if (x.latex !== '\\text{?}' && x.latex !== marker) guesses++;
      if (y.latex !== marker) after++;
    }
    const tree = parseDocument(decode(b.bundle.members.get('index.html')));
    walk(tree, node => {
      if (!rejected.has(node.attribs?.['data-reader-equation'])) return;
      assert.equal(node.attribs['data-latex'], marker);
      for (const child of node.children) if (child.name === 'img') assert.equal(child.attribs.alt, text);
      if (node.attribs.class.includes('reader-math-fallback')) assert.equal(node.children.map(n => n.data ?? '').join(''), node.attribs.class.includes('reader-display') ? marker : `\\(${marker}\\)`);
    });
    assert.equal(after, 0);
    const row = { group: source.group, paper: key, record_sha256: sha(bytes), pdf_sha256: record.input.pdf.sha256,
      pages: record.input.pages, equations: a.index.equations.length, accepted: a.index.equations.length - rejected.size,
      rejected: rejected.size, exposed_before: before, exposed_after: after, nonempty_guesses_before: guesses,
      candidate_index_sha256: sha(b.bundle.members.get('reader.json')) };
    report.papers.push(row);
    report.totals.papers++;
    for (const name of Object.keys(report.totals).filter(k => k !== 'papers')) report.totals[name] += row[name];
    writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify({ paper: key, rejected: before, exposed_after: after }));
  }
}
assert.ok(report.totals.papers > 0 && report.totals.nonempty_guesses_before > 0, 'no affected baseline; this cannot prove improvement');
report.passed = true;
writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report.totals));
