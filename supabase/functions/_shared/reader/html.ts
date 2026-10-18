import { parseDocument } from 'htmlparser2';
import { check, CONTROL, fail } from './util.ts';
import { CSP, LIMITS } from './profile.ts';

// Minimal structural view of htmlparser2's DOM; avoids a type dependency on
// domhandler while staying faithful to its runtime shape.
export interface DomNode {
  type: string;
  name: string;
  data: string;
  attribs: Record<string, string>;
  children: DomNode[];
  parent: DomNode | null;
}

export function parseHTML(html: string, xml = false): DomNode {
  check(html.length <= LIMITS.htmlBytes, 'html_limit');
  const root = parseDocument(html, xml
    ? { xmlMode: true, decodeEntities: true, recognizeSelfClosing: true }
    : { decodeEntities: true, recognizeSelfClosing: true, lowerCaseAttributeNames: false }) as unknown as DomNode;
  let count = 0;
  walk(root, (_node, depth) => { check(++count <= LIMITS.domNodes && depth <= LIMITS.domDepth, 'dom_limit'); });
  return root;
}
export function walk(node: DomNode, visit: (node: DomNode, depth: number) => void, depth = 0): void {
  visit(node, depth);
  for (const child of node.children ?? []) walk(child, visit, depth + 1);
}
export function elements(root: DomNode, predicate: (node: DomNode) => boolean): DomNode[] {
  const found: DomNode[] = [];
  walk(root, node => { if (node.type === 'tag' && predicate(node)) found.push(node); });
  return found;
}
export function textContent(node: DomNode): string {
  if (node.type === 'text') return node.data;
  return (node.children ?? []).map(textContent).join('');
}
export function classes(node: DomNode): string[] {
  return (node.attribs?.class ?? '').split(/\s+/).filter(Boolean);
}

export const escapeText = (value: string): string => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
export const escapeAttr = (value: string): string => escapeText(value).replaceAll('"', '&quot;');

// --- Output vocabulary -----------------------------------------------------
// Everything the generator emits (and the validator admits). Phrasing content
// rules keep htmlparser2 and WebKit's HTML5 tree builder in agreement.
export const VOID = new Set(['img', 'br', 'hr']);
export const PHRASING = new Set(['a', 'em', 'i', 'strong', 'b', 'u', 's', 'sub', 'sup', 'code', 'br', 'span', 'math']);
export const HTML_ATTRIBUTES: Record<string, readonly string[]> = {
  h1: ['id', 'data-reader-block', 'data-reader-kind'], h2: ['id', 'data-reader-block', 'data-reader-kind'],
  h3: ['id', 'data-reader-block', 'data-reader-kind'], h4: ['id', 'data-reader-block', 'data-reader-kind'],
  h5: ['id', 'data-reader-block', 'data-reader-kind'], h6: ['id', 'data-reader-block', 'data-reader-kind'],
  p: ['id', 'class', 'data-reader-block', 'data-reader-kind'],
  div: ['id', 'class', 'data-reader-block', 'data-reader-kind'],
  figure: ['id', 'data-reader-block', 'data-reader-kind', 'data-reader-figure'],
  figcaption: [], img: ['src', 'alt', 'width', 'height'],
  table: [], tbody: [], tr: [], th: ['colspan', 'rowspan'], td: ['colspan', 'rowspan'],
  ul: ['class'], ol: ['class', 'start'], li: ['id', 'class', 'data-reader-block', 'data-reader-kind'],
  pre: ['id', 'data-reader-block', 'data-reader-kind'], code: [], hr: [],
  a: ['href', 'rel'], em: [], i: [], strong: [], b: [], u: [], s: [], sub: [], sup: [], br: [],
  span: ['id', 'class', 'data-reader-equation', 'data-latex'],
};
export const CLASSES = new Set(['reader-authors', 'reader-abstract', 'reader-caption', 'reader-table', 'reader-references',
  'reader-footnotes', 'reader-custom-marker', 'reader-marker', 'reader-equation', 'reader-inline', 'reader-display',
  'reader-tagged', 'reader-tag', 'reader-math-fallback',
  'reader-affiliations', 'reader-notes', 'reader-affiliation-lines']);

const MATH_TOKEN = new Set(['mi', 'mo', 'mn', 'mtext', 'ms']);
const MATH_CONTAINER = new Set(['math', 'mrow', 'msub', 'msup', 'msubsup', 'munder', 'mover', 'munderover', 'mfrac',
  'msqrt', 'mroot', 'mtable', 'mtr', 'mtd', 'mstyle', 'mpadded', 'mphantom', 'menclose', 'mmultiscripts',
  'mprescripts', 'none', 'mspace', 'mfenced']);
export const MATH_ELEMENTS = new Set([...MATH_TOKEN, ...MATH_CONTAINER]);
export const isMathToken = (name: string): boolean => MATH_TOKEN.has(name);
const GENERIC = ['mathvariant', 'mathsize', 'mathcolor', 'mathbackground', 'displaystyle', 'scriptlevel', 'dir'];
const TABLE = ['rowalign', 'columnalign', 'rowspacing', 'columnspacing', 'rowlines', 'columnlines', 'frame',
  'framespacing', 'equalrows', 'equalcolumns', 'columnwidth', 'width', 'align'];
export const MATH_ATTRIBUTES: Record<string, readonly string[]> = {
  math: [...GENERIC, 'display'],
  mo: [...GENERIC, 'stretchy', 'fence', 'separator', 'symmetric', 'largeop', 'movablelimits', 'accent', 'form',
    'lspace', 'rspace', 'minsize', 'maxsize'],
  mover: [...GENERIC, 'accent'], munder: [...GENERIC, 'accentunder'], munderover: [...GENERIC, 'accent', 'accentunder'],
  mfrac: [...GENERIC, 'linethickness', 'numalign', 'denomalign', 'bevelled'],
  mspace: [...GENERIC, 'width', 'height', 'depth', 'linebreak'],
  mpadded: [...GENERIC, 'width', 'height', 'depth', 'lspace', 'voffset'],
  mtable: [...GENERIC, ...TABLE], mtr: [...GENERIC, 'rowalign', 'columnalign'],
  mtd: [...GENERIC, 'rowalign', 'columnalign', 'columnspan', 'rowspan'],
  menclose: [...GENERIC, 'notation'], mfenced: [...GENERIC, 'open', 'close', 'separators'],
  ms: [...GENERIC, 'lquote', 'rquote'],
};
const MATHVARIANTS = new Set(['normal', 'bold', 'italic', 'bold-italic', 'double-struck', 'bold-fraktur', 'script',
  'bold-script', 'fraktur', 'sans-serif', 'bold-sans-serif', 'sans-serif-italic', 'sans-serif-bold-italic',
  'monospace', 'initial', 'tailed', 'looped', 'stretched']);
// Attribute values are short tokens: no quotes, colons, slashes or brackets,
// so no URL, CSS function or markup can be expressed.
export function mathAttributeIsSafe(element: string, name: string, value: string): boolean {
  if (!(MATH_ATTRIBUTES[element] ?? GENERIC).includes(name)) return false;
  if (name === 'mathvariant') return MATHVARIANTS.has(value);
  if (name === 'display') return value === 'block' || value === 'inline';
  if (name === 'open' || name === 'close' || name === 'separators' || name === 'lquote' || name === 'rquote') {
    return value.length <= 8 && !/[<>&"'\\\u0000-\u001f\u007f]/.test(value);
  }
  return /^[A-Za-z0-9 .%#+-]{0,128}$/.test(value);
}

// Deterministic serializer: sorted attributes, explicit close tags for every
// non-void element. The validator requires parse(serialize(x)) to be stable.
export function serialize(node: DomNode): string {
  if (node.type === 'root') return node.children.map(serialize).join('');
  if (node.type === 'text') return escapeText(node.data);
  if (node.type !== 'tag') return fail('html_node_type');
  const attrs = Object.keys(node.attribs).sort().map(key => ` ${key}="${escapeAttr(node.attribs[key])}"`).join('');
  if (VOID.has(node.name) && !MATH_ELEMENTS.has(node.name)) return `<${node.name}${attrs}>`;
  return `<${node.name}${attrs}>${node.children.map(serialize).join('')}</${node.name}>`;
}

export interface OutNode { name: string; attribs: Record<string, string>; children: (OutNode | string)[] }
export function el(name: string, attribs: Record<string, string> = {}, children: (OutNode | string)[] = []): OutNode {
  return { name, attribs, children };
}
export function render(node: OutNode | string): string {
  if (typeof node === 'string') {
    check(!CONTROL.test(node), 'html_text');
    return escapeText(node);
  }
  const attrs = Object.keys(node.attribs).sort().map(key => {
    check(!CONTROL.test(node.attribs[key]), 'html_attribute_value');
    return ` ${key}="${escapeAttr(node.attribs[key])}"`;
  }).join('');
  if (VOID.has(node.name)) { check(node.children.length === 0, 'html_void'); return `<${node.name}${attrs}>`; }
  return `<${node.name}${attrs}>${node.children.map(render).join('')}</${node.name}>`;
}

// Generator-owned document skeleton; the validator requires it byte-for-byte.
export function htmlPrefix(title: string): string {
  return `<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="${CSP}"><title>${escapeText(title)}</title><link rel="stylesheet" href="reader.css"></head><body>\n`;
}
export const HTML_SUFFIX = '\n</body></html>\n';

// Index text: visible prose with each equation represented by its LaTeX.
// Element-level separators keep the result independent of text-node merging,
// so generator (OutNode) and validator (parsed DOM) agree exactly.
const TEXT_SEPARATED = new Set(['tr', 'td', 'th', 'li', 'p', 'pre', 'figcaption', 'table', 'tbody', 'ul', 'ol']);
export function outText(node: OutNode | string): string {
  if (typeof node === 'string') return node;
  if (node.attribs['data-reader-equation']) return ` ${node.attribs['data-latex']} `;
  if (node.name === 'br') return ' ';
  if (node.name === 'img' || node.attribs.class === 'reader-tag') return '';
  return node.children.map(outText).join('') + (TEXT_SEPARATED.has(node.name) ? ' ' : '');
}
export function domText(node: DomNode): string {
  if (node.type === 'text') return node.data;
  if (node.type !== 'tag') return '';
  if (node.attribs['data-reader-equation'] !== undefined) return ` ${node.attribs['data-latex']} `;
  if (node.name === 'br') return ' ';
  if (node.name === 'img' || node.attribs.class === 'reader-tag') return '';
  return node.children.map(domText).join('') + (TEXT_SEPARATED.has(node.name) ? ' ' : '');
}
export const normalizeSpace = (text: string): string => text.replace(/\s+/g, ' ').trim();
