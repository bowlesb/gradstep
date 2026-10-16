// The article as the converter reads it: the one `article.ltx_document`, unique ids, LaTeXML's conversion-error markers
// emptied and counted, unnamed pictures named, and graphics that are not the paper's own assets left out.
import { elements, normalizeSpace, parseHTML, textContent, walk, type DomNode } from '../html.ts';
import { ARXIV_SOURCE_BYTES } from '../profile.ts';
import { check, utf8 } from '../util.ts';
import { has, nearest } from './context.ts';
import { arxivAssetURL } from './urls.ts';

/** LaTeXML marks what it could not convert (an undefined macro such as `\\pdfauthor`) with `ltx_ERROR`; these are
 * dropped and counted, and the paper still reads (2026-10-14: a paper with 288 such preamble macros was refused
 * outright). Beyond this many the conversion is not trusted at all. */
export const CONVERSION_ERROR_LIMIT = 1000;
export function article(source: string): { root: DomNode; dropped: number } {
  check(utf8(source).length <= ARXIV_SOURCE_BYTES && source.length > 0, 'source_limit');
  const root = parseHTML(source);
  const papers = elements(root, n => n.name === 'article' && has(n, 'ltx_document'));
  check(papers.length === 1, 'arxiv_article');
  const ids = new Set<string>(), errors: DomNode[] = [];
  walk(papers[0], n => {
    if (n.attribs?.id) { check(!ids.has(n.attribs.id), 'arxiv_duplicate_id'); ids.add(n.attribs.id); }
    if (has(n, 'ltx_ERROR') || has(n, 'ltx_error')) errors.push(n);
  });
  check(errors.length <= CONVERSION_ERROR_LIMIT, 'arxiv_conversion_error');
  // Each marker stays as an empty span that names its macro (`data-reader-macro`); the reader never prints it, and a
  // title page a template left in pieces can be read by macro (front-matter.ts `templatePreamble`).
  for (const n of errors) { n.attribs = { ...(n.attribs ?? {}), 'data-reader-macro': normalizeSpace(textContent(n)).slice(0, 64) }; n.children = []; }
  // A picture LaTeXML left without an id (2610.20584: 56 such pictures, refused `arxiv_inline_svg`) gets one, in
  // document order, so the compile and the picture serialization name it alike.
  let unnamed = 0;
  for (const svg of elements(papers[0], c => c.name === 'svg' && !nearest(c, 'svg') && typeof c.attribs?.id !== 'string')) {
    unnamed += 1; svg.attribs = { ...(svg.attribs ?? {}), id: `srpic${unnamed}` };
  }
  return { root: papers[0], dropped: errors.length };
}

/** A graphic that is not one of the paper's own assets (arXiv's page chrome inside the article, an empty `src`:
 * 2610.20570, refused `arxiv_asset_url` on the fresh-paper sweep) is left out; returns how many, for the closing note.
 * An image arXiv's own conversion lost (LaTeXML's `ltx_missing_image`, an empty `src`: 16 of CyberArena's 17 figures,
 * 2610.19005) is not counted there: its figure is marked (`data-reader-missing`) so its caption says the PDF has it. */
export function omitForeignGraphics(root: DomNode, sourceURL: string): number {
  let omitted = 0;
  for (const graphic of elements(root, c => c.name === 'img' || c.name === 'object')) {
    const reference = graphic.attribs?.[graphic.name === 'img' ? 'src' : 'data'] ?? '';
    let own = false; try { arxivAssetURL(reference, sourceURL); own = true; } catch { own = false; }
    if (own || !graphic.parent) continue;
    graphic.parent.children = graphic.parent.children.filter(c => c !== graphic);
    const figure = has(graphic, 'ltx_missing_image') ? nearest(graphic, 'figure') : null;
    if (figure) figure.attribs = { ...(figure.attribs ?? {}), 'data-reader-missing': '1' }; else omitted += 1;
  }
  return omitted;
}
