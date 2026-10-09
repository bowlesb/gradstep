// Verbatim evidence for paper podcast scripts (docs/architecture/PAPER_PODCASTS.md, checker v3).
// A model's quote is located in the pinned converted text (Mathpix standalone.mmd) through one
// canonical form applied identically to both sides, so formatting differences never reject real text:
// Unicode compatibility forms and diacritics, case, whitespace, punctuation and dashes, soft and
// line-break hyphens, Markdown/MMD markup, LaTeX commands and math delimiters, footnote markers and
// citation brackets. The evidence kept is always the paper's own span (whitespace-normalized), never
// the model's rendering, so every stored quote is text that appears in the pinned paper. Deno and Node
// compatible; nothing here logs or returns paper text except the verified spans themselves.

/** Quote length bounds, measured on the model's whitespace-normalized quote (the prompt asks for 12-300). */
export const QUOTE_MIN_CHARS = 12, QUOTE_MAX_CHARS = 400;
/** A verified span must carry at least this many canonical letters/digits; the stored span is at most this long. */
export const SPAN_MIN_CANONICAL = 8, SPAN_MAX_CHARS = 600;
/** A quote with fewer letters than this outside math delimiters is a bare formula, never evidence. */
const MATH_ONLY_LETTERS = 8;

export type EvidenceDrop = 'too_short' | 'too_long' | 'math_only' | 'not_found';
export type EvidenceRepair = 'math' | 'escapes' | 'citations' | 'ellipsis' | 'page_split' | 'formatting';

const GREEK: Record<string, string> = {
  α: 'alpha', β: 'beta', γ: 'gamma', δ: 'delta', ε: 'epsilon', ϵ: 'epsilon', ζ: 'zeta', η: 'eta', θ: 'theta', ϑ: 'theta', ι: 'iota',
  κ: 'kappa', λ: 'lambda', μ: 'mu', ν: 'nu', ξ: 'xi', ο: 'omicron', π: 'pi', ϖ: 'pi', ρ: 'rho', ϱ: 'rho', σ: 'sigma', ς: 'sigma',
  τ: 'tau', υ: 'upsilon', φ: 'phi', ϕ: 'phi', χ: 'chi', ψ: 'psi', ω: 'omega',
};
const GREEK_COMMANDS = new Set(['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta', 'iota', 'kappa', 'lambda', 'mu', 'nu', 'xi',
  'omicron', 'pi', 'rho', 'sigma', 'tau', 'upsilon', 'phi', 'chi', 'psi', 'omega']);
const COMMAND_TEXT: Record<string, string> = { times: 'x', ell: 'l', varepsilon: 'epsilon', vartheta: 'theta', varpi: 'pi', varrho: 'rho',
  varsigma: 'sigma', varphi: 'phi' };

/** Canonical text with, for each character, the [start, end) of the source unit that produced it. */
interface Canonical { text: string; start: number[]; end: number[] }

const LETTER_OR_DIGIT = /[\p{L}\p{N}]/u;
const MARK = /\p{M}/u;
const COMMAND = /\\([A-Za-z]+)\*?/y;
const FOOTNOTE_MARK = /\{\s*\}\s*\^\s*\{[^{}]{0,40}\}/y; // Mathpix "{ } ^ { 1 }"
const NUMERIC_CITATION = /\[\s*\d{1,3}(?:\s*[,–-]\s*\d{1,3})*\s*\]/y; // "[19, 15, 33]"
const PARENTHETICAL = /\(([^()]{1,300})\)/y;
const CITATION_PART = /(?:^|[\s,(])(?:19|20)\d\d[a-z]?(?:\s[a-z])?$/;

/** "(Grattafiori et al., 2024; OpenAI, 2026)", "(2025)": every ';'-separated part ends with a year. */
function isCitation(inner: string): boolean {
  return inner.split(';').every(part => CITATION_PART.test(part.trim()));
}

/** The canonical form of `raw[from, to)`: letters and digits lowercased, '%' and decimal points kept, everything else dropped. */
function canonical(raw: string, from = 0, to = raw.length): Canonical {
  const text: string[] = [], start: number[] = [], end: number[] = [];
  const emit = (value: string, a: number, b: number) => { for (const ch of value) { text.push(ch); start.push(a); end.push(b); } };
  const at = (pattern: RegExp, i: number) => { pattern.lastIndex = i; const m = pattern.exec(raw); return m && m.index + m[0].length <= to ? m : null; };
  for (let i = from; i < to;) {
    const c = raw[i];
    if (c === '\\') {
      const command = at(COMMAND, i);
      if (command) {
        const name = command[1];
        const value = COMMAND_TEXT[name] ?? (GREEK_COMMANDS.has(name) ? name : '');
        emit(value, i, i + command[0].length); i += command[0].length; continue;
      }
      // An escaped symbol (\% \& \_ \( \) \[ \] \\ ...): only the percent sign carries meaning.
      if (raw[i + 1] === '%') emit('%', i, i + 2);
      i += 2; continue;
    }
    const skipped = c === '{' ? at(FOOTNOTE_MARK, i) : c === '[' ? at(NUMERIC_CITATION, i) : null;
    if (skipped) { i += skipped[0].length; continue; }
    if (c === '(') {
      const group = at(PARENTHETICAL, i);
      if (group && isCitation(group[1])) { i += group[0].length; continue; }
    }
    const point = raw.codePointAt(i)!, width = point > 0xffff ? 2 : 1;
    for (const ch of String.fromCodePoint(point).normalize('NFKD')) {
      if (MARK.test(ch)) continue;
      if (ch === '%' || ch === '.') emit(ch, i, i + width);
      else if (ch === '×') emit('x', i, i + width);
      else if (LETTER_OR_DIGIT.test(ch)) { const lower = ch.toLowerCase(); emit(GREEK[lower] ?? lower, i, i + width); }
    }
    i += width;
  }
  // A point survives only as a decimal point (between two digits).
  const keep = text.map((ch, k) => ch !== '.' || (/\d/.test(text[k - 1] ?? '') && /\d/.test(text[k + 1] ?? '')));
  return { text: text.filter((_, k) => keep[k]).join(''), start: start.filter((_, k) => keep[k]), end: end.filter((_, k) => keep[k]) };
}

/** The model-facing canonical form of a quote (exported for tests and diagnostics). */
export function canonicalQuote(quote: string): string {
  return canonical(quote).text;
}

// ----------------------------------------------------------------------------
// The paper index: quotable blocks, page-split paragraphs rejoined.
// ----------------------------------------------------------------------------
const BOUNDARY_LINE = /^(#|\\(sub)*section\*?\{|\\(begin|end)\{|\\title\{|!\[)/;
const NON_TEXT_BLOCK = /^(\\footnotetext|\\caption|\\includegraphics|\\captionsetup|\\hline|\\item\b|\\author|\})/;
const FLOAT_BEGIN = /^\\begin\{(figure|table|tabular)\*?\}/, FLOAT_END = /^\\end\{(figure|table|tabular)\*?\}/;

interface Block { from: number; to: number; text: boolean; inFloat: boolean }
interface Group { parts: { from: number; to: number }[] }
export interface PaperIndex {
  raw: string;
  /** All groups' canonical text joined by '\n' (a quote's canonical form never contains one). */
  canon: Canonical;
  /** Canonical index where each stitched part begins (a page-split join). */
  joins: Set<number>;
  /** Inline/display math regions in the raw text, so a span never starts or ends inside a formula. */
  math: [number, number][];
  identifiers: Set<string>;
  references: string;
  latex: string;
}

/** Blocks as the reader shows them: a paragraph or line group, never a heading or environment marker. */
function blocks(raw: string): Block[] {
  const out: Block[] = [];
  let from = -1, to = -1, depth = 0, inFloat = false;
  const flush = () => {
    if (from >= 0) {
      const head = raw.slice(from, Math.min(to, from + 40)).trimStart();
      out.push({ from, to, inFloat, text: !inFloat && !NON_TEXT_BLOCK.test(head) });
    }
    from = -1;
  };
  let offset = 0;
  for (const line of raw.split('\n')) {
    const lineStart = offset, lineEnd = offset + line.length; offset = lineEnd + 1;
    const trimmed = line.trim();
    if (FLOAT_BEGIN.test(trimmed)) { flush(); depth++; inFloat = true; continue; }
    if (FLOAT_END.test(trimmed)) { flush(); depth = Math.max(0, depth - 1); inFloat = depth > 0; continue; }
    if (!trimmed || BOUNDARY_LINE.test(trimmed)) { flush(); continue; }
    if (trimmed === '\\pagebreak') continue; // page furniture, not a paragraph boundary on its own
    if (from < 0) from = lineStart;
    to = lineEnd;
  }
  flush();
  return out;
}

/**
 * Mathpix emits each PDF page in order, so a sentence that runs over a page break is cut into two
 * paragraphs with the page's floats between them. A text paragraph that does not end a sentence is
 * rejoined with the next text paragraph when that one starts in lower case. A quote that crosses the
 * join is stored as one span per side, each verbatim in its own paragraph.
 */
function groups(raw: string, list: Block[]): Group[] {
  const out: Group[] = [];
  for (let i = 0; i < list.length; i++) {
    const group: Group = { parts: [{ from: list[i].from, to: list[i].to }] };
    out.push(group);
    let current = list[i];
    while (current.text && !/[.!?:;]["')\]]?$/.test(raw.slice(current.from, current.to).replace(/\\pagebreak\s*$/, '').trimEnd())) {
      let j = i + 1;
      while (j < list.length && !list[j].text) j++;
      if (j >= list.length || j - i > 12 || !/^[a-z]/.test(raw.slice(list[j].from, list[j].to).trimStart())) break;
      group.parts.push({ from: list[j].from, to: list[j].to });
      // The skipped floats remain their own blocks.
      for (let k = i + 1; k < j; k++) out.push({ parts: [{ from: list[k].from, to: list[k].to }] });
      i = j; current = list[j];
    }
  }
  return out;
}

const IDENTIFIER = /[\p{L}][\p{L}\p{N}.@+_-]*/gu;
/** Names that mix letters and digits (Qwen3-4B, GSM8K, AIME24, pass@64), with their hyphen prefixes and parts. */
function identifiersOf(text: string): string[] {
  const out: string[] = [];
  for (const m of text.normalize('NFKC').matchAll(IDENTIFIER)) {
    const token = m[0].replace(/[.@+_-]+$/, '').toLowerCase();
    if (!/\d/.test(token)) continue;
    out.push(token);
    const parts = token.split('-');
    for (let k = 1; k < parts.length; k++) out.push(parts.slice(0, k).join('-'));
    for (const part of parts) if (/^\p{L}/u.test(part) && /\d/.test(part)) out.push(part);
  }
  return out;
}

export function indexPaper(raw: string): PaperIndex {
  const text: string[] = [], start: number[] = [], end: number[] = [];
  const joins = new Set<number>();
  for (const group of groups(raw, blocks(raw))) {
    // The separator belongs to no source unit, so a match can never begin or end on it.
    if (text.length) { text.push('\n'); start.push(-1); end.push(-1); }
    group.parts.forEach((part, k) => {
      const c = canonical(raw, part.from, part.to);
      if (k > 0) joins.add(text.length);
      for (let n = 0; n < c.text.length; n++) { text.push(c.text[n]); start.push(c.start[n]); end.push(c.end[n]); }
    });
  }
  const math: [number, number][] = [];
  for (const m of raw.matchAll(/\\\((?:[^\\]|\\(?!\)))*?\\\)|\\\[(?:[^\\]|\\(?!\]))*?\\\]/g)) math.push([m.index!, m.index! + m[0].length]);
  return { raw, canon: { text: text.join(''), start, end }, joins, math, identifiers: new Set(identifiersOf(raw)),
    // Words and numbers only ("(Table 2)", "\caption{Table 2:", "Stage- 2" all read "table 2" / "stage 2").
    references: ' ' + raw.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}.]+/gu, ' ') + ' ',
    latex: raw.normalize('NFKC').replace(/\s+/g, '') };
}

// ----------------------------------------------------------------------------
// Quote verification
// ----------------------------------------------------------------------------
export interface VerifiedSpan { quote: string; offset: number }
export type QuoteResult =
  | { ok: true; spans: VerifiedSpan[]; repairs: EvidenceRepair[] }
  | { ok: false; reason: EvidenceDrop; diagnostic: { chars: number; canonical: number; matched: number; offset: number } };

const ELLIPSIS = /\s*(?:\[\s*(?:\.\s*){3}\]|\[…\]|(?:\.\s*){3}|…)\s*/;
const isWordChar = (ch: string | undefined) => !!ch && LETTER_OR_DIGIT.test(ch);

/** Widens [a, b) so it never starts or ends inside an inline formula. */
function wholeMath(index: PaperIndex, a: number, b: number): [number, number] {
  for (const [m0, m1] of index.math) {
    if (m0 >= b) break;
    if (m1 <= a) continue;
    if (m0 < a && a < m1) a = m0;
    if (m0 < b && b < m1) b = m1;
  }
  return [a, b];
}

/** Every occurrence of `needle` in the canonical paper that starts and ends on word boundaries of the source. */
function locate(index: PaperIndex, needle: string): number {
  const { text, start, end } = index.canon, raw = index.raw;
  for (let s = text.indexOf(needle); s >= 0; s = text.indexOf(needle, s + 1)) {
    const e = s + needle.length - 1;
    // Never begin or end in the middle of one source unit (a command or a ligature), nor mid-word.
    if (s > 0 && start[s - 1] === start[s]) continue;
    if (e + 1 < text.length && start[e + 1] === start[e]) continue;
    const a = start[s], b = end[e];
    if (isWordChar(raw[a - 1]) || isWordChar(raw[b])) continue;
    // A number is never cut at its decimal point or thousands separator ("26" inside "26.2").
    if (/[.,]/.test(raw[b] ?? '') && /\d/.test(raw[b - 1] ?? '') && /\d/.test(raw[b + 1] ?? '')) continue;
    if (/[.,]/.test(raw[a - 1] ?? '') && /\d/.test(raw[a] ?? '') && /\d/.test(raw[a - 2] ?? '')) continue;
    return s;
  }
  return -1;
}

/** Longest canonical prefix of a failed quote that the paper contains, and where (diagnostics only). */
function closest(index: PaperIndex, needle: string): { matched: number; offset: number } {
  let lo = 0, hi = needle.length, at = -1;
  while (lo < hi) {
    const mid = Math.ceil((lo + hi) / 2), found = index.canon.text.indexOf(needle.slice(0, mid));
    if (found >= 0) { lo = mid; at = found; } else hi = mid - 1;
  }
  return { matched: lo, offset: at >= 0 ? index.canon.start[at] : -1 };
}

const count = (text: string, ch: string) => text.split(ch).length - 1;
const PAIRS: Record<string, string> = { '(': ')', '[': ']', '“': '”', '‘': '’' };

/**
 * The source span for canonical [x, y): never inside a formula, closed over the brackets and quote
 * marks it opened, and ending with its sentence's final punctuation or percent sign when that follows
 * at once. Every character added is the paper's own.
 */
function sourceSpan(index: PaperIndex, x: number, y: number): VerifiedSpan {
  const raw = index.raw;
  let [from, to] = wholeMath(index, index.canon.start[x], index.canon.end[y - 1]);
  for (let n = 0; n < 4; n++) {
    const span = raw.slice(from, to), next = raw[to], before = raw[from - 1];
    const open = Object.keys(PAIRS).find(o => PAIRS[o] === next);
    if (open && count(span, open) > count(span, next)) { to++; continue; }
    if (before && PAIRS[before] && count(span, PAIRS[before]) > count(span, before)) { from--; continue; }
    if (before && '-−'.includes(before) && /\d/.test(raw[from] ?? '') && !isWordChar(raw[from - 2])) { from--; continue; }
    if (next === '"' && count(span, '"') % 2 === 1) { to++; continue; }
    if (raw.startsWith('\\%', to)) { to += 2; continue; }
    if (next === '%' || (next && '.!?'.includes(next) && !/\d/.test(raw[to + 1] ?? ''))) { to++; continue; }
    break;
  }
  return { quote: raw.slice(from, to).replace(/\s+/g, ' ').trim(), offset: from };
}

/** One span per paragraph the match covers (a page-split join divides it); a side too short to stand alone is left out. */
function spansFor(index: PaperIndex, s: number, length: number): { spans: VerifiedSpan[]; split: boolean } {
  const pieces: [number, number][] = [];
  let a = s;
  for (let k = s + 1; k < s + length; k++) if (index.joins.has(k)) { pieces.push([a, k]); a = k; }
  pieces.push([a, s + length]);
  return { split: pieces.length > 1, spans: pieces.filter(([x, y]) => y - x >= SPAN_MIN_CANONICAL).map(([x, y]) => sourceSpan(index, x, y)) };
}

/** How a verified quote differed from the paper's own text (diagnostics only; the stored span is always the paper's). */
function repairsFor(quote: string, spans: VerifiedSpan[], split: boolean, ellipsis: boolean): EvidenceRepair[] {
  const shown = quote.normalize('NFKC').replace(/\s+/g, ' ').trim(), joined = spans.map(s => s.quote.normalize('NFKC')).join(' ');
  if (!split && !ellipsis && spans.length === 1 && joined === shown) return [];
  const repairs = new Set<EvidenceRepair>();
  if (ellipsis) repairs.add('ellipsis');
  if (split) repairs.add('page_split');
  const citation = (text: string) => /\[\s*\d{1,3}(?:\s*,\s*\d{1,3})*\s*\]|\([^()]*(?:19|20)\d\d[a-z]?\)/.test(text);
  if (citation(joined) && !citation(shown)) repairs.add('citations');
  if (/\\[%&#_]/.test(joined) && !/\\[%&#_]/.test(shown)) repairs.add('escapes');
  const latex = (text: string) => (text.match(/\\[()[\]]|\\[A-Za-z]+|\$/g) ?? []).join('');
  if (latex(joined) !== latex(shown) || (joined.includes('\\(') && joined.replace(/\s+/g, '') !== shown.replace(/\s+/g, '')
    && joined.replace(/\\\(.*?\\\)/g, '').replace(/\s+/g, '') === shown.replace(/\\\(.*?\\\)/g, '').replace(/\s+/g, ''))) repairs.add('math');
  if (!repairs.size || (repairs.size === 1 && (split || ellipsis))) repairs.add('formatting');
  return [...repairs];
}

/**
 * Locates one model quote in the paper. An ellipsis splits it into fragments that are verified
 * separately (each becomes its own span); a quote that crosses a page-split join yields one span per
 * paragraph. The spans returned are the paper's own text, whitespace-normalized.
 */
export function verifyQuote(index: PaperIndex, quote: string): QuoteResult {
  const shown = quote.replace(/\s+/g, ' ').trim();
  const fail = (reason: EvidenceDrop, needle = canonicalQuote(shown)): QuoteResult => {
    const near = reason === 'not_found' ? closest(index, needle) : { matched: 0, offset: -1 };
    return { ok: false, reason, diagnostic: { chars: shown.length, canonical: needle.length, ...near } };
  };
  if (shown.length < QUOTE_MIN_CHARS) return fail('too_short');
  if (shown.length > QUOTE_MAX_CHARS) return fail('too_long');
  const outsideMath = shown.replace(/\\\(.*?\\\)|\\\[.*?\\\]|\$[^$]*\$/g, ' ');
  if ((outsideMath.match(/\p{L}/gu) ?? []).length < MATH_ONLY_LETTERS) return fail('math_only');
  const fragments = shown.split(ELLIPSIS).map(f => f.trim()).filter(Boolean);
  const ellipsis = fragments.length > 1 || ELLIPSIS.test(shown);
  const spans: VerifiedSpan[] = [];
  let split = false, longest = '';
  for (const fragment of fragments) {
    const needle = canonicalQuote(fragment);
    if (needle.length > longest.length) longest = needle;
    if (needle.length < SPAN_MIN_CANONICAL) continue;
    const s = locate(index, needle);
    if (s < 0) return fail('not_found', needle);
    const found = spansFor(index, s, needle.length);
    if (found.split) split = true;
    spans.push(...found.spans);
  }
  if (!spans.length) return fail(longest.length < SPAN_MIN_CANONICAL ? 'too_short' : 'not_found', longest);
  if (spans.some(s => s.quote.length > SPAN_MAX_CHARS)) return fail('too_long');
  return { ok: true, spans, repairs: repairsFor(shown, spans, split, ellipsis) };
}

// ----------------------------------------------------------------------------
// Spoken numbers
// ----------------------------------------------------------------------------
const NUMBER = /\d+(?:[.,]\d+)*/g;
const THOUSANDS = /^\d{1,3}(?:,\d{3})+(?:\.\d+)?$/;
/** Words that name a numbered part of a paper; "fig"/"eq" abbreviations and plurals fold into their family. */
const REFERENCE = /\b(sections?|figures?|figs?\.?|tables?|appendix|appendices|equations?|eqs?\.?|stages?)\s+(\d+(?:\.\d+)*)(?![\d.]*\d)/gi;
const REFERENCE_FORMS: Record<string, string[]> = { section: ['section'], figure: ['figure', 'fig.', 'fig'], table: ['table'],
  appendix: ['appendix'], equation: ['equation', 'eq.', 'eq'], stage: ['stage'] };
const referenceFamily = (word: string) => {
  const w = word.toLowerCase().replace(/\.$/, '');
  return w.startsWith('fig') ? 'figure' : w.startsWith('eq') ? 'equation' : w.startsWith('append') ? 'appendix' : w.replace(/s$/, '');
};
const escapeRegExp = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** A number's value as a canonical decimal string: leading zeros of the whole part and trailing zeros of the fraction trimmed. */
export function numberValue(token: string): string {
  const [whole, fraction = ''] = token.split('.', 2);
  const w = whole.replace(/^0+(?=\d)/, ''), f = fraction.replace(/0+$/, '');
  return f ? `${w}.${f}` : w;
}

/** Numeric values in text: "32,768" is one number, "1,2,4" three. */
function numbersIn(text: string): string[] {
  const out: string[] = [];
  for (const m of text.matchAll(NUMBER)) {
    if (THOUSANDS.test(m[0])) out.push(numberValue(m[0].replace(/,/g, '')));
    else for (const part of m[0].split(',')) out.push(numberValue(part));
  }
  return out;
}

/** Numbers stated by verified evidence spans; inline math is read with its spaced-out digit groups ("{ 4 5 . 4 }") rejoined. */
export function evidenceNumbers(spans: string[]): Set<string> {
  const values = new Set<string>();
  for (const span of spans) {
    const text = span.replace(/\\\((.*?)\\\)/g, (_, inner: string) => ' ' + inner.replace(/\{,\}/g, ',')
      .replace(/\{\s*([\d.](?:\s*[\d.])*)\s*\}/g, (_g, digits: string) => digits.replace(/\s+/g, ''))
      .replace(/\\[A-Za-z]+/g, ' ').replace(/[{}^_]/g, ' ') + ' ');
    for (const value of numbersIn(text)) values.add(value);
  }
  return values;
}

/**
 * Numbers a segment speaks that must be supported by its own evidence. Digits inside a name the
 * paper uses (Qwen3-4B, Llama-3.1-8B, GSM8K, AIME24, pass@64: a token that starts with a letter and
 * appears in the pinned text) and references to a numbered part of the paper that exists (Section 4,
 * Figure 3, Table 2, Stage 1) are names and locators, not quantitative claims.
 */
export function spokenNumbers(index: PaperIndex, text: string): string[] {
  let rest = text.normalize('NFKC').replace(IDENTIFIER, token => {
    const name = token.replace(/[.@+_-]+$/, '').toLowerCase();
    return /\d/.test(name) && index.identifiers.has(name) ? token.replace(/\d/g, '#') : token;
  });
  rest = rest.replace(REFERENCE, (whole: string, word: string, n: string) => {
    const forms = REFERENCE_FORMS[referenceFamily(word)] ?? [];
    const exists = forms.some(form => new RegExp(` ${escapeRegExp(form)} ${escapeRegExp(n)}(?!\\d|\\.\\d)`).test(index.references));
    return exists ? whole.replace(/\d/g, '#') : whole;
  });
  return numbersIn(rest);
}

/** Formula notes are display-only: their LaTeX must appear in the paper, compared without whitespace. */
export function latexFromPaper(index: PaperIndex, latex: string): boolean {
  const compact = latex.normalize('NFKC').replace(/^\s*(\\\(|\\\[|\$\$?)|(\\\)|\\\]|\$\$?)\s*$/g, '').replace(/\s+/g, '');
  return compact.length > 0 && index.latex.includes(compact);
}
