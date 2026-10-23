// The inline tagger's inputs (models/inline_tagger.py raw_features and tensors_from_raw) and its spans. The host
// runs the Core ML model; everything that decides what the model sees and what its logits mean lives here.
import { median } from './geometry.ts';
import type { Glyph, TagLine, TaggerVocabulary } from './types.ts';

export const fontFamily = (font: string): string => font.replace(/^[A-Z]{6}\+/, '').replace(/\d+$/, '');

/** A font the tagger's vocabulary does not know, named as the one it reads like (fontAliases; venue templates and
 * packages set math in fonts arXiv training papers rarely used): a Latin Modern size variant as its 10 pt design
 * ("LMMathItalic6-Regular"), a math italic, symbol, extension or blackboard font by its name (MathDesign, mathabx,
 * MnSymbol, URW's Symbol) as Computer Modern's. Known fonts and unrecognised names are returned unchanged. */
export function aliasFont(font: string, vocab: { font_vocab: Record<string, number> }): string {
  const family = fontFamily(font);
  if (family in vocab.font_vocab) return font;
  const sized = family.replace(/^(LM[A-Za-z]+?)\d+(-)/, '$110$2');
  if (sized !== family && sized in vocab.font_vocab) return sized;
  const bold = /Bold/i.test(family);
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

/** The tagger's tensors for one line (at most `max_len` glyphs; features use the whole line, as the reference). */
export function tagInput(line: readonly Glyph[], vocab: TaggerVocabulary): TagLine {
  const med = median(line.map(g => g.size)) || 1.0;
  const mids = line.map(g => (g.top + g.bottom) / 2);
  const lmid = median(mids);
  const clip = (v: number) => Math.max(-2, Math.min(2, v));
  const n = Math.min(line.length, vocab.max_len);
  const fallback = vocab.default_prior ?? 0.04, unknown = vocab.unknown_index ?? 0;
  const fams = line.slice(0, n).map(g => fontFamily(g.font));
  const prior = fams.map(f => vocab.font_prior[f] ?? fallback);
  const x: number[] = [], font: number[] = [], cls: number[] = [], char: number[] = [];
  for (let i = 0; i < n; i++) {
    const g = line[i];
    const gapPrev = i > 0 ? (g.x0 - line[i - 1].x1) / med : 2.0;
    const gapNext = i + 1 < line.length ? (line[i + 1].x0 - g.x1) / med : 2.0;
    x.push(g.size / med, (mids[i] - lmid) / med, clip(gapPrev), clip(gapNext), g.upright ? 1 : 0, (g.x1 - g.x0) / med,
      prior[i], i > 0 ? prior[i - 1] : fallback, i + 1 < n ? prior[i + 1] : fallback, i === 0 ? 1 : fams[i] === fams[i - 1] ? 1 : 0);
    font.push(vocab.font_vocab[fams[i]] ?? unknown);
    const ch = firstChar(g.text);
    cls.push(charClass(ch));
    char.push(vocab.char_vocab[String(Math.min(ch.codePointAt(0)!, 0xffff))] ?? unknown);
  }
  return { x, font, cls, char };
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
