import { isMathpixArchivePath, validateMathpixRenderInput } from '../mathpix-result.ts';
import type { MathpixRenderInput } from '../mathpix-result.ts';
import { MATHPIX_PROFILE } from '../mathpix.ts';
import { HTML_SUFFIX, htmlPrefix } from './html.ts';
import { admitReaderImage } from './images.ts';
import type { AdmittedImage } from './images.ts';
import { THIRD_PARTY_NOTICES } from './notice.ts';
import { BUNDLE_FORMAT, LIMITS, PROVENANCE_FORMAT, READER_CSS, RENDERER_BUILD_SHA256, RENDERER_ID, SOURCE_KIND } from './profile.ts';
import { renderMathpixDocument } from './render.ts';
import type { ReaderIndex, RenderStats } from './render.ts';
import { canonicalBytes, check, CONTROL, decodeUTF8, HEX64, sha256Hex, utf8 } from './util.ts';
import { validateReaderBundle } from './validate.ts';

export interface MathpixReaderProvenanceInput {
  ocr: { api: string; profile: string; options_sha256: string };
  provider_job_id: string;
  document: { sha256: string; page_count: number };
}
export interface MathpixReaderInput {
  // Complete expanded mmd.zip (see unpackReaderZip), keyed by archive path.
  // Exactly one *.mmd member is the source; figures resolve relative to it.
  archive: Map<string, Uint8Array>;
  provenance: MathpixReaderProvenanceInput;
  // Optional document credit appended to NOTICE.txt (for example CC BY 4.0).
  attribution?: string;
  // Used only when the MMD has no \title.
  titleFallback?: string;
}
export interface MathpixReaderBundle {
  manifestBytes: Uint8Array;
  manifestSHA256: string;
  members: Map<string, Uint8Array>;
  index: ReaderIndex;
  stats: RenderStats;
}

export function noticeText(attribution?: string): string {
  if (attribution === undefined) return THIRD_PARTY_NOTICES;
  const text = attribution.replace(/\r\n?/g, '\n').trim();
  check(text.length > 0 && !CONTROL.test(text) && utf8(text).length <= 8192, 'attribution_invalid');
  return `${THIRD_PARTY_NOTICES}\n\nDocument attribution\n============================================================\n${text}\n`;
}

// Bounded POSIX resolver: no schemes, absolute paths, encodings, queries or
// escape above the archive root. Provider image URLs are never fetched.
export function resolveArchiveImagePath(reference: string, sourcePath: string): string {
  check(typeof reference === 'string' && reference.length > 0 && reference.length <= 240 &&
    !/[\\%?#:\u0000- \u007f-￿]/.test(reference) && !reference.startsWith('/'), 'asset_reference');
  const parts = sourcePath.split('/').slice(0, -1);
  for (const part of reference.split('/')) {
    check(part.length > 0, 'asset_reference');
    if (part === '.') continue;
    if (part === '..') { check(parts.length > 0, 'asset_reference'); parts.pop(); } else parts.push(part);
  }
  const path = parts.join('/');
  check(isMathpixArchivePath(path), 'asset_reference');
  return path;
}

function checkProvenanceInput(value: MathpixReaderProvenanceInput): MathpixReaderProvenanceInput {
  check(value && typeof value === 'object', 'provenance_invalid');
  const { ocr, document } = value;
  // The options hash identifies the funded attempt's profile (e.g. its page cap);
  // the server binds it to the OCR run and the bundle digest.
  check(ocr?.api === 'v3/pdf' && ocr.profile === MATHPIX_PROFILE && typeof ocr.options_sha256 === 'string' && HEX64.test(ocr.options_sha256), 'provenance_ocr');
  check(typeof value.provider_job_id === 'string' && /^[A-Za-z0-9_-]{1,160}$/.test(value.provider_job_id), 'provenance_job');
  check(typeof document?.sha256 === 'string' && HEX64.test(document.sha256) && Number.isSafeInteger(document.page_count) &&
    document.page_count >= 1 && document.page_count <= 250, 'provenance_document');
  return { ocr: { api: ocr.api, profile: ocr.profile, options_sha256: ocr.options_sha256 }, provider_job_id: value.provider_job_id,
    document: { sha256: document.sha256, page_count: document.page_count } };
}

export async function renderMathpixReader(input: MathpixReaderInput): Promise<MathpixReaderBundle> {
  check(input && input.archive instanceof Map, 'archive_required');
  const provenance = checkProvenanceInput(input.provenance);
  // Own every archive byte before any processing.
  check(input.archive.size > 0 && input.archive.size <= LIMITS.archiveImages + 1, 'archive_limit');
  const archive = new Map<string, Uint8Array>();
  let archiveBytes = 0;
  for (const [path, bytes] of input.archive) {
    check(isMathpixArchivePath(path) && bytes instanceof Uint8Array && bytes.length <= LIMITS.memberBytes, 'archive_member');
    archiveBytes += bytes.length;
    check(archiveBytes <= LIMITS.bundleBytes, 'archive_limit');
    archive.set(path, new Uint8Array(bytes));
  }
  const sources = [...archive.keys()].filter(path => path.endsWith('.mmd'));
  check(sources.length === 1, 'mmd_ambiguous');
  const sourcePath = sources[0], sourceBytes = archive.get(sourcePath)!;
  check(sourceBytes.length > 0 && sourceBytes.length <= LIMITS.sourceBytes, 'source_limit');
  const source = decodeUTF8(sourceBytes, 'source_encoding');
  const notice = utf8(noticeText(input.attribution));
  check(notice.length <= LIMITS.noticeBytes, 'attribution_invalid');
  const sourceSHA256 = sha256Hex(sourceBytes);

  // Lazy figure admission: only referenced archive images are checked and
  // published. Names are content addresses of the canonical image bytes, so
  // identical images share one member while each figure keeps its own ID.
  const admitted = new Map<string, { image: AdmittedImage; path: string; inputSHA256: string }>();
  const published = new Map<string, AdmittedImage>();
  let pixels = 0;
  const rendered = renderMathpixDocument(source, sourceSHA256.slice(0, 12), reference => {
    const archivePath = resolveArchiveImagePath(reference, sourcePath);
    let entry = admitted.get(archivePath);
    if (!entry) {
      const bytes = archive.get(archivePath);
      check(bytes && archivePath !== sourcePath, 'asset_reference');
      check(admitted.size < LIMITS.archiveImages, 'image_limit');
      const image = admitReaderImage(bytes);
      const path = `assets/${sha256Hex(image.bytes)}.${image.extension}`;
      if (!published.has(path)) {
        pixels += image.width * image.height;
        check(pixels <= LIMITS.totalImagePixels, 'image_total_limit');
        published.set(path, image);
      }
      entry = { image, path, inputSHA256: sha256Hex(bytes) };
      admitted.set(archivePath, entry);
    }
    return { path: entry.path, width: entry.image.width, height: entry.image.height };
  }, input.titleFallback);
  const index = rendered.index;
  const imageInputs = [...admitted].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([archivePath, entry]) => ({
    archive_path: archivePath, input_sha256: entry.inputSHA256, published_path: entry.path,
    published_sha256: entry.path.slice(7, 71), media_type: entry.image.mediaType, width: entry.image.width, height: entry.image.height,
  }));
  const provenanceBytes = canonicalBytes({
    format: PROVENANCE_FORMAT, ocr: provenance.ocr, provider_job_id: provenance.provider_job_id, document: provenance.document,
    source: { archive_path: sourcePath, bytes: sourceBytes.length, sha256: sourceSHA256 },
    renderer: { id: RENDERER_ID, build_sha256: RENDERER_BUILD_SHA256 }, image_inputs: imageInputs,
  });
  const html = utf8(`${htmlPrefix(index.title)}${rendered.bodyHTML}${HTML_SUFFIX}`);
  check(html.length <= LIMITS.htmlBytes, 'html_limit');
  const indexBytes = canonicalBytes(index);
  check(indexBytes.length <= LIMITS.indexBytes, 'index_limit');

  const roles: Record<string, [string, string]> = {
    'index.html': ['html', 'text/html'], 'reader.json': ['index', 'application/json'], 'reader.css': ['style', 'text/css'],
    'provenance.json': ['provenance', 'application/json'], 'NOTICE.txt': ['notice', 'text/plain'],
  };
  const members = new Map<string, Uint8Array>([['index.html', html], ['reader.json', indexBytes], ['reader.css', utf8(READER_CSS)],
    ['provenance.json', provenanceBytes], ['NOTICE.txt', notice]]);
  for (const [path, image] of published) members.set(path, image.bytes);
  const entries = [...members].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([path, bytes]) => {
    const image = published.get(path);
    return { path, role: roles[path]?.[0] ?? 'image', media_type: roles[path]?.[1] ?? image!.mediaType, bytes: bytes.length,
      sha256: sha256Hex(bytes), ...(image ? { width: image.width, height: image.height } : {}) };
  });
  const manifestBytes = canonicalBytes({
    format: BUNDLE_FORMAT, renderer: { id: RENDERER_ID, build_sha256: RENDERER_BUILD_SHA256 },
    source: { kind: SOURCE_KIND, sha256: sourceSHA256, provenance_path: 'provenance.json' },
    entrypoint: 'index.html', index_path: 'reader.json', members: entries,
  });
  const manifestSHA256 = sha256Hex(manifestBytes);
  // The producer never returns what the independent validator would refuse.
  validateReaderBundle(manifestBytes, members, manifestSHA256);
  return { manifestBytes, manifestSHA256, members, index, stats: rendered.stats };
}

// Retained-output entry: revalidates the raw manifest and the complete
// expanded archive, then renders with provenance taken from that manifest.
export async function renderRetainedMathpixResult(input: MathpixRenderInput, options: { attribution?: string; titleFallback?: string } = {}): Promise<MathpixReaderBundle> {
  const checked = await validateMathpixRenderInput(input);
  const raw = checked.manifest;
  return renderMathpixReader({
    archive: checked.archiveMembers, attribution: options.attribution, titleFallback: options.titleFallback,
    provenance: { ocr: { ...raw.ocr }, provider_job_id: raw.attempt.provider_job_id,
      document: { sha256: raw.document.sha256, page_count: raw.document.page_count } },
  });
}
