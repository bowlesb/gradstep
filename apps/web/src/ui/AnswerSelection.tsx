// Actions on selected answer text and formulas (B1; ChatRichTextView / ReaderModel on iPhone, iPad and Mac): text offers
// Quote in Chat, Explain and Define; a formula (a selection that is exactly one, or a click on it) also Copy LaTeX and
// Copy as text. Saved answers only, never the one still streaming. Formulas carry their LaTeX from the renderer
// (lib/markdown.ts `answer-math`), so a quote keeps `\(…\)` / `\[…\]` as the apps' quotes do.
import { useEffect, useState } from 'react';
import { mathText } from '../lib/paper-contents';

export interface AnswerPick { quote: string; latex: string | null }
/** The apps' cut: 4,000 characters of the trimmed quote (ChatGenerationRequest.maximumSelectionScalars). */
const MAX_QUOTE = 4_000;
const elementOf = (node: Node | null) => (node instanceof Element ? node : node?.parentElement ?? null);
const delimited = (el: Element) => {
  const latex = el.getAttribute('data-latex') ?? '';
  return el.getAttribute('data-display') === '1' ? `\\[${latex}\\]` : `\\(${latex}\\)`;
};
const clean = (text: string) => [...text.trim()].slice(0, MAX_QUOTE).join('');

/** A formula as picked: its quote in delimiters and its LaTeX. */
export function formulaPick(el: Element): AnswerPick | null {
  const latex = el.getAttribute('data-latex');
  return latex ? { quote: clean(delimited(el)), latex } : null;
}

/** The current selection when it lies within one saved answer of this transcript. */
export function readAnswerSelection(region: HTMLElement | null): AnswerPick | null {
  const selection = document.getSelection();
  if (!region || !selection || selection.isCollapsed || !selection.rangeCount) return null;
  const range = selection.getRangeAt(0);
  const answer = elementOf(range.startContainer)?.closest('[data-answer]');
  if (!answer || answer !== elementOf(range.endContainer)?.closest('[data-answer]') || !region.contains(answer)) return null;
  // Inside one formula: that formula.
  const inside = elementOf(range.commonAncestorContainer)?.closest('.answer-math[data-latex]');
  if (inside) return formulaPick(inside);
  const fragment = range.cloneContents(), formulas = [...fragment.querySelectorAll('.answer-math[data-latex]')];
  // Exactly one formula with only punctuation around it: that formula (ChatRichTextView's single-formula selection).
  if (formulas.length === 1) {
    const rest = fragment.cloneNode(true) as DocumentFragment;
    rest.querySelector('.answer-math[data-latex]')?.remove();
    if (/^[\s.,;:]*$/.test(rest.textContent ?? '')) return formulaPick(formulas[0]);
  }
  for (const formula of formulas) formula.replaceWith(document.createTextNode(delimited(formula)));
  const quote = clean(fragment.textContent ?? '');
  return quote ? { quote, latex: null } : null;
}

/** Follows the page's selection for one transcript (settled briefly, so a drag doesn't flicker the bar). */
export function useAnswerSelection(region: () => HTMLElement | null, reset: unknown) {
  const [pick, setPick] = useState<(AnswerPick & { clicked?: boolean }) | null>(null);
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const update = () => {
      clearTimeout(timer);
      timer = setTimeout(() => setPick(previous => readAnswerSelection(region()) ?? (previous?.clicked && document.getSelection()?.isCollapsed !== false ? previous : null)), 120);
    };
    document.addEventListener('selectionchange', update);
    return () => { clearTimeout(timer); document.removeEventListener('selectionchange', update); };
  }, [region]);
  useEffect(() => setPick(null), [reset]);
  return [pick, setPick] as const;
}

export function AnswerSelectionBar({ pick, onQuote, onExplain, onDefine, canQuote, canAsk, onDone }: {
  pick: AnswerPick; onQuote: (quote: string) => void; onExplain: (quote: string) => void; onDefine: (quote: string) => void;
  canQuote: boolean; canAsk: boolean; onDone: () => void;
}) {
  const [copied, setCopied] = useState<string | null>(null);
  const copy = (text: string, label: string) => { void navigator.clipboard.writeText(text).then(() => setCopied(label), () => setCopied('Couldn’t copy')); };
  const act = (run: (quote: string) => void) => { run(pick.quote); onDone(); };
  // Pressing a button never clears the selection first (it would also clear this bar).
  return <div className="selection-bar chat-selection-bar" role="toolbar" aria-label={pick.latex ? 'Selected formula' : 'Selected text'} data-testid="answer-selection"
    onMouseDown={event => event.preventDefault()}>
    {pick.latex && <>
      <button type="button" className="secondary small" onClick={() => copy(pick.latex!, 'LaTeX copied')}>Copy LaTeX</button>
      <button type="button" className="secondary small" onClick={() => copy(mathText(pick.latex!), 'Copied as text')}>Copy as text</button>
    </>}
    <button type="button" className="secondary small" disabled={!canQuote} onClick={() => act(onQuote)}>Quote in Chat</button>
    <button type="button" className="secondary small" disabled={!canAsk} onClick={() => act(onExplain)}>Explain</button>
    <button type="button" className="secondary small" disabled={!canAsk} onClick={() => act(onDefine)}>Define</button>
    {copied && <span className="fine" role="status">{copied}</span>}
  </div>;
}
