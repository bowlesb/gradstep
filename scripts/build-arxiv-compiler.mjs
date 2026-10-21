import { build } from 'esbuild';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const noble = JSON.parse(readFileSync(new URL('../node_modules/@noble/hashes/package.json', import.meta.url), 'utf8'));
if (noble.version !== '1.8.0') throw Error('Unreviewed device SHA-256 dependency');
const result = await build({ absWorkingDir: root, entryPoints: ['supabase/functions/_shared/reader/device-compiler.ts'],
  outfile: 'apps/apple/ScienceReader/Resources/arxiv-reader.js', bundle: true, platform: 'browser', target: 'es2022',
  format: 'iife', globalName: 'GradstepArxivReader', minify: true, legalComments: 'eof',
  alias: { 'node:crypto': fileURLToPath(new URL('./arxiv-compiler/crypto.ts', import.meta.url)),
    'node:zlib': fileURLToPath(new URL('./arxiv-compiler/zlib.ts', import.meta.url)) }, write: false,
});
for (const path of ['apps/apple/ScienceReader/Resources/arxiv-reader.js', 'apps/web/src/reader/arxiv-reader.js']) {
  if (process.argv.includes('--check')) {
    if (!readFileSync(root + path).equals(Buffer.from(result.outputFiles[0].contents)))
      throw Error(`Stale device compiler: ${path}. Run node scripts/build-arxiv-compiler.mjs.`);
  } else writeFileSync(root + path, result.outputFiles[0].contents);
}
// The native app's metadata extractor (docs/architecture/ARXIV_DEVICE_ONLY.md §5.3): its own bundle, so reading a paper's
// metadata never changes the compiler above or its identity. The browser imports the same TypeScript directly.
const metadata = await build({ absWorkingDir: root, entryPoints: ['supabase/functions/_shared/reader/source-metadata-entry.ts'],
  outfile: 'apps/apple/ScienceReader/Resources/arxiv-source-metadata.js', bundle: true, platform: 'browser', target: 'es2022',
  format: 'iife', globalName: 'GradstepSourceMetadata', minify: true, legalComments: 'eof', write: false,
  alias: { 'node:crypto': fileURLToPath(new URL('./arxiv-compiler/crypto.ts', import.meta.url)),
    'node:zlib': fileURLToPath(new URL('./arxiv-compiler/zlib.ts', import.meta.url)) } });
const metadataPath = 'apps/apple/ScienceReader/Resources/arxiv-source-metadata.js';
if (process.argv.includes('--check')) {
  let current = null; try { current = readFileSync(root + metadataPath); } catch { current = null; }
  if (!current || !current.equals(Buffer.from(metadata.outputFiles[0].contents)))
    throw Error(`Stale metadata extractor: ${metadataPath}. Run node scripts/build-arxiv-compiler.mjs.`);
} else writeFileSync(root + metadataPath, metadata.outputFiles[0].contents);
// The renderer the native app ships, so it can tell a bundle compiled by an older app from its own
// (ReaderModel.openHTMLReader re-prepares those): the same identity the bundle manifest carries.
const { ARXIV_BUILD_SHA256 } = await import('../supabase/functions/_shared/reader/arxiv-bundle.ts');
const { ARXIV_RENDERER_ID, ARXIV_RENDERER_REVISION } = await import('../supabase/functions/_shared/reader/arxiv-html.ts');
// The compiled code's own digest travels with the identity: a compiler whose code changed under the same
// ARXIV_RENDERER_REVISION would reopen bundles it no longer produces (audit 2026-10-15), so the build refuses it.
const { createHash } = await import('node:crypto');
const codeSHA256 = createHash('sha256').update(Buffer.from(result.outputFiles[0].contents)).digest('hex');
const identity = JSON.stringify({ renderer_id: ARXIV_RENDERER_ID, revision: ARXIV_RENDERER_REVISION, build_sha256: ARXIV_BUILD_SHA256, code_sha256: codeSHA256 }, null, 1) + '\n';
const buildPath = 'apps/apple/ScienceReader/Resources/arxiv-reader-build.json';
let previous = null; try { previous = JSON.parse(readFileSync(root + buildPath, 'utf8')); } catch { previous = null; }
if (previous && previous.revision === ARXIV_RENDERER_REVISION && previous.code_sha256 && previous.code_sha256 !== codeSHA256) {
  throw Error(`The device compiler's code changed but ARXIV_RENDERER_REVISION is still ${ARXIV_RENDERER_REVISION}: bump it in supabase/functions/_shared/reader/arxiv-html.ts so devices prepare their stored papers again.`);
}
if (process.argv.includes('--check')) {
  if (readFileSync(root + buildPath, 'utf8') !== identity) throw Error(`Stale device compiler identity: ${buildPath}. Run node scripts/build-arxiv-compiler.mjs.`);
} else writeFileSync(root + buildPath, identity);
// Reader version details (owner, build 62) name each stored paper's version from this list: the shipped identity must
// be in it (docs/architecture/READER_VERSIONS.md).
const versions = JSON.parse(readFileSync(root + 'apps/apple/ScienceReader/Resources/reader-versions.json', 'utf8')).versions;
if (!versions.some(v => v.revision === ARXIV_RENDERER_REVISION && v.build_sha256 === ARXIV_BUILD_SHA256))
  throw Error(`apps/apple/ScienceReader/Resources/reader-versions.json has no entry for revision ${ARXIV_RENDERER_REVISION} (${ARXIV_BUILD_SHA256}): add one with its date and a one-line note.`);
