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
/** The letters, digits, accents and plain operators a formula shows, letters and digits folded to their plain forms
 * (𝑥, 𝐱 and ℝ as x, x and R), sorted. Delimiters, which the text layer names inconsistently (a big one has no Unicode),
 * bars and spaces are left out. */
function checkable(chars: readonly string[]): string {
  return chars.flatMap(c => [...c]).flatMap(c => ACCENTS[c] ? [ACCENTS[c]] : [...c.normalize('NFKC')])
    .map(c => c === 'ı' ? 'i' : c === 'ȷ' ? 'j' : c === '-' ? '−' : c)
    .filter(c => /[\p{L}\p{N}=+−,;<>≤≥×∗⋆′ˆ˜¯˙¨˚ˇ˘´`→]/u.test(c)).sort().join('');
}
/** verifyGlyphs (2026-10-24, docs/reviews/DEVICE_PDF_WEAKNESSES_20261024.md): the recognised formula's letters and
 * digits are exactly the formula's glyphs on the page (the text layer names each one), as many of each, at least `min`
 * of them. Glyphs the text layer cannot name (`(cid:18)`, a big delimiter) and every operator, bar and space are left
 * out of both sides; what is compared is what a misreading most often changes. */
export function glyphsAgree(pageGlyphs: readonly string[], math: OutNode, min = 2): boolean {
  const page = checkable(pageGlyphs.filter(t => [...t].length === 1));
  if (page.length < min) return false;
  const leaves: string[] = [];
  const visit = (n: OutNode | string, token: boolean) => {
    if (typeof n === 'string') { if (token) leaves.push(n); return; }
    for (const c of n.children) visit(c, isMathToken(n.name));
  };
  visit(math, false);
  return checkable(leaves) === page;
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
