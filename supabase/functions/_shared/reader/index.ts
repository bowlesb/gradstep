// Public surface of the Edge-compatible reader renderer (timestep-mathpix-mathml-v1).
import { unpackReaderZip } from '../archive.ts';

export { renderMathpixReader, renderRetainedMathpixResult, resolveArchiveImagePath } from './bundle.ts';
export type { MathpixReaderBundle, MathpixReaderInput, MathpixReaderProvenanceInput } from './bundle.ts';
export { validateReaderBundle } from './validate.ts';
export type { ValidatedReaderBundle } from './validate.ts';
export type { ReaderIndex, RenderStats } from './render.ts';
export { admitReaderImage } from './images.ts';
export { BUNDLE_FORMAT, CSP, INDEX_FORMAT, LIMITS, PROVENANCE_FORMAT, RENDERER_BUILD_SHA256, RENDERER_ID, SOURCE_KIND } from './profile.ts';
export { ReaderRenderError } from './util.ts';

// Expands Mathpix's mmd.zip with the restricted reader-zip-v1 profile.
export async function readMathpixArchive(zip: Uint8Array, signal?: AbortSignal): Promise<Map<string, Uint8Array>> {
  return new Map((await unpackReaderZip(zip, signal)).map(file => [file.path, file.bytes]));
}
