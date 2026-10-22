// The figure explainer's progress bar (FIGURE_VIEW.md "Progress", owner 2026-10-22: "it needs a progress bar"). One pure
// function shared in meaning with the apps' `FigureProgress` (ScienceReaderCore/FigureProgress.swift): both reproduce
// tests/fixtures/figure-progress.json. Honest by construction: a stage label always; a determinate value only while the
// number of parts is known (the figure's own sub-figures, else the panels its caption letters, else none) and not yet
// exceeded; the value never goes back and never waits at a made-up 99 %: when the estimate runs out it turns
// indeterminate ("Writing part 4…") until the walkthrough is done.

/** Where the request is: `preparing` (this device makes the image and request), `reading` (the server asked the model;
 * it is reading the figure), `writing` (the walkthrough's characters are arriving), `done`. */
export type FigureProgressStage = 'preparing' | 'reading' | 'writing' | 'done';

export interface FigureProgressInput {
  stage: FigureProgressStage;
  /** The summary has arrived. */
  summary: boolean;
  /** Parts that have arrived. */
  parts: number;
  /** The walkthrough's characters written so far (the latest `figure_progress`), 0 before any. */
  characters: number;
  /** `characters` when the summary or the latest part arrived (what the current part has written is the difference). */
  charactersAtLast: number;
  /** How many parts to expect, when known (sub-figures, else caption panels, at least 2); null when not. */
  expected: number | null;
  /** The value last shown (the bar never goes back); null when it was indeterminate or nothing was shown. */
  previous: number | null;
}
export interface FigureProgressState { label: string; value: number | null }

/** Measured walkthrough sizes (Gemini 3.8 Flash at low effort, four real figures, 2026-10-22): the summary's JSON
 * about 500 characters, a part's about 1,500 (its text, label, title, citations and box). */
export const FIGURE_PROGRESS = Object.freeze({ summaryChars: 500, partChars: 1_500, summaryShare: 0.1, partCap: 0.9 });

/** The expected number of parts: the figure's own sub-figures when there are two or more, else the panels its caption
 * letters when there are two or more, else unknown. */
export function expectedParts(subfigures: number | null | undefined, captionLetters: number): number | null {
  if (subfigures != null && subfigures >= 2) return subfigures;
  return captionLetters >= 2 ? captionLetters : null;
}

/** An explainer's words for its stages (the figure's parts, the equation's symbols). */
export interface ProgressWords { preparing: string; reading: string; summary: string; item: (next: number, of: number | null) => string }
export interface ProgressParameters { summaryChars: number; partChars: number; summaryShare: number; partCap: number }
const FIGURE_WORDS: ProgressWords = { preparing: 'Preparing the figure…', reading: 'Reading the figure…', summary: 'Writing the summary…',
  item: (next, of) => of ? `Writing part ${next} of ${of}…` : `Writing part ${next}…` };

export function figureProgress(input: FigureProgressInput): FigureProgressState { return explainerProgress(input, FIGURE_WORDS, FIGURE_PROGRESS); }

/** The shared rule (figure walkthrough and equation symbols; equation-progress.ts): `parts` are the items that arrived. */
export function explainerProgress(input: FigureProgressInput, words: ProgressWords, p: ProgressParameters): FigureProgressState {
  switch (input.stage) {
    case 'preparing': return { label: words.preparing, value: null };
    case 'reading': return { label: words.reading, value: null };
    case 'done': return { label: 'Done', value: 1 };
    default: break;
  }
  const n = input.expected;
  const known = n != null && n >= 1 && input.parts < n;
  const label = !input.summary && input.parts === 0 ? words.summary : words.item(input.parts + 1, known ? n! : null);
  if (!known) return { label, value: null };
  const current = Math.max(0, input.characters - input.charactersAtLast);
  const value = !input.summary && input.parts === 0
    ? p.summaryShare * Math.min(p.partCap, current / p.summaryChars)
    : p.summaryShare + (1 - p.summaryShare) * (input.parts + Math.min(p.partCap, current / p.partChars)) / n!;
  return { label, value: round(Math.min(1, Math.max(input.previous ?? 0, value))) };
}
const round = (v: number) => Math.round(v * 10_000) / 10_000;
