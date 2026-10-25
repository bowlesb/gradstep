// Tables as cells (device_pdf.table_cells and cell_span_ok), ported rule for rule; since port revision 13 with measured
// rules of its own (TableOptions, docs/reviews/DEVICE_PDF_TABLES_20261024.md).
import { byX, linesOf, visible } from './geometry.ts';
import { CELL_GAP, WIDE_CELL, type Box, type Glyph } from './types.ts';

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

/** Converter rules for tables (each measured on its own; off reproduces the reference). */
export interface TableOptions {
  /** Columns from the lines with the most cells (the body's grid), so a spanning header or a wide caption-like line no
   * longer bridges two columns into one. */
  columns?: boolean;
  /** A cell that joins lines keeps them as lines: its text is read line by line instead of by x across them. */
  cellLines?: boolean;
  /** A line that continues the row above (a wrapped text cell: no number in it, only columns the row above fills, and
   * no wider gap than the table's tightest line spacing) joins that row cell by cell. */
  rows?: boolean;
  /** The page's ruling lines (points, [x0, top, x1, bottom]): a horizontal rule between two lines keeps them apart; in a
   * table ruled between (nearly) every row, the lines between two rules are one row; a vertical rule separates
   * columns. */
  rules?: readonly Box[];
}

const lowerMedian = (values: number[]) => { const s = [...values].sort((a, b) => a - b); return s[s.length >> 1]; };
const top = (gl: readonly Glyph[]) => Math.min(...gl.map(g => g.top));
const bottom = (gl: readonly Glyph[]) => Math.max(...gl.map(g => g.bottom));
const extent = (r: readonly Glyph[]): [number, number] => [Math.min(...r.map(g => g.x0)), Math.max(...r.map(g => g.x1))];
/** A cell of figures: digits with the signs and marks results carry (93.4 ± 0.2, 12.5%, (3), –, 1e-4), no word. */
const NUMERIC = /^[\s\d.,%±+\-−–—()[\]/×*†‡∗⋆·:<>≤≥~^e]*\d[\s\d.,%±+\-−–—()[\]/×*†‡∗⋆·:<>≤≥~^e]*$/u;
const textOf = (gl: readonly Glyph[]) => byX(gl).map(g => g.text).join('');

/** Rows of (cell glyphs, colspan[, lines]) from the text layer inside a table box, or null (fewer than two columns or
 * rows). */
export function tableCells(glyphs: readonly Glyph[], options: TableOptions = {}): Cell[][] | null {
  if (!options.columns && !options.cellLines && !options.rows && !options.rules?.length) return referenceCells(glyphs);
  const lines = linesOf(glyphs.filter(visible)).map((ln, i) => [ln, i] as const)
    .sort((a, b) => top(a[0]) - top(b[0]) || a[1] - b[1]).map(([ln]) => ln);
  if (lines.length < 2) return null;
  const x0 = Math.min(...glyphs.map(g => g.x0));
  const x1 = Math.max(...glyphs.map(g => g.x1));
  const width = Math.max(1.0, x1 - x0);
  const yTop = Math.min(...glyphs.map(g => g.top)), yBottom = Math.max(...glyphs.map(g => g.bottom));
  // Ruling lines over the table: horizontal ones crossing a third of its width, vertical ones inside it.
  const rules = options.rules ?? [];
  const hRules = rules.filter(r => r[3] - r[1] <= 2.5 && r[2] - r[0] > r[3] - r[1] && Math.min(r[2], x1) - Math.max(r[0], x0) >= width / 3 &&
    r[1] >= yTop - 6 && r[3] <= yBottom + 6).map(r => (r[1] + r[3]) / 2);
  const vRules = rules.filter(r => r[2] - r[0] <= 2.5 && r[3] - r[1] > r[2] - r[0] && r[0] > x0 + 2 && r[2] < x1 - 2 &&
    Math.min(r[3], yBottom) - Math.max(r[1], yTop) > 0).map(r => [(r[0] + r[2]) / 2, r[1], r[3]] as const);
  const ruleBetween = (a: readonly Glyph[], b: readonly Glyph[]) => { const lo = bottom(a) - 1.0, hi = top(b) + 1.0; return hRules.some(y => y > lo && y < hi); };

  const runsByLine: Glyph[][][] = [];
  for (const ln of lines) {
    const order = byX(ln);
    const h = Math.max(1.0, lowerMedian(order.map(g => g.bottom - g.top)));
    const lt = top(ln), lb = bottom(ln);
    const runs: Glyph[][] = [[order[0]]];
    for (const g of order.slice(1)) {
      const last = runs[runs.length - 1], prev = last[last.length - 1];
      const ruled = vRules.some(([x, a, b]) => x > prev.x1 - 0.5 && x < g.x0 + 0.5 && Math.min(b, lb) - Math.max(a, lt) > 0);
      if (g.x0 - prev.x1 > CELL_GAP * h || ruled) runs.push([]);
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
  const spans = source.flat().map(extent).filter(([a, b]) => b - a < WIDE_CELL * width).sort((p, q) => p[0] - q[0] || p[1] - q[1]);
  let columns: [number, number][] = [];
  for (const [a, b] of spans) {
    if (columns.length && a <= columns[columns.length - 1][1]) columns[columns.length - 1][1] = Math.max(columns[columns.length - 1][1], b);
    else columns.push([a, b]);
  }
  // A vertical rule inside a column splits it.
  if (vRules.length) {
    columns = columns.flatMap(([a, b]) => {
      const cuts = [...new Set(vRules.map(([x]) => x).filter(x => x > a + 1 && x < b - 1))].sort((p, q) => p - q);
      const out: [number, number][] = []; let from = a;
      for (const x of cuts) { out.push([from, x]); from = x; }
      out.push([from, b]);
      return out;
    });
  }
  if (columns.length < 2) return null;

  type Row = { cells: Map<number, Cell>; lines: Glyph[][] };
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
  // The table's tightest spacing between lines (a wrapped cell's lines are set at it).
  const gaps = lines.slice(1).map((ln, i) => top(ln) - bottom(lines[i])).filter(g => g > -2);
  const tightest = gaps.length ? Math.min(...gaps) : 0;
  const hAll = Math.max(1.0, lowerMedian(glyphs.filter(visible).map(g => g.bottom - g.top)));
  // Ruled between rows: at least three rules between lines and most of the stretches between them one line.
  let ruledRows = false;
  if (hRules.length) {
    const groups: number[] = [1];
    for (let i = 1; i < lines.length; i++) { if (ruleBetween(lines[i - 1], lines[i])) groups.push(1); else groups[groups.length - 1] += 1; }
    ruledRows = groups.length >= 4 && groups.filter(n => n === 1).length >= 0.6 * groups.length;
  }

  const rows: Row[] = [];
  runsByLine.forEach((runs, li) => {
    const cells = rowOf(runs), line = lines[li];
    const prev = rows[rows.length - 1];
    const prevLine = prev?.lines[prev.lines.length - 1];
    const blocked = prev ? ruleBetween(prevLine!, line) : true;
    if (prev && !blocked) {
      // In a table ruled between its rows, the lines between two rules are one row.
      if (ruledRows) { join(prev.cells, cells); prev.lines.push(line); return; }
      const filled = [...cells.keys()];
      // The reference's rule: a line with one cell, under a filled cell of the row above and close to it, continues it.
      if (filled.length === 1) {
        const s = covering(prev.cells, filled[0]);
        if (s === filled[0] && prev.cells.get(s)![0].length) {
          const above = prev.cells.get(s)![0];
          const h = Math.max(1.0, lowerMedian(above.map(g => g.bottom - g.top)));
          if (top(cells.get(s)![0]) - bottom(above) < 0.5 * h) { join(prev.cells, cells); prev.lines.push(line); return; }
        }
      }
      // rows: a wrapped text line continues the row above.
      if (options.rows && filled.length < prev.cells.size && top(line) - bottom(prevLine!) <= tightest + 0.15 * hAll &&
          [...cells.values()].every(cell => !NUMERIC.test(textOf(cell[0]))) &&
          filled.every(c => { const s = covering(prev.cells, c); return s >= 0 && !NUMERIC.test(textOf(prev.cells.get(s)![0])); })) {
        join(prev.cells, cells); prev.lines.push(line); return;
      }
    }
    rows.push({ cells, lines: [line] });
  });

  const out: Cell[][] = rows.map(({ cells }) => {
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
