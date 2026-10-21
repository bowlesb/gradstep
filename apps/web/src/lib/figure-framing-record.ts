// The framing interaction record (owner, 2026-10-21: "we could even log the data (later) from zoom behavior and build a
// training dataset"; FIGURE_VIEW.md "Parts as viewports" › "Future opt-in training signal; not collected"). When a part
// card is shown, expanded, zoomed or panned, one structured, geometry-only record per card is kept here, in this tab's
// memory only: never sent, never stored, cleared on sign-out. It is the single place a future opt-in, consented upload
// would attach to (DECISIONS.md proposal: opt-in only, geometry only, public arXiv figures only, no account linkage).
// Only figures of arXiv papers are recorded (their public identity); nothing for local PDFs or snippets.
// ScienceReaderCore's FigureFramingRecord.swift is the same record on iPhone, iPad and Mac.
import type { Rect } from './figure-crops';
import type { FramingLevel } from './figure-framing';

/** A public arXiv figure: the paper's id and revision and the figure's number as the paper names it ("Figure 3"). */
export interface ArxivFigure { sourceID: string; revision: number; figure: string }
export type FramingSurface = 'walkthrough' | 'chat';

/** One card's record. Rectangles are [x0, y0, x1, y1] fractions of the figure (a frame may reach past 0–1 by its margin). */
export interface FramingRecord {
  figure: ArxivFigure;
  surface: FramingSurface;
  /** The part's place in its set (0-based) and the set's size. */
  part: number; parts: number;
  level: FramingLevel;
  /** The AI's box, the completed region and the frame shown at first. */
  box: Rect; region: Rect; frame: Rect;
  /** The view the reader left the card at (the frame when untouched), and what they did. */
  finalView: Rect;
  zoomed: boolean; panned: boolean; expanded: boolean;
}

const LIMIT = 200;
const records = new Map<string, FramingRecord>();
const round = (r: Rect): Rect => r.map(v => Math.round(v * 1e4) / 1e4) as Rect;

/** The identity of an arXiv paper's figure, or null for anything else (a local PDF, a snippet): then nothing is recorded. */
export function arxivFigure(paper: { source?: string | null; kind?: string | null; source_id?: string | null; source_revision?: number | null } | null | undefined,
  figure: string): ArxivFigure | null {
  if (!paper?.source_id || !(paper.kind === 'import' || paper.source === 'arxiv') || !paper.source_revision) return null;
  return { sourceID: paper.source_id, revision: paper.source_revision, figure };
}

/** A card was shown: its record starts (again) at its frame. `key` names the card (figure, surface, part). */
export function framingShown(key: string, init: Omit<FramingRecord, 'finalView' | 'zoomed' | 'panned' | 'expanded'> | null): void {
  if (!init) return;
  if (records.has(key)) return;
  records.set(key, { ...init, box: round(init.box), region: round(init.region), frame: round(init.frame), finalView: round(init.frame), zoomed: false, panned: false, expanded: false });
  while (records.size > LIMIT) records.delete(records.keys().next().value!);
}
/** The reader zoomed or panned the card (`view` is where it now shows), or expanded it to the whole figure. */
export function framingChanged(key: string, change: { view?: Rect; zoomed?: boolean; panned?: boolean; expanded?: boolean }): void {
  const record = records.get(key);
  if (!record) return;
  if (change.view) record.finalView = round(change.view);
  if (change.zoomed) record.zoomed = true;
  if (change.panned) record.panned = true;
  if (change.expanded) record.expanded = true;
}
/** What is kept (copies), for a future consented upload and for tests. */
export const framingRecords = (): FramingRecord[] => [...records.values()].map(r => ({ ...r }));
/** Signing out forgets every record. */
export function clearFramingRecords(): void { records.clear(); }
