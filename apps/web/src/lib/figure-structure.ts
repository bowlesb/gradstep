// Structure first (docs/architecture/FIGURE_VIEW.md "Structure first"; subfigure detector round 3: 15.7 % of arXiv HTML
// figures already hold two or more images, 9.6 % with sub-captions). When the reader bundle's figure has several images,
// its parts are exact, no model needed: each image (or each sub-caption's images) is one band of the composed image the
// request carries (chat-figures.ts `composeFigure`: every image scaled to the widest one's width, stacked top to bottom
// with 2 % of the width of white between them). This module reads that structure from the figure's own markup in the
// bundle, describes it to the model next to the caption (so its sections line up), and matches the walkthrough's
// sections to it: by sub-caption letter (or label), then by a box that is clearly one band, then by order when the counts
// agree. A matched part is shown as its band, at the highest confidence (figure-framing.ts `exact`).
// The same rules, numbers and fixtures as ScienceReaderCore/FigureStructure.swift (tests/fixtures/figure-crops/structure.json).
import type { VerifiedBundle } from './bundle';
import type { Rect } from './figure-crops';
import { captionLetters, labelLetter } from './figure-framing';

/** Every threshold of the structure, in one place (the Swift port's `FigureStructure.Parameters`; the fixture states them). */
export const STRUCTURE = {
  /** Images composed into the one image a request carries (chat-figures.ts `MAX_PANELS`). */
  maxImages: 4,
  /** A walkthrough box matches a sub-figure when their intersection over union is at least this. */
  boxMatch: 0.6,
  /** The longest sub-caption quoted to the model, in characters. */
  captionChars: 100,
  /** The selection's limit (chat.ts `MAX_SELECTION_SCALARS`): the note is left out when caption and note don't fit. */
  quoteScalars: 4000,
} as const;

/** One sub-figure: its letter ("a"; null when neither it nor the caption names one), its sub-caption's words (without the
 * letter), the label the model is asked to use ("(a)", else "Image 2"), its images (indices into the figure's asset
 * paths) and its band of the composed image, [x0, y0, x1, y1] fractions. */
export interface StructurePart { letter: string | null; caption: string; label: string; images: number[]; rect: Rect }
/** A figure's own structure: its sub-figures (at least two, all within the composed image), how many panel images the
 * figure has and how many of its images the composed image holds, and the composed image's size before scaling. */
export interface FigureStructure { parts: StructurePart[]; images: number; composed: number; width: number; height: number }

/** The composed image's layout (chat-figures.ts `composeFigure`, ChatFigureFinder.composite): width, height, and each
 * image's band [top, bottom] in its pixels. */
export function stackLayout(sizes: { width: number; height: number }[]): { width: number; height: number; bands: [number, number][] } {
  const width = Math.max(...sizes.map(s => s.width)), gap = Math.max(1, Math.round(width * 0.02));
  const heights = sizes.map(s => Math.round(s.height * width / s.width));
  const bands: [number, number][] = [];
  let top = 0;
  for (const h of heights) { bands.push([top, top + h]); top += h + gap; }
  return { width, height: top - gap, bands };
}

const entities = (text: string) => text.replaceAll('&nbsp;', ' ').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"')
  .replaceAll('&#39;', "'").replaceAll('&amp;', '&');
/** Markup as text (FigureCaptionText.plain): `data-latex` equations as `\( … \)`, tags dropped, entities read, white space
 * collapsed. */
export function plainText(markup: string): string {
  const text = markup.replace(/<span[^>]*\sdata-latex="([^"]*)"[^>]*>[\s\S]*?<\/math><\/span>/g, (_, latex: string) => `\\(${entities(latex)}\\)`)
    .replace(/<[^>]*>/g, '');
  return entities(text).split(/\s+/).filter(Boolean).join(' ');
}

/** A sub-caption's letter and words: "(a) Routing criticality", "a) Routing criticality"; null for any other paragraph. */
export function subcaption(text: string): { letter: string; words: string } | null {
  const m = /^\(([a-zA-Z])\)\s*([\s\S]*)$/.exec(text) ?? /^([a-z])\)\s+([\s\S]*)$/.exec(text);
  return m ? { letter: m[1].toLowerCase(), words: m[2].trim() } : null;
}

const round6 = (v: number) => Math.round(v * 1e6) / 1e6;

/** The structure of a figure block's markup (the bundle's `<figure data-reader-figure>`): its panel images in order (an
 * `<img>` outside a paragraph; legend symbols inside words are not panels), each run of images followed by sub-captions
 * ("(a) …" paragraphs: one for the run, or one per image), else the caption's letters in order when it names exactly as
 * many panels as there are images. `assetPaths` are the figure's (as the index lists them, the composed image's order);
 * `sizes` the images' pixel sizes (manifest). Null when the figure has fewer than two sub-figures in the composed image. */
export function figureStructure(markup: string, assetPaths: string[], sizes: ({ width: number; height: number } | null | undefined)[], caption: string): FigureStructure | null {
  const composed = Math.min(STRUCTURE.maxImages, assetPaths.length);
  if (composed < 2) return null;
  const known = sizes.slice(0, composed);
  if (known.length < composed || known.some(s => !s || !(s.width > 0) || !(s.height > 0))) return null;
  const layout = stackLayout(known as { width: number; height: number }[]);
  // The figure's own content, its caption left out.
  const body = markup.replace(/<figcaption\b[\s\S]*?<\/figcaption>/g, '');
  type Token = { image: number } | { letter: string; words: string };
  const tokens: Token[] = [], seen = new Set<number>();
  for (const m of body.matchAll(/<img\b[^>]*>|<p\b[^>]*>([\s\S]*?)<\/p>/g)) {
    if (m[0].startsWith('<img')) {
      if (/\sclass="[^"]*reader-inline-image/.test(m[0])) continue;
      const src = /\ssrc="([^"]*)"/.exec(m[0])?.[1] ?? '', index = assetPaths.indexOf(src);
      if (index >= 0 && !seen.has(index)) { seen.add(index); tokens.push({ image: index }); }
    } else {
      const sub = subcaption(plainText(m[1] ?? ''));
      if (sub) tokens.push(sub);
    }
  }
  // Runs of images, each with the sub-captions that follow it.
  const groups: { images: number[]; subs: { letter: string; words: string }[] }[] = [];
  let current: (typeof groups)[number] = { images: [], subs: [] };
  for (const t of tokens) {
    if ('image' in t) {
      if (current.subs.length) { groups.push(current); current = { images: [], subs: [] }; }
      current.images.push(t.image);
    } else current.subs.push(t);
  }
  groups.push(current);
  let parts: { letter: string | null; caption: string; images: number[] }[] = [];
  for (const g of groups) {
    if (!g.images.length) continue;
    if (g.subs.length === 1) parts.push({ letter: g.subs[0].letter, caption: g.subs[0].words, images: g.images });
    else if (g.subs.length === g.images.length) g.images.forEach((image, i) => parts.push({ letter: g.subs[i].letter, caption: g.subs[i].words, images: [image] }));
    else g.images.forEach(image => parts.push({ letter: null, caption: '', images: [image] }));
  }
  // A letter names one part (the first).
  const used = new Set<string>();
  parts = parts.map(p => { if (p.letter && used.has(p.letter)) return { ...p, letter: null, caption: '' }; if (p.letter) used.add(p.letter); return p; });
  // No sub-captions: the caption's letters, in order, when it names exactly as many panels.
  const letters = captionLetters(caption);
  if (!parts.some(p => p.letter) && letters.length >= 2 && letters.length === parts.length) parts = parts.map((p, i) => ({ ...p, letter: letters[i] }));
  const images = parts.reduce((n, p) => n + p.images.length, 0);
  const inside = parts.filter(p => p.images.every(i => i < composed));
  if (inside.length < 2) return null;
  const H = layout.height;
  return {
    parts: inside.map((p, k) => {
      const top = Math.min(...p.images.map(i => layout.bands[i][0])), bottom = Math.max(...p.images.map(i => layout.bands[i][1]));
      return { letter: p.letter, caption: p.caption, label: p.letter ? `(${p.letter})` : `Image ${k + 1}`, images: p.images, rect: [0, round6(top / H), 1, round6(bottom / H)] as Rect };
    }),
    images, composed, width: layout.width, height: layout.height,
  };
}

const fraction = (v: number) => { const n = Math.round(v * 100); return n >= 100 ? '1.00' : `0.${String(n).padStart(2, '0')}`; };
const shorten = (text: string, limit: number) => [...text].length <= limit ? text : [...text].slice(0, limit - 1).join('').trimEnd() + '…';

/** The structure as the model reads it, after the caption: each sub-figure's label, sub-caption and band. */
export function structureNote(s: FigureStructure): string {
  const lines = [`The image stacks this figure's ${s.parts.length} sub-figures top to bottom, each across its full width (y: fractions of the image's height):`];
  for (const p of s.parts) {
    const words = p.caption ? ` ${shorten(p.caption, STRUCTURE.captionChars)}` : '';
    lines.push(`- ${p.label}${words}: y ${fraction(p.rect[1])}–${fraction(p.rect[3])}`);
  }
  if (s.images > s.composed) lines.push(`Only the first ${s.composed} of its ${s.images} images are in the image.`);
  lines.push('Give each its own panel card, labelled as listed, in this order.');
  return lines.join('\n');
}

/** The walkthrough's selection: the caption, then the structure when the figure has one and both fit the selection's limit. */
export function structureQuote(caption: string, s: FigureStructure | null): string {
  if (!s) return caption;
  const quote = `${caption}\n\n${structureNote(s)}`;
  return [...quote].length <= STRUCTURE.quoteScalars ? quote : caption;
}

const area = (b: Rect) => Math.max(0, b[2] - b[0]) * Math.max(0, b[3] - b[1]);
const iou = (a: Rect, b: Rect) => {
  const i = area([Math.max(a[0], b[0]), Math.max(a[1], b[1]), Math.min(a[2], b[2]), Math.min(a[3], b[3])]);
  return i / Math.max(1e-9, area(a) + area(b) - i);
};
const normal = (text: string) => text.toLowerCase().split(/\s+/).filter(Boolean).join(' ');

/** A walkthrough section as matching needs it: its label, title, kind and box ([x0, y0, x1, y1] fractions), if any. */
export interface MatchSection { label: string; title: string; kind?: string; box?: Rect | null }

/** Which sub-figure each section shows (an index into `s.parts`), or null. Panel sections only; a sub-figure is matched
 * once. First by letter (the label's, else the title's when there is no label) or by the label the note gave ("Image 2");
 * then by a box whose intersection over union with one band is at least `boxMatch` (a section lettered otherwise is
 * not moved); then, when there are exactly as many panel sections as sub-figures, the unboxed rest in order (a letter
 * must not disagree). A section whose label names two panels ("(a) and (b)") is matched by none of these and stops the
 * order step: it shows a group, not one sub-figure. */
export function matchSections(sections: MatchSection[], s: FigureStructure | null): (number | null)[] {
  const out: (number | null)[] = sections.map(() => null);
  if (!s) return out;
  const taken = new Set<number>(), panels = sections.flatMap((x, i) => !x.kind || x.kind === 'panel' ? [i] : []);
  // A label naming two panels ("(a) and (b)") names no one sub-figure.
  const letterOf = (x: MatchSection) => { const text = x.label || x.title; return captionLetters(text).length > 1 ? null : labelLetter(text); };
  const agrees = (x: MatchSection, k: number) => { const l = letterOf(x), p = s.parts[k].letter; return !l || !p || l === p; };
  for (const i of panels) {
    const x = sections[i], l = letterOf(x);
    const k = s.parts.findIndex((p, k) => !taken.has(k) && ((!!l && p.letter === l) || (!!x.label && normal(x.label) === normal(p.label))));
    if (k >= 0) { out[i] = k; taken.add(k); }
  }
  for (const i of panels) {
    const box = sections[i].box;
    if (out[i] !== null || !box) continue;
    let best = -1, score = 0;
    s.parts.forEach((p, k) => { const v = iou(box, p.rect); if (!taken.has(k) && v > score) { best = k; score = v; } });
    if (best >= 0 && score >= STRUCTURE.boxMatch && agrees(sections[i], best)) { out[i] = best; taken.add(best); }
  }
  // In order only when every panel section can be one sub-figure (none names two panels).
  if (panels.length === s.parts.length && panels.every(i => captionLetters(sections[i].label || sections[i].title).length <= 1)) {
    panels.forEach((i, k) => {
      if (out[i] === null && !sections[i].box && !taken.has(k) && agrees(sections[i], k)) { out[i] = k; taken.add(k); }
    });
  }
  return out;
}

/** A figure block's markup in the bundle's page: its `<figure … data-reader-figure="id">` element (figures don't nest). */
export function figureMarkup(html: string, figureID: string): string | null {
  if (!/^[A-Za-z0-9._:-]{1,128}$/.test(figureID)) return null;
  const open = html.indexOf(`data-reader-figure="${figureID}"`);
  if (open < 0) return null;
  const start = html.lastIndexOf('<figure', open), end = html.indexOf('</figure>', open);
  return start >= 0 && end > open && !html.slice(start, open).includes('>') ? html.slice(start, end + '</figure>'.length) : null;
}

const pages = new WeakMap<VerifiedBundle, string>();
/** A figure's structure from the open paper's bundle (its markup, asset paths and the images' sizes in the manifest). */
export function bundleFigureStructure(bundle: VerifiedBundle, figure: VerifiedBundle['index']['figures'][number]): FigureStructure | null {
  if (figure.asset_paths.length < 2) return null;
  let page = pages.get(bundle);
  if (page === undefined) {
    const bytes = bundle.contents.get(bundle.manifest.entrypoint);
    page = bytes ? new TextDecoder().decode(bytes) : '';
    pages.set(bundle, page);
  }
  const markup = figureMarkup(page, figure.id);
  if (!markup) return null;
  const sizes = figure.asset_paths.map(path => { const m = bundle.manifest.members.find(x => x.path === path); return m?.width && m.height ? { width: m.width, height: m.height } : null; });
  return figureStructure(markup, figure.asset_paths, sizes, figure.caption);
}

/** Whether a structure describes this composed image (its aspect within 2 %): a composite that lost an image, or an
 * image prepared otherwise, keeps no structure. */
export const structureFits = (s: FigureStructure | null | undefined, image: { width: number; height: number }): s is FigureStructure =>
  !!s && image.width > 0 && image.height > 0 && Math.abs((s.width / s.height) / (image.width / image.height) - 1) <= 0.02;
