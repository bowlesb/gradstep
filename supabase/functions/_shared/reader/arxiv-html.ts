// Official arXiv HTML -> the existing inert reader vocabulary. No network, OCR,
// source scripts/styles, or PDF handling. Acquisition supplies every image.
//
// The converter's components (docs/proposals/READER_ARCHITECTURE_RETHINK.md, step 2) live in ./arxiv/: the shared
// context (context.ts), source preparation (source.ts), front matter and authors (front-matter.ts, authors.ts), the page
// flow (flow.ts), running text (inline.ts), math (math.ts), tables (tables.ts), figures (figures.ts), inline pictures
// (pictures.ts) and the finished page (finish.ts). This module keeps the public API and the order of the passes.
// `scripts/arxiv-converter-equivalence.mjs` proves a restructuring changes no output.
import { elements, serialize } from './html.ts';
import { LIMITS } from './profile.ts';
import { check, sha256Hex, utf8 } from './util.ts';
import type { ReaderIndex } from './render.ts';
import { createContext, nearest, type ArxivConvertOptions, type ResolveImage } from './arxiv/context.ts';
import { article, omitForeignGraphics } from './arxiv/source.ts';
import { svgOnly, svgTextLabels, withSharedDefinitions } from './arxiv/pictures.ts';
import { catalogHeader, catalogTitle, dropRepeatedTitle, frontMatterFirst } from './arxiv/front-matter.ts';
import { flow } from './arxiv/flow.ts';
import { checkMathCoverage, checkNotStub, closingNote, compose, dropEmptyParagraphs, dropMacroParagraphs } from './arxiv/finish.ts';

export { ARXIV_ID, arxivAssetURL, arxivHTMLURL } from './arxiv/urls.ts';
export { CONVERSION_ERROR_LIMIT } from './arxiv/source.ts';
export type { ArxivConvertOptions, HTMLImage, ResolveImage } from './arxiv/context.ts';

export const ARXIV_RENDERER_ID = 'gradstep-arxiv-html-mathml-v2';
export const ARXIV_SOURCE_KIND = 'arxiv-html';
export const ARXIV_PROVENANCE_FORMAT = 'arxiv-html-reader-provenance-v2';
/** Bumped whenever the compiled reader changes for the same source (2026-10-15: author blocks, template title pages;
 * revision 10: the shared validator's device-pdf extension, which arXiv output never uses; revision 11: the converter
 * split into components, output proven identical apart from the ids this revision hashes; revision 12: picture panels
 * under one caption are one figure; revision 13: math styling or attributes outside the allow-list are left out, not
 * refused, 2606.05868 on build 55; revision 14: a figure whose image arXiv's HTML lacks says so in its caption, a
 * placeholder author block gives way to the catalog's names, a picture title's alt is the title; revision 15: an image the
 * device can't prepare says so in its figure instead of refusing the paper, an SVG's unreferenced repeated id is dropped
 * and an over-large SVG is drawn smaller, 2610.19820 and 2610.16784 on build 58), so a device re-prepares papers it
 * compiled with an older app (ReaderModel.openHTMLReader). */
export const ARXIV_RENDERER_REVISION = 15;

/** Only the paper's content assets, never logos, styles or PDF object fallbacks. */
export function arxivHTMLAssets(source: string, sourceURL: string, options: ArxivConvertOptions = {}): string[] {
  // Exactly the images the compiled reader references (a dry compile with placeholder admissions), so acquisition,
  // asset coverage and provenance agree; a graphic the reader leaves out is never fetched. Structural refusals surface
  // here, before any image is downloaded.
  const placeholder = { path: `assets/${'0'.repeat(64)}.png`, width: 1, height: 1 };
  const assets = convertArxivHTML(source, sourceURL, () => placeholder, options).imageURLs.filter(url => !url.startsWith('#'));
  check(assets.length <= LIMITS.archiveImages, 'image_limit');
  return assets;
}

/** Inline vectors are source bytes, never remote asset URLs. The canonical
 * serialization is hashed in provenance before the device SVG admission. */
export function arxivInlineImages(source: string, sourceURL: string, options: ArxivConvertOptions = {}): Map<string, string> {
  // Exactly the pictures the compiled reader references (a dry compile), as for raster assets.
  const placeholder = { path: `assets/${'0'.repeat(64)}.png`, width: 1, height: 1 };
  const wanted = new Set(convertArxivHTML(source, sourceURL, () => placeholder, options).imageURLs.filter(url => url.startsWith('#')).map(url => url.slice(1)));
  const result = new Map<string, string>();
  const root = article(source).root;
  for (const n of elements(root, n => n.name === 'svg')) {
    const id = n.attribs.id;
    if (typeof id !== 'string' || !wanted.has(id)) continue;
    check(/^[A-Za-z_][A-Za-z0-9_.:-]{0,199}$/.test(id) && !nearest(n, 'svg') && !nearest(n, 'math'), 'arxiv_inline_svg');
    check(!n.attribs.xmlns || n.attribs.xmlns === 'http://www.w3.org/2000/svg', 'arxiv_inline_svg');
    const xml = serialize(svgOnly(svgTextLabels(withSharedDefinitions(root, { ...n, attribs: { ...n.attribs, xmlns: 'http://www.w3.org/2000/svg' } }))));
    result.set('#' + id, xml);
  }
  check(result.size === wanted.size, 'arxiv_inline_svg');
  check(result.size <= LIMITS.archiveImages, 'image_limit');
  return result;
}

export function convertArxivHTML(source: string, sourceURL: string, resolveImage: ResolveImage, options: ArxivConvertOptions = {}): {
  index: ReaderIndex; html: string; imageURLs: string[];
} {
  const { root, dropped } = article(source);
  check(/^https:\/\/arxiv\.org\/html\/.+v[1-9][0-9]*$/.test(sourceURL), 'arxiv_identity');
  const digest = sha256Hex(utf8(`${ARXIV_RENDERER_REVISION}\n${source}`)).slice(0, 12);
  const cx = createContext(root, sourceURL, resolveImage, options, digest, dropped);
  cx.omittedGraphics += omitForeignGraphics(root, sourceURL);
  // The page: a catalog title when the HTML has no `h1`, then the paper's own structure.
  catalogTitle(cx);
  cx.top.push(...flow(cx, root));
  // Front matter: title, authors and abstract first; the catalog's authors when the HTML has none, with a custom title
  // page read into them.
  frontMatterFirst(cx);
  catalogHeader(cx);
  // What is no content, then the checks and the ledger.
  dropMacroParagraphs(cx);
  dropEmptyParagraphs(cx);
  dropRepeatedTitle(cx);
  checkNotStub(cx);
  closingNote(cx);
  checkMathCoverage(cx);
  return compose(cx);
}
