// Tables (arXiv converter component): LaTeXML's tabulars as reader tables, and table blocks' other contents.
import { el, elements, type DomNode, type OutNode } from '../html.ts';
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
