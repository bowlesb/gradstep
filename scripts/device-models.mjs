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
//   node scripts/device-models.mjs --require-encryption [--encryption-keys /private/path/keys.json]
//   node scripts/device-models.mjs --development-plaintext   (local research only; release gate rejects it)
//   Optional: --from ~/gradstep-mac --out apps/apple/DeviceModels --manifest PATH --update-lock
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
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync, realpathSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, resolve, relative, sep } from 'node:path';
import { MODEL_FILES, TEAM_ID, verifyEncryptedTree, treeSHA } from './device-model-protection.mjs';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const arg = (name, fallback) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : fallback; };
const FROM = resolve(arg('--from', join(homedir(), 'gradstep-mac')));
const DESTINATION = resolve(ROOT, arg('--out', 'apps/apple/DeviceModels'));
let OUT = DESTINATION;
const LOCK = join(ROOT, 'apps/apple/device-models.lock.json');
const MANIFEST = resolve(ROOT, arg('--manifest', 'apps/apple/DeviceModelsManifest/device-models-pack.json'));
// The On-Demand Resources tag the pack is published under (project.yml `resourceTags`) and the folder it unpacks as.
const PACK_TAG = 'device-pdf-models';

const SOURCES = {
  layout: { dir: 'layout-fcos-v5-coreml', package: 'layout.mlpackage', compiled: 'DeviceLayout.mlmodelc' },
  tagger: { dir: 'inline-tagger-v5b-journal-coreml', package: 'tagger.mlpackage', compiled: 'DeviceTagger.mlmodelc' },
  recogniser: { dir: 'texteller-ft-v4-mf8-int8-l512', package: 'recogniser.mlpackage', compiled: MODEL_FILES.recogniser },
};
const RECOGNISER = SOURCES.recogniser;
// Calibrated on source-reviewed journal development labels and all 399 original development papers.
// Pin the runtime policy alongside the weights: changing it changes the pack digest, even with identical model bytes.
const TAGGER_THRESHOLD = 0.65;
const REFERENCE = { dir: 'inline-tagger-v5b-journal-reference', manifest: 'tagger-reference.json', weights: 'tagger-reference.bin' };
const CARRIER = { dir: 'inline-tagger-v5b-journal-reference-carrier', package: 'tagger-reference-carrier.mlpackage', compiled: MODEL_FILES.tagger_reference };
const plaintext = process.argv.includes('--development-plaintext');
if (plaintext && process.argv.includes('--require-encryption')) throw Error('conflicting encryption modes');
const keysFile = resolve(arg('--encryption-keys', process.env.SCIENCE_READER_COREML_KEYS ?? join(homedir(), '.config/science-reader/coreml-encryption/keys.json')));
const sha = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const files = dir => readdirSync(dir, { recursive: true }).map(f => join(dir, String(f))).filter(f => statSync(f).isFile()).sort();
// A package's identity: the digest of its files' digests in path order (weights and spec).
const packageDigest = dir => createHash('sha256').update(files(dir).map(f => `${f.slice(dir.length)}:${sha(f)}`).join('\n')).digest('hex');

// The pack's description (DevicePDFModelPack.swift): files in path order, version = sha256 of "path\tsize\tsha256\n" lines.
function description(lockModels) {
  const list = files(OUT).filter(f => !f.endsWith('/.DS_Store')).map(f => ({ path: f.slice(OUT.length + 1), size: statSync(f).size, sha256: sha(f) }))
    .sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const version = createHash('sha256').update(list.map(f => `${f.path}\t${f.size}\t${f.sha256}\n`).join('')).digest('hex');
  const pack = { schema: 'gradstep-device-models-pack-v1', version, tag: PACK_TAG, folder: 'DeviceModels',
    lock: Object.fromEntries(Object.entries(lockModels).map(([role, m]) => [role, m.sha256])), files: list };
  return pack;
}
function describe(lockModels) {
  const pack = description(lockModels);
  mkdirSync(dirname(MANIFEST), { recursive: true });
  writeFileSync(MANIFEST + '.pending', JSON.stringify(pack, null, 1) + '\n');
  renameSync(MANIFEST + '.pending', MANIFEST);
  console.log(`pack ${pack.version.slice(0, 12)}: ${pack.files.length} files; description ${MANIFEST}`);
}
if (process.argv.includes('--describe')) {
  if (!existsSync(join(OUT, 'device-models.json'))) { console.error(`no models in ${OUT}`); process.exit(2); }
  // Re-describing files does not grant encryption qualification; release gates inspect the actual compiled trees.
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
// Check every source, key and vocabulary before replacing an existing generated pack.
const carrierPackage = join(FROM, CARRIER.dir, CARRIER.package);
const carrier = JSON.parse(readFileSync(join(FROM, CARRIER.dir, 'export.json'), 'utf8'));
const carrierSHA = packageDigest(carrierPackage);
if (carrier.format !== 'device-pdf-tagger-reference-carrier-v1' || carrier.package_sha256 !== carrierSHA ||
    carrier.source_manifest_sha256 !== sha(referenceManifest) || carrier.binary_sha256 !== reference.binary_sha256 ||
    carrier.checkpoint_sha256 !== reference.checkpoint_sha256 || carrier.vocabulary_sha256 !== reference.vocabulary_sha256)
  throw Error('reference carrier differs from the pinned reference export');
const referenceLock = { export: REFERENCE.dir, manifest: REFERENCE.manifest, weights: REFERENCE.weights,
  sha256: sha(referenceManifest), binary_sha256: reference.binary_sha256, checkpoint_sha256: reference.checkpoint_sha256,
  carrier_export: CARRIER.dir, carrier_package: CARRIER.package, carrier_sha256: carrierSHA };
const nextLock = { note: 'Source digests of the device route models. Same v5b-journal/layout-v5/TexTeller-v4 weights; exact-weight recovery carrier. Encrypted compiled artifacts are verified separately.',
  models: { ...Object.fromEntries(Object.entries(SOURCES).map(([role, s]) => [role, { export: s.dir, package: s.package,
    sha256: digests[role], ...(role === 'tagger' ? { threshold: TAGGER_THRESHOLD } : {}) }])), tagger_reference: referenceLock } };
const lock = existsSync(LOCK) ? JSON.parse(readFileSync(LOCK, 'utf8')) : null;
if (!process.argv.includes('--update-lock')) {
  if (!lock) throw Error('missing model lock; do not create it implicitly');
  for (const role of Object.keys(SOURCES)) if (lock.models[role]?.sha256 !== digests[role]) throw Error(`${role}: source differs from lock`);
  if (lock.models.tagger.threshold !== TAGGER_THRESHOLD || JSON.stringify(lock.models.tagger_reference) !== JSON.stringify(referenceLock))
    throw Error('reference carrier or threshold differs from lock; verify the export before --update-lock');
}
const layout = JSON.parse(readFileSync(join(FROM, SOURCES.layout.dir, 'export.json'), 'utf8'));
const recogniser = JSON.parse(readFileSync(join(FROM, RECOGNISER.dir, 'export.json'), 'utf8'));
if (recogniser.protocol !== 'multifunction') throw Error('recognizer must use the multifunction protocol');
const taggerVocabulary = JSON.parse(readFileSync(join(FROM, SOURCES.tagger.dir, 'vocab.json'), 'utf8'));
const vocabularyBytes = JSON.stringify({ ...taggerVocabulary, threshold: TAGGER_THRESHOLD }, null, 1) + '\n';
if (reference.vocabulary_sha256 !== createHash('sha256').update(vocabularyBytes).digest('hex')) throw Error('reference vocabulary differs from app vocabulary');
const keys = {};
if (!plaintext) {
  if (!existsSync(keysFile)) throw Error('Apple model keys are required. Configure SCIENCE_READER_COREML_KEYS, or use --development-plaintext for local research only.');
  const record = JSON.parse(readFileSync(keysFile, 'utf8'));
  if (record.team_id !== TEAM_ID) throw Error('model keys must belong to the app signing team');
  for (const role of Object.keys(MODEL_FILES)) {
    const value = record.keys?.[role];
    if (typeof value !== 'string' || !isAbsolute(value) || !value.endsWith('.mlmodelkey')) throw Error(`missing private model key: ${role}`);
    const key = realpathSync(value), rel = relative(ROOT, key), stat = statSync(key);
    if ((!(rel === '..' || rel.startsWith(`..${sep}`)) && !isAbsolute(rel)) || !stat.isFile() || stat.size === 0 || (stat.mode & 0o077) !== 0)
      throw Error(`model key must be a private file outside the checkout: ${role}`);
    keys[role] = key;
  }
}
const boundInputs = [referenceManifest, referenceWeights, join(FROM, CARRIER.dir, 'export.json'),
  ...Object.values(SOURCES).map(s => join(FROM, s.dir, 'export.json')), join(FROM, RECOGNISER.dir, 'export.json'), join(FROM, SOURCES.tagger.dir, 'vocab.json'),
  join(FROM, RECOGNISER.dir, 'tokenizer/vocab.json'), join(FROM, RECOGNISER.dir, 'tokenizer/added_tokens.json'),
  ...(existsSync(LOCK) ? [LOCK] : []), ...(!plaintext ? [keysFile, ...new Set(Object.values(keys))] : [])];
const frozenInputs = new Map(boundInputs.map(path => [path, sha(path)]));
mkdirSync(dirname(DESTINATION), { recursive: true });
OUT = mkdtempSync(join(dirname(DESTINATION), '.device-models-build-'));
let promoted = false;
try {
const compiled = { ...SOURCES, tagger_reference: CARRIER };
const protection = { format: 'apple-coreml-encryption-v1', mode: plaintext ? 'development-plaintext' : 'encrypted',
  compiler_version: execFileSync('xcrun', ['coremlcompiler', 'version'], { encoding: 'utf8' }).trim(), models: {} };
for (const [role, s] of Object.entries(compiled)) {
  const tmp = join(OUT, '.compile'); mkdirSync(tmp);
  const args = ['coremlcompiler', 'compile', join(FROM, s.dir, s.package), tmp, ...(!plaintext ? ['--encrypt', keys[role]] : [])];
  // Never capture a key's contents or copy it into build output. Errors remain local compiler diagnostics.
  execFileSync('xcrun', args, { stdio: ['ignore', 'ignore', 'inherit'] });
  const produced = readdirSync(tmp).find(f => f.endsWith('.mlmodelc'));
  if (!produced) throw Error(`compiler did not produce ${role}`);
  cpSync(join(tmp, produced), join(OUT, s.compiled), { recursive: true }); rmSync(tmp, { recursive: true });
  protection.models[role] = { file: s.compiled, source_sha256: role === 'tagger_reference' ? carrierSHA : digests[role],
    compiled_sha256: plaintext ? treeSHA(join(OUT, s.compiled)) : verifyEncryptedTree(join(OUT, s.compiled)),
    method: plaintext ? 'coremlcompiler compile' : 'coremlcompiler --encrypt' };
}
writeFileSync(join(OUT, 'tagger-vocab.json'), vocabularyBytes);
cpSync(referenceManifest, join(OUT, REFERENCE.manifest));
// Recovery weights are delivered only in the carrier, including development packs; no plaintext .bin copy.
cpSync(join(FROM, RECOGNISER.dir, 'tokenizer', 'vocab.json'), join(OUT, 'recogniser-vocab.json'));
cpSync(join(FROM, RECOGNISER.dir, 'tokenizer', 'added_tokens.json'), join(OUT, 'recogniser-added-tokens.json'));
const model = (role, id, extra = {}) => ({ id, file: SOURCES[role].compiled, weights_sha256: digests[role], ...extra });
const config = {
  protection,
  layout: { model: model('layout', 'layout-fcos-v5'), classes: layout.classes, thresholds: layout.thresholds, nms_iou: layout.nms_iou,
    max_detections: layout.max_detections, canvas_width: layout.canvas.width, canvas_height: layout.canvas.height },
  tagger: { model: model('tagger', 'inline-tagger-v5b-journal'), vocabulary: 'tagger-vocab.json',
    reference: { manifest: REFERENCE.manifest, manifest_sha256: sha(referenceManifest), coreml_sha256: digests.tagger,
      weights_model: { id: 'inline-tagger-v5b-journal-reference-carrier', file: CARRIER.compiled, weights_sha256: carrierSHA } } },
  // Keep the qualified learned-model selection. Encrypted runtime qualification currently fails for this stateful
  // package; the release gate must remain closed until a compatible representation passes quality and resource gates.
  recogniser: { encoder: model('recogniser', 'texteller-ft-v4-mf8-int8-l512', { function: 'prefill' }),
    decoder: model('recogniser', 'texteller-ft-v4-mf8-int8-l512', { function: 'step' }), bos: recogniser.bos,
    eos: recogniser.eos, max_len: recogniser.max_len, image_size: recogniser.image_size, mean: 0.9545467, std: 0.15394445,
    vocabulary: 'recogniser-vocab.json', added_tokens: 'recogniser-added-tokens.json' },
};
writeFileSync(join(OUT, 'device-models.json'), JSON.stringify(config, null, 1) + '\n');
const bytes = files(OUT).reduce((n, f) => n + statSync(f).size, 0);
for (const [path, digest] of frozenInputs) if (sha(path) !== digest) throw Error('a build input changed during compilation');
for (const [role, source] of Object.entries(compiled)) {
  const expected = role === 'tagger_reference' ? carrierSHA : digests[role];
  if (packageDigest(join(FROM, source.dir, source.package)) !== expected) throw Error('source model changed during compilation');
}
const pack = description(nextLock.models);
const previous = `${DESTINATION}.previous-build`;
if (existsSync(previous)) throw Error('previous pack backup exists; inspect it before rebuilding');
mkdirSync(dirname(MANIFEST), { recursive: true });
const oldManifest = existsSync(MANIFEST) ? readFileSync(MANIFEST) : null;
const oldLock = existsSync(LOCK) ? readFileSync(LOCK) : null;
const pendingManifest = `${MANIFEST}.pending-${process.pid}`, pendingLock = `${LOCK}.pending-${process.pid}`;
let swapped = false;
try {
  // Prepare metadata before touching the selected pack; roll all three back on any synchronous publication failure.
  writeFileSync(pendingManifest, JSON.stringify(pack, null, 1) + '\n');
  if (process.argv.includes('--update-lock')) writeFileSync(pendingLock, JSON.stringify(nextLock, null, 1) + '\n');
  if (existsSync(DESTINATION)) renameSync(DESTINATION, previous);
  try { renameSync(OUT, DESTINATION); swapped = true; } catch (error) { if (existsSync(previous)) renameSync(previous, DESTINATION); throw error; }
  if (process.argv.includes('--update-lock')) renameSync(pendingLock, LOCK);
  renameSync(pendingManifest, MANIFEST);
  promoted = true;
} catch (error) {
  if (swapped) {
    rmSync(DESTINATION, { recursive: true, force: true });
    if (existsSync(previous)) renameSync(previous, DESTINATION);
    if (oldManifest) writeFileSync(MANIFEST, oldManifest); else rmSync(MANIFEST, { force: true });
    if (oldLock) writeFileSync(LOCK, oldLock); else rmSync(LOCK, { force: true });
  }
  throw error;
} finally { rmSync(pendingManifest, { force: true }); rmSync(pendingLock, { force: true }); }
OUT = DESTINATION;
rmSync(previous, { recursive: true, force: true });
console.log(`pack ${pack.version.slice(0, 12)}: ${pack.files.length} files; device models ready (${protection.mode}), ${(bytes / 1e6).toFixed(1)} MB`);
} finally { if (!promoted) rmSync(OUT, { recursive: true, force: true }); }
