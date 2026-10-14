import { ARXIV_PROVENANCE_FORMAT, ARXIV_RENDERER_ID, ARXIV_RENDERER_REVISION, ARXIV_SOURCE_KIND,
  arxivHTMLAssets, arxivHTMLURL, arxivInlineImages, convertArxivHTML } from './arxiv-html.ts';
import { BUNDLE_FORMAT, LIMITS, READER_CSS } from './profile.ts';
import { THIRD_PARTY_NOTICES } from './notice.ts';
import { canonicalBytes, check, decodeUTF8, HEX64, sha256Hex, utf8 } from './util.ts';

export interface ArxivImage {
  bytes: Uint8Array; inputSHA256: string; mediaType: 'image/png' | 'image/jpeg'; width: number; height: number;
}
export interface ArxivBundleInput {
  source: Uint8Array; sourceID: string; revision: number; images: Map<string, ArxivImage>;
}
export const ARXIV_CSS = READER_CSS + '\nfigure img.reader-inline-image,body.reader-figure-detail figure img.reader-inline-image{display:inline-block;width:auto;height:.65em;max-width:none;margin:0 .15em;border-radius:0;vertical-align:baseline;background:transparent}\n';
export const ARXIV_BUILD_SHA256 = sha256Hex(canonicalBytes({ renderer: ARXIV_RENDERER_ID,
  revision: ARXIV_RENDERER_REVISION, css: sha256Hex(utf8(ARXIV_CSS)), notices: sha256Hex(utf8(THIRD_PARTY_NOTICES)) }));

/** Compose already decoded/admitted device images. Consumers independently verify the whole bundle. */
export function composeArxivReader(input: ArxivBundleInput) {
  check(input.source instanceof Uint8Array && input.source.length > 0 && input.source.length <= LIMITS.sourceBytes, 'source_limit');
  check(input.images instanceof Map && input.images.size <= LIMITS.archiveImages, 'image_limit');
  const source = decodeUTF8(input.source), url = arxivHTMLURL(input.sourceID, input.revision);
  const inline = arxivInlineImages(source, url);
  const required = [...arxivHTMLAssets(source, url), ...inline.keys()].sort();
  check(required.length === input.images.size && required.every(url => input.images.has(url)), 'arxiv_asset_set');
  const published = new Map<string, ArxivImage>();
  const references = new Map<string, { path: string; width: number; height: number }>();
  let pixels = 0, inputBytes = input.source.length;
  const imageInputs = required.map(sourceURL => {
    const image = input.images.get(sourceURL)!;
    check(image.bytes instanceof Uint8Array && image.bytes.length > 0 && image.bytes.length <= LIMITS.memberBytes &&
      HEX64.test(image.inputSHA256) && ['image/png', 'image/jpeg'].includes(image.mediaType) &&
      Number.isSafeInteger(image.width) && Number.isSafeInteger(image.height) && image.width > 0 && image.height > 0 &&
      image.width <= LIMITS.imageDimension && image.height <= LIMITS.imageDimension && image.width * image.height <= LIMITS.imagePixels, 'arxiv_asset');
    const digest = sha256Hex(image.bytes), path = `assets/${digest}.${image.mediaType === 'image/png' ? 'png' : 'jpg'}`;
    inputBytes += image.bytes.length; check(inputBytes <= LIMITS.bundleBytes, 'bundle_limit');
    if (!published.has(path)) { pixels += image.width * image.height; published.set(path, image); }
    check(pixels <= LIMITS.totalImagePixels, 'image_total_limit');
    references.set(sourceURL, { path, width: image.width, height: image.height });
    if (inline.has(sourceURL)) check(image.inputSHA256 === sha256Hex(utf8(inline.get(sourceURL)!)), 'arxiv_asset');
    return { ...(inline.has(sourceURL) ? {source_id:sourceURL.slice(1)} : {source_url:sourceURL}), input_sha256: image.inputSHA256, published_path: path, published_sha256: digest,
      media_type: image.mediaType, width: image.width, height: image.height };
  });
  const rendered = convertArxivHTML(source, url, reference => {
    const image = references.get(reference); check(image, 'arxiv_asset_missing'); return image;
  });
  check(JSON.stringify(rendered.imageURLs) === JSON.stringify(required), 'arxiv_asset_coverage');
  const sourceSHA256 = sha256Hex(input.source);
  const provenance = canonicalBytes({ format: ARXIV_PROVENANCE_FORMAT,
    source: { arxiv_id: input.sourceID, revision: input.revision, url, bytes: input.source.length, sha256: sourceSHA256 },
    renderer: { id: ARXIV_RENDERER_ID, build_sha256: ARXIV_BUILD_SHA256 },
    image_inputs: imageInputs.filter(i => 'source_url' in i), inline_image_inputs: imageInputs.filter(i => 'source_id' in i) });
  const members = new Map<string, Uint8Array>([['index.html', utf8(rendered.html)], ['reader.json', canonicalBytes(rendered.index)],
    ['reader.css', utf8(ARXIV_CSS)], ['provenance.json', provenance], ['NOTICE.txt', utf8(`${THIRD_PARTY_NOTICES}\n\nSource: ${url}\nPrepared on the reader's device from the official arXiv HTML.\n`)]]);
  for (const [path, image] of published) members.set(path, image.bytes);
  const fixed: Record<string, [string, string]> = { 'index.html': ['html', 'text/html'], 'reader.json': ['index', 'application/json'],
    'reader.css': ['style', 'text/css'], 'provenance.json': ['provenance', 'application/json'], 'NOTICE.txt': ['notice', 'text/plain'] };
  let total = 0;
  const entries = [...members].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([path, bytes]) => {
    total += bytes.length; check(bytes.length > 0 && bytes.length <= LIMITS.memberBytes && total <= LIMITS.bundleBytes, 'bundle_limit');
    const image = published.get(path);
    return { path, role: image ? 'image' : fixed[path][0], media_type: image?.mediaType ?? fixed[path][1], bytes: bytes.length,
      sha256: sha256Hex(bytes), ...(image ? { width: image.width, height: image.height } : {}) };
  });
  check(entries.length <= LIMITS.members && provenance.length <= LIMITS.provenanceBytes && members.get('reader.json')!.length <= LIMITS.indexBytes, 'bundle_limit');
  const manifestBytes = canonicalBytes({ format: BUNDLE_FORMAT, renderer: { id: ARXIV_RENDERER_ID, build_sha256: ARXIV_BUILD_SHA256 },
    source: { kind: ARXIV_SOURCE_KIND, sha256: sourceSHA256, provenance_path: 'provenance.json' },
    entrypoint: 'index.html', index_path: 'reader.json', members: entries });
  check(manifestBytes.length <= LIMITS.manifestBytes, 'manifest_limit');
  return { manifestBytes, manifestSHA256: sha256Hex(manifestBytes), members, index: rendered.index };
}
