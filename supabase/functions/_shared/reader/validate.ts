import { isMathpixArchivePath } from '../mathpix-result.ts';
import { MATHPIX_PROFILE } from '../mathpix.ts';
import { validateHTML } from './html-validate.ts';
import { admitReaderImage } from './images.ts';
import { THIRD_PARTY_NOTICES } from './notice.ts';
import { BUNDLE_FORMAT, INDEX_FORMAT, LIMITS, PROVENANCE_FORMAT, READER_CSS, RENDERER_ID, SOURCE_KIND, ARXIV_SOURCE_BYTES } from './profile.ts';
import { canonicalBytes, check, CONTROL, decodeUTF8, excerpt, fail, HEX64, idIsSafe, memberPathIsSafe, sameBytes, sha256Hex, utf8 } from './util.ts';
import type { ReaderIndex } from './render.ts';
import { ARXIV_PROVENANCE_FORMAT, ARXIV_RENDERER_ID, ARXIV_SOURCE_KIND, arxivAssetURL, arxivHTMLURL } from './arxiv-html.ts';
import { ARXIV_CSS } from './arxiv-bundle.ts';

// Independent, rejecting check of a complete timestep-mathpix-mathml-v1
// bundle. It never repairs input. Callers still need an independently
// trusted manifest digest (never one taken from the same upload).
export interface ValidatedReaderBundle { manifest: Record<string, unknown>; index: ReaderIndex; provenance: Record<string, unknown> }

const ROLES: Record<string, string[]> = {
  html: ['text/html'], index: ['application/json'], provenance: ['application/json'], style: ['text/css'],
  notice: ['text/plain'], image: ['image/jpeg', 'image/png'],
};
const BLOCK_KINDS = new Set(['heading', 'paragraph', 'equation', 'figure', 'table', 'list', 'code']);

function record(value: unknown, keys: string[], code: string): Record<string, unknown> {
  check(value !== null && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value as object).sort().join(',') === [...keys].sort().join(','), code);
  return value as Record<string, unknown>;
}
const integer = (value: unknown, low: number, high: number): value is number =>
  typeof value === 'number' && Number.isSafeInteger(value) && value >= low && value <= high;
const text = (value: unknown, maximum: number): value is string =>
  typeof value === 'string' && !CONTROL.test(value) && utf8(value).length <= maximum;
function parseCanonical(bytes: Uint8Array, code: string): unknown {
  let value: unknown;
  try { value = JSON.parse(decodeUTF8(bytes, code)); } catch { fail(code); }
  check(sameBytes(canonicalBytes(value), bytes), code);
  return value;
}

export function validateReaderBundle(manifestBytes: Uint8Array, members: Map<string, Uint8Array>, expectedSHA256: string): ValidatedReaderBundle {
  check(manifestBytes instanceof Uint8Array && manifestBytes.length <= LIMITS.manifestBytes && typeof expectedSHA256 === 'string' &&
    HEX64.test(expectedSHA256) && sha256Hex(manifestBytes) === expectedSHA256, 'manifest_integrity');
  const manifest = record(parseCanonical(manifestBytes, 'manifest_canonical'),
    ['format', 'renderer', 'source', 'entrypoint', 'index_path', 'members'], 'manifest_format');
  const renderer = record(manifest.renderer, ['id', 'build_sha256'], 'manifest_format');
  const source = record(manifest.source, ['kind', 'sha256', 'provenance_path'], 'manifest_format');
  const extendedFigures = renderer.id === ARXIV_RENDERER_ID;
  const arxiv = [ARXIV_RENDERER_ID,'gradstep-arxiv-html-mathml-v1'].includes(renderer.id as string) && source.kind === ARXIV_SOURCE_KIND;
  check(manifest.format === BUNDLE_FORMAT && (arxiv || (renderer.id === RENDERER_ID && source.kind === SOURCE_KIND)) &&
    typeof renderer.build_sha256 === 'string' && HEX64.test(renderer.build_sha256) &&
    typeof source.sha256 === 'string' && HEX64.test(source.sha256), 'manifest_format');
  check(manifest.entrypoint === 'index.html' && manifest.index_path === 'reader.json' && source.provenance_path === 'provenance.json', 'entrypoint');
  check(members instanceof Map && Array.isArray(manifest.members) && manifest.members.length > 0 &&
    manifest.members.length <= LIMITS.members && members.size === manifest.members.length, 'member_count');

  // Members: exact paths, roles, media types, sizes and content hashes.
  const folded = new Set<string>(), byPath = new Map<string, Record<string, unknown>>();
  const imageMembers = new Map<string, { width: number; height: number; mediaType: string }>();
  let total = 0, pixels = 0, previous = '';
  for (const value of manifest.members as unknown[]) {
    const isImage = value !== null && typeof value === 'object' && (value as Record<string, unknown>).role === 'image';
    const member = record(value, ['path', 'role', 'media_type', 'bytes', 'sha256', ...(isImage ? ['width', 'height'] : [])], 'member_format');
    const path = member.path;
    check(memberPathIsSafe(path) && path > previous && path.toLowerCase() !== 'manifest.json' && !folded.has(path.toLowerCase()), 'member_path');
    previous = path; folded.add(path.toLowerCase());
    const bytes = members.get(path);
    check(bytes instanceof Uint8Array && integer(member.bytes, 1, LIMITS.memberBytes) && bytes.length === member.bytes &&
      sha256Hex(bytes) === member.sha256, 'member_integrity');
    check(typeof member.role === 'string' && ROLES[member.role]?.includes(member.media_type as string), 'member_role');
    total += bytes.length;
    check(total <= LIMITS.bundleBytes, 'bundle_limit');
    byPath.set(path, member);
    if (isImage) {
      const extension = member.media_type === 'image/jpeg' ? 'jpg' : 'png';
      check(path === `assets/${member.sha256}.${extension}`, 'member_path');
      // Canonical images are a fixed point of admission.
      const admitted = admitReaderImage(bytes);
      check(sameBytes(admitted.bytes, bytes) && admitted.mediaType === member.media_type &&
        admitted.width === member.width && admitted.height === member.height, 'member_image');
      pixels += admitted.width * admitted.height;
      check(pixels <= LIMITS.totalImagePixels, 'image_total_limit');
      imageMembers.set(path, { width: admitted.width, height: admitted.height, mediaType: admitted.mediaType });
    }
  }
  for (const path of folded) {
    const parts = path.split('/');
    for (let n = 1; n < parts.length; n++) check(!folded.has(parts.slice(0, n).join('/')), 'member_path');
  }
  const fixed: [string, string][] = [['index.html', 'html'], ['reader.json', 'index'], ['reader.css', 'style'],
    ['provenance.json', 'provenance'], ['NOTICE.txt', 'notice']];
  for (const [path, role] of fixed) check(byPath.get(path)?.role === role, 'entrypoint');
  check([...byPath.values()].filter(member => member.role !== 'image').length === fixed.length, 'member_role');
  check(sameBytes(members.get('reader.css')!, utf8(extendedFigures ? ARXIV_CSS : READER_CSS)), 'style_reference');
  const notice = decodeUTF8(members.get('NOTICE.txt')!, 'notice_invalid');
  check(notice.startsWith(THIRD_PARTY_NOTICES) && members.get('NOTICE.txt')!.length <= LIMITS.noticeBytes && !CONTROL.test(notice), 'notice_invalid');

  const index = validateIndex(members.get('reader.json')!, new Set(imageMembers.keys()));
  const provenance = arxiv ? validateArxivProvenance(members.get('provenance.json')!, renderer, source, imageMembers)
    : validateProvenance(members.get('provenance.json')!, renderer, source, imageMembers, index);
  validateHTML(members.get('index.html')!, index, imageMembers, extendedFigures);
  return { manifest, index, provenance };
}

function validateArxivProvenance(bytes: Uint8Array, renderer: Record<string, unknown>, source: Record<string, unknown>,
  images: Map<string, { width: number; height: number; mediaType: string }>): Record<string, unknown> {
  check(bytes.length <= LIMITS.provenanceBytes, 'provenance_limit');
  const extended = renderer.id === ARXIV_RENDERER_ID;
  const value = record(parseCanonical(bytes, 'provenance_format'), ['format', 'source', 'renderer', 'image_inputs', ...(extended ? ['inline_image_inputs'] : [])], 'provenance_format');
  check(value.format === (extended ? ARXIV_PROVENANCE_FORMAT : 'arxiv-html-reader-provenance-v1'), 'provenance_format');
  const input = record(value.source, ['arxiv_id', 'revision', 'url', 'bytes', 'sha256'], 'provenance_source');
  check(typeof input.arxiv_id === 'string' && integer(input.revision, 1, 2147483647) &&
    input.url === arxivHTMLURL(input.arxiv_id, input.revision) && integer(input.bytes, 1, ARXIV_SOURCE_BYTES) && input.sha256 === source.sha256, 'provenance_source');
  const build = record(value.renderer, ['id', 'build_sha256'], 'provenance_renderer');
  check(build.id === renderer.id && build.build_sha256 === renderer.build_sha256, 'provenance_renderer');
  check(Array.isArray(value.image_inputs) && value.image_inputs.length <= LIMITS.archiveImages, 'provenance_images');
  check(!extended || (Array.isArray(value.inline_image_inputs) && value.inline_image_inputs.length + value.image_inputs.length <= LIMITS.archiveImages), 'provenance_images');
  const published = new Set<string>();
  for (const [key, rows] of [['source_url',value.image_inputs], ...extended ? [['source_id',value.inline_image_inputs]] : []] as [string, unknown[]][]) {
   let previous = '';
   for (const raw of rows) {
    const row = record(raw, [key, 'input_sha256', 'published_path', 'published_sha256', 'media_type', 'width', 'height'], 'provenance_images');
    const path = row.published_path as string, image = images.get(path);
    check(typeof row[key] === 'string' && row[key] > previous &&
      (key === 'source_url' ? arxivAssetURL(row[key] as string, input.url as string) === row[key]
        : /^[A-Za-z_][A-Za-z0-9_.:-]{0,199}$/.test(row[key] as string) && row.media_type === 'image/png') &&
      typeof row.input_sha256 === 'string' && HEX64.test(row.input_sha256) && image &&
      path === `assets/${row.published_sha256}.${image.mediaType === 'image/png' ? 'png' : 'jpg'}` &&
      row.width === image.width && row.height === image.height && row.media_type === image.mediaType, 'provenance_images');
    previous = row[key] as string; published.add(path);
   }
  }
  check(published.size === images.size, 'provenance_images');
  return value;
}

function validateIndex(bytes: Uint8Array, images: Set<string>): ReaderIndex {
  check(bytes.length <= LIMITS.indexBytes, 'index_limit');
  const index = record(parseCanonical(bytes, 'index_format'), ['format', 'title', 'headings', 'blocks', 'equations', 'figures'], 'index_format');
  check(index.format === INDEX_FORMAT && text(index.title, LIMITS.headingBytes) && (index.title as string).length > 0, 'index_title');
  const limits: Record<string, number> = { blocks: LIMITS.blocks, headings: LIMITS.headings, equations: LIMITS.equations, figures: LIMITS.figures };
  for (const [key, limit] of Object.entries(limits)) {
    const rows = index[key];
    check(Array.isArray(rows) && rows.length <= limit, 'index_collection');
    const ids = new Set((rows as { id?: unknown }[]).map(row => row?.id));
    check(ids.size === rows.length && [...ids].every(idIsSafe), 'index_collection');
  }
  const blocks = new Map<string, string>();
  for (const value of index.blocks as unknown[]) {
    const block = record(value, ['id', 'kind', 'text'], 'index_block');
    check(BLOCK_KINDS.has(block.kind as string) && text(block.text, LIMITS.textBytes), 'index_block');
    blocks.set(block.id as string, block.kind as string);
  }
  check(blocks.size > 0, 'index_block');
  const headingIDs = new Set<string>();
  for (const value of index.headings as unknown[]) {
    const heading = record(value, ['id', 'level', 'title'], 'index_heading');
    check(blocks.get(heading.id as string) === 'heading' && !headingIDs.has(heading.id as string) && integer(heading.level, 1, 6) &&
      text(heading.title, LIMITS.headingBytes) && (heading.title as string).length > 0, 'index_heading');
    headingIDs.add(heading.id as string);
  }
  for (const value of index.equations as unknown[]) {
    const equation = record(value, ['id', 'block_id', 'latex', 'display', 'source_form'], 'index_equation');
    check(!blocks.has(equation.id as string) && blocks.has(equation.block_id as string) && typeof equation.display === 'boolean' &&
      (equation.source_form === 'body' || (equation.source_form === 'environment' && equation.display)) &&
      text(equation.latex, LIMITS.textBytes) && (equation.latex as string).trim().length > 0, 'index_equation');
  }
  const referenced = new Set<string>();
  for (const value of index.figures as unknown[]) {
    const figure = record(value, ['id', 'block_id', 'asset_paths', 'caption', 'alt'], 'index_figure');
    const paths = figure.asset_paths;
    check(figure.id === figure.block_id && blocks.get(figure.id as string) === 'figure' && Array.isArray(paths) &&
      paths.length >= 1 && paths.length <= LIMITS.imagesPerFigure && new Set(paths).size === paths.length &&
      paths.every(path => images.has(path as string)) && text(figure.caption, LIMITS.textBytes) &&
      text(figure.alt, LIMITS.textBytes) && (figure.alt as string).trim().length > 0, 'index_figure');
    for (const path of paths as string[]) referenced.add(path);
  }
  check(referenced.size === images.size, 'unused_asset');
  return index as unknown as ReaderIndex;
}

function validateProvenance(bytes: Uint8Array, renderer: Record<string, unknown>, source: Record<string, unknown>,
  images: Map<string, { width: number; height: number; mediaType: string }>, index: ReaderIndex): Record<string, unknown> {
  check(bytes.length <= LIMITS.provenanceBytes, 'provenance_limit');
  const value = record(parseCanonical(bytes, 'provenance_format'),
    ['format', 'ocr', 'provider_job_id', 'document', 'source', 'renderer', 'image_inputs'], 'provenance_format');
  const ocr = record(value.ocr, ['api', 'profile', 'options_sha256'], 'provenance_format');
  const document = record(value.document, ['sha256', 'page_count'], 'provenance_format');
  const input = record(value.source, ['archive_path', 'bytes', 'sha256'], 'provenance_format');
  const build = record(value.renderer, ['id', 'build_sha256'], 'provenance_format');
  check(value.format === PROVENANCE_FORMAT && ocr.api === 'v3/pdf' && ocr.profile === MATHPIX_PROFILE &&
    typeof ocr.options_sha256 === 'string' && HEX64.test(ocr.options_sha256) && typeof value.provider_job_id === 'string' &&
    /^[A-Za-z0-9_-]{1,160}$/.test(value.provider_job_id) && typeof document.sha256 === 'string' && HEX64.test(document.sha256) &&
    integer(document.page_count, 1, 250), 'provenance_format');
  check(isMathpixArchivePath(input.archive_path) && (input.archive_path as string).endsWith('.mmd') &&
    integer(input.bytes, 1, LIMITS.sourceBytes) && input.sha256 === source.sha256, 'provenance_source');
  check(build.id === renderer.id && build.build_sha256 === renderer.build_sha256, 'provenance_renderer');
  const rows = value.image_inputs;
  check(Array.isArray(rows) && rows.length <= LIMITS.archiveImages, 'provenance_images');
  const published = new Map<string, string>();
  let previous = '';
  for (const row of rows as unknown[]) {
    const image = record(row, ['archive_path', 'input_sha256', 'published_path', 'published_sha256', 'media_type', 'width', 'height'], 'provenance_images');
    const path = image.published_path as string, member = images.get(path);
    check(isMathpixArchivePath(image.archive_path) && (image.archive_path as string) > previous && image.archive_path !== input.archive_path &&
      typeof image.input_sha256 === 'string' && HEX64.test(image.input_sha256) && member !== undefined &&
      path === `assets/${image.published_sha256}.${member.mediaType === 'image/jpeg' ? 'jpg' : 'png'}` &&
      image.media_type === member.mediaType && image.width === member.width && image.height === member.height, 'provenance_images');
    previous = image.archive_path as string;
    published.set(path, path);
  }
  const referenced = new Set(index.figures.flatMap(figure => figure.asset_paths));
  check(published.size === images.size && [...images.keys()].every(path => published.has(path) && referenced.has(path)), 'provenance_images');
  return value;
}

