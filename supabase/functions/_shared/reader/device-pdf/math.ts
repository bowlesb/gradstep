// The confidence gate and Temml MathML (bundle/mathml.py with arxiv_html.sanitize_mathml), mapped onto this
// reader's MathML allowlist: unknown elements are unwrapped (their text kept), annotations dropped, attributes
// kept only when the shared validator would admit them. A formula renders live only when Temml accepts it and no
// backslash is left (Temml writes an unknown command as its own text instead of failing).
import temml from 'temml';
import { el, isMathToken, MATH_ELEMENTS, mathAttributeIsSafe, parseHTML, type DomNode, type OutNode } from '../html.ts';
import { CONTROL } from '../util.ts';

/** The lowest token probability (inline) or the second lowest (display); 0 without tokens. */
export function confidence(probs: readonly number[], display: boolean): number {
  if (!probs.length) return 0;
  const s = [...probs].sort((a, b) => a - b);
  return display && s.length > 1 ? s[1] : s[0];
}

/** The recogniser's LaTeX in a form Temml takes (2026-10-21, docs/reviews/DEVICE_PDF_ROUTE_20261021.md): it learnt its
 * targets from LaTeXML, which writes an aligned group's rows with `&` and `\\` and no environment (Temml refuses a bare
 * `&`), and package commands Temml does not know (`\mathbbm{1}`, `\scalebox{s}{x}`). The meaning is unchanged. */
export function tidyLatex(latex: string): string {
  let t = latex.replace(/\\mathbbm\s*\{/g, '\\mathbb{').replace(/\\scalebox\s*\{[^{}]*\}\s*/g, '');
  if (/&|\\\\/.test(t) && !/\\begin\s*\{/.test(t)) t = `\\begin{aligned}${t}\\end{aligned}`;
  return t;
}

/** Accents as the text layer names them (spacing forms, combining marks) and as Temml writes them, to one form each. */
const ACCENTS: Record<string, string> = {
  '^': 'ˆ', 'ˆ': 'ˆ', '̂': 'ˆ', '~': '˜', '˜': '˜', '̃': '˜', '‾': '¯', '¯': '¯', '̄': '¯', '̅': '¯', '˙': '˙', '̇': '˙',
  '¨': '¨', '̈': '¨', '˚': '˚', '̊': '˚', 'ˇ': 'ˇ', '̌': 'ˇ', '˘': '˘', '̆': '˘', '´': '´', '́': '´', '`': '`', '̀': '`',
  '⃗': '→', '*': '∗', '∗': '∗', '-': '−',
};
const SYMBOLS: Record<string, string> = {
  '·': '⋅', '∙': '⋅', '⋯': '⋅⋅⋅', '◦': '∘', '\\': '∖',
  '∬': '∫∫', '∭': '∫∫∫', '∛': '3√', '∜': '4√',
};
function characters(chars: readonly string[]): string[] {
  return chars.flatMap(c => [...c]).flatMap(c => ACCENTS[c] ? [ACCENTS[c]] : [...c.normalize('NFKC')])
    .map(c => c === 'ı' ? 'i' : c === 'ȷ' ? 'j' : c === '-' ? '−' : c);
}
/** Keep the original character-evidence requirement as well as the stronger symbol check. This change narrows
 * promotions; equivalent encodings or newly counted multi-character glyphs must not admit previously refused math. */
function characterEvidence(chars: readonly string[]): string {
  return characters(chars).filter(c => /[\p{L}\p{N}=+−,;<>≤≥×∗⋆′ˆ˜¯˙¨˚ˇ˘´`→]/u.test(c)).sort().join('');
}
/** The letters, digits, accents and mathematical operators a formula shows, letters and digits folded to their plain forms
 * (𝑥, 𝐱 and ℝ as x, x and R), sorted. Delimiters, which the text layer names inconsistently (a big one has no Unicode),
 * bars and spaces are left out. Unnamed glyphs are accounted for separately. */
function checkable(chars: readonly string[]): string {
  return characters(chars)
    .flatMap(c => [...(SYMBOLS[c] ?? (/\p{Sm}/u.test(c) ? c.normalize('NFD') : c))])
    .filter(c => !/[|∣‖∥⟨⟩]/u.test(c) && /[\p{L}\p{N}\p{Sm},;′ˆ˜¯˙¨˚ˇ˘´`\u0338]/u.test(c)).sort().join('');
}
/** Count unmatched, balanced grouping delimiters in MathML. Negative or unbalanced counts are inconclusive. */
function extraDelimiters(page: readonly string[], math: readonly string[]): number | null {
  const counts = (chars: readonly string[]) => {
    const out = new Map<string, number>();
    for (const text of chars) for (const c of text.normalize('NFKC')) if ('()[]{}⟨⟩'.includes(c)) out.set(c, (out.get(c) ?? 0) + 1);
    return out;
  };
  const before = counts(page), after = counts(math);
  let accounted = 0;
  for (const [left, right] of ['()', '[]', '{}', '⟨⟩']) {
    const l = (after.get(left) ?? 0) - (before.get(left) ?? 0);
    const r = (after.get(right) ?? 0) - (before.get(right) ?? 0);
    if (l < 0 || l !== r) return null;
    accounted += l + r;
  }
  return accounted;
}
/** The named characters must all survive. Only extra mathematical operators (never letters/digits/accents) may
 * account for unnamed PDF symbols. This checks their count, not the identity of an unknown character. */
function extraOperators(page: string, math: string): number | null {
  const remaining = new Map<string, number>();
  for (const c of math) remaining.set(c, (remaining.get(c) ?? 0) + 1);
  for (const c of page) {
    const count = remaining.get(c) ?? 0;
    if (!count) return null;
    remaining.set(c, count - 1);
  }
  let count = 0;
  for (const [c, n] of remaining) {
    if (n && !/[\p{Sm}\u0338]/u.test(c)) return null;
    count += n;
  }
  return count;
}
/** verifyGlyphs: the recognised formula agrees with the PDF's named letters, digits, accents and operators, with
 * at least `min` checked characters. Every unnamed glyph must be accounted for by an unmatched operator or balanced
 * grouping delimiter in MathML. This catches an omitted integral without discarding correct large delimiters, but
 * cannot prove an unnamed symbol's identity, script/fraction structure, delimiter shape or character order.
 * See docs/reviews/DEVICE_PDF_MATH_INTEGRITY_20261026.md. */
export function glyphsAgree(pageGlyphs: readonly string[], math: OutNode, min = 2): boolean {
  if (pageGlyphs.some(t => /[\uFFFC\uFFFD]/u.test(t))) return false;
  const opaque = (t: string) => /\(cid:|\p{Co}/u.test(t);
  const unknown = pageGlyphs.filter(opaque);
  const named = pageGlyphs.filter(t => !opaque(t));
  const page = checkable(named);
  const evidence = characterEvidence(pageGlyphs.filter(t => [...t].length === 1));
  if (evidence.length < min) return false;
  const leaves: string[] = [];
  const visit = (n: OutNode | string, token: boolean) => {
    if (typeof n === 'string') { if (token) leaves.push(n); return; }
    // MathML draws radicals structurally; they are not token leaves like + or ∫.
    if (n.name === 'msqrt' || n.name === 'mroot') leaves.push('√');
    for (const c of n.children) visit(c, isMathToken(n.name));
  };
  visit(math, false);
  if (characterEvidence(leaves) !== evidence) return false;
  const candidate = checkable(leaves);
  if (!unknown.length) return candidate === page;
  const operators = extraOperators(page, candidate), delimiters = extraDelimiters(named, leaves);
  return operators !== null && delimiters !== null && operators + delimiters === unknown.length;
}

type Child = OutNode | string;
class Refused extends Error {}

/** Sanitized MathML for `latex`, or null when Temml refuses it or the result is not a rendering. */
export function renderMath(latex: string, display: boolean): OutNode | null {
  let markup: string;
  try { markup = temml.renderToString(latex, { displayMode: display, throwOnError: true, strict: false, trust: false }); }
  catch { return null; }
  let root: DomNode;
  try { root = parseHTML(markup, true); } catch { return null; }
  const top = (root.children ?? []).filter(n => !(n.type === 'text' && !n.data.trim()));
  if (top.length !== 1 || top[0].type !== 'tag' || top[0].name !== 'math') return null;
  const convert = (node: DomNode, inToken: boolean): Child[] => {
    if (node.type === 'text') {
      if (node.data.includes('\\') || CONTROL.test(node.data)) throw new Refused();
      if (inToken) return [node.data];
      return node.data.trim() ? [el('mtext', {}, [node.data])] : [];
    }
    if (node.type !== 'tag') return [];
    const name = node.name;
    if (name === 'annotation' || name === 'annotation-xml' || name === 'maligngroup' || name === 'malignmark') return [];
    if (name === 'merror') throw new Refused();
    if (name === 'semantics') {
      const first = (node.children ?? []).find(c => c.type === 'tag' && c.name !== 'annotation' && c.name !== 'annotation-xml');
      return first ? convert(first, false) : [];
    }
    const mapped = name === 'mlabeledtr' ? 'mtr' : name;
    if (!MATH_ELEMENTS.has(mapped)) return (node.children ?? []).flatMap(c => convert(c, inToken));
    const attribs: Record<string, string> = {};
    for (const [key, value] of Object.entries(node.attribs ?? {})) {
      if (value.includes('\\')) throw new Refused();
      if (value.length < 200 && mathAttributeIsSafe(mapped, key, value)) attribs[key] = value;
    }
    // Temml aligns a table's cells by class (tml-right, tml-left), which the reader drops: the column's alignment is
    // `columnalign`, as LaTeXML writes it, so an aligned group's relations line up (MATH_TABLE_CSS).
    if (mapped === 'mtd') {
      const names = (node.attribs?.class ?? '').split(/\s+/);
      if (names.includes('tml-right')) attribs.columnalign = 'right'; else if (names.includes('tml-left')) attribs.columnalign = 'left';
    }
    const token = isMathToken(mapped);
    return [el(mapped, attribs, (node.children ?? []).flatMap(c => convert(c, token)))];
  };
  try {
    const math = top[0];
    const children = (math.children ?? []).flatMap(c => convert(c, false));
    for (const [key, value] of Object.entries(math.attribs ?? {})) if (value.includes('\\')) throw new Refused();
    return el('math', display ? { display: 'block' } : {}, children);
  } catch (error) {
    if (error instanceof Refused) return null;
    throw error;
  }
}
