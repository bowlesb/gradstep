// Tables as cells (device_pdf.table_cells and cell_span_ok), ported rule for rule.
import { byX, linesOf, visible } from './geometry.ts';
import { CELL_GAP, WIDE_CELL, type Glyph } from './types.ts';

const MATH_FONT = /CMMI|CMSY|CMEX|MSAM|MSBM|Math|rsfs|eufm|wasy|stmry|Symbol/i;

/** A tagged span in a table cell is text when it is one glyph with no letter and no math font (a dagger, an
 * asterisk, a footnote digit). */
export function cellSpanOk(glyphs: readonly Glyph[]): boolean {
  const shown = glyphs.filter(visible);
  if (shown.length !== 1) return true;
  const g = shown[0], text = g.text.trim();
  return /^\p{L}+$/u.test(text) || MATH_FONT.test(g.font ?? '');
}

export type Cell = [Glyph[], number];
const lowerMedian = (values: number[]) => { const s = [...values].sort((a, b) => a - b); return s[s.length >> 1]; };

/** Rows of (cell glyphs, colspan) from the text layer inside a table box, or null (fewer than two columns or rows). */
export function tableCells(glyphs: readonly Glyph[]): Cell[][] | null {
  const lines = linesOf(glyphs.filter(visible)).map((ln, i) => [ln, i] as const)
    .sort((a, b) => Math.min(...a[0].map(g => g.top)) - Math.min(...b[0].map(g => g.top)) || a[1] - b[1]).map(([ln]) => ln);
  if (lines.length < 2) return null;
  const runsByLine: Glyph[][][] = [];
  for (const ln of lines) {
    const order = byX(ln);
    const h = Math.max(1.0, lowerMedian(order.map(g => g.bottom - g.top)));
    const runs: Glyph[][] = [[order[0]]];
    for (const g of order.slice(1)) {
      const last = runs[runs.length - 1];
      if (g.x0 - last[last.length - 1].x1 > CELL_GAP * h) runs.push([]);
      runs[runs.length - 1].push(g);
    }
    runsByLine.push(runs);
  }
  const x0 = Math.min(...glyphs.map(g => g.x0));
  const width = Math.max(1.0, Math.max(...glyphs.map(g => g.x1)) - x0);
  const extent = (r: Glyph[]): [number, number] => [Math.min(...r.map(g => g.x0)), Math.max(...r.map(g => g.x1))];
  const spans = runsByLine.flat().map(extent).filter(([a, b]) => b - a < WIDE_CELL * width).sort((p, q) => p[0] - q[0] || p[1] - q[1]);
  const columns: [number, number][] = [];
  for (const [a, b] of spans) {
    if (columns.length && a <= columns[columns.length - 1][1]) columns[columns.length - 1][1] = Math.max(columns[columns.length - 1][1], b);
    else columns.push([a, b]);
  }
  if (columns.length < 2) return null;
  const rows: Cell[][] = [];
  for (const runs of runsByLine) {
    const cells = new Map<number, Cell>();
    for (const r of runs) {
      const [a, b] = extent(r);
      let hit = columns.map(([ca, cb], i) => Math.min(b, cb) - Math.max(a, ca) > 0 ? i : -1).filter(i => i >= 0);
      if (!hit.length) {
        const c = (a + b) / 2;
        let best = 0;
        columns.forEach((col, i) => { if (Math.abs((col[0] + col[1]) / 2 - c) < Math.abs((columns[best][0] + columns[best][1]) / 2 - c)) best = i; });
        hit = [best];
      }
      const first = hit[0], span = hit[hit.length - 1] - hit[0] + 1;
      const existing = cells.get(first);
      cells.set(first, existing ? [[...existing[0], ...r], Math.max(existing[1], span)] : [r, span]);
    }
    const row: Cell[] = [];
    for (let i = 0; i < columns.length;) {
      const cell = cells.get(i);
      if (cell) { row.push(cell); i += cell[1]; } else { row.push([[], 1]); i += 1; }
    }
    const filled = row.map((c, j) => c[0].length ? j : -1).filter(j => j >= 0);
    if (rows.length && filled.length === 1 && filled[0] < rows[rows.length - 1].length && rows[rows.length - 1][filled[0]][0].length) {
      const prev = rows[rows.length - 1][filled[0]][0];
      const h = Math.max(1.0, lowerMedian(prev.map(g => g.bottom - g.top)));
      if (Math.min(...row[filled[0]][0].map(g => g.top)) - Math.max(...prev.map(g => g.bottom)) < 0.5 * h) {
        rows[rows.length - 1][filled[0]] = [[...prev, ...row[filled[0]][0]], rows[rows.length - 1][filled[0]][1]];
        continue;
      }
    }
    rows.push(row);
  }
  return rows.length >= 2 ? rows : null;
}
