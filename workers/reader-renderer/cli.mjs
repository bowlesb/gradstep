#!/usr/bin/env node
import { constants, closeSync, openSync, readSync, fstatSync, lstatSync, readdirSync, mkdirSync, writeFileSync, renameSync, rmSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { captureRendererIdentity } from './build-identity.mjs';
import { runProcessGroup } from './process-group.mjs';
function requireThat(condition, code) { if (!condition) throw new Error(code); }

const fixture = fileURLToPath(new URL('../../tests/fixtures/reader/', import.meta.url));
function readRegular(path, maximum) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = fstatSync(fd); requireThat(stat.isFile() && stat.size <= maximum, 'input_file');
    const chunks = []; let count = 0;
    while (true) { const chunk = Buffer.alloc(Math.min(65536, maximum + 1 - count)); const read = readSync(fd, chunk, 0, chunk.length, null); if (read === 0) break; count += read; requireThat(count <= maximum, 'input_file'); chunks.push(chunk.subarray(0, read)); }
    const after = fstatSync(fd); requireThat(count === stat.size && after.size === stat.size && after.mtimeMs === stat.mtimeMs && after.ctimeMs === stat.ctimeMs, 'input_changed');
    return Buffer.concat(chunks, count);
  } finally { closeSync(fd); }
}
export async function generateFixture() {
  const beforeImport = captureRendererIdentity();
  const { profile, sha256 } = await import('./common.mjs');
  const { buildBundle, validateBundle, rendererIdentity } = await import('./bundle.mjs');
  requireThat(rendererIdentity() === beforeImport, 'renderer_source_changed');
  const assetRoot = join(fixture, 'assets'); requireThat(lstatSync(assetRoot).isDirectory() && !lstatSync(assetRoot).isSymbolicLink(), 'asset_directory');
  const names = readdirSync(assetRoot).sort(); requireThat(names.length <= profile.max_figures, 'asset_limit');
  const assets = new Map(); let inputBytes = 0;
  for (const name of names) { requireThat(/^[A-Za-z0-9][A-Za-z0-9_.-]*\.png$/.test(name), 'asset_path'); const bytes = readRegular(join(assetRoot, name), Math.min(profile.max_member_bytes, profile.max_bundle_bytes - inputBytes)); inputBytes += bytes.length; assets.set(`assets/${name}`, bytes); }
  const result = buildBundle({ sourceBytes: readRegular(join(fixture, 'sample.mmd'), profile.max_source_bytes), assets, provenance: JSON.parse(readRegular(join(fixture, 'provenance.json'), profile.max_manifest_bytes)) });
  requireThat(rendererIdentity() === beforeImport, 'renderer_source_changed');
  return publishBundle(result, join(fixture, 'generated'), beforeImport, { profile, sha256, validateBundle, rendererIdentity });
}

export async function generateMathpix(inputDirectory, expectedRawSHA256, outputDirectory) {
  requireThat(typeof expectedRawSHA256 === 'string' && /^[a-f0-9]{64}$/.test(expectedRawSHA256), 'raw_manifest_integrity');
  const beforeImport = captureRendererIdentity();
  const { profile, sha256 } = await import('./common.mjs');
  const { openMathpixResult } = await import('../../supabase/functions/_shared/mathpix-result.ts');
  const { buildMathpixBundle } = await import('./mathpix-input.mjs');
  const { validateBundle, rendererIdentity } = await import('./bundle.mjs');
  requireThat(rendererIdentity() === beforeImport, 'renderer_source_changed');
  const inputRoot = resolve(inputDirectory), outputRoot = resolve(outputDirectory);
  const stat = lstatSync(inputRoot); requireThat(stat.isDirectory() && !stat.isSymbolicLink(), 'input_directory');
  // Only fixed logical raw names are opened. No archive entry becomes a path.
  const manifestBytes = readRegular(join(inputRoot, 'manifest.json'), 262144);
  const rawMembers = new Map([
    ['standalone.mmd', readRegular(join(inputRoot, 'standalone.mmd'), 8388608)],
    ['output.mmd.zip', readRegular(join(inputRoot, 'output.mmd.zip'), 33554432)],
    ['lines.json', readRegular(join(inputRoot, 'lines.json'), 16777216)],
  ]);
  const input = await openMathpixResult({ manifestBytes, expectedSHA256: expectedRawSHA256, rawMembers });
  const result = await buildMathpixBundle(input);
  requireThat(rendererIdentity() === beforeImport, 'renderer_source_changed');
  return publishBundle(result, outputRoot, beforeImport, { profile, sha256, validateBundle, rendererIdentity });
}

function publishBundle(result, outputRoot, beforeImport, { profile, sha256, validateBundle, rendererIdentity }) {
  mkdirSync(outputRoot, { recursive: true }); requireThat(!lstatSync(outputRoot).isSymbolicLink(), 'output_directory');
  const destination = join(outputRoot, result.manifestSHA);
  if (existsSync(destination)) {
    requireThat(lstatSync(destination).isDirectory() && !lstatSync(destination).isSymbolicLink(), 'output_directory');
    const oldManifest = readRegular(join(destination, 'manifest.json'), profile.max_manifest_bytes);
    requireThat(sha256(oldManifest) === result.manifestSHA, 'output_changed');
    const oldMembers = new Map([...result.members].map(([path, bytes]) => { const old = readRegular(join(destination, path), profile.max_member_bytes); requireThat(old.equals(bytes), 'output_changed'); return [path, old]; }));
    validateBundle(oldManifest, oldMembers, result.manifestSHA);
  } else {
    const staging = join(outputRoot, `staging-${randomUUID()}`); mkdirSync(staging);
    try {
      for (const [path, bytes] of result.members) { const parent = resolve(staging, path, '..'); mkdirSync(parent, { recursive: true }); writeFileSync(join(staging, path), bytes, { flag: 'wx' }); }
      writeFileSync(join(staging, 'manifest.json'), result.manifestBytes, { flag: 'wx' }); requireThat(rendererIdentity() === beforeImport, 'renderer_source_changed'); renameSync(staging, destination);
    } finally { if (existsSync(staging)) rmSync(staging, { recursive: true }); }
  }
  return { manifest_sha256: result.manifestSHA, renderer_build_sha256: result.manifest.renderer.build_sha256, directory: destination, members: result.members.size, bytes: [...result.members.values()].reduce((n, b) => n + b.length, 0), equations: result.index.equations.length, figures: result.index.figures.length };
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length === 3 && process.argv[2] === '--worker') { console.log(JSON.stringify(await generateFixture())); }
  else if (process.argv.length === 6 && process.argv[2] === '--mathpix-worker') {
    console.log(JSON.stringify(await generateMathpix(...process.argv.slice(3))));
  }
  else {
    const mathpix = process.argv.length === 6 && process.argv[2] === '--mathpix';
    requireThat(process.argv.length === 2 || mathpix, 'unsupported_arguments');
    // The outer watchdog owns the entire worker process group, including its
    // short-lived math child. A timeout/cancel cannot strand that grandchild.
    // This is a local wall limit plus V8 heap limits, not total RSS/hosted CPU.
    const output = await runProcessGroup(process.execPath, ['--max-old-space-size=256', fileURLToPath(import.meta.url),
      ...(mathpix ? ['--mathpix-worker', ...process.argv.slice(3)] : ['--worker'])]);
    process.stdout.write(output);
  }
}
