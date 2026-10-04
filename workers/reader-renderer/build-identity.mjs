import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

// Local build provenance, not hosted admission. The CLI captures this before
// importing rendering modules, then rechecks before and after publication.
const productionFiles = ['profile.json', 'package.json', 'package-lock.json', 'common.mjs', 'png.mjs', 'dom.mjs', 'renderer.mjs', 'render-document.mjs', 'render-worker.mjs', 'bundle.mjs', 'mathpix-profile.mjs', 'mathpix-provenance.mjs', 'mathpix-input.mjs', 'image-paths.mjs', 'build-identity.mjs', 'cli.mjs', 'process-group.mjs', 'reader.css', 'NOTICE.txt',
  '../../supabase/functions/_shared/mathpix-result.ts', '../../supabase/functions/_shared/mathpix.ts',
  '../../supabase/functions/_shared/archive.ts', '../../supabase/functions/_shared/http.ts'];
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
export function captureRendererIdentity() {
  return digest(JSON.stringify({ domain: 'science-reader-renderer-build-v1', runtime: { node: process.versions.node, v8: process.versions.v8, zlib: process.versions.zlib }, files: productionFiles.map(path => ({ path, sha256: digest(readFileSync(new URL(path, import.meta.url))) })) }));
}
