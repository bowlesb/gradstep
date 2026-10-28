// Shared build/release checks for the Apple-encrypted PDF model pack.
// LMNE is the envelope observed from the installed Apple compiler on genuine encrypted MLProgram exports.
// A header alone is insufficient: require compiler receipts bound to every tree and a signed runtime qualification.
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, lstatSync, openSync, readSync, closeSync, realpathSync } from 'node:fs';
import { join, relative, isAbsolute, sep } from 'node:path';

export const MODEL_FILES = Object.freeze({ layout: 'DeviceLayout.mlmodelc', tagger: 'DeviceTagger.mlmodelc',
  recogniser: 'DeviceRecogniser.mlmodelc', tagger_reference: 'DeviceTaggerReference.mlmodelc' });
export const TEAM_ID = '3BJ33TT599';
export const sha256 = data => createHash('sha256').update(data).digest('hex');
export const fileSHA = path => sha256(readFileSync(path));
const need = (value, message) => { if (!value) throw Error(`device model protection: ${message}`); };
export function filesIn(directory) {
  const result = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    need(!lstatSync(path).isSymbolicLink(), 'symbolic links are not permitted in model artifacts');
    if (entry.isDirectory()) result.push(...filesIn(path));
    else { need(entry.isFile(), 'unexpected filesystem object'); result.push(path); }
  }
  return result.sort();
}
export function treeSHA(directory) {
  return sha256(filesIn(directory).map(path => `/${relative(directory, path)}:${fileSHA(path)}`).join('\n'));
}
export function verifyEncryptedTree(directory) {
  const paths = filesIn(directory);
  need(paths.length >= 4 && paths.includes(join(directory, 'encryptionInfo/coremldata.bin')), 'missing Apple encryption envelope');
  for (const path of paths) {
    const fd = openSync(path, 'r'), magic = Buffer.alloc(4);
    let read;
    try { read = readSync(fd, magic, 0, 4, 0); } finally { closeSync(fd); }
    need(read === 4 && magic.equals(Buffer.from('LMNE')), 'unencrypted or unknown compiled-model payload');
  }
  return treeSHA(directory);
}
export function verifyPackFiles(directory, manifest) {
  need(manifest.schema === 'gradstep-device-models-pack-v1' && manifest.folder === 'DeviceModels', 'unexpected pack schema');
  need(Array.isArray(manifest.files) && manifest.files.length > 0, 'missing pack files');
  const names = new Set();
  for (const row of manifest.files) {
    need(typeof row.path === 'string' && /^[A-Za-z0-9_.\/-]+$/.test(row.path) &&
      row.path.split('/').every(p => p && p !== '.' && p !== '..') && !names.has(row.path), 'unsafe or duplicate pack path');
    names.add(row.path);
    const path = join(directory, row.path), stat = lstatSync(path);
    need(stat.isFile() && !stat.isSymbolicLink() && stat.size === row.size && fileSHA(path) === row.sha256, `pack file differs: ${row.path}`);
  }
  const rows = [...manifest.files].sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  need(sha256(rows.map(f => `${f.path}\t${f.size}\t${f.sha256}\n`).join('')) === manifest.version, 'pack version differs');
  const actual = filesIn(directory).map(p => relative(directory, p));
  need(actual.length === names.size && actual.every(p => names.has(p)), 'unlisted files in model pack');
}
export function verifyProtectedPack(directory, manifest, lock) {
  verifyPackFiles(directory, manifest);
  const config = JSON.parse(readFileSync(join(directory, 'device-models.json'), 'utf8'));
  const record = config.protection;
  need(record?.format === 'apple-coreml-encryption-v1' && record.mode === 'encrypted', 'an encrypted pack is required');
  need(typeof record.compiler_version === 'string' && record.compiler_version.length > 0, 'missing compiler identity');
  need(config.tagger?.reference?.weights_model && !config.tagger.reference.weights, 'plaintext reference weights are forbidden');
  const rootFiles = new Set(['device-models.json', 'tagger-vocab.json', 'recogniser-vocab.json', 'recogniser-added-tokens.json', 'tagger-reference.json']);
  for (const row of manifest.files) {
    const first = row.path.split('/')[0];
    need(Object.values(MODEL_FILES).includes(first) || rootFiles.has(row.path), 'unexpected payload in protected pack');
  }
  const selected = { layout: config.layout?.model, tagger: config.tagger?.model,
    recogniser: config.recogniser?.encoder, tagger_reference: config.tagger?.reference?.weights_model };
  need(config.recogniser?.encoder?.function === 'prefill' && config.recogniser?.decoder?.function === 'step' &&
    config.recogniser.decoder.file === MODEL_FILES.recogniser &&
    config.recogniser.decoder.weights_sha256 === lock.models.recogniser?.sha256 &&
    config.recogniser.shared_state !== false, 'recognizer functions must use the locked shared-state model');
  const trees = {};
  for (const [role, file] of Object.entries(MODEL_FILES)) {
    const expected = role === 'tagger_reference' ? lock.models[role]?.carrier_sha256 : lock.models[role]?.sha256;
    need(/^[a-f0-9]{64}$/.test(expected ?? '') && selected[role]?.file === file && selected[role]?.weights_sha256 === expected, `source lock differs: ${role}`);
    need(manifest.lock?.[role] === lock.models[role]?.sha256, `manifest lock differs: ${role}`);
    const receipt = record.models?.[role];
    const compiled = verifyEncryptedTree(join(directory, file));
    need(receipt?.file === file && receipt.source_sha256 === expected && receipt.compiled_sha256 === compiled &&
      receipt.method === 'coremlcompiler --encrypt', `compiler receipt differs: ${role}`);
    trees[role] = compiled;
  }
  return { config, trees };
}
export function verifyQualification(report, manifest, trees) {
  need(report?.schema === 'science-reader-coreml-encryption-verification-v1' && report.passed === true, 'signed encrypted-load verification is required');
  need(report.pack_version === manifest.version && report.signature_team === TEAM_ID && report.signature_verified === true,
    'verification is stale or from another signing team');
  need(/^[a-f0-9]{64}$/.test(report.tool_sha256 ?? ''), 'verification lacks signed tool identity');
  for (const [role, digest] of Object.entries(trees)) need(report.compiled_trees?.[role] === digest, `verification tree differs: ${role}`);
  need(report.runtime?.passed === true && report.runtime.recogniser_available === true && report.runtime.reference_available === true,
    'all models and protected reference must load successfully');
  return true;
}
// Also inspect resources outside the declared pack, including ODR siblings, for accidental source/key/plaintext copies.
export function rejectUnprotectedModelCopies(directory) {
  const canonicalRoot = realpathSync(directory);
  function inspect(folder) {
    for (const entry of readdirSync(folder, { withFileTypes: true })) {
      const path = join(folder, entry.name);
      need(!/\.(?:mlmodelkey|mlmodel|mlpackage)(?:\/|$)/i.test(path), 'key or source model in distribution');
      need(!/tagger-reference\.bin$/i.test(path), 'raw tagger recovery weights in distribution');
      // Framework version links are normal in Mac bundles. Never follow them or external links; model trees remain strict.
      if (entry.isSymbolicLink()) {
        const resolved = realpathSync(path), within = relative(canonicalRoot, resolved);
        need(path.includes('.framework/') && !path.endsWith('.mlmodelc') && within !== '..' &&
          !within.startsWith(`..${sep}`) && !isAbsolute(within), 'external or non-framework symbolic link in distribution');
        continue;
      }
      if (entry.isDirectory()) {
        if (path.endsWith('.mlmodelc')) verifyEncryptedTree(path);
        else inspect(path);
      }
    }
  }
  inspect(directory);
}
