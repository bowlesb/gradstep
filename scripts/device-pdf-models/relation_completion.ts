// Rejected research prototype. Not imported by the reader. See training/device_pdf/README.md.
import type { Glyph } from '../../supabase/functions/_shared/reader/device-pdf/types.ts';

/** Complete an already detected scalar relation, never a new detection. The grammar is deliberately smaller
 * than mathematics: one variable, an explicit comparison, and a numeric value (optionally an uncertainty).
 * Unlike general touching-glyph expansion, it cannot grow through words or arbitrary operators. Original
 * spans that extend outside the complete relation are left alone. Coordinates and glyph identities survive. */
export function completeRelations(line: readonly Glyph[], spans: readonly [number, number][]): [number, number][] {
  if (!spans.length) return [];
  const number = '[+−-]?(?:[0-9]+(?:\\.[0-9]+)?|\\.[0-9]+)(?:[eE][+−-]?[0-9]+)?';
  const relation = new RegExp(`[A-Za-zΑ-Ωα-ω][=<>≤≥≈]${number}(?:±${number})?`, 'g');
  // One UTF-16 character per glyph keeps match offsets identical to glyph offsets; unfamiliar glyphs stop a match.
  const text = line.map(g => g.text.length === 1 ? g.text : '\ufffd').join('');
  const gap = (a: Glyph, b: Glyph) => (b.x0 - a.x1) / Math.max(a.size, b.size, 1);
  const marked = line.map((_, i) => spans.some(([a, b]) => a <= i && i < b));
  const completed: [number, number][] = [];
  for (const match of text.matchAll(relation)) {
    const a = match.index!, b = a + match[0].length;
    if (b - a > 32 || !marked.slice(a, b).some(Boolean) || marked.slice(a, b).every(Boolean)) continue;
    if (spans.some(([s, e]) => s < b && a < e && (s < a || e > b))) continue;
    const own = line.slice(a, b), prev = line[a - 1], next = line[b];
    if (own.some(g => !g.upright || /OCR/i.test(g.font) || ![g.x0, g.x1, g.top, g.bottom, g.size].every(Number.isFinite) ||
      g.size <= 0 || g.x1 <= g.x0 || g.bottom <= g.top)) continue;
    if (own.some((g, i) => i > 0 && (gap(own[i - 1], g) > 0.65 || g.x0 < own[i - 1].x0 ||
      Math.abs((g.top + g.bottom - own[i - 1].top - own[i - 1].bottom) / 2) > 0.6 * Math.max(g.size, own[i - 1].size)))) continue;
    // Do not reinterpret the end of a word, one factor of a larger expression, or a numeric prefix as complete.
    if (prev && ((/[\p{L}\p{N}]/u.test(prev.text) && gap(prev, own[0]) < 0.2) ||
      (/[+−\-*/^_=<>≤≥≈±]/.test(prev.text) && gap(prev, own[0]) < 0.65))) continue;
    if (next && ((/[\p{L}\p{N}]/u.test(next.text) && gap(own[own.length - 1], next) < 0.2) ||
      (/[+−\-*/^_=<>≤≥≈±]/.test(next.text) && gap(own[own.length - 1], next) < 0.65))) continue;
    if (next?.text === '.' && /[0-9]/.test(line[b + 1]?.text ?? '')) continue;
    if (next?.text === ',' && /[0-9]/.test(line[b + 1]?.text ?? '') && gap(next, line[b + 1]) < 0.2) continue;
    completed.push([a, b]);
  }
  if (!completed.length) return spans.map(([a, b]) => [a, b]);
  const out: [number, number][] = [];
  for (const [a, b] of [...spans, ...completed].sort((x, y) => x[0] - y[0])) {
    const last = out[out.length - 1];
    // Adjacency is not overlap: a detected trailing semicolon must not fuse two independent relations.
    if (last && a < last[1]) last[1] = Math.max(last[1], b);
    else out.push([a, b]);
  }
  return out;
}
