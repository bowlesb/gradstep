// Simple inline formulas from the PDF's own text layer (docs/reviews/DEVICE_PDF_ROUTE_20261021.md): a formula whose
// glyphs are letters, digits and plain symbols in known math fonts, on one baseline with at most one level of sub- and
// superscripts, is written as LaTeX directly instead of being read by the recogniser. The text layer names every glyph
// exactly, so these formulas are exact and cost nothing; anything else (fractions, radicals, accents, big operators,
// unknown fonts, stacked glyphs) returns null and goes to the recogniser as before.
import { byX, visible } from './geometry.ts';
import { fontFamily } from './tagger.ts';
import type { Glyph } from './types.ts';

const GREEK: Record<string, string> = {
  'α': 'alpha', 'β': 'beta', 'γ': 'gamma', 'δ': 'delta', 'ϵ': 'epsilon', 'ε': 'varepsilon', 'ζ': 'zeta', 'η': 'eta', 'θ': 'theta',
  'ϑ': 'vartheta', 'ι': 'iota', 'κ': 'kappa', 'λ': 'lambda', 'μ': 'mu', 'ν': 'nu', 'ξ': 'xi', 'π': 'pi', 'ϖ': 'varpi', 'ρ': 'rho',
  'ϱ': 'varrho', 'σ': 'sigma', 'ς': 'varsigma', 'τ': 'tau', 'υ': 'upsilon', 'ϕ': 'phi', 'φ': 'varphi', 'χ': 'chi', 'ψ': 'psi', 'ω': 'omega',
  'Γ': 'Gamma', 'Δ': 'Delta', 'Θ': 'Theta', 'Λ': 'Lambda', 'Ξ': 'Xi', 'Π': 'Pi', 'Σ': 'Sigma', 'Υ': 'Upsilon', 'Φ': 'Phi', 'Ψ': 'Psi', 'Ω': 'Omega',
};
/** Symbols as TeX writes them (the glyph's Unicode from the font's encoding or ToUnicode). */
const SYMBOL: Record<string, string> = {
  '+': '+', '=': '=', '<': '<', '>': '>', '(': '(', ')': ')', '[': '[', ']': ']', '/': '/', '|': '|', ',': ',', '.': '.', ';': ';', ':': ':',
  '!': '!', '*': '*', "'": "'", '−': '-', '-': '-', '∗': '*', '·': '\\cdot', '⋅': '\\cdot', '×': '\\times', '±': '\\pm', '∓': '\\mp',
  '≤': '\\leq', '≥': '\\geq', '≠': '\\neq', '≈': '\\approx', '∼': '\\sim', '≃': '\\simeq', '≡': '\\equiv', '∝': '\\propto', '∈': '\\in',
  '∉': '\\notin', '⊂': '\\subset', '⊆': '\\subseteq', '⊃': '\\supset', '⊇': '\\supseteq', '∪': '\\cup', '∩': '\\cap', '∅': '\\emptyset',
  '→': '\\to', '←': '\\leftarrow', '↦': '\\mapsto', '⇒': '\\Rightarrow', '⇔': '\\Leftrightarrow', '∞': '\\infty', '∂': '\\partial',
  '∇': '\\nabla', '∀': '\\forall', '∃': '\\exists', '¬': '\\neg', '∧': '\\wedge', '∨': '\\vee', 'ℓ': '\\ell', '{': '\\{', '}': '\\}',
  '⟨': '\\langle', '⟩': '\\rangle', '‖': '\\|', '∥': '\\|', '∣': '\\mid', '⊤': '\\top', '⊥': '\\perp', '†': '\\dagger', '⋆': '\\star',
  '∘': '\\circ', '…': '\\ldots', '⋯': '\\cdots', '′': '\\prime', '≪': '\\ll', '≫': '\\gg', '⊕': '\\oplus', '⊗': '\\otimes', '⊙': '\\odot',
};
const OPERATORS = new Set(['log', 'exp', 'sin', 'cos', 'tan', 'max', 'min', 'arg', 'sup', 'inf', 'lim', 'det', 'dim', 'ker', 'deg', 'ln', 'Pr']);

type Style = 'italic' | 'roman' | 'symbol' | 'blackboard' | 'bold' | 'boldItalic';
/** The font's role in math, from its name (Computer Modern, Latin Modern and the common Times math fonts); null when
 * the name does not say. */
export function mathStyle(font: string): Style | null {
  const f = fontFamily(font);
  if (/^(CMMIB|CMBSY)|BoldItalic|MathBoldItalic/i.test(f)) return 'boldItalic';
  if (/^CMMI|^LMMathItalic|^NewTXMI|^ntxmi|^txmi|^STIXTwoMath-Italic|^LibertinusMath-Italic/i.test(f)) return 'italic';
  if (/^(MSBM|msbm|bbold|NewTXBMI|txbb)/i.test(f)) return 'blackboard';
  if (/^(CMSY|LMMathSymbols|NewTXSY|ntxsy|txsy|MSAM|msam|STIXTwoMath-Regular)/i.test(f)) return 'symbol';
  if (/^(CMBX|LMRoman\d*-Bold$|NimbusRomNo9L-Medi|TeXGyreTermes-Bold$|ntxbmi)/i.test(f)) return 'bold';
  if (/^(CMR|LMRoman\d*-Regular|NimbusRomNo9L-Regu|TeXGyreTermes-Regular|NewTXRoman|ntxr|txr|Times-Roman|LinLibertineT)/i.test(f)) return 'roman';
  return null;
}

/** One glyph as a TeX token, or null when it cannot be written safely. */
function token(g: Glyph): { tex: string; letter: boolean; style: Style } | null {
  const ch = g.text;
  if ([...ch].length !== 1) return null;
  const style = mathStyle(g.font);
  if (!style) return null;
  const latin = /^[A-Za-z]$/.test(ch), digit = /^[0-9]$/.test(ch);
  if (GREEK[ch]) {
    // TeX's upright capitals come from the roman font, the italic lower case from the math italic; anything else (a
    // bold or an italic capital) is a style this rule does not write.
    const upper = /\p{Lu}/u.test(ch);
    if ((upper && style === 'roman') || (!upper && style === 'italic')) return { tex: `\\${GREEK[ch]}`, letter: false, style };
    return null;
  }
  if (latin) {
    if (style === 'italic') return { tex: ch, letter: false, style };
    if (style === 'roman') return { tex: ch, letter: true, style };
    if (style === 'blackboard' && /[A-Z]/.test(ch)) return { tex: `\\mathbb{${ch}}`, letter: false, style };
    if (style === 'symbol' && /[A-Z]/.test(ch)) return { tex: `\\mathcal{${ch}}`, letter: false, style };
    if (style === 'bold') return { tex: `\\mathbf{${ch}}`, letter: false, style };
    if (style === 'boldItalic') return { tex: `\\boldsymbol{${ch}}`, letter: false, style };
    return null;
  }
  if (digit) return style === 'roman' || style === 'italic' ? { tex: ch, letter: false, style } : style === 'bold' ? { tex: `\\mathbf{${ch}}`, letter: false, style } : null;
  if (SYMBOL[ch] !== undefined && style !== 'bold' && style !== 'boldItalic' && style !== 'blackboard') return { tex: SYMBOL[ch], letter: false, style };
  return null;
}

/** LaTeX for an inline formula's glyphs, or null (the recogniser reads it). `size` is the line's median glyph size. */
export function transcribe(glyphs: readonly Glyph[], size: number): string | null {
  const gl = byX(glyphs.filter(visible));
  if (!gl.length || gl.length > 24 || !(size > 0)) return null;
  const tokens = gl.map(token);
  if (tokens.some(t => t === null)) return null;
  // The base size: the formula's own largest glyphs (a script-only formula has none at the line's size).
  const big = Math.max(...gl.map(g => g.size));
  if (big < 0.85 * size || big > 1.25 * size) return null;
  const mains = gl.filter(g => g.size >= 0.85 * big);
  const centre = (g: Glyph) => (g.top + g.bottom) / 2;
  const mainCentre = mains.map(centre).sort((a, b) => a - b)[mains.length >> 1];
  // Every full-size glyph on one line: a stacked formula (a fraction set in text style, a matrix) is not this rule's.
  if (mains.some(g => Math.abs(centre(g) - mainCentre) > 0.12 * big)) return null;
  type Part = { role: 'main' | 'sub' | 'sup'; g: Glyph; tex: string; letter: boolean };
  const parts: Part[] = [];
  for (let i = 0; i < gl.length; i++) {
    const g = gl[i], t = tokens[i]!;
    let role: Part['role'] = 'main';
    if (g.size < 0.85 * big) {
      if (g.size < 0.6 * big) return null; // a script of a script
      const shift = centre(g) - mainCentre;
      if (shift < -0.12 * big) role = 'sup'; else if (shift > 0.08 * big) role = 'sub'; else return null;
    }
    parts.push({ role, g, tex: t.tex, letter: t.letter });
  }
  // No two full-size glyphs overlap (an accent, a slash through a letter, an overprint).
  for (let i = 1; i < parts.length; i++) {
    const a = parts[i - 1], b = parts[i];
    if (a.role === 'main' && b.role === 'main' && b.g.x0 < a.g.x1 - 0.15 * big) return null;
  }
  let out = '', pendingRoman = '';
  const flushRoman = () => {
    if (!pendingRoman) return;
    out += pendingRoman.length === 1 ? `\\mathrm{${pendingRoman}}` : OPERATORS.has(pendingRoman) ? `\\${pendingRoman}` : `\\mathrm{${pendingRoman}}`;
    pendingRoman = '';
  };
  let lastMain: Part | null = null, i = 0;
  while (i < parts.length) {
    const p = parts[i];
    if (p.role === 'main') {
      if (p.letter) pendingRoman += p.tex; else { flushRoman(); out += needsSpace(out, p.tex) ? ` ${p.tex}` : p.tex; }
      lastMain = p; i++; continue;
    }
    // Scripts follow a full-size glyph closely (TeX sets them against the base; a fraction stands apart, after the
    // null delimiter space).
    if (!lastMain || p.g.x0 - lastMain.g.x1 > 0.12 * big) return null;
    flushRoman();
    const groups: Record<'sub' | 'sup', Part[]> = { sub: [], sup: [] };
    while (i < parts.length && parts[i].role !== 'main') { groups[parts[i].role as 'sub' | 'sup'].push(parts[i]); i++; }
    for (const role of ['sub', 'sup'] as const) {
      const run = groups[role];
      if (!run.length) continue;
      out += role === 'sub' ? `_{${write(run)}}` : `^{${write(run)}}`;
    }
    // Scripts that overlap in x but are not a sub and sup pair, or sit far apart, are not this rule's.
    if (groups.sub.length && groups.sup.length && Math.abs(groups.sub[0].g.x0 - groups.sup[0].g.x0) > 0.25 * big) return null;
  }
  flushRoman();
  out = out.trim();
  // A formula that is only punctuation is the tagger's mistake, not math.
  if (!/[A-Za-z0-9\\]/.test(out)) return null;
  return out;
}

/** Math the tagger did not mark, found by its fonts (table cells, where a line is a few glyphs with little context for
 * the tagger): maximal runs of glyphs in math fonts, with the digits and operators between them, that `transcribe`
 * can write. `line` is in x order; returns [start, end) spans of it that do not overlap `taken`. */
export function mathRuns(line: readonly Glyph[], taken: readonly [number, number][] = []): [number, number][] {
  const busy = new Set<number>();
  for (const [s, e] of taken) for (let i = s; i < e; i++) busy.add(i);
  const kind = (g: Glyph): 'math' | 'neutral' | 'text' => {
    const style = mathStyle(g.font);
    if (style === 'italic' || style === 'symbol' || style === 'blackboard' || style === 'boldItalic') return 'math';
    if (style === 'roman' && /^[0-9=+\-−()[\],./<>|:;!*']$/.test(g.text)) return 'neutral';
    return 'text';
  };
  const spans: [number, number][] = [];
  let i = 0;
  while (i < line.length) {
    if (busy.has(i) || kind(line[i]) === 'text' || !visible(line[i])) { i++; continue; }
    let j = i;
    while (j < line.length && !busy.has(j) && kind(line[j]) !== 'text' && visible(line[j])
      && (j === i || line[j].x0 - line[j - 1].x1 < 0.4 * Math.max(line[j].size, 1))) j++;
    // Not a run that is only digits and punctuation (a number in a cell is text), nor ends of punctuation.
    let s = i, e = j;
    while (s < e && /^[,.;:]$/.test(line[s].text)) s++;
    while (e > s && /^[,.;:]$/.test(line[e - 1].text)) e--;
    // A run against a span the tagger found is part of that formula (the tagger cut its boundary), not a formula of its own.
    const touches = (k: number, edge: Glyph, before: boolean) => k >= 0 && k < line.length && busy.has(k)
      && (before ? edge.x0 - line[k].x1 : line[k].x0 - edge.x1) < 0.4 * Math.max(edge.size, 1);
    const against = e > s && (touches(s - 1, line[s], true) || touches(e, line[e - 1], false));
    if (e > s && !against && line.slice(s, e).some(g => kind(g) === 'math') && transcribe(line.slice(s, e), Math.max(...line.slice(s, e).map(g => g.size)))) spans.push([s, e]);
    i = Math.max(j, i + 1);
  }
  return spans;
}

/** Tokens in order: runs of upright letters as one `\mathrm{…}` or operator name, control words kept apart. */
function write(run: readonly { tex: string; letter: boolean }[]): string {
  let out = '', roman = '';
  const flush = () => {
    if (!roman) return;
    const t = OPERATORS.has(roman) ? `\\${roman}` : `\\mathrm{${roman}}`;
    out += needsSpace(out, t) ? ` ${t}` : t; roman = '';
  };
  for (const r of run) {
    if (r.letter) { roman += r.tex; continue; }
    flush();
    out += needsSpace(out, r.tex) ? ` ${r.tex}` : r.tex;
  }
  flush();
  return out;
}

/** A space keeps a control word from running into the letter after it (`\in x`, not `\inx`). */
const needsSpace = (before: string, next: string): boolean => /\\[A-Za-z]+$/.test(before) && /^[A-Za-z]/.test(next);
