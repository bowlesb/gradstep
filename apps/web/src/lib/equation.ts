// The equation view (docs/architecture/EQUATION_VIEW.md): a tapped equation large, each symbol described (from the
// paper where the paper describes it, general usage where not), optional background, and a way into the chat. Both
// requests are chat actions sent exactly as this browser's chat would send them, so they share the chat's cached paper.
import type { VerifiedBundle } from './bundle';

export const EQUATION_FORMAT = 'equation-symbols-v1';
export type EquationAction = 'equation' | 'equation_background';
export const isEquationAction = (action: string | null | undefined): action is EquationAction => action === 'equation' || action === 'equation_background';
export interface EquationSymbol { symbol: string; latex?: string; meaning: string; source: 'paper' | 'general'; paragraph?: number }
export interface EquationSymbols { format: typeof EQUATION_FORMAT; summary: string; symbols: EquationSymbol[] }
/** What the view shows for one request: the symbols (or, without usable JSON, the model's words), the credits used. */
export interface EquationResult { phase: 'loading' | 'done' | 'failed'; symbols: EquationSymbols | null; text: string; credits: number | null; issue: string | null }
export const MAX_SYMBOLS = 24;

const clean = (value: unknown, limit: number) => typeof value === 'string'
  ? [...value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '').trim()].slice(0, limit).join('') : '';

/** The `equation` event, as the server relays it (chat-equation.ts), checked again: unusable rows are dropped, an
 * unusable event is null (informational, never fatal). */
export function parseEquationSymbols(value: unknown): EquationSymbols | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const v = value as Record<string, unknown>;
  if (v.format !== EQUATION_FORMAT || !Array.isArray(v.symbols)) return null;
  const summary = clean(v.summary, 600);
  const symbols: EquationSymbol[] = [];
  for (const raw of v.symbols.slice(0, MAX_SYMBOLS)) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue;
    const row = raw as Record<string, unknown>;
    const symbol = clean(row.symbol, 80), meaning = clean(row.meaning, 500), latex = clean(row.latex, 200);
    if (!symbol || !meaning) continue;
    const n = row.paragraph, paragraph = row.source === 'paper' && Number.isSafeInteger(n) && (n as number) >= 1 && (n as number) <= 99_999 ? n as number : undefined;
    symbols.push({ symbol, ...(latex ? { latex } : {}), meaning, source: paragraph ? 'paper' : 'general', ...(paragraph ? { paragraph } : {}) });
  }
  return summary || symbols.length ? { format: EQUATION_FORMAT, summary, symbols } : null;
}

/** The equation's number as the paper prints it ("(7)"), from its own tag in the bundle; null for an untagged one. */
export function equationNumber(bundle: VerifiedBundle, equationID: string): string | null {
  const element = equationElement(bundle, equationID);
  const tag = element?.querySelector('.reader-tag')?.textContent?.trim() ?? '';
  return /^\(?[\w.\-–′'* ]{1,12}\)?$/.test(tag) && tag ? (tag.startsWith('(') ? tag : `(${tag})`) : null;
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
  let doc = parsed.get(bundle);
  if (!doc) {
    const bytes = bundle.contents.get(bundle.manifest.entrypoint);
    if (!bytes) return null;
    doc = new DOMParser().parseFromString(new TextDecoder().decode(bytes), 'text/html');
    parsed.set(bundle, doc);
  }
  return [...doc.querySelectorAll('[data-reader-equation]')].find(e => e.getAttribute('data-reader-equation') === equationID) ?? null;
}

/** Results are kept for the session per paper revision, equation, action and model (never in plaintext storage). */
export const equationKey = (manifest: string, equationID: string, action: EquationAction, profile: string) => `${manifest}|${equationID}|${action}|${profile}`;
