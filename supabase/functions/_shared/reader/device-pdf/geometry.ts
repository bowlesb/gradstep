// Text-layer geometry, ported rule for rule from the reference (device_pdf.py and inline_tagger.lines_of).
import { CROP_HALO, EDGE_MARGIN, LINE_GAP, PLACEHOLDER, type Box, type Glyph, type Region } from './types.ts';

/** Python's `str.strip()` truthiness for a glyph: anything but whitespace. */
export const visible = (g: Glyph): boolean => g.text.trim() !== '';

export function union(gl: Glyph[]): Box {
  let x0 = Infinity, top = Infinity, x1 = -Infinity, bottom = -Infinity;
  for (const g of gl) { if (g.x0 < x0) x0 = g.x0; if (g.top < top) top = g.top; if (g.x1 > x1) x1 = g.x1; if (g.bottom > bottom) bottom = g.bottom; }
  return [x0, top, x1, bottom];
}
export function centreIn(g: Glyph, box: readonly number[]): boolean {
  const cx = (g.x0 + g.x1) / 2, cy = (g.top + g.bottom) / 2;
  return box[0] <= cx && cx <= box[2] && box[1] <= cy && cy <= box[3];
}

/** Lines in stream order: a glyph joins the current line when its vertical extent overlaps the line's band;
 * a new line starts without overlap, or when x jumps back by more than two glyph sizes below the band. */
export function linesOf(glyphs: readonly Glyph[]): Glyph[][] {
  const lines: Glyph[][] = [];
  let cur: Glyph[] = [], top = 0, bottom = 0;
  for (const g of glyphs) {
    if (cur.length) {
      const overlap = Math.min(g.bottom, bottom) - Math.max(g.top, top) > 0;
      const back = g.x0 < cur[cur.length - 1].x0 - 2.0 * Math.max(g.size, 1.0);
      if (!overlap || (back && g.top > bottom - 1.0)) { lines.push(cur); cur = []; }
    }
    if (!cur.length) { top = g.top; bottom = g.bottom; } else { top = Math.min(top, g.top); bottom = Math.max(bottom, g.bottom); }
    cur.push(g);
  }
  if (cur.length) lines.push(cur);
  return lines;
}

/** Indices of `items` sorted by a key, stable (Python's `sorted`). */
export function argsort<T>(items: readonly T[], key: (item: T) => number): number[] {
  return items.map((_, i) => i).sort((a, b) => key(items[a]) - key(items[b]) || a - b);
}
export const byX = (gl: readonly Glyph[]): Glyph[] => argsort(gl, g => g.x0).map(i => gl[i]);

/** Words by gaps (a gap over a fifth of the glyph size), each formula span one placeholder. `spans` index `line`
 * as given; returns the text and each span's glyphs in x order (empty spans dropped). */
export function lineText(line: readonly Glyph[], spans: readonly [number, number][]): [string, Glyph[][]] {
  const inSpan = new Map<number, number>();
  spans.forEach(([s, e], k) => { for (let i = s; i < e; i++) inSpan.set(i, k); });
  const parts: string[] = [];
  const formulas: Glyph[][] = spans.map(() => []);
  let lastSpan = -1;
  const order = argsort(line, g => g.x0);
  order.forEach((g, i) => {
    const gl = line[g];
    if (i && gl.x0 - line[order[i - 1]].x1 > 0.2 * Math.max(gl.size, 1.0)) parts.push(' ');
    const k = inSpan.get(g);
    if (k === undefined) { parts.push(gl.text); lastSpan = -1; }
    else {
      formulas[k].push(gl);
      if (k !== lastSpan) { parts.push(PLACEHOLDER); lastSpan = k; }
    }
  });
  return [pyStrip(parts.join('').replace(/\s+/g, ' ')), formulas.filter(f => f.length)];
}

/** Python's `str.islower()` on the first character. */
export function startsLower(text: string): boolean {
  const ch = [...text.slice(0, 2)][0] ?? '';
  return /^\p{Lowercase}$/u.test(ch);
}
export function joinLines(lines: readonly string[]): string {
  let text = '';
  for (const ln of lines) {
    if (!ln) continue;
    if (text.endsWith('-') && startsLower(ln)) text = text.slice(0, -1) + ln;
    else text = text ? `${text} ${ln}` : ln;
  }
  return text;
}
export const pyStrip = (text: string): string => text.trim();
/** The reference's `canonical`: NFC, whitespace runs as one space, trimmed. */
export const canonicalText = (text: string): string => text.normalize('NFC').replace(/\s+/g, ' ').trim();
/** Truncate so the UTF-8 encoding is at most `limit` bytes, a cut character dropped (`clip_bytes`). */
export function clipBytes(text: string, limit: number): string {
  let bytes = 0, out = '';
  for (const ch of text) {
    const cp = ch.codePointAt(0)!; const n = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
    if (bytes + n > limit) return out;
    bytes += n; out += ch;
  }
  return out;
}
export const utf8Length = (text: string): number => {
  let n = 0; for (const ch of text) { const cp = ch.codePointAt(0)!; n += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4; } return n;
};
/** Python's `round(x, n)` closely enough for reports (ties at exact binary halves aside). */
export const pyRound = (x: number, n: number): number => Number(x.toFixed(n));
export const median = (values: readonly number[]): number => {
  const s = [...values].sort((a, b) => a - b); const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

/** Ownership step 1 and 2: the smallest-area region holding the glyph's centre, else the smallest whose box grown
 * by half the glyph's height holds it. */
export function assign(glyphs: readonly Glyph[], regions: readonly Region[]): (Region | null)[] {
  const areas = regions.map(r => (r.pt[2] - r.pt[0]) * (r.pt[3] - r.pt[1]));
  return glyphs.map(g => {
    let best: Region | null = null, ba = Infinity;
    regions.forEach((r, i) => { if (areas[i] < ba && centreIn(g, r.pt)) { best = r; ba = areas[i]; } });
    if (best === null) {
      const m = EDGE_MARGIN * Math.max(1.0, g.bottom - g.top);
      regions.forEach((r, i) => {
        const b = r.pt;
        if (areas[i] < ba && centreIn(g, [b[0] - m, b[1] - m, b[2] + m, b[3] + m])) { best = r; ba = areas[i]; }
      });
    }
    return best;
  });
}

/** Ownership step 3: an unowned glyph takes its neighbour's region along the line across a gap of at most one
 * glyph height, chained, sweeping left to right then right to left. */
export function growLines(glyphs: readonly Glyph[], owner: readonly (Region | null)[]): (Region | null)[] {
  const index = new Map<Glyph, number>(glyphs.map((g, i) => [g, i]));
  const out = [...owner];
  for (const line of linesOf(glyphs)) {
    const order = byX(line);
    for (const seq of [order, [...order].reverse()]) {
      let prev: Glyph | null = null;
      for (const g of seq) {
        const i = index.get(g)!;
        if (out[i] === null && prev !== null && out[index.get(prev)!] !== null) {
          const gap = g.x0 >= prev.x0 ? g.x0 - prev.x1 : prev.x0 - g.x1;
          if (gap <= LINE_GAP * Math.max(1.0, g.bottom - g.top)) out[i] = out[index.get(prev)!];
        }
        prev = g;
      }
    }
  }
  return out;
}

const EQUATION_TAG = /^\(?\d+[a-z]?\)?$/;
/** Lines no region reads (three glyphs or more, equation numbers aside), stacked at line spacing into blocks:
 * paragraph regions read in place. */
export function orphanRegions(glyphs: readonly Glyph[], owner: readonly (Region | null)[], s: number): Region[] {
  const free = glyphs.filter((_, i) => owner[i] === null);
  const pieces: Glyph[][] = [];
  for (const line of linesOf(free)) {
    let run: Glyph[] = [];
    for (const g of byX(line)) {
      if (run.length && g.x0 - run[run.length - 1].x1 > 2.0 * Math.max(1.0, g.bottom - g.top)) { pieces.push(run); run = []; }
      run.push(g);
    }
    if (run.length) pieces.push(run);
  }
  const lines = pieces.filter(ln => ln.filter(visible).length >= 3 && !EQUATION_TAG.test(ln.map(g => g.text).join('').trim()));
  const order = argsort(lines, ln => 0).sort((a, b) => {
    const ta = Math.min(...lines[a].map(g => g.top)), tb = Math.min(...lines[b].map(g => g.top));
    if (ta !== tb) return ta - tb;
    const xa = Math.min(...lines[a].map(g => g.x0)), xb = Math.min(...lines[b].map(g => g.x0));
    return xa - xb || a - b;
  });
  const blocks: Glyph[][][] = [];
  for (const ln of order.map(i => lines[i])) {
    const b = union(ln), h = b[3] - b[1];
    const last = blocks.length ? blocks[blocks.length - 1][blocks[blocks.length - 1].length - 1] : null;
    if (last !== null) {
      const lb = union(last);
      if (b[1] - lb[3] >= 0 && b[1] - lb[3] <= 0.8 * Math.max(1.0, h) && Math.min(b[2], lb[2]) - Math.max(b[0], lb[0]) > 0) {
        blocks[blocks.length - 1].push(ln); continue;
      }
    }
    blocks.push([ln]);
  }
  return blocks.map(blk => {
    const pt = union(blk.flat());
    return { cls: 'paragraph', score: 0, box: pt.map(v => v * s), pt, orphan: true };
  });
}

/** The recogniser crop rectangle in 150 dpi pixels, halo included, clamped to the page image (the factory cut). */
export function recogniserRect(box: Box, s: number, width: number, height: number): [number, number, number, number] {
  const x0 = Math.max(0, Math.trunc(box[0] * s) - CROP_HALO), y0 = Math.max(0, Math.trunc(box[1] * s) - CROP_HALO);
  const x1 = Math.min(width, Math.trunc(box[2] * s + 0.999) + CROP_HALO), y1 = Math.min(height, Math.trunc(box[3] * s + 0.999) + CROP_HALO);
  return [x0, y0, Math.max(x0, x1), Math.max(y0, y1)];
}
