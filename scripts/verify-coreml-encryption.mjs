#!/usr/bin/env node
// Qualify the exact encrypted pack with a locally signed native loader; never uploads models or private keys.
// node scripts/verify-coreml-encryption.mjs --tool SIGNED_TOOL --models DIR --manifest JSON --out REPORT
import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fileSHA, TEAM_ID, verifyProtectedPack } from './device-model-protection.mjs';
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const option = key => { const i = process.argv.indexOf(key); if (i < 0 || !process.argv[i + 1]) throw Error(`missing ${key}`); return resolve(process.argv[i + 1]); };
const tool = option('--tool'), models = option('--models'), manifestPath = option('--manifest'), out = option('--out');
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify({ passed: false }) + '\n');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const lock = JSON.parse(readFileSync(resolve(root, 'apps/apple/device-models.lock.json'), 'utf8'));
const { trees } = verifyProtectedPack(models, manifest, lock);
execFileSync('codesign', ['--verify', '--strict', tool], { stdio: 'pipe' });
const signing = spawnSync('codesign', ['--display', '--verbose=4', tool], { encoding: 'utf8' });
if (signing.status !== 0 || !signing.stderr.split('\n').includes(`TeamIdentifier=${TEAM_ID}`)) throw Error('loader must be signed by the Science Reader team');
const toolSHA = fileSHA(tool);
const runtimePath = out + '.runtime.pending';
try {
  rmSync(runtimePath, { force: true });
  const loaded = spawnSync(tool, ['--verify-model-load', '--models', models, '--out', runtimePath], { encoding: 'utf8', timeout: 180_000 });
  if (loaded.status !== 0) {
    let failure = { passed: false };
    try { failure = JSON.parse(readFileSync(runtimePath, 'utf8')); } catch {}
    writeFileSync(out, JSON.stringify({ passed: false, pack_version: manifest.version, runtime: failure }, null, 2) + '\n');
    throw Error('signed encrypted model loading failed; no qualification issued');
  }
  const runtime = JSON.parse(readFileSync(runtimePath, 'utf8'));
  if (runtime.passed !== true || runtime.recogniser_available !== true || runtime.reference_available !== true) throw Error('incomplete native model load');
  // Recheck immutable inputs after loading; a report cannot bless files replaced during the probe.
  const after = verifyProtectedPack(models, manifest, lock).trees;
  if (fileSHA(tool) !== toolSHA || JSON.stringify(after) !== JSON.stringify(trees)) throw Error('model pack changed during verification');
  const report = { schema: 'science-reader-coreml-encryption-verification-v1', passed: true,
    verified_at: new Date().toISOString(), pack_version: manifest.version, signature_team: TEAM_ID, signature_verified: true,
    tool_sha256: toolSHA, verifier_sha256: fileSHA(fileURLToPath(import.meta.url)), compiled_trees: trees, runtime,
    scope: 'Signed native macOS loading of every exact encrypted asset and byte-validated CPU reference. Not an iOS/Catalyst journey, offline-first proof, or release.' };
  writeFileSync(out, JSON.stringify(report, null, 2) + '\n');
  console.log(`verified encrypted pack ${manifest.version.slice(0, 12)}: four assets, exact CPU recovery weights`);
} finally { rmSync(runtimePath, { force: true }); }
