import { parseDocument } from 'htmlparser2';
import sanitizeHTML from 'sanitize-html';
import { profile, requireThat, escapeText, escapeAttr, idIsSafe, pathIsSafe } from './common.mjs';

const htmlTags = ['div', 'span', 'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'strong', 'em', 'b', 'i', 's', 'del', 'sub', 'sup', 'br', 'hr', 'a', 'code', 'pre', 'ul', 'ol', 'li', 'table', 'thead', 'tbody', 'tfoot', 'tr', 'th', 'td', 'figure', 'figcaption', 'img'];
const svgTags = ['svg', 'g', 'path', 'rect', 'line', 'polyline', 'polygon', 'circle', 'ellipse', 'defs', 'use', 'text', 'tspan', 'clipPath'];
const mathTags = ['math', 'mrow', 'mi', 'mo', 'mn', 'mtext', 'mspace', 'ms', 'msub', 'msup', 'msubsup', 'munder', 'mover', 'munderover', 'mfrac', 'msqrt', 'mroot', 'mfenced', 'mtable', 'mtr', 'mlabeledtr', 'mtd', 'mstyle', 'mpadded', 'mphantom', 'menclose', 'semantics', 'annotation'];
const tags = new Set([...htmlTags, ...svgTags, ...mathTags]);
const commonAttrs = ['id', 'class', 'style', 'role', 'aria-hidden', 'aria-label', 'aria-labelledby', 'hidden', 'data-reader-block', 'data-reader-kind', 'data-reader-equation', 'data-reader-figure'];
const specific = {
  a: ['href', 'title'], img: ['src', 'alt', 'title', 'width', 'height'],
  ol: ['start'], li: ['value'], th: ['colspan', 'rowspan', 'scope', 'align'], td: ['colspan', 'rowspan', 'align'],
  svg: ['xmlns', 'xmlns:xlink', 'x', 'y', 'width', 'height', 'viewBox', 'preserveAspectRatio', 'focusable', 'data-table', 'data-labels'],
  g: ['stroke', 'fill', 'stroke-width', 'transform', 'data-mml-node', 'data-mjx-texclass', 'data-mjx-error', 'data-labels', 'data-idbox'],
  path: ['d', 'fill', 'stroke', 'stroke-width', 'transform', 'data-c'],
  rect: ['x', 'y', 'width', 'height', 'rx', 'ry', 'fill', 'stroke', 'stroke-width', 'transform'],
  line: ['x1', 'y1', 'x2', 'y2', 'stroke', 'stroke-width', 'transform'],
  polyline: ['points', 'fill', 'stroke', 'stroke-width', 'transform'], polygon: ['points', 'fill', 'stroke', 'stroke-width', 'transform'],
  circle: ['cx', 'cy', 'r', 'fill', 'stroke', 'stroke-width', 'transform'], ellipse: ['cx', 'cy', 'rx', 'ry', 'fill', 'stroke', 'stroke-width', 'transform'],
  use: ['href', 'xlink:href', 'x', 'y', 'transform'], text: ['x', 'y', 'dx', 'dy', 'fill', 'stroke', 'font-size', 'font-family', 'text-anchor', 'transform', 'data-id-align'], tspan: ['x', 'y', 'dx', 'dy'],
  clipPath: ['clipPathUnits'],
};
const mathAttrs = ['xmlns', 'display', 'mathvariant', 'mathsize', 'mathcolor', 'mathbackground', 'displaystyle', 'scriptlevel', 'stretchy', 'fence', 'separator', 'symmetric', 'largeop', 'movablelimits', 'accent', 'accentunder', 'form', 'lspace', 'rspace', 'minsize', 'maxsize', 'width', 'height', 'depth', 'voffset', 'linethickness', 'numalign', 'denomalign', 'rowalign', 'columnalign', 'groupalign', 'align', 'rowspacing', 'columnspacing', 'rowlines', 'columnlines', 'frame', 'framespacing', 'equalrows', 'equalcolumns', 'columnwidth', 'side', 'minlabelspacing', 'rowspan', 'columnspan', 'notation', 'open', 'close', 'separators', 'encoding', 'href'];
for (const tag of mathTags) specific[tag] = [...mathAttrs, 'data-mjx-texclass', 'data-mjx-variant'];
export const parserOptions = { decodeEntities: true, lowerCaseTags: false, lowerCaseAttributeNames: false, recognizeSelfClosing: true };
export function parseHTML(html) {
  requireThat(Buffer.byteLength(html) <= profile.max_html_bytes, 'html_limit');
  const doc = parseDocument(html, parserOptions); let count = 0;
  walk(doc, (_n, depth) => { requireThat(++count <= profile.max_dom_nodes && depth <= profile.max_dom_depth, 'dom_limit'); });
  return doc;
}
export function walk(node, callback, depth = 0) { callback(node, depth); for (const child of node.children ?? []) walk(child, callback, depth + 1); }
export function elements(root, predicate) { const found = []; walk(root, n => { if (n.type === 'tag' && predicate(n)) found.push(n); }); return found; }
export function serialize(node) {
  if (node.type === 'root') return node.children.map(serialize).join('');
  if (node.type === 'text') return escapeText(node.data);
  requireThat(node.type === 'tag', 'html_node_type');
  const attrs = Object.keys(node.attribs).sort().map(k => ` ${k}="${escapeAttr(node.attribs[k])}"`).join('');
  if (['img', 'br', 'hr'].includes(node.name)) return `<${node.name}${attrs}>`;
  return `<${node.name}${attrs}>${node.children.map(serialize).join('')}</${node.name}>`;
}
function styleIsSafe(style) {
  if (style.length > 1024 || /[\\@()"'<>\u0000-\u001f]/.test(style)) return false;
  const props = new Set(['vertical-align', 'margin', 'margin-left', 'margin-right', 'margin-top', 'margin-bottom', 'padding', 'padding-left', 'padding-right', 'padding-top', 'padding-bottom', 'width', 'height', 'min-width', 'max-width', 'text-align', 'text-decoration', 'cursor', 'display', 'position', 'color', 'background-color', 'font-size', 'font-weight', 'font-style', 'border', 'border-bottom', 'border-top', 'border-left', 'border-right', 'border-collapse']);
  return style.split(';').every(part => {
    if (!part.trim()) return true;
    const match = /^\s*([a-z-]+)\s*:\s*([-#.% a-zA-Z0-9,]+)\s*$/.exec(part);
    return match && props.has(match[1]) && !/url|expression|import|fixed|sticky/i.test(match[2]);
  });
}
function checkDOM(doc, assetPaths, { requireResolved = true } = {}) {
  const ids = new Set(), refs = [];
  walk(doc, node => {
    if (node.type === 'root' || node.type === 'text') return;
    requireThat(node.type === 'tag' && tags.has(node.name), 'html_tag');
    requireThat(node.name !== 'merror' && node.attribs['data-mml-node'] !== 'merror' && !('data-mjx-error' in node.attribs), 'math_error');
    for (const [attr, value] of Object.entries(node.attribs)) {
      requireThat(commonAttrs.includes(attr) || (specific[node.name] ?? []).includes(attr), `html_attribute:${node.name}:${/^[a-zA-Z0-9_-]{1,40}$/.test(attr) ? attr : 'unknown'}`);
      requireThat(typeof value === 'string' && value.length <= (attr === 'd' ? 300000 : 20000) && !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value), 'html_attribute_value');
      if (attr === 'id') { requireThat(idIsSafe(value) && !ids.has(value), 'duplicate_or_invalid_dom_id'); ids.add(value); }
      if (attr === 'style') requireThat(styleIsSafe(value), 'unsafe_style');
      if (attr === 'src') requireThat(node.name === 'img' && pathIsSafe(value) && assetPaths.has(value), 'asset_reference');
      if (attr === 'href' || attr === 'xlink:href') { requireThat(value.startsWith('#') && idIsSafe(value.slice(1)), 'external_reference'); refs.push(value.slice(1)); }
      if (attr === 'aria-labelledby') { const targets = value.split(' '); requireThat(targets.every(idIsSafe), 'aria_reference'); refs.push(...targets); }
      if (attr === 'xmlns') requireThat(value === (node.name === 'svg' ? 'http://www.w3.org/2000/svg' : 'http://www.w3.org/1998/Math/MathML'), 'xml_namespace');
      if (attr === 'xmlns:xlink') requireThat(node.name === 'svg' && value === 'http://www.w3.org/1999/xlink', 'xml_namespace');
      if (attr !== 'style' && attr !== 'aria-label' && attr !== 'alt' && attr !== 'title' && attr !== 'd' && !attr.startsWith('data-') && !['xmlns', 'xmlns:xlink'].includes(attr)) requireThat(!/url\s*\(|javascript:|data:|blob:/i.test(value), 'external_reference');
    }
    if (node.name === 'img') requireThat(node.attribs.alt?.length > 0 && /^\d+$/.test(node.attribs.width ?? '') && /^\d+$/.test(node.attribs.height ?? ''), 'image_metadata');
  });
  if (requireResolved) requireThat(refs.every(id => ids.has(id)), 'unresolved_fragment');
  return ids;
}
// Renaming happens inside each math component before the document pass. A
// cached repeated equation may repeat internal IDs, but never shares a target.
export function namespaceIDs(root, prefix, aliases = new Map()) {
  const mapping = new Map(); let ordinal = 0;
  for (const node of elements(root, n => 'id' in n.attribs)) {
    const old = node.attribs.id; requireThat(old.length <= 1024 && !mapping.has(old), 'duplicate_generated_id');
    const id = `${prefix}-${++ordinal}`; mapping.set(old, id); node.attribs.id = id;
  }
  for (const node of elements(root, () => true)) {
    for (const attr of ['href', 'xlink:href']) {
      const value = node.attribs[attr]; if (value === undefined) continue;
      requireThat(value.startsWith('#'), 'external_reference'); const key = value.slice(1);
      const id = mapping.get(key) ?? aliases.get(key); requireThat(id, 'unresolved_fragment'); node.attribs[attr] = `#${id}`;
    }
    if ('aria-labelledby' in node.attribs) node.attribs['aria-labelledby'] = node.attribs['aria-labelledby'].split(' ').map(id => { const mapped = mapping.get(id) ?? aliases.get(id); requireThat(mapped, 'aria_reference'); return mapped; }).join(' ');
  }
  return mapping;
}
export function sanitizeAndValidate(html, assetPaths) {
  const before = parseHTML(html); checkDOM(before, assetPaths);
  const clean = sanitizeHTML(serialize(before), {
    allowedTags: [...tags], allowedAttributes: { '*': commonAttrs, ...Object.fromEntries([...tags].map(tag => [tag, [...commonAttrs, ...(specific[tag] ?? [])]])) },
    allowedSchemes: [], allowedSchemesAppliedToAttributes: ['href', 'src', 'xlink:href'], allowProtocolRelative: false,
    parser: parserOptions, enforceHtmlBoundary: false, parseStyleAttributes: false, disallowedTagsMode: 'discard',
  });
  const after = parseHTML(clean); checkDOM(after, assetPaths);
  // Validation is rejecting, not lossy: neither anchors nor content can vanish
  // during independent sanitization and still be claimed by the sidecar.
  requireThat(serialize(before) === serialize(after), 'sanitizer_changed_output');
  return after;
}
