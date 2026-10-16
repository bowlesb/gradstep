// The paper's Contents beside its Figures, Tables and Equations (owner, build 59: "four tabs, content, figures, tables,
// and equations… consistent styling in the rows and be clickable into the paper"), as the app's PaperContentsSheet:
// a figure or table is its number and caption ("Figure 1 — Subplots of …"), an equation its printed number and its
// LaTeX read as text. Pure: the page's own equation numbers are passed in (equationNumbers in equation.ts).
import type { ReaderIndex } from './bundle';
import { equationTurn } from './equation';

/** One figure or table as listed: "Figure 3" / "Table 2" (null when its caption names none) and the caption after it.
 * `block`: a table block the index lists by its caption (it opens as a table, not in the figure viewer). */
export interface ContentsFigure { id: string; number: string | null; caption: string; table: boolean; block?: boolean }
/** One display equation as listed: "Equation (4)", or "Equation · 3.2 Method" for one the paper doesn't number (owner,
 * build 62: "remove the equation text from this view and instead put Equation 1, Equation 2"); `text`: its LaTeX as
 * plain text (at most 160 characters), which names one with neither number nor section in the equation view's menu. */
export interface ContentsEquation { id: string; label: string; text: string }

/** Splits "Figure 4: Best of N …" into ("Figure 4", "Best of N …"); "Fig. 2", "FIGURE 2", "Figure A.1", "Table 3" and
 * "Algorithm 1" are recognized, anything else is all caption; escaped LaTeX characters read as text (GalleryFigure.label). */
export function figureLabel(text: string): { number: string | null; caption: string } {
  const caption = text.replace(/\\([{}%$&_#])/g, '$1').replace(/\s+/g, ' ').replace(/\s+([.,;:])/g, '$1').trim();
  const match = /^(fig(?:ure)?\.?|table|algorithm)\s*([A-Z]?\.?\s?\d{1,3}[a-z]?)\s*[:.|]?\s*/i.exec(caption);
  if (!match) return { number: null, caption };
  const kind = match[1].toLowerCase().startsWith('t') ? 'Table' : match[1].toLowerCase().startsWith('a') ? 'Algorithm' : 'Figure';
  return { number: `${kind} ${match[2].replace(/\s/g, '')}`, caption: caption.slice(match[0].length) };
}

/** The paper's figures and tables in order (a table is one whose caption names a table). */
export function contentsFigures(index: Pick<ReaderIndex, 'figures'>): ContentsFigure[] {
  return index.figures.map(f => {
    const { number, caption } = figureLabel(f.caption || f.alt);
    return { id: f.id, number, caption, table: !!number?.startsWith('Table') };
  });
}

/** The paper's tables in page order (Contents › Tables): the captioned tables the index lists (arXiv HTML revision 16)
 * beside the tables arXiv published as images (figures whose caption names a table); an earlier bundle, with no list,
 * shows those figures only. A listed table is never also a figure (one is a table block, the other a figure block). */
export function contentsTables(index: Pick<ReaderIndex, 'figures' | 'tables' | 'blocks'>): ContentsFigure[] {
  const images = contentsFigures(index).filter(f => f.table);
  if (!index.tables) return images;
  const order = new Map(index.blocks.map((b, i) => [b.id, i]));
  const listed = index.tables.map(t => ({ id: t.id, ...figureLabel(t.caption), table: true, block: true }));
  return [...listed, ...images].sort((a, b) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0));
}

/** The paper's display equations in order, numbered as printed (the page's tag, else a \tag{…} in the source), with
 * their LaTeX read as text; labels and numbering switches aren't shown. */
export function contentsEquations(index: Pick<ReaderIndex, 'equations'> & Partial<Pick<ReaderIndex, 'headings' | 'blocks'>>,
  printed: (id: string) => string | null): ContentsEquation[] {
  // The section an equation sits in: the last heading before its block.
  const order = new Map((index.blocks ?? []).map((b, i) => [b.id, i]));
  const headings = (index.headings ?? []).map(h => ({ at: order.get(h.id) ?? -1, title: h.title })).filter(h => h.at >= 0).sort((a, b) => a.at - b.at);
  const section = (block: string) => {
    const at = order.get(block); if (at === undefined) return null;
    let title: string | null = null;
    for (const h of headings) { if (h.at <= at) title = h.title; else break; }
    return title;
  };
  return index.equations.filter(e => e.display).map(e => {
    const tag = /\\tag\*?\{([^}]{1,12})\}/.exec(e.latex);
    const number = printed(e.id) ?? (tag ? `(${tag[1]})` : null);
    const source = e.latex.replace(/\\(?:label|tag\*?)\{[^}]*\}|\\(?:nonumber|notag)\b/g, '');
    const where = number ? null : section(e.block_id);
    return { id: e.id, label: where ? `Equation · ${where}` : equationTurn(number), text: [...mathText(source)].slice(0, 160).join('') };
  });
}

// ---------- LaTeX as readable text (ScienceReaderCore ChatMathText.plain) ----------

const SYMBOLS: Record<string, string> = {
  alpha: 'α', beta: 'β', gamma: 'γ', delta: 'δ', epsilon: 'ε', varepsilon: 'ε', zeta: 'ζ', eta: 'η',
  theta: 'θ', vartheta: 'ϑ', iota: 'ι', kappa: 'κ', lambda: 'λ', mu: 'μ', nu: 'ν', xi: 'ξ', pi: 'π',
  rho: 'ρ', sigma: 'σ', tau: 'τ', upsilon: 'υ', phi: 'φ', varphi: 'φ', chi: 'χ', psi: 'ψ', omega: 'ω',
  Gamma: 'Γ', Delta: 'Δ', Theta: 'Θ', Lambda: 'Λ', Xi: 'Ξ', Pi: 'Π', Sigma: 'Σ', Phi: 'Φ', Psi: 'Ψ', Omega: 'Ω',
  cdot: '·', times: '×', div: '÷', pm: '±', mp: '∓', leq: '≤', le: '≤', geq: '≥', ge: '≥', neq: '≠', ne: '≠',
  approx: '≈', sim: '∼', simeq: '≃', equiv: '≡', propto: '∝', infty: '∞', partial: '∂', nabla: '∇',
  sum: '∑', prod: '∏', int: '∫', in: '∈', notin: '∉', subset: '⊂', subseteq: '⊆', cup: '∪', cap: '∩',
  forall: '∀', exists: '∃', to: '→', rightarrow: '→', leftarrow: '←', Rightarrow: '⇒', Leftarrow: '⇐',
  leftrightarrow: '↔', mapsto: '↦', top: 'ᵀ', intercal: 'ᵀ', ell: 'ℓ', ldots: '…', cdots: '⋯', dots: '…',
  langle: '⟨', rangle: '⟩', lVert: '‖', rVert: '‖', Vert: '‖', '|': '‖', mid: '|', circ: '∘', odot: '⊙',
  otimes: '⊗', oplus: '⊕', star: '⋆', ast: '∗', prime: '′', lesssim: '≲', gtrsim: '≳', ll: '≪', gg: '≫',
  log: 'log', exp: 'exp', ln: 'ln', max: 'max', min: 'min', arg: 'arg', sin: 'sin', cos: 'cos', tanh: 'tanh',
  lim: 'lim', sup: 'sup', inf: 'inf', det: 'det', Pr: 'Pr', E: 'E',
  ',': ' ', ';': ' ', ':': ' ', '!': '', ' ': ' ', quad: ' ', qquad: ' ', '{': '{', '}': '}', '%': '%', _: '_', '&': '&', '#': '#', $: '$',
};
/** Commands whose argument is shown as is (fonts, text, operator names). */
const STYLES = new Set(['mathrm', 'mathbf', 'mathit', 'mathsf', 'mathtt', 'mathcal', 'mathbb', 'mathfrak', 'boldsymbol', 'bm',
  'text', 'textrm', 'textbf', 'textit', 'operatorname', 'mbox', 'hat', 'bar', 'tilde', 'vec', 'overline', 'widehat', 'widetilde']);
/** Commands that only size or space and are dropped. */
const DROPPED = new Set(['left', 'right', 'big', 'Big', 'bigg', 'Bigg', 'bigl', 'bigr', 'Bigl', 'Bigr', 'displaystyle', 'textstyle', 'limits', 'nolimits']);
const DELIMITED = new Set(['left', 'right', 'bigl', 'bigr', 'Bigl', 'Bigr', 'big', 'Big']);
const SUPERSCRIPTS: Record<string, string> = { 0: '⁰', 1: '¹', 2: '²', 3: '³', 4: '⁴', 5: '⁵', 6: '⁶', 7: '⁷', 8: '⁸', 9: '⁹',
  '+': '⁺', '-': '⁻', '=': '⁼', '(': '⁽', ')': '⁾', n: 'ⁿ', i: 'ⁱ', T: 'ᵀ', t: 'ᵗ', k: 'ᵏ', '*': '*', '′': '′', 'ᵀ': 'ᵀ' };
const SUBSCRIPTS: Record<string, string> = { 0: '₀', 1: '₁', 2: '₂', 3: '₃', 4: '₄', 5: '₅', 6: '₆', 7: '₇', 8: '₈', 9: '₉',
  '+': '₊', '-': '₋', '=': '₌', '(': '₍', ')': '₎', a: 'ₐ', e: 'ₑ', i: 'ᵢ', j: 'ⱼ', k: 'ₖ', l: 'ₗ', m: 'ₘ', n: 'ₙ',
  o: 'ₒ', p: 'ₚ', r: 'ᵣ', s: 'ₛ', t: 'ₜ', u: 'ᵤ', v: 'ᵥ', x: 'ₓ' };

/** A formula as readable plain text: Greek letters and common symbols as Unicode, simple sub/superscripts as Unicode
 * scripts (else `_x`, `^(…)`), `\frac{a}{b}` as `a/b`, `\sqrt{x}` as `√x`, style commands dropped. An approximation. */
export function mathText(latex: string): string {
  const chars = [...latex];
  let index = 0, depth = 0;
  const own = (table: Record<string, string>, key: string) => Object.hasOwn(table, key);
  const group = (text: string) => {
    const trimmed = text.trim();
    return [...trimmed].length <= 1 || /^[\p{L}\p{N}]*$/u.test(trimmed) ? trimmed : `(${trimmed})`;
  };
  const argument = (): string => {
    while (index < chars.length && chars[index] === ' ') index++;
    if (index >= chars.length) return '';
    if (chars[index] === '{') { index++; return sequence('}'); }
    if (chars[index] === '\\') return command();
    return chars[index++];
  };
  const script = (table: Record<string, string>, marker: string) => {
    const body = argument(), letters = [...body];
    if (letters.length && letters.every(c => own(table, c))) return letters.map(c => table[c]).join('');
    return letters.length === 1 ? marker + body : `${marker}(${body})`;
  };
  const command = (): string => {
    index++; // the backslash
    if (index >= chars.length) return '';
    let name = '';
    if (/[A-Za-z]/.test(chars[index])) { while (index < chars.length && /[A-Za-z]/.test(chars[index])) name += chars[index++]; }
    else name = chars[index++];
    if (name === 'frac' || name === 'dfrac' || name === 'tfrac') { const top = argument(), bottom = argument(); return `${group(top)}/${group(bottom)}`; }
    if (name === 'sqrt') return '√' + group(argument());
    if (name === '\\') return '; ';
    if (STYLES.has(name)) return argument();
    if (DROPPED.has(name)) {
      // \left( keeps its delimiter.
      if (index < chars.length && DELIMITED.has(name)) {
        if (chars[index] === '.') { index++; return ''; }
        if (chars[index] === '\\') return command();
        return chars[index++];
      }
      return '';
    }
    if (name === 'begin' || name === 'end') { argument(); return ' '; }
    return own(SYMBOLS, name) ? SYMBOLS[name] : name;
  };
  function sequence(close: string | null): string {
    let out = '';
    depth++;
    try {
      if (depth >= 40) { index = chars.length; return out; }
      while (index < chars.length) {
        const c = chars[index];
        if (close !== null && c === close) { index++; return out; }
        switch (c) {
          case '{': index++; out += sequence('}'); break;
          case '\\': out += command(); break;
          case '^': index++; out += script(SUPERSCRIPTS, '^'); break;
          case '_': index++; out += script(SUBSCRIPTS, '_'); break;
          case '~': case '&': index++; out += ' '; break;
          default: index++; out += c;
        }
      }
      return out;
    } finally { depth--; }
  }
  return sequence(null).replace(/\s+/g, ' ').trim();
}
