#!/usr/bin/env node
// Conservation and native crop-job extraction only. Synthetic replay pixels cannot score visual crop quality.
// node audit_formula_crops.mjs BASELINE_CHECKOUT MANIFEST_JSON PDF_MAP_JSON OUTDIR
// Manifest: [{group, directory}] containing paper subdirectories with record.json[.gz]. PDF map: {sha256: localPath}.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { gunzipSync } from 'node:zlib';
import { parseDocument } from 'htmlparser2';
import { composeDevicePDFReader as candidate } from '../../supabase/functions/_shared/reader/device-pdf/bundle.ts';
import { replayHost } from '../../supabase/functions/_shared/reader/device-pdf/record.ts';
import { png } from '../../tests/backend/device-pdf/synthetic.ts';

const [baselineRoot, manifestPath, pdfMapPath, outputPath] = process.argv.slice(2);
assert.ok(baselineRoot && manifestPath && pdfMapPath && outputPath, 'BASELINE_CHECKOUT MANIFEST_JSON PDF_MAP_JSON OUTDIR required');
const out = resolve(outputPath), root = fileURLToPath(new URL('../../', import.meta.url));
const { composeDevicePDFReader: baseline } = await import(pathToFileURL(resolve(baselineRoot, 'supabase/functions/_shared/reader/device-pdf/bundle.ts')).href);
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const decode = bytes => new TextDecoder().decode(bytes);
const readJSON = path => JSON.parse(readFileSync(path, 'utf8'));
const memberJSON = (bundle, name) => JSON.parse(decode(bundle.members.get(name)));
const walk = (node, fn) => { fn(node); for (const c of node.children ?? []) walk(c, fn); };
const withoutContent = r => {
  if (!r.clean) return r;
  const { content, ...clean } = r.clean;
  return { ...r, clean };
};

function run(converter, record) {
  let sequence = 0;
  const images = [], recognitions = [], assets = new Map();
  const host = replayHost(record, request => {
    images.push(request);
    const width = Math.max(1, request.rect[2] - request.rect[0]), height = Math.max(1, request.rect[3] - request.rect[1]);
    assert.ok(sequence < 65536, 'synthetic image seed would repeat within this paper');
    const encoded = png(width, height, sequence++), asset = `assets/${sha(Buffer.from(encoded, 'base64'))}.png`;
    assert.ok(!assets.has(asset), 'synthetic image identity is not unique');
    assets.set(asset, request);
    return { png: encoded, width, height, ...(request.clean ? { rect: request.rect } : {}) };
  });
  const recognise = host.recognise;
  host.recognise = crops => { recognitions.push(crops); return recognise(crops); };
  const bundle = converter({ ...record.input, trace: true }, host);
  assert.deepEqual(host.misses, { tags: 0, crops: 0 }, 'incomplete recorded model answers');
  return { bundle, images, recognitions, assets, index: memberJSON(bundle, 'reader.json'), provenance: memberJSON(bundle, 'provenance.json') };
}

const pdfMap = readJSON(pdfMapPath), verifiedPDFs = new Set(), seen = new Set(), jobs = [];
const emptyCounts = () => ({ papers: 0, pages: 0, equations: 0, rejected: 0, image_requests: 0, hints: 0, mapped_fallbacks: 0 });
const report = { purpose: 'crop-request conservation and native job extraction; no visual accuracy claim',
  manifest_sha256: sha(readFileSync(manifestPath)), pdf_map_sha256: sha(readFileSync(pdfMapPath)),
  converters: Object.fromEntries([['baseline', resolve(baselineRoot)], ['candidate', root]].map(([name, directory]) =>
    [name, readJSON(join(directory, 'apps/apple/ScienceReader/Resources/device-pdf-reader-build.json'))])),
  passed: false, groups: {}, papers: [], totals: emptyCounts() };
mkdirSync(join(out, 'cases'), { recursive: true });
const save = () => {
  writeFileSync(join(out, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  writeFileSync(join(out, 'crop-jobs.json'), JSON.stringify(jobs, null, 2) + '\n');
};
// Invalidate an earlier successful report before doing any comparisons in this output directory.
save();
for (const source of readJSON(manifestPath)) {
  for (const key of readdirSync(source.directory).sort()) {
    const plain = join(source.directory, key, 'record.json'), zipped = plain + '.gz';
    if (!existsSync(plain) && !existsSync(zipped)) continue;
    const file = existsSync(plain) ? plain : zipped, bytes = readFileSync(file);
    const record = JSON.parse(decode(file.endsWith('.gz') ? gunzipSync(bytes) : bytes));
    const pdfSHA = record.input.pdf.sha256;
    assert.ok(!seen.has(pdfSHA), 'duplicate PDF in evaluation manifest'); seen.add(pdfSHA);
    const a = run(baseline, record), b = run(candidate, record);
    assert.deepEqual(a.bundle.trace, b.bundle.trace, 'raw model results or reading trace changed');
    assert.deepEqual(a.provenance.equations, b.provenance.equations, 'equation decisions or PDF bounds changed');
    const { adapter: oldAdapter, ...oldProvenance } = a.provenance;
    const { adapter: newAdapter, ...newProvenance } = b.provenance;
    assert.deepEqual(oldProvenance, newProvenance, 'provenance beyond converter identity changed');
    assert.deepEqual(a.recognitions, b.recognitions, 'recognition request geometry/order changed');
    assert.deepEqual(a.images.map(withoutContent), b.images.map(withoutContent), 'image request changed beyond content hint');
    assert.deepEqual(a.index, b.index, 'reader index changed');
    assert.deepEqual(a.bundle.members.get('index.html'), b.bundle.members.get('index.html'), 'reader HTML changed with identical replay pixels');
    const row = { group: source.group, paper: key, pdf_sha256: pdfSHA, record_sha256: sha(bytes), papers: 1,
      pages: record.input.pages, equations: b.index.equations.length, rejected: b.provenance.equations.filter(e => !e[2]).length,
      image_requests: b.images.length, hints: b.images.filter(r => r.clean?.content).length, mapped_fallbacks: 0 };
    if (pdfMap[pdfSHA]) {
      const pdf = resolve(pdfMap[pdfSHA]);
      if (!verifiedPDFs.has(pdfSHA)) { assert.equal(sha(readFileSync(pdf)), pdfSHA, 'local PDF differs from recorded source'); verifiedPDFs.add(pdfSHA); }
      walk(parseDocument(decode(b.bundle.members.get('index.html'))), node => {
        const equation = node.attribs?.['data-reader-equation'];
        if (!equation || !node.attribs.class?.split(' ').includes('reader-math-image')) return;
        const image = node.children.find(child => child.name === 'img'), request = b.assets.get(image?.attribs.src);
        assert.ok(request?.clean, 'fallback image has no corresponding crop request');
        const id = sha(Buffer.from(`${pdfSHA}:${equation}`)).slice(0, 16);
        jobs.push({ id, equation, group: source.group, paper: key, pdf_sha256: pdfSHA, pdf, page: request.page,
          rect: request.rect, em: request.clean.em, margin: request.clean.margin,
          ...(request.clean.content ? { content: request.clean.content } : {}), out: join(out, 'cases', id) });
        row.mapped_fallbacks++;
      });
    }
    report.papers.push(row);
    const group = report.groups[source.group] ??= emptyCounts();
    for (const name of Object.keys(report.totals)) { report.totals[name] += row[name]; group[name] += row[name]; }
    save();
    console.log(JSON.stringify({ paper: key, hints: row.hints, mapped_fallbacks: row.mapped_fallbacks }));
  }
}
assert.ok(report.totals.papers > 0, 'manifest contains no recordings');
assert.equal(new Set(jobs.map(j => j.id)).size, jobs.length, 'crop job identity collision');
report.passed = true; save();
console.log(JSON.stringify(report.totals));
