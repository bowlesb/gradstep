import { profile, requireThat, decodeUTF8, jsonBytes } from './common.mjs';
import { MATHPIX_OPTIONS_SHA256, isMathpixArchivePath } from '../../supabase/functions/_shared/mathpix-result.ts';

function keys(value, names) {
  requireThat(value && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).sort().join(',') === [...names].sort().join(','), 'mathpix_provenance');
}
const hash = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const integer = (value, low, high) => Number.isSafeInteger(value) && value >= low && value <= high;

// Native admission implements this same finite, closed profile. Raw provider
// attempts and outputs stay server-side; this member binds their content root.
export function validateMathpixProvenance(bytes, manifest, index) {
  requireThat(bytes instanceof Uint8Array && bytes.length > 0 && bytes.length <= profile.max_manifest_bytes, 'mathpix_provenance_limit');
  let value;
  try { value = JSON.parse(decodeUTF8(bytes)); } catch { throw new Error('mathpix_provenance'); }
  keys(value, ['format', 'raw_result_sha256', 'document', 'ocr', 'source', 'image_inputs']);
  requireThat(value.format === 'mathpix-reader-provenance-v1' && hash(value.raw_result_sha256) &&
    jsonBytes(value).equals(Buffer.from(bytes)), 'mathpix_provenance');
  keys(value.document, ['sha256', 'bytes', 'page_count']);
  requireThat(hash(value.document.sha256) && integer(value.document.bytes, 8, 33554432) &&
    integer(value.document.page_count, 1, 250), 'mathpix_provenance');
  keys(value.ocr, ['api', 'profile', 'options_sha256']);
  requireThat(value.ocr.api === 'v3/pdf' && value.ocr.profile === 'science-reader-mmd-v1' &&
    value.ocr.options_sha256 === MATHPIX_OPTIONS_SHA256, 'mathpix_provenance');
  keys(value.source, ['archive_path', 'bytes', 'sha256']);
  requireThat(isMathpixArchivePath(value.source.archive_path) && value.source.archive_path.endsWith('.mmd') &&
    integer(value.source.bytes, 1, profile.max_source_bytes) && hash(value.source.sha256) &&
    value.source.sha256 === manifest.source.sha256, 'mathpix_provenance');
  requireThat(Array.isArray(value.image_inputs) && value.image_inputs.length <= profile.max_figures, 'mathpix_provenance');
  const images = new Map(manifest.members.filter(member => member.role === 'image').map(member => [member.path, member]));
  const published = new Map(); let previous = '';
  for (const input of value.image_inputs) {
    keys(input, ['archive_path', 'input_sha256', 'published_path', 'published_sha256', 'width', 'height']);
    requireThat(isMathpixArchivePath(input.archive_path) && input.archive_path > previous &&
      input.archive_path !== value.source.archive_path && hash(input.input_sha256) && hash(input.published_sha256) &&
      input.published_path === `assets/${input.input_sha256}.png` &&
      integer(input.width, 1, profile.max_image_dimension) && integer(input.height, 1, profile.max_image_dimension), 'mathpix_provenance');
    previous = input.archive_path;
    const member = images.get(input.published_path);
    requireThat(member && member.sha256 === input.published_sha256 && member.width === input.width && member.height === input.height, 'mathpix_provenance_image');
    const facts = `${input.input_sha256}:${input.published_sha256}:${input.width}:${input.height}`;
    requireThat(!published.has(input.published_path) || published.get(input.published_path) === facts, 'mathpix_provenance_image');
    published.set(input.published_path, facts);
  }
  const referenced = new Set(index.figures.flatMap(figure => figure.asset_paths));
  requireThat(published.size === images.size && referenced.size === images.size &&
    [...images.keys()].every(path => published.has(path) && referenced.has(path)), 'mathpix_provenance_image');
  return value;
}
