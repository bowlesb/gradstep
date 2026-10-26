// Offline, opt-in evaluation: reuse recorded local model answers, evaluate new windows with the actual Apple host,
// and collect every missing crop for DevicePDFRouteTool --recognise-crops. Never score a partial replay.
// prepare --from m1-test --to span-test-rec --corpus DIR --models DIR --tool BINARY --work DIR
// finish  --to span-test-rec --answers FILE.jsonl --work DIR
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { gunzipSync, gzipSync } from 'node:zlib';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { composeDevicePDFReader } from '../../supabase/functions/_shared/reader/device-pdf/bundle.ts';
import { replayHost, tagKey, cropKey } from '../../supabase/functions/_shared/reader/device-pdf/record.ts';

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const arg = name => process.argv[process.argv.indexOf(name) + 1];
const work = resolve(arg('--work')), to = join(root, '.artifacts/device-route/accuracy', arg('--to'));
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const bytesAt = dir => existsSync(join(dir, 'record.json')) ? readFileSync(join(dir, 'record.json')) : gunzipSync(readFileSync(join(dir, 'record.json.gz')));
const recordAt = dir => JSON.parse(bytesAt(dir));
const save = (path, value) => writeFileSync(path, JSON.stringify(value));
const saveRecord = (dir, record) => { mkdirSync(dir, { recursive: true }); writeFileSync(join(dir, 'record.json.gz'), gzipSync(JSON.stringify(record))); };
const image = r => ({ png: '', width: Math.max(1, r.rect[2] - r.rect[0]), height: Math.max(1, r.rect[3] - r.rect[1]) });
const run = (record, host) => composeDevicePDFReader({ ...record.input, trace: false, record: false }, host);
mkdirSync(work, { recursive: true });

if (process.argv[2] === 'prepare') {
  const from = join(root, '.artifacts/device-route/accuracy', arg('--from'));
  const corpus = resolve(arg('--corpus')), models = resolve(arg('--models')), tool = resolve(arg('--tool'));
  const vocab = JSON.parse(readFileSync(join(models, 'tagger-vocab.json')));
  const keys = readdirSync(from).filter(k => existsSync(join(from, k, 'record.json')) || existsSync(join(from, k, 'record.json.gz'))).sort();
  const queries = new Map(), checks = [], sources = {};
  for (const key of keys) {
    const raw = bytesAt(join(from, key)), record = JSON.parse(raw);
    assert.equal(record.input.pdf.sha256, sha(readFileSync(join(corpus, key, 'paper.pdf'))), `${key}: exact local PDF`);
    const { threshold: oldThreshold, ...oldVocab } = record.input.tagger, { threshold, ...newVocab } = vocab;
    // Swift's JSON encoder round-trips the last decimal bit differently from Node; the model reads float32.
    const normalized = value => JSON.parse(JSON.stringify(value, (_, v) => typeof v === 'number' ? Number(v.toPrecision(12)) : v));
    assert.deepEqual(normalized(oldVocab), normalized(newVocab), `${key}: recorded context model vocabulary`);
    sources[key] = { record_sha256: sha(raw), pdf_sha256: record.input.pdf.sha256, original_models: record.input.models };
    record.input.tagger = vocab;
    const tags = new Map(record.tags), host = replayHost(record, image), lines = [];
    const tag = host.tag;
    host.tag = ls => { for (const l of ls) { const k = tagKey(l); lines.push(l); if (!tags.has(k)) queries.set(k, l); } return tag(ls); };
    run(record, host);
    // Four evenly spaced actual converter inputs per paper independently verify the reused export's answers.
    for (let i = 0; i < 4 && lines.length; i++) {
      const l = lines[Math.floor(i * (lines.length - 1) / 3)], k = tagKey(l);
      if (tags.has(k)) { queries.set(k, l); checks.push({ key, tag: k, expected: tags.get(k) }); }
    }
  }
  const inputs = [...queries.values()]; save(join(work, 'tag-inputs.json'), inputs);
  execFileSync(tool, ['--tag-inputs', join(work, 'tag-inputs.json'), '--models', models, '--out', join(work, 'tag-outputs.json')], { stdio: 'inherit' });
  const outputs = JSON.parse(readFileSync(join(work, 'tag-outputs.json')));
  assert.equal(outputs.logits.length, inputs.length);
  const fresh = new Map(inputs.map((l, i) => [tagKey(l), outputs.logits[i]]));
  let worst = 0, disagreements = 0, checkedGlyphs = 0;
  const logitThreshold = Math.log(vocab.threshold / (1 - vocab.threshold));
  for (const check of checks) {
    const actual = fresh.get(check.tag); assert.equal(actual.length, check.expected.length);
    actual.forEach((v, i) => { worst = Math.max(worst, Math.abs(v - check.expected[i])); checkedGlyphs++; if ((v > logitThreshold) !== (check.expected[i] > logitThreshold)) disagreements++; });
  }
  assert.equal(disagreements, 0, 'reused records must agree with the actual export on sampled decisions');
  assert.ok(worst < 0.1, `recorded logits differ from the actual export: ${worst}`);
  const pending = [], rows = [];
  for (const key of keys) {
    const record = recordAt(join(from, key)); record.input.tagger = vocab; record.input.models = outputs.models;
    record.tags = [...new Map([...record.tags, ...fresh]).entries()];
    const host = replayHost(record, image), known = new Map(record.recognitions), requests = new Map();
    const recognise = host.recognise;
    host.recognise = crops => { for (const c of crops) if (!known.has(cropKey(c))) requests.set(cropKey(c), c); return recognise(crops); };
    run(record, host); assert.equal(host.misses.tags, 0, `${key}: no missing tagger outputs`);
    for (const [k, c] of requests) pending.push({ id: `${arg('--to')}|${key}|${k}`, pdf: join(corpus, key, 'paper.pdf'), page: c.page, rect: c.rect });
    const out = join(to, key); saveRecord(out, record); copyFileSync(join(from, key, 'conversion.json'), join(out, 'conversion.json'));
    rows.push({ key, missingCrops: requests.size, pages: record.pages.length });
  }
  save(join(work, 'pending-crops.json'), pending);
  save(join(work, 'audit.json'), { sources, rows, newOrCheckedTagInputs: inputs.length, checks: checks.length, checkedGlyphs, maxReusedLogitError: worst, reusedDecisionDisagreements: disagreements, models: outputs.models, threshold: vocab.threshold });
  console.log(JSON.stringify({ papers: keys.length, missingCrops: pending.length, tagInputs: inputs.length, checkedGlyphs, worst }));
} else if (process.argv[2] === 'finish') {
  const pending = JSON.parse(readFileSync(join(work, 'pending-crops.json')));
  const answers = new Map(readFileSync(arg('--answers'), 'utf8').trim().split('\n').map(l => JSON.parse(l)).filter(r => r.id).map(r => [r.id, { latex: r.latex, probs: r.probs }]));
  const audit = JSON.parse(readFileSync(join(work, 'audit.json')));
  for (const { key } of audit.rows) {
    const dir = join(to, key), record = recordAt(dir);
    for (const job of pending.filter(j => j.id.split('|')[1] === key)) {
      assert.ok(answers.has(job.id), `missing actual recognition ${job.id}`);
      record.recognitions.push([job.id.split('|')[2], answers.get(job.id)]);
    }
    const host = replayHost(record, image); run(record, host);
    assert.deepEqual(host.misses, { tags: 0, crops: 0 }, `${key}: only a complete replay can be scored`);
    saveRecord(dir, record);
  }
  audit.completed = true; audit.answers_sha256 = sha(readFileSync(arg('--answers'))); save(join(work, 'audit.json'), audit);
  console.log(`${audit.rows.length} complete records; zero missing tags/crops`);
} else throw new Error('expected prepare or finish');
