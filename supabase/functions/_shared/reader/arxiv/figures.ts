// Figures (arXiv converter component): figure blocks with their images, legends and captions.
import { el, elements, normalizeSpace, outText, textContent, type DomNode, type OutNode } from '../html.ts';
import { LIMITS } from '../profile.ts';
import { boundedText, check, excerpt } from '../util.ts';
import { active, bind, block, children, loneImage, type ArxivContext, type Child } from './context.ts';
import { inline } from './inline.ts';
import { arxivAssetURL } from './urls.ts';

/** One of a figure's images: an asset (or an inline picture by id) admitted by the host, at most `imagesPerFigure`. */
export function figureImage(cx: ArxivContext, n: DomNode, owner: string, inlineImage = false): Child {
  bind(cx, n, owner);
  // A grid past the figure's image limit (112 thumbnails in a tabular, 2610.20584): the first ones stay, the rest
  // are left out and counted, never a refusal.
  if ((cx.figureImages.get(owner)?.length ?? 0) >= LIMITS.imagesPerFigure) { cx.omittedGraphics += 1; for (const m of elements(n, c => c.name === 'math')) cx.skippedMath.add(m); return ''; }
  // Math drawn inside an inline SVG picture (a TikZ node's foreignObject) travels with the picture, not as an equation.
  if (n.name === 'svg') for (const m of elements(n, c => c.name === 'math')) cx.skippedMath.add(m);
  check(n.name !== 'object' || n.attribs.type === 'image/svg+xml', 'arxiv_asset_type');
  const url = n.name === 'svg' ? '#' + n.attribs.id : arxivAssetURL(n.attribs[n.name === 'img' ? 'src' : 'data'] ?? '', cx.sourceURL);
  cx.imageURLs.add(url);
  const asset = cx.resolveImage(url);
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
  return block(cx, n, 'figure', 'figure', id => {
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
      else if (['div','span','table','thead','tbody','tfoot','tr','td','th'].includes(child.name)) children(child).forEach(visit);
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
        flush(); output.push(part);
      } else run.push(part);
    }
    flush();
    const captionText = caption ? excerpt(normalizeSpace(outText(caption)), LIMITS.textBytes) : '';
    const alt = boundedText(captionText || images.map(i => i.attribs.alt ?? '').filter(Boolean).join(' ') || 'Figure', LIMITS.textBytes, 'arxiv_alt');
    for (const image of imageNodes) image.attribs.alt = alt;
    const paths = imageNodes.map(image => image.attribs.src);
    cx.figures.push({ id, block_id: id, asset_paths: [...new Set(paths)], caption: captionText, alt });
    return output;
  }, {});
}
