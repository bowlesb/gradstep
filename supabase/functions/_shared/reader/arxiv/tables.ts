// Tables (arXiv converter component): LaTeXML's tabulars as reader tables, and table blocks' other contents.
import { classes, el, elements, type DomNode, type OutNode } from '../html.ts';
import { check } from '../util.ts';
import { active, bind, children, nearest, type ArxivContext, type Child } from './context.ts';
import { equation } from './math.ts';
import { inline } from './inline.ts';

/** An HTML table: rows and cells with their spans; nested layout tables flattened into the cell. */
export function table(cx: ArxivContext, n: DomNode, owner: string): OutNode {
  bind(cx, n, owner);
  const rows = elements(n, c => c.name === 'tr' && nearest(c, 'table') === n);
  return el('table', {}, [el('tbody', {}, rows.map(row => {
    bind(cx, row, owner);
    return el('tr', {}, children(row).filter(c => ['td', 'th'].includes(c.name)).map(cell => {
      bind(cx, cell, owner);
      const attrs: Record<string, string> = {};
      for (const key of ['rowspan', 'colspan']) if (cell.attribs[key]) {
        check(/^[1-9][0-9]{0,2}$/.test(cell.attribs[key]), 'arxiv_table_span'); attrs[key] = cell.attribs[key];
      }
      return el(cell.name, attrs, children(cell).flatMap(c => cellContents(cx, c, owner)));
    }));
  }))]);
}
export function cellContents(cx: ArxivContext, n: DomNode, owner: string): Child[] {
  if (n.type === 'text' || n.type === 'comment') return inline(cx, n, owner);
  // HTML tables nested inside a cell express a panel's row layout. Flatten
  // only that layout to line/column separators; retain every cell and math.
  if (n.name === 'table' || elements(n, c => c !== n && c.name === 'table').length) {
    bind(cx, n, owner);
    return children(n).flatMap(c => cellContents(cx, c, owner));
  }
  if (['tbody', 'thead', 'tfoot', 'tr', 'td', 'th'].includes(n.name)) {
    bind(cx, n, owner);
    return [...children(n).flatMap(c => cellContents(cx, c, owner)), ...(n.name === 'tr' ? [el('br')] : [' '])];
  }
  return inline(cx, n, owner);
}
/** What a table block holds besides its tables: captions, lists, paragraphs and the text between them. */
export function tableContents(cx: ArxivContext, n: DomNode, owner: string): Child[] {
  if (n.type === 'text') return [n.data];
  if (n.type === 'comment' || active.has(n.name)) return [];
  bind(cx, n, owner);
  if (n.name === 'table') return [table(cx, n, owner)];
  if (n.name === 'math') return [equation(cx, n, owner)];
  if (n.name === 'figcaption') return [el('p', { class: 'reader-caption' }, children(n).flatMap(c => inline(cx, c, owner)))];
  if (['ul', 'ol', 'li', 'p', 'pre'].includes(n.name)) return [el(n.name, {}, children(n).flatMap(c => tableContents(cx, c, owner)))];
  if (['div', 'figure', 'section'].includes(n.name) ||
    elements(n, child => child !== n && child.name === 'table').length) return children(n).flatMap(c => tableContents(cx, c, owner));
  return inline(cx, n, owner);
}

/** At most this many entries in the index's optional `tables` list (the converter lists the first ones). Not in
 * profile.ts LIMITS, which is part of the Mathpix renderer's identity and bundled into the device PDF converter.
 * Copied in ReaderBundle.swift (`tableLimit`) and apps/web bundle.ts. */
export const INDEX_TABLES = 512;

/** A table float whose parts became separate blocks (its tabular beside an image or a nested figure, 2610.19820's
 * Table 1; captions in a row above tables in a row, 2610.20608's Tables 1 and 2): its captions are paragraphs of their
 * own. As many captions as tables pair in order; one caption names the group's first table, and the group's other
 * tables (sub-tables under it) aren't listed on their own. `from` is the number of blocks before the float's. */
export function tableGroupCaption(cx: ArxivContext, from: number): void {
  const made = cx.blocks.slice(from);
  const captions = made.filter(b => b.kind === 'paragraph' && b.node.attribs.class === 'reader-caption');
  const tables = made.filter(b => b.kind === 'table');
  if (!tables.length || !captions.length) return;
  if (captions.length === tables.length) tables.forEach((table, i) => cx.tableCaptions.set(table.id, captions[i].node));
  else if (captions.length === 1) tables.forEach((table, i) => cx.tableCaptions.set(table.id, i ? null : captions[0].node));
}

/** A table float captioned inside a minipage (`\captionof`, LaTeXML's `span.ltx_caption` in a paragraph: 2610.20608's
 * Table 6) has no `figcaption`: its caption's words, math as its LaTeX (as `data-latex` reads), for the table list. */
export function minipageCaption(cx: ArxivContext, n: DomNode, id: string): void {
  // A figcaption anywhere in it is the table's own caption paragraph (ownTableCaption).
  if (elements(n, c => c.name === 'figcaption').length) return;
  const caption = elements(n, c => classes(c).includes('ltx_caption'))[0];
  if (!caption) return;
  const words = (node: DomNode): string => node.type === 'text' ? node.data : node.type !== 'tag' ? ''
    : node.name === 'math' ? ` ${node.attribs.alttext ?? ''} ` : classes(node).includes('ltx_note') ? '' : (node.children ?? []).map(words).join('');
  cx.tableCaptions.set(id, words(caption));
}

/** A table block's own caption: the caption paragraph directly in it, else the first one inside it. */
export function ownTableCaption(node: OutNode): OutNode | null {
  const isCaption = (c: Child): c is OutNode => typeof c !== 'string' && c.name === 'p' && c.attribs.class === 'reader-caption';
  const direct = node.children.find(isCaption);
  if (direct) return direct;
  for (const child of node.children) {
    if (typeof child === 'string' || child.name === 'table') continue;
    const inner = ownTableCaption(child);
    if (inner) return inner;
  }
  return null;
}
