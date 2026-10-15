// Builds the on-device PDF converter for JavaScriptCore (docs/architecture/DEVICE_PDF_ROUTE.md):
// apps/apple/ScienceReader/Resources/device-pdf-reader.js (global `GradstepDevicePDF`) and its identity file.
//   node scripts/build-device-pdf-compiler.mjs [--check]
import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const pinned = { '@noble/hashes': '1.8.0', temml: '0.11.11' };
for (const [name, version] of Object.entries(pinned)) {
  const found = JSON.parse(readFileSync(new URL(`../node_modules/${name}/package.json`, import.meta.url), 'utf8')).version;
  if (found !== version) throw Error(`Unreviewed device converter dependency ${name} ${found} (expected ${version})`);
}
const result = await build({ absWorkingDir: root, entryPoints: ['supabase/functions/_shared/reader/device-pdf-compiler.ts'],
  bundle: true, platform: 'neutral', target: 'es2022', format: 'iife', globalName: 'GradstepDevicePDF', minify: true, legalComments: 'eof',
  mainFields: ['module', 'main'], conditions: ['import'],
  banner: { js: readFileSync(new URL('./device-pdf-compiler/prelude.js', import.meta.url), 'utf8') },
  alias: { 'node:crypto': fileURLToPath(new URL('./arxiv-compiler/crypto.ts', import.meta.url)),
    'node:zlib': fileURLToPath(new URL('./arxiv-compiler/zlib.ts', import.meta.url)) }, write: false,
});
const code = Buffer.from(result.outputFiles[0].contents);
const bundlePath = 'apps/apple/ScienceReader/Resources/device-pdf-reader.js';
const { DEVICE_PDF_BUILD_SHA256 } = await import('../supabase/functions/_shared/reader/device-pdf/bundle.ts');
const { DEVICE_PDF_RENDERER_ID, DEVICE_PDF_CONVERTER_VERSION, DEVICE_PDF_PORT_REVISION } = await import('../supabase/functions/_shared/reader/device-pdf/types.ts');
const codeSHA256 = createHash('sha256').update(code).digest('hex');
const identity = JSON.stringify({ renderer_id: DEVICE_PDF_RENDERER_ID, converter: DEVICE_PDF_CONVERTER_VERSION, revision: DEVICE_PDF_PORT_REVISION,
  build_sha256: DEVICE_PDF_BUILD_SHA256, code_sha256: codeSHA256 }, null, 1) + '\n';
const identityPath = 'apps/apple/ScienceReader/Resources/device-pdf-reader-build.json';
let previous = null; try { previous = JSON.parse(readFileSync(root + identityPath, 'utf8')); } catch { previous = null; }
if (previous && previous.revision === DEVICE_PDF_PORT_REVISION && previous.code_sha256 && previous.code_sha256 !== codeSHA256 && !process.argv.includes('--check')) {
  throw Error(`The device PDF converter's code changed but DEVICE_PDF_PORT_REVISION is still ${DEVICE_PDF_PORT_REVISION}: bump it in supabase/functions/_shared/reader/device-pdf/types.ts.`);
}
if (process.argv.includes('--check')) {
  if (!readFileSync(root + bundlePath).equals(code)) throw Error(`Stale device PDF converter: ${bundlePath}. Run node scripts/build-device-pdf-compiler.mjs.`);
  if (readFileSync(root + identityPath, 'utf8') !== identity) throw Error(`Stale device PDF converter identity: ${identityPath}.`);
} else {
  writeFileSync(root + bundlePath, code); writeFileSync(root + identityPath, identity);
  console.log(`${bundlePath}: ${code.length} bytes; ${identityPath}`);
}
