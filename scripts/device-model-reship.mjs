// Reshipping a model pack that TestFlight already distributed (JUDGMENT_LOG 56, owner decision 2026-10-28).
// apps/apple/device-models-shipped.json pins every such pack by its exact description (file list, sizes, SHA-256 and
// the version digest). Only a listed pack may skip Apple model encryption, and only with exactly those bytes: it
// exposes nothing that was not already public. Any other pack still requires --require-encryption and the signed
// qualification (device-model-protection.mjs). Every check fails closed with a message naming the rule.
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { filesIn, fileSHA, sha256, verifyPackFiles } from './device-model-protection.mjs';

export const SHIPPED_SCHEMA = 'gradstep-device-models-shipped-v1';
export const SHIPPED_RECORD = 'apps/apple/device-models-shipped.json';
const need = (value, message) => { if (!value) throw Error(`device model reship: ${message}`); };
const versionOf = files => sha256([...files].sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0)
  .map(f => `${f.path}\t${f.size}\t${f.sha256}\n`).join(''));

/** The record's entry for `version` (the full 64-character pack version), after checking the record is self-consistent. */
export function shippedPack(record, version) {
  need(record?.schema === SHIPPED_SCHEMA && Array.isArray(record.packs), `unreadable shipped-pack record (${SHIPPED_RECORD})`);
  need(typeof version === 'string' && /^[a-f0-9]{64}$/.test(version),
    'name the full 64-character version of a pack TestFlight already shipped (apps/apple/device-models-shipped.json)');
  const matches = record.packs.filter(p => p?.description?.version === version);
  need(matches.length > 0, `pack ${version.slice(0, 12)} was never recorded as shipped; a new pack must be built with --require-encryption and pass the signed verification`);
  need(matches.length === 1, `pack ${version.slice(0, 12)} is recorded more than once; fix ${SHIPPED_RECORD}`);
  const entry = matches[0], d = entry.description;
  need(d.schema === 'gradstep-device-models-pack-v1' && d.folder === 'DeviceModels' && d.tag === 'device-pdf-models' &&
    d.lock && typeof d.lock === 'object', 'recorded description has an unexpected schema');
  need(Array.isArray(d.files) && d.files.length > 0 && versionOf(d.files) === d.version, 'recorded file list does not hash to its version');
  need(Number.isSafeInteger(entry.builds?.ios) && entry.builds.ios > 0 && /^[0-9a-f]{40}$/.test(entry.commit ?? ''),
    'recorded pack lacks the build and commit that shipped it');
  return entry;
}

/** Candidate DeviceModels folders inside an archive, an app, or the folder itself. */
export function packFolders(path) {
  const target = resolve(path);
  if (!existsSync(target)) return [];
  if (basename(target) === 'DeviceModels') return [target];
  const found = [];
  const odr = join(target, 'Products', 'OnDemandResources');
  if (existsSync(odr)) for (const pack of readdirSync(odr)) if (pack.endsWith('.assetpack')) found.push(join(odr, pack, 'DeviceModels'));
  const apps = join(target, 'Products', 'Applications');
  for (const app of existsSync(apps) ? readdirSync(apps).map(a => join(apps, a)) : target.endsWith('.app') ? [target] : [])
    found.push(join(app, 'Contents', 'Resources', 'DeviceModels'), join(app, 'DeviceModels'));
  return found.filter(f => existsSync(f) && statSync(f).isDirectory());
}

/** The exact recorded bytes: every listed file with its size and SHA-256, nothing unlisted, no links. */
export function verifyReshipSource(directory, entry) {
  verifyPackFiles(directory, entry.description);
  return directory;
}

/** The first folder among `from` (explicit) or the record's own archives that holds exactly the recorded pack. */
export function findReshipSource(root, entry, from) {
  const places = from ? [from] : (entry.sources ?? []).map(s => resolve(root, s));
  const tried = [];
  for (const place of places) {
    for (const folder of packFolders(place)) {
      try { return verifyReshipSource(folder, entry); } catch (error) { tried.push(`${folder}: ${error.message}`); }
    }
    if (!packFolders(place).length) tried.push(`${place}: no DeviceModels folder`);
  }
  need(false, `no source holds the recorded bytes of pack ${entry.description.version.slice(0, 12)} ` +
    `(pass --reship-from ARCHIVE_OR_FOLDER; a rebuild cannot reproduce them, because the compiler orders model metadata ` +
    `differently between runs):\n  ${tried.join('\n  ')}`);
}

/** For rejectUnprotectedModelCopies: a plaintext compiled tree is allowed only inside a DeviceModels folder and only
 * when it is byte for byte the recorded pack's tree of that name. Anything else stays subject to the encryption rule. */
export function shippedPlaintextTrees(entry) {
  const rows = entry.description.files;
  return path => {
    const name = basename(path), prefix = `${name}/`;
    const expected = rows.filter(r => r.path.startsWith(prefix));
    if (basename(dirname(path)) !== 'DeviceModels' || !expected.length) return false;
    const actual = filesIn(path);
    need(actual.length === expected.length, `${name} differs from the recorded shipped pack`);
    for (const row of expected) {
      const file = join(path, row.path.slice(prefix.length));
      need(existsSync(file) && statSync(file).size === row.size && fileSHA(file) === row.sha256, `${name} differs from the recorded shipped pack`);
    }
    return true;
  };
}

/** The description written for the app must be the recorded one, field for field. */
export function verifyReshipDescription(described, entry) {
  need(JSON.stringify(described) === JSON.stringify(entry.description), 'the written description is not the recorded shipped one');
  return true;
}

export function readShippedRecord(root, path) {
  return JSON.parse(readFileSync(resolve(root, path ?? SHIPPED_RECORD), 'utf8'));
}
