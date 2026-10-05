// Local CLI for the Edge reader renderer (timestep-mathpix-mathml-v1).
//
//   node scripts/render-mathpix-reader.ts <raw-result-dir> <raw-manifest-sha256> <output-root> [attribution-file]
//
// <raw-result-dir> holds a retained capture (manifest.json, standalone.mmd,
// output.mmd.zip, lines.json). The raw manifest and expanded archive are fully
// revalidated; provenance comes from that manifest. Output is a validated,
// content-addressed <output-root>/<reader-manifest-sha256>/ directory. An
// existing directory is compared byte-for-byte, never overwritten. No network,
// provider or database access occurs.
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { openMathpixResult } from '../supabase/functions/_shared/mathpix-result.ts';
import { renderRetainedMathpixResult, validateReaderBundle } from '../supabase/functions/_shared/reader/index.ts';

const [rawDirectory, rawSHA256, outputRoot, attributionFile] = process.argv.slice(2);
if (!rawDirectory || !/^[a-f0-9]{64}$/.test(rawSHA256 ?? '') || !outputRoot || process.argv.length > 6) {
  console.error('usage: node scripts/render-mathpix-reader.ts <raw-result-dir> <raw-manifest-sha256> <output-root> [attribution-file]');
  process.exit(2);
}
const read = (path: string) => new Uint8Array(readFileSync(path));
const manifestBytes = read(join(rawDirectory, 'manifest.json'));
const rawMembers = new Map(['standalone.mmd', 'output.mmd.zip', 'lines.json'].map(name => [name, read(join(rawDirectory, name))]));
const input = await openMathpixResult({ manifestBytes, expectedSHA256: rawSHA256, rawMembers });
const attribution = attributionFile ? readFileSync(attributionFile, 'utf8') : undefined;
const started = performance.now();
const bundle = await renderRetainedMathpixResult(input, { attribution });
const elapsed = Math.round(performance.now() - started);

const destination = resolve(outputRoot, bundle.manifestSHA256);
if (existsSync(destination)) {
  const members = new Map([...bundle.members.keys()].map(path => [path, read(join(destination, path))]));
  validateReaderBundle(read(join(destination, 'manifest.json')), members, bundle.manifestSHA256);
  for (const [path, bytes] of bundle.members) {
    if (Buffer.compare(Buffer.from(bytes), Buffer.from(members.get(path)!)) !== 0) throw new Error(`output_changed:${path}`);
  }
} else {
  const staging = resolve(outputRoot, `staging-${randomUUID()}`);
  try {
    for (const [path, bytes] of [...bundle.members, ['manifest.json', bundle.manifestBytes] as const]) {
      mkdirSync(dirname(join(staging, path)), { recursive: true });
      writeFileSync(join(staging, path), bytes, { flag: 'wx' });
    }
    renameSync(staging, destination);
  } finally { if (existsSync(staging)) rmSync(staging, { recursive: true }); }
}
console.log(JSON.stringify({ manifest_sha256: bundle.manifestSHA256, directory: destination, render_ms: elapsed,
  members: bundle.members.size, bytes: [...bundle.members.values()].reduce((sum, bytes) => sum + bytes.length, 0), ...bundle.stats }));
