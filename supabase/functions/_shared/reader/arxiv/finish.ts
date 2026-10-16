// The finished page (arXiv converter component): paragraphs that are no paragraphs left out, the stub check, the
// closing note that says what the HTML omitted, math coverage, in-page links resolved, and the index and HTML.
import { el, elements, HTML_SUFFIX, htmlPrefix, normalizeSpace, outText, render } from '../html.ts';
import { INDEX_FORMAT, LIMITS } from '../profile.ts';
import { boundedText, check, excerpt, utf8 } from '../util.ts';
import type { ReaderIndex } from '../render.ts';
import { nextID, remove, type ArxivContext, type Child } from './context.ts';

/** A macro definition LaTeXML left as text ("[1]for each #1 do", 2610.18683: TeX parameter tokens never read in prose)
 * is no paragraph; it counts as an unsupported command in the closing note. */
export function dropMacroParagraphs(cx: ArxivContext): void {
  for (const entry of cx.blocks.filter(b => b.kind === 'paragraph' && cx.top.includes(b.node) && /#\d/.test(outText(b.node)))) { remove(cx, entry); cx.dropped += 1; }
}

/** A paragraph with nothing in it (a horizontal rule, an empty LaTeXML paragraph) is no block, unless a link points at it. */
export function dropEmptyParagraphs(cx: ArxivContext): void {
  const substance = (node: Child): boolean => typeof node === 'string' ? node.trim().length > 0
    : node.name === 'img' || node.name === 'a' || node.attribs['data-reader-equation'] !== undefined || node.children.some(substance);
  const targeted = new Set(cx.links.map(link => cx.aliases.get(link.target)));
  for (const entry of cx.blocks.filter(b => b.kind === 'paragraph' && cx.top.includes(b.node) && !targeted.has(b.id) && !substance(b.node))) remove(cx, entry);
}

/** A page that is only a pointer to the PDF (Adam v9: "See pages 1-last of … .pdf") is no paper, however the catalog heads it. */
export function checkNotStub(cx: ArxivContext): void {
  const own = cx.blocks.filter(b => !cx.synthetic.has(b.node));
  check(own.length >= 3 || own.some(b => b.kind !== 'heading' && normalizeSpace(outText(b.node)).length > 200), 'arxiv_article');
}

/** What the HTML left out, said in the paper itself as its last paragraph, so a reader knows (the ledger). */
export function closingNote(cx: ArxivContext): void {
  const { dropped, omittedGraphics, unresolvedCitations } = cx;
  if (dropped > 0 || omittedGraphics > 0 || unresolvedCitations > 0) {
    const parts = [dropped > 0 ? `${dropped} unsupported ${dropped === 1 ? 'command' : 'commands'}` : '',
      omittedGraphics > 0 ? `${omittedGraphics} inline ${omittedGraphics === 1 ? 'graphic' : 'graphics'}` : '',
      unresolvedCitations > 0 ? `${unresolvedCitations} unresolved ${unresolvedCitations === 1 ? 'citation' : 'citations'}` : ''].filter(Boolean);
    const id = nextID(cx);
    const note = el('p', { id, 'data-reader-block': id, 'data-reader-kind': 'paragraph' },
      [`Note: arXiv’s HTML conversion of this version left out ${parts.join(' and ')}. The PDF is complete.`]);
    cx.blocks.push({ id, kind: 'paragraph', node: note }); cx.top.push(note);
  }
}

/** Every `math` element is rendered or deliberately left out with what carried it; anything else refuses the paper
 * (`onUncoveredMath` lets the sweep say where it sat). */
export function checkMathCoverage(cx: ArxivContext): void {
  const covered = new Set([...cx.usedMath, ...cx.skippedMath]);
  const uncovered = elements(cx.root, n => n.name === 'math').filter(m => !covered.has(m));
  if (uncovered.length && cx.options.onUncoveredMath) cx.options.onUncoveredMath(uncovered);
  check(uncovered.length === 0, 'arxiv_math_coverage');
}

/** Figures marked, in-page links pointed at the blocks that hold their targets, one title, the index and the page. */
export function compose(cx: ArxivContext): { index: ReaderIndex; html: string; imageURLs: string[] } {
  // A heading with no words (LaTeXML's run-in `\paragraph{}` with an empty title: eight in 2207.00729, refused
  // `index_heading` because the page's navigable headings and the index disagreed) is no heading: links to it go to
  // the block after it.
  for (const entry of cx.blocks.filter(b => b.kind === 'heading' && b.node.name !== 'h1' && !normalizeSpace(outText(b.node)))) {
    const next = cx.blocks[cx.blocks.indexOf(entry) + 1];
    for (const [source, target] of cx.aliases) if (target === entry.id) { if (next) cx.aliases.set(source, next.id); else cx.aliases.delete(source); }
    remove(cx, entry);
  }
  for (const entry of cx.blocks) if (entry.kind === 'figure') entry.node.attribs['data-reader-figure'] = entry.id;
  for (const link of cx.links) {
    const id = cx.aliases.get(link.target); check(id, 'arxiv_unresolved_fragment'); link.node.attribs.href = `#${id}`;
  }
  const titles = cx.blocks.filter(b => b.node.name === 'h1');
  check(titles.length === 1, 'arxiv_title');
  // A title set as a picture (2610.18615's word-mark, in the owner's library on build 55) has no words of its own (a
  // heading keeps no graphics): the catalog's title is the heading's text and names the paper, never a refusal. The
  // validator requires the index title to be the heading's own text (revision 13 named only the index: `index_title`).
  const own = normalizeSpace(outText(titles[0].node));
  const title = boundedText(own || normalizeSpace(cx.metadataTitle ?? '') || 'Untitled paper', LIMITS.headingBytes, 'arxiv_title');
  check(title.length > 0, 'arxiv_title');
  if (!own) titles[0].node.children = [title];
  const headings = cx.blocks.filter(b => b.kind === 'heading' && b !== titles[0]).map(b => ({ id: b.id,
    level: Number(b.node.name.slice(1)), title: boundedText(normalizeSpace(outText(b.node)), LIMITS.headingBytes, 'heading_limit') }));
  check(headings.length <= LIMITS.headings, 'heading_limit');
  const index: ReaderIndex = { format: INDEX_FORMAT, title, headings, equations: cx.equations, figures: cx.figures,
    // A block longer than the index allows (a bibliography entry listing hundreds of authors) is excerpted, as the
    // validator compares (audit 2026-10-15); control characters still refuse.
    blocks: cx.blocks.map(b => ({ id: b.id, kind: b.kind, text: boundedText(excerpt(normalizeSpace(outText(b.node)), LIMITS.textBytes), LIMITS.textBytes, 'arxiv_block_text') })) };
  const html = htmlPrefix(title) + cx.top.map(render).join('') + HTML_SUFFIX;
  check(utf8(html).length <= LIMITS.htmlBytes && cx.imageURLs.size <= LIMITS.archiveImages, 'html_limit');
  return { index, html, imageURLs: [...cx.imageURLs].sort() };
}
