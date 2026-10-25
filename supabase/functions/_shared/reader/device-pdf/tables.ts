// Tables as cells (device_pdf.table_cells and cell_span_ok), ported rule for rule; since port revision 13 with measured
// rules of its own (TableOptions; docs/reviews/DEVICE_PDF_TABLES_20261024.md).
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

/** A cell: its glyphs, its colspan, and (with `cellLines`) its lines top to bottom when it has more than one, which
 * are read one by one (a cell's glyphs sorted by x alone interleave its lines' words). */
export type Cell = [Glyph[], number, Glyph[][]?];

/** Converter rules for tables (each measured on its own; none set reads as the reference). */
export interface TableOptions {
  /** Columns from the lines with the most cells (the body's grid), so a spanning header no longer bridges two columns
   * into one; a run starting under a spanning cell joins it. */
  columns?: boolean;
  /** A cell that joins lines keeps them as lines: its text is read line by line instead of by x across them. */
  cellLines?: boolean;
  /** A gap of 0.45 of the line's glyph height, not 0.6, separates two cells of a line: tables set with a narrow
   * column separation (or scaled down) no longer read two columns' entries as one cell. */
  narrowGaps?: boolean;
}

/** The narrowGaps rule's cell gap, in glyph heights (measured on the factory's labelled tables: 0.4 splits words of
 * loosely set text cells, 0.5 and up merges narrow columns). */
const NARROW_CELL_GAP = 0.45;
const lowerMedian = (values: number[]) => { const s = [...values].sort((a, b) => a - b); return s[s.length >> 1]; };
const top = (gl: readonly Glyph[]) => Math.min(...gl.map(g => g.top));
const bottom = (gl: readonly Glyph[]) => Math.max(...gl.map(g => g.bottom));
const extent = (r: readonly Glyph[]): [number, number] => [Math.min(...r.map(g => g.x0)), Math.max(...r.map(g => g.x1))];

/** Rows of (cell glyphs, colspan[, lines]) from the text layer inside a table box, or null (fewer than two columns or
 * rows). */
export function tableCells(glyphs: readonly Glyph[], options: TableOptions = {}): Cell[][] | null {
  if (!options.columns && !options.cellLines && !options.narrowGaps) return referenceCells(glyphs);
  const lines = linesOf(glyphs.filter(visible)).map((ln, i) => [ln, i] as const)
    .sort((a, b) => top(a[0]) - top(b[0]) || a[1] - b[1]).map(([ln]) => ln);
  if (lines.length < 2) return null;
  const x0 = Math.min(...glyphs.map(g => g.x0));
  const width = Math.max(1.0, Math.max(...glyphs.map(g => g.x1)) - x0);

  const gapFactor = options.narrowGaps ? NARROW_CELL_GAP : CELL_GAP;
  const runsByLine: Glyph[][][] = [];
  for (const ln of lines) {
    const order = byX(ln);
    const h = Math.max(1.0, lowerMedian(order.map(g => g.bottom - g.top)));
    const runs: Glyph[][] = [[order[0]]];
    for (const g of order.slice(1)) {
      const last = runs[runs.length - 1];
      if (g.x0 - last[last.length - 1].x1 > gapFactor * h) runs.push([]);
      runs[runs.length - 1].push(g);
    }
    runsByLine.push(runs);
  }
  // Columns: the runs' extents merged where they overlap (wide runs left out); with `columns`, only the lines with the
  // most common number of runs (at least two; ties to the larger) or more set them.
  let source = runsByLine;
  if (options.columns) {
    const freq = new Map<number, number>();
    for (const r of runsByLine) if (r.length >= 2) freq.set(r.length, (freq.get(r.length) ?? 0) + 1);
    let mode = 0, best = 0;
    for (const [n, f] of freq) if (f > best || (f === best && n > mode)) { mode = n; best = f; }
    if (mode >= 2) source = runsByLine.filter(r => r.length >= mode);
  }
  const columnsOf = (from: Glyph[][][]) => {
    const spans = from.flat().map(extent).filter(([a, b]) => b - a < WIDE_CELL * width).sort((p, q) => p[0] - q[0] || p[1] - q[1]);
    const out: [number, number][] = [];
    for (const [a, b] of spans) {
      if (out.length && a <= out[out.length - 1][1]) out[out.length - 1][1] = Math.max(out[out.length - 1][1], b);
      else out.push([a, b]);
    }
    return out;
  };
  let columns = columnsOf(source);
  // The grid's lines may hold too few narrow runs (a wide text column): then every line's, as the reference.
  if (columns.length < 2 && source !== runsByLine) columns = columnsOf(runsByLine);
  if (columns.length < 2) return null;

  const rowOf = (runs: Glyph[][]): Map<number, Cell> => {
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
    return cells;
  };
  /** The start of the cell of `row` covering column `c`, or -1. */
  const covering = (row: Map<number, Cell>, c: number) => { for (const [s, cell] of row) if (c >= s && c < s + cell[1]) return s; return -1; };
  const linesOfCell = (cell: Cell) => cell[2] ?? [cell[0]];
  /** Joins `add` into `into` cell by cell; a joined cell keeps its lines (cellLines). */
  const join = (into: Map<number, Cell>, add: Map<number, Cell>) => {
    for (const [c, cell] of add) {
      const s = covering(into, c);
      if (s < 0) { into.set(c, cell); continue; }
      const old = into.get(s)!;
      into.set(s, [[...old[0], ...cell[0]], old[1], options.cellLines ? [...linesOfCell(old), ...linesOfCell(cell)] : undefined]);
    }
  };

  const rows: Map<number, Cell>[] = [];
  for (const runs of runsByLine) {
    const cells = rowOf(runs);
    const prev = rows[rows.length - 1];
    if (prev) {
      const filled = [...cells.keys()];
      // The reference's rule: a line with one cell, under a filled cell of the row above and close to it, continues it.
      if (filled.length === 1) {
        const s = covering(prev, filled[0]);
        if (s === filled[0] && prev.get(s)![0].length) {
          const above = prev.get(s)![0];
          const h = Math.max(1.0, lowerMedian(above.map(g => g.bottom - g.top)));
          if (top(cells.get(s)![0]) - bottom(above) < 0.5 * h) { join(prev, cells); continue; }
        }
      }
    }
    rows.push(cells);
  }

  const out: Cell[][] = rows.map(cells => {
    const row: Cell[] = [];
    for (let i = 0; i < columns.length;) {
      const cell = cells.get(i);
      if (cell) {
        const span = Math.max(1, Math.min(cell[1], columns.length - i));
        // With `columns`, a run that starts under a spanning cell belongs to it (the reference drops its glyphs).
        if (options.columns) for (let j = i + 1; j < i + span; j++) {
          const under = cells.get(j);
          if (under) cell[0].push(...under[0]);
          if (under && cell[2]) cell[2].push(...linesOfCell(under));
        }
        const ls = cell[2]?.filter(l => l.length);
        row.push(ls && ls.length > 1 ? [cell[0], span, ls] : [cell[0], span]);
        i += span;
      } else { row.push([[], 1]); i += 1; }
    }
    return row;
  });
  return out.length >= 2 ? out : null;
}

/** The reference's rule (device_pdf.table_cells), unchanged: with no TableOptions the port reads as the reference. */
function referenceCells(glyphs: readonly Glyph[]): Cell[][] | null {
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
