import { readFileSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { captureMathpixResult, openMathpixResult, MATHPIX_OPTIONS_SHA256 } from '../../../supabase/functions/_shared/mathpix-result.ts';
import { crc32, encodePNG } from '../png.mjs';
import { sha256 } from '../common.mjs';

export const smallPNG = () => encodePNG(2, 2, Buffer.from([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]));

// Synthetic stored ZIP writer for local fixtures, not a production decoder.
export function storedZIP(entries) {
  const locals = [], central = []; let offset = 0;
  for (const [path, input] of entries) {
    const bytes = Buffer.from(input), name = Buffer.from(path), crc = crc32(bytes);
    const local = Buffer.alloc(30); local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4);
    local.writeUInt32LE(crc, 14); local.writeUInt32LE(bytes.length, 18); local.writeUInt32LE(bytes.length, 22); local.writeUInt16LE(name.length, 26);
    locals.push(local, name, bytes);
    const directory = Buffer.alloc(46); directory.writeUInt32LE(0x02014b50); directory.writeUInt16LE(20, 4); directory.writeUInt16LE(20, 6);
    directory.writeUInt32LE(crc, 16); directory.writeUInt32LE(bytes.length, 20); directory.writeUInt32LE(bytes.length, 24); directory.writeUInt16LE(name.length, 28); directory.writeUInt32LE(offset, 42);
    central.push(directory, name); offset += local.length + name.length + bytes.length;
  }
  const index = Buffer.concat(central), end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50); end.writeUInt16LE(entries.size, 8); end.writeUInt16LE(entries.size, 10); end.writeUInt32LE(index.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, index, end]);
}

export async function captureFixture({ source = '# Synthetic archive\n\nArchive equation $x+1$.', sourcePath = 'paper/main.mmd', entries = new Map(),
  documentID = 'c1300000-0000-4000-8000-000000000001', originalObjectID = 'c1300000-0000-4000-8000-000000000002' } = {}) {
  const checkpoint = Buffer.from('Synthetic original identity only; no PDF verification or Mathpix request occurred.');
  const providerJobID = 'synthetic-mathpix-result';
  return captureMathpixResult({
    binding: {
      document: { id: documentID, original_object_id: originalObjectID, sha256: sha256(checkpoint), bytes: checkpoint.length, page_count: 1 },
      attempt: { ocr_run_id: 'c1300000-0000-4000-8000-000000000003', id: 'c1300000-0000-4000-8000-000000000004', provider_scope_id: 'synthetic_local_fixture', provider_job_id: providerJobID },
      ocr: { api: 'v3/pdf', profile: 'science-reader-mmd-v1', options_sha256: MATHPIX_OPTIONS_SHA256 },
    },
    status: { providerJobID, state: 'completed', pages: 1, completedPages: 1, pipelineVersion: 'synthetic-fixture-v1', deleted: false, errorCode: null },
    conversion: { providerJobID, state: 'completed', errorCode: null },
    standaloneMMD: Buffer.from('# Standalone synthetic delivery\n\nThis deliberately differs from the archived source.\n\n![Standalone crop](standalone-crops/figure.png)\n'),
    archive: storedZIP(new Map([[sourcePath, Buffer.from(source)], ...entries])),
    linesJSON: Buffer.from('{"pages":[{"page":1,"lines":[]}]}\n'),
  });
}
export function openFixture(raw) {
  return openMathpixResult({ manifestBytes: raw.manifestBytes, expectedSHA256: raw.manifestSHA256, rawMembers: raw.rawMembers });
}
export async function captureAuthoredFixture() {
  const root = new URL('../../../tests/fixtures/reader/', import.meta.url);
  return captureFixture({ source: readFileSync(new URL('sample.mmd', root)),
    documentID: 'dddddddd-0000-4000-8000-000000000002', originalObjectID: 'dddddddd-0000-4000-8000-000000000008', entries: new Map(
    ['attention', 'evaluation'].map(name => [`paper/assets/${name}.png`, readFileSync(new URL(`assets/${name}.png`, root))])) });
}
export function writeRawFixture(raw, parent) {
  const directory = join(resolve(parent), raw.manifestSHA256); mkdirSync(directory, { recursive: true });
  const members = new Map([['manifest.json', raw.manifestBytes], ...raw.rawMembers]);
  for (const [name, input] of members) {
    const path = join(directory, name), bytes = Buffer.from(input);
    if (existsSync(path)) {
      if (!readFileSync(path).equals(bytes)) throw new Error('fixture_changed');
    } else writeFileSync(path, bytes, { flag: 'wx' });
  }
  return directory;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) throw new Error('fixture_arguments');
  const raw = await captureAuthoredFixture();
  console.log(JSON.stringify({ synthetic_fixture: true, raw_manifest_sha256: raw.manifestSHA256, directory: writeRawFixture(raw, process.argv[2]) }));
}
