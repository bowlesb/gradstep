// One bundled local compiler for WebKit and the browser. All bytes are supplied
// by the host. There is deliberately no fetch, service credential, or PDF parser.
import { zlibSync } from 'fflate';
import { arxivHTMLAssets, arxivHTMLURL, arxivInlineImages } from './arxiv-html.ts';
import { composeArxivReader, type ArxivImage } from './arxiv-bundle.ts';
import { LIMITS, ARXIV_SOURCE_BYTES } from './profile.ts';
import { check, decodeUTF8, sha256Hex, utf8 } from './util.ts';
import { validateHTML } from './html-validate.ts';
import { inspectImage } from '../images.ts';
import { admitReaderImage } from './images.ts';

const base64 = (bytes: Uint8Array): string => {
  let s = ''; for (let i = 0; i < bytes.length; i += 8192) s += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(s);
};
const decode64 = (value: string, maximum: number): Uint8Array => {
  check(typeof value === 'string' && value.length <= Math.ceil(maximum / 3) * 4 && /^[A-Za-z0-9+/]*={0,2}$/.test(value), 'base64_limit');
  const s = atob(value); check(s.length <= maximum, 'base64_limit'); return Uint8Array.from(s, c => c.charCodeAt(0));
};
function png(width: number, height: number, pixels: Uint8ClampedArray): Uint8Array {
  function chunk(name: string, body: Uint8Array) {
    const bytes = new Uint8Array(body.length + 12), view = new DataView(bytes.buffer);
    view.setUint32(0, body.length); bytes.set(utf8(name), 4); bytes.set(body, 8);
    let crc = 0xffffffff;
    for (const byte of bytes.subarray(4, 8 + body.length)) { crc ^= byte; for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0); }
    view.setUint32(8 + body.length, (crc ^ 0xffffffff) >>> 0); return bytes;
  }
  const header = new Uint8Array(13), view = new DataView(header.buffer);
  view.setUint32(0, width); view.setUint32(4, height); header[8] = 8; header[9] = 6;
  const stride = width * 4, rows = new Uint8Array((stride + 1) * height);
  for (let y = 0; y < height; y++) rows.set(pixels.subarray(y * stride, (y + 1) * stride), y * (stride + 1) + 1);
  const parts = [new Uint8Array([137,80,78,71,13,10,26,10]), chunk('IHDR', header), chunk('IDAT', zlibSync(rows, { level: 6 })), chunk('IEND', new Uint8Array())];
  const output = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let at = 0;
  for (const part of parts) { output.set(part, at); at += part.length; }
  check(output.length <= LIMITS.memberBytes, 'image_limit'); return output;
}

/** SVG is rasterized only after rejecting every executable/external resource.
 * It is decoded as an image under a no-network host CSP, never inserted into DOM. */
export function svgImage(input: Uint8Array): { bytes: Uint8Array; width: number; height: number } {
  const source = decodeUTF8(input);
  // arXiv/Matplotlib SVG often has a public SVG doctype. Remove only that exact
  // declaration, never entities or an internal subset, before XML parsing.
  const cleaned = source.replace(/<!DOCTYPE svg PUBLIC "-\/\/W3C\/\/DTD SVG 1\.1\/\/EN"\s+"http:\/\/www\.w3\.org\/Graphics\/SVG\/1\.1\/DTD\/svg11\.dtd">/g, '');
  check(!/<!DOCTYPE|<!ENTITY/i.test(cleaned), 'svg_doctype');
  const doc = new DOMParser().parseFromString(cleaned, 'image/svg+xml');
  const root = doc.documentElement;
  check(root.localName === 'svg' && !doc.querySelector('parsererror'), 'svg_invalid');
  const allowed = new Set(['svg','g','defs','path','rect','circle','ellipse','line','polyline','polygon','text','tspan','textPath','use',
    'symbol','clipPath','mask','linearGradient','radialGradient','stop','pattern','title','desc','style','metadata']);
  const ids = new Set<string>(), duplicates = new Set<string>(), fragments = new Set<string>(), styles: string[] = []; let count = 0;
  const safeCSS = (css: string) => {
    check(!/[@\\<>]|expression\s*\(|(?:https?|data|javascript):/i.test(css), 'svg_style');
    for (const match of css.matchAll(/url\s*\(([^)]*)\)/gi)) {
      const id = /^['"]?#([A-Za-z_][A-Za-z0-9_.:-]*)['"]?$/.exec(match[1].trim());
      check(id, 'svg_resource'); fragments.add(id[1]);
    }
  };
  function visit(node: Element, depth: number) {
    check(++count <= 100_000 && depth <= 100 && node.namespaceURI === 'http://www.w3.org/2000/svg' && allowed.has(node.localName), 'svg_element');
    if (node.localName === 'metadata') { node.remove(); return; }
    // An id given twice (2610.19820's teaser: two Illustrator layers both "layer_1") is kept on its first element; a
    // later copy loses it, which changes nothing unless something refers to that id (checked below).
    if (node.id) { if (ids.has(node.id)) { duplicates.add(node.id); node.removeAttribute('id'); } else ids.add(node.id); }
    for (const attr of Array.from(node.attributes)) {
      // MuPDF's vector glyphs carry their source character in data-text. It is
      // metadata, not CSS or rendered text; the referenced glyph path remains.
      if (attr.name === 'data-text') { node.removeAttribute(attr.name); continue; }
      check(!/^on/i.test(attr.localName) && !['base','src'].includes(attr.localName), 'svg_attribute');
      if (attr.name === 'xmlns' || attr.name === 'xmlns:xlink') continue;
      if (attr.localName === 'href') { check(/^#[A-Za-z_][A-Za-z0-9_.:-]*$/.test(attr.value), 'svg_resource'); fragments.add(attr.value.slice(1)); }
      else safeCSS(attr.value);
    }
    if (node.localName === 'style') { safeCSS(node.textContent ?? ''); styles.push(node.textContent ?? ''); }
    for (const child of Array.from(node.children)) visit(child, depth + 1);
  }
  visit(root, 0);
  check([...fragments].every(id => ids.has(id)), 'svg_fragment');
  // A reference to an id given twice (a fragment, or a style selector naming it) would be ambiguous: not drawn.
  check([...duplicates].every(id => !fragments.has(id) && !styles.some(css => css.includes('#' + id))), 'svg_id');
  const dimension = (s: string | null) => {
    const m = /^(\d+(?:\.\d+)?)(px|pt)?$/.exec(s ?? '');
    return m ? Number(m[1]) * (m[2] === 'pt' ? 4 / 3 : 1) : null;
  };
  const view = (root.getAttribute('viewBox') ?? '').trim().split(/[ ,]+/).map(Number);
  const w = dimension(root.getAttribute('width')) ?? (view.length === 4 ? view[2] : NaN);
  const h = dimension(root.getAttribute('height')) ?? (view.length === 4 ? view[3] : NaN);
  check(Number.isFinite(w) && Number.isFinite(h) && w! > 0 && h! > 0, 'svg_dimensions');
  let width = Math.ceil(w! * 2), height = Math.ceil(h! * 2);
  if (width > LIMITS.imageDimension || height > LIMITS.imageDimension || width * height > LIMITS.imagePixels) {
    // A picture too large to draw at twice its size (2610.16784's 1,802 × 1,275 pt data-engine diagram, refused
    // `image_dimensions` on build 58) is drawn at the largest size the reader allows: it is a vector, and the pixel
    // budget below keeps fewer pixels than that anyway.
    const scale = Math.min(LIMITS.imageDimension / w!, LIMITS.imageDimension / h!, Math.sqrt(LIMITS.imagePixels / (w! * h!)));
    width = Math.max(1, Math.floor(w! * scale)); height = Math.max(1, Math.floor(h! * scale));
  }
  root.setAttribute('width', String(width)); root.setAttribute('height', String(height));
  return { bytes: utf8(new XMLSerializer().serializeToString(root)), width, height };
}

/** The most pixels one image may keep: a figure reads sharp on a phone or an iPad well under this. */
const PIXEL_CAP = 3_000_000;
/** The pixels each of `count` images may keep so a paper's images together never pass the bundle's total
 * (Apertus 1.5 on build 42: 24 figures, fifteen of them pictures drawn at 2×, refused as `image_total_limit`). */
export function pixelBudget(count: number): number { return Math.min(PIXEL_CAP, Math.floor(LIMITS.totalImagePixels / Math.max(1, count))); }

/** A raster image the device keeps as it came when the reader's own admission accepts it within the budget
 * (the same bytes on every device, no re-encoding); a picture (SVG) or an over-large or inadmissible raster is
 * drawn, scaled to the budget, and encoded as PNG. */
async function raster(input: Uint8Array, svg: boolean, budget = PIXEL_CAP): Promise<ArxivImage> {
  let bytes = input, mediaType: string, width: number, height: number;
  if (svg) {
    const image = svgImage(input); bytes = image.bytes; width = image.width; height = image.height; mediaType = 'image/svg+xml';
  } else {
    // A figure larger than the reader keeps (Habitat's 9,900 × 1,938 plot, refused on build 46) is read and scaled
    // to the budget below; only an absurd size is refused.
    const image = inspectImage(input, { side: 16_384, pixels: 80_000_000 }); width = image.width; height = image.height; mediaType = image.mediaType;
    if (width * height <= budget) {
      try {
        const admitted = admitReaderImage(input);
        if (admitted.width === width && admitted.height === height)
          return { bytes: admitted.bytes, inputSHA256: sha256Hex(input), mediaType: admitted.mediaType, width, height };
      } catch { /* drawn below */ }
    }
  }
  if (svg) check(width * height <= LIMITS.imagePixels, 'image_dimensions');
  // Scaled down to the budget, never up; whole pixels, at least one.
  const scale = width * height > budget ? Math.sqrt(budget / (width * height)) : 1;
  const target = { width: Math.max(1, Math.floor(width * scale)), height: Math.max(1, Math.floor(height * scale)) };
  const image = new Image();
  image.src = `data:${mediaType};base64,${base64(bytes)}`;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([image.decode(), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('image_timeout')), 15_000); })]);
    check(image.naturalWidth === width && image.naturalHeight === height, 'image_dimensions');
    const canvas = document.createElement('canvas'); canvas.width = target.width; canvas.height = target.height;
    try {
      const ctx = canvas.getContext('2d', { willReadFrequently: true }); check(ctx, 'image_decode');
      ctx.drawImage(image, 0, 0, target.width, target.height);
      return { bytes: png(target.width, target.height, ctx.getImageData(0, 0, target.width, target.height).data), inputSHA256: sha256Hex(input),
        mediaType: 'image/png', width: target.width, height: target.height };
    } finally { canvas.width = canvas.height = 0; }
  } finally { clearTimeout(timer); image.removeAttribute('src'); }
}

/** One image's own refusals (revision 15; `raster` and `svgImage` above, the shared inspector's codes, the browser's
 * decode errors): an SVG the admission refuses, a raster too large to read or not a PNG/JPEG, a decode that fails or
 * times out, a drawing that encodes too large. That figure says it couldn't be shown; every other refusal (the
 * paper's totals, its structure, the host's inputs) still refuses the paper. */
const UNPREPARABLE = new Set(['utf8_invalid', 'svg_doctype', 'svg_invalid', 'svg_element', 'svg_id', 'svg_attribute', 'svg_resource',
  'svg_style', 'svg_fragment', 'svg_dimensions', 'image_dimensions', 'image_dimensions_exceeded', 'invalid_image', 'image_decode',
  'image_timeout', 'image_limit']);
export function unpreparable(error: unknown): boolean {
  const e = typeof error === 'object' && error !== null ? error as { message?: unknown; name?: unknown } : {};
  return UNPREPARABLE.has(String(e.message)) || ['EncodingError', 'SecurityError', 'InvalidStateError'].includes(String(e.name));
}

/** The catalog record the compile may lean on (names that were graphics, a paper without an `h1`), bounded. */
function convertOptions(options?: { authors?: unknown; title?: unknown }) {
  const authors = Array.isArray(options?.authors) ? options!.authors.filter((a): a is string => typeof a === 'string').slice(0, 64).map(a => a.slice(0, 256)) : [];
  const title = typeof options?.title === 'string' ? options.title.slice(0, 2000) : undefined;
  return { authors, title };
}
export function assets(source64: string, sourceID: string, revision: number, options?: { authors?: unknown; title?: unknown }): string[] {
  return arxivHTMLAssets(decodeUTF8(decode64(source64, ARXIV_SOURCE_BYTES)), arxivHTMLURL(sourceID, revision), convertOptions(options));
}
/** One declared asset as the host downloaded it: its bytes, or `missing` when arXiv didn't serve that one image (not
 * found, not an image, too large on its own). A missing image is that figure's loss, as an unpreparable one is; the
 * host still refuses for arXiv being busy or refusing, a lost connection, and the paper's byte budget. */
export type AssetInput = { url: string; base64: string; missing?: undefined } | { url: string; missing: true; base64?: undefined };
export async function prepare(source64: string, sourceID: string, revision: number, inputs: AssetInput[], options?: { authors?: unknown; title?: unknown }) {
  const { authors, title } = convertOptions(options);
  const source = decode64(source64, ARXIV_SOURCE_BYTES), urls = assets(source64, sourceID, revision, options);
  check(Array.isArray(inputs) && inputs.length === urls.length && new Set(inputs.map(i => i.url)).size === inputs.length &&
    inputs.every(i => urls.includes(i.url) && (i.missing === true ? i.base64 === undefined : typeof i.base64 === 'string')), 'arxiv_asset_set');
  const images = new Map<string, ArxivImage | null>(); let bytes = source.length, pixels = 0;
  const inline = arxivInlineImages(decodeUTF8(source), arxivHTMLURL(sourceID, revision), { authors, title });
  check(inputs.length + inline.size <= LIMITS.archiveImages, 'image_limit');
  for (const input of inputs) if (input.missing) images.set(input.url, null);
  function* decodeInputs() {
    for (const input of inputs) if (!input.missing) yield {key:input.url,data:decode64(input.base64,LIMITS.memberBytes),svg:/\.svg$/i.test(new URL(input.url).pathname)};
    for (const [key, xml] of inline) yield {key,data:utf8(xml),svg:true};
  }
  const budget = pixelBudget(inputs.length + inline.size);
  for (const input of decodeInputs()) {
    const data = input.data; bytes += data.length; check(bytes <= LIMITS.bundleBytes, 'bundle_limit');
    let image: ArxivImage | null;
    // One image this device can't prepare is that figure's loss, never the paper's: its figure says so and points to
    // the PDF (arxiv/figures.ts). Only the paper's totals (bytes, pixels, image count) refuse.
    try { image = await raster(data, input.svg, budget); }
    catch (error) { if (!unpreparable(error)) throw error; image = null; }
    if (image) { pixels += image.width * image.height; check(pixels <= LIMITS.totalImagePixels, 'image_total_limit'); }
    images.set(input.key, image);
  }
  const bundle = composeArxivReader({ source, sourceID, revision, images, authors, title });
  validateHTML(bundle.members.get('index.html')!, bundle.index,
    new Map(JSON.parse(decodeUTF8(bundle.manifestBytes)).members.filter((m: { role: string }) => m.role === 'image')
      .map((m: { path: string; width: number; height: number }) => [m.path, { width: m.width, height: m.height }])), true);
  return { manifest: base64(bundle.manifestBytes), manifestSHA256: bundle.manifestSHA256,
    members: [...bundle.members].map(([path, bytes]) => ({ path, base64: base64(bytes) })) };
}
