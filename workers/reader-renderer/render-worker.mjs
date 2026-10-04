import { readSync, writeSync } from 'node:fs';
import { captureRendererIdentity } from './build-identity.mjs';

const identity = captureRendererIdentity();
let reply;
try {
  const chunks = []; let length = 0, maximum = 2 * 1024 * 1024;
  while (true) { const bytes = Buffer.alloc(Math.min(65536, maximum + 1 - length)); const count = readSync(0, bytes, 0, bytes.length, null); if (!count) break; length += count; if (length > maximum) throw new Error('render_request_limit'); chunks.push(bytes.subarray(0, count)); }
  const input = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, length)));
  if (!input || Object.keys(input).sort().join(',') !== 'images,source' || !Array.isArray(input.images)) throw new Error('render_request');
  const { profile, pathIsSafe } = await import('./common.mjs');
  if (typeof input.source !== 'string' || Buffer.byteLength(input.source) > profile.max_source_bytes || input.images.length > profile.max_figures || !input.images.every(row => Array.isArray(row) && row.length === 2 && pathIsSafe(row[0]) && row[1] && Object.keys(row[1]).sort().join(',') === 'height,width' && Number.isInteger(row[1].width) && Number.isInteger(row[1].height) && row[1].width > 0 && row[1].height > 0 && row[1].width <= profile.max_image_dimension && row[1].height <= profile.max_image_dimension && row[1].width * row[1].height <= profile.max_image_pixels) || new Set(input.images.map(row => row[0])).size !== input.images.length) throw new Error('render_request');
  const { renderIsolatedDocument } = await import('./render-document.mjs');
  if (captureRendererIdentity() !== identity) throw new Error('renderer_source_changed');
  const result = renderIsolatedDocument(input.source, new Map(input.images));
  if (captureRendererIdentity() !== identity) throw new Error('renderer_source_changed');
  reply = { ok: true, identity, result };
} catch (error) {
  reply = { ok: false, identity, code: typeof error?.message === 'string' && /^[a-z_]+(?::[a-zA-Z0-9_-]{1,40}){0,2}$/.test(error.message) ? error.message : 'renderer_failed' };
}
const bytes = Buffer.from(JSON.stringify(reply));
if (bytes.length > 32 * 1024 * 1024) throw new Error('render_reply_limit');
// Dedicated result pipe: upstream parser diagnostics are discarded, not mixed
// into output or archived. No original error/document content is returned.
let position = 0; while (position < bytes.length) position += writeSync(3, bytes, position, bytes.length - position);
