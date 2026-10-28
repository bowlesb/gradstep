// The inline tagger's inputs (models/inline_tagger.py raw_features and tensors_from_raw) and its spans. The host
// runs the Core ML model; everything that decides what the model sees and what its logits mean lives here.
import { median } from './geometry.ts';
import { check } from '../util.ts';
import type { Glyph, TagLine, TaggerVocabulary } from './types.ts';

export const fontFamily = (font: string): string => font.replace(/^[A-Z]{6}\+/, '').replace(/\d+$/, '');

/** A font the tagger's vocabulary does not know, named as the one it reads like (fontAliases; venue templates and
 * packages set math in fonts arXiv training papers rarely used): a Latin Modern size variant as its 10 pt design
 * ("LMMathItalic6-Regular"), a math italic, symbol, extension or blackboard font by its name (MathDesign, mathabx,
 * MnSymbol, URW's Symbol) as Computer Modern's. Known fonts and unrecognised names are returned unchanged. */
/** Characters a font's broken Unicode mapping names wrongly, by font family (fontAliases): PLOS's Computer Modern symbols
 * map the parentheses to ð Þ and the equals sign to ¼ (PLOS Comput Biol 2024). */
const MISNAMED: Record<string, Record<string, string>> = { TeX_CM_Maths_Symbols: { 'ð': '(', 'Þ': ')', '¼': '=' } };
export function aliasText(text: string, font: string): string { return MISNAMED[fontFamily(font)]?.[text] ?? text; }

export function aliasFont(font: string, vocab: { font_vocab: Record<string, number> }): string {
  const family = fontFamily(font);
  if (family in vocab.font_vocab) return font;
  const sized = family.replace(/^(LM[A-Za-z]+?)\d+(-)/, '$110$2');
  if (sized !== family && sized in vocab.font_vocab) return sized;
  const bold = /Bold/i.test(family);
  // PLOS's typesetting embeds Computer Modern under its own names.
  const plos = /^TeX_CM_Maths_(Symbols|Italic|Extension)/.exec(family);
  if (plos) return plos[1] === 'Symbols' ? 'CMSY10' : plos[1] === 'Italic' ? 'CMMI10' : 'CMEX10';
  if (/Math.?Italic|MathMI|-MI$|^TeX-mathi/i.test(family)) return bold ? 'CMMIB10' : 'CMMI10';
  if (/Blackboard|DoubleStruck|^bbold|^dsrom|^msbm/i.test(family)) return 'MSBM10';
  if (/Extension|-EX$|^TeX-mathx|MathEX/i.test(family)) return 'CMEX10';
  if (/Math.?Symbol|Symbol(A|B)?-?$|MathDesignSymbol|-SY$|^TeX-math[ab]|^MnSymbol|^StandardSymL|^Cmsy$/i.test(family)) return bold ? 'CMBSY10' : 'CMSY10';
  if (/^MathDesign-.*-(OT1|T1)-?$/i.test(family)) return 'CMR10';
  return font;
}

// Python's str.isdigit(): decimal digits and the Unicode "Digit" numerics (superscripts, circled digits).
const DIGIT = /^[\p{Nd}²³¹⁰⁴-⁹₀-₉①-⑨⑴-⑼⒈-⒐⓪⓵-⓽⓿❶-❾➀-➈➊-➒]$/u;
export function charClass(ch: string): number {
  if (DIGIT.test(ch)) return 1;
  if (/^\p{L}$/u.test(ch)) {
    const o = ch.codePointAt(0)!;
    if (o >= 0x370 && o <= 0x3ff) return 4;
    return /^\p{Lowercase}$/u.test(ch) ? 2 : 3; // Python's islower(): the Lowercase property (math italic 𝑑 is lower)
  }
  if ('.,;:'.includes(ch)) return 5;
  if ('()[]{}'.includes(ch)) return 6;
  if ('+-=<>*/|~^_'.includes(ch)) return 7;
  if (/^\s$/u.test(ch)) return 8;
  return 9;
}
const firstChar = (text: string): string => { const ch = String.fromCodePoint(text.codePointAt(0) ?? 32); return text ? ch : ' '; };

/** Geometry is measured against the original line, including when that line needs several model windows. */
function rawFeatures(line: readonly Glyph[]): number[][] {
  const med = median(line.map(g => g.size)) || 1.0;
  const mids = line.map(g => (g.top + g.bottom) / 2);
  const lmid = median(mids);
  const clip = (v: number) => Math.max(-2, Math.min(2, v));
  return line.map((g, i) => {
    const gapPrev = i > 0 ? (g.x0 - line[i - 1].x1) / med : 2.0;
    const gapNext = i + 1 < line.length ? (line[i + 1].x0 - g.x1) / med : 2.0;
    return [g.size / med, (mids[i] - lmid) / med, clip(gapPrev), clip(gapNext), g.upright ? 1 : 0, (g.x1 - g.x0) / med];
  });
}

export interface TagWindow {
  input: TagLine;
  /** Positions in the original line covered by this window (context is excluded). */
  from: number; to: number;
  /** The corresponding output-logit range, after the preceding context. */
  own: [number, number];
}

/** Cover every glyph once. v5 adds previous/next context and two flag columns; v4 keeps ten columns. Context for
 * a long line comes from its adjacent windows. Short inputs exactly match the exported model's training contract. */
export function tagWindows(line: readonly Glyph[], vocab: TaggerVocabulary, prev?: readonly Glyph[] | null, next?: readonly Glyph[] | null): TagWindow[] {
  const k = vocab.context ?? 0, maximum = vocab.max_len;
  check(Number.isSafeInteger(maximum) && maximum >= 2 && maximum <= 400 && Number.isSafeInteger(k) && k >= 0 && 2 * k <= maximum - 2, 'device_pdf_tagger');
  if (!line.length) return [];
  const raw = rawFeatures(line);
  const before = k && prev ? prev.slice(-k) : [], beforeRaw = k && prev ? rawFeatures(prev).slice(-k) : [];
  const after = k && next ? next.slice(0, k) : [], afterRaw = k && next ? rawFeatures(next).slice(0, k) : [];
  const fallback = vocab.default_prior ?? 0.04, unknown = vocab.unknown_index ?? 0;
  const build = (from: number, to: number, pre: readonly Glyph[], preRaw: number[][], post: readonly Glyph[], postRaw: number[][]): TagWindow => {
    const glyphs = [...pre, ...line.slice(from, to), ...post], features = [...preRaw, ...raw.slice(from, to), ...postRaw];
    const own: [number, number] = [pre.length, pre.length + to - from];
    const fams = glyphs.map(g => fontFamily(g.font)), prior = fams.map(f => vocab.font_prior[f] ?? fallback);
    const x: number[] = [], font: number[] = [], cls: number[] = [], char: number[] = [];
    glyphs.forEach((g, i) => {
      x.push(...features[i], prior[i], i ? prior[i - 1] : fallback, i + 1 < glyphs.length ? prior[i + 1] : fallback, i === 0 || fams[i] === fams[i - 1] ? 1 : 0);
      if (k) x.push(i < own[0] ? 1 : 0, i >= own[1] ? 1 : 0);
      font.push(vocab.font_vocab[fams[i]] ?? unknown);
      const ch = firstChar(g.text);
      cls.push(charClass(ch)); char.push(vocab.char_vocab[String(Math.min(ch.codePointAt(0)!, 0xffff))] ?? unknown);
    });
    return { input: { x, font, cls, char }, from, to, own };
  };
  if (line.length + before.length + after.length <= maximum) return [build(0, line.length, before, beforeRaw, after, afterRaw)];
  const out: TagWindow[] = [], capacity = maximum - 2 * k;
  for (let from = 0; from < line.length; from += capacity) {
    const to = Math.min(line.length, from + capacity);
    // The model accepts at least two glyphs. A v4 one-glyph tail borrows one preceding glyph, whose logit is ignored.
    const left = from && !k && to - from === 1 ? from - 1 : Math.max(0, from - k);
    out.push(build(from, to, from ? line.slice(left, from) : before, from ? raw.slice(left, from) : beforeRaw,
      to < line.length ? line.slice(to, to + k) : after, to < line.length ? raw.slice(to, to + k) : afterRaw));
  }
  return out;
}

/** One bounded input, retained for v4 fixture compatibility. Conversion uses all tagWindows, including the tail. */
export function tagInput(line: readonly Glyph[], vocab: TaggerVocabulary): TagLine {
  return tagWindows(line, vocab)[0]?.input ?? { x: [], font: [], cls: [], char: [] };
}

/** Runs of glyphs whose sigmoid(logit) passes the threshold, as (start, end) ranges. */
export function spansOf(logits: readonly number[], threshold: number): [number, number][] {
  const out: [number, number][] = [];
  let start: number | null = null;
  for (let i = 0; i <= logits.length; i++) {
    const on = i < logits.length && 1 / (1 + Math.exp(-logits[i])) > threshold;
    if (on && start === null) start = i;
    if (!on && start !== null) { out.push([start, i]); start = null; }
  }
  return out;
}
