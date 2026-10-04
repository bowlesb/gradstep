import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { profile, requireThat, pathIsSafe } from './common.mjs';
import { captureRendererIdentity } from './build-identity.mjs';
import { validateImageMapping, validateUsedImagePaths } from './image-paths.mjs';

// Mathpix's Reset clears equation tags, not TeX macro definitions. Each document
// therefore owns a fresh process/module graph, including failed documents.
export function renderMMD(source, images) {
  return renderDocument(source, images, null);
}
export function renderMathpixMMD(source, images, mapping) {
  requireThat(mapping !== null && mapping !== undefined, 'image_mapping');
  return renderDocument(source, images, mapping);
}
function renderDocument(source, images, mapping) {
  requireThat(typeof source === 'string' && source.length > 0 && Buffer.byteLength(source) <= profile.max_source_bytes, 'source_limit');
  requireThat(images instanceof Map && images.size <= (mapping ? 512 : profile.max_figures), 'asset_limit');
  const metadata = [...images].map(([path, image]) => {
    requireThat(pathIsSafe(path) && Number.isInteger(image.width) && Number.isInteger(image.height) && image.width > 0 && image.height > 0 && image.width <= profile.max_image_dimension && image.height <= profile.max_image_dimension && image.width * image.height <= profile.max_image_pixels, 'image_metadata');
    return [path, { width: image.width, height: image.height }];
  });
  if (mapping) validateImageMapping(mapping, images);
  const input = Buffer.from(JSON.stringify({ source, images: metadata, ...(mapping ? { image_mapping: mapping } : {}) })); requireThat(input.length <= 2 * 1024 * 1024, 'render_request_limit');
  const identity = captureRendererIdentity();
  const result = spawnSync(process.execPath, ['--max-old-space-size=256', fileURLToPath(new URL('./render-worker.mjs', import.meta.url))], {
    input, stdio: ['pipe', 'ignore', 'ignore', 'pipe'], timeout: 30000, maxBuffer: 32 * 1024 * 1024,
    env: { PATH: process.env.PATH },
  });
  requireThat(captureRendererIdentity() === identity, 'renderer_source_changed');
  requireThat(!result.error && result.signal === null && result.status === 0 && result.output?.[3]?.length > 0 && result.output[3].length <= 32 * 1024 * 1024, 'renderer_process_failed');
  const reply = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(result.output[3]));
  requireThat(reply && typeof reply.ok === 'boolean' && reply.identity === identity, 'renderer_reply');
  if (!reply.ok) throw new Error(typeof reply.code === 'string' && /^[a-z_]+(?::[a-zA-Z0-9_-]{1,40}){0,2}$/.test(reply.code) ? reply.code : 'renderer_failed');
  requireThat(typeof reply.result?.html === 'string' && Buffer.byteLength(reply.result.html) <= profile.max_html_bytes && reply.result.index?.format === profile.index_format, 'renderer_reply');
  if (mapping) validateUsedImagePaths(reply.result.image_paths, mapping);
  return reply.result;
}
