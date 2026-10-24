// The logical blocks in this reader's vocabulary (html.ts, html-validate.ts with the device-pdf extension), the
// formula images and figure crops within the bundle's budget, and the reference's index (`trace`) completed.
// Degrade, never refuse: past the image budget a formula shows its LaTeX as text and a figure is scaled down or
// shown by its caption; past the equation limit a formula is its own characters. Every degradation is counted.
import { el, outText, normalizeSpace, type OutNode } from '../html.ts';
import { LIMITS } from '../profile.ts';
import { check, CONTROL, excerpt, sha256Hex } from '../util.ts';
import { pyRound } from './geometry.ts';
import { MARKER, type LogicalBlock, type Reading } from './convert.ts';
import { CROP_SCALE, DPI, PLACEHOLDER, type DevicePDFHost, type Formula, type ImageRequest } from './types.ts';
import { decodeBase64 } from './base64.ts';
import type { ReaderIndex } from '../render.ts';

type Child = OutNode | string;
export interface EmittedImage { path: string; bytes: Uint8Array; width: number; height: number }
export interface Emitted {
  top: OutNode[]; index: ReaderIndex; images: Map<string, EmittedImage>;
  /** Each shown figure's crop on its page (port revision 10): [figure id, page index, x0, y0, x1, y1, page width, page
   * height], points from the top left of the page as shown (its crop box, turned by its /Rotate), so the apps can zoom
   * out of the crop onto the PDF itself. */
  figureRegions: [string, number, number, number, number, number, number, number][];
  degraded: { formulaText: number; figuresScaled: number; figuresOmitted: number; equationLimit: number; imageFailures: number };
}

/** Image budget: the Swift verifier admits ≤ 512 members (five are the page, index, style, provenance and notice),
 * ≤ 64 MP of images and ≤ 32 MiB in all. Figures may take most of it; formula images take what is left. */
const MAX_IMAGES = 507, FIGURE_PIXELS = 48_000_000, IMAGE_BYTES = 24 * 1024 * 1024;
const STYLE_NUMBER = (v: number) => { const n = Math.min(999, Math.max(0, v)); return String(pyRound(n, 3)); };
const cleanText = (text: string) => text.replaceAll(PLACEHOLDER, '').replace(/[\t\n\r]/g, ' ').replace(new RegExp(CONTROL.source, 'g'), '');

export function emit(reading: Reading, host: DevicePDFHost, fallbackTitle: string): Emitted {
  const { prefix, formulas } = reading;
  const images = new Map<string, EmittedImage>();
  let pixels = 0, imageBytes = 0;
  const degraded = { formulaText: 0, figuresScaled: 0, figuresOmitted: 0, equationLimit: 0, imageFailures: 0 };
  /** The image and where it sits on the page (pixels at the request's dpi): the request's rectangle, or the cleaned
   * image's own when the host cleaned it (its size must be the image's). */
  const fetchPlaced = (request: ImageRequest): { image: EmittedImage; rect: [number, number, number, number] } | null => {
    let result;
    try { result = host.image(request); } catch { degraded.imageFailures += 1; return null; }
    if (!result || typeof result.png !== 'string') { degraded.imageFailures += 1; return null; }
    let bytes: Uint8Array;
    try { bytes = decodeBase64(result.png, LIMITS.memberBytes); } catch { degraded.imageFailures += 1; return null; }
    const size = pngSize(bytes);
    if (!size || size.width !== result.width || size.height !== result.height || size.width > LIMITS.imageDimension ||
      size.height > LIMITS.imageDimension || size.width * size.height > LIMITS.imagePixels) { degraded.imageFailures += 1; return null; }
    let rect = request.rect;
    if (result.rect !== undefined) {
      const r = result.rect;
      if (!Array.isArray(r) || r.length !== 4 || !r.every(n => Number.isSafeInteger(n) && Math.abs(n) <= 1_000_000) ||
        r[2] - r[0] !== size.width || r[3] - r[1] !== size.height) { degraded.imageFailures += 1; return null; }
      rect = [r[0], r[1], r[2], r[3]];
    }
    const path = `assets/${sha256Hex(bytes)}.png`;
    const known = images.get(path);
    if (known) return { image: known, rect };
    if (images.size >= MAX_IMAGES || pixels + size.width * size.height > LIMITS.totalImagePixels || imageBytes + bytes.length > IMAGE_BYTES) return null;
    const image = { path, bytes, width: size.width, height: size.height };
    images.set(path, image); pixels += size.width * size.height; imageBytes += bytes.length;
    return { image, rect };
  };
  const fetchImage = (request: ImageRequest): EmittedImage | null => fetchPlaced(request)?.image ?? null;

  // Figures and image tables first, in document order: the paper's own pictures matter more than formula crops.
  const figureImages = new Map<LogicalBlock, EmittedImage | null>();
  const figureRects = new Map<LogicalBlock, [number, number, number, number]>();
  for (const block of reading.blocks) {
    if (block.kind !== 'figure') continue;
    const [x0, y0, x1, y1] = block.rect, area = (x1 - x0) * (y1 - y0);
    let f = 1;
    if (pixels + area > FIGURE_PIXELS) f = Math.sqrt(Math.max(0, FIGURE_PIXELS - pixels) / area);
    if (images.size >= MAX_IMAGES - 64 || f < 0.25) { figureImages.set(block, null); degraded.figuresOmitted += 1; continue; }
    if (f < 1) degraded.figuresScaled += 1;
    const rect: [number, number, number, number] = f < 1 ? [Math.floor(x0 * f), Math.floor(y0 * f), Math.ceil(x1 * f), Math.ceil(y1 * f)] : block.rect;
    const image = fetchImage({ page: block.page, dpi: DPI * f, rect });
    if (!image) degraded.figuresOmitted += 1;
    figureImages.set(block, image);
    // The image is exactly this rectangle of the page at DPI × f: in points, it is where the crop sits on the page.
    const k = 72 / (DPI * f);
    figureRects.set(block, [rect[0] * k, rect[1] * k, rect[2] * k, rect[3] * k]);
  }
  // Formula images for every formula that does not render, while the budget lasts. Each crop is cleaned (owner, build
  // 62: "an outline clean step where excess pixels around the edge are cleaned and then with margin"): the cut tails of
  // the lines above and below go, and the ink keeps a margin, 0.25 em for a display and 0.12 em inline (a line's
  // height has little room).
  const formulaImages = new Map<string, { image: EmittedImage; rect: [number, number, number, number] }>();
  for (const id of reading.committed) {
    const f = formulas.get(id)!;
    if (f.rendered) continue;
    const pad = 2.0, b = f.imageBox ?? f.box;
    const rect: [number, number, number, number] = [Math.trunc(Math.max(0, b[0] - pad) * CROP_SCALE), Math.trunc(Math.max(0, b[1] - pad) * CROP_SCALE),
      Math.trunc((b[2] + pad) * CROP_SCALE + 0.999), Math.trunc((b[3] + pad) * CROP_SCALE + 0.999)];
    if (rect[2] <= rect[0] || rect[3] <= rect[1]) continue;
    const em = (f.fontSize > 0 ? f.fontSize : 10) * CROP_SCALE;
    const placed = fetchPlaced({ page: f.page, dpi: 72 * CROP_SCALE, rect, clean: { em: pyRound(em, 2), margin: Math.round(em * (f.display ? 0.25 : 0.12)) } });
    if (placed) formulaImages.set(id, placed);
  }

  // -- blocks
  let issued = 0;
  const nextID = () => { issued += 1; check(issued <= LIMITS.blocks, 'block_limit'); return `b-${prefix}-${issued}`; };
  const top: OutNode[] = [];
  const blocks: { id: string; kind: string; node: OutNode }[] = [];
  const equations: ReaderIndex['equations'] = [], figures: ReaderIndex['figures'] = [];
  const figureRegions: Emitted['figureRegions'] = [];
  let h1: OutNode | null = null, navigable = 0;
  const block = (name: string, kind: string, children: Child[], attrs: Record<string, string> = {}): OutNode => {
    const id = nextID();
    const node = el(name, { ...attrs, id, 'data-reader-block': id, 'data-reader-kind': kind }, children);
    blocks.push({ id, kind, node });
    return node;
  };
  const latexOf = (f: Formula) => excerpt(cleanText(f.latex || '\\text{?}'), 4000) || '\\text{?}';
  const equation = (f: Formula, owner: () => string): Child => {
    if (equations.length >= LIMITS.equations) { degraded.equationLimit += 1; return cleanText(f.glyphText); }
    const latex = latexOf(f);
    const names = ['reader-equation', f.display ? 'reader-display' : 'reader-inline'];
    let children: Child[];
    const placed = formulaImages.get(f.id);
    if (f.rendered && f.mathml) {
      children = [f.mathml as OutNode];
      // A display's number (equationNumbers), beside it as the arXiv reader shows one.
      if (f.display && f.tag) { names.push('reader-tagged'); children.push(el('span', { class: 'reader-tag' }, [f.tag])); }
    }
    else if (placed) {
      names.push('reader-math-image');
      // Sized and aligned from where the image sits on the page (points = pixels / CROP_SCALE): at the paper's own size
      // relative to its text, its bottom as far below the formula's box as on the page, on a line's descender (0.22 em).
      const { image, rect } = placed, fs = f.fontSize > 0 ? f.fontSize : 10;
      const width = (rect[2] - rect[0]) / CROP_SCALE, height = (rect[3] - rect[1]) / CROP_SCALE, below = rect[3] / CROP_SCALE - f.box[3];
      const shift = -(below / fs + 0.22);
      const style = f.display ? `width:${STYLE_NUMBER(width / fs)}em`
        : `height:${STYLE_NUMBER(height / fs)}em;vertical-align:${shift < 0 ? '-' : ''}${STYLE_NUMBER(Math.abs(shift))}em`;
      children = [el('img', { src: image.path, width: String(image.width), height: String(image.height), alt: excerpt(latex, 200).trim() || 'equation', style })];
    } else {
      names.push('reader-math-fallback'); degraded.formulaText += 1;
      children = [f.display ? latex : `\\(${latex}\\)`];
    }
    equations.push({ id: f.id, block_id: owner(), latex, display: f.display, source_form: f.display ? 'environment' : 'body' });
    return el('span', { id: f.id, class: names.join(' '), 'data-reader-equation': f.id, 'data-latex': latex }, children);
  };
  /** Marked text as children: text, and an equation span for each committed formula (others leave no trace). */
  const content = (marked: string, owner: () => string): Child[] => {
    const out: Child[] = [];
    let last = 0;
    for (const match of marked.matchAll(MARKER)) {
      const before = cleanText(marked.slice(last, match.index));
      if (before) out.push(before);
      const f = formulas.get(match[1]);
      if (f) out.push(equation(f, owner));
      last = match.index! + match[0].length;
    }
    const rest = cleanText(marked.slice(last));
    if (rest) out.push(rest);
    return out;
  };
  const hasText = (children: Child[]) => normalizeSpace(children.map(c => typeof c === 'string' ? c : outText(c)).join('')).length > 0;
  // A block's id is known only once it is made; equations inside take it from here.
  let pendingID = '';
  const withBlock = (name: string, kind: string, make: (owner: () => string) => Child[], attrs: Record<string, string> = {}): OutNode | null => {
    const id = `b-${prefix}-${issued + 1}`; pendingID = id;
    const mark = equations.length;
    const children = make(() => pendingID);
    if (!hasText(children)) { equations.length = mark; return null; }
    const node = block(name, kind, children, attrs);
    check(node.attribs.id === id, 'block_identity');
    return node;
  };
  let referenceList: OutNode | null = null;
  for (const lb of reading.blocks) {
    if (lb.kind !== 'references') referenceList = null;
    switch (lb.kind) {
      case 'heading': {
        const level = lb.level === 1 && !h1 ? 1 : Math.max(2, lb.level);
        if (level > 1 && navigable >= LIMITS.headings) { const p = withBlock('p', 'paragraph', o => content(lb.marked, o)); if (p) top.push(p); break; }
        const node = withBlock(`h${level}`, 'heading', o => content(lb.marked, o));
        if (!node) break;
        if (level === 1) h1 = node; else navigable += 1;
        top.push(node); break;
      }
      case 'paragraph': {
        const role = { authors: 'reader-authors', abstract: 'reader-abstract', footnote: 'reader-footnote', '': '' }[lb.role];
        const node = withBlock('p', 'paragraph', o => content(lb.marked, o), role ? { class: role } : {});
        if (node) top.push(node); break;
      }
      case 'equation': {
        const f = formulas.get(lb.formula);
        if (!f) break;
        const node = equations.length >= LIMITS.equations ? withBlock('p', 'paragraph', () => [cleanText(f.glyphText)])
          : withBlock('p', 'equation', o => [equation(f, o)]);
        if (node) top.push(node); break;
      }
      case 'code': {
        const withMath = lb.lines.some(line => [...line.matchAll(MARKER)].some(m => formulas.has(m[1])));
        const node = withMath
          ? withBlock('p', 'paragraph', o => lb.lines.flatMap((line, i) => [...(i ? [el('br')] : []), ...content(line, o)]))
          : withBlock('pre', 'code', () => [el('code', {}, [lb.lines.map(line => cleanText(line.replace(MARKER, ''))).join('\n')])]);
        if (node) top.push(node); break;
      }
      case 'references': {
        if (!referenceList) { referenceList = el('ul', { class: 'reader-references' }, []); top.push(referenceList); }
        for (const ref of lb.refs) { const li = withBlock('li', 'list', () => [cleanText(ref)]); if (li) referenceList.children.push(li); }
        if (!referenceList.children.length) { top.splice(top.indexOf(referenceList), 1); referenceList = null; }
        break;
      }
      case 'figure': {
        const image = figureImages.get(lb) ?? null;
        const caption = cleanText(lb.caption);
        // A caption with its math (captionMath) is marked text; its formulas belong to the figure's block.
        const captionContent = (owner: () => string): Child[] => lb.captionMarked !== undefined ? content(lb.captionMarked, owner) : caption ? [caption] : [];
        if (!image) {
          if (caption) { const p = withBlock('p', 'paragraph', o => captionContent(o), { class: 'reader-caption' }); if (p) top.push(p); }
          break;
        }
        const traceID = reading.traceFigureBlocks.get(lb);
        const traced = reading.trace.figures.find(f => f.id === traceID);
        if (traced) traced.asset_paths = [image.path];
        const alt = excerpt(normalizeSpace(caption ? caption.split('. ')[0] : lb.table ? 'Table' : 'Figure'), 2000) || 'Figure';
        const id = `b-${prefix}-${issued + 1}`;
        const children: Child[] = [el('img', { src: image.path, width: String(image.width), height: String(image.height), alt })];
        const mark = equations.length;
        const captionChildren = caption ? captionContent(() => id) : [];
        const figcaption = captionChildren.length && hasText(captionChildren) ? el('figcaption', {}, captionChildren) : null;
        if (!figcaption) equations.length = mark;
        if (figcaption) children.push(figcaption);
        const node = block('figure', 'figure', children, { 'data-reader-figure': id });
        figures.push({ id, block_id: id, asset_paths: [image.path], caption: figcaption ? excerpt(normalizeSpace(outText(figcaption)), LIMITS.textBytes) : '', alt });
        const placed = figureRects.get(lb);
        const shown = reading.pages[lb.page];
        if (placed && shown) {
          const [x0, y0, x1, y1] = placed.map(v => pyRound(v, 2));
          figureRegions.push([id, lb.page, x0, y0, x1, y1, pyRound(shown.width, 2), pyRound(shown.height, 2)]);
        }
        top.push(node); break;
      }
      case 'cells': {
        const node = withBlock('div', 'table', o => {
          // The caption first: equations are indexed in document order.
          const caption = cleanText(lb.caption);
          const captionChildren = !caption ? [] : lb.captionMarked !== undefined ? content(lb.captionMarked, o) : [caption];
          const rows = lb.rows.map(row => el('tr', {}, row.map(cell => el('td', cell.span > 1 ? { colspan: String(Math.min(cell.span, 999)) } : {}, content(cell.marked, o)))));
          return [...(captionChildren.length ? [el('p', { class: 'reader-caption' }, captionChildren)] : []), el('table', {}, [el('tbody', {}, rows)])];
        }, { class: 'reader-table' });
        if (node) top.push(node); break;
      }
    }
  }
  if (!h1) {
    const title = excerpt(normalizeSpace(cleanText(fallbackTitle)), LIMITS.headingBytes) || 'Untitled paper';
    const id = nextID();
    h1 = el('h1', { id, 'data-reader-block': id, 'data-reader-kind': 'heading' }, [title]);
    blocks.unshift({ id, kind: 'heading', node: h1 }); top.unshift(h1);
  }
  const title = excerpt(normalizeSpace(outText(h1)), LIMITS.headingBytes);
  const headings = blocks.filter(b => b.kind === 'heading' && b.node !== h1).map(b => ({ id: b.id, level: Number(b.node.name.slice(1)),
    title: excerpt(normalizeSpace(outText(b.node)), LIMITS.headingBytes) })).filter(h => h.title.length > 0);
  // Blocks in document order (the fallback title first), as the DOM has them.
  const order = new Map<OutNode, number>(); let n = 0;
  const walk = (node: OutNode) => { order.set(node, n++); for (const c of node.children) if (typeof c !== 'string') walk(c); };
  top.forEach(walk);
  blocks.sort((a, b) => order.get(a.node)! - order.get(b.node)!);
  const index: ReaderIndex = { format: 'reader-index-v1', title, headings, equations, figures,
    blocks: blocks.map(b => ({ id: b.id, kind: b.kind, text: excerpt(normalizeSpace(outText(b.node)), LIMITS.textBytes) })) };
  return { top, index, images, figureRegions, degraded };
}

/** Width and height from a PNG's IHDR, or null when the bytes are not a PNG. */
export function pngSize(bytes: Uint8Array): { width: number; height: number } | null {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 33 || signature.some((b, i) => bytes[i] !== b)) return null;
  if (String.fromCharCode(...bytes.subarray(12, 16)) !== 'IHDR') return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const width = view.getUint32(16), height = view.getUint32(20);
  return width > 0 && height > 0 ? { width, height } : null;
}
