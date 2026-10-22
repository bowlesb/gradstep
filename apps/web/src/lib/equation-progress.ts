// The equation explainer's progress bar (EQUATION_VIEW.md "Streamed explanation", owner 2026-10-22: "the equations AI
// explainer needs the same progress with the progress bar"). The figure walkthrough's rule (figure-progress.ts) with the
// equation's words and sizes, shared in meaning with the apps' `FigureProgress.state(_:kind: .equation)`; both reproduce
// tests/fixtures/equation-progress.json. A stage label always; "Explaining symbol k of N…" and a determinate value only
// once the model has announced N (its first field) and while it is not exceeded; never backwards, never a made-up 99 %.
import { explainerProgress, type FigureProgressInput, type FigureProgressState, type ProgressWords } from './figure-progress';

/** Measured sizes (2026-10-22, DPO's loss and its gradient; Gemini 3.8 Flash low/medium and Sonnet 5.5 low): the
 * summary's JSON about 240–430 characters, a symbol's about 170–210 (its symbol, LaTeX, meaning, source, paragraph). */
export const EQUATION_PROGRESS = Object.freeze({ summaryChars: 320, partChars: 200, summaryShare: 0.1, partCap: 0.9 });

const WORDS: ProgressWords = { preparing: 'Preparing the equation…', reading: 'Reading the equation…', summary: 'Writing the summary…',
  item: (next, of) => of ? `Explaining symbol ${next} of ${of}…` : `Explaining symbol ${next}…` };

/** `parts` are the symbols that arrived; `expected` the count the model announced (null until it did). */
export function equationProgress(input: FigureProgressInput): FigureProgressState { return explainerProgress(input, WORDS, EQUATION_PROGRESS); }
