// Math (arXiv converter component): formulas as sanitized MathML with their LaTeX in the index, and the coverage rule
// that every `math` element of the paper is either rendered or deliberately left out with what carried it.
import { el, elements, isMathToken, MATH_ELEMENTS, mathAttributeIsSafe, normalizeSpace, textContent, type DomNode, type OutNode } from '../html.ts';
import { LIMITS } from '../profile.ts';
import { boundedText, byteLength, check, CONTROL, ReaderRenderError } from '../util.ts';
import { bind, children, type ArxivContext, type Child } from './context.ts';
import { mathBadgeText } from './math-badge.ts';
import { applyMathVariant } from '../mathvariant.ts';
import { readerAccent } from '../accents.ts';

// HTML phrasing LaTeXML leaves inside a formula's text: a citation in `\text{…}` (revision 29, 2610.37645v1's display
// "Attention (Vaswani et al., 2017): O = softmax(QKᵀ+M)V", whose `cite` refused the paper `arxiv_math_element` on the
// fresh-paper sweep). Its words are the text of the token around it, or a text token of their own.
const MATH_PHRASING = new Set(['cite', 'em', 'i', 'b', 'strong', 'u', 's', 'small', 'big', 'tt', 'code', 'q', 'abbr', 'var',
  'kbd', 'samp', 'mark', 'font', 'sub', 'sup']);
/** Whether a node sits inside a MathML token (`mi`, `mo`, `mn`, `mtext`, `ms`), past any HTML wrappers. */
function inToken(n: DomNode): boolean {
  for (let p = n.parent; p; p = p.parent) if (p.type === 'tag' && (MATH_ELEMENTS.has(p.name) || p.name === 'semantics')) return isMathToken(p.name);
  return false;
}

/** LaTeXML's presentation MathML in the reader's vocabulary: annotations and links dropped, attributes allow-listed. */
export function mathNode(n: DomNode): Child[] {
  if (n.type === 'text') return n.data.trim() || isMathToken(n.parent?.name ?? '') ? [n.data] : [];
  if (n.name === 'annotation' || n.name === 'annotation-xml') return [];
  if (n.name === 'svg') return [mathBadgeText(n)];
  if (n.name === 'a' || n.name === 'span') return children(n).flatMap(mathNode);
  if (MATH_PHRASING.has(n.name)) {
    const words = children(n).flatMap(mathNode);
    return words.length && !inToken(n) && words.every(w => typeof w === 'string') ? [el('mtext', {}, words)] : words;
  }
  if (n.name === 'semantics') {
    const presentation = children(n).filter(c => c.type === 'tag' && !['annotation', 'annotation-xml'].includes(c.name));
    check(presentation.length === 1, 'arxiv_math_semantics');
    return mathNode(presentation[0]);
  }
  check(MATH_ELEMENTS.has(n.name) && n.name !== 'math', 'arxiv_math_element');
  const attrs: Record<string, string> = {};
  for (const [key, value] of Object.entries(n.attribs ?? {})) {
    if (['class', 'id', 'intent', 'alttext', 'xref', 'xmlns'].includes(key)) continue;
    if (key === 'style') {
      // LaTeXML mirrors a few presentation attributes as CSS. Never retain
      // source CSS; translate only this finite scalar vocabulary. Anything
      // else is left out, never refused: one `vertical-align:-2.1pt` on one
      // formula refused all of 2606.05868 (owner, 2026-10-15: "Couldn't open
      // this paper"). The formula keeps its content; only that styling goes.
      for (const declaration of value.split(';').map(v => v.trim()).filter(Boolean)) {
        const match = /^(width|height|depth|font-size|--ltx-fg-color|--ltx-bg-color):\s*([A-Za-z0-9 .%#+-]+)$/.exec(declaration);
        if (!match) continue;
        // The reader owns its colours: a source colour or background (a boxed ± in 2610.18683's tables, a teal
        // dagger) is left out, as the HTML's own colours are.
        if (match[1] === '--ltx-fg-color' || match[1] === '--ltx-bg-color') continue;
        const attr = match[1] === 'font-size' ? 'mathsize' : match[1];
        if (mathAttributeIsSafe(n.name, attr, match[2])) attrs[attr] = match[2];
      }
      continue;
    }
    if (key === 'mathcolor' || key === 'mathbackground') continue;
    // An attribute outside the allow-list (or with an unsafe value) is left out, as unknown styling is.
    if (mathAttributeIsSafe(n.name, key, value)) attrs[key] = value;
  }
  // An accent in the form every engine draws over its letter (accents.ts).
  return [readerAccent(el(n.name, attrs, children(n).flatMap(mathNode)))];
}
// A formula in a heading as words (revision 24, 2610.21306v1 "VLA-$\Delta$: …" on the fresh-paper sweep): the index
// writes an equation as its LaTeX, and a heading's index text is its title in the Library header, Contents and the
// page's <title>, so "VLA- \Delta : Learning…" showed the macro. A formula that Unicode spells exactly (letters,
// digits, operators, and sub- or superscripts Unicode has: "Δ", "τ²", "𝒮₀", "λ < 1", "↓") is text in the heading, a
// one-letter variable in italics; anything else (a fraction, "p_T", "r_{novelty}") stays an equation.
const SUPERSCRIPT: Record<string, string> = { '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴', '5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹',
  '+': '⁺', '-': '⁻', '−': '⁻', '=': '⁼', '(': '⁽', ')': '⁾', n: 'ⁿ', i: 'ⁱ', '⊤': 'ᵀ', T: 'ᵀ',
  // Marks that already sit high: a prime, a star, a dagger.
  '′': '′', '″': '″', '‴': '‴', '*': '*', '∗': '*', '⋆': '⋆', '†': '†', '‡': '‡' };
const SUBSCRIPT: Record<string, string> = { '0': '₀', '1': '₁', '2': '₂', '3': '₃', '4': '₄', '5': '₅', '6': '₆', '7': '₇', '8': '₈', '9': '₉',
  '+': '₊', '-': '₋', '−': '₋', '=': '₌', '(': '₍', ')': '₎', a: 'ₐ', e: 'ₑ', h: 'ₕ', i: 'ᵢ', j: 'ⱼ', k: 'ₖ', l: 'ₗ', m: 'ₘ',
  n: 'ₙ', o: 'ₒ', p: 'ₚ', r: 'ᵣ', s: 'ₛ', t: 'ₜ', u: 'ᵤ', v: 'ᵥ', x: 'ₓ', β: 'ᵦ', γ: 'ᵧ', ρ: 'ᵨ', φ: 'ᵩ', χ: 'ᵪ' };
const SPACED = new Set(['=', '<', '>', '≤', '≥', '≈', '≠', '∼', '≡', '∝', '→', '←', '↔', '⇒', '⇐', '⇔', '∈', '+', '−', '×', '·', '⋅', '±', '∓', '⊕', '⊗']);
const INVISIBLE = /[​⁡-⁤]/g;
const TOKENS = new Set(['mi', 'mn', 'mo', 'mtext']), GROUPS = new Set(['mrow', 'mstyle', 'mpadded']);
const elementChildren = (n: DomNode) => children(n).filter(c => c.type === 'tag' && !['annotation', 'annotation-xml'].includes(c.name));
/** A token's characters, mapped through its mathvariant; null when Unicode has no such letter. */
function tokenText(n: DomNode): string | null {
  const text = textContent(n).replace(INVISIBLE, '').trim(), variant = n.attribs.mathvariant;
  return !variant || variant === 'normal' || variant === 'italic' ? text : applyMathVariant(text, variant);
}
/** A script's characters in Unicode's sub- or superscript forms, or null. */
function scriptText(n: DomNode, map: Record<string, string>): string | null {
  const parts: string[] = [];
  const visit = (c: DomNode): boolean => {
    if (c.type === 'text') return !c.data.trim();
    if (c.type !== 'tag') return true;
    if (TOKENS.has(c.name)) { const text = tokenText(c); if (text === null) return false; parts.push(text); return true; }
    return GROUPS.has(c.name) && children(c).every(visit);
  };
  if (!visit(n)) return null;
  const chars = [...parts.join('').replace(/\s+/g, '')];
  return chars.length && chars.every(ch => map[ch] !== undefined) ? chars.map(ch => map[ch]).join('') : null;
}
export function mathAsText(n: DomNode): Child[] | null {
  const convert = (c: DomNode): Child[] | null => {
    if (c.type === 'text') return c.data.trim() ? null : [];
    if (c.type !== 'tag' || ['annotation', 'annotation-xml'].includes(c.name)) return [];
    if (c.name === 'math' || c.name === 'semantics' || GROUPS.has(c.name)) {
      const kids = elementChildren(c), out: Child[] = [];
      for (const [at, kid] of kids.entries()) {
        const part = convert(kid); if (!part) return null;
        // A relation or binary operator between two operands reads with spaces around it ("λ < 1", "D5 × D8"), as the
        // formula sets it; a sign after an operator or a bracket ("(−1)") does not.
        const operand = (x: DomNode | undefined, fences: string) => !!x && (x.name !== 'mo' || fences.includes(normalizeSpace(textContent(x))));
        const spaced = kid.name === 'mo' && SPACED.has(normalizeSpace(textContent(kid))) && operand(kids[at - 1], ')]}|')
          && operand(kids[at + 1], '([{|') && kid.attribs.lspace !== '0em' && kid.attribs.rspace !== '0em';
        out.push(...(spaced ? [' ', ...part, ' '] : part));
      }
      return out;
    }
    if (TOKENS.has(c.name)) {
      const text = tokenText(c); if (text === null) return null;
      if (!text) return [];
      // A one-letter Latin or Greek identifier is a variable, set in italics unless the formula says upright ("Δ" is
      // mathvariant normal); a styled letter ("𝒮") already carries its face.
      const italic = c.name === 'mi' && (c.attribs.mathvariant === 'italic' || (!c.attribs.mathvariant && /^[A-Za-zΑ-ωϑϕϵ]$/u.test(text)));
      return [italic ? el('em', {}, [text]) : text];
    }
    if (c.name === 'mspace') return [' '];
    if (['msub', 'msup', 'msubsup'].includes(c.name)) {
      const [base, first, second] = elementChildren(c);
      const head = base ? convert(base) : null;
      const sub = c.name === 'msup' ? '' : first ? scriptText(first, SUBSCRIPT) : null;
      const sup = c.name === 'msub' ? '' : c.name === 'msup' ? (first ? scriptText(first, SUPERSCRIPT) : null) : second ? scriptText(second, SUPERSCRIPT) : null;
      if (!head || sub === null || sup === null) return null;
      return [...head, sub + sup];
    }
    return null;
  };
  const out = convert(n);
  return out && out.some(part => typeof part !== 'string' || part.trim()) ? out : null;
}

/** The LaTeX LaTeXML wrote for a formula: its alttext, else its one TeX annotation ('' when it wrote none). */
function givenLatex(n: DomNode, annotations: DomNode[]): string {
  return n.attribs.alttext?.trim() ? n.attribs.alttext : annotations.length === 1 ? textContent(annotations[0]) : '';
}
const texAnnotations = (n: DomNode) => elements(n, c => c.name === 'annotation' && c.attribs.encoding === 'application/x-tex');

/** A formula's LaTeX read back from its MathML, for a formula LaTeXML wrote without any (revision 29, 2610.37481v1's
 * boxed "15" in Table 4: no alttext and no annotation, which refused the paper `arxiv_math_source`). Tokens, rows,
 * scripts, fractions, roots, under- and overscripts; any other element reads as the LaTeX of its children. The index
 * needs a LaTeX for every equation; the reader still draws the MathML. */
export function latexFromMathML(n: DomNode): string {
  const parts = (c: DomNode) => children(c).filter(x => x.type === 'tag' && !['annotation', 'annotation-xml'].includes(x.name)).map(read);
  const group = (s = '') => [...s].length === 1 ? s : `{${s}}`;
  function read(c: DomNode): string {
    if (c.type !== 'tag') return '';
    const r = parts(c);
    switch (c.name) {
      case 'mi': case 'mn': case 'mo': case 'ms': return normalizeSpace(textContent(c));
      case 'mtext': { const words = normalizeSpace(textContent(c)); return words ? `\\text{${words}}` : ''; }
      case 'mspace': return '\\ ';
      case 'msub': return `${group(r[0])}_${group(r[1])}`;
      case 'msup': return `${group(r[0])}^${group(r[1])}`;
      case 'msubsup': return `${group(r[0])}_${group(r[1])}^${group(r[2])}`;
      case 'mfrac': return `\\frac{${r[0] ?? ''}}{${r[1] ?? ''}}`;
      case 'msqrt': return `\\sqrt{${r.join(' ')}}`;
      case 'mroot': return `\\sqrt[${r[1] ?? ''}]{${r[0] ?? ''}}`;
      case 'munder': return `\\underset{${r[1] ?? ''}}{${r[0] ?? ''}}`;
      case 'mover': return `\\overset{${r[1] ?? ''}}{${r[0] ?? ''}}`;
      case 'munderover': return `\\underset{${r[1] ?? ''}}{\\overset{${r[2] ?? ''}}{${r[0] ?? ''}}}`;
      default: return r.filter(Boolean).join(' ');
    }
  }
  return normalizeSpace(read(n));
}

// Why a formula's MathML can't be drawn in the reader's vocabulary (an element outside it, a picture in a formula that
// isn't a text badge, a `semantics` without one presentation): the formula then shows its LaTeX, never refusing the paper
// (revision 29; a refusal is a first-open failure).
const UNDRAWN = new Set(['arxiv_math_element', 'arxiv_math_semantics']);
/** A formula's MathML in the reader's vocabulary, or null when the reader can't draw it. */
export function drawnMath(n: DomNode): Child[] | null {
  try {
    return children(n).flatMap(mathNode);
  } catch (error) {
    if (error instanceof ReaderRenderError && UNDRAWN.has(error.code)) return null;
    throw error;
  }
}

/** One formula: its LaTeX source in the index, its MathML in an equation span (forced display in an equation block).
 * A formula the reader can't draw shows its LaTeX (`reader-math-fallback`, the shared vocabulary's text form). */
export function equation(cx: ArxivContext, n: DomNode, owner: string, forceDisplay = false): OutNode {
  check(!cx.usedMath.has(n), 'arxiv_math_duplicate'); cx.usedMath.add(n);
  const annotations = texAnnotations(n), given = givenLatex(n, annotations);
  const latex = boundedText(given.trim() ? given : latexFromMathML(n), LIMITS.textBytes, 'arxiv_math_source');
  check(latex.trim().length > 0 && cx.equations.length < LIMITS.equations, 'arxiv_math_source');
  if (annotations.length && given.trim()) check(annotations.length === 1 && normalizeSpace(textContent(annotations[0])) === normalizeSpace(latex), 'arxiv_math_mismatch');
  const display = forceDisplay || n.attribs.display === 'block';
  const id = `e-${cx.digest}-${cx.equations.length + 1}`; bind(cx, n, id);
  const form = /^\s*\\begin\{(?:equation\*?|align\*?|gather\*?|multline\*?)\}/.test(latex) ? 'environment' : 'body';
  check(form !== 'environment' || display, 'arxiv_math_source');
  cx.equations.push({ id, block_id: owner, latex, display, source_form: form });
  const kind = `reader-equation ${display ? 'reader-display' : 'reader-inline'}`;
  const body = drawnMath(n);
  if (!body?.length) return el('span', { id, 'data-reader-equation': id, 'data-latex': latex, class: `${kind} reader-math-fallback` }, [display ? latex : `\\(${latex}\\)`]);
  return el('span', { id, 'data-reader-equation': id, 'data-latex': latex, class: kind }, [el('math', display ? { display: 'block' } : {}, body)]);
}

/** An equation's number beside it: inside its span, or just after it when the formula shows as its LaTeX (a fallback
 * span holds only its LaTeX). */
export function numbered(span: OutNode, tag: string): Child[] {
  if (span.attribs.class.split(' ').includes('reader-math-fallback')) return [span, ' ', tag];
  span.attribs.class += ' reader-tagged';
  span.children.push(el('span', { class: 'reader-tag' }, [tag]));
  return [span];
}

/** A formula's LaTeX as `equation` reads it, or null where `equation` would refuse it or read it back from its MathML. */
export function mathLatex(n: DomNode): string | null {
  const annotations = texAnnotations(n), latex = givenLatex(n, annotations);
  if (!latex.trim() || CONTROL.test(latex) || byteLength(latex) > LIMITS.textBytes) return null;
  if (annotations.length && !(annotations.length === 1 && normalizeSpace(textContent(annotations[0])) === normalizeSpace(latex))) return null;
  return latex;
}

/** Several formulas shown as one display equation (an aligned group's rows, align.ts): `latex` in the index, `body` its
 * MathML. Each source formula is accounted for and its id leads to this equation. */
export function joinedEquation(cx: ArxivContext, sources: DomNode[], owner: string, latex: string, body: Child[]): OutNode {
  for (const n of sources) { check(!cx.usedMath.has(n), 'arxiv_math_duplicate'); cx.usedMath.add(n); }
  boundedText(latex, LIMITS.textBytes, 'arxiv_math_source');
  check(latex.trim().length > 0 && cx.equations.length < LIMITS.equations, 'arxiv_math_source');
  const id = `e-${cx.digest}-${cx.equations.length + 1}`;
  for (const n of sources) bind(cx, n, id);
  cx.equations.push({ id, block_id: owner, latex, display: true, source_form: 'body' });
  const math = el('math', { display: 'block' }, body);
  check(math.children.length > 0, 'arxiv_math_empty');
  return el('span', { id, 'data-reader-equation': id, 'data-latex': latex, class: 'reader-equation reader-display' }, [math]);
}
