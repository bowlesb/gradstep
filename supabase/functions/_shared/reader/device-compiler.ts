// One bundled local compiler for WebKit and the browser. All bytes are supplied
// by the host. There is deliberately no fetch, service credential, or PDF parser.
import { zlibSync } from 'fflate';
import { arxivHTMLAssets, arxivHTMLURL, arxivInlineImages } from './arxiv-html.ts';
import { composeArxivReader, type ArxivImage } from './arxiv-bundle.ts';
import { LIMITS } from './profile.ts';
import { check, decodeUTF8, sha256Hex, utf8 } from './util.ts';
import { validateHTML } from './html-validate.ts';
import { inspectImage } from '../images.ts';

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
function svgImage(input: Uint8Array): { bytes: Uint8Array; width: number; height: number } {
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
  const ids = new Set<string>(), fragments = new Set<string>(); let count = 0;
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
    if (node.id) { check(!ids.has(node.id), 'svg_id'); ids.add(node.id); }
    for (const attr of Array.from(node.attributes)) {
      // MuPDF's vector glyphs carry their source character in data-text. It is
      // metadata, not CSS or rendered text; the referenced glyph path remains.
      if (attr.name === 'data-text') { node.removeAttribute(attr.name); continue; }
      check(!/^on/i.test(attr.localName) && !['base','src'].includes(attr.localName), 'svg_attribute');
      if (attr.name === 'xmlns' || attr.name === 'xmlns:xlink') continue;
      if (attr.localName === 'href') { check(/^#[A-Za-z_][A-Za-z0-9_.:-]*$/.test(attr.value), 'svg_resource'); fragments.add(attr.value.slice(1)); }
      else safeCSS(attr.value);
    }
    if (node.localName === 'style') safeCSS(node.textContent ?? '');
    for (const child of Array.from(node.children)) visit(child, depth + 1);
  }
  visit(root, 0);
  check([...fragments].every(id => ids.has(id)), 'svg_fragment');
  const dimension = (s: string | null) => {
    const m = /^(\d+(?:\.\d+)?)(px|pt)?$/.exec(s ?? '');
    return m ? Number(m[1]) * (m[2] === 'pt' ? 4 / 3 : 1) : null;
  };
  const view = (root.getAttribute('viewBox') ?? '').trim().split(/[ ,]+/).map(Number);
  const w = dimension(root.getAttribute('width')) ?? (view.length === 4 ? view[2] : NaN);
  const h = dimension(root.getAttribute('height')) ?? (view.length === 4 ? view[3] : NaN);
  check(Number.isFinite(w) && Number.isFinite(h) && w! > 0 && h! > 0, 'svg_dimensions');
  const width = Math.ceil(w! * 2), height = Math.ceil(h! * 2);
  check(width <= LIMITS.imageDimension && height <= LIMITS.imageDimension && width * height <= LIMITS.imagePixels, 'image_dimensions');
  root.setAttribute('width', String(width)); root.setAttribute('height', String(height));
  return { bytes: utf8(new XMLSerializer().serializeToString(root)), width, height };
}

async function raster(input: Uint8Array, svg: boolean): Promise<ArxivImage> {
  let bytes = input, mediaType: string, width: number, height: number;
  if (svg) {
    const image = svgImage(input); bytes = image.bytes; width = image.width; height = image.height; mediaType = 'image/svg+xml';
  } else {
    const image = inspectImage(input); width = image.width; height = image.height; mediaType = image.mediaType;
  }
  check(width * height <= LIMITS.imagePixels, 'image_dimensions');
  const image = new Image();
  image.src = `data:${mediaType};base64,${base64(bytes)}`;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([image.decode(), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('image_timeout')), 15_000); })]);
    check(image.naturalWidth === width && image.naturalHeight === height, 'image_dimensions');
    const canvas = document.createElement('canvas'); canvas.width = width; canvas.height = height;
    try {
      const ctx = canvas.getContext('2d', { willReadFrequently: true }); check(ctx, 'image_decode');
      ctx.drawImage(image, 0, 0, width, height);
      return { bytes: png(width, height, ctx.getImageData(0, 0, width, height).data), inputSHA256: sha256Hex(input), mediaType: 'image/png', width, height };
    } finally { canvas.width = canvas.height = 0; }
  } finally { clearTimeout(timer); image.removeAttribute('src'); }
}

export function assets(source64: string, sourceID: string, revision: number): string[] {
  return arxivHTMLAssets(decodeUTF8(decode64(source64, LIMITS.sourceBytes)), arxivHTMLURL(sourceID, revision));
}
export async function prepare(source64: string, sourceID: string, revision: number, inputs: { url: string; base64: string }[]) {
  const source = decode64(source64, LIMITS.sourceBytes), urls = assets(source64, sourceID, revision);
  check(Array.isArray(inputs) && inputs.length === urls.length && new Set(inputs.map(i => i.url)).size === inputs.length &&
    inputs.every(i => urls.includes(i.url)), 'arxiv_asset_set');
  const images = new Map<string, ArxivImage>(); let bytes = source.length, pixels = 0;
  const inline = arxivInlineImages(decodeUTF8(source));
  check(inputs.length + inline.size <= LIMITS.archiveImages, 'image_limit');
  function* decodeInputs() {
    for (const input of inputs) yield {key:input.url,data:decode64(input.base64,LIMITS.memberBytes),svg:/\.svg$/i.test(new URL(input.url).pathname)};
    for (const [key, xml] of inline) yield {key,data:utf8(xml),svg:true};
  }
  for (const input of decodeInputs()) {
    const data = input.data; bytes += data.length; check(bytes <= LIMITS.bundleBytes, 'bundle_limit');
    const image = await raster(data, input.svg); pixels += image.width * image.height;
    check(pixels <= LIMITS.totalImagePixels, 'image_total_limit'); images.set(input.key, image);
  }
  const bundle = composeArxivReader({ source, sourceID, revision, images });
  validateHTML(bundle.members.get('index.html')!, bundle.index,
    new Map(JSON.parse(decodeUTF8(bundle.manifestBytes)).members.filter((m: { role: string }) => m.role === 'image')
      .map((m: { path: string; width: number; height: number }) => [m.path, { width: m.width, height: m.height }])), true);
  return { manifest: base64(bundle.manifestBytes), manifestSHA256: bundle.manifestSHA256,
    members: [...bundle.members].map(([path, bytes]) => ({ path, base64: base64(bytes) })) };
}
