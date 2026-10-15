// Page structure, ported from the reference: running heads and feet, first-page front matter, reading order by
// column rules (eval/reading_order.py), the author block, captions attached to floats, floats placed in the flow.
import { centreIn, lineText, linesOf, visible } from './geometry.ts';
import { FLOWISH, MARGIN, type Glyph, type Region } from './types.ts';

const DIGITS = /\p{Nd}+/gu;
const words = (text: string) => text.split(/\s+/).filter(Boolean);

/** Short lines in the top and bottom bands of a page: (text with digits removed, glyphs). */
export function marginGlyphLines(glyphs: readonly Glyph[], height: number): [string, Glyph[]][] {
  const out: [string, Glyph[]][] = [];
  for (const ln of linesOf(glyphs.filter(visible))) {
    const y = (Math.min(...ln.map(g => g.top)) + Math.max(...ln.map(g => g.bottom))) / 2;
    if (y < MARGIN * height || y > (1 - MARGIN) * height) {
      const text = lineText(ln, [])[0].replace(DIGITS, '').trim();
      const n = words(text).length;
      if (n > 0 && n <= 8) out.push([text, ln]);
    }
  }
  return out;
}

/** Running heads and feet: margin lines whose text (digits aside) recurs on three pages or more. */
export function furniture(pages: readonly { glyphs: Glyph[]; height: number }[]): Set<string> {
  const seen = new Map<string, Set<number>>();
  pages.forEach((page, p) => {
    for (const [text] of marginGlyphLines(page.glyphs, page.height)) {
      if (!seen.has(text)) seen.set(text, new Set());
      seen.get(text)!.add(p);
    }
  });
  const out = new Set<string>();
  if (pages.length >= 3) for (const [text, ps] of seen) if (ps.size >= 3) out.add(text);
  return out;
}

const FRONT_MATTER = /\b(edited by|reviewed by|correspondence|received|accepted|published|citation|copyright|open access|keywords|doi|article type|original research|specialty section|this article was submitted|approved by|competing interests?|academic editor|data availability)\b/gi;

/** A first-page region that is the journal's front-matter strip: three or more distinct markers in its text. */
export function isFrontMatter(r: Region, glyphs: readonly Glyph[]): boolean {
  if (['figure', 'table', 'title', 'display'].includes(r.cls)) return false;
  const inside = glyphs.filter(g => centreIn(g, r.pt));
  const text = linesOf(inside).map(ln => lineText(ln, [])[0]).join(' ');
  return new Set([...text.matchAll(FRONT_MATTER)].map(m => m[0].toLowerCase())).size >= 3;
}

/** A region in a page margin whose lines are all running heads or feet (or a bare page number). */
export function isFurniture(r: Region, glyphs: readonly Glyph[], pageHeight: number, known: Set<string>): boolean {
  const box = r.pt, y = (box[1] + box[3]) / 2;
  if (!(y < MARGIN * pageHeight || y > (1 - MARGIN) * pageHeight) || r.cls === 'figure' || r.cls === 'table') return false;
  const inside = glyphs.filter(g => centreIn(g, box));
  if (!inside.length) return false;
  return linesOf(inside).map(ln => lineText(ln, [])[0].replace(DIGITS, '').trim()).every(t => known.has(t) || t === '');
}

// -- reading order (eval/reading_order.py, rules v1)
const FLOW = new Set(['title', 'abstract', 'heading', 'paragraph', 'listing']);
const width = (r: Region) => r.box[2] - r.box[0];
const centre = (r: Region) => (r.box[1] + r.box[3]) / 2;
const stableSort = <T>(items: readonly T[], compare: (a: T, b: T) => number): T[] =>
  items.map((item, i) => [item, i] as const).sort((a, b) => compare(a[0], b[0]) || a[1] - b[1]).map(([item]) => item);
const byTopLeft = (a: Region, b: Region) => a.box[1] - b.box[1] || a.box[0] - b.box[0];

export function readingOrder(regions: readonly Region[], pageWidth: number): Region[] {
  const flow = regions.filter(r => FLOW.has(r.cls));
  if (!flow.length) return [];
  const widest = Math.max(...flow.map(width));
  const full = flow.filter(r => width(r) >= 0.7 * widest && width(r) >= 0.5 * pageWidth);
  const narrow = flow.filter(r => !full.includes(r));
  if (!narrow.length) return stableSort(flow, byTopLeft);
  const cuts = full.map(centre).sort((a, b) => a - b);
  const out: Region[] = [];
  let lo = -1.0;
  for (const cut of [...cuts, Infinity]) {
    out.push(...columns(narrow.filter(r => lo < centre(r) && centre(r) <= cut), pageWidth));
    out.push(...full.filter(r => centre(r) === cut));
    lo = cut;
  }
  return out;
}
function columns(members: readonly Region[], pageWidth: number): Region[] {
  if (!members.length) return [];
  const byLeft = stableSort(members, (a, b) => a.box[0] - b.box[0]);
  const cols: Region[][] = [[byLeft[0]]];
  for (const r of byLeft.slice(1)) {
    if (r.box[0] - cols[cols.length - 1][0].box[0] > 0.15 * pageWidth) cols.push([r]); else cols[cols.length - 1].push(r);
  }
  return cols.flatMap(col => stableSort(col, byTopLeft));
}

/** One page's reading order: flow by the column rules, floats after the flow region above them, captions on
 * their floats; on the first page the text between the title and the abstract (or first heading) is one
 * `authors` region read right after the title. Mutates captions it cannot attach into paragraphs, as the
 * reference does. */
export function structure(input: Region[], pageWidth: number, firstPage: boolean): Region[] {
  let regions = input;
  if (firstPage) {
    const titles = regions.filter(r => r.cls === 'title');
    const below = regions.filter(r => r.cls === 'abstract' || r.cls === 'heading');
    if (titles.length && below.length) {
      const top = Math.max(...titles.map(r => r.box[3]));
      const under = below.filter(r => r.box[1] > top);
      if (under.length) {
        const bottom = Math.min(...under.map(r => r.box[1]));
        const lines = regions.filter(r => ['paragraph', 'footnote', 'caption', 'bibitem'].includes(r.cls) && r.box[1] >= top - 2 && r.box[3] <= bottom + 2);
        if (lines.length) {
          const xs = lines.flatMap(r => [r.box[0], r.box[2]]), ys = lines.flatMap(r => [r.box[1], r.box[3]]);
          const box = [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
          const f = lines[0].box[1] ? lines[0].pt[1] / lines[0].box[1] : 1;
          const pt = box.map(v => lines[0].box[1] ? v * f : v) as Region['pt'];
          const authors: Region = { cls: 'authors', score: 1.0, box, pt, parts: lines };
          regions = [...regions.filter(r => !lines.includes(r)), authors];
        }
      }
    }
  }
  const floats = regions.filter(r => r.cls === 'figure' || r.cls === 'table');
  const captions = regions.filter(r => r.cls === 'caption');
  for (const c of captions) {
    const cb = c.box;
    let best: Region | null = null, bd = 1e9;
    for (const fl of floats) {
      const fb = fl.box;
      if (Math.min(cb[2], fb[2]) - Math.max(cb[0], fb[0]) <= 0) continue;
      const d = Math.min(Math.abs(cb[1] - fb[3]), Math.abs(fb[1] - cb[3]));
      if (d < bd) { best = fl; bd = d; }
    }
    if (best !== null && bd < 0.15 * pageWidth) (best.captions ??= []).push(c);
    else c.cls = 'paragraph';
  }
  const attached = new Set(floats.flatMap(f => f.captions ?? []));
  const flow = regions.filter(r => FLOWISH.has(r.cls) || r.cls === 'authors' || (r.cls === 'caption' && !attached.has(r))).map(r => ({ ...r, cls: ['display', 'bibitem', 'footnote', 'caption', 'authors'].includes(r.cls) ? 'paragraph' : r.cls }));
  // The reference maps the ordered copies back by box (`by_box`, the last region with that box wins): two
  // detections of one box under different classes read as the later one, twice.
  const byBox = new Map<string, Region>();
  for (const r of regions) byBox.set(r.box.join(','), r);
  const seq = readingOrder(flow, pageWidth).map(r => byBox.get(r.box.join(','))!);
  for (const fl of stableSort(floats, byTopLeft)) {
    const fb = fl.box;
    let pos = 0;
    seq.forEach((r, i) => { const rb = r.box; if (rb[3] <= fb[1] + 4 && Math.min(rb[2], fb[2]) - Math.max(rb[0], fb[0]) > 0) pos = i + 1; });
    seq.splice(pos, 0, fl);
  }
  return seq;
}
