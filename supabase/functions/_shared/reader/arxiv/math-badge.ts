// LaTeXML's TikZ text badges in MathML (DocPilot, 2610.21327v1, alg1.m8). The label is mathematical
// content; the coloured rounded rectangles are decoration. Recognise that shape, never flatten arbitrary SVG.
import { elements, textContent, walk, type DomNode } from '../html.ts';
import { check } from '../util.ts';

function roundedRectangle(d: string): boolean {
  // Four axis-aligned sides and four cubic rounded corners; no extra subpath, symbol or plot stroke.
  const parts = [...d.matchAll(/([MLCZ])\s*([^MLCZ]*)/g)];
  if (parts.map(p => p[1]).join('') !== 'MLCLCLCLCZ' || parts.map(p => p[0]).join('').trim() !== d.trim()) return false;
  const points = parts.map(p => p[2].trim() ? p[2].trim().split(/[\s,]+/).map(Number) : []);
  if (points.some((p, i) => p.length !== (parts[i][1] === 'C' ? 6 : parts[i][1] === 'Z' ? 0 : 2)
    || p.some(n => !Number.isFinite(n) || Math.abs(n) > 10_000))) return false;
  const [a,b,c,d1,e,f,g,h,j] = points;
  const [left, low] = a, high = b[1], top = c[5], right = e[4], bottom = g[5];
  const near = (x: number, y: number) => Math.abs(x-y) < .015;
  const between = (x: number, lo: number, hi: number) => x >= lo-.015 && x <= hi+.015;
  return left < c[4] && c[4] <= d1[0] && d1[0] < right && bottom < low && low <= high && high < top
    && near(b[0],left) && near(c[0],left) && between(c[1],high,top) && between(c[2],left,c[4]) && near(c[3],top)
    && near(d1[1],top) && between(e[0],d1[0],right) && near(e[1],top) && near(e[2],right) && between(e[3],high,top) && near(e[5],high)
    && near(f[0],right) && near(f[1],low) && near(g[0],right) && between(g[1],bottom,low) && between(g[2],d1[0],right) && near(g[3],bottom) && near(g[4],d1[0])
    && near(h[0],c[4]) && near(h[1],bottom) && between(j[0],left,c[4]) && near(j[1],bottom) && near(j[2],left) && between(j[3],bottom,low) && near(j[4],left) && near(j[5],low);
}

export function mathBadgeText(svg: DomNode): string {
  walk(svg, n => check(['tag','text','comment'].includes(n.type), 'arxiv_math_element'));
  const nodes = elements(svg, () => true), objects = nodes.filter(n => n.name.toLowerCase() === 'foreignobject');
  const paths = nodes.filter(n => n.name === 'path');
  check(svg.parent?.name === 'mtext' && nodes.length <= 24 && objects.length === 1 && paths.length >= 1 && paths.length <= 2,
    'arxiv_math_element');
  const content = objects[0], spans = elements(content, n => n.name === 'span');
  check(spans.some(n => (n.attribs.class ?? '').split(/\s+/).includes('ltx_foreignobject_content'))
    && elements(content, n => n !== content && n.name !== 'span').length === 0, 'arxiv_math_element');
  check(nodes.every(n => ['svg','g','path','foreignobject','span'].includes(n.name.toLowerCase())
    && Object.keys(n.attribs).every(k => !/^on|href|src/i.test(k)))
    && paths.every(n => roundedRectangle(n.attribs.d ?? '')), 'arxiv_math_element');
  // Text anywhere outside the one label, including other SVG text, is not a decorative badge.
  const outsideText = (n: DomNode): string => n === content ? '' : n.type === 'text' ? n.data : (n.children ?? []).map(outsideText).join('');
  const label = textContent(content).trim();
  check(!outsideText(svg).trim() && label.length > 0 && label.length <= 128 && !/[\r\n\u0000-\u001f]/.test(label), 'arxiv_math_element');
  return label;
}
