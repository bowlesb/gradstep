import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative } from 'node:path';
import test from 'node:test';
import { rejectUnprotectedModelCopies } from '../../scripts/device-model-protection.mjs';
import { findReshipSource, packFolders, shippedPack, shippedPlaintextTrees, verifyReshipDescription,
  verifyReshipSource } from '../../scripts/device-model-reship.mjs';

// Policy fixtures for the reship rule (JUDGMENT_LOG 56): only a pack TestFlight already shipped, byte for byte, may
// skip encryption. Never invokes Apple's compiler, Core ML, signing or private models.
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const save = (path, value) => { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, value); };
const SCRIPT = new URL('../../scripts/device-models.mjs', import.meta.url).pathname;
const RECORD = new URL('../../apps/apple/device-models-shipped.json', import.meta.url).pathname;
const LOCK = new URL('../../apps/apple/device-models.lock.json', import.meta.url).pathname;

function describe(directory, lock) {
  const files = readdirSync(directory, { recursive: true }).map(p => join(directory, String(p)))
    .filter(p => statSync(p).isFile()).map(p => ({ path: relative(directory, p), size: statSync(p).size, sha256: hash(readFileSync(p)) }))
    .sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  return { schema: 'gradstep-device-models-pack-v1', version: hash(files.map(f => `${f.path}\t${f.size}\t${f.sha256}\n`).join('')),
    tag: 'device-pdf-models', folder: 'DeviceModels', lock, files };
}

// An iOS-shaped archive whose asset pack holds a plaintext pack, plus a record naming exactly that pack.
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'device-model-reship-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const archive = join(root, 'Paperstep-93.xcarchive'), pack = join(archive, 'Products/OnDemandResources/x.assetpack/DeviceModels');
  for (const model of ['DeviceLayout', 'DeviceTagger', 'DeviceRecogniser'])
    for (const name of ['coremldata.bin', 'model.mil', 'weights/weight.bin']) save(join(pack, `${model}.mlmodelc`, name), `plaintext ${model} ${name}`);
  for (const name of ['device-models.json', 'tagger-vocab.json', 'recogniser-vocab.json', 'recogniser-added-tokens.json']) save(join(pack, name), `{"${name}":1}\n`);
  const description = describe(pack, { layout: hash('layout'), tagger: hash('tagger-v4'), recogniser: hash('recogniser') });
  const entry = { builds: { ios: 93, mac: 93 }, commit: hash('commit').slice(0, 40), protection: 'plaintext',
    sources: [relative(root, archive)], description };
  const record = { schema: 'gradstep-device-models-shipped-v1', packs: [entry] };
  const recordPath = join(root, 'shipped.json');
  writeFileSync(recordPath, JSON.stringify(record, null, 1) + '\n');
  return { root, archive, pack, description, entry, record, recordPath };
}

test('a recorded pack is found by its full version and its exact bytes verify from an archive', t => {
  const f = fixture(t), entry = shippedPack(f.record, f.description.version);
  assert.equal(entry, f.entry);
  assert.deepEqual(packFolders(f.archive), [f.pack]);
  assert.equal(findReshipSource(f.root, entry), f.pack, 'defaults to the archive the record names');
  assert.equal(findReshipSource(f.root, entry, f.archive), f.pack);
  assert.equal(verifyReshipDescription(structuredClone(f.description), entry), true);
});

test('an unrecorded, abbreviated or malformed version is refused: new packs still need encryption', t => {
  const f = fixture(t);
  assert.throws(() => shippedPack(f.record, hash('a new pack')), /never recorded as shipped; a new pack must be built with --require-encryption/);
  for (const version of [f.description.version.slice(0, 12), f.description.version.toUpperCase(), undefined, '', '--reship-from'])
    assert.throws(() => shippedPack(f.record, version), /full 64-character version/);
  assert.throws(() => shippedPack({ packs: [] }, f.description.version), /unreadable shipped-pack record/);
});

test('a record whose file list does not hash to its version, or lacks its build, cannot authorize anything', t => {
  const f = fixture(t), tampered = structuredClone(f.record);
  tampered.packs[0].description.files[0].sha256 = hash('swapped weights');
  assert.throws(() => shippedPack(tampered, f.description.version), /does not hash to its version/);
  const unbuilt = structuredClone(f.record); delete unbuilt.packs[0].builds;
  assert.throws(() => shippedPack(unbuilt, f.description.version), /lacks the build and commit/);
  const duplicated = structuredClone(f.record); duplicated.packs.push(structuredClone(f.entry));
  assert.throws(() => shippedPack(duplicated, f.description.version), /recorded more than once/);
});

test('changed, missing, extra or linked files in the source are refused, and no rebuild is offered as a substitute', t => {
  const f = fixture(t), entry = shippedPack(f.record, f.description.version);
  const weight = join(f.pack, 'DeviceTagger.mlmodelc/weights/weight.bin');
  save(weight, 'plaintext DeviceTagger weights/weight.bin, retrained');
  assert.throws(() => verifyReshipSource(f.pack, entry), /pack file differs/);
  assert.throws(() => findReshipSource(f.root, entry), /no source holds the recorded bytes[\s\S]*rebuild cannot reproduce/);
  save(weight, 'plaintext DeviceTagger weights/weight.bin');
  assert.equal(verifyReshipSource(f.pack, entry), f.pack);
  save(join(f.pack, 'tagger-reference.bin'), 'new recovery weights');
  assert.throws(() => verifyReshipSource(f.pack, entry), /unlisted files/);
  rmSync(join(f.pack, 'tagger-reference.bin'));
  symlinkSync('tagger-vocab.json', join(f.pack, 'linked.json'));
  assert.throws(() => verifyReshipSource(f.pack, entry), /symbolic links/);
  rmSync(join(f.pack, 'linked.json'));
  rmSync(join(f.pack, 'tagger-vocab.json'));
  assert.throws(() => verifyReshipSource(f.pack, entry), /ENOENT|pack file differs/);
});

test('the written description must be the recorded one field for field', t => {
  const f = fixture(t), entry = shippedPack(f.record, f.description.version);
  for (const mutate of [d => { d.lock.tagger = hash('tagger-v5b'); }, d => { d.tag = 'other'; }, d => { d.files.pop(); }]) {
    const changed = structuredClone(f.description); mutate(changed);
    assert.throws(() => verifyReshipDescription(changed, entry), /not the recorded shipped one/);
  }
});

test('distribution scan: only the recorded plaintext trees pass; keys, sources, raw weights and other plaintext stay refused', t => {
  const f = fixture(t), entry = shippedPack(f.record, f.description.version), allowPlaintext = shippedPlaintextTrees(entry);
  assert.throws(() => rejectUnprotectedModelCopies(f.archive), /encryption envelope|unencrypted/, 'the encryption rule is unchanged by default');
  assert.doesNotThrow(() => rejectUnprotectedModelCopies(f.archive, { allowPlaintext }));
  const extra = join(f.pack, 'DeviceTaggerReference.mlmodelc/weights/weight.bin');
  save(extra, 'unrecorded plaintext carrier');
  assert.throws(() => rejectUnprotectedModelCopies(f.archive, { allowPlaintext }), /encryption envelope|unencrypted/);
  rmSync(dirname(dirname(extra)), { recursive: true });
  const elsewhere = join(f.archive, 'Products/Applications/ScienceReader.app/DeviceTagger.mlmodelc/model.mil');
  save(elsewhere, 'plaintext DeviceTagger model.mil');
  assert.throws(() => rejectUnprotectedModelCopies(f.archive, { allowPlaintext }), /encryption envelope|unencrypted/, 'only inside DeviceModels');
  rmSync(dirname(elsewhere), { recursive: true });
  save(join(f.pack, 'DeviceLayout.mlmodelc/model.mil'), 'changed layout');
  assert.throws(() => rejectUnprotectedModelCopies(f.archive, { allowPlaintext }), /DeviceLayout\.mlmodelc differs from the recorded shipped pack/);
  save(join(f.pack, 'DeviceLayout.mlmodelc/model.mil'), 'plaintext DeviceLayout model.mil');
  for (const [name, created] of [['Products/Applications/ScienceReader.app/model.mlmodelkey', 'Products/Applications/ScienceReader.app/model.mlmodelkey'],
    ['Products/x.mlpackage/Data/weights.bin', 'Products/x.mlpackage'],
    ['Products/OnDemandResources/x.assetpack/tagger-reference.bin', 'Products/OnDemandResources/x.assetpack/tagger-reference.bin']]) {
    save(join(f.archive, name), 'private');
    assert.throws(() => rejectUnprotectedModelCopies(f.archive, { allowPlaintext }), /key or source model|raw tagger recovery/);
    rmSync(join(f.archive, created), { recursive: true });
  }
  assert.doesNotThrow(() => rejectUnprotectedModelCopies(f.archive, { allowPlaintext }));
});

test('device-models.mjs --reship-pack copies exactly the recorded bytes, writes the recorded description, and fails closed', t => {
  const f = fixture(t), out = join(f.root, 'apps/DeviceModels'), manifest = join(f.root, 'apps/DeviceModelsManifest/pack.json');
  const run = (...extra) => spawnSync(process.execPath, [SCRIPT, '--shipped-record', f.recordPath, '--out', out, '--manifest', manifest, ...extra],
    { encoding: 'utf8', timeout: 20_000, env: { PATH: process.env.PATH } });
  save(join(out, 'previous.txt'), 'the selected development pack');
  const changed = join(f.pack, 'recogniser-vocab.json');
  save(changed, '{"changed":1}\n');
  let result = run('--reship-pack', f.description.version, '--reship-from', f.archive);
  assert.notEqual(result.status, 0); assert.match(result.stderr, /no source holds the recorded bytes/);
  assert.equal(readFileSync(join(out, 'previous.txt'), 'utf8'), 'the selected development pack', 'failure keeps the previous pack');
  save(changed, '{"recogniser-vocab.json":1}\n');
  result = run('--reship-pack', f.description.version, '--reship-from', f.archive);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /reshipped unchanged from TestFlight 93 \(plaintext/);
  assert.deepEqual(JSON.parse(readFileSync(manifest, 'utf8')), f.description);
  assert.deepEqual(describe(out, f.description.lock), f.description, 'byte-identical files, nothing else');
  for (const [extra, message] of [
    [['--reship-pack', hash('unrecorded')], /never recorded as shipped/],
    [['--reship-pack'], /full 64-character version/],
    [['--reship-pack', f.description.version, '--require-encryption'], /cannot be combined/],
    [['--reship-pack', f.description.version, '--development-plaintext'], /cannot be combined/],
    [['--reship-pack', f.description.version, '--update-lock'], /cannot be combined/],
  ]) {
    result = run(...extra);
    assert.notEqual(result.status, 0); assert.match(result.stderr, message);
  }
  assert.deepEqual(describe(out, f.description.lock), f.description, 'refused runs leave the reshipped pack alone');
});

test('the repository record names only TestFlight 93\'s pack; the current lock\'s models are not recorded', () => {
  const record = JSON.parse(readFileSync(RECORD, 'utf8')), lock = JSON.parse(readFileSync(LOCK, 'utf8'));
  const version = '28f6fd14e8beec14bbb21207ae05b94960c76db65c9562605ca92ff80493b195';
  const entry = shippedPack(record, version);
  assert.deepEqual(entry.builds, { ios: 93, mac: 93 });
  assert.equal(entry.commit, '1c87b2af4bf9b97f8a780b1dd4dede33cc192bb9');
  assert.equal(entry.description.lock.tagger, '516064d074f540bf1cb700a4fd52bbeacdeb6e5cf975c3c459ca5b4d8ff72121', 'inline-tagger-v4');
  assert.equal(record.packs.length, 1);
  assert.ok(!entry.description.files.some(f => /TaggerReference|tagger-reference/.test(f.path)), 'no recovery weights in the reshipped pack');
  for (const p of record.packs) assert.notEqual(p.description.lock.tagger, lock.models.tagger.sha256, 'the unshipped v5b tagger still needs encryption');
});

test('both upload scripts skip the signed encryption verification only behind RESHIP_DEVICE_PACK', () => {
  for (const name of ['upload-testflight.sh', 'upload-testflight-mac.sh']) {
    const script = readFileSync(new URL(`../../scripts/${name}`, import.meta.url), 'utf8');
    const reship = script.indexOf('if [ -n "${RESHIP_DEVICE_PACK:-}" ]; then'), otherwise = script.indexOf('\nelse\n', reship);
    const done = script.indexOf('\nfi\n', otherwise);
    assert.ok(reship > 0 && otherwise > reship && done > otherwise, name);
    const branch = script.slice(reship, otherwise), encrypted = script.slice(otherwise, done);
    assert.match(branch, /device-models\.mjs --reship-pack "\$RESHIP_DEVICE_PACK"/);
    assert.doesNotMatch(branch, /--development-plaintext|verify-coreml-encryption/);
    assert.match(encrypted, /device-models\.mjs --require-encryption/);
    assert.match(encrypted, /verify-coreml-encryption\.mjs --tool/);
    assert.match(script, /check-device-model-pack\.mjs (--mac )?\$PACK_MODE "\$ARCHIVE"/);
    const prepareOnly = script.indexOf('if [ "${PREPARE_ONLY:-}" = 1 ]');
    assert.ok(prepareOnly > done && prepareOnly < script.indexOf('. ./.env.appstore') && prepareOnly < script.indexOf('xcodebuild archive'),
      'PREPARE_ONLY stops after the model gate, before the App Store key and the archive');
  }
});
