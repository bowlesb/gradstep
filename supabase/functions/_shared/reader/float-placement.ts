// Where floats read, for both readers (arXiv reader revision 27, device port revision 15). A float printed or written
// before the first section (a teaser, or `figure*` floats the PDF sets at the foot of page 1 and the top of page 2) sits
// between the abstract and the Introduction: on paper the reader sees it beside the text that cites it, on a phone it is
// screens before that text (owner, TestFlight 92, WorldCast 2610.20731v2: "Is the Figure displayed in the right place";
// its Figure 1, cited in the Introduction's second paragraph, and Figure 2 read before "1 Introduction").
//
// The rule (docs/JUDGMENT_LOG.md 43): a float between the title and the first section that the first section cites moves
// to just after the paragraph that first cites it. Floats keep their order: once one moves, every later float before the
// first section moves too, to its own first citation in the body, or else right after the float before it. A float never
// passes a float of the body, nor reaches the references. A float the first section doesn't cite, ahead of any that
// moves, stays under the abstract (a teaser, or one cited only later or never), and floats in the body stay where the
// author put them. What a float is and what cites it is each reader's own (arxiv/floats.ts: LaTeXML's floats and in-page
// links; device-pdf/emit.ts: figure and table blocks and "Figure 2" in the text). Ids are issued before this, in source
// order, so a figure keeps its id and anchors.
import { normalizeSpace, outText, type OutNode } from './html.ts';

/** One float: the consecutive page nodes it is, from `at`; a `fixed` one never moves, nor does any float before it. */
export type Float = { at: number; nodes: OutNode[]; fixed?: boolean };

const heading = (node: OutNode) => /^h[2-6]$/.test(node.name);
const fold = (text: string) => text.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();

/** The page's landmarks: the title, the first section and where it ends, and where the references begin. */
export function pageSections(top: readonly OutNode[]): { titleAt: number; firstAt: number; firstEnd: number; backAt: number } | null {
  const titleAt = top.findIndex(node => node.name === 'h1');
  // The references and anything after them (an appendix) are never a destination.
  const listAt = top.findIndex(node => ['ul', 'ol'].includes(node.name) && node.attribs.class === 'reader-references');
  const backAt = listAt < 0 ? top.length : listAt > 0 && heading(top[listAt - 1]) ? listAt - 1 : listAt;
  const firstAt = top.findIndex((node, i) => i > titleAt && heading(node)
    && !['', 'abstract', 'contents', 'table of contents'].includes(fold(normalizeSpace(outText(node)))));
  if (titleAt < 0 || firstAt < 0 || firstAt >= backAt) return null;
  // The first section runs to the next heading of its level or above (its subsections are in it).
  const level = Number(top[firstAt].name[1]);
  let firstEnd = top.findIndex((node, i) => i > firstAt && heading(node) && Number(node.name[1]) <= level);
  if (firstEnd < 0 || firstEnd > backAt) firstEnd = backAt;
  return { titleAt, firstAt, firstEnd, backAt };
}

/** Moves the floats before the first section (`floats`: every float of the page, in page order) next to the paragraph that
 * first cites them (`cited`: the page index of each float's first citing paragraph; `paragraphEnd`: the last page node of
 * the paragraph at an index). Returns how many floats moved; `top` is rearranged in place. */
export function placeFloats(top: OutNode[], floats: readonly Float[], cited: ReadonlyMap<Float, number>, paragraphEnd: (at: number) => number): number {
  const sections = pageSections(top);
  if (!sections) return 0;
  const { titleAt, firstAt, firstEnd, backAt } = sections;
  const inFront = (float: Float) => float.at > titleAt && float.at < firstAt;
  const lastFixed = floats.reduce((last, float, i) => float.fixed && inFront(float) ? i : last, -1);
  const front = floats.filter((float, i) => i > lastFixed && !float.fixed && inFront(float));
  if (!front.length) return 0;
  const bound = (floats.find(float => float.at > firstAt)?.at ?? backAt) - 1;
  const after = new Map<number, OutNode[]>();
  let previous = -1, moved = 0;
  for (const float of front) {
    const at = cited.get(float);
    const inBody = at !== undefined && at > firstAt && at < backAt;
    if (previous < 0 && !(inBody && at < firstEnd)) continue;
    const place = Math.min(Math.max(inBody ? Math.min(paragraphEnd(at), backAt - 1) : previous, previous), bound);
    after.set(place, [...(after.get(place) ?? []), ...float.nodes]);
    previous = place; moved += 1;
  }
  if (!moved) return 0;
  const leaving = new Set([...after.values()].flat());
  const page = top.flatMap((node, i) => [...(leaving.has(node) ? [] : [node]), ...(after.get(i) ?? [])]);
  top.splice(0, top.length, ...page);
  return moved;
}
