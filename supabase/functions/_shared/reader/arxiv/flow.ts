// The page's flow (arXiv converter component): which reader block each LaTeXML structure becomes.
import { el, elements, normalizeSpace, textContent, walk, type DomNode, type OutNode } from '../html.ts';
import { check } from '../util.ts';
import { active, bind, block, children, has, isMarker, loneImage, onTitlePage, type ArxivContext, type Child } from './context.ts';
import { authorsBlock } from './authors.ts';
import { equation } from './math.ts';
import { inline } from './inline.ts';
import { imageFigure } from './figures.ts';
import { minipageCaption, table, tableContents, tableGroupCaption } from './tables.ts';
import { templatePreamble } from './front-matter.ts';

/** Opens the caption of a figure whose image arXiv's own HTML conversion lost (owner's library sweep, 2026-10-15). */
export const MISSING_FIGURE_NOTE = 'This figure is not in arXiv’s HTML version of the paper; the PDF has it.';

/** The page's structure: one source node to the reader blocks it becomes, in order (sections, headings, paragraphs,
 * figures, tables, equations, lists, the author block, a title page's pieces). */
export function flow(cx: ArxivContext, n: DomNode): OutNode[] {
  if (n.type === 'comment' || active.has(n.name) || (n.type === 'text' && !n.data.trim())) return [];
  if (n.type === 'text') return [block(cx, n, 'p', 'paragraph', () => [n.data])];
  check(n.type === 'tag', 'arxiv_node');
  if (isMarker(n)) { bind(cx, n, cx.blocks[cx.blocks.length - 1]?.id ?? ''); return []; }
  // The date line under the header (the paper line already says the year and the arXiv revision).
  if (has(n, 'ltx_dates')) { for (const m of elements(n, c => c.name === 'math')) cx.skippedMath.add(m); return []; }
  // Publication notes under the title (a revision date, a venue line, a DOI and ISBN: 2610.07591, 2610.19855) are
  // catalog data, not the paper; the author block follows the title.
  if (has(n, 'ltx_pubnotes')) { for (const m of elements(n, c => c.name === 'math')) cx.skippedMath.add(m); return []; }
  if (!cx.titleSeen && ['div', 'p'].includes(n.name) && elements(n, c => isMarker(c)).length >= 2 && !elements(n, c => ['figure', 'table', 'h1'].includes(c.name)).length) {
    templatePreamble(cx, n); return [];
  }
  // A recovered abstract reads where the paper's own would: after the title and the authors.
  let recovered: OutNode[] = [];
  if (cx.pendingAbstract && cx.titleSeen && n.name !== 'h1' && !has(n, 'ltx_authors')) {
    const { owner, nodes } = cx.pendingAbstract; cx.pendingAbstract = null;
    recovered = [block(cx, owner, 'h6', 'heading', () => ['Abstract']), block(cx, owner, 'p', 'paragraph', id => nodes.flatMap(c => inline(cx, c, id)))];
  }
  const before = cx.blocks.length;
  let output: OutNode[];
  if (n.name === 'h1') cx.titleSeen = true;
  // A heading keeps no line breaks (LaTeX's \\ in a title, 2610.10478 on build 46: "Why is performance on a new line?").
  if (/^h[1-6]$/.test(n.name)) output = [block(cx, n, n.name, 'heading', id => children(n).flatMap(c => inline(cx, c, id)).map(c => typeof c !== 'string' && c.name === 'br' ? ' ' : c))];
  else if (n.name === 'figure') {
    const insideSVG = (c: DomNode) => { for (let a = c.parent; a; a = a.parent) if (a.name === 'svg') return true; return false; };
    const tables = elements(n, c => c.name === 'table' && !insideSVG(c));
    const images = elements(n, c => ['img','object','svg'].includes(c.name));
    const captions = children(n).filter(c => c.name === 'figcaption');
    if (captions.length > 1 && !tables.length && !elements(n, c => c !== n && c.name === 'figure').length) {
      // LaTeXML can put several complete numbered figures in one container.
      // Keep each image group with its following caption, in source order.
      output = []; let panel: DomNode[] = [];
      for (const child of children(n)) {
        panel.push(child);
        if (child.name === 'figcaption') {
          output.push(imageFigure(cx, { ...n, attribs: {}, children: panel })); panel = [];
        }
      }
      output.push(...panel.flatMap(c => flow(cx, c)));
    } else if (tables.length && images.length && !elements(n, c => c !== n && c.name === 'figure').length
        && tables.every(t => !normalizeSpace(textContent(t)).length)) {
      // Panels laid out in a tabular whose cells hold only graphics (Batch Normalization's Figure 1, audit
      // 2026-10-15: graphics in table cells were left out): the figure's own images, in cell order.
      output = [imageFigure(cx, n)];
    } else if (imagePanels(n, insideSVG)) {
      // Panels that are all pictures under one caption ("Figure 1" with (a) and (b), 2610.19525 on build 51: the
      // panels were two figures and "Figure 1" a paragraph, so a chat question about Figure 1 found nothing): one
      // figure, its panels in order with their own captions under them, the figure's caption last. A reference to a
      // panel opens the figure.
      output = [imageFigure(cx, n)];
    } else if (elements(n, c => c !== n && c.name === 'figure').length || (tables.length && images.length)) {
      // Compound figures keep their panel order and captions as separate,
      // non-nested reader blocks. A reference to the group opens its first panel.
      output = children(n).flatMap(c => flow(cx, c));
      // A table float's caption is then a paragraph beside its tables: Contents › Tables names them by it.
      if (has(n, 'ltx_table')) tableGroupCaption(cx, before);
    } else if (!tables.length && images.length === 0 && captions.length === 1
        && !children(n).some(c => c.name !== 'figcaption' && normalizeSpace(textContent(c)).length > 0)) {
      // A caption with no graphic of its own (LaTeXML's \\captionof after an unwrapped \\includegraphics, as in
      // 2610.17288's Figure 1): the caption paragraph, right under the figure the paragraph before it became.
      // A figure whose other children carry text (an algorithm's listing, a tabular in a paragraph) is a table
      // block below instead (audit 2026-10-15: nine of fifteen refusals were listings dropped here).
      // A figure whose image arXiv's HTML lacks (data-reader-missing, source.ts) says so before its caption.
      const missing = n.attribs?.['data-reader-missing'] === '1'
        || elements(n, c => c.attribs?.['data-reader-missing'] === '1').length > 0;
      output = [block(cx, n, 'p', 'paragraph', id => [...(missing ? [el('em', {}, [MISSING_FIGURE_NOTE]), ' '] : []),
        ...children(captions[0]).flatMap(c => inline(cx, c, id))], { class: 'reader-caption' })];
    } else if (tables.length || images.length === 0) {
      output = [block(cx, n, 'div', 'table', id => children(n).flatMap(c => tableContents(cx, c, id)), { class: 'reader-table' })];
      if (!captions.length) minipageCaption(cx, n, output[0].attribs.id);
    } else output = [imageFigure(cx, n)];
  } else if (has(n, 'ltx_equation') || has(n, 'ltx_equationgroup')) {
    const maths = elements(n, c => c.name === 'math');
    // An "equation" that is only text (a file-name pattern marked as math, 2610.19830) reads as a paragraph.
    if (!maths.length) output = [block(cx, n, 'p', 'paragraph', id => children(n).flatMap(c => inline(cx, c, id)))];
    else output = [block(cx, n, 'p', 'equation', id => {
      const parts: Child[] = [];
      for (const math of maths) parts.push(equation(cx, math, id, true));
      const tags = elements(n, c => has(c, 'ltx_tag_equation') || has(c, 'ltx_tag_equationgroup'));
      if (tags.length) {
        const last = parts[parts.length - 1] as OutNode;
        last.attribs.class += ' reader-tagged';
        last.children.push(el('span', { class: 'reader-tag' }, [tags.map(textContent).join(' ')]));
      }
      walk(n, child => { if (child.name !== 'math' && child.attribs?.id && !cx.aliases.has(child.attribs.id)) bind(cx, child, id); });
      return parts;
    })];
  } else if (n.name === 'table') output = [block(cx, n, 'div', 'table', id => [table(cx, n, id)], { class: 'reader-table' })];
  else if (n.name === 'pre') output = [block(cx, n, 'pre', 'code', () => [el('code', {}, [textContent(n)])])];
  else if (n.name === 'ul' || n.name === 'ol') {
    const list = el(n.name, has(n, 'ltx_biblist') ? { class: 'reader-references' } : {}, []);
    const pending: DomNode[] = [];
    for (const item of children(n)) {
      if (item.type === 'text' && !item.data.trim() || item.type === 'comment') continue;
      check(item.name === 'li', 'arxiv_list');
      // An item holding a table (KAN's enumerated comparisons) keeps it as a table inside the item.
      const tabular = elements(item, c => c !== item && c.name === 'table').length > 0;
      // A figure inside an item (PaLM's first figure) becomes its own block after the list; the item keeps its words.
      const holdsFigure = (c: DomNode) => c.name === 'figure' || elements(c, x => x !== c && x.name === 'figure').length > 0;
      const figures = children(item).filter(holdsFigure);
      list.children.push(block(cx, item, 'li', 'list', id => children(item).filter(c => !holdsFigure(c)).flatMap(c => tabular ? tableContents(cx, c, id) : inline(cx, c, id))));
      pending.push(...figures);
    }
    // Compiled after every item so the index order matches the page (a block is numbered when it is made).
    output = [list, ...pending.flatMap(c => flow(cx, c))];
  } else if (n.name !== 'figcaption' && n.name !== 'math' && !has(n, 'ltx_authors') && loneImage(n) && onTitlePage(n)) {
    // A logo on a custom title page (2610.15371's company mark above the title) is no figure: left out and counted.
    cx.omittedGraphics += 1; for (const m of elements(n, c => c.name === 'math')) cx.skippedMath.add(m); output = [];
  } else if (n.name !== 'figcaption' && n.name !== 'math' && !has(n, 'ltx_authors') && loneImage(n)) {
    // A TikZ picture that is really a framed text box (LaTeXML: `svg.ltx_picture` whose foreignObjects hold the
    // text): its words read as paragraphs and the frame is left out and counted. Any other lone graphic is a figure.
    const picture = elements(n, c => c.name === 'svg')[0];
    const labels = picture ? elements(picture, c => c.name === 'foreignObject').filter(fo => normalizeSpace(textContent(fo)).length > 0) : [];
    if (picture && labels.length) {
      cx.omittedGraphics += 1;
      output = labels.map(fo => elements(fo, c => c.name === 'table').length
        ? block(cx, fo, 'div', 'table', id => children(fo).flatMap(c => tableContents(cx, c, id)), { class: 'reader-table' })
        : block(cx, fo, 'p', 'paragraph', id => children(fo).flatMap(c => inline(cx, c, id))));
      if (picture.attribs?.id && output.length) bind(cx, picture, output[0].attribs.id);
    } else output = [imageFigure(cx, n)];
  }
  // A table or figure wrapped in inline-blocks (LaTeXML's resizebox, `span.ltx_transformed_inner`): its container
  // is flow, not a paragraph, so the table reads as a table block.
  else if (n.name !== 'figcaption' && !has(n, 'ltx_authors') && elements(n, c => c !== n && ['table', 'figure'].includes(c.name)).length) output = children(n).flatMap(c => flow(cx, c));
  else if (has(n, 'ltx_authors') && elements(n, c => has(c, 'ltx_creator')).length) output = [authorsBlock(cx, n)];
  else if (n.name === 'p' || n.name === 'figcaption' || has(n, 'ltx_authors') || n.name === 'math') {
    output = [block(cx, n, 'p', n.name === 'math' ? 'equation' : 'paragraph', id => n.name === 'math' ? [equation(cx, n, id)]
      : children(n).flatMap(c => inline(cx, c, id)), has(n, 'ltx_authors') ? { class: 'reader-authors' }
        : n.name === 'figcaption' ? { class: 'reader-caption' } : {})];
  } else if (n.name === 'hr') output = [el('hr')];
  else if (['article', 'section', 'div', 'header', 'footer', 'aside'].includes(n.name)) output = children(n).flatMap(c => flow(cx, c));
  else if (n.name === 'img' || n.name === 'object' || n.name === 'svg') output = [imageFigure(cx, n)];
  else output = [block(cx, n, 'p', 'paragraph', id => inline(cx, n, id))];
  if (cx.blocks.length > before && n.attribs?.id && !cx.aliases.has(n.attribs.id)) bind(cx, n, cx.blocks[before].id);
  return recovered.length ? [...recovered, ...output] : output;
}

/** A figure whose nested panels each hold a picture and no table of text, with one caption of its own. */
function imagePanels(n: DomNode, insideSVG: (c: DomNode) => boolean): boolean {
  const panels = elements(n, c => c !== n && c.name === 'figure');
  const textTable = (root: DomNode) => elements(root, c => c.name === 'table' && !insideSVG(c) && normalizeSpace(textContent(c)).length > 0).length > 0;
  return panels.length > 0 && children(n).filter(c => c.name === 'figcaption').length === 1 && !textTable(n)
    && panels.every(p => elements(p, c => ['img','object','svg'].includes(c.name)).length > 0);
}
