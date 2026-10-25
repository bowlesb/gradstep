// Where floats read in a model reading (port revision 15). The reading follows the pages, so a float printed at the foot
// of page 1 or the top of page 2 sits between the abstract and the Introduction, as in the arXiv reader before its
// revision 27. The rule is that reader's (../float-placement.ts, docs/JUDGMENT_LOG.md 27); here a float is a figure or
// table block (a figure without its picture reads as its caption) whose caption names it ("Figure 2", "Fig. 2", "Table
// 1"), and a paragraph cites it by naming it: a model reading has no links. A figure no caption names never moves.
import { normalizeSpace, outText, type OutNode } from '../html.ts';
import { placeFloats, type Float } from '../float-placement.ts';

const LABEL = /^\s*(fig(?:ure)?|tab(?:le)?)\.?\s*(\d+)\b/i;
const MENTION = /\b(fig(?:ure)?s?|tab(?:le)?s?)\.?\s*(\d+[a-z]?(?:\s*(?:,|and|&|or|[-–—])\s*\d+[a-z]?)*)/gi;
const kind = (word: string) => /^f/i.test(word) ? 'figure' : 'table';
const text = (node: OutNode | string) => normalizeSpace(outText(node));
const child = (node: OutNode, test: (c: OutNode) => boolean) => node.children.find((c): c is OutNode => typeof c === 'object' && test(c));

/** Moves the floats printed before the first section next to the paragraph that first names them. Returns how many moved. */
export function floatsNearMentions(top: OutNode[]): number {
  const caption = (node: OutNode) => node.name === 'p' && node.attribs.class === 'reader-caption';
  const label = (node: OutNode): string | null => {
    const words = node.name === 'figure' ? child(node, c => c.name === 'figcaption')
      : node.attribs.class === 'reader-table' ? child(node, caption) : caption(node) ? node : undefined;
    const found = words ? LABEL.exec(text(words)) : null;
    return found ? `${kind(found[1])} ${Number(found[2])}` : null;
  };
  const floats: Float[] = [], byLabel = new Map<string, Float[]>();
  top.forEach((node, at) => {
    const name = label(node); if (!name) return;
    const float = { at, nodes: [node] }; floats.push(float); byLabel.set(name, [...(byLabel.get(name) ?? []), float]);
  });
  if (!floats.length) return 0;
  // Prose: the paper's paragraphs (the abstract's too: a float it names is near enough), not captions or tables.
  const prose = (node: OutNode) => node.name === 'p' && node.attribs['data-reader-kind'] === 'paragraph'
    && (!node.attribs.class || node.attribs.class === 'reader-abstract');
  const cited = new Map<Float, number>();
  top.forEach((node, at) => {
    if (!prose(node)) return;
    for (const mention of text(node).matchAll(MENTION)) for (const number of mention[2].match(/\d+/g) ?? [])
      for (const float of byLabel.get(`${kind(mention[1])} ${Number(number)}`) ?? []) if (!cited.has(float)) cited.set(float, at);
  });
  // A float lands after the citing paragraph, its displays and the words that continue its sentence: after a display, a
  // paragraph opening in lower case ("where x is…"); after a paragraph a column or page break cut mid-sentence, the rest.
  const equation = (node: OutNode) => node.attribs['data-reader-kind'] === 'equation';
  const continues = (node: OutNode, next: OutNode) => prose(next)
    && (equation(node) ? /^[a-z]/.test(text(next)) : prose(node) && !/[.!?:]["'”’)\]]*$/.test(text(node)));
  const paragraphEnd = (at: number) => {
    let end = at;
    while (end + 1 < top.length && (equation(top[end + 1]) || continues(top[end], top[end + 1]))) end += 1;
    return end;
  };
  return placeFloats(top, floats, cited, paragraphEnd);
}
