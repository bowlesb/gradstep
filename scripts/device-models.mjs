#!/usr/bin/env node
// The device route's models for the app and the Mac tool (docs/architecture/DEVICE_PDF_ROUTE.md): compiles the
// exported Core ML packages (copied to this Mac, read-only, from the desktop), writes device-models.json (contracts,
// vocabularies, weight digests) and checks the weights against the committed lock, so a build carries exactly the
// locked models. The output directory is not committed (hundreds of MB).
//
// Since 2026-10-24 the models are a separate download on iPhone and iPad (DEVICE_PDF_ROUTE.md "The models as a
// download"): the output folder is the pack (an On-Demand Resources tag in the iOS app, inside the app on the Mac), and
// this script also writes the pack's description, apps/apple/DeviceModelsManifest/device-models-pack.json, which ships
// inside the app: every file's size and SHA-256 and a version that is the digest of that list. The app installs a
// download only when every file matches it. The lock stays the single source of truth for which models are built.
//
//   node scripts/device-models.mjs [--from ~/gradstep-mac] [--out apps/apple/DeviceModels] [--update-lock]
//   node scripts/device-models.mjs --describe   (only rewrites the description of an existing output folder)
//
// Sources (each a directory under --from):
// - layout-fcos-v5-coreml (the desktop's port kit, /home/ben/mathpix/data/models; fp16: 91/91 agreement on the Mac)
// - inline-tagger-v5b-journal-coreml (v5a adapted on the private Papers corpus with replay/distillation; 2026-10-26)
// - inline-tagger-v5b-journal-reference (identical checkpoint, independent CPU recovery; 2026-10-27)
// - texteller-ft-v4-mf8-int8 (2026-10-21, docs/reviews/DEVICE_PDF_ROUTE_20261021.md): the port kit's recogniser weights
//   (texteller-ft-v4) exported by scripts/device-pdf-models/export_texteller.py as one multifunction package with a
//   batch of 8: `prefill` (pixels into the shared state) and `step`; int8 weights per channel; 20/20 and 80/80 token
//   agreement with the port kit's export. Built on the desktop in /home/ben/science-reader-device-pdf/exports.
// - texteller-ft-v4-mf8-int8-l512 (2026-10-23, docs/reviews/DEVICE_PDF_ROUTE_20261023.md): the same export with a
//   512-token decoder cache (`--max-len 512`; 20/20 on the samples): recognitions the 256-token cache cut off are read
//   whole, every other one is the same token for token; decoder step +13 % on the Mac's GPU. In the app since then.
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const arg = (name, fallback) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : fallback; };
const FROM = resolve(arg('--from', join(homedir(), 'gradstep-mac')));
const OUT = resolve(ROOT, arg('--out', 'apps/apple/DeviceModels'));
const LOCK = join(ROOT, 'apps/apple/device-models.lock.json');
const MANIFEST = resolve(ROOT, arg('--manifest', 'apps/apple/DeviceModelsManifest/device-models-pack.json'));
// The On-Demand Resources tag the pack is published under (project.yml `resourceTags`) and the folder it unpacks as.
const PACK_TAG = 'device-pdf-models';

const SOURCES = {
  layout: { dir: 'layout-fcos-v5-coreml', package: 'layout.mlpackage', compiled: 'DeviceLayout.mlmodelc' },
  tagger: { dir: 'inline-tagger-v5b-journal-coreml', package: 'tagger.mlpackage', compiled: 'DeviceTagger.mlmodelc' },
  recogniser: { dir: 'texteller-ft-v4-mf8-int8-l512', package: 'recogniser.mlpackage', compiled: 'DeviceRecogniser.mlmodelc' },
};
// Calibrated on source-reviewed journal development labels and all 399 original development papers.
// Pin the runtime policy alongside the weights: changing it changes the pack digest, even with identical model bytes.
const TAGGER_THRESHOLD = 0.65;
const REFERENCE = { dir: 'inline-tagger-v5b-journal-reference', manifest: 'tagger-reference.json', weights: 'tagger-reference.bin' };
const sha = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const files = dir => readdirSync(dir, { recursive: true }).map(f => join(dir, String(f))).filter(f => statSync(f).isFile()).sort();
// A package's identity: the digest of its files' digests in path order (weights and spec).
const packageDigest = dir => createHash('sha256').update(files(dir).map(f => `${f.slice(dir.length)}:${sha(f)}`).join('\n')).digest('hex');

// The pack's description (DevicePDFModelPack.swift): files in path order, version = sha256 of "path\tsize\tsha256\n" lines.
function describe(lockModels) {
  const list = files(OUT).filter(f => !f.endsWith('/.DS_Store')).map(f => ({ path: f.slice(OUT.length + 1), size: statSync(f).size, sha256: sha(f) }))
    .sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const version = createHash('sha256').update(list.map(f => `${f.path}\t${f.size}\t${f.sha256}\n`).join('')).digest('hex');
  const pack = { schema: 'gradstep-device-models-pack-v1', version, tag: PACK_TAG, folder: 'DeviceModels',
    lock: Object.fromEntries(Object.entries(lockModels).map(([role, m]) => [role, m.sha256])), files: list };
  mkdirSync(dirname(MANIFEST), { recursive: true });
  writeFileSync(MANIFEST, JSON.stringify(pack, null, 1) + '\n');
  const bytes = list.reduce((n, f) => n + f.size, 0);
  console.log(`pack ${version.slice(0, 12)}: ${list.length} files, ${(bytes / 1e6).toFixed(1)} MB; description ${MANIFEST}`);
}
if (process.argv.includes('--describe')) {
  if (!existsSync(join(OUT, 'device-models.json'))) { console.error(`no models in ${OUT}`); process.exit(2); }
  describe(JSON.parse(readFileSync(LOCK, 'utf8')).models);
  process.exit(0);
}

const digests = {};
for (const [role, s] of Object.entries(SOURCES)) {
  const pkg = join(FROM, s.dir, s.package);
  if (!existsSync(pkg)) { console.error(`missing ${pkg} (copy the exports to this Mac; see the sources above)`); process.exit(2); }
  digests[role] = packageDigest(pkg);
}
const referenceManifest = join(FROM, REFERENCE.dir, REFERENCE.manifest), referenceWeights = join(FROM, REFERENCE.dir, REFERENCE.weights);
if (!existsSync(referenceManifest) || !existsSync(referenceWeights)) throw Error('missing independent tagger reference export; see training/device_pdf/README.md');
const reference = JSON.parse(readFileSync(referenceManifest, 'utf8'));
const taggerExport = JSON.parse(readFileSync(join(FROM, SOURCES.tagger.dir, 'export.json'), 'utf8'));
if (reference.format !== 'device-pdf-tagger-reference-v1' || reference.binary_sha256 !== sha(referenceWeights) ||
    reference.checkpoint_sha256 !== taggerExport.checkpoint_sha256) throw Error('reference tagger must match the selected Core ML checkpoint');
const referenceLock = { export: REFERENCE.dir, manifest: REFERENCE.manifest, weights: REFERENCE.weights,
  sha256: sha(referenceManifest), binary_sha256: reference.binary_sha256, checkpoint_sha256: reference.checkpoint_sha256 };
const lock = existsSync(LOCK) ? JSON.parse(readFileSync(LOCK, 'utf8')) : null;
if (process.argv.includes('--update-lock') || !lock) {
  writeFileSync(LOCK, JSON.stringify({ note: 'Package digests of the device route models (scripts/device-models.mjs). Layout: converter 0.1.0 port kit; tagger: v5b journal adaptation with replay/distillation, 2026-10-26; recogniser: texteller-ft-v4 batched multifunction, 512-token cache, 2026-10-23.',
    models: { ...Object.fromEntries(Object.entries(SOURCES).map(([role, s]) => [role, { export: s.dir, package: s.package, sha256: digests[role], ...(role === 'tagger' ? { threshold: TAGGER_THRESHOLD } : {}) }])),
      tagger_reference: referenceLock } }, null, 1) + '\n');
  console.log(`lock written: ${LOCK}`);
} else {
  for (const role of Object.keys(SOURCES)) if (lock.models[role]?.sha256 !== digests[role]) {
    console.error(`${role}: ${digests[role]} is not the locked ${lock.models[role]?.sha256} (run with --update-lock only for new models)`); process.exit(1);
  }
  if (lock.models.tagger.threshold !== TAGGER_THRESHOLD) { console.error('tagger threshold differs from the lock'); process.exit(1); }
  if (JSON.stringify(lock.models.tagger_reference) !== JSON.stringify(referenceLock)) throw Error('reference tagger differs from the lock');
}

rmSync(OUT, { recursive: true, force: true }); mkdirSync(OUT, { recursive: true });
for (const s of Object.values(SOURCES)) {
  const tmp = join(OUT, '.compile'); rmSync(tmp, { recursive: true, force: true }); mkdirSync(tmp);
  execFileSync('xcrun', ['coremlcompiler', 'compile', join(FROM, s.dir, s.package), tmp], { stdio: ['ignore', 'ignore', 'inherit'] });
  const produced = readdirSync(tmp).find(f => f.endsWith('.mlmodelc'));
  cpSync(join(tmp, produced), join(OUT, s.compiled), { recursive: true }); rmSync(tmp, { recursive: true, force: true });
}
const layout = JSON.parse(readFileSync(join(FROM, SOURCES.layout.dir, 'export.json'), 'utf8'));
const recogniser = JSON.parse(readFileSync(join(FROM, SOURCES.recogniser.dir, 'export.json'), 'utf8'));
if (recogniser.protocol !== 'multifunction') { console.error('the recogniser export must be the multifunction protocol'); process.exit(2); }
const taggerVocabulary = JSON.parse(readFileSync(join(FROM, SOURCES.tagger.dir, 'vocab.json'), 'utf8'));
writeFileSync(join(OUT, 'tagger-vocab.json'), JSON.stringify({ ...taggerVocabulary, threshold: TAGGER_THRESHOLD }, null, 1) + '\n');
if (reference.vocabulary_sha256 !== sha(join(OUT, 'tagger-vocab.json'))) throw Error('reference tagger vocabulary differs from the selected app vocabulary');
cpSync(referenceManifest, join(OUT, REFERENCE.manifest));
cpSync(referenceWeights, join(OUT, REFERENCE.weights));
cpSync(join(FROM, SOURCES.recogniser.dir, 'tokenizer', 'vocab.json'), join(OUT, 'recogniser-vocab.json'));
cpSync(join(FROM, SOURCES.recogniser.dir, 'tokenizer', 'added_tokens.json'), join(OUT, 'recogniser-added-tokens.json'));
const model = (role, id, extra = {}) => ({ id, file: SOURCES[role].compiled, weights_sha256: digests[role], ...extra });
const config = {
  layout: { model: model('layout', 'layout-fcos-v5'), classes: layout.classes, thresholds: layout.thresholds, nms_iou: layout.nms_iou,
    max_detections: layout.max_detections, canvas_width: layout.canvas.width, canvas_height: layout.canvas.height },
  tagger: { model: model('tagger', 'inline-tagger-v5b-journal'), vocabulary: 'tagger-vocab.json',
    reference: { manifest: REFERENCE.manifest, weights: REFERENCE.weights, manifest_sha256: sha(referenceManifest), coreml_sha256: digests.tagger } },
  // TexTeller's preprocessing constants (`texteller.py`: IMAGE_MEAN, IMAGE_STD). The encoder and decoder are the
  // package's two functions; the app loads each by name and passes one state between them.
  recogniser: { encoder: model('recogniser', SOURCES.recogniser.dir, { function: 'prefill' }),
    decoder: model('recogniser', SOURCES.recogniser.dir, { function: 'step' }), bos: recogniser.bos,
    eos: recogniser.eos, max_len: recogniser.max_len, image_size: recogniser.image_size, mean: 0.9545467, std: 0.15394445,
    vocabulary: 'recogniser-vocab.json', added_tokens: 'recogniser-added-tokens.json' },
};
writeFileSync(join(OUT, 'device-models.json'), JSON.stringify(config, null, 1) + '\n');
const bytes = files(OUT).reduce((n, f) => n + statSync(f).size, 0);
console.log(`device models ready in ${OUT}: ${(bytes / 1e6).toFixed(1)} MB`);
describe(JSON.parse(readFileSync(LOCK, 'utf8')).models);
