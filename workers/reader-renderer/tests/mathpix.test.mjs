import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { buildMathpixBundle } from '../mathpix-input.mjs';
import { validateBundle } from '../bundle.mjs';
import { pngHeaderMetadata, crc32, encodePNG } from '../png.mjs';
import { sha256, jsonBytes } from '../common.mjs';
import { resolveArchiveImagePath } from '../image-paths.mjs';
import { captureFixture, captureAuthoredFixture, openFixture, smallPNG, writeRawFixture } from './mathpix-fixture.mjs';

test('raw adapter and renderer preserve distinct standalone/archive identities with token-relative PNG dedup', async () => {
  const png = smallPNG();
  const source = '# Archive paper\n\nBefore $x_1+1$.\n\n![First diagram](./assets/a.bin "Figure 1. First")\n\n![Second diagram](../images/b.png "Figure 2. Second")\n\nLiteral `assets/a.bin` stays unchanged.\n';
  const raw = await captureFixture({ source, entries: new Map([['paper/assets/a.bin', png], ['images/b.png', png], ['unused/readme.txt', Buffer.from('raw-only')]]) });
  const result = await buildMathpixBundle(await openFixture(raw));
  const provenance = JSON.parse(result.members.get('provenance.json'));
  assert.equal(result.index.title, 'Archive paper');
  assert.equal(result.manifest.renderer.id, 'timestep-mathpix-mmd-v1'); assert.equal(result.manifest.source.kind, 'mathpix-mmd');
  assert.equal(result.manifest.source.sha256, sha256(Buffer.from(source)));
  assert.notEqual(result.manifest.source.sha256, sha256(raw.rawMembers.get('standalone.mmd')));
  assert.equal(provenance.raw_result_sha256, raw.manifestSHA256);
  assert.equal(provenance.source.archive_path, 'paper/main.mmd'); assert.equal(provenance.source.bytes, Buffer.byteLength(source));
  assert.deepEqual(provenance.image_inputs.map(row => row.archive_path), ['images/b.png', 'paper/assets/a.bin']);
  assert.equal(result.index.figures.length, 2); assert.notEqual(result.index.figures[0].id, result.index.figures[1].id);
  assert.deepEqual(result.index.figures[0].asset_paths, result.index.figures[1].asset_paths);
  assert.equal(result.manifest.members.filter(member => member.role === 'image').length, 1);
  assert.ok(result.index.blocks.some(block => block.text.includes('Literal assets/a.bin stays unchanged.')));
  assert.ok(![...result.members.keys()].some(path => /standalone|lines|readme/.test(path)));
  assert.doesNotThrow(() => validateBundle(result.manifestBytes, result.members, result.manifestSHA));
});

test('archive path resolution is bounded and never turns remote/encoded/missing references into assets', async () => {
  assert.equal(resolveArchiveImagePath('../images/a.png', 'paper/main.mmd'), 'images/a.png');
  for (const path of ['../../escape.png', '/images/a.png', 'https://invalid.test/a.png', 'data:image/png,a', 'a%2epng', 'a.png?x', 'a.png#x', 'a\\b.png', 'a//b.png']) {
    assert.throws(() => resolveArchiveImagePath(path, 'paper/main.mmd'), /asset_reference/);
  }
  for (const path of ['missing.png', '../Images/a.png', 'https://invalid.test/a.png']) {
    const raw = await captureFixture({ source: `# Missing\n\n![A diagram](${path})`, entries: new Map([['images/a.png', smallPNG()]]) });
    await assert.rejects(buildMathpixBundle(await openFixture(raw)), /asset_reference/);
  }
});

test('referenced PNG requires full decode; unrelated raw entries do not spend the 128-image admission', async () => {
  const png = smallPNG(), entries = new Map([['paper/used.png', png], ['paper/unused-broken.png', Buffer.from('not an image')], ['paper/unused-truncated.png', png.subarray(0, 33)]]);
  for (let n = 0; n < 129; n++) entries.set(`paper/unused-${String(n).padStart(3, '0')}.png`, encodePNG(1, 1, Buffer.from([n, 0, 0, 255])));
  const raw = await captureFixture({ source: '# One image\n\n![A diagram](used.png)', entries });
  const result = await buildMathpixBundle(await openFixture(raw));
  assert.equal(result.index.figures.length, 1); assert.equal(JSON.parse(result.members.get('provenance.json')).image_inputs.length, 1);
  const truncated = png.subarray(0, 33); assert.doesNotThrow(() => pngHeaderMetadata(truncated));
  for (const bytes of [truncated, Buffer.from('not an image')]) {
    const broken = await captureFixture({ source: '# Broken\n\n![A diagram](broken.png)', entries: new Map([['paper/broken.png', bytes]]) });
    await assert.rejects(buildMathpixBundle(await openFixture(broken)), /png_|asset_reference/);
  }
  const highBit = Buffer.from(png); highBit[12] = 0xc9; highBit.writeUInt32BE(crc32(highBit.subarray(12, 29)), 29);
  assert.throws(() => pngHeaderMetadata(highBit), /png_header/);
});

test('receiver refuses substituted/missing/extra expanded bytes and retries retained raw data without any provider transport', async () => {
  const raw = await captureFixture(), input = await openFixture(raw);
  const previousFetch = globalThis.fetch; let calls = 0;
  globalThis.fetch = async () => { calls++; throw new Error('unexpected_network'); };
  try {
    for (const change of [members => members.set('paper/main.mmd', Buffer.from('# Changed')), members => members.delete('paper/main.mmd'), members => members.set('extra.txt', Buffer.from('extra'))]) {
      const members = new Map(input.archiveMembers); change(members);
      await assert.rejects(buildMathpixBundle({ ...input, archiveMembers: members }), /binding_mismatch|mmd_ambiguous/);
    }
    const pending = buildMathpixBundle(input);
    input.rawManifestBytes.fill(0); input.archiveMembers.get('paper/main.mmd').fill(0);
    const first = await pending;
    const second = await buildMathpixBundle(await openFixture(raw));
    assert.deepEqual(first.manifestBytes, second.manifestBytes); assert.deepEqual(first.members, second.members);
    assert.equal(calls, 0);
  } finally { globalThis.fetch = previousFetch; }
});

test('new producer keeps fresh process macro isolation across successes and failures', async () => {
  const render = async source => buildMathpixBundle(await openFixture(await captureFixture({ source })));
  await render(String.raw`# First

$\newcommand{\rawprobe}{x}\rawprobe$`);
  await assert.rejects(render(String.raw`# Second

$\rawprobe$`), /math_error/);
  await assert.rejects(render(String.raw`# Failure

$\newcommand{\failedraw}{x}\style{display:none}{\failedraw}$`), /author_math_attributes/);
  await assert.rejects(render(String.raw`# After

$\failedraw$`), /math_error/);
});

test('closed provenance, cross-profile and image/HTML facts reject independently rehashed contradictions', async () => {
  const raw = await captureFixture({ source: '# Figure\n\n![A diagram](a.png)', entries: new Map([['paper/a.png', smallPNG()]]) });
  const original = await buildMathpixBundle(await openFixture(raw));
  function changedProvenance(change) {
    const value = JSON.parse(original.members.get('provenance.json')); change(value);
    const bytes = jsonBytes(value), members = new Map(original.members), manifest = structuredClone(original.manifest);
    members.set('provenance.json', bytes); Object.assign(manifest.members.find(member => member.role === 'provenance'), { bytes: bytes.length, sha256: sha256(bytes) });
    const manifestBytes = jsonBytes(manifest); return () => validateBundle(manifestBytes, members, sha256(manifestBytes));
  }
  for (const change of [p => { p.extra = true; }, p => { p.ocr.options_sha256 = '0'.repeat(64); }, p => { p.source.sha256 = '0'.repeat(64); }, p => { p.image_inputs[0].width++; }, p => { p.image_inputs.push(p.image_inputs[0]); }, p => { p.image_inputs = []; }, p => { p.image_inputs[0].archive_path = p.source.archive_path; }]) {
    assert.throws(changedProvenance(change), /mathpix_provenance/);
  }
  for (const change of [m => { m.renderer.id = 'timestep-mmd-v1'; }, m => { m.source.kind = 'authored-mmd'; }]) {
    const manifest = structuredClone(original.manifest); change(manifest); const bytes = jsonBytes(manifest);
    assert.throws(() => validateBundle(bytes, original.members, sha256(bytes)), /manifest_format/);
  }
  const html = Buffer.from(original.members.get('index.html').toString().replace('width="2"', 'width="200"'));
  assert.notDeepEqual(html, original.members.get('index.html'));
  const members = new Map(original.members); members.set('index.html', html); const manifest = structuredClone(original.manifest);
  Object.assign(manifest.members.find(member => member.role === 'html'), { bytes: html.length, sha256: sha256(html) });
  const bytes = jsonBytes(manifest); assert.throws(() => validateBundle(bytes, members, sha256(bytes)), /image_reference/);
});

test('same and fresh bounded CLI processes reproduce the synthetic authored-content adapter fixture', async () => {
  const root = mkdtempSync(join(tmpdir(), 'reader-mathpix-'));
  try {
    const raw = await captureAuthoredFixture(), inputDirectory = writeRawFixture(raw, join(root, 'raw'));
    const result = await buildMathpixBundle(await openFixture(raw));
    const first = spawnSync(process.execPath, ['cli.mjs', '--mathpix', inputDirectory, raw.manifestSHA256, join(root, 'readers')], { cwd: new URL('../', import.meta.url), encoding: 'utf8', timeout: 65000 });
    assert.equal(first.status, 0, first.stderr);
    const summary = JSON.parse(first.stdout); assert.equal(summary.manifest_sha256, result.manifestSHA);
    assert.deepEqual(readFileSync(join(summary.directory, 'manifest.json')), result.manifestBytes);
    for (const [path, bytes] of result.members) assert.deepEqual(readFileSync(join(summary.directory, path)), bytes);
    assert.equal(result.index.title, 'Reading machine learning papers'); assert.equal(result.index.equations.length, 7); assert.equal(result.index.figures.length, 2);
    const second = spawnSync(process.execPath, ['cli.mjs', '--mathpix', inputDirectory, raw.manifestSHA256, join(root, 'readers')], { cwd: new URL('../', import.meta.url), encoding: 'utf8', timeout: 65000 });
    assert.equal(second.status, 0, second.stderr); assert.deepEqual(JSON.parse(second.stdout), summary);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('unchanged authored4851 artifact remains accepted by the additive validator', () => {
  const root = new URL('../../../tests/fixtures/reader/generated/4851d8173451955cc36a455dc5d5fe0992a156d186c09f6fb291e05b4935f0b4/', import.meta.url);
  const manifestBytes = readFileSync(new URL('manifest.json', root)), manifest = JSON.parse(manifestBytes);
  const members = new Map(manifest.members.map(member => [member.path, readFileSync(new URL(member.path, root))]));
  assert.doesNotThrow(() => validateBundle(manifestBytes, members, '4851d8173451955cc36a455dc5d5fe0992a156d186c09f6fb291e05b4935f0b4'));
});
