// Official arXiv HTML -> the existing inert reader vocabulary. No network, OCR,
// source scripts/styles, or PDF handling. Acquisition supplies every image.
import { classes, el, elements, HTML_SUFFIX, htmlPrefix, isMathToken, MATH_ELEMENTS, mathAttributeIsSafe,
  normalizeSpace, outText, parseHTML, render, serialize, textContent, walk, type DomNode, type OutNode } from './html.ts';
import { INDEX_FORMAT, LIMITS, ARXIV_SOURCE_BYTES } from './profile.ts';
import { boundedText, check, excerpt, sha256Hex, utf8 } from './util.ts';
import type { ReaderIndex } from './render.ts';

export const ARXIV_RENDERER_ID = 'gradstep-arxiv-html-mathml-v2';
export const ARXIV_SOURCE_KIND = 'arxiv-html';
export const ARXIV_PROVENANCE_FORMAT = 'arxiv-html-reader-provenance-v2';
/** Bumped whenever the compiled reader changes for the same source (2026-10-15: author blocks, template title pages),
 * so a device re-prepares papers it compiled with an older app (ReaderModel.openHTMLReader). */
export const ARXIV_RENDERER_REVISION = 7;
export const ARXIV_ID = /^(?:\d{4}\.\d{4,5}|[a-z][a-z.-]+(?:\.[A-Z]{2})?\/\d{7})$/;
export type HTMLImage = { path: string; width: number; height: number };
type Child = OutNode | string;
const has = (n: DomNode, cls: string) => classes(n).includes(cls);
const children = (n: DomNode) => n.children ?? [];
const active = new Set(['script', 'style', 'link', 'meta', 'form', 'input', 'button', 'textarea', 'iframe', 'embed', 'audio', 'video']);

export function arxivHTMLURL(sourceID: string, revision: number): string {
  check(ARXIV_ID.test(sourceID) && Number.isSafeInteger(revision) && revision >= 1 && revision <= 2147483647, 'arxiv_identity');
  return `https://arxiv.org/html/${sourceID}v${revision}`;
}

export function arxivAssetURL(reference: string, sourceURL: string): string {
  let url: URL;
  try { url = new URL(reference, sourceURL); } catch { throw new Error('arxiv_asset_url'); }
  const source = new URL(sourceURL);
  const root = source.pathname + '/';
  check(url.origin === 'https://arxiv.org' && source.origin === url.origin && !url.username && !url.password &&
    !url.port && !url.search && !url.hash && url.pathname.startsWith(root) && !/%/.test(url.pathname) &&
    /\.(?:png|jpe?g|svg)$/i.test(url.pathname) && url.href.length <= 2048, 'arxiv_asset_url');
  return url.href;
}

/** LaTeXML marks what it could not convert (an undefined macro such as `\\pdfauthor`) with `ltx_ERROR`; these are
 * dropped and counted, and the paper still reads (2026-10-14: a paper with 288 such preamble macros was refused
 * outright). Beyond this many the conversion is not trusted at all. */
export const CONVERSION_ERROR_LIMIT = 1000;
function article(source: string): { root: DomNode; dropped: number } {
  check(utf8(source).length <= ARXIV_SOURCE_BYTES && source.length > 0, 'source_limit');
  const root = parseHTML(source);
  const papers = elements(root, n => n.name === 'article' && has(n, 'ltx_document'));
  check(papers.length === 1, 'arxiv_article');
  const ids = new Set<string>(), errors: DomNode[] = [];
  walk(papers[0], n => {
    if (n.attribs?.id) { check(!ids.has(n.attribs.id), 'arxiv_duplicate_id'); ids.add(n.attribs.id); }
    if (has(n, 'ltx_ERROR') || has(n, 'ltx_error')) errors.push(n);
  });
  check(errors.length <= CONVERSION_ERROR_LIMIT, 'arxiv_conversion_error');
  // Each marker stays as an empty span that names its macro (`data-reader-macro`); the reader never prints it, and a
  // title page a template left in pieces can be read by macro (templatePreamble below).
  for (const n of errors) { n.attribs = { ...(n.attribs ?? {}), 'data-reader-macro': normalizeSpace(textContent(n)).slice(0, 64) }; n.children = []; }
  return { root: papers[0], dropped: errors.length };
}

/** Only the paper's content assets, never logos, styles or PDF object fallbacks. */
export function arxivHTMLAssets(source: string, sourceURL: string, options: ArxivConvertOptions = {}): string[] {
  // Exactly the images the compiled reader references (a dry compile with placeholder admissions), so acquisition,
  // asset coverage and provenance agree; a graphic the reader leaves out is never fetched. Structural refusals surface
  // here, before any image is downloaded.
  const placeholder = { path: `assets/${'0'.repeat(64)}.png`, width: 1, height: 1 };
  const assets = convertArxivHTML(source, sourceURL, () => placeholder, options).imageURLs.filter(url => !url.startsWith('#'));
  check(assets.length <= LIMITS.archiveImages, 'image_limit');
  return assets;
}

/** Inline vectors are source bytes, never remote asset URLs. The canonical
 * serialization is hashed in provenance before the device SVG admission. */
export function arxivInlineImages(source: string, sourceURL: string, options: ArxivConvertOptions = {}): Map<string, string> {
  // Exactly the pictures the compiled reader references (a dry compile), as for raster assets.
  const placeholder = { path: `assets/${'0'.repeat(64)}.png`, width: 1, height: 1 };
  const wanted = new Set(convertArxivHTML(source, sourceURL, () => placeholder, options).imageURLs.filter(url => url.startsWith('#')).map(url => url.slice(1)));
  const result = new Map<string, string>();
  const root = article(source).root;
  for (const n of elements(root, n => n.name === 'svg')) {
    const id = n.attribs.id;
    if (typeof id !== 'string' || !wanted.has(id)) continue;
    check(/^[A-Za-z_][A-Za-z0-9_.:-]{0,199}$/.test(id) && !nearest(n, 'svg') && !nearest(n, 'math'), 'arxiv_inline_svg');
    check(!n.attribs.xmlns || n.attribs.xmlns === 'http://www.w3.org/2000/svg', 'arxiv_inline_svg');
    const xml = serialize(svgTextLabels(withSharedDefinitions(root, { ...n, attribs: { ...n.attribs, xmlns: 'http://www.w3.org/2000/svg' } })));
    result.set('#' + id, xml);
  }
  check(result.size === wanted.size, 'arxiv_inline_svg');
  check(result.size <= LIMITS.archiveImages, 'image_limit');
  return result;
}

/** A TikZ picture may use a pattern or symbol LaTeXML defined once elsewhere in the page (Apertus 1.5's Figure 9, refused
 * as `svg_fragment` on build 42): those definitions travel with the picture in their own `defs`, and an element whose
 * reference nothing on the page defines is left out rather than refusing the paper. */
function withSharedDefinitions(root: DomNode, picture: DomNode): DomNode {
  const ownRefs = (x: DomNode): string[] => Object.entries(x.attribs ?? {}).flatMap(([key, value]) => {
    if ((key === 'href' || key === 'xlink:href') && value.startsWith('#')) return [value.slice(1)];
    return [...String(value).matchAll(/url\(#([^)]+)\)/g)].map(m => m[1]);
  });
  const refs = (node: DomNode): string[] => elements(node, () => true).flatMap(ownRefs);
  const have = new Set(elements(picture, x => typeof x.attribs?.id === 'string').map(x => x.attribs.id));
  const copies: DomNode[] = [], seen = new Set<string>();
  let pending = refs(picture).filter(id => !have.has(id));
  for (let depth = 0; pending.length && depth < 4; depth += 1) {
    const next: string[] = [];
    for (const id of pending) {
      if (seen.has(id) || have.has(id)) continue; seen.add(id);
      const source = elements(root, x => x.attribs?.id === id && x !== picture && !nearest(x, 'math'))[0];
      if (!source) continue;
      copies.push(source); have.add(id);
      for (const inner of elements(source, x => typeof x.attribs?.id === 'string')) have.add(inner.attribs.id);
      next.push(...refs(source).filter(r => !have.has(r)));
    }
    pending = next;
  }
  const defs: DomNode = { type: 'tag', name: 'defs', attribs: {}, children: copies, parent: picture } as DomNode;
  const missing = new Set(refs(picture).concat(copies.flatMap(refs)).filter(id => !have.has(id)));
  const prune = (node: DomNode): DomNode => ({ ...node, children: (node.children ?? [])
    .filter(child => !(child.type === 'tag' && ownRefs(child).some(id => missing.has(id))))
    .map(child => child.type === 'tag' ? prune(child) : child) });
  const withDefs: DomNode = copies.length ? { ...picture, children: [...picture.children, defs] } : picture;
  return missing.size ? prune(withDefs) : withDefs;
}

/** LaTeXML draws TikZ node labels as `foreignObject` HTML, which the device SVG admission refuses. Each label becomes
 * SVG text centred in the label's box (its flip undone), so the diagram keeps its words; placement is best effort. */
function svgTextLabels(n: DomNode): DomNode {
  if (n.type !== 'tag') return n;
  if (n.name === 'foreignObject') {
    const width = Number(n.attribs.width) || 0, height = Number(n.attribs.height) || 0;
    const size = /font-size:\s*([\d.]+)(pt|px)/.exec(n.attribs.style ?? '');
    const fontSize = size ? (size[2] === 'pt' ? Number(size[1]) * 4 / 3 : Number(size[1])) : 13;
    const label: DomNode = { type: 'text', data: normalizeSpace(textContent(n)), name: '', attribs: {}, children: [], parent: null };
    const text: DomNode = { type: 'tag', name: 'text', attribs: { x: String(width / 2), y: String(height / 2), 'text-anchor': 'middle',
      'dominant-baseline': 'central', 'font-size': String(Math.round(fontSize * 100) / 100), transform: `matrix(1 0 0 -1 0 ${height})` },
      children: [label], parent: null, data: '' };
    return { type: 'tag', name: 'g', attribs: n.attribs.transform ? { transform: n.attribs.transform } : {}, children: [text], parent: null, data: '' };
  }
  return { ...n, children: (n.children ?? []).map(svgTextLabels) };
}

export interface ArxivConvertOptions {
  /** The library's author names for this paper, used when the HTML's own names are graphics or missing. */
  authors?: readonly string[];
  /** The catalog's title, used when the HTML has no `h1`. */
  title?: string;
}
export function convertArxivHTML(source: string, sourceURL: string, resolveImage: (url: string) => HTMLImage, options: ArxivConvertOptions = {}): {
  index: ReaderIndex; html: string; imageURLs: string[];
} {
  const { root, dropped: droppedMarkers } = article(source);
  let dropped = droppedMarkers;
  const metadataAuthors = (Array.isArray(options.authors) ? options.authors : []).filter(a => typeof a === 'string')
    .map(a => normalizeSpace(a)).filter(Boolean).slice(0, 64).map(a => a.slice(0, 256));
  check(/^https:\/\/arxiv\.org\/html\/.+v[1-9][0-9]*$/.test(sourceURL), 'arxiv_identity');
  const digest = sha256Hex(utf8(`${ARXIV_RENDERER_REVISION}\n${source}`)).slice(0, 12);
  const blocks: { id: string; kind: string; node: OutNode }[] = [], top: OutNode[] = [];
  let omittedGraphics = 0;
  const isMarker = (n: DomNode) => n.type === 'tag' && n.attribs?.['data-reader-macro'] !== undefined;
  // A title page LaTeXML could not convert (a custom report template whose macros it does not know, 2610.18356):
  // the abstract, the affiliations and the contribution notes it carried are kept for the header; the rest (a logo
  // path, running titles, PDF metadata) is left out with the macros. Read before the document title only.
  let titleSeen = false;
  let pendingAbstract: { owner: DomNode; nodes: DomNode[] } | null = null;
  const templateNotes: { mark: string; text: string }[] = [], templateAffiliations: { mark: string; text: string }[] = [];
  /** Math carried by a picture (drawn inside it or left out with it) rather than rendered as an equation. */
  const skippedMath = new Set<DomNode>();
  /** A paragraph whose only content is one graphic (LaTeXML's unwrapped \\includegraphics): a figure, not text. */
  const loneImage = (n: DomNode): boolean => {
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
  };
  const equations: ReaderIndex['equations'] = [], figures: ReaderIndex['figures'] = [];
  const usedMath = new Set<DomNode>();
  const aliases = new Map<string, string>(), links: { node: OutNode; target: string }[] = [];
  const imageURLs = new Set<string>();
  const figureImages = new Map<string, OutNode[]>();
  const bind = (n: DomNode, id: string) => { if (n.attribs?.id) aliases.set(n.attribs.id, id); };
  // Ids are issued, never reused: a block removed later (an empty paragraph, a repeated title) must not free its number.
  let issued = 0;
  const nextID = () => { check(blocks.length < LIMITS.blocks, 'block_limit'); issued += 1; return `b-${digest}-${issued}`; };
  // Adjacent strings as one, and the parentheses a dropped citation left empty ("PPO ()", "LLMs (, )") removed.
  const tidyPunctuation = (parts: Child[]): Child[] => {
    const out: Child[] = [];
    for (const part of parts) {
      if (typeof part === 'string' && typeof out[out.length - 1] === 'string') out[out.length - 1] = (out[out.length - 1] as string) + part;
      else out.push(part);
    }
    return out.map(part => typeof part === 'string' ? part.replace(/\s*[([]\s*(?:[,;]\s*)*[)\]]/g, '').replace(/\s+([.,;:])/g, '$1') : part);
  };
  function block(n: DomNode, name: string, kind: string, make: (id: string) => Child[], attrs: Record<string, string> = {}): OutNode {
    const id = nextID();
    const out = el(name, { ...attrs, id, 'data-reader-block': id, 'data-reader-kind': kind });
    blocks.push({ id, kind, node: out }); bind(n, id);
    const made = make(id);
    out.children = ['paragraph', 'heading', 'list'].includes(kind) && unresolvedCitations > 0 ? tidyPunctuation(made) : made;
    return out;
  }
  // The authors (LaTeXML `div.ltx_authors`), read as a typeset header rather than as LaTeXML prints it: each name
  // once with its affiliation marks, then the affiliations, any address (a project page) and the notes the marks
  // and daggers point to, each on its own line. Left out: duplicated marks and "footnotemark:" labels, "Affiliation:"
  // contact labels, e-mail addresses. Authors whose affiliations come without marks (one "Affiliation:" each) get
  // numbered marks in order. A name that was a graphic (a team logo) is replaced by the library's author metadata
  // when the caller passes it (owner reports, 2026-10-14: "gross author presentation", "what is this Team business").
  // Author text helpers, shared by LaTeXML's author block and a custom title page read into the header.
    const MARKS = /[\d,†‡*§¶‖]/g, LEADING_MARKS = /^[\d,†‡*§¶‖\s]+/;
    const EMAIL = /\{[^}]*\}@[\w.-]+|[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g;
    const plain = (parts: Child[]) => normalizeSpace(parts.map(part => typeof part === 'string' ? part : outText(part)).join(''));
    const isSup = (part: Child): part is OutNode => typeof part === 'object' && part.name === 'sup';
    const isBr = (part: Child) => typeof part === 'object' && part.name === 'br';
    // Collapsed whitespace, no e-mail, no space around a mark, consecutive marks as one ("1,2"), tidy punctuation,
    // trimmed ends.
    const tidy = (parts: Child[]): Child[] => {
      const out: Child[] = [];
      for (const part of parts) {
        if (typeof part === 'string') {
          const last = out[out.length - 1];
          const text = (isSup(last) ? part.trimStart() : part).replace(EMAIL, '').replace(/\s+/g, ' ');
          if (!text) continue;
          if (typeof last === 'string') out[out.length - 1] = (last + text).replace(/\s+/g, ' '); else out.push(text);
        } else if (isSup(part)) {
          if (!outText(part).trim()) continue; // a mark that was an icon (an envelope, 2610.12978)
          const last = out[out.length - 1];
          if (typeof last === 'string') { const trimmed = last.trimEnd(); if (trimmed) out[out.length - 1] = trimmed; else out.pop(); }
          const previous = out[out.length - 1];
          if (isSup(previous)) {
            const marks = [...new Set([...outText(previous).split(','), ...outText(part).split(',')].map(m => m.trim()).filter(Boolean))];
            previous.children = [marks.join(',')];
          } else out.push(part);
        } else if (part.name === 'br' || part.name === 'a') out.push(part);
        else {
          // An emphasis wrapper: tidied inside, and left out when nothing is left in it (a logo that was dropped).
          const inner = tidy(part.children);
          if (inner.length) out.push({ ...part, children: inner });
        }
      }
      for (let i = 0; i < out.length; i++) {
        const part = out[i];
        if (typeof part === 'string') out[i] = part.replace(/\s+([.,;:])/g, '$1').replace(/:\s*\./g, '.').replace(/\.{2,}/g, '.').replace(/\s+/g, ' ');
      }
      if (typeof out[0] === 'string') { out[0] = out[0].trimStart(); if (!out[0]) out.shift(); }
      const last = out[out.length - 1];
      if (typeof last === 'string') { out[out.length - 1] = last.trimEnd().replace(/^[\s,;:]+/, ''); if (!out[out.length - 1]) out.pop(); }
      return out;
    };
    // An affiliation line ("²Stanford University ³CZ Biohub"): each mark starts an entry; entries read "a · b".
    const entries = (parts: Child[]): Child[][] => {
      const list: Child[][] = [];
      for (const part of parts) {
        if (isSup(part) || !list.length) list.push([]);
        list[list.length - 1].push(part);
      }
      return list.map(tidy).filter(entry => plain(entry).replace(MARKS, '').trim());
    };
  /** A run of names and affiliations without LaTeXML's creator structure (a tabular's cells, a custom title page,
   * 2610.10238 and 2610.14075): "Name<sup>1</sup>" is an author, "<sup>1</sup>Place" an affiliation, and a unit without
   * marks lists names ("A, B and C"). */
  const trimEdges = (unit: Child[]): Child[] => {
    const out = [...unit];
    if (typeof out[0] === 'string') { out[0] = out[0].replace(/^[\s,;:·]+/, ''); if (!out[0]) out.shift(); }
    const last = out[out.length - 1];
    if (typeof last === 'string') { out[out.length - 1] = last.replace(/[\s,;:·]+$/, ''); if (!out[out.length - 1]) out.pop(); }
    return out;
  };
  const splitNames = (unit: Child[]): Child[][] => {
    if (unit.some(part => typeof part !== 'string')) return [unit];
    const text = plain(unit).replace(/^[A-Z][A-Za-z ]{1,30}:\s*/, '');
    return text.split(/\s*(?:,|;|\band\b|&)\s*/).map(name => name.trim()).filter(Boolean).map(name => [name]);
  };
  const parseRun = (parts: Child[]): { names: Child[][]; affiliations: Child[][] } => {
    const names: Child[][] = [], affiliations: Child[][] = [];
    let current: Child[] = [], mode: 'name' | 'affiliation' | null = null;
    const flush = () => {
      const unit = trimEdges(tidy(current)); current = [];
      if (plain(unit).replace(MARKS, '').trim()) (mode === 'affiliation' ? affiliations : names).push(unit);
      mode = null;
    };
    for (const part of parts) {
      if (isBr(part)) { flush(); continue; }
      if (isSup(part)) {
        if (mode === 'name') { current.push(part); flush(); }
        else { if (mode === 'affiliation') flush(); current.push(part); mode = 'affiliation'; }
      } else { if (mode === null) mode = 'name'; current.push(part); }
    }
    flush();
    return { names: names.flatMap(unit => unit.some(isSup) ? [unit] : splitNames(unit)), affiliations };
  };
  /** The header's author paragraph: the names with their marks, then the affiliations and the notes each on its own
   * line in a smaller face (ARXIV_CSS; owner, build 42: "still ugly", "needs space after author section"). */
  const renderAuthors = (names: Child[][], affiliations: Child[][], addresses: Child[][], notes: { mark: string; body: Child[] }[]): Child[] => {
    const out: Child[] = [];
    names.forEach((name, index) => { if (index) out.push(', '); out.push(...name); });
    const lines = (units: Child[][]): Child[] => units.flatMap((unit, index) => index ? [el('br'), ...unit] : unit);
    if (affiliations.length || addresses.length) out.push(' ', el('span', { class: 'reader-affiliations' }, lines([...affiliations, ...addresses])));
    if (notes.length) out.push(' ', el('span', { class: 'reader-notes' }, lines(notes.map(note => note.mark ? [el('sup', {}, [note.mark]), ' ', ...note.body] : note.body))));
    return out;
  };
  function authorsBlock(n: DomNode): OutNode {
    return block(n, 'p', 'paragraph', id => {
      for (const e of elements(n, () => true)) bind(e, id);
      const INLINE = ['em', 'i', 'strong', 'b', 'u', 's', 'sub', 'sup', 'code'];
      const MARK_SYMBOLS: Record<string, string> = { '†': '†', '‡': '‡', '*': '*', '∗': '*', '⋆': '*', '§': '§', '¶': '¶', '‖': '‖' };
      const mathText = (m: DomNode): string => m.type === 'text' ? m.data : m.type !== 'tag' || ['annotation', 'annotation-xml'].includes(m.name) ? '' : children(m).map(mathText).join('').trim();
      const notes: { mark: string; body: Child[] }[] = [], seenNotes = new Set<string>();
      const addresses: Child[][] = [];
      const drop = (c: DomNode): Child[] => { for (const m of elements(c, x => x.name === 'math')) skippedMath.add(m); return []; };
      const walk = (c: DomNode): Child[] => {
        if (c.type === 'text') return [c.data];
        if (c.type !== 'tag') return [];
        if (c.name === 'math') {
          // A mark set as math ($\dagger$ beside a name, 2610.12978) is its symbol; an equation span has no text.
          const symbol = MARK_SYMBOLS[mathText(c)]; if (symbol) { drop(c); return [symbol]; }
          return [equation(c, id)];
        }
        if (['svg', 'img', 'object'].includes(c.name)) { omittedGraphics += 1; return drop(c); }
        if (has(c, 'ltx_note')) {
          const first = elements(c, x => has(x, 'ltx_note_mark'))[0];
          const mark = first ? normalizeSpace(textContent(first)) : '';
          const content = elements(c, x => has(x, 'ltx_note_content'))[0];
          const body: Child[] = [];
          for (const x of content ? children(content) : []) {
            if (x.type === 'tag' && (has(x, 'ltx_note_mark') || has(x, 'ltx_note_type') || has(x, 'ltx_tag'))) drop(x); else body.push(...walk(x));
          }
          const text = plain(tidy(body));
          if (text && !seenNotes.has(mark + '\u0000' + text)) { seenNotes.add(mark + '\u0000' + text); notes.push({ mark, body: tidy(body) }); }
          return mark ? [el('sup', {}, [mark])] : [];
        }
        if (has(c, 'ltx_contact_name') || has(c, 'ltx_role_email')) return drop(c);
        if (c.name === 'a') {
          const href = c.attribs?.href ?? '';
          if (/^mailto:/i.test(href)) return drop(c);
          const rendered = inline(c, id);
          if (/^https?:/i.test(href)) { addresses.push(rendered); return []; }
          return rendered;
        }
        if (has(c, 'ltx_author_before') || has(c, 'ltx_author_after')) return [' '];
        if (c.name === 'br') return [el('br')];
        // A mark is its text (a template's italic "1,2" is no emphasis, 2610.10238); the block has one face, so
        // bold or italic wrappers around names are left out.
        if (c.name === 'sup') { const text = plain(children(c).flatMap(walk)); return text ? [el('sup', {}, [text])] : []; }
        // An author block set as a table (2610.10238): a row is a line, a cell is a unit.
        if (has(c, 'ltx_tr')) return [...children(c).flatMap(walk), el('br')];
        if (has(c, 'ltx_td') || has(c, 'ltx_th')) return [...children(c).flatMap(walk), ' '];
        const name = INLINE.includes(c.name) ? c.name : null;
        const result = children(c).flatMap(walk);
        return name ? [el(name, {}, result)] : result;
      };
      const affiliations = new Map<string, Child[]>();
      const addAffiliations = (parts: Child[]): string[] => {
        const keys: string[] = [];
        for (const entry of entries(parts)) {
          const key = plain(entry).replace(LEADING_MARKS, '').toLowerCase();
          if (!key) continue;
          if (!affiliations.has(key)) affiliations.set(key, entry);
          keys.push(key);
        }
        return keys;
      };
      const creators: { name: Child[]; keys: string[]; lost: boolean }[] = [];
      for (const creator of elements(n, c => has(c, 'ltx_creator'))) {
        const person = elements(creator, c => has(c, 'ltx_personname'))[0];
        const graphicsBefore = omittedGraphics;
        const parts = walk(person ?? creator);
        const lost = omittedGraphics > graphicsBefore;
        // Lines after the name (LaTeXML's `\\` in an author block) are that author's affiliations.
        const cut = parts.findIndex(isBr);
        const head = tidy(cut >= 0 ? parts.slice(0, cut) : parts);
        const startsWithMark = isSup(head[0]);
        const text = plain(head).replace(LEADING_MARKS, '');
        const keys: string[] = [];
        let name: Child[] | null = null;
        if (text && !startsWithMark) name = head; else if (text) keys.push(...addAffiliations(head));
        // Several authors in one creator (a tabular's cells, names run together with their marks): each is one.
        const more: Child[][] = [];
        if (name) {
          const run = parseRun(name);
          if (run.names.length >= 2) {
            for (const unit of run.affiliations) keys.push(...addAffiliations(unit));
            more.push(...run.names.slice(1)); name = run.names[0];
          }
        }
        if (cut >= 0) {
          // Lines after the first: more authors when they carry marks ("Heyuan Deng⁴ Fei Mi⁴,‡", 2610.18683),
          // otherwise that author's affiliations (LaTeXML's `\\` under a name).
          const rest = parseRun(parts.slice(cut + 1));
          for (const unit of rest.names) { if (unit.some(isSup) && name) more.push(unit); else keys.push(...addAffiliations(unit)); }
          for (const unit of rest.affiliations) keys.push(...addAffiliations(unit));
        }
        for (const extra of person ? children(creator).filter(c => c !== person) : []) {
          // A note beside the name (a dagger for equal contribution) marks the name; anything else is an affiliation.
          const marksOnly = extra.type === 'tag' && (has(extra, 'ltx_note')
            || (elements(extra, x => has(x, 'ltx_note')).length > 0 && !normalizeSpace(textContent(extra).replace(MARKS, '')).length));
          const rendered = walk(extra);
          if (marksOnly && name) name = tidy([...name, ...rendered]); else keys.push(...addAffiliations(rendered));
        }
        if (name || lost) creators.push({ name: name ?? [], keys: [...new Set(keys)], lost });
        for (const unit of more) creators.push({ name: unit, keys: [], lost: false });
      }
      // A title page read by macro (templatePreamble): its affiliations and contribution notes belong here.
      for (const entry of templateAffiliations.splice(0)) addAffiliations([el('sup', {}, [entry.mark]), entry.text]);
      for (const note of templateNotes.splice(0)) {
        if (!seenNotes.has(note.mark + '\u0000' + note.text)) { seenNotes.add(note.mark + '\u0000' + note.text); notes.push({ mark: note.mark, body: [note.text] }); }
      }
      // An affiliation that is only punctuation (a template's "[", 2610.18356) says nothing.
      for (const [key, entry] of [...affiliations]) if (!/[\p{L}\p{N}]/u.test(plain(entry).replace(LEADING_MARKS, ''))) affiliations.delete(key);
      for (const c of creators) c.keys = c.keys.filter(key => affiliations.has(key));
      const named = creators.filter(c => c.name.length);
      // A name that was a graphic, or no name at all: the library's author metadata names them.
      const useMetadata = metadataAuthors.length > 0 && (creators.some(c => c.lost) || !named.length);
      const affiliationMarked = named.some(c => c.name.some(part => isSup(part) && /\d/.test(outText(part))));
      if (!useMetadata && !affiliationMarked && affiliations.size >= 2 && named.some(c => c.keys.length)) {
        const numbers = new Map([...affiliations.keys()].map((key, index) => [key, String(index + 1)]));
        for (const c of named) {
          const marks = c.keys.map(key => numbers.get(key)).filter((m): m is string => !!m);
          if (marks.length) c.name = tidy([...c.name, el('sup', {}, [marks.join(',')])]);
        }
        for (const [key, entry] of affiliations) affiliations.set(key, tidy([el('sup', {}, [numbers.get(key)!]), ...entry]));
      }
      const out = renderAuthors(useMetadata ? [[metadataAuthors.join(', ')]] : named.map(c => c.name), [...affiliations.values()], addresses, notes);
      if (out.length) return out;
      // Nothing recognisable: the block's own words, with any math inside counted as left out.
      for (const m of elements(n, x => x.name === 'math')) if (!usedMath.has(m)) skippedMath.add(m);
      return [normalizeSpace(textContent(n))];
    }, { class: 'reader-authors' });
  }
  function mathNode(n: DomNode): Child[] {
    if (n.type === 'text') return n.data.trim() || isMathToken(n.parent?.name ?? '') ? [n.data] : [];
    if (n.name === 'annotation' || n.name === 'annotation-xml') return [];
    if (n.name === 'a' || n.name === 'span') return children(n).flatMap(mathNode);
    if (n.name === 'semantics') {
      const presentation = children(n).filter(c => c.type === 'tag' && !['annotation', 'annotation-xml'].includes(c.name));
      check(presentation.length === 1, 'arxiv_math_semantics');
      return mathNode(presentation[0]);
    }
    check(MATH_ELEMENTS.has(n.name) && n.name !== 'math', 'arxiv_math_element');
    const attrs: Record<string, string> = {};
    for (const [key, value] of Object.entries(n.attribs ?? {})) {
      if (['class', 'id', 'intent', 'alttext', 'xref', 'xmlns'].includes(key)) continue;
      if (key === 'style') {
        // LaTeXML mirrors a few presentation attributes as CSS. Never retain
        // source CSS; translate only this finite scalar vocabulary.
        for (const declaration of value.split(';').map(v => v.trim()).filter(Boolean)) {
          const match = /^(width|height|depth|font-size|--ltx-fg-color|--ltx-bg-color):\s*([A-Za-z0-9 .%#+-]+)$/.exec(declaration);
          check(match, 'arxiv_math_style');
          // The reader owns its colours: a source colour or background (a boxed ± in 2610.18683's tables, a teal
          // dagger) is left out, as the HTML's own colours are.
          if (match[1] === '--ltx-fg-color' || match[1] === '--ltx-bg-color') continue;
          const attr = match[1] === 'font-size' ? 'mathsize' : match[1];
          check(mathAttributeIsSafe(n.name, attr, match[2]), 'arxiv_math_style'); attrs[attr] = match[2];
        }
        continue;
      }
      if (key === 'mathcolor' || key === 'mathbackground') continue;
      check(mathAttributeIsSafe(n.name, key, value), 'arxiv_math_attribute'); attrs[key] = value;
    }
    return [el(n.name, attrs, children(n).flatMap(mathNode))];
  }
  function equation(n: DomNode, owner: string, forceDisplay = false): OutNode {
    check(!usedMath.has(n), 'arxiv_math_duplicate'); usedMath.add(n);
    const annotations = elements(n, c => c.name === 'annotation' && c.attribs.encoding === 'application/x-tex');
    const latex = boundedText(n.attribs.alttext ?? (annotations.length === 1 ? textContent(annotations[0]) : ''), LIMITS.textBytes, 'arxiv_math_source');
    check(latex.trim().length > 0 && equations.length < LIMITS.equations, 'arxiv_math_source');
    if (annotations.length) check(annotations.length === 1 && normalizeSpace(textContent(annotations[0])) === normalizeSpace(latex), 'arxiv_math_mismatch');
    const display = forceDisplay || n.attribs.display === 'block';
    const id = `e-${digest}-${equations.length + 1}`; bind(n, id);
    const form = /^\s*\\begin\{(?:equation\*?|align\*?|gather\*?|multline\*?)\}/.test(latex) ? 'environment' : 'body';
    check(form !== 'environment' || display, 'arxiv_math_source');
    equations.push({ id, block_id: owner, latex, display, source_form: form });
    const math = el('math', display ? { display: 'block' } : {}, children(n).flatMap(mathNode));
    check(math.children.length > 0, 'arxiv_math_empty');
    return el('span', { id, 'data-reader-equation': id, 'data-latex': latex,
      class: `reader-equation ${display ? 'reader-display' : 'reader-inline'}` }, [math]);
  }
  // A size or style command LaTeXML left in running text ("\\scriptsize①" in 2610.14075's Figure 1 caption, build 42:
  // "I see \\scriptsize") is no word of the paper.
  const LEAKED_MACRO = /\\(?:scriptsize|footnotesize|small|tiny|large|Large|LARGE|huge|Huge|normalsize|bfseries|itshape|rmfamily|sffamily|ttfamily|bf|it|rm|sf|tt|em|centering|raggedright|raggedleft|noindent|boldmath|unboldmath|relax)(?![A-Za-z])\s?/g;
  let unresolvedCitations = 0;
  function inline(n: DomNode, owner: string, inAnchor = false, forceDisplay = false): Child[] {
    if (n.type === 'text') return [n.data.replace(LEAKED_MACRO, '')];
    // A citation LaTeXML could not resolve prints as a bold "?" (2610.18683: "(?)", "(??)"): left out and counted;
    // the parentheses around it go too (`tidyPunctuation`).
    if (n.type === 'tag' && has(n, 'ltx_font_bold') && /^\?+$/.test(normalizeSpace(textContent(n)))) { unresolvedCitations += 1; bind(n, owner); return []; }
    if (n.type === 'comment') return [];
    check(n.type === 'tag' || active.has(n.name), 'arxiv_node');
    if (active.has(n.name)) return [];
    bind(n, owner);
    if (n.name === 'math') return [equation(n, owner, forceDisplay)];
    if (['svg', 'img', 'object'].includes(n.name) && figureImages.has(owner)) return [figureImage(n, owner, true)];
    // A graphic inside running text outside a figure (an affiliation logo, an inline TikZ mark): the reader has no
    // inline-image vocabulary there, so it is left out and counted in the closing note rather than refusing the paper.
    if (['svg', 'img', 'object'].includes(n.name)) {
      omittedGraphics += 1; for (const m of elements(n, c => c.name === 'math')) skippedMath.add(m); return [];
    }
    check(!['table', 'figure'].includes(n.name), 'arxiv_nested_content');
    // A footnote in running text (LaTeXML: the mark, then the content repeating the mark and a "footnotetext:" label,
    // 2610.19864): the mark once, then its words.
    if (has(n, 'ltx_note')) {
      const mark = elements(n, x => x !== n && has(x, 'ltx_note_mark'))[0];
      const content = elements(n, x => x !== n && has(x, 'ltx_note_content'))[0];
      for (const x of elements(n, x => x !== n && (has(x, 'ltx_note_mark') || has(x, 'ltx_note_type'))))
        for (const m of elements(x, y => y.name === 'math')) skippedMath.add(m);
      const body = (content ? children(content) : children(n).filter(x => !has(x, 'ltx_note_mark')))
        .filter(x => !(x.type === 'tag' && (has(x, 'ltx_note_mark') || has(x, 'ltx_note_type')))).flatMap(x => inline(x, owner, inAnchor, forceDisplay));
      const markText = mark ? normalizeSpace(textContent(mark)) : '';
      return markText ? [el('sup', {}, [markText]), ' ', ...body] : body;
    }
    const content = () => children(n).flatMap(c => inline(c, owner, inAnchor || n.name === 'a', forceDisplay));
    if (n.name === 'br') return [el('br')];
    if (n.name === 'a') {
      if (inAnchor) return content();
      const href = n.attribs.href ?? '';
      let target: URL | null = null;
      try { target = new URL(href, sourceURL); } catch { /* preserve inert text */ }
      const node = el('a', {}, content());
      if (target && target.origin === new URL(sourceURL).origin && target.pathname === new URL(sourceURL).pathname && target.hash) {
        let fragment: string; try { fragment = decodeURIComponent(target.hash.slice(1)); } catch { throw new Error('arxiv_fragment'); }
        links.push({ node, target: fragment }); return [node];
      }
      if (target && ['https:', 'http:'].includes(target.protocol) && !target.username && !target.password && !target.port) {
        target.protocol = 'https:'; node.attribs = { href: target.href, rel: 'noopener noreferrer' }; return [node];
      }
      return node.children;
    }
    const name = ['em', 'i', 'strong', 'b', 'u', 's', 'sub', 'sup', 'code'].includes(n.name) ? n.name
      : has(n, 'ltx_font_bold') ? 'strong' : has(n, 'ltx_font_italic') ? 'em' : null;
    const result = content();
    // Inline wrappers have no arbitrary attributes; the reader owns its CSS.
    return name ? [el(name, {}, result)] : ['p', 'div', 'li', 'tr'].includes(n.name) ? [...result, el('br')] : result;
  }
  function table(n: DomNode, owner: string): OutNode {
    bind(n, owner);
    const rows = elements(n, c => c.name === 'tr' && nearest(c, 'table') === n);
    return el('table', {}, [el('tbody', {}, rows.map(row => {
      bind(row, owner);
      return el('tr', {}, children(row).filter(c => ['td', 'th'].includes(c.name)).map(cell => {
        bind(cell, owner);
        const attrs: Record<string, string> = {};
        for (const key of ['rowspan', 'colspan']) if (cell.attribs[key]) {
          check(/^[1-9][0-9]{0,2}$/.test(cell.attribs[key]), 'arxiv_table_span'); attrs[key] = cell.attribs[key];
        }
        return el(cell.name, attrs, children(cell).flatMap(c => cellContents(c, owner)));
      }));
    }))]);
  }
  function cellContents(n: DomNode, owner: string): Child[] {
    if (n.type === 'text' || n.type === 'comment') return inline(n, owner);
    // HTML tables nested inside a cell express a panel's row layout. Flatten
    // only that layout to line/column separators; retain every cell and math.
    if (n.name === 'table' || elements(n, c => c !== n && c.name === 'table').length) {
      bind(n, owner);
      return children(n).flatMap(c => cellContents(c, owner));
    }
    if (['tbody', 'thead', 'tfoot', 'tr', 'td', 'th'].includes(n.name)) {
      bind(n, owner);
      return [...children(n).flatMap(c => cellContents(c, owner)), ...(n.name === 'tr' ? [el('br')] : [' '])];
    }
    return inline(n, owner);
  }
  function tableContents(n: DomNode, owner: string): Child[] {
    if (n.type === 'text') return [n.data];
    if (n.type === 'comment' || active.has(n.name)) return [];
    bind(n, owner);
    if (n.name === 'table') return [table(n, owner)];
    if (n.name === 'math') return [equation(n, owner)];
    if (n.name === 'figcaption') return [el('p', { class: 'reader-caption' }, children(n).flatMap(c => inline(c, owner)))];
    if (['ul', 'ol', 'li', 'p', 'pre'].includes(n.name)) return [el(n.name, {}, children(n).flatMap(c => tableContents(c, owner)))];
    if (['div', 'figure', 'section'].includes(n.name) ||
      elements(n, child => child !== n && child.name === 'table').length) return children(n).flatMap(c => tableContents(c, owner));
    return inline(n, owner);
  }
  function figureImage(n: DomNode, owner: string, inlineImage = false): OutNode {
    bind(n, owner);
    // Math drawn inside an inline SVG picture (a TikZ node's foreignObject) travels with the picture, not as an equation.
    if (n.name === 'svg') for (const m of elements(n, c => c.name === 'math')) skippedMath.add(m);
    check(n.name !== 'object' || n.attribs.type === 'image/svg+xml', 'arxiv_asset_type');
    const url = n.name === 'svg' ? '#' + n.attribs.id : arxivAssetURL(n.attribs[n.name === 'img' ? 'src' : 'data'] ?? '', sourceURL);
    imageURLs.add(url);
    const asset = resolveImage(url);
    check(/^assets\/[a-f0-9]{64}\.(png|jpg)$/.test(asset.path) && Number.isSafeInteger(asset.width) && Number.isSafeInteger(asset.height)
      && asset.width > 0 && asset.height > 0 && asset.width <= LIMITS.imageDimension && asset.height <= LIMITS.imageDimension, 'arxiv_asset');
    const output = el('img', {src:asset.path,alt:'Figure',width:String(asset.width),height:String(asset.height),
      ...(inlineImage ? {class:'reader-inline-image'} : {})});
    figureImages.get(owner)!.push(output); return output;
  }
  function imageFigure(n: DomNode): OutNode {
    const images = elements(n, c => ['img','object','svg'].includes(c.name));
    check(images.length >= 1 && images.length <= LIMITS.imagesPerFigure && figures.length < LIMITS.figures, 'arxiv_figure');
    const captions = elements(n, c => c.name === 'figcaption');
    check(captions.length <= 1, 'arxiv_caption');
    return block(n, 'figure', 'figure', id => {
      const imageNodes: OutNode[] = []; figureImages.set(id, imageNodes);
      let caption: OutNode | null = null;
      // Preserve legend text and inline symbols instead of collecting images
      // and accidentally discarding the other children of a figure.
      const parts: Child[] = [];
      const visit = (child: DomNode) => {
        if (child.type === 'comment' || active.has(child.name)) return;
        bind(child, id);
        if (child.name === 'figcaption') {
          caption = el('figcaption', {}, children(child).flatMap(c => inline(c, id))); parts.push(caption);
        } else if (child.name === 'img' || child.name === 'object') parts.push(figureImage(child,id));
        // A picture beside words is a legend symbol, inline; a picture on its own (a table drawn as TikZ, 2610.18683's
        // Table 11, shown 0.65 em tall on build 43) is the figure's image.
        else if (child.name === 'svg') {
          const wrapper = child.parent && child.parent !== n ? child.parent : null;
          if (wrapper && normalizeSpace(textContent(wrapper)).length > 0) parts.push(...inline(child, id)); else parts.push(figureImage(child, id));
        }
        // A paragraph that only wraps the graphic (LaTeXML centres with p > span > img) is the figure's image, full
        // size; a paragraph with words keeps its graphics inline as legend symbols (build 31 drew 2610.17288's
        // teaser 0.65 em tall: "the figure is tiny").
        else if (child.name === 'p' && loneImage(child)) parts.push(figureImage(elements(child, c => ['img','object','svg'].includes(c.name))[0], id));
        else if (child.name === 'p') parts.push(el('p', {}, children(child).flatMap(c => inline(c,id))));
        else if (['div','span','table','thead','tbody','tfoot','tr','td','th'].includes(child.name)) children(child).forEach(visit);
        else parts.push(...inline(child,id));
      };
      if (['img','object','svg'].includes(n.name)) parts.push(figureImage(n,id));
      else children(n).forEach(visit);
      const output: Child[] = []; let run: Child[] = [];
      const flush = () => {
        if (run.some(c => typeof c !== 'string' || c.trim())) output.push(el('p', {}, run));
        run = [];
      };
      for (const part of parts) {
        if (typeof part !== 'string' && (['p','figcaption'].includes(part.name) || (part.name === 'img' && !part.attribs.class))) {
          flush(); output.push(part);
        } else run.push(part);
      }
      flush();
      const captionText = caption ? excerpt(normalizeSpace(outText(caption)), LIMITS.textBytes) : '';
      const alt = boundedText(captionText || images.map(i => i.attribs.alt ?? '').filter(Boolean).join(' ') || 'Figure', LIMITS.textBytes, 'arxiv_alt');
      for (const image of imageNodes) image.attribs.alt = alt;
      const paths = imageNodes.map(image => image.attribs.src);
      figures.push({ id, block_id: id, asset_paths: [...new Set(paths)], caption: captionText, alt });
      return output;
    }, {});
  }
  function templatePreamble(n: DomNode): void {
    const segments: { macro: string; nodes: DomNode[] }[] = [{ macro: '', nodes: [] }];
    const visit = (c: DomNode) => {
      if (isMarker(c)) { segments.push({ macro: c.attribs['data-reader-macro'], nodes: [] }); return; }
      if (c.type === 'tag' && ['p', 'div', 'section', 'span'].includes(c.name) && (c.name !== 'span' || elements(c, x => x !== c && isMarker(x)).length)) { children(c).forEach(visit); return; }
      segments[segments.length - 1].nodes.push(c);
    };
    children(n).forEach(visit);
    const text = (nodes: DomNode[]) => normalizeSpace(nodes.map(textContent).join(''));
    for (const segment of segments) {
      const words = text(segment.nodes);
      if (!words) continue;
      if (/abstract/i.test(segment.macro) && !pendingAbstract) { pendingAbstract = { owner: n, nodes: segment.nodes }; continue; }
      for (const m of segment.nodes.flatMap(x => elements(x, y => y.name === 'math'))) skippedMath.add(m);
      if (/contribution|thanks|footnote|note/i.test(segment.macro)) {
        const note = /^\[?\s*([^\]\s]{1,3})\s*\]\s*(.+)$/u.exec(words);
        templateNotes.push(note ? { mark: note[1], text: note[2] } : { mark: '', text: words });
        continue;
      }
      // Affiliation lines a template wrote as "1]Wuhan University".
      for (const line of nodes_lines(segment.nodes)) {
        const affiliation = /^\s*(\d{1,2}|[a-z])\s*\]\s*(.+?)\s*$/u.exec(line);
        if (affiliation) templateAffiliations.push({ mark: affiliation[1], text: normalizeSpace(affiliation[2]) });
      }
    }
  }
  function nodes_lines(nodes: DomNode[]): string[] { return nodes.map(textContent).join('').split('\n'); }
  function flow(n: DomNode): OutNode[] {
    if (n.type === 'comment' || active.has(n.name) || (n.type === 'text' && !n.data.trim())) return [];
    if (n.type === 'text') return [block(n, 'p', 'paragraph', () => [n.data])];
    check(n.type === 'tag', 'arxiv_node');
    if (isMarker(n)) { bind(n, blocks[blocks.length - 1]?.id ?? ''); return []; }
    // The date line under the header (the paper line already says the year and the arXiv revision).
    if (has(n, 'ltx_dates')) return [];
    // Publication notes under the title (a revision date, a venue line, a DOI and ISBN: 2610.07591, 2610.19855) are
    // catalog data, not the paper; the author block follows the title.
    if (has(n, 'ltx_pubnotes')) { for (const m of elements(n, c => c.name === 'math')) skippedMath.add(m); return []; }
    if (!titleSeen && ['div', 'p'].includes(n.name) && elements(n, c => isMarker(c)).length >= 2 && !elements(n, c => ['figure', 'table', 'h1'].includes(c.name)).length) {
      templatePreamble(n); return [];
    }
    // A recovered abstract reads where the paper's own would: after the title and the authors.
    let recovered: OutNode[] = [];
    if (pendingAbstract && titleSeen && n.name !== 'h1' && !has(n, 'ltx_authors')) {
      const { owner, nodes } = pendingAbstract; pendingAbstract = null;
      recovered = [block(owner, 'h6', 'heading', () => ['Abstract']), block(owner, 'p', 'paragraph', id => nodes.flatMap(c => inline(c, id)))];
    }
    const before = blocks.length;
    let output: OutNode[];
    if (n.name === 'h1') titleSeen = true;
    if (/^h[1-6]$/.test(n.name)) output = [block(n, n.name, 'heading', id => children(n).flatMap(c => inline(c, id)))];
    else if (n.name === 'figure') {
      const insideSVG = (c: DomNode) => { for (let a = c.parent; a; a = a.parent) if (a.name === 'svg') return true; return false; };
      const tables = elements(n, c => c.name === 'table' && !insideSVG(c));
      const images = elements(n, c => ['img','object','svg'].includes(c.name));
      const captions = children(n).filter(c => c.name === 'figcaption');
      if (captions.length > 1 && !tables.length && !elements(n, c => c !== n && c.name === 'figure').length) {
        // LaTeXML can put several complete numbered figures in one container.
        // Keep each image group with its following caption, in source order.
        output = []; let panel: DomNode[] = [];
        for (const child of children(n)) {
          panel.push(child);
          if (child.name === 'figcaption') {
            output.push(imageFigure({ ...n, attribs: {}, children: panel })); panel = [];
          }
        }
        output.push(...panel.flatMap(flow));
      } else if (tables.length && images.length && !elements(n, c => c !== n && c.name === 'figure').length
          && tables.every(t => !normalizeSpace(textContent(t)).length)) {
        // Panels laid out in a tabular whose cells hold only graphics (Batch Normalization's Figure 1, audit
        // 2026-10-15: graphics in table cells were left out): the figure's own images, in cell order.
        output = [imageFigure(n)];
      } else if (elements(n, c => c !== n && c.name === 'figure').length || (tables.length && images.length)) {
        // Compound figures keep their panel order and captions as separate,
        // non-nested reader blocks. A reference to the group opens its first panel.
        output = children(n).flatMap(flow);
      } else if (!tables.length && images.length === 0 && captions.length === 1
          && !children(n).some(c => c.name !== 'figcaption' && normalizeSpace(textContent(c)).length > 0)) {
        // A caption with no graphic of its own (LaTeXML's \\captionof after an unwrapped \\includegraphics, as in
        // 2610.17288's Figure 1): the caption paragraph, right under the figure the paragraph before it became.
        // A figure whose other children carry text (an algorithm's listing, a tabular in a paragraph) is a table
        // block below instead (audit 2026-10-15: nine of fifteen refusals were listings dropped here).
        output = [block(n, 'p', 'paragraph', id => children(captions[0]).flatMap(c => inline(c, id)), { class: 'reader-caption' })];
      } else if (tables.length || images.length === 0) {
        output = [block(n, 'div', 'table', id => children(n).flatMap(c => tableContents(c, id)), { class: 'reader-table' })];
      } else output = [imageFigure(n)];
    } else if (has(n, 'ltx_equation') || has(n, 'ltx_equationgroup')) {
      const maths = elements(n, c => c.name === 'math');
      // An "equation" that is only text (a file-name pattern marked as math, 2610.19830) reads as a paragraph.
      if (!maths.length) output = [block(n, 'p', 'paragraph', id => children(n).flatMap(c => inline(c, id)))];
      else output = [block(n, 'p', 'equation', id => {
        const parts: Child[] = [];
        for (const math of maths) parts.push(equation(math, id, true));
        const tags = elements(n, c => has(c, 'ltx_tag_equation') || has(c, 'ltx_tag_equationgroup'));
        if (tags.length) {
          const last = parts[parts.length - 1] as OutNode;
          last.attribs.class += ' reader-tagged';
          last.children.push(el('span', { class: 'reader-tag' }, [tags.map(textContent).join(' ')]));
        }
        walk(n, child => { if (child.name !== 'math' && child.attribs?.id && !aliases.has(child.attribs.id)) bind(child, id); });
        return parts;
      })];
    } else if (n.name === 'table') output = [block(n, 'div', 'table', id => [table(n, id)], { class: 'reader-table' })];
    else if (n.name === 'pre') output = [block(n, 'pre', 'code', () => [el('code', {}, [textContent(n)])])];
    else if (n.name === 'ul' || n.name === 'ol') {
      const list = el(n.name, has(n, 'ltx_biblist') ? { class: 'reader-references' } : {}, []);
      const pending: DomNode[] = [];
      for (const item of children(n)) {
        if (item.type === 'text' && !item.data.trim() || item.type === 'comment') continue;
        check(item.name === 'li', 'arxiv_list');
        // An item holding a table (KAN's enumerated comparisons) keeps it as a table inside the item.
        const tabular = elements(item, c => c !== item && c.name === 'table').length > 0;
        // A figure inside an item (PaLM's first figure) becomes its own block after the list; the item keeps its words.
        const holdsFigure = (c: DomNode) => c.name === 'figure' || elements(c, x => x !== c && x.name === 'figure').length > 0;
        const figures = children(item).filter(holdsFigure);
        list.children.push(block(item, 'li', 'list', id => children(item).filter(c => !holdsFigure(c)).flatMap(c => tabular ? tableContents(c, id) : inline(c, id))));
        pending.push(...figures);
      }
      // Compiled after every item so the index order matches the page (a block is numbered when it is made).
      output = [list, ...pending.flatMap(flow)];
    } else if (n.name !== 'figcaption' && n.name !== 'math' && !has(n, 'ltx_authors') && loneImage(n) && onTitlePage(n)) {
      // A logo on a custom title page (2610.15371's company mark above the title) is no figure: left out and counted.
      omittedGraphics += 1; for (const m of elements(n, c => c.name === 'math')) skippedMath.add(m); output = [];
    } else if (n.name !== 'figcaption' && n.name !== 'math' && !has(n, 'ltx_authors') && loneImage(n)) {
      // A TikZ picture that is really a framed text box (LaTeXML: `svg.ltx_picture` whose foreignObjects hold the
      // text): its words read as paragraphs and the frame is left out and counted. Any other lone graphic is a figure.
      const picture = elements(n, c => c.name === 'svg')[0];
      const labels = picture ? elements(picture, c => c.name === 'foreignObject').filter(fo => normalizeSpace(textContent(fo)).length > 0) : [];
      if (picture && labels.length) {
        omittedGraphics += 1;
        output = labels.map(fo => elements(fo, c => c.name === 'table').length
          ? block(fo, 'div', 'table', id => children(fo).flatMap(c => tableContents(c, id)), { class: 'reader-table' })
          : block(fo, 'p', 'paragraph', id => children(fo).flatMap(c => inline(c, id))));
        if (picture.attribs?.id && output.length) bind(picture, output[0].attribs.id);
      } else output = [imageFigure(n)];
    }
    // A table or figure wrapped in inline-blocks (LaTeXML's resizebox, `span.ltx_transformed_inner`): its container
    // is flow, not a paragraph, so the table reads as a table block.
    else if (n.name !== 'figcaption' && !has(n, 'ltx_authors') && elements(n, c => c !== n && ['table', 'figure'].includes(c.name)).length) output = children(n).flatMap(flow);
    else if (has(n, 'ltx_authors') && elements(n, c => has(c, 'ltx_creator')).length) output = [authorsBlock(n)];
    else if (n.name === 'p' || n.name === 'figcaption' || has(n, 'ltx_authors') || n.name === 'math') {
      output = [block(n, 'p', n.name === 'math' ? 'equation' : 'paragraph', id => n.name === 'math' ? [equation(n, id)]
        : children(n).flatMap(c => inline(c, id)), has(n, 'ltx_authors') ? { class: 'reader-authors' }
          : n.name === 'figcaption' ? { class: 'reader-caption' } : {})];
    } else if (n.name === 'hr') output = [el('hr')];
    else if (['article', 'section', 'div', 'header', 'footer', 'aside'].includes(n.name)) output = children(n).flatMap(flow);
    else if (n.name === 'img' || n.name === 'object' || n.name === 'svg') output = [imageFigure(n)];
    else output = [block(n, 'p', 'paragraph', id => inline(n, id))];
    if (blocks.length > before && n.attribs?.id && !aliases.has(n.attribs.id)) bind(n, blocks[before].id);
    return recovered.length ? [...recovered, ...output] : output;
  }
  // No `h1` (a template that set the title as a bold paragraph, 2610.19861): the catalog's title heads the paper and
  // a paragraph that merely repeats it is left out. A page that is only a pointer to the PDF (a stub) is no paper.
  const metadataTitle = typeof options.title === 'string' ? normalizeSpace(options.title).slice(0, 2000) : '';
  const synthetic = new Set<OutNode>();
  if (!elements(root, n => n.name === 'h1').length && metadataTitle) {
    const heading = block(root, 'h1', 'heading', () => [metadataTitle]); synthetic.add(heading); top.push(heading); titleSeen = true;
  }
  top.push(...flow(root));
  // The index lists blocks, equations and figures in page order; after a move, the order is read back from the page.
  const reorder = () => {
    const order = new Map<string, number>();
    const walk = (node: Child) => {
      if (typeof node !== 'object') return;
      const id = node.attribs['data-reader-block'] ?? node.attribs['data-reader-equation']; if (id) order.set(id, order.size);
      node.children.forEach(walk);
    };
    top.forEach(walk);
    const at = (id: string) => order.get(id) ?? Number.MAX_SAFE_INTEGER;
    blocks.sort((a, b) => at(a.id) - at(b.id)); equations.sort((a, b) => at(a.id) - at(b.id)); figures.sort((a, b) => at(a.id) - at(b.id));
  };
  const fold = (t: string) => t.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
  const remove = (entry: { id: string; node: OutNode }) => {
    const at = blocks.indexOf(entry); if (at >= 0) blocks.splice(at, 1);
    const index = top.indexOf(entry.node); if (index >= 0) top.splice(index, 1);
  };
  // Front matter first: a figure or a venue line LaTeXML placed before the title (DDPM's samples, SGAnalog's
  // "AI for Chip Design") follows the title, the authors and the abstract instead (sweep, 2026-10-15).
  const h1At = top.findIndex(node => node.name === 'h1');
  if (h1At > 0) {
    const front = (node: OutNode) => node.name === 'h1' || (node.name === 'p' && node.attribs.class === 'reader-authors')
      || (/^h[2-6]$/.test(node.name) && fold(outText(node)) === 'abstract');
    let end = h1At; while (end < top.length && front(top[end])) end += 1;
    // The abstract's paragraph(s), when a heading named it.
    if (end > h1At + 1 && /^h[2-6]$/.test(top[end - 1].name)) while (end < top.length && top[end].name === 'p' && top[end].attribs.class !== 'reader-authors') end += 1;
    const before = top.splice(0, h1At); top.splice(end - h1At, 0, ...before); reorder();
  }
  // No author block in the HTML (a template that set the names in a tabular, 2610.19861): the library's names head
  // the paper after its title, and a paragraph that merely lists them again is left out.
  if (metadataAuthors.length && !blocks.some(b => b.node.attribs.class === 'reader-authors')) {
    const names = metadataAuthors.join(', ');
    const authors = block(root, 'p', 'paragraph', () => [names], { class: 'reader-authors' }); synthetic.add(authors);
    const titleAt = top.findIndex(node => node.name === 'h1');
    top.splice(titleAt + 1, 0, authors); reorder();
    const listed = fold(metadataAuthors.join(' '));
    for (const entry of blocks.filter(b => b.kind === 'paragraph' && b.node !== authors && fold(outText(b.node)) === listed)) remove(entry);
    // A custom title page (2610.14075: names with marks in a tabular, affiliation lines, a date line, "Corresponding
    // authors:" with e-mail) reads into the header: its names with their marks when they are the catalog's, its
    // affiliations and notes under them; the date and e-mail lines go. A subtitle stays as the first paragraph.
    const catalog = new Set(metadataAuthors.map(fold));
    const parsedNames: Child[][] = [], affiliations: Child[][] = [], notes: { mark: string; body: Child[] }[] = [];
    let kept = 0;
    for (const node of top.slice(top.indexOf(authors) + 1, top.indexOf(authors) + 14)) {
      if (node.name !== 'p' || node.attribs.class) break;
      const entry = blocks.find(b => b.node === node); if (!entry) break;
      const text = normalizeSpace(outText(node)), run = parseRun(node.children);
      const matched = run.names.filter(unit => catalog.has(fold(plain(unit).replace(MARKS, '')))).length;
      if (/\bdate:/i.test(text) || (/\b(19|20)\d{2}\b/.test(text) && text.length <= 60 && !/[.!?]$/.test(text))) { remove(entry); continue; }
      if (/corresponding author|equal contribution|contributed equally/i.test(text) && text.length <= 240) {
        const mark = /^[†‡*§¶‖]/.exec(text)?.[0] ?? '';
        notes.push({ mark, body: [text.replace(EMAIL, '').replace(/^[†‡*§¶‖\s]+/, '').replace(/\s+([.,;:])/g, '$1').replace(/[\s,;:]+$/, '')] });
        remove(entry); continue;
      }
      if (run.names.length >= 2 && matched * 2 >= run.names.length) { parsedNames.push(...run.names); affiliations.push(...run.affiliations); remove(entry); continue; }
      if (!run.names.length && run.affiliations.length) { affiliations.push(...run.affiliations); remove(entry); continue; }
      if (++kept >= 3) break;
    }
    if (parsedNames.length || affiliations.length || notes.length) {
      authors.children = renderAuthors(parsedNames.length ? parsedNames : [[names]], affiliations, [], notes);
    }
  }
  // A macro definition LaTeXML left as text ("[1]for each #1 do", 2610.18683: TeX parameter tokens never read in prose)
  // is no paragraph; it counts as an unsupported command in the closing note.
  for (const entry of blocks.filter(b => b.kind === 'paragraph' && top.includes(b.node) && /#\d/.test(outText(b.node)))) { remove(entry); dropped += 1; }
  // A paragraph with nothing in it (a horizontal rule, an empty LaTeXML paragraph) is no block.
  const substance = (node: Child): boolean => typeof node === 'string' ? node.trim().length > 0
    : node.name === 'img' || node.name === 'a' || node.attribs['data-reader-equation'] !== undefined || node.children.some(substance);
  const targeted = new Set(links.map(link => aliases.get(link.target)));
  for (const entry of blocks.filter(b => b.kind === 'paragraph' && top.includes(b.node) && !targeted.has(b.id) && !substance(b.node))) remove(entry);
  if (metadataTitle && blocks[0]?.node.name === 'h1' && blocks[0].node.children[0] === metadataTitle) {
    const repeat = blocks.find((b, i) => i > 0 && b.kind === 'paragraph' && fold(outText(b.node)) === fold(metadataTitle));
    if (repeat) remove(repeat);
  }
  // A page that is only a pointer to the PDF (Adam v9: "See pages 1-last of … .pdf") is no paper, however the catalog heads it.
  const own = blocks.filter(b => !synthetic.has(b.node));
  check(own.length >= 3 || own.some(b => b.kind !== 'heading' && normalizeSpace(outText(b.node)).length > 200), 'arxiv_article');
  if (dropped > 0 || omittedGraphics > 0 || unresolvedCitations > 0) {
    // Said in the paper itself, as its last paragraph, so a reader knows what the HTML omitted.
    const parts = [dropped > 0 ? `${dropped} unsupported ${dropped === 1 ? 'command' : 'commands'}` : '',
      omittedGraphics > 0 ? `${omittedGraphics} inline ${omittedGraphics === 1 ? 'graphic' : 'graphics'}` : '',
      unresolvedCitations > 0 ? `${unresolvedCitations} unresolved ${unresolvedCitations === 1 ? 'citation' : 'citations'}` : ''].filter(Boolean);
    const id = nextID();
    const note = el('p', { id, 'data-reader-block': id, 'data-reader-kind': 'paragraph' },
      [`Note: arXiv’s HTML conversion of this version left out ${parts.join(' and ')}. The PDF is complete.`]);
    blocks.push({ id, kind: 'paragraph', node: note }); top.push(note);
  }
  check(new Set([...usedMath, ...skippedMath]).size === elements(root, n => n.name === 'math').length, 'arxiv_math_coverage');
  for (const entry of blocks) if (entry.kind === 'figure') entry.node.attribs['data-reader-figure'] = entry.id;
  for (const link of links) {
    const id = aliases.get(link.target); check(id, 'arxiv_unresolved_fragment'); link.node.attribs.href = `#${id}`;
  }
  const titles = blocks.filter(b => b.node.name === 'h1');
  check(titles.length === 1, 'arxiv_title');
  const title = boundedText(normalizeSpace(outText(titles[0].node)), LIMITS.headingBytes, 'arxiv_title');
  check(title.length > 0, 'arxiv_title');
  const headings = blocks.filter(b => b.kind === 'heading' && b !== titles[0]).map(b => ({ id: b.id,
    level: Number(b.node.name.slice(1)), title: boundedText(normalizeSpace(outText(b.node)), LIMITS.headingBytes, 'heading_limit') }));
  check(headings.length <= LIMITS.headings, 'heading_limit');
  const index: ReaderIndex = { format: INDEX_FORMAT, title, headings, equations, figures,
    // A block longer than the index allows (a bibliography entry listing hundreds of authors) is excerpted, as the
    // validator compares (audit 2026-10-15); control characters still refuse.
    blocks: blocks.map(b => ({ id: b.id, kind: b.kind, text: boundedText(excerpt(normalizeSpace(outText(b.node)), LIMITS.textBytes), LIMITS.textBytes, 'arxiv_block_text') })) };
  const html = htmlPrefix(title) + top.map(render).join('') + HTML_SUFFIX;
  check(utf8(html).length <= LIMITS.htmlBytes && imageURLs.size <= LIMITS.archiveImages, 'html_limit');
  return { index, html, imageURLs: [...imageURLs].sort() };
}
function onTitlePage(node: DomNode): boolean {
  for (let p: DomNode | null = node; p; p = p.parent) if (p.type === 'tag' && has(p, 'ltx_titlepage')) return true;
  return false;
}
function nearest(node: DomNode, name: string): DomNode | null {
  for (let p = node.parent; p; p = p.parent) if (p.name === name) return p;
  return null;
}
