import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseDocument } from 'htmlparser2';
import { arxivHTMLURL, arxivInlineImages } from '../../supabase/functions/_shared/reader/arxiv-html.ts';
import { composeArxivReader, type ArxivImage } from '../../supabase/functions/_shared/reader/arxiv-bundle.ts';
import { prepare, svgImage, unpreparable } from '../../supabase/functions/_shared/reader/device-compiler.ts';
import { admitReaderImage } from '../../supabase/functions/_shared/reader/images.ts';
import { LIMITS } from '../../supabase/functions/_shared/reader/profile.ts';
import { validateReaderBundle } from '../../supabase/functions/_shared/reader/validate.ts';
import { decodeUTF8, sha256Hex, utf8 } from '../../supabase/functions/_shared/reader/util.ts';

// Revision 15 (build 58): an image the device can't prepare is its figure's loss, never the paper's. ActionOPD
// (2610.19820) was refused `svg_id` over a teaser SVG with two layers named alike; InfoVis (2610.16784) `image_dimensions`
// over a diagram too large to draw at twice its size. Both now open with every figure (reader-device-compile.mjs); a
// figure the device truly can't prepare reads as its caption under a note that the PDF has it.

const url = arxivHTMLURL('2601.01234', 2);
const source = readFileSync(new URL('../fixtures/reader-arxiv/source.html', import.meta.url), 'utf8');
const figures = readFileSync(new URL('../fixtures/reader-arxiv/figures.html', import.meta.url), 'utf8');
const raw = new Uint8Array(readFileSync(new URL('../fixtures/reader-mathpix/figure-exif.jpg', import.meta.url)));
const jpeg: ArxivImage = { ...admitReaderImage(raw), inputSHA256: sha256Hex(raw) };
// An inline picture is published as PNG.
const png = admitReaderImage(new Uint8Array(readFileSync(new URL('../fixtures/reader/assets/attention.png', import.meta.url))));
const html = (bundle: { members: Map<string, Uint8Array> }) => decodeUTF8(bundle.members.get('index.html')!);
const check = (bundle: ReturnType<typeof composeArxivReader>) => validateReaderBundle(bundle.manifestBytes, bundle.members, bundle.manifestSHA256);
const compose = (text: string, images: Map<string, ArxivImage | null>) => composeArxivReader({ source: utf8(text), sourceID: '2601.01234', revision: 2, images });

const WHOLE = /<p class="reader-caption"[^>]*><em>This figure couldn’t be shown here; the PDF has it\.<\/em> /;
const PART = '<p><em>Part of this figure couldn’t be shown here; the PDF has it.</em></p>';

test('a figure whose image the device couldn\'t prepare reads as its caption under a note; the paper opens', () => {
  const text = source.replace('<ol>', '<figure id="S1.F2"><img src="2601.01234v2/huge.png"><figcaption>Figure 2: Too large to read.</figcaption></figure><ol>');
  const bundle = compose(text, new Map([[url + '/figure.jpg', jpeg], [url + '/huge.png', null]]));
  const checked = check(bundle), page = html(bundle);
  assert.match(page, new RegExp(WHOLE.source + 'Figure 2: Too large to read\\.</p>'));
  assert.deepEqual(checked.index.figures.map(f => f.caption), ['Figure 1: A test figure.'], 'no figure entry without an image');
  assert.equal((checked.provenance.image_inputs as unknown[]).length, 1, 'only published images are inputs');
  assert.doesNotMatch(page, /huge\.png/);
  // The same paper with every image prepared is unchanged by the mechanism.
  const shown = check(compose(text, new Map([[url + '/figure.jpg', jpeg], [url + '/huge.png', jpeg]])));
  assert.equal(shown.index.figures.length, 2);
});

test('a panel the device couldn\'t prepare leaves a note in its place; the figure keeps its other images', () => {
  const panels = '<figure id="S1.F3"><img src="2601.01234v2/figure.jpg"><img src="2601.01234v2/a.png"><img src="2601.01234v2/b.png">'
    + '<figcaption>Figure 3: Three panels.</figcaption></figure>';
  const bundle = compose(source.replace('<ol>', panels + '<ol>'), new Map([[url + '/figure.jpg', jpeg], [url + '/a.png', null], [url + '/b.png', null]]));
  const checked = check(bundle), page = html(bundle);
  const figure = checked.index.figures.find(f => f.caption === 'Figure 3: Three panels.')!;
  assert.equal(figure.asset_paths.length, 1);
  // Two lost panels side by side say so once, before the caption.
  assert.equal(page.split(PART).length - 1, 1);
  assert.match(page, new RegExp(`<img [^>]+>${PART}<figcaption>Figure 3: Three panels\\.</figcaption></figure>`));
});

test('an inline picture the device couldn\'t prepare: a note in its place; a legend symbol in a line of words is left out and the figure says so once', () => {
  const inline = arxivInlineImages(figures, url);
  assert.deepEqual([...inline.keys()], ['#legend-symbol']);
  const bundle = compose(figures, new Map([[url + '/figure.jpg', jpeg], ['#legend-symbol', null]]));
  const checked = check(bundle), page = html(bundle);
  assert.equal(checked.index.figures.length, 4, 'every figure keeps its image');
  assert.equal((checked.provenance.inline_image_inputs as unknown[]).length, 0);
  assert.match(page, new RegExp(`${PART}<p> Retained legend text\\.`));
  // A key symbol beside its words (`reader-inline-image` when shown).
  const key = '<figure id="key"><img src="2601.01234v2/figure.jpg"><p><svg id="swatch" width="20" height="6" viewBox="0 0 20 6"><path d="M0 3L20 3"></path></svg> Model A</p>'
    + '<figcaption>Figure 4: With a key.</figcaption></figure>';
  const keyed = figures.replace('</article>', key + '</article>');
  const pictures = arxivInlineImages(keyed, url), picture = (id: string): ArxivImage => ({ ...png, inputSHA256: sha256Hex(utf8(pictures.get(id)!)) });
  const shown = html(compose(keyed, new Map([[url + '/figure.jpg', jpeg], ['#legend-symbol', picture('#legend-symbol')], ['#swatch', picture('#swatch')]])));
  assert.match(shown, /<p><img [^>]*class="reader-inline-image"[^>]*> Model A<\/p><figcaption>Figure 4/);
  const lost = compose(keyed, new Map([[url + '/figure.jpg', jpeg], ['#legend-symbol', picture('#legend-symbol')], ['#swatch', null]]));
  check(lost);
  assert.match(html(lost), new RegExp(`<p> Model A</p>${PART}<figcaption>Figure 4: With a key\\.</figcaption>`));
});

test('the image set stays exact: every referenced image is prepared or marked, nothing else', () => {
  assert.throws(() => compose(source, new Map()), /arxiv_asset_set/);
  assert.throws(() => compose(source, new Map([[url + '/figure.jpg', jpeg], [url + '/other.png', null]])), /arxiv_asset_set/);
});

test('one image\'s own refusals are unpreparable; the paper\'s totals, structure and host inputs still refuse', () => {
  for (const code of ['svg_id', 'svg_element', 'svg_resource', 'svg_dimensions', 'image_dimensions', 'image_dimensions_exceeded', 'invalid_image', 'image_decode', 'image_timeout'])
    assert.ok(unpreparable(new Error(code)), code);
  assert.ok(unpreparable(new DOMException('The source image cannot be decoded.', 'EncodingError')));
  for (const code of ['bundle_limit', 'image_total_limit', 'arxiv_asset_set', 'base64_limit', 'arxiv_math_coverage', 'source_limit'])
    assert.ok(!unpreparable(new Error(code)), code);
  assert.ok(!unpreparable(new TypeError('undefined is not a function')));
});

// A raster too large to read (here 20,000 px a side, past the 16,384 the device reads and scales) on the whole device
// path in Node: the compile plans it, refuses only that image, and the bundle validates.
function pngHeader(width: number, height: number): Uint8Array {
  const crc = (bytes: Uint8Array) => { let c = 0xffffffff; for (const b of bytes) { c ^= b; for (let i = 0; i < 8; i++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0); } return (c ^ 0xffffffff) >>> 0; };
  const chunk = (name: string, body: Uint8Array) => {
    const out = new Uint8Array(body.length + 12), view = new DataView(out.buffer);
    view.setUint32(0, body.length); out.set(utf8(name), 4); out.set(body, 8); view.setUint32(8 + body.length, crc(out.subarray(4, 8 + body.length))); return out;
  };
  const ihdr = new Uint8Array(13), view = new DataView(ihdr.buffer); view.setUint32(0, width); view.setUint32(4, height); ihdr[8] = 8; ihdr[9] = 6;
  const parts = [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', new Uint8Array([120, 156, 3, 0, 0, 0, 0, 1])), chunk('IEND', new Uint8Array())];
  return Uint8Array.from(parts.flatMap(p => [...p]));
}
const b64 = (bytes: Uint8Array) => Buffer.from(bytes).toString('base64');

test('device compile: an oversized raster becomes its figure\'s note, the paper opens', async () => {
  const text = source.replace('<ol>', '<figure id="S1.F2"><img src="2601.01234v2/huge.png"><figcaption>Figure 2: Twenty thousand pixels a side.</figcaption></figure><ol>');
  const result = await prepare(b64(utf8(text)), '2601.01234', 2, [{ url: url + '/figure.jpg', base64: b64(raw) }, { url: url + '/huge.png', base64: b64(pngHeader(20_000, 20_000)) }]);
  const members = new Map(result.members.map(m => [m.path, new Uint8Array(Buffer.from(m.base64, 'base64'))]));
  const checked = validateReaderBundle(new Uint8Array(Buffer.from(result.manifest, 'base64')), members, result.manifestSHA256);
  assert.match(decodeUTF8(members.get('index.html')!), new RegExp(WHOLE.source + 'Figure 2: Twenty thousand pixels a side\\.</p>'));
  assert.equal(checked.index.figures.length, 1);
});

// Node has no XML DOM; the device parses pictures with WebKit's or Chromium's. A small stand-in over htmlparser2's XML
// mode gives svgImage the same calls so its id and size rules run in the fast tier; the real parsers run in
// apps/web/e2e/arxiv-compiler.spec.ts and scripts/reader-device-compile.mjs.
type Raw = { type: string; name: string; data?: string; attribs: Record<string, string>; children: Raw[]; parent: Raw | null };
const isElement = (n: Raw) => n.attribs !== undefined;
class XMLElement {
  readonly raw: Raw;
  constructor(raw: Raw) { this.raw = raw; }
  get localName() { return this.raw.name.split(':').pop()!; }
  get namespaceURI() { for (let n: Raw | null = this.raw; n; n = n.parent) if (n.attribs?.xmlns) return n.attribs.xmlns; return null; }
  get id() { return this.raw.attribs.id ?? ''; }
  get children() { return this.raw.children.filter(isElement).map(c => new XMLElement(c)); }
  get attributes() { return Object.entries(this.raw.attribs).map(([name, value]) => ({ name, localName: name.split(':').pop()!, value })); }
  get textContent(): string { const text = (n: Raw): string => n.type === 'text' ? n.data ?? '' : (n.children ?? []).map(text).join(''); return text(this.raw); }
  getAttribute(name: string) { return this.raw.attribs[name] ?? null; }
  setAttribute(name: string, value: string) { this.raw.attribs[name] = value; }
  removeAttribute(name: string) { delete this.raw.attribs[name]; }
  remove() { if (this.raw.parent) this.raw.parent.children = this.raw.parent.children.filter(c => c !== this.raw); }
}
const serialize = (n: Raw): string => n.type === 'text' ? n.data ?? '' : !isElement(n) ? ''
  : `<${n.name}${Object.entries(n.attribs).map(([k, v]) => ` ${k}="${v}"`).join('')}>${n.children.map(serialize).join('')}</${n.name}>`;
Object.assign(globalThis, {
  DOMParser: class { parseFromString(text: string) {
    const root = (parseDocument(text, { xmlMode: true }) as unknown as Raw).children.find(isElement)!;
    return { documentElement: new XMLElement(root), querySelector: () => null };
  } },
  XMLSerializer: class { serializeToString(element: XMLElement) { return serialize(element.raw); } },
});

const svg = (body: string, size = 'width="20pt" height="10pt"') => utf8(`<svg xmlns="http://www.w3.org/2000/svg" ${size}>${body}</svg>`);
const layers = '<g id="layer_1" data-name="Layer 1"><path d="M0 0H1"/></g><g id="layer_1" data-name="Layer 2"><path d="M0 1H1"/></g>';

test('an SVG id given twice: kept on its first element when nothing refers to it, otherwise not drawn (2610.19820)', () => {
  const kept = svgImage(svg(layers));
  assert.equal(decodeUTF8(kept.bytes).match(/id="layer_1"/g)?.length, 1);
  assert.match(decodeUTF8(kept.bytes), /data-name="Layer 2"/, 'the second layer stays, without the id');
  assert.throws(() => svgImage(svg(layers + '<use href="#layer_1"/>')), /svg_id/);
  assert.throws(() => svgImage(svg(`<g style="clip-path:url(#layer_1)"/>${layers}`)), /svg_id/);
  assert.throws(() => svgImage(svg(`<style>#layer_1{fill:red}</style>${layers}`)), /svg_id/);
});

test('an SVG too large to draw at twice its size is drawn at the largest size allowed (2610.16784)', () => {
  const small = svgImage(svg('<path d="M0 0H1"/>', 'width="300" height="200"'));
  assert.deepEqual([small.width, small.height], [600, 400], 'within the limits: twice its size, as before');
  const big = svgImage(svg('<path d="M0 0H1"/>', 'width="1801.9199pt" height="1275.12pt" viewBox="0 0 1801.9199 1275.12"'));
  assert.ok(big.width * big.height <= LIMITS.imagePixels && big.width <= LIMITS.imageDimension && big.height <= LIMITS.imageDimension);
  assert.ok(big.width * big.height > LIMITS.imagePixels * 0.99, 'as large as the limits allow');
  assert.match(decodeUTF8(big.bytes), new RegExp(`width="${big.width}" height="${big.height}"`));
  const strip = svgImage(svg('', 'width="100000" height="1"'));
  assert.deepEqual([strip.width, strip.height], [LIMITS.imageDimension, 1]);
});

test('device compile: an SVG whose repeated id is referenced becomes its figure\'s note, the paper opens', async () => {
  const text = source.replace('<ol>', '<figure id="S1.F2"><img src="2601.01234v2/teaser.svg"><figcaption>Figure 2: Layers.</figcaption></figure><ol>');
  const result = await prepare(b64(utf8(text)), '2601.01234', 2, [{ url: url + '/figure.jpg', base64: b64(raw) },
    { url: url + '/teaser.svg', base64: b64(svg(layers + '<use href="#layer_1"/>')) }]);
  const members = new Map(result.members.map(m => [m.path, new Uint8Array(Buffer.from(m.base64, 'base64'))]));
  validateReaderBundle(new Uint8Array(Buffer.from(result.manifest, 'base64')), members, result.manifestSHA256);
  assert.match(decodeUTF8(members.get('index.html')!), new RegExp(WHOLE.source + 'Figure 2: Layers\\.</p>'));
});
