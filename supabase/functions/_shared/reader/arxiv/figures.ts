// Figures (arXiv converter component): figure blocks with their images, legends and captions.
import { el, elements, normalizeSpace, outText, textContent, type DomNode, type OutNode } from '../html.ts';
import { LIMITS } from '../profile.ts';
import { boundedText, check, excerpt } from '../util.ts';
import { active, bind, block, children, loneImage, type ArxivContext, type Child } from './context.ts';
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
