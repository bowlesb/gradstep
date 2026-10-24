// Inline pictures (LaTeXML's SVG) as standalone images: the definitions they use from elsewhere on the page, SVG
// elements only, and TikZ labels drawn as SVG text. The device rasterizes the result (device-compiler.ts).
import { elements, normalizeSpace, type DomNode } from '../html.ts';
import { nearest } from './context.ts';

/** A TikZ picture may use a pattern or symbol LaTeXML defined once elsewhere in the page (Apertus 1.5's Figure 9, refused
 * as `svg_fragment` on build 42): those definitions travel with the picture in their own `defs`, and an element whose
 * reference nothing on the page defines is left out rather than refusing the paper. */
export function withSharedDefinitions(root: DomNode, picture: DomNode): DomNode {
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

/** Only SVG elements leave with a picture: HTML the parser left inside one (a figure and its table inside a TikZ box,
 * 2610.20570, refused `svg_invalid` on the device) is dropped, and so is any `foreignObject` the label pass did not
 * turn into text. The device's own admission lists the same elements. */
const SVG_ELEMENTS = new Set(['svg','g','defs','path','rect','circle','ellipse','line','polyline','polygon','text','tspan','textPath','use',
  'symbol','clipPath','mask','linearGradient','radialGradient','stop','pattern','title','desc','style','metadata','marker']);
export function svgOnly(n: DomNode): DomNode {
  if (n.type !== 'tag') return n;
  return { ...n, children: (n.children ?? []).filter(c => c.type !== 'tag' || SVG_ELEMENTS.has(c.name)).map(svgOnly) };
}

const classOf = (n: DomNode) => (n.attribs?.class ?? '').split(/\s+/);
/** LaTeXML's `\phantom` (a strut such as "Ag" kept for its height) is laid out but never seen; drawn as text it read
 * "Agand", "Agconcern" (build 88, 2610.14162v1 Figure 3). */
const hidden = (n: DomNode) => classOf(n).includes('ltx_phantom') || /visibility:\s*hidden/.test(n.attribs?.style ?? '');

/** A label's words as a reader sees them: MathML's TeX annotation is not shown ("σ", not "σ\sigma"), nor a phantom. */
function labelText(n: DomNode): string {
  if (n.type === 'text') return n.data;
  if (n.type !== 'tag' || n.name === 'annotation' || n.name === 'annotation-xml' || hidden(n)) return '';
  return (n.children ?? []).map(labelText).join('');
}

type Word = { text: string; bold: boolean };
type Line = { words: Word[]; size: number };

/** A label's lines: each paragraph (`ltx_p`), table row, `br` and rule starts one, as a browser lays the label's HTML out.
 * A line's size is its first word's (`font-size:NN%` on the way down); bold follows `ltx_font_bold`/`ltx_font_medium`. */
function labelLines(fo: DomNode, fontSize: number): Line[] {
  const lines: Line[] = [];
  let current: Line | null = null, glued = false;
  const close = () => { if (current?.words.length) lines.push(current); current = null; glued = false; };
  const visit = (n: DomNode, scale: number, bold: boolean) => {
    if (n.type === 'text') {
      for (const part of n.data.split(/(\s+)/)) {
        if (!part) continue;
        if (/^\s/.test(part)) { glued = false; continue; }
        current ??= { words: [], size: fontSize * scale };
        if (glued && current.words.length) current.words[current.words.length - 1].text += part;
        else current.words.push({ text: part, bold });
        glued = true;
      }
      return;
    }
    if (n.type !== 'tag' || n.name === 'annotation' || n.name === 'annotation-xml' || hidden(n)) return;
    const names = classOf(n);
    if (n.name === 'br' || names.includes('ltx_rule')) { close(); return; }
    const percent = /font-size:\s*([\d.]+)%/.exec(n.attribs.style ?? '');
    const inner = percent ? scale * Number(percent[1]) / 100 : scale;
    const strong = names.includes('ltx_font_bold') ? true : names.includes('ltx_font_medium') ? false : bold;
    const block = ['p', 'div', 'tr'].includes(n.name) || names.some(c => ['ltx_p', 'ltx_para', 'ltx_tr'].includes(c));
    if (block) close();
    if (n.name === 'td' || names.includes('ltx_td')) glued = false;
    for (const child of n.children ?? []) visit(child, inner, strong);
    if (block) close();
  };
  for (const child of fo.children ?? []) visit(child, 1, false);
  close();
  return lines;
}

/** Greedy wrapping at an estimated advance (half an em a letter, a little more in bold): a label set in a minipage keeps
 * to the minipage's width, as a browser wraps it in arXiv's own page. */
function wrap(line: Line, width: number): Line[] {
  const advance = (w: Word, first: boolean) => (first ? 0 : line.size * 0.25) + w.text.length * line.size * (w.bold ? 0.55 : 0.5);
  const out: Line[] = []; let words: Word[] = [], used = 0;
  for (const word of line.words) {
    if (words.length && used + advance(word, false) > width) { out.push({ words, size: line.size }); words = []; used = 0; }
    used += advance(word, !words.length); words.push(word);
  }
  if (words.length) out.push({ words, size: line.size });
  return out;
}

const round = (v: number) => String(Math.round(v * 100) / 100);
const textNode = (data: string): DomNode => ({ type: 'text', data, name: '', attribs: {}, children: [], parent: null });

/** One drawn line, its bold words as `tspan`s. HTML text is never stroked: a picture's line width would otherwise
 * thicken every letter. */
function lineText(line: Line, x: number, y: number, anchor: string): DomNode {
  const parts: DomNode[] = [];
  line.words.forEach((word, i) => {
    const text = (i ? ' ' : '') + word.text, last = parts[parts.length - 1];
    if (last && (last.type === 'tag') === word.bold) (word.bold ? last.children[0] : last).data += text;
    else parts.push(word.bold ? { type: 'tag', name: 'tspan', attribs: { 'font-weight': 'bold' }, children: [textNode(text)], parent: null, data: '' } : textNode(text));
  });
  return { type: 'tag', name: 'text', attribs: { x: round(x), y: round(y), 'text-anchor': anchor, 'font-size': round(line.size), stroke: 'none' },
    children: parts, parent: null, data: '' };
}

/** LaTeXML draws TikZ/pgfplots node labels as `foreignObject` HTML, which the device SVG admission refuses. Each label
 * becomes SVG text, so the diagram keeps its words; placement is best effort.
 *
 * The text is drawn in the foreignObject's own coordinates, exactly where a browser lays out its HTML: the object's
 * `transform` (LaTeXML's counter-flip of the picture's y-up system, `matrix(1 0 0 -1 0 h)`) moves to the wrapping `g`
 * and the text adds none. Revision 22 (build 73, 2610.22371v1 Figure 3): a second flip on the text drew every tick and
 * axis label of a flipped picture upside down.
 *
 * A one-line label is centred in its box. A label of several lines (paragraphs, table rows, `\\`) or set in a minipage
 * is drawn line by line: a minipage's from its top-left corner and wrapped to the minipage's width, other lines centred.
 * Revision 23 (build 88, 2610.14162v1 Figure 3): every label was one centred line, so each step box's sentence ran across
 * the whole figure over its neighbours' and the boxes looked empty. */
export function svgTextLabels(n: DomNode): DomNode {
  if (n.type !== 'tag') return n;
  if (n.name === 'foreignObject') {
    const width = Number(n.attribs.width) || 0, height = Number(n.attribs.height) || 0;
    const size = /font-size:\s*([\d.]+)(pt|px)/.exec(n.attribs.style ?? '');
    const fontSize = size ? (size[2] === 'pt' ? Number(size[1]) * 4 / 3 : Number(size[1])) : 13;
    const group = (texts: DomNode[]): DomNode =>
      ({ type: 'tag', name: 'g', attribs: n.attribs.transform ? { transform: n.attribs.transform } : {}, children: texts, parent: null, data: '' });
    const minipage = (function find(x: DomNode): DomNode | null {
      if (x.type !== 'tag' || hidden(x)) return null;
      if (classOf(x).includes('ltx_minipage')) return x;
      for (const c of x.children ?? []) { const found = find(c); if (found) return found; }
      return null;
    })(n);
    const lines = labelLines(n, fontSize);
    if (lines.length > 1 || minipage) {
      const em = /width:\s*([\d.]+)em/.exec(minipage?.attribs.style ?? '');
      const measure = minipage ? (em ? Number(em[1]) * fontSize : width) : Infinity;
      const laid = lines.flatMap(line => wrap(line, measure));
      // A line box 1.25 em high, its baseline 0.8 em below the box's top half-leading.
      let top = minipage ? 0 : (height - laid.reduce((sum, line) => sum + line.size * 1.25, 0)) / 2;
      return group(laid.map(line => {
        const baseline = top + line.size * (0.125 + 0.8); top += line.size * 1.25;
        return minipage ? lineText(line, 0, baseline, 'start') : lineText(line, width / 2, baseline, 'middle');
      }));
    }
    const text: DomNode = { type: 'tag', name: 'text', attribs: { x: String(width / 2), y: String(height / 2), 'text-anchor': 'middle',
      // HTML text is never stroked: a picture's line width would otherwise thicken every letter.
      'dominant-baseline': 'central', 'font-size': String(Math.round(fontSize * 100) / 100), stroke: 'none' },
      children: [textNode(normalizeSpace(labelText(n)))], parent: null, data: '' };
    return group([text]);
  }
  return { ...n, children: (n.children ?? []).map(svgTextLabels) };
}
