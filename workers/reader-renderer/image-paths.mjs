import { isMathpixArchivePath } from '../../supabase/functions/_shared/mathpix-result.ts';
import { profile, pathIsSafe, requireThat } from './common.mjs';

export function resolveArchiveImagePath(reference, sourcePath) {
  requireThat(isMathpixArchivePath(sourcePath) && sourcePath.endsWith('.mmd') && typeof reference === 'string' &&
    reference.length > 0 && reference.length <= 240 && !/[\\%?#:\u0000-\u0020\u007f-\uffff]/.test(reference) &&
    !reference.startsWith('/'), 'asset_reference');
  const parts = sourcePath.split('/').slice(0, -1);
  for (const part of reference.split('/')) {
    requireThat(part.length > 0, 'asset_reference');
    if (part === '.') continue;
    if (part === '..') { requireThat(parts.length > 0, 'asset_reference'); parts.pop(); }
    else parts.push(part);
  }
  const path = parts.join('/');
  requireThat(isMathpixArchivePath(path), 'asset_reference');
  return path;
}

// Candidate metadata is header-only and is not image admission. It may describe
// up to the full ZIP inventory, while actual referenced images remain <=128.
export function validateImageMapping(mapping, images) {
  requireThat(mapping && typeof mapping === 'object' && !Array.isArray(mapping) &&
    Object.keys(mapping).sort().join(',') === 'candidates,source_path' &&
    isMathpixArchivePath(mapping.source_path) && mapping.source_path.endsWith('.mmd') &&
    Array.isArray(mapping.candidates) && mapping.candidates.length <= 512, 'image_mapping');
  const paths = new Map(), destinations = new Set(); let previous = '';
  for (const row of mapping.candidates) {
    requireThat(Array.isArray(row) && row.length === 2 && isMathpixArchivePath(row[0]) && row[0] > previous &&
      row[0] !== mapping.source_path && typeof row[1] === 'string' && /^assets\/[a-f0-9]{64}\.png$/.test(row[1]) &&
      pathIsSafe(row[1]) && images.has(row[1]), 'image_mapping');
    paths.set(row[0], row[1]); destinations.add(row[1]); previous = row[0];
  }
  requireThat(destinations.size === images.size && images.size <= 512, 'image_mapping');
  return paths;
}

export function validateUsedImagePaths(paths, mapping) {
  requireThat(Array.isArray(paths) && paths.length <= profile.max_figures, 'image_mapping');
  const candidates = new Map(mapping.candidates); let previous = '';
  for (const path of paths) {
    requireThat(typeof path === 'string' && path > previous && candidates.has(path), 'image_mapping'); previous = path;
  }
  return candidates;
}
