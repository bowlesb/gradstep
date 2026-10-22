// The equation view (docs/architecture/EQUATION_VIEW.md): a tapped equation's symbols, each described from the paper
// where the paper describes it and from general usage where it does not, and optional background. Both are chat
// actions on the reader's own chat model, tools, shared instructions and paper, so they read and write the same
// cached prefix as the reader's chat about that paper; only these instructions follow the paper.
import { JsonListStream } from './json-list-stream.ts';

export const EQUATION_ACTIONS = ['equation', 'equation_background'] as const;
export type EquationAction = typeof EQUATION_ACTIONS[number];
export const isEquationAction = (action: string | null | undefined): action is EquationAction =>
  action === 'equation' || action === 'equation_background';

/** The symbols are one JSON object: a small, fixed allowance (and hold). */
export const EQUATION_MAX_TOKENS = 2_000;
export const EQUATION_FORMAT = 'equation-symbols-v1';
export const MAX_SYMBOLS = 24;

export const EQUATION_INSTRUCTIONS = `The reader opened the selected equation to read it closely. Describe it for them: what it states, then each symbol in it.
Reply with only one JSON object (no prose, no code fence), exactly this shape, its fields in this order:
{"count": <the number of symbols you will list>,
 "summary": "<one or two plain sentences: what the equation computes or states, and its role in the paper>",
 "symbols": [{"symbol": "<the symbol as plain Unicode text, e.g. π_θ(y|x), β, ∇_θ, E_{x∼D}>", "latex": "<the symbol's LaTeX>",
   "meaning": "<what it is here, in one or two sentences>", "source": "paper" | "general", "paragraph": <the number N of the [¶N] block where the paper defines or describes it; only with "paper">}]}
First "count" (the reader's progress bar), then the summary, then each symbol whole before the next: the reader sees each as soon as it is written.
List every distinct variable, parameter, function, distribution, index and operator a reader might not know, in the order they first appear (at most ${MAX_SYMBOLS}); list an indexed family once (x_i), and skip plain arithmetic (+, =, fractions).
"source" is "paper" only when the paper itself defines or describes the symbol; give that block's number. Otherwise it is "general": what the symbol usually means in this field, worded so it does not overclaim ("usually", "here most likely"). Never invent a paragraph number.
Inside the JSON strings, escape as JSON requires (a backslash is \\\\, a line break \\n). Do not use any tool and do not search the web.`;

export const EQUATION_BACKGROUND_INSTRUCTIONS = `The reader opened the selected equation and asked for background to understand it. Explain, for someone meeting it for the first time:
what problem it solves and where it sits in the paper's method; the intuition behind each term and why it has that form; the concepts it relies on, each explained briefly; and a small worked example or a limiting case when one makes it click.
Do not list the symbols one by one (the reader already sees each symbol described). Cite the paper as usual. Do not use any tool and do not search the web.`;

export interface EquationSymbol { symbol: string; latex?: string; meaning: string; source: 'paper' | 'general'; paragraph?: number }
export interface EquationSymbols { format: typeof EQUATION_FORMAT; summary: string; symbols: EquationSymbol[] }

const clean = (value: unknown, limit: number) => typeof value === 'string' ? value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '').trim().slice(0, limit) : '';

/** One symbol of the model's JSON, checked and bounded (untrusted), or null without a symbol or meaning. A paragraph
 * number outside the paper (`paragraphs` blocks) is dropped and the symbol counted as general. The final symbols and the
 * streamed ones (`EquationSymbolsStream`) use this one check, so what a device sees as it arrives is the final answer. */
export function equationSymbol(raw: unknown, paragraphs: number): EquationSymbol | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const row = raw as Record<string, unknown>;
  const symbol = clean(row.symbol, 80), meaning = clean(row.meaning, 500), latex = clean(row.latex, 200);
  if (!symbol || !meaning) return null;
  const n = row.paragraph;
  const paragraph = row.source === 'paper' && typeof n === 'number' && Number.isSafeInteger(n) && n >= 1 && n <= paragraphs ? n : undefined;
  return { symbol, ...(latex ? { latex } : {}), meaning, source: paragraph ? 'paper' : 'general', ...(paragraph ? { paragraph } : {}) };
}
export const equationSummary = (value: unknown): string => clean(value, 600);

/** The model's JSON (a code fence or words around it tolerated), checked and bounded; null when there is none.
 * `paragraphs` is the paper's block count. The first 24 usable symbols are kept (as the stream keeps them). */
export function equationSymbols(text: string, paragraphs: number): EquationSymbols | null {
  const start = text.indexOf('{'), end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  let value: unknown;
  try { value = JSON.parse(text.slice(start, end + 1)); } catch { return null; }
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const object = value as Record<string, unknown>;
  const summary = equationSummary(object.summary);
  if (!Array.isArray(object.symbols)) return null;
  const symbols: EquationSymbol[] = [];
  for (const raw of object.symbols) {
    if (symbols.length >= MAX_SYMBOLS) break;
    const symbol = equationSymbol(raw, paragraphs);
    if (symbol) symbols.push(symbol);
  }
  if (!summary && !symbols.length) return null;
  return { format: EQUATION_FORMAT, summary, symbols };
}

/** What the symbols' JSON yields as it arrives (EQUATION_VIEW.md "Streamed explanation"): the announced count, the
 * summary once its string is complete, each symbol once its object is complete and passes `equationSymbol` (in order;
 * `index` is its place in the final symbols). */
export type EquationStreamItem = { kind: 'count'; count: number } | { kind: 'summary'; summary: string } | { kind: 'symbol'; index: number; symbol: EquationSymbol };

/** Reads the symbols' JSON incrementally (`{"count": N, "summary": "…", "symbols": [{…}, …]}`, keys in any order;
 * json-list-stream.ts, shared with the figure walkthrough). */
export class EquationSymbolsStream extends JsonListStream<EquationSymbol> {
  constructor(paragraphs: number) {
    super({ countKey: 'count', summaryKey: 'summary', listKey: 'symbols', maxCount: MAX_SYMBOLS, maxItems: MAX_SYMBOLS,
      summary: equationSummary, item: raw => equationSymbol(raw, paragraphs) });
  }
  /** The symbols streamed so far (a cut-off reply keeps those that were complete); null before any symbol. */
  symbols(): EquationSymbols | null {
    return this.kept.length ? { format: EQUATION_FORMAT, summary: this.summaryText, symbols: [...this.kept] } : null;
  }
  push(chunk: string): EquationStreamItem[] {
    return this.read(chunk).map((item): EquationStreamItem => item.kind === 'item' ? { kind: 'symbol', index: item.index, symbol: item.item } : item);
  }
}

/** Prose is a useful fallback; broken structured output is neither an explanation nor delivered work. */
export function equationFallbackText(text: string): string {
  const words = text.trim();
  if (/^(?:```(?:json)?\s*)?\{/.test(words) || /"(?:summary|symbols)"\s*:/.test(words)) return '';
  return words.slice(0, 8_000);
}

/** The paper's numbered blocks ([¶N] markers in reader-local-context-v2), so a cited paragraph can be checked. */
export function paragraphCount(paperText: string): number {
  let highest = 0;
  for (const match of paperText.matchAll(/\[¶(\d{1,5})\]/g)) highest = Math.max(highest, Number(match[1]));
  return highest;
}
