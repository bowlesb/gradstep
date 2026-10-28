// Figures (arXiv converter component): figure blocks with their images, legends and captions.
import { el, elements, normalizeSpace, outText, textContent, walk, type DomNode, type OutNode } from '../html.ts';
import { LIMITS } from '../profile.ts';
import { boundedText, check, excerpt } from '../util.ts';
import { active, bind, block, children, has, loneImage, type ArxivContext, type Child } from './context.ts';
import { inline } from './inline.ts';
import { arxivAssetURL } from './urls.ts';

/** Opens the caption of a figure none of whose images this device could prepare (revision 15: ActionOPD 2610.19820's
 * teaser, refused `svg_id`; InfoVis 2610.16784, refused `image_dimensions`, build 58). The paper still opens. */
export const UNSHOWN_FIGURE_NOTE = 'This figure couldn’t be shown here; the PDF has it.';
/** In place of one panel of a figure that this device couldn't prepare (the figure's other images stay). */
export const UNSHOWN_PART_NOTE = 'Part of this figure couldn’t be shown here; the PDF has it.';
const unshownNotes = new WeakSet<OutNode>();
const unshownNote = (): OutNode => { const note = el('p', {}, [el('em', {}, [UNSHOWN_PART_NOTE])]); unshownNotes.add(note); return note; };
const isUnshownNote = (part: Child | undefined) => typeof part === 'object' && unshownNotes.has(part);

/** One of a figure's images: an asset (or an inline picture by id) admitted by the host, at most `imagesPerFigure`. */
export function figureImage(cx: ArxivContext, n: DomNode, owner: string, inlineImage = false): Child {
  bind(cx, n, owner);
  // A grid past the figure's image limit (112 thumbnails in a tabular, 2610.20584): the first ones stay, the rest
  // are left out and counted, never a refusal. An image the device couldn't prepare still takes its place, so the
  // same images are planned, fetched and placed whichever of them a device can show.
  if ((cx.figureImages.get(owner)?.length ?? 0) + (cx.unshownImages.get(owner) ?? 0) >= LIMITS.imagesPerFigure) { cx.omittedGraphics += 1; for (const m of elements(n, c => c.name === 'math')) cx.skippedMath.add(m); return ''; }
  // Math drawn inside an inline SVG picture (a TikZ node's foreignObject) travels with the picture, not as an equation.
  if (n.name === 'svg') for (const m of elements(n, c => c.name === 'math')) cx.skippedMath.add(m);
  check(n.name !== 'object' || n.attribs.type === 'image/svg+xml', 'arxiv_asset_type');
  const url = n.name === 'svg' ? '#' + n.attribs.id : arxivAssetURL(n.attribs[n.name === 'img' ? 'src' : 'data'] ?? '', cx.sourceURL);
  cx.imageURLs.add(url);
  const asset = cx.resolveImage(url);
  // An image this device couldn't prepare: a note takes its place (a legend symbol is left out of its line and the
  // figure says so once, imageFigure); a figure left with no image reads as its caption.
  if (!asset) { cx.unshownImages.set(owner, (cx.unshownImages.get(owner) ?? 0) + 1); return inlineImage ? '' : unshownNote(); }
  check(/^assets\/[a-f0-9]{64}\.(png|jpg)$/.test(asset.path) && Number.isSafeInteger(asset.width) && Number.isSafeInteger(asset.height)
    && asset.width > 0 && asset.height > 0 && asset.width <= LIMITS.imageDimension && asset.height <= LIMITS.imageDimension, 'arxiv_asset');
  const output = el('img', {src:asset.path,alt:'Figure',width:String(asset.width),height:String(asset.height),
    ...(inlineImage ? {class:'reader-inline-image'} : {})});
  cx.figureImages.get(owner)!.push(output); return output;
}
/** A figure block: its images, legend text and sub-captions in order, its own caption, and its index entry. */
export function imageFigure(cx: ArxivContext, n: DomNode): OutNode {
  const images = elements(n, c => ['img','object','svg'].includes(c.name));
  check(images.length >= 1 && cx.figures.length < LIMITS.figures, 'arxiv_figure');
  // Several captions (sub-captions inside spans, 2610.20608): the figure's own is a direct child or the last one;
  // the others read as paragraphs inside the figure.
  const captions = elements(n, c => c.name === 'figcaption');
  const mainCaption = children(n).find(c => c.name === 'figcaption') ?? captions[captions.length - 1];
  const figure = block(cx, n, 'figure', 'figure', id => {
    const imageNodes: OutNode[] = []; cx.figureImages.set(id, imageNodes);
    let caption: OutNode | null = null;
    // Preserve legend text and inline symbols instead of collecting images
    // and accidentally discarding the other children of a figure.
    const parts: Child[] = [];
    const visit = (child: DomNode) => {
      if (child.type === 'comment' || active.has(child.name)) return;
      bind(cx, child, id);
      if (child.name === 'figcaption') {
        if (child === mainCaption) { caption = el('figcaption', {}, children(child).flatMap(c => inline(cx, c, id))); parts.push(caption); }
        else parts.push(el('p', {}, children(child).flatMap(c => inline(cx, c, id))));
      } else if (child.name === 'img' || child.name === 'object') parts.push(figureImage(cx, child,id));
      // A picture beside words is a legend symbol, inline; a picture on its own (a table drawn as TikZ, 2610.18683's
      // Table 11, shown 0.65 em tall on build 43) is the figure's image.
      else if (child.name === 'svg') {
        const wrapper = child.parent && child.parent !== n ? child.parent : null;
        const words = wrapper ? normalizeSpace(children(wrapper).filter(c => c !== child).map(textContent).join(' ')).length > 0 : false;
        if (words) parts.push(...inline(cx, child, id)); else parts.push(figureImage(cx, child, id));
      }
      // A paragraph that only wraps the graphic (LaTeXML centres with p > span > img) is the figure's image, full
      // size; a paragraph with words keeps its graphics inline as legend symbols (build 31 drew 2610.17288's
      // teaser 0.65 em tall: "the figure is tiny").
      else if (child.name === 'p' && loneImage(child)) parts.push(figureImage(cx, elements(child, c => ['img','object','svg'].includes(c.name))[0], id));
      else if (child.name === 'p') parts.push(el('p', {}, children(child).flatMap(c => inline(cx, c,id))));
      // A panel (a nested figure) reads in place: its pictures, then its own caption as a paragraph.
      else if (['div','span','figure','table','thead','tbody','tfoot','tr','td','th'].includes(child.name)) children(child).forEach(visit);
      else parts.push(...inline(cx, child,id));
    };
    if (['img','object','svg'].includes(n.name)) parts.push(figureImage(cx, n,id));
    else children(n).forEach(visit);
    const output: Child[] = []; let run: Child[] = [];
    const flush = () => {
      if (run.some(c => typeof c !== 'string' || c.trim())) output.push(el('p', {}, run));
      run = [];
    };
    for (const part of parts) {
      if (typeof part !== 'string' && (['p','figcaption'].includes(part.name) || (part.name === 'img' && !part.attribs.class))) {
        // Panels side by side that the device couldn't prepare say so once.
        flush(); if (!(isUnshownNote(part) && isUnshownNote(output[output.length - 1]))) output.push(part);
      } else run.push(part);
    }
    flush();
    // A legend symbol the device couldn't prepare: the figure says so once, before its caption.
    if ((cx.unshownImages.get(id) ?? 0) > 0 && !output.some(isUnshownNote)) {
      const at = output.findIndex(part => typeof part === 'object' && part.name === 'figcaption');
      output.splice(at < 0 ? output.length : at, 0, unshownNote());
    }
    const captionText = caption ? excerpt(normalizeSpace(outText(caption)), LIMITS.textBytes) : '';
    const alt = boundedText(captionText || images.map(i => i.attribs.alt ?? '').filter(Boolean).join(' ') || 'Figure', LIMITS.textBytes, 'arxiv_alt');
    for (const image of imageNodes) image.attribs.alt = alt;
    const paths = imageNodes.map(image => image.attribs.src);
    cx.figures.push({ id, block_id: id, asset_paths: [...new Set(paths)], caption: captionText, alt });
    return output;
  }, {});
  const id = figure.attribs.id;
  return cx.figureImages.get(id)!.length === 0 && (cx.unshownImages.get(id) ?? 0) > 0 ? unshownFigure(cx, figure) : figure;
}

const isGraphic = (c: DomNode) => c.type === 'tag' && ['img', 'object', 'svg'].includes(c.name);
/** A node's words, without what its graphics draw (a picture's labels); math counts as words. */
const wordsOf = (c: DomNode): string => c.type === 'text' ? c.data : c.type !== 'tag' || isGraphic(c) ? '' : children(c).map(wordsOf).join('');
/** The graphics in a node that no other graphic or math holds. */
const ownGraphics = (root: DomNode) => elements(root, c => {
  if (!isGraphic(c)) return false;
  for (let a = c.parent; a && a !== root; a = a.parent) if (isGraphic(a) || a.name === 'math') return false;
  return true;
});
const oneCaption = (n: DomNode) => children(n).filter(c => c.name === 'figcaption').length === 1;

/** Pictures LaTeXML set apart from their sub-captions (2610.20608v1's Figures 2 and 8: the source draws three plots in
 * one row and captions them in the next, so the figure holds a paragraph of pictures, then sub-figures holding only "(a)
 * …", "(b) …", "(c) …"). The flow read that paragraph as text, where a graphic is left out and counted, and the figure as
 * its captions: no picture showed. Returns the figure as panels (imageFigure reads each in place): the i-th picture in
 * the i-th caption's panel, before the caption when the pictures come first, after it when the captions do; pictures and
 * captions that don't pair one to one stay in page order. Null for any other figure, which reads as before. */
export function panelsApart(n: DomNode): DomNode | null {
  if (!oneCaption(n)) return null;
  // The figure's pictures, panels and caption in page order, through the wordless layout around them.
  const items: DomNode[] = [];
  let other = false;
  const collect = (c: DomNode) => {
    if (c.type === 'text') { if (c.data.trim()) other = true; return; }
    if (c.type !== 'tag' || active.has(c.name) || c.name === 'br') return;
    if (c.name === 'figure' || c.name === 'figcaption' || isGraphic(c)) { items.push(c); return; }
    // A table, math, a list or any other content: not this layout.
    if (!['div', 'p', 'span', 'a'].includes(c.name)) { other = true; return; }
    children(c).forEach(collect);
  };
  children(n).forEach(collect);
  const pictures = items.filter(isGraphic), panels = items.filter(c => c.name === 'figure');
  const captionOnly = (panel: DomNode) => children(panel).some(c => c.name === 'figcaption')
    && children(panel).every(c => c.type === 'comment' || (c.type === 'text' ? !c.data.trim() : c.name === 'figcaption'));
  // A drawing right under the figure would read as a legend symbol beside its words (imageFigure): not this layout.
  if (other || !pictures.length || !panels.length || !panels.every(captionOnly) || pictures.some(p => p.name === 'svg' && p.parent === n)) return null;
  if (pictures.length !== panels.length) return { ...n, children: items };
  const picturesFirst = items.indexOf(pictures[0]) < items.indexOf(panels[0]);
  return { ...n, children: items.filter(c => !isGraphic(c)).map(c => {
    const at = panels.indexOf(c);
    return at < 0 ? c : { ...c, children: picturesFirst ? [pictures[at], ...children(c)] : [...children(c), pictures[at]] };
  }) };
}

/** Panels in a tabular with their labels in the next row (Batch Normalization's Figure 1, 1502.03167v3: three plots,
 * then "(a)", "(b) Without BN", "(c) With BN"; 2610.09823v1's galleries: rows of four pictures, each with a row of names
 * under it). The labels made the tabular a table of words, where a graphic is left out: the figure read as a table of
 * labels. Returns the figure as panels, each picture with its label (under it, or over it when the labels' row comes
 * first). Only a figure whose one tabular holds rows of single pictures and rows of words, each words row beside a row of
 * as many pictures; a grid with row or column headings (a comparison of methods) stays a table. */
export function labelledPanels(n: DomNode): DomNode | null {
  if (has(n, 'ltx_table') || !oneCaption(n)) return null;
  const tables = elements(n, c => c.name === 'table');
  if (tables.length !== 1 || elements(n, c => c !== n && c.name === 'figure').length) return null;
  const grid = tables[0];
  // Nothing but the tabular and the caption: no words, math or graphics around them.
  const outside = (c: DomNode): boolean => c === grid || c.name === 'figcaption' ? false
    : c.type === 'text' ? c.data.trim().length > 0 : c.type === 'tag' && (isGraphic(c) || c.name === 'math' || children(c).some(outside));
  if (children(n).some(outside)) return null;
  type Row = { pictures: DomNode[] } | { labels: DomNode[] };
  const rows: (Row | null)[] = elements(grid, c => c.name === 'tr').map(row => {
    const cells = children(row).filter(c => c.name === 'td' || c.name === 'th');
    if (!cells.length || cells.some(c => (c.attribs.colspan ?? '1') !== '1' || (c.attribs.rowspan ?? '1') !== '1')) return null;
    const pictures = cells.map(ownGraphics), said = cells.map(c => normalizeSpace(wordsOf(c)).length > 0);
    if (pictures.every((p, i) => p.length === 1 && !said[i])) return { pictures: pictures.map(p => p[0]) };
    if (pictures.every((p, i) => p.length === 0 && said[i])) return { labels: cells };
    return null;
  });
  if (rows.some(r => !r) || !rows.some(r => r && 'labels' in r)) return null;
  // A panel: the picture and its label as a caption (the cell's own content), in the order the page sets them.
  const panel = (picture: DomNode, cell: DomNode, labelFirst: boolean): DomNode => {
    const caption: DomNode = { ...cell, name: 'figcaption', attribs: {} };
    return { type: 'tag', name: 'figure', data: '', attribs: {}, parent: n, children: labelFirst ? [caption, picture] : [picture, caption] };
  };
  const panels: DomNode[] = [];
  for (let i = 0; i < rows.length;) {
    const row = rows[i]!, next = rows[i + 1];
    if ('pictures' in row && next && 'labels' in next && next.labels.length === row.pictures.length) {
      row.pictures.forEach((p, j) => panels.push(panel(p, next.labels[j], false))); i += 2;
    } else if ('labels' in row && next && 'pictures' in next && next.pictures.length === row.labels.length) {
      next.pictures.forEach((p, j) => panels.push(panel(p, row.labels[j], true))); i += 2;
    } else if ('pictures' in row) { panels.push(...row.pictures); i += 1; }
    else return null;
  }
  // The caption keeps its place (over or under the panels).
  return { ...n, children: children(n).flatMap(c => c.name === 'figcaption' ? [c] : elements(c, x => x === grid).length ? panels : []) };
}

/** A figure read through `panelsApart` or `labelledPanels`: one figure block, and every source id in it (the row of
 * pictures, a table cell) resolves to it, so a link to any part of the figure opens it. */
export function panelFigure(cx: ArxivContext, n: DomNode, panels: DomNode): OutNode {
  const figure = imageFigure(cx, panels);
  const id = figure.attribs.id;
  walk(n, c => { if (c.name !== 'math' && c.attribs?.id && !cx.aliases.has(c.attribs.id)) bind(cx, c, id); });
  return figure;
}

/** A figure none of whose images this device could prepare reads as its caption, opened by a note that the PDF has it
 * (as a figure arXiv's HTML lost does, flow.ts): a caption paragraph, its legend lines kept, so no figure without an
 * image reaches the index and the paper still opens. Its equations and links stay in the block. */
function unshownFigure(cx: ArxivContext, figure: OutNode): OutNode {
  const id = figure.attribs.id;
  const listed = cx.figures.findIndex(f => f.id === id); if (listed >= 0) cx.figures.splice(listed, 1);
  const entry = cx.blocks.find(b => b.id === id); if (entry) entry.kind = 'paragraph';
  const words: Child[] = [];
  for (const part of figure.children) {
    if (typeof part === 'string') { words.push(part); continue; }
    if (isUnshownNote(part)) continue;
    if (words.length) words.push(el('br'));
    words.push(...part.children);
  }
  figure.name = 'p';
  figure.attribs = { class: 'reader-caption', id, 'data-reader-block': id, 'data-reader-kind': 'paragraph' };
  figure.children = [el('em', {}, [UNSHOWN_FIGURE_NOTE]), ...(words.length ? [' ', ...words] : [])];
  return figure;
}
