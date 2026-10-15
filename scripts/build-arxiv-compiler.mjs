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
for (const path of ['apps/apple/ScienceReader/Resources/arxiv-reader.js', 'apps/web/public/arxiv-reader.js']) {
  if (process.argv.includes('--check')) {
    if (!readFileSync(root + path).equals(Buffer.from(result.outputFiles[0].contents)))
      throw Error(`Stale device compiler: ${path}. Run node scripts/build-arxiv-compiler.mjs.`);
  } else writeFileSync(root + path, result.outputFiles[0].contents);
}
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
