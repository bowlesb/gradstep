// Where floats read (arXiv converter component, revision 27): LaTeXML keeps a float where the source wrote it, so one
// written before the first section sits between the abstract and the Introduction. The rule and its reasons are in
// ../float-placement.ts (docs/JUDGMENT_LOG.md 27); this component says what a float is in LaTeXML's page and what cites it.
import type { OutNode } from '../html.ts';
import { placeFloats, type Float } from '../float-placement.ts';
import { reorder, type ArxivContext, type Child } from './context.ts';
import { UNSHOWN_FIGURE_NOTE } from './figures.ts';
import { MISSING_FIGURE_NOTE } from './flow.ts';

const caption = (node: OutNode) => node.name === 'p' && node.attribs.class === 'reader-caption';
/** A caption paragraph that is a whole figure: its picture missing from arXiv's HTML, or not shown on this device. */
const opensWith = (node: OutNode, note: string) => { const first = node.children[0]; return typeof first === 'object' && first.name === 'em' && first.children[0] === note; };

/** Moves the floats written before the first section next to the paragraph that first cites them. Returns how many moved. */
export function floatsNearCitations(cx: ArxivContext): number {
  const top = cx.top;
  // A float: the consecutive page nodes one source float (`figure` element) became. A float of captions alone (LaTeXML's
  // \captionof after an unwrapped \includegraphics, 2610.17288) takes the uncaptioned picture right above it, as the page
  // shows them; whether this device could show that picture (a figure, or a caption opened by the unshown note) changes
  // nothing. One whose picture became something else (2610.07591's Figure 1, a diagram read as its labels) can't move
  // without it, so it is fixed.
  const floats: Float[] = [];
  top.forEach((node, i) => {
    const source = cx.floatOf.get(node); if (!source) return;
    const last = floats[floats.length - 1];
    if (last && last.at + last.nodes.length === i && cx.floatOf.get(last.nodes[last.nodes.length - 1]) === source) last.nodes.push(node);
    else floats.push({ at: i, nodes: [node] });
  });
  for (const float of floats) {
    if (!float.nodes.every(node => caption(node) && !opensWith(node, UNSHOWN_FIGURE_NOTE) && !opensWith(node, MISSING_FIGURE_NOTE))) continue;
    const above = top[float.at - 1];
    const picture = float.at > 0 && !cx.floatOf.has(above) && (above.name === 'figure' || (caption(above) && opensWith(above, UNSHOWN_FIGURE_NOTE)));
    if (picture) { float.nodes.unshift(above); float.at -= 1; } else float.fixed = true;
  }
  const floatOfID = new Map<string, Float>();
  for (const float of floats) for (const node of float.nodes) {
    const visit = (child: Child) => { if (typeof child === 'string') return; if (child.attribs['data-reader-block']) floatOfID.set(child.attribs['data-reader-block'], float); child.children.forEach(visit); };
    visit(node);
  }
  // Citations: in-page links from the paper's prose (a paragraph or a list, not a caption or a table).
  const prose = (node: OutNode) => !cx.floatOf.has(node) && ((node.name === 'p' && !node.attribs.class && node.attribs['data-reader-kind'] === 'paragraph')
    || (['ul', 'ol'].includes(node.name) && !node.attribs.class));
  const linkAt = new Map<OutNode, number>();
  top.forEach((node, i) => {
    if (!prose(node)) return;
    const visit = (child: Child) => { if (typeof child === 'string') return; if (child.name === 'a') linkAt.set(child, i); child.children.forEach(visit); };
    visit(node);
  });
  const cited = new Map<Float, number>();
  for (const link of cx.links) {
    const at = linkAt.get(link.node), id = cx.aliases.get(link.target), float = id ? floatOfID.get(id) : undefined;
    if (at !== undefined && float && at < (cited.get(float) ?? Infinity)) cited.set(float, at);
  }
  // A float lands after the whole LaTeX paragraph that cites it (its sentence's displays and the words after them).
  const paragraphEnd = (at: number) => {
    const paragraph = cx.paragraphOf.get(top[at]);
    let end = at; if (paragraph) while (end + 1 < top.length && cx.paragraphOf.get(top[end + 1]) === paragraph) end += 1;
    return end;
  };
  const moved = placeFloats(top, floats, cited, paragraphEnd);
  if (moved) reorder(cx);
  return moved;
}
