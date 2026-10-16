// The arXiv converter's shared state (docs/proposals/READER_ARCHITECTURE_RETHINK.md, step 2): one conversion's blocks,
// equations, figures, id allocation and ledger counters, and the small helpers every component uses. The components
// (front matter, authors, flow, inline text, math, tables, figures, finish) take this context as their first argument.
import { classes, el, elements, normalizeSpace, type DomNode, type OutNode } from '../html.ts';
import { LIMITS } from '../profile.ts';
import { check } from '../util.ts';
import type { ReaderIndex } from '../render.ts';

export type Child = OutNode | string;
export type HTMLImage = { path: string; width: number; height: number };
/** What the host admitted for an image URL: the published image, or `null` when this device couldn't prepare it (an SVG
 * its admission refuses, a raster too large to read, a decode that fails: device-compiler.ts). Its figure says so. */
export type ResolveImage = (url: string) => HTMLImage | null;

export interface ArxivConvertOptions {
  /** The library's author names for this paper, used when the HTML's own names are graphics or missing. */
  authors?: readonly string[];
  /** The catalog's title, used when the HTML has no `h1`. */
  title?: string;
  /** Diagnostics: the `math` elements no block accounted for, before `arxiv_math_coverage` refuses (the sweep). */
  onUncoveredMath?: (uncovered: DomNode[]) => void;
}

export const has = (n: DomNode, cls: string) => classes(n).includes(cls);
export const children = (n: DomNode) => n.children ?? [];
/** Source elements that never become reader content. */
export const active = new Set(['script', 'style', 'link', 'meta', 'form', 'input', 'button', 'textarea', 'iframe', 'embed', 'audio', 'video']);
export function nearest(node: DomNode, name: string): DomNode | null {
  for (let p = node.parent; p; p = p.parent) if (p.name === name) return p;
  return null;
}
export function onTitlePage(node: DomNode): boolean {
  for (let p: DomNode | null = node; p; p = p.parent) if (p.type === 'tag' && has(p, 'ltx_titlepage')) return true;
  return false;
}
/** Letters and digits only, lower case: how names and titles are compared. */
export const fold = (t: string) => t.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
/** A LaTeXML conversion-error marker (`ltx_ERROR`), kept as an empty span naming its macro (source.ts). */
export const isMarker = (n: DomNode) => n.type === 'tag' && n.attribs?.['data-reader-macro'] !== undefined;
/** Math drawn inside a node that is left out (a dropped graphic, a note mark, the date line): accounted, not rendered. */
export const skipMathIn = (cx: ArxivContext, n: DomNode) => { for (const m of elements(n, c => c.name === 'math')) cx.skippedMath.add(m); };

/** A paragraph whose only content is one graphic (LaTeXML's unwrapped \\includegraphics): a figure, not text. */
export function loneImage(n: DomNode): boolean {
  let images = 0, other = false;
  const visit = (c: DomNode) => {
    if (c.type === 'text') { if (c.data.trim()) other = true; return; }
    if (c.type !== 'tag') return;
    if (['img', 'object', 'svg'].includes(c.name)) { images += 1; return; }
    if (!['span', 'a', 'div', 'p'].includes(c.name)) { other = true; return; }
    children(c).forEach(visit);
  };
  children(n).forEach(visit);
  return images === 1 && !other;
}

export interface Block { id: string; kind: string; node: OutNode }

export interface ArxivContext {
  readonly root: DomNode;
  readonly sourceURL: string;
  readonly resolveImage: ResolveImage;
  readonly options: ArxivConvertOptions;
  /** The library's author names, cleaned (at most 64). */
  readonly metadataAuthors: string[];
  /** The catalog title, cleaned ('' when none). */
  readonly metadataTitle: string;
  /** Hashes the renderer revision and the source: block and equation ids are stable for one compiler and one paper. */
  readonly digest: string;
  readonly blocks: Block[];
  /** The page's top-level nodes, in reading order. */
  readonly top: OutNode[];
  readonly equations: ReaderIndex['equations'];
  readonly figures: ReaderIndex['figures'];
  readonly usedMath: Set<DomNode>;
  /** Math carried by a picture (drawn inside it or left out with it) rather than rendered as an equation. */
  readonly skippedMath: Set<DomNode>;
  /** Source ids to the reader block or equation that now holds them (in-page links resolve through these). */
  readonly aliases: Map<string, string>;
  readonly links: { node: OutNode; target: string }[];
  readonly imageURLs: Set<string>;
  readonly figureImages: Map<string, OutNode[]>;
  /** Per figure block: the images this device couldn't prepare (`ResolveImage` gave null). */
  readonly unshownImages: Map<string, number>;
  /** Blocks the converter made up from metadata (a catalog title or author line), not the paper's own. */
  readonly synthetic: Set<OutNode>;
  issued: number;
  // The closing note's ledger.
  dropped: number;
  omittedGraphics: number;
  unresolvedCitations: number;
  // A title page read by macro (front-matter.ts `templatePreamble`).
  titleSeen: boolean;
  pendingAbstract: { owner: DomNode; nodes: DomNode[] } | null;
  readonly templateNotes: { mark: string; text: string }[];
  readonly templateAffiliations: { mark: string; text: string }[];
}

export function createContext(root: DomNode, sourceURL: string, resolveImage: ResolveImage, options: ArxivConvertOptions,
  digest: string, dropped: number): ArxivContext {
  const metadataAuthors = (Array.isArray(options.authors) ? options.authors : []).filter(a => typeof a === 'string')
    .map(a => normalizeSpace(a)).filter(Boolean).slice(0, 64).map(a => a.slice(0, 256));
  const metadataTitle = typeof options.title === 'string' ? normalizeSpace(options.title).slice(0, 2000) : '';
  return { root, sourceURL, resolveImage, options, metadataAuthors, metadataTitle, digest, blocks: [], top: [], equations: [], figures: [],
    usedMath: new Set(), skippedMath: new Set(), aliases: new Map(), links: [], imageURLs: new Set(), figureImages: new Map(), unshownImages: new Map(), synthetic: new Set(),
    issued: 0, dropped, omittedGraphics: 0, unresolvedCitations: 0, titleSeen: false, pendingAbstract: null, templateNotes: [], templateAffiliations: [] };
}

export const bind = (cx: ArxivContext, n: DomNode, id: string) => { if (n.attribs?.id) cx.aliases.set(n.attribs.id, id); };
// Ids are issued, never reused: a block removed later (an empty paragraph, a repeated title) must not free its number.
export const nextID = (cx: ArxivContext) => { check(cx.blocks.length < LIMITS.blocks, 'block_limit'); cx.issued += 1; return `b-${cx.digest}-${cx.issued}`; };

// Adjacent strings as one, and the parentheses a dropped citation left empty ("PPO ()", "LLMs (, )") removed.
function tidyPunctuation(parts: Child[]): Child[] {
  const out: Child[] = [];
  for (const part of parts) {
    if (typeof part === 'string' && typeof out[out.length - 1] === 'string') out[out.length - 1] = (out[out.length - 1] as string) + part;
    else out.push(part);
  }
  return out.map(part => typeof part === 'string' ? part.replace(/\s*[([]\s*(?:[,;]\s*)*[)\]]/g, '').replace(/\s+([.,;:])/g, '$1') : part);
}

/** A reader block: its id issued and bound to the source node first, then its content made (which may bind more). */
export function block(cx: ArxivContext, n: DomNode, name: string, kind: string, make: (id: string) => Child[], attrs: Record<string, string> = {}): OutNode {
  const id = nextID(cx);
  const out = el(name, { ...attrs, id, 'data-reader-block': id, 'data-reader-kind': kind });
  cx.blocks.push({ id, kind, node: out }); bind(cx, n, id);
  const made = make(id);
  out.children = ['paragraph', 'heading', 'list'].includes(kind) && cx.unresolvedCitations > 0 ? tidyPunctuation(made) : made;
  return out;
}

/** The index lists blocks, equations and figures in page order; after a move, the order is read back from the page. */
export function reorder(cx: ArxivContext): void {
  const order = new Map<string, number>();
  const walk = (node: Child) => {
    if (typeof node !== 'object') return;
    const id = node.attribs['data-reader-block'] ?? node.attribs['data-reader-equation']; if (id) order.set(id, order.size);
    node.children.forEach(walk);
  };
  cx.top.forEach(walk);
  const at = (id: string) => order.get(id) ?? Number.MAX_SAFE_INTEGER;
  cx.blocks.sort((a, b) => at(a.id) - at(b.id)); cx.equations.sort((a, b) => at(a.id) - at(b.id)); cx.figures.sort((a, b) => at(a.id) - at(b.id));
}

/** A block leaves the page and the index, with its equations and figures (2610.20570: three equations in a dropped macro
 * paragraph stayed listed, refused `index_identity`). */
export function remove(cx: ArxivContext, entry: { id: string; node: OutNode }): void {
  const at = cx.blocks.indexOf(entry as Block); if (at >= 0) cx.blocks.splice(at, 1);
  const index = cx.top.indexOf(entry.node); if (index >= 0) cx.top.splice(index, 1);
  for (let i = cx.equations.length - 1; i >= 0; i -= 1) if (cx.equations[i].block_id === entry.id) cx.equations.splice(i, 1);
  for (let i = cx.figures.length - 1; i >= 0; i -= 1) if (cx.figures[i].block_id === entry.id) cx.figures.splice(i, 1);
}

