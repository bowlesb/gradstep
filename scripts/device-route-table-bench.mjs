#!/usr/bin/env node
// The device route's table grid (supabase/functions/_shared/reader/device-pdf/tables.ts) against labelled grids
// (docs/reviews/DEVICE_PDF_TABLES_20261024.md): each table's text-layer characters inside its box and its label cells
// in page points, made by scripts/device-route-table-bench.py from the desktop factory's table index (arXiv tables whose
// grids come from LaTeXML). Evaluation only; runs anywhere Node runs, in seconds per thousand tables.
//
//   node scripts/device-route-table-bench.mjs <bench.jsonl> [--set columns=true …] [--limit n] [--worst n]
//
// Glyphs are mapped to label cells by their centres. Measures: tables read as a grid; cells exactly right (a predicted
// cell holding exactly a label cell's glyphs; recall over label cells with glyphs, precision over predicted cells with
// mapped glyphs); adjacency (ICDAR 2013 style: neighbouring non-empty cells along rows and columns, predicted cells
// named by the label cell holding most of their glyphs).
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const { tableCells } = await import(`${ROOT}/supabase/functions/_shared/reader/device-pdf/tables.ts`);
const argv = process.argv.slice(2);
const arg = (name, fallback) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : fallback; };
const options = {};
argv.forEach((a, i) => { if (a === '--set') { const [k, ...v] = argv[i + 1].split('='); options[k] = JSON.parse(v.join('=')); } });
const limit = Number(arg('--limit', '0')), worst = Number(arg('--worst', '0'));

const totals = { tables: 0, read: 0, labelCells: 0, predCells: 0, exact: 0, labelRel: 0, predRel: 0, rel: 0 };
const perTable = [];
const lines = readFileSync(argv[0], 'utf8').split('\n').filter(Boolean);
for (const [n, line] of lines.entries()) {
  if (limit && n >= limit) break;
  const t = JSON.parse(line);
  const glyphs = t.glyphs.map(([text, x0, top, x1, bottom, size, font, upright]) => ({ text, x0, top, x1, bottom, size, font, upright }));
  const shown = glyphs.filter(g => g.text.trim() !== '');
  // Each glyph's label cell (by its centre; the smallest box holding it).
  const cellOf = new Map();
  t.cells.forEach((c, ci) => {
    for (const g of shown) {
      const cx = (g.x0 + g.x1) / 2, cy = (g.top + g.bottom) / 2;
      if (c.boxes.some(b => cx >= b[0] - 0.75 && cx <= b[2] + 0.75 && cy >= b[1] - 0.75 && cy <= b[3] + 0.75) && !cellOf.has(g)) cellOf.set(g, ci);
    }
  });
  const labelSets = new Map();
  for (const [g, ci] of cellOf) { if (!labelSets.has(ci)) labelSets.set(ci, new Set()); labelSets.get(ci).add(g); }
  if (!labelSets.size) continue;
  totals.tables++;
  // Label relations: neighbours along each row and each column among cells with glyphs.
  const labelRel = new Set();
  const withGlyphs = t.cells.map((c, ci) => ({ ...c, ci })).filter(c => labelSets.has(c.ci));
  for (const c of withGlyphs) {
    const right = withGlyphs.filter(d => d.row <= c.row + c.rowspan - 1 && d.row + d.rowspan - 1 >= c.row && d.col >= c.col + c.colspan).sort((a, b) => a.col - b.col)[0];
    const below = withGlyphs.filter(d => d.col <= c.col + c.colspan - 1 && d.col + d.colspan - 1 >= c.col && d.row >= c.row + c.rowspan).sort((a, b) => a.row - b.row)[0];
    if (right) labelRel.add(`${c.ci}>${right.ci}`);
    if (below) labelRel.add(`${c.ci}v${below.ci}`);
  }
  const grid = tableCells(shown, options);
  let exact = 0, predCells = 0, rel = 0;
  const predRel = new Set();
  if (grid) {
    totals.read++;
    // Predicted cells with their column ranges.
    const cells = [];
    grid.forEach((row, r) => { let col = 0; for (const [gl, span] of row) { if (gl.length) cells.push({ r, col, span, gl }); col += span; } });
    const named = cells.map(c => {
      const votes = new Map();
      for (const g of c.gl) if (cellOf.has(g)) votes.set(cellOf.get(g), (votes.get(cellOf.get(g)) ?? 0) + 1);
      const best = [...votes.entries()].sort((a, b) => b[1] - a[1])[0];
      return { ...c, label: best ? best[0] : -1, mapped: c.gl.filter(g => cellOf.has(g)) };
    }).filter(c => c.mapped.length);
    predCells = named.length;
    for (const c of named) {
      const want = labelSets.get(c.label);
      if (want && want.size === c.mapped.length && c.mapped.every(g => cellOf.get(g) === c.label)) exact++;
    }
    for (const c of named) {
      const right = named.filter(d => d.r === c.r && d.col >= c.col + c.span).sort((a, b) => a.col - b.col)[0];
      const below = named.filter(d => d.col <= c.col + c.span - 1 && d.col + d.span - 1 >= c.col && d.r > c.r).sort((a, b) => a.r - b.r)[0];
      if (right && right.label !== c.label) predRel.add(`${c.label}>${right.label}`);
      if (below && below.label !== c.label) predRel.add(`${c.label}v${below.label}`);
    }
    for (const x of predRel) if (labelRel.has(x)) rel++;
  }
  totals.labelCells += labelSets.size; totals.predCells += predCells; totals.exact += exact;
  totals.labelRel += labelRel.size; totals.predRel += predRel.size; totals.rel += rel;
  perTable.push({ paper: t.paper, page: t.page, id: t.id, cells: labelSets.size, exactRecall: exact / labelSets.size, relF1: 2 * rel / Math.max(1, labelRel.size + predRel.size) });
}
const r3 = v => Math.round(v * 1000) / 1000;
const f1 = (m, a, b) => r3(2 * m / Math.max(1, a + b));
console.log(JSON.stringify({ options, tables: totals.tables, read: r3(totals.read / Math.max(1, totals.tables)),
  cell_recall: r3(totals.exact / Math.max(1, totals.labelCells)), cell_precision: r3(totals.exact / Math.max(1, totals.predCells)), cell_f1: f1(totals.exact, totals.labelCells, totals.predCells),
  adjacency_recall: r3(totals.rel / Math.max(1, totals.labelRel)), adjacency_precision: r3(totals.rel / Math.max(1, totals.predRel)), adjacency_f1: f1(totals.rel, totals.labelRel, totals.predRel),
  tables_exact: r3(perTable.filter(p => p.exactRecall === 1).length / Math.max(1, perTable.length)) }));
if (worst) for (const p of perTable.sort((a, b) => a.relF1 - b.relF1).slice(0, worst)) console.log(JSON.stringify(p));
