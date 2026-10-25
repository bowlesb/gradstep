// Aligned equations (arXiv converter component; owner, TestFlight 92: "Is this equation displayed correctly?",
// 2610.27450v1 equation (2)). LaTeXML writes align, alignat, eqnarray and flalign as an HTML table: a row per line, a
// cell per column (right- and left-aligned in turn, or right, centre and left) and a `math` in each cell. Every cell had
// become an equation of its own on its own centred line ("A_t", then "= Top-K(p_S),"), so each relation came apart.
//
// Now a group's rows are one display equation: a MathML table, a row per line, each column aligned as LaTeX aligns it
// (the relation signs under one another), wider than the screen only where a row is, its LaTeX the rows' own as
// `aligned` (an `array` naming the columns otherwise) and its number beside it. Rows numbered apart ((4) and (5)) are
// equations of their own, each with its number: a row that continues the line above (its first column empty) stays with
// it, rows before a number belong to that number and unnumbered rows after the last number to the last. Lines of one
// formula each (gather, or several equations in one group) keep their own lines; with two numbers or more each number
// now follows its own line instead of all of them following the last. A cell holding anything but formulas and words
// (a resized box, a footnote) keeps the table as it was read before.
import { classes, el, elements, normalizeSpace, textContent, type DomNode, type OutNode } from '../html.ts';
import { LIMITS } from '../profile.ts';
import { byteLength, CONTROL } from '../util.ts';
import { bind, children, has, type ArxivContext, type Child } from './context.ts';
import { equation, joinedEquation, mathLatex, mathNode } from './math.ts';

type Align = 'left' | 'right' | 'center';
type Piece = { math: DomNode } | { text: string; node: DomNode | null };
interface Cell { align: Align | null; span: number; pieces: Piece[] }
interface Row { cells: Cell[]; tag: string | null; covers: number }
interface Group { rows: Row[]; tags: string[] }

/** The empty cells LaTeXML pads a row with to centre it (or set it flush left). */
const FRAME = /^ltx_eqn_(?:center|left|right)_pad(?:left|right)$/;
const isMath = (p: Piece): p is { math: DomNode } => 'math' in p;
const formulas = (rows: Row[]) => rows.flatMap(r => r.cells.flatMap(c => c.pieces.filter(isMath).map(p => p.math)));

function tableRows(table: DomNode): DomNode[] {
  const rows: DomNode[] = [];
  for (const c of children(table)) {
    if (c.name === 'tr') rows.push(c);
    else if (['tbody', 'thead', 'tfoot'].includes(c.name)) rows.push(...children(c).filter(r => r.name === 'tr'));
  }
  return rows;
}

/** A cell's formulas and words in order, or null when it holds anything else. */
function cellPieces(td: DomNode): Piece[] | null {
  const pieces: Piece[] = [];
  for (const c of children(td)) {
    if (c.type === 'comment') continue;
    if (c.type === 'text') { if (c.data.trim()) pieces.push({ text: normalizeSpace(c.data), node: null }); continue; }
    if (c.type !== 'tag') return null;
    if (c.name === 'math') { pieces.push({ math: c }); continue; }
    // Words set as text in a cell (`\mbox`, `\textrm`: span.ltx_text.ltx_markedasmath, Batch Normalization's
    // "// mini-batch mean"); they had been left out.
    if (c.name === 'span' && children(c).every(x => x.type === 'text' || x.type === 'comment')) {
      if (textContent(c).trim()) pieces.push({ text: normalizeSpace(textContent(c)), node: c });
      continue;
    }
    return null;
  }
  return pieces;
}

function readRows(table: DomNode): Row[] | null {
  const rows: Row[] = [];
  for (const tr of tableRows(table)) {
    const cells: Cell[] = []; let tag: string | null = null, covers = 1;
    for (const td of children(tr)) {
      if (td.type !== 'tag') { if (td.type === 'text' && td.data.trim()) return null; continue; }
      if (td.name !== 'td') return null;
      if (has(td, 'ltx_eqn_eqno')) { tag = normalizeSpace(textContent(td)) || null; covers = Math.max(1, Number(td.attribs.rowspan) || 1); continue; }
      if (classes(td).some(c => FRAME.test(c))) continue;
      const pieces = cellPieces(td); if (!pieces) return null;
      const align = has(td, 'ltx_align_right') ? 'right' : has(td, 'ltx_align_left') ? 'left' : has(td, 'ltx_align_center') ? 'center' : null;
      cells.push({ align, span: Math.min(64, Math.max(1, Number(td.attribs.colspan) || 1)), pieces });
    }
    // An empty spacer row (the first row of 2312.00752v2's subequations) is no line.
    if (!tag && cells.every(c => !c.pieces.length)) continue;
    rows.push({ cells, tag, covers });
  }
  return rows;
}

/** The rows of each number: a numbered line and the lines before it, the lines its number spans and the lines continuing
 * it (first column empty); unnumbered lines after the last number stay with it. */
function groups(rows: Row[]): Group[] {
  const out: Group[] = []; let current: Group = { rows: [], tags: [] }, through = -1;
  rows.forEach((row, at) => {
    const continues = !row.cells.length || !row.cells[0].pieces.length;
    if (current.tags.length && at > through && !continues) { out.push(current); current = { rows: [], tags: [] }; }
    current.rows.push(row);
    if (row.tag) { current.tags.push(row.tag); through = Math.max(through, at + row.covers - 1); }
  });
  if (current.rows.length) {
    if (!current.tags.length && out.length) out[out.length - 1].rows.push(...current.rows);
    else out.push(current);
  }
  return out;
}

/** Each column's alignment: its filled cells' (the empty first cell of a continued line often names none). */
function columnAligns(rows: Row[]): Align[] {
  const width = Math.max(1, ...rows.map(r => r.cells.reduce((n, c) => n + c.span, 0)));
  const aligns: (Align | null)[] = new Array(width).fill(null);
  for (const filledOnly of [true, false]) for (const row of rows) {
    let column = 0;
    for (const cell of row.cells) {
      if (cell.span === 1 && cell.align && !aligns[column] && (!filledOnly || cell.pieces.length)) aligns[column] = cell.align;
      column += cell.span;
    }
  }
  return aligns.map(a => a ?? 'center');
}

const DISPLAY_STYLE = /^\s*\\displaystyle(?![A-Za-z])\s*/;
const textLatex = (text: string) => `\\text{${text.replace(/[\\{}$&#^_%~]/g, ch => ch === '\\' ? '\\textbackslash{}'
  : ch === '^' || ch === '~' ? `\\${ch}{}` : `\\${ch}`)}}`;

/** The rows' LaTeX: one line of a relation as itself, otherwise `aligned` (columns right and left in turn, each cell's
 * `\displaystyle` dropped as `aligned` sets display style) or an `array` naming each column. */
function groupLatex(rows: Row[], aligns: Align[], latexOf: Map<DomNode, string>): string {
  const alternating = aligns.every((a, n) => a === (n % 2 ? 'left' : 'right'));
  const cell = (c: Cell, keepStyle: boolean) => c.pieces.map(p => isMath(p)
    ? (keepStyle ? latexOf.get(p.math)! : latexOf.get(p.math)!.replace(DISPLAY_STYLE, '')) : textLatex(p.text)).join(' ').trim();
  if (alternating && rows.length === 1 && rows[0].cells.length <= 2) return rows[0].cells.map(c => cell(c, false)).filter(Boolean).join(' ');
  const line = (r: Row, keepStyle: boolean) => r.cells.flatMap(c => [cell(c, keepStyle), ...new Array(c.span - 1).fill('')]).join(' & ');
  if (alternating) return `\\begin{aligned}${rows.map(r => line(r, false)).join(' \\\\ ')}\\end{aligned}`;
  return `\\begin{array}{${aligns.map(a => a[0]).join('')}}${rows.map(r => line(r, true)).join(' \\\\ ')}\\end{array}`;
}

const OPERATOR = /^(?:[=<>≤≥≦≧≈≠∼≃≅≡≢∝→←↔⇒⇐⇔⟶⟵⟹⟸⟺↦≔≕≜≐≺≻⪯⪰≪≫∈∉∋⊂⊃⊆⊇⊊⊋⊢⊨≲≳≍+−±∓×∗⋆∘∙·⋅∪∩∧∨⊕⊗⊙⊖∖]|:=|=:)$/;
/** A relation or operator opening the cell after a relation's `&` is spaced as one, as LaTeX spaces `&=` (`{}=`).
 * MathML reads an `mo` that opens a row as a prefix, unspaced: 2006.11239v2's "≔" ran into the bracket before it. */
function spacedOpening(nodes: Child[]): void {
  let first = nodes.find(c => typeof c !== 'string') as OutNode | undefined;
  while (first && ['mrow', 'mstyle', 'mpadded'].includes(first.name)) first = first.children.find(c => typeof c !== 'string') as OutNode | undefined;
  if (first?.name === 'mo' && !first.attribs.form && OPERATOR.test(first.children.join('').trim())) first.attribs.form = 'infix';
}

function mathRow(row: Row, aligns: Align[]): OutNode {
  let column = 0;
  return el('mtr', {}, row.cells.map(cell => {
    const align = cell.span > 1 ? cell.align ?? 'center' : aligns[column];
    const joined = align === 'left' && column > 0 && aligns[column - 1] === 'right';
    column += cell.span;
    const content = cell.pieces.flatMap(p => isMath(p) ? children(p.math).flatMap(mathNode) : [el('mtext', {}, [p.text])]);
    if (joined) spacedOpening(content);
    return el('mtd', { columnalign: align, ...(cell.span > 1 ? { columnspan: String(cell.span) } : {}) }, content);
  }));
}

function addTag(span: OutNode, tags: string[]): void {
  span.attribs.class += ' reader-tagged';
  span.children.push(el('span', { class: 'reader-tag' }, [tags.join(' ')]));
}

/** An equation table's display equations, or null when the table reads as before (one formula per line and at most one
 * number, or a cell the reading doesn't cover); `flow` then shows each formula on its own line. */
export function equationTable(cx: ArxivContext, n: DomNode, owner: string): Child[] | null {
  if (n.name !== 'table' || !has(n, 'ltx_eqn_table')) return null;
  const rows = readRows(n);
  if (!rows?.length) return null;
  const maths = formulas(rows);
  // Every formula of the table is in a cell (none in a number or a frame cell), and none is shown elsewhere.
  if (!maths.length || maths.length !== elements(n, c => c.name === 'math').length || maths.some(m => cx.usedMath.has(m))) return null;
  const aligned = rows.some(r => r.cells.length > 1);
  if (!aligned && rows.filter(r => r.tag).length < 2) return null;
  const numbered = groups(rows);
  if (!aligned) {
    const parts: OutNode[] = [];
    for (const group of numbered) {
      const spans = formulas(group.rows).map(m => equation(cx, m, owner, true));
      if (spans.length && group.tags.length) addTag(spans[spans.length - 1], group.tags);
      parts.push(...spans);
    }
    return parts;
  }
  // A formula `equation` would refuse keeps the reading it had (and its refusal).
  const latexOf = new Map<DomNode, string>();
  for (const m of maths) { const latex = mathLatex(m); if (latex === null) return null; latexOf.set(m, latex); }
  const aligns = columnAligns(rows);
  const latexes = numbered.map(g => groupLatex(g.rows, aligns, latexOf));
  if (latexes.some(l => !l.trim() || CONTROL.test(l) || byteLength(l) > LIMITS.textBytes)) return null;
  return numbered.map((group, at) => {
    const span = joinedEquation(cx, formulas(group.rows), owner, latexes[at],
      [el('mtable', { displaystyle: 'true' }, group.rows.map(r => mathRow(r, aligns)))]);
    for (const row of group.rows) for (const cell of row.cells) for (const p of cell.pieces) if (!isMath(p) && p.node) bind(cx, p.node, span.attribs.id);
    if (group.tags.length) addTag(span, group.tags);
    return span;
  });
}
