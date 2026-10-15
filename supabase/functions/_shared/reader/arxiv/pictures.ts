// Inline pictures (LaTeXML's SVG) as standalone images: the definitions they use from elsewhere on the page, SVG
// elements only, and TikZ labels drawn as SVG text. The device rasterizes the result (device-compiler.ts).
import { elements, normalizeSpace, textContent, type DomNode } from '../html.ts';
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

/** LaTeXML draws TikZ node labels as `foreignObject` HTML, which the device SVG admission refuses. Each label becomes
 * SVG text centred in the label's box (its flip undone), so the diagram keeps its words; placement is best effort. */
export function svgTextLabels(n: DomNode): DomNode {
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
