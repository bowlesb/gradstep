// The native app's metadata extractor (arxiv-source-metadata.js, built by scripts/build-arxiv-compiler.mjs): a separate
// bundle from the reader compiler, so reading a paper's metadata never changes how it is prepared
// (docs/architecture/ARXIV_DEVICE_ONLY.md §5.3). Host: `GradstepSourceMetadata.extract(html, sourceID, revision)` and
// `GradstepSourceMetadata.fromAtom(xml, sourceID, revision)` return the record as JSON, or "null".
import './jsc-text-encoder.ts';
import { extractSourceMetadata, sourceMetadataFromAtom } from './arxiv/source-metadata.ts';

export function extract(html: string, sourceID: string, revision: number): string {
  if (typeof html !== 'string' || typeof sourceID !== 'string' || !Number.isSafeInteger(revision)) return 'null';
  try {
    const result = extractSourceMetadata(html, sourceID, revision);
    return JSON.stringify(result ? result.metadata : null);
  } catch {
    return 'null';
  }
}

/** The export API's Atom answer for one exact version (the native fallback for a paper without HTML). */
export function fromAtom(xml: string, sourceID: string, revision: number): string {
  if (typeof xml !== 'string' || typeof sourceID !== 'string' || !Number.isSafeInteger(revision)) return 'null';
  try {
    const result = sourceMetadataFromAtom(xml, sourceID, revision);
    return JSON.stringify(result ? result.metadata : null);
  } catch {
    return 'null';
  }
}
