#!/usr/bin/env node
// The on-device PDF models as a separate download (docs/architecture/DEVICE_PDF_ROUTE.md "The models as a download"):
// checks a built iOS app or archive before it is uploaded.
//
//   SCIENCE_READER_COREML_VERIFICATION=/path/verification.json node scripts/check-device-model-pack.mjs ARCHIVE
//   --development-plaintext skips encryption qualification for local unsigned research builds only.
//   --reship-pack VERSION: the pack is one TestFlight already shipped (apps/apple/device-models-shipped.json,
//     JUDGMENT_LOG 55). Instead of encryption qualification, the description must be the recorded one and every
//     distributed model tree must be exactly its recorded bytes; keys, sources and raw recovery weights stay refused.
//   node scripts/check-device-model-pack.mjs --mac <archive.xcarchive | Gradstep.app>    Mac (models inside the app)
//
// iPhone/iPad: the app carries the pack's description (device-models-pack.json, equal to the one
// scripts/device-models.mjs wrote, its lock digests equal to apps/apple/device-models.lock.json) and not the models; its
// On-Demand Resources table maps the tag to an asset pack; that asset pack holds every described file with its size and
// SHA-256. Mac: the models are inside the app and match the description.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyPackFiles, verifyProtectedPack, verifyQualification, rejectUnprotectedModelCopies } from './device-model-protection.mjs';
import { readShippedRecord, shippedPack, shippedPlaintextTrees, verifyReshipDescription } from './device-model-reship.mjs';

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const mac = process.argv.includes('--mac');
const development = process.argv.includes('--development-plaintext');
const args = process.argv.slice(2);
const take = name => { const i = args.indexOf(name); return i >= 0 ? (args.splice(i, 2)[1] ?? '') : undefined; };
const evidencePath = take('--encryption-verification') ?? process.env.SCIENCE_READER_COREML_VERIFICATION;
const reshipVersion = take('--reship-pack'), shippedRecord = take('--shipped-record');
const target = resolve(args.find(a => !a.startsWith('--')) ?? '');
const fail = message => { console.error(`device model pack: ${message}`); process.exit(1); };
if (reshipVersion !== undefined && development) fail('--reship-pack and --development-plaintext are different release modes');
const qualification = evidencePath && reshipVersion === undefined ? JSON.parse(readFileSync(resolve(evidencePath), 'utf8')) : null;
if (!existsSync(target)) fail(`pass an archive, a products folder or an app (${target})`);

const described = JSON.parse(readFileSync(join(ROOT, 'apps/apple/DeviceModelsManifest/device-models-pack.json'), 'utf8'));
const lock = JSON.parse(readFileSync(join(ROOT, 'apps/apple/device-models.lock.json'), 'utf8'));
let reship = null;
if (reshipVersion !== undefined) {
  // A recorded shipped pack carries its own lock (the models it was built from); the current lock names new models.
  try { reship = shippedPack(readShippedRecord(ROOT, shippedRecord), reshipVersion); verifyReshipDescription(described, reship); }
  catch (error) { fail(error.message); }
} else {
  for (const [role, model] of Object.entries(lock.models)) {
    if (described.lock?.[role] !== model.sha256) fail(`the description's ${role} is not the locked one (run node scripts/device-models.mjs)`);
  }
}
const distributionScan = reship ? { allowPlaintext: shippedPlaintextTrees(reship) } : {};
const sha = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const walk = dir => readdirSync(dir, { withFileTypes: true }).flatMap(e => {
  const path = join(dir, e.name);
  return e.isDirectory() ? [path, ...walk(path)] : [path];
});
function matches(folder, where) {
  if (reship) verifyPackFiles(folder, described); // exactly the recorded files: nothing changed, missing or added
  else if (!development) {
    const { trees } = verifyProtectedPack(folder, described, lock);
    verifyQualification(qualification, described, trees);
  }
  for (const file of described.files) {
    const path = join(folder, file.path);
    if (!existsSync(path)) fail(`${where} lacks ${file.path}`);
    if (statSync(path).size !== file.size || sha(path) !== file.sha256) fail(`${where}: ${file.path} differs from the description`);
  }
}
const findApp = () => {
  if (target.endsWith('.app')) return target;
  const apps = walk(target).filter(p => p.endsWith('.app') && !p.includes('.app/') && statSync(p).isDirectory() && !/Runner\.app$/.test(p));
  if (apps.length !== 1) fail(`expected one app in ${target}, found ${apps.length}`);
  return apps[0];
};
const app = findApp();
if (!development) rejectUnprotectedModelCopies(app, distributionScan);
const resources = mac ? join(app, 'Contents', 'Resources') : app;
const shipped = join(resources, 'device-models-pack.json');
if (!existsSync(shipped)) fail(`the app lacks device-models-pack.json`);
if (JSON.parse(readFileSync(shipped, 'utf8')).version !== described.version) fail('the app\'s description is not the one just written');
if (reship) try { verifyReshipDescription(JSON.parse(readFileSync(shipped, 'utf8')), reship); } catch (error) { fail(error.message); }

if (mac) {
  matches(join(resources, described.folder), 'the Mac app');
  console.log(`device model pack: the Mac app carries ${described.files.length} files, version ${described.version.slice(0, 12)}${reship ? ` (reshipped from TestFlight ${reship.builds.mac ?? reship.builds.ios}, ${reship.protection})` : ''}`);
  process.exit(0);
}
if (existsSync(join(app, described.folder))) fail(`the iOS app still carries ${described.folder}/ (On-Demand Resources off?)`);
const odr = join(app, 'OnDemandResources.plist');
if (!existsSync(odr)) fail('the app has no On-Demand Resources table');
const table = JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', odr], { encoding: 'utf8' }));
const packIDs = table.NSBundleResourceRequestTags?.[described.tag]?.NSAssetPacks ?? [];
if (packIDs.length === 0) fail(`no asset pack for the tag ${described.tag}`);
const assetPacks = walk(target.endsWith('.app') ? resolve(target, '..') : target).filter(p => p.endsWith('.assetpack'));
let checked = 0;
for (const pack of assetPacks) {
  if (!development) rejectUnprotectedModelCopies(pack, distributionScan);
  const folder = join(pack, described.folder);
  if (existsSync(folder)) {
    matches(folder, pack.slice(target.length + 1)); checked++;
  }
}
if (checked === 0) fail(`no asset pack holding ${described.folder}/ under ${target}`);
const bytes = described.files.reduce((n, f) => n + f.size, 0);
console.log(`device model pack: tag ${described.tag} → ${packIDs.join(', ')}; ${described.files.length} files, ${(bytes / 1e6).toFixed(1)} MB, version ${described.version.slice(0, 12)}; not inside the app${reship ? `; reshipped from TestFlight ${reship.builds.ios} (${reship.protection})` : ''}`);
