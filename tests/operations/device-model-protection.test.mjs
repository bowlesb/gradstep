import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative } from 'node:path';
import test from 'node:test';
import { MODEL_FILES, TEAM_ID, rejectUnprotectedModelCopies, treeSHA, verifyEncryptedTree,
  verifyPackFiles, verifyProtectedPack, verifyQualification } from '../../scripts/device-model-protection.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const save = (path, value) => { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, value); };
const saveJSON = (path, value) => save(path, JSON.stringify(value) + '\n');
// These small envelopes are policy fixtures, not cryptographically valid models. Real encrypted loading has its
// own signed native gate; this suite must never invoke Apple's compiler, Keychain, networking or private models.
const envelope = name => Buffer.concat([Buffer.from('4c4d4e4502000060', 'hex'), Buffer.from(`synthetic:${name}`)]);

function describe(directory, lock) {
  const files = readdirSync(directory, { recursive: true }).map(p => join(directory, String(p)))
    .filter(p => statSync(p).isFile()).map(p => ({ path: relative(directory, p), size: statSync(p).size, sha256: hash(readFileSync(p)) }))
    .sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  return { schema: 'gradstep-device-models-pack-v1', folder: 'DeviceModels', tag: 'device-pdf-models',
    lock: Object.fromEntries(Object.entries(lock.models).map(([role, value]) => [role, value.sha256])), files,
    version: hash(files.map(f => `${f.path}\t${f.size}\t${f.sha256}\n`).join('')) };
}

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'device-model-protection-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const directory = join(root, 'DeviceModels'), lock = { models: {} }, models = {}, receipts = {};
  for (const [role, file] of Object.entries(MODEL_FILES)) {
    const source = hash(`source:${role}`);
    lock.models[role] = role === 'tagger_reference' ? { sha256: hash('reference-manifest'), carrier_sha256: source } : { sha256: source };
    models[role] = { id: `fixture-${role}`, file, weights_sha256: source };
    for (const name of ['coremldata.bin', 'model.mil', 'weights/weight.bin', 'encryptionInfo/coremldata.bin'])
      save(join(directory, file, name), envelope(`${role}:${name}`));
    receipts[role] = { file, source_sha256: source, compiled_sha256: treeSHA(join(directory, file)), method: 'coremlcompiler --encrypt' };
  }
  const config = { layout: { model: models.layout },
    tagger: { model: models.tagger, vocabulary: 'tagger-vocab.json', reference: { manifest: 'tagger-reference.json',
      manifest_sha256: hash('{}\n'), coreml_sha256: models.tagger.weights_sha256, weights_model: models.tagger_reference } },
    recogniser: { encoder: { ...models.recogniser, function: 'prefill' }, decoder: { ...models.recogniser, function: 'step' } },
    protection: { format: 'apple-coreml-encryption-v1', mode: 'encrypted', compiler_version: 'fixture-compiler', models: receipts } };
  saveJSON(join(directory, 'device-models.json'), config);
  for (const file of ['tagger-vocab.json', 'recogniser-vocab.json', 'recogniser-added-tokens.json', 'tagger-reference.json'])
    saveJSON(join(directory, file), {});
  const manifest = describe(directory, lock), trees = Object.fromEntries(Object.entries(receipts).map(([role, r]) => [role, r.compiled_sha256]));
  const qualification = { schema: 'science-reader-coreml-encryption-verification-v1', passed: true, pack_version: manifest.version,
    signature_team: TEAM_ID, signature_verified: true, tool_sha256: hash('signed fixture tool'), compiled_trees: trees,
    runtime: { passed: true, recogniser_available: true, reference_available: true } };
  return { root, directory, lock, config, manifest, trees, qualification,
    refresh() { saveJSON(join(directory, 'device-models.json'), config); return describe(directory, lock); } };
}

test('a complete protected pack binds four compiled trees, source lock and signed runtime qualification', t => {
  const f = fixture(t), result = verifyProtectedPack(f.directory, f.manifest, f.lock);
  assert.deepEqual(result.trees, f.trees);
  assert.equal(verifyQualification(f.qualification, f.manifest, result.trees), true);
  assert.doesNotThrow(() => rejectUnprotectedModelCopies(f.directory));
});

test('changed bytes fail the manifest, and re-describing those bytes still fails the original compiler receipt', t => {
  const f = fixture(t), path = join(f.directory, MODEL_FILES.tagger, 'weights/weight.bin');
  save(path, envelope('different weights'));
  assert.throws(() => verifyPackFiles(f.directory, f.manifest), /pack file differs/);
  const redescribed = describe(f.directory, f.lock);
  assert.throws(() => verifyProtectedPack(f.directory, redescribed, f.lock), /compiler receipt differs: tagger/);
});

test('encryption labels and recomputed hashes cannot bless a plaintext compiled payload', t => {
  const f = fixture(t), path = join(f.directory, MODEL_FILES.tagger, 'weights/weight.bin');
  save(path, 'plaintext learned weights');
  f.config.protection.models.tagger.compiled_sha256 = treeSHA(join(f.directory, MODEL_FILES.tagger));
  assert.throws(() => verifyProtectedPack(f.directory, f.refresh(), f.lock), /unencrypted or unknown/);
});

test('an encryption-looking payload without the Apple envelope record is refused', t => {
  const f = fixture(t);
  rmSync(join(f.directory, MODEL_FILES.layout, 'encryptionInfo'), { recursive: true });
  assert.throws(() => verifyEncryptedTree(join(f.directory, MODEL_FILES.layout)), /missing Apple encryption envelope/);
});

test('unlisted payloads and listed plaintext recovery weights are both refused', t => {
  const f = fixture(t);
  save(join(f.directory, 'tagger-reference.bin'), 'private fixture weights');
  assert.throws(() => verifyProtectedPack(f.directory, f.manifest, f.lock), /unlisted files/);
  assert.throws(() => verifyProtectedPack(f.directory, describe(f.directory, f.lock), f.lock), /unexpected payload/);
  rmSync(join(f.directory, 'tagger-reference.bin'));
  f.config.tagger.reference.weights = 'tagger-reference.bin';
  assert.throws(() => verifyProtectedPack(f.directory, f.refresh(), f.lock), /plaintext reference weights/);
});

test('stale source, incorrect model path or split recognizer package cannot qualify', t => {
  const f = fixture(t), stale = structuredClone(f.lock);
  stale.models.tagger.sha256 = hash('newly selected source');
  assert.throws(() => verifyProtectedPack(f.directory, f.manifest, stale), /source lock differs: tagger/);
  f.config.tagger.model.file = MODEL_FILES.layout;
  assert.throws(() => verifyProtectedPack(f.directory, f.refresh(), f.lock), /source lock differs: tagger/);
  f.config.tagger.model.file = MODEL_FILES.tagger;
  f.config.recogniser.decoder.weights_sha256 = hash('different decoder');
  assert.throws(() => verifyProtectedPack(f.directory, f.refresh(), f.lock), /recognizer functions must use the locked shared-state model/);
});

test('qualification rejects old packs, wrong trees/team, unsigned tools and unavailable recovery or recognizer', t => {
  const f = fixture(t);
  for (const mutate of [
    r => { r.pack_version = hash('old pack'); },
    r => { r.compiled_trees.tagger = hash('old compiled tagger'); },
    r => { r.signature_team = 'OTHERTEAM'; },
    r => { r.signature_verified = false; },
    r => { r.tool_sha256 = 'unsigned'; },
    r => { r.runtime.reference_available = false; },
    r => { r.runtime.recogniser_available = false; },
    r => { r.passed = false; },
  ]) {
    const report = structuredClone(f.qualification); mutate(report);
    assert.throws(() => verifyQualification(report, f.manifest, f.trees), /device model protection/);
  }
  assert.throws(() => verifyQualification(null, f.manifest, f.trees), /verification is required/);
});

test('distribution scanning rejects private keys, source packages and recovery weights outside the declared pack', t => {
  const f = fixture(t), distribution = join(f.root, 'App.app');
  mkdirSync(distribution);
  for (const name of ['Resources/model.mlmodelkey', 'Resources/model.mlmodel', 'Resources/model.mlpackage/Data/weights.bin',
    'Resources/TAGGER-REFERENCE.BIN', 'Other.assetpack/model.mlmodelkey']) {
    const path = join(distribution, name); save(path, 'private fixture');
    assert.throws(() => rejectUnprotectedModelCopies(distribution), /key or source model|raw tagger recovery/);
    rmSync(path);
  }
});

test('a partial compiled-model copy containing only plaintext weights is refused', t => {
  const f = fixture(t), distribution = join(f.root, 'App.app');
  save(join(distribution, 'Resources/Abandoned.mlmodelc/weights/weight.bin'), 'private fixture weights');
  assert.throws(() => rejectUnprotectedModelCopies(distribution), /encryption envelope|unencrypted/);
});

test('model pack symlinks are refused even when they resolve inside the pack', t => {
  const f = fixture(t);
  symlinkSync('tagger-vocab.json', join(f.directory, 'linked-vocab.json'));
  assert.throws(() => verifyPackFiles(f.directory, f.manifest), /symbolic links/);
});

test('internal versioned-framework links are allowed without following them; escaping links are refused', t => {
  const f = fixture(t), distribution = join(f.root, 'App.app'), framework = join(distribution, 'Contents/Frameworks/Fixture.framework');
  save(join(framework, 'Versions/A/Fixture'), 'ordinary framework fixture');
  symlinkSync('A', join(framework, 'Versions/Current'));
  symlinkSync('Versions/Current/Fixture', join(framework, 'Fixture'));
  assert.doesNotThrow(() => rejectUnprotectedModelCopies(distribution));
  symlinkSync(f.directory, join(distribution, 'Contents/ExternalModels'));
  assert.throws(() => rejectUnprotectedModelCopies(distribution), /symbolic link|outside|escape/);
});

test('--describe cannot turn a plaintext research pack into a protected pack', t => {
  const f = fixture(t), out = join(f.root, 'description.json');
  f.config.protection.mode = 'development-plaintext';
  save(join(f.directory, MODEL_FILES.layout, 'weights/weight.bin'), 'plaintext fixture');
  f.refresh();
  execFileSync(process.execPath, [new URL('../../scripts/device-models.mjs', import.meta.url).pathname,
    '--describe', '--out', f.directory, '--manifest', out], { encoding: 'utf8', timeout: 10_000,
    env: { PATH: process.env.PATH, SCIENCE_READER_COREML_KEYS: join(f.root, 'no-private-key-file') } });
  const described = JSON.parse(readFileSync(out, 'utf8'));
  assert.equal(JSON.parse(readFileSync(join(f.directory, 'device-models.json'))).protection.mode, 'development-plaintext');
  assert.throws(() => verifyProtectedPack(f.directory, described, f.lock), /encrypted pack is required/);
});
