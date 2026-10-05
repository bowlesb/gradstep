import { isMathpixArchivePath } from '../mathpix-result.ts';
import { MATHPIX_PROFILE } from '../mathpix.ts';
import { CLASSES, domText, HTML_ATTRIBUTES, HTML_SUFFIX, htmlPrefix, isMathToken, MATH_ELEMENTS, mathAttributeIsSafe, normalizeSpace, parseHTML, PHRASING, serialize } from './html.ts';
import type { DomNode } from './html.ts';
import { admitReaderImage } from './images.ts';
import { THIRD_PARTY_NOTICES } from './notice.ts';
import { BUNDLE_FORMAT, INDEX_FORMAT, LIMITS, PROVENANCE_FORMAT, READER_CSS, RENDERER_ID, SOURCE_KIND } from './profile.ts';
import { canonicalBytes, check, CONTROL, decodeUTF8, excerpt, fail, HEX64, idIsSafe, memberPathIsSafe, sameBytes, sha256Hex, utf8 } from './util.ts';
import type { ReaderIndex } from './render.ts';

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
  check(manifest.format === BUNDLE_FORMAT && renderer.id === RENDERER_ID && source.kind === SOURCE_KIND &&
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
  check(sameBytes(members.get('reader.css')!, utf8(READER_CSS)), 'style_reference');
  const notice = decodeUTF8(members.get('NOTICE.txt')!, 'notice_invalid');
  check(notice.startsWith(THIRD_PARTY_NOTICES) && members.get('NOTICE.txt')!.length <= LIMITS.noticeBytes && !CONTROL.test(notice), 'notice_invalid');

  const index = validateIndex(members.get('reader.json')!, new Set(imageMembers.keys()));
  const provenance = validateProvenance(members.get('provenance.json')!, renderer, source, imageMembers, index);
  validateHTML(members.get('index.html')!, index, imageMembers);
  return { manifest, index, provenance };
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

// --- HTML ------------------------------------------------------------------

function attr(node: DomNode, name: string): string | undefined { return node.attribs?.[name]; }
const indexText = (node: DomNode, maximum: number) => excerpt(normalizeSpace(domText(node)), maximum);
const blank = (node: DomNode) => node.type === 'text' && !node.data.trim();

function validateHTML(bytes: Uint8Array, index: ReaderIndex, images: Map<string, { width: number; height: number }>): void {
  check(bytes.length <= LIMITS.htmlBytes, 'html_limit');
  const html = decodeUTF8(bytes, 'html_encoding');
  const prefix = htmlPrefix(index.title), suffix = HTML_SUFFIX;
  check(html.startsWith(prefix) && html.endsWith(suffix) && html.length >= prefix.length + suffix.length, 'html_structure');
  const body = html.slice(prefix.length, html.length - suffix.length);
  const root = parseHTML(body);
  // The generator's serialization is a parse fixed point; anything an HTML5
  // tree builder could restructure is refused by the content rules below.
  check(serialize(root) === body, 'html_canonical');

  const ids = new Set<string>(), fragments: string[] = [];
  const blocks: DomNode[] = [], equations: DomNode[] = [], figures: DomNode[] = [];
  const blockOf = (node: DomNode): DomNode | null => {
    for (let current: DomNode | null = node; current; current = current.parent) if (current.attribs?.['data-reader-block']) return current;
    return null;
  };
  const visit = (node: DomNode, inMath: boolean, inAnchor: boolean, phrasingOnly: boolean): void => {
    if (node.type === 'text') {
      check(!CONTROL.test(node.data), 'html_text');
      if (node.data.trim()) {
        check(blockOf(node) !== null, 'text_outside_block');
        if (inMath) check(node.parent && isMathToken(node.parent.name), 'math_text');
        else check(!['ul', 'ol', 'table', 'tbody', 'tr', 'figure'].includes(node.parent?.name ?? ''), 'html_text');
      }
      return;
    }
    check(node.type === 'tag', 'html_node_type');
    const name = node.name;
    if (inMath) {
      check(MATH_ELEMENTS.has(name) && name !== 'math', 'math_element');
      for (const [key, value] of Object.entries(node.attribs)) check(mathAttributeIsSafe(name, key, value), 'math_attribute');
      for (const child of node.children) visit(child, true, inAnchor, true);
      return;
    }
    check(name === 'math' || name in HTML_ATTRIBUTES, 'html_tag');
    if (phrasingOnly) check(PHRASING.has(name), 'html_content_model');
    if (name === 'math') {
      check(node.parent?.name === 'span' && attr(node.parent, 'data-reader-equation') !== undefined, 'math_context');
      for (const [key, value] of Object.entries(node.attribs)) check(mathAttributeIsSafe('math', key, value), 'math_attribute');
      for (const child of node.children) visit(child, true, inAnchor, true);
      return;
    }
    const allowed = HTML_ATTRIBUTES[name];
    for (const [key, value] of Object.entries(node.attribs)) {
      check(allowed.includes(key) && !CONTROL.test(value) && value.length <= LIMITS.textBytes * 2, `html_attribute:${name}`);
      if (key === 'id') { check(idIsSafe(value) && !ids.has(value), 'dom_id'); ids.add(value); }
      if (key === 'class') check(value.split(' ').every(item => CLASSES.has(item)), 'html_class');
    }
    if (attr(node, 'data-reader-block') !== undefined) {
      check(attr(node, 'id') === attr(node, 'data-reader-block') && blockOf(node.parent!) === null, 'block_nesting');
      blocks.push(node);
    }
    if (attr(node, 'data-reader-equation') !== undefined) equations.push(node);
    if (attr(node, 'data-reader-figure') !== undefined) figures.push(node);
    let childPhrasing = phrasingOnly || ['p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'figcaption', 'th', 'td', 'code', ...PHRASING].includes(name);
    switch (name) {
      case 'a': {
        check(!inAnchor, 'nested_anchor');
        const href = attr(node, 'href') ?? '';
        if (href.startsWith('#')) { check(attr(node, 'rel') === undefined, 'link_reference'); fragments.push(href.slice(1)); }
        else {
          let url: URL | null = null;
          try { url = new URL(href); } catch { /* refused below */ }
          check(url && url.protocol === 'https:' && url.href === href && !url.username && !url.password && !url.port &&
            attr(node, 'rel') === 'noopener noreferrer', 'link_reference');
        }
        for (const child of node.children) visit(child, false, true, true);
        return;
      }
      case 'img': {
        const image = images.get(attr(node, 'src') ?? '');
        check(node.parent?.name === 'figure' && image && attr(node, 'width') === String(image.width) &&
          attr(node, 'height') === String(image.height) && (attr(node, 'alt') ?? '').trim().length > 0, 'image_reference');
        return;
      }
      case 'figure': {
        const children = node.children.filter(child => !blank(child));
        const last = children[children.length - 1];
        const imgs = children.filter(child => child.name === 'img');
        check(imgs.length >= 1 && children.every((child, n) => child.name === 'img' || (child.name === 'figcaption' && n === children.length - 1)) &&
          (last.name === 'img' || last.name === 'figcaption'), 'figure_structure');
        break;
      }
      case 'div': check(attr(node, 'class') === 'reader-table', 'html_structure'); break;
      case 'table': check(node.children.filter(child => !blank(child)).every(child => child.name === 'tbody'), 'table_structure'); break;
      case 'tbody': check(node.parent?.name === 'table' && node.children.filter(child => !blank(child)).every(child => child.name === 'tr'), 'table_structure'); break;
      case 'tr': check(node.parent?.name === 'tbody' && node.children.filter(child => !blank(child)).every(child => child.name === 'td' || child.name === 'th'), 'table_structure'); break;
      case 'th': case 'td': {
        check(node.parent?.name === 'tr', 'table_structure');
        for (const key of ['colspan', 'rowspan']) { const value = attr(node, key); check(value === undefined || /^[1-9][0-9]{0,2}$/.test(value), 'table_structure'); }
        break;
      }
      case 'ul': case 'ol': {
        check(node.children.filter(child => !blank(child)).every(child => child.name === 'li'), 'list_structure');
        const start = attr(node, 'start');
        check(start === undefined || (name === 'ol' && /^-?[0-9]{1,6}$/.test(start)), 'list_structure');
        break;
      }
      case 'li': check(node.parent?.name === 'ul' || node.parent?.name === 'ol', 'list_structure'); childPhrasing = false; break;
      case 'pre': check(node.children.length === 1 && node.children[0].name === 'code', 'code_structure'); break;
      case 'code': check(node.children.every(child => child.type === 'text') || node.parent?.name !== 'pre', 'code_structure'); break;
      case 'figcaption': check(node.parent?.name === 'figure', 'figure_structure'); break;
      case 'span': {
        if (attr(node, 'data-reader-equation') !== undefined) {
          const names = (attr(node, 'class') ?? '').split(' ');
          const children = node.children.filter(child => !blank(child));
          const math = children.filter(child => child.name === 'math');
          check(names[0] === 'reader-equation' && (names[1] === 'reader-inline' || names[1] === 'reader-display') && attr(node, 'data-latex') !== undefined, 'equation_representation');
          const tagged = names.includes('reader-tagged'), fallback = names.includes('reader-math-fallback');
          check(names.length === 2 + Number(tagged) + Number(fallback) && !(tagged && fallback), 'equation_representation');
          if (fallback) check(children.length === 1 && children[0].type === 'text', 'equation_representation');
          else {
            check(math.length === 1 && children[0] === math[0] && children.length === (tagged ? 2 : 1), 'equation_representation');
            check((attr(math[0], 'display') === 'block') === (names[1] === 'reader-display'), 'equation_representation');
            if (tagged) check(children[1].name === 'span' && attr(children[1], 'class') === 'reader-tag' && names[1] === 'reader-display', 'equation_representation');
          }
        } else if (attr(node, 'class') === 'reader-tag') {
          check(node.parent && attr(node.parent, 'data-reader-equation') !== undefined && node.children.every(child => child.type === 'text'), 'equation_representation');
        } else check(attr(node, 'class') === 'reader-marker' && node.parent?.name === 'li', 'html_structure');
        break;
      }
      case 'p': {
        const names = attr(node, 'class');
        check(names === undefined || ['reader-authors', 'reader-abstract', 'reader-caption'].includes(names), 'html_class');
        break;
      }
    }
    for (const child of node.children) visit(child, false, inAnchor, childPhrasing);
  };
  for (const child of root.children) {
    if (blank(child)) continue;
    const name = child.name;
    check(child.type === 'tag' && (attr(child, 'data-reader-block') !== undefined || name === 'hr' ||
      ((name === 'ul' || name === 'ol') && child.children.filter(item => !blank(item)).every(item => attr(item, 'data-reader-block') !== undefined))), 'top_level');
    visit(child, false, false, false);
  }
  for (const id of fragments) check(ids.has(id), 'unresolved_fragment');

  // DOM and sidecar describe the same blocks, equations and figures, in order.
  check(blocks.length === index.blocks.length && equations.length === index.equations.length && figures.length === index.figures.length, 'index_identity');
  const blockByID = new Map<string, DomNode>();
  blocks.forEach((node, n) => {
    const row = index.blocks[n];
    check(attr(node, 'id') === row.id && attr(node, 'data-reader-kind') === row.kind && row.text === indexText(node, LIMITS.textBytes), 'index_identity');
    const expected: Record<string, string[]> = { heading: ['h1', 'h2', 'h3', 'h4', 'h5', 'h6'], paragraph: ['p'], equation: ['p'],
      figure: ['figure'], table: ['div'], list: ['li'], code: ['pre'] };
    check(expected[row.kind].includes(node.name) && (row.kind === 'figure') === (attr(node, 'data-reader-figure') !== undefined), 'index_identity');
    blockByID.set(row.id, node);
  });
  // Exactly one H1 carries the document title; every other heading is navigable.
  const headingBlocks = blocks.filter(node => attr(node, 'data-reader-kind') === 'heading');
  const titles = headingBlocks.filter(node => node.name === 'h1');
  check(titles.length === 1 && indexText(titles[0], LIMITS.headingBytes) === index.title, 'index_title');
  const navigable = headingBlocks.filter(node => node !== titles[0] && indexText(node, LIMITS.headingBytes).length > 0);
  check(navigable.length === index.headings.length && navigable.every((node, n) => attr(node, 'id') === index.headings[n].id &&
    node.name === `h${index.headings[n].level}` && indexText(node, LIMITS.headingBytes) === index.headings[n].title), 'index_heading');
  equations.forEach((node, n) => {
    const row = index.equations[n];
    check(attr(node, 'id') === row.id && attr(node, 'data-reader-equation') === row.id && attr(node, 'data-latex') === row.latex &&
      blockOf(node) === blockByID.get(row.block_id) && (attr(node, 'class') ?? '').split(' ')[1] === (row.display ? 'reader-display' : 'reader-inline'), 'equation_identity');
    if ((attr(node, 'class') ?? '').includes('reader-math-fallback')) {
      check(node.children[0].data === (row.display ? row.latex : `\\(${row.latex}\\)`), 'equation_representation');
    }
  });
  figures.forEach((node, n) => {
    const row = index.figures[n];
    const imgs = node.children.filter(child => child.name === 'img');
    const caption = node.children.find(child => child.name === 'figcaption');
    check(attr(node, 'id') === row.id && attr(node, 'data-reader-figure') === row.id &&
      JSON.stringify([...new Set(imgs.map(img => attr(img, 'src')))]) === JSON.stringify(row.asset_paths) &&
      imgs.every(img => attr(img, 'alt') === row.alt) &&
      row.caption === (caption ? indexText(caption, LIMITS.textBytes) : ''), 'figure_identity');
  });
}

