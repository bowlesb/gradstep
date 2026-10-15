#!/usr/bin/env node
// The device route's models for the app and the Mac tool (docs/architecture/DEVICE_PDF_ROUTE.md): compiles the
// exported Core ML packages the model-building agent ships (copied to this Mac per its MAC_AGENT_INSTRUCTIONS.md),
// writes device-models.json (contracts, vocabularies, weight digests) and checks the weights against the committed
// lock, so a build carries exactly the frozen models. The output directory is not committed (hundreds of MB).
//
//   node scripts/device-models.mjs [--from ~/gradstep-mac] [--out apps/apple/DeviceModels] [--update-lock]
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const arg = (name, fallback) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : fallback; };
const FROM = resolve(arg('--from', join(homedir(), 'gradstep-mac')));
const OUT = resolve(ROOT, arg('--out', 'apps/apple/DeviceModels'));
const LOCK = join(ROOT, 'apps/apple/device-models.lock.json');

// Which exports: layout fp16 (91/91 agreement on the Mac; int8 88/91), the int8 recogniser (20/20, half the size),
// the tagger (60/60 lines).
const SOURCES = {
  layout: { dir: 'layout-fcos-v5-coreml', package: 'layout.mlpackage', compiled: 'DeviceLayout.mlmodelc' },
  tagger: { dir: 'inline-tagger-v4-coreml', package: 'tagger.mlpackage', compiled: 'DeviceTagger.mlmodelc' },
  encoder: { dir: 'texteller-ft-v4-coreml-int8', package: 'encoder.mlpackage', compiled: 'DeviceRecogniserEncoder.mlmodelc' },
  decoder: { dir: 'texteller-ft-v4-coreml-int8', package: 'decoder-step.mlpackage', compiled: 'DeviceRecogniserDecoder.mlmodelc' },
};
const sha = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const files = dir => readdirSync(dir, { recursive: true }).map(f => join(dir, String(f))).filter(f => statSync(f).isFile()).sort();
// A package's identity: the digest of its files' digests in path order (weights and spec).
const packageDigest = dir => createHash('sha256').update(files(dir).map(f => `${f.slice(dir.length)}:${sha(f)}`).join('\n')).digest('hex');

const digests = {};
for (const [role, s] of Object.entries(SOURCES)) {
  const pkg = join(FROM, s.dir, s.package);
  if (!existsSync(pkg)) { console.error(`missing ${pkg} (copy the exports per the desktop's docs/MAC_AGENT_INSTRUCTIONS.md)`); process.exit(2); }
  digests[role] = packageDigest(pkg);
}
const lock = existsSync(LOCK) ? JSON.parse(readFileSync(LOCK, 'utf8')) : null;
if (process.argv.includes('--update-lock') || !lock) {
  writeFileSync(LOCK, JSON.stringify({ note: 'Package digests of the device route models (scripts/device-models.mjs). Converter 0.1.0 port kit, 2026-10-14.',
    models: Object.fromEntries(Object.entries(SOURCES).map(([role, s]) => [role, { export: s.dir, package: s.package, sha256: digests[role] }])) }, null, 1) + '\n');
  console.log(`lock written: ${LOCK}`);
} else {
  for (const role of Object.keys(SOURCES)) if (lock.models[role]?.sha256 !== digests[role]) {
    console.error(`${role}: ${digests[role]} is not the locked ${lock.models[role]?.sha256} (run with --update-lock only for a new port kit)`); process.exit(1);
  }
}

rmSync(OUT, { recursive: true, force: true }); mkdirSync(OUT, { recursive: true });
for (const s of Object.values(SOURCES)) {
  const tmp = join(OUT, '.compile'); rmSync(tmp, { recursive: true, force: true }); mkdirSync(tmp);
  execFileSync('xcrun', ['coremlcompiler', 'compile', join(FROM, s.dir, s.package), tmp], { stdio: ['ignore', 'ignore', 'inherit'] });
  const produced = readdirSync(tmp).find(f => f.endsWith('.mlmodelc'));
  cpSync(join(tmp, produced), join(OUT, s.compiled), { recursive: true }); rmSync(tmp, { recursive: true, force: true });
}
const layout = JSON.parse(readFileSync(join(FROM, SOURCES.layout.dir, 'export.json'), 'utf8'));
const recogniser = JSON.parse(readFileSync(join(FROM, SOURCES.encoder.dir, 'export.json'), 'utf8'));
cpSync(join(FROM, SOURCES.tagger.dir, 'vocab.json'), join(OUT, 'tagger-vocab.json'));
cpSync(join(FROM, SOURCES.encoder.dir, 'tokenizer', 'vocab.json'), join(OUT, 'recogniser-vocab.json'));
cpSync(join(FROM, SOURCES.encoder.dir, 'tokenizer', 'added_tokens.json'), join(OUT, 'recogniser-added-tokens.json'));
const model = (role, id) => ({ id, file: SOURCES[role].compiled, weights_sha256: digests[role] });
const config = {
  layout: { model: model('layout', 'layout-fcos-v5'), classes: layout.classes, thresholds: layout.thresholds, nms_iou: layout.nms_iou,
    max_detections: layout.max_detections, canvas_width: layout.canvas.width, canvas_height: layout.canvas.height },
  tagger: { model: model('tagger', 'inline-tagger-v4'), vocabulary: 'tagger-vocab.json' },
  // TexTeller's preprocessing constants (`texteller.py`: IMAGE_MEAN, IMAGE_STD).
  recogniser: { encoder: model('encoder', 'texteller-ft-v4-int8'), decoder: model('decoder', 'texteller-ft-v4-int8'), bos: recogniser.bos,
    eos: recogniser.eos, max_len: recogniser.max_len, image_size: recogniser.image_size, mean: 0.9545467, std: 0.15394445,
    vocabulary: 'recogniser-vocab.json', added_tokens: 'recogniser-added-tokens.json' },
};
writeFileSync(join(OUT, 'device-models.json'), JSON.stringify(config, null, 1) + '\n');
const bytes = files(OUT).reduce((n, f) => n + statSync(f).size, 0);
console.log(`device models ready in ${OUT}: ${(bytes / 1e6).toFixed(1)} MB`);
