// Visual answers (docs/proposals/CHAT_TOOLS.md): the model may show one HTML fragment beside an answer — a flow chart
// drawn as SVG, a pipeline, a timeline, a comparison table. The fragment is untrusted: this module keeps a finite
// vocabulary (structure, text, tables, inline SVG shapes), inline CSS without external references, links to https
// only, and refuses anything that looks like script. Devices render the result in a frame with no scripts and no
// network (native: WKWebView with content JavaScript off; browser: a sandboxed iframe), encrypted like a diagram.
import { escapeAttr, escapeText, parseHTML, type DomNode } from './reader/html.ts';

export const VISUAL_MAX_BYTES = 16_000;
/** The sanitized fragment may grow a little (quoted attributes, closed tags). */
export const VISUAL_OUTPUT_MAX_BYTES = 24_000;
export interface VisualRequest { title: string; html: string }

const STRUCTURE = new Set(['div', 'section', 'article', 'header', 'footer', 'main', 'aside', 'nav', 'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'ul', 'ol', 'li', 'dl', 'dt', 'dd', 'table', 'thead', 'tbody', 'tfoot', 'tr', 'th', 'td', 'caption', 'colgroup', 'col', 'blockquote',
  'pre', 'code', 'em', 'strong', 'b', 'i', 'u', 's', 'small', 'sub', 'sup', 'span', 'br', 'hr', 'figure', 'figcaption', 'details',
  'summary', 'kbd', 'var', 'abbr', 'mark', 'a', 'style', 'time', 'cite', 'q', 'dfn']);
const VOID = new Set(['br', 'hr', 'col']);
/** SVG element names by their lowercase form (the HTML parser lowercases names). */
const SVG: Record<string, string> = Object.fromEntries(['svg', 'g', 'defs', 'path', 'rect', 'circle', 'ellipse', 'line', 'polyline', 'polygon',
  'text', 'tspan', 'textPath', 'use', 'symbol', 'clipPath', 'mask', 'linearGradient', 'radialGradient', 'stop', 'pattern', 'marker', 'title', 'desc']
  .map(name => [name.toLowerCase(), name]));
/** Anything in this set refuses the whole visual: nothing the model should ever produce. */
const REFUSED = new Set(['script', 'iframe', 'object', 'embed', 'frame', 'frameset', 'applet', 'base', 'link', 'meta', 'form', 'input',
  'button', 'textarea', 'select', 'option', 'template', 'noscript', 'foreignobject', 'image', 'canvas', 'dialog', 'slot', 'portal']);
/** Left out quietly with their contents (an image the frame could not load anyway, math the answer text already carries). */
const DROPPED = new Set(['img', 'picture', 'video', 'audio', 'source', 'track', 'map', 'area', 'math', 'svg:a']);
const GLOBAL = new Set(['class', 'title', 'lang', 'dir', 'id', 'style']);
const HTML_ATTRS: Record<string, readonly string[]> = { td: ['colspan', 'rowspan', 'scope'], th: ['colspan', 'rowspan', 'scope'], col: ['span'],
  colgroup: ['span'], a: ['href'], ol: ['start', 'type', 'reversed'], details: ['open'], time: ['datetime'] };
const SVG_ATTRS: Record<string, string> = Object.fromEntries(['viewBox', 'width', 'height', 'x', 'y', 'x1', 'y1', 'x2', 'y2', 'cx', 'cy', 'r', 'rx', 'ry', 'd',
  'points', 'fill', 'stroke', 'stroke-width', 'stroke-dasharray', 'stroke-dashoffset', 'stroke-linecap', 'stroke-linejoin', 'stroke-opacity',
  'fill-opacity', 'fill-rule', 'opacity', 'transform', 'font-size', 'font-family', 'font-weight', 'font-style', 'text-anchor',
  'dominant-baseline', 'alignment-baseline', 'marker-start', 'marker-mid', 'marker-end', 'href', 'offset', 'stop-color', 'stop-opacity',
  'gradientUnits', 'gradientTransform', 'patternUnits', 'patternTransform', 'markerWidth', 'markerHeight', 'markerUnits', 'refX', 'refY',
  'orient', 'preserveAspectRatio', 'clip-path', 'clipPathUnits', 'mask', 'dx', 'dy', 'rotate', 'textLength', 'lengthAdjust',
  'letter-spacing', 'xml:space', 'xmlns', 'role', 'aria-label'].map(name => [name.toLowerCase(), name]));
const UNSAFE_CSS = /url\s*\(|expression\s*\(|@import|@charset|javascript:|vbscript:|data:|behavior\s*:|-moz-binding|\\|<|\/\*[\s\S]*?\*\/|&#/i;
const SAFE_ID = /^[A-Za-z][\w:.-]{0,63}$/;
const SVG_URL = /url\(\s*#[\w:.-]+\s*\)/g;
const LIMITS = { nodes: 4_000, depth: 48 };

interface Out { name: string; attribs: Record<string, string>; children: (Out | string)[]; raw?: string }

function sanitize(node: DomNode, inSVG: boolean, state: { refused: boolean; nodes: number; text: number; drawings: number }, depth: number): (Out | string)[] {
  if (node.type === 'text') { state.text += node.data.trim().length; return [node.data]; }
  // The parser types <script> and <style> elements by name.
  if (node.type === 'script') { state.refused = true; return []; }
  if (node.type !== 'tag' && node.type !== 'style') return [];
  if (++state.nodes > LIMITS.nodes || depth > LIMITS.depth) { state.refused = true; return []; }
  const lower = node.name.toLowerCase();
  if (REFUSED.has(lower)) { state.refused = true; return []; }
  const children = node.children ?? [];
  if (lower === 'style') {
    const css = (node.children ?? []).filter(child => child.type === 'text').map(child => child.data).join('');
    return !css.trim() || UNSAFE_CSS.test(css) ? [] : [{ name: 'style', attribs: {}, children: [], raw: css }];
  }
  const svg = inSVG || lower === 'svg';
  if (DROPPED.has(lower) || (svg && lower === 'a')) return [];
  const name = svg ? SVG[lower] : STRUCTURE.has(lower) ? lower : null;
  if (!name) return children.flatMap(child => sanitize(child, svg, state, depth + 1));
  if (name === 'svg') state.drawings += 1;
  const attribs: Record<string, string> = {};
  for (const [key, value] of Object.entries(node.attribs ?? {})) {
    const k = key.toLowerCase();
    if (k.startsWith('on') || /[<>"'`]/.test(value) || value.length > 4096) { if (k.startsWith('on')) state.refused = true; continue; }
    if (k === 'style') { if (!UNSAFE_CSS.test(value)) attribs.style = value; continue; }
    if (GLOBAL.has(k)) { if (k === 'id' ? SAFE_ID.test(value) : value.length <= 256) attribs[k] = value; continue; }
    if (svg) {
      const canonical = SVG_ATTRS[k === 'xlink:href' ? 'href' : k];
      if (!canonical) continue;
      if (canonical === 'href') { if (/^#[\w:.-]{1,64}$/.test(value)) attribs.href = value; continue; }
      if (/url\(/i.test(value.replace(SVG_URL, ''))) continue;
      attribs[canonical] = value;
      continue;
    }
    if (!HTML_ATTRS[name]?.includes(k)) continue;
    if (k === 'href') { if (/^https:\/\/[^\s"'<>]{1,500}$/i.test(value)) { attribs.href = value; attribs.rel = 'noopener noreferrer'; attribs.target = '_blank'; } continue; }
    if (/^[\w -]{1,32}$/.test(value)) attribs[k] = value;
  }
  return [{ name, attribs, children: VOID.has(name) ? [] : children.flatMap(child => sanitize(child, svg, state, depth + 1)) }];
}

function renderOut(node: Out | string): string {
  if (typeof node === 'string') return escapeText(node.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, ''));
  if (node.raw !== undefined) return `<style>${node.raw.replace(/<\/style/gi, '')}</style>`;
  const attrs = Object.keys(node.attribs).sort().map(key => ` ${key}="${escapeAttr(node.attribs[key].replace(/[\u0000-\u001f\u007f]/g, ' '))}"`).join('');
  if (VOID.has(node.name)) return `<${node.name}${attrs}>`;
  return `<${node.name}${attrs}>${node.children.map(renderOut).join('')}</${node.name}>`;
}

/** The sanitized fragment, or null when the input is not a visual the reader's frame may show. */
export function sanitizeVisual(html: string): string | null {
  if (new TextEncoder().encode(html).length > VISUAL_MAX_BYTES || /<!doctype|<\?xml/i.test(html)) return null;
  let root: DomNode;
  try { root = parseHTML(`<!doctype html><html><body>${html}</body></html>`); } catch { return null; }
  const find = (node: DomNode): DomNode | null => node.type === 'tag' && node.name === 'body' ? node : (node.children ?? []).map(find).find(Boolean) ?? null;
  const body = find(root);
  if (!body) return null;
  const state = { refused: false, nodes: 0, text: 0, drawings: 0 };
  const out = (body.children ?? []).flatMap(child => sanitize(child, false, state, 0));
  if (state.refused || (state.text === 0 && state.drawings === 0)) return null;
  const rendered = out.map(renderOut).join('').trim();
  return rendered && new TextEncoder().encode(rendered).length <= VISUAL_OUTPUT_MAX_BYTES ? rendered : null;
}

/** Validates the model's create_visual input. */
export function visualRequest(input: unknown): VisualRequest | null {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return null;
  const value = input as Record<string, unknown>;
  if (Object.keys(value).some(key => !['title', 'html'].includes(key))) return null;
  const title = typeof value.title === 'string' ? value.title.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim() : '';
  if (!title || [...title].length > 120 || typeof value.html !== 'string') return null;
  const html = sanitizeVisual(value.html.replace(/\r\n?/g, '\n').trim());
  return html ? { title, html } : null;
}

/** The document a device wraps the fragment in (visual-document.ts, which the browser imports too). */
export { visualDocument } from './visual-document.ts';
