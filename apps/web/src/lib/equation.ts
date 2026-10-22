// The equation view (docs/architecture/EQUATION_VIEW.md): a tapped equation large, each symbol described (from the
// paper where the paper describes it, general usage where not), optional background, and a way into the chat. Both
// requests are chat actions sent exactly as this browser's chat would send them, so they share the chat's cached paper.
import type { VerifiedBundle } from './bundle';
import type { FigureStreamProgress } from './figure-view';

export const EQUATION_FORMAT = 'equation-symbols-v1';
export type EquationAction = 'equation' | 'equation_background';
export const isEquationAction = (action: string | null | undefined): action is EquationAction => action === 'equation' || action === 'equation_background';
export interface EquationSymbol { symbol: string; latex?: string; meaning: string; source: 'paper' | 'general'; paragraph?: number }
export interface EquationSymbols { format: typeof EQUATION_FORMAT; summary: string; symbols: EquationSymbol[] }
/** What the view shows for one request: the symbols (or, without usable JSON, the model's words), the credits used. */
export interface EquationResult { phase: 'loading' | 'done' | 'failed'; symbols: EquationSymbols | null; text: string; credits: number | null; issue: string | null;
  /** The model that answered, when the server named it (shown under the explanation, B7). */ model?: string;
  /** Whether the reader paid and, when not, why (servers from 2026-10-16): a cut-off explanation says "not charged". */
  charged?: boolean; reason?: string;
  /** While the symbols stream (EQUATION_VIEW.md "Streamed explanation", servers from 2026-10-22): the progress bar's inputs
   * (`parts` are the symbols shown, `announced` the count the model gave). Never kept. */
  progress?: FigureStreamProgress }
export const MAX_SYMBOLS = 24;

const clean = (value: unknown, limit: number) => typeof value === 'string'
  ? [...value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '').trim()].slice(0, limit).join('') : '';

/** The `equation` event, as the server relays it (chat-equation.ts), checked again: unusable rows are dropped, an
 * unusable event is null (informational, never fatal). */
export function parseEquationSymbols(value: unknown): EquationSymbols | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const v = value as Record<string, unknown>;
  if (v.format !== EQUATION_FORMAT || !Array.isArray(v.symbols)) return null;
  const summary = equationSummary(v.summary);
  const symbols: EquationSymbol[] = [];
  for (const raw of v.symbols) {
    if (symbols.length >= MAX_SYMBOLS) break;
    const symbol = parseEquationSymbol(raw);
    if (symbol) symbols.push(symbol);
  }
  return summary || symbols.length ? { format: EQUATION_FORMAT, summary, symbols } : null;
}
/** The summary as the `equation` event's (control characters dropped, at most 600 characters). */
export const equationSummary = (value: unknown) => clean(value, 600);
/** One symbol row, checked as the `equation` event's rows are (and the streamed `equation_symbol`'s): null when unusable. */
export function parseEquationSymbol(raw: unknown): EquationSymbol | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const row = raw as Record<string, unknown>;
  const symbol = clean(row.symbol, 80), meaning = clean(row.meaning, 500), latex = clean(row.latex, 200);
  if (!symbol || !meaning) return null;
  const n = row.paragraph, paragraph = row.source === 'paper' && Number.isSafeInteger(n) && (n as number) >= 1 && (n as number) <= 99_999 ? n as number : undefined;
  return { symbol, ...(latex ? { latex } : {}), meaning, source: paragraph ? 'paper' : 'general', ...(paragraph ? { paragraph } : {}) };
}

/** An equation element's printed tag as its number ("(7)"); null for none or an unusable one. */
function printedNumber(element: Element | null | undefined): string | null {
  const tag = element?.querySelector('.reader-tag')?.textContent?.trim() ?? '';
  return /^\(?[\w.\-–′'* ]{1,12}\)?$/.test(tag) && tag ? (tag.startsWith('(') ? tag : `(${tag})`) : null;
}
/** The equation's number as the paper prints it ("(7)"), from its own tag in the bundle; null for an untagged one. */
export function equationNumber(bundle: VerifiedBundle, equationID: string): string | null {
  return printedNumber(equationElement(bundle, equationID));
}
/** Every equation's printed number at once (Contents › Equations), from one reading of the bundle's page. */
export function equationNumbers(bundle: VerifiedBundle): Map<string, string> {
  const numbers = new Map<string, string>();
  for (const element of bundlePage(bundle)?.querySelectorAll('[data-reader-equation]') ?? []) {
    const id = element.getAttribute('data-reader-equation'), number = printedNumber(element);
    if (id && number && !numbers.has(id)) numbers.set(id, number);
  }
  return numbers;
}
/** The one user turn the server sees ("Equation (7)"): only the action's instructions follow the cached paper. */
export const equationTurn = (number: string | null) => number ? `Equation ${number}` : 'Equation';

/** The equation's LaTeX from the verified index (never from a frame message), as its `selection.quote`. */
export function equationLatex(bundle: VerifiedBundle, equationID: string): string | null {
  const equation = bundle.index.equations.find(e => e.id === equationID);
  const latex = equation?.latex.trim();
  return latex ? [...latex].slice(0, 4_000).join('') : null;
}

const parsed = new WeakMap<VerifiedBundle, Document>();
/** The equation's element in the bundle's own page (`data-reader-equation`), parsed once per bundle. */
export function equationElement(bundle: VerifiedBundle, equationID: string): Element | null {
  const doc = bundlePage(bundle);
  return doc ? [...doc.querySelectorAll('[data-reader-equation]')].find(e => e.getAttribute('data-reader-equation') === equationID) ?? null : null;
}
function bundlePage(bundle: VerifiedBundle): Document | null {
  let doc = parsed.get(bundle);
  if (!doc) {
    const bytes = bundle.contents.get(bundle.manifest.entrypoint);
    if (!bytes) return null;
    doc = new DOMParser().parseFromString(new TextDecoder().decode(bytes), 'text/html');
    parsed.set(bundle, doc);
  }
  return doc;
}

/** Results are kept for the session per paper revision, equation, action and model (never in plaintext storage). */
export const equationKey = (manifest: string, equationID: string, action: EquationAction, profile: string) => `${manifest}|${equationID}|${action}|${profile}`;
