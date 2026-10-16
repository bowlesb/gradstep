// The figure view (docs/architecture/FIGURE_VIEW.md): a figure's walkthrough on request — what it shows, then part by
// part, with a crop only where the model chose one — and, per part, the same again more simply. Both are chat actions
// sent exactly as this browser's chat sends a question about the paper, so they read the chat's cached paper.
import type { VerifiedBundle } from './bundle';
import { figureLabel } from './chat-figures';

export const FIGURE_WALKTHROUGH_FORMAT = 'figure-walkthrough-v1';
export type FigureAction = 'figure' | 'figure_simpler';
export const isFigureAction = (action: string | null | undefined): action is FigureAction => action === 'figure' || action === 'figure_simpler';
/** A region of the image that was sent: fractions of its width and height, (x, y) its top-left corner. */
export interface FigureBox { x: number; y: number; w: number; h: number }
export interface FigureSection { label: string; title: string; text: string; paragraphs: number[]; box?: FigureBox }
export interface FigureWalkthrough { format: typeof FIGURE_WALKTHROUGH_FORMAT; summary: string; sections: FigureSection[] }
/** The image the request carried (JPEG, base64), kept with the result: a box is cropped from exactly it. */
export interface SentFigure { data: string; width: number; height: number }
/** What the view shows for one request: the walkthrough (or, without one, the model's words) and how it ended. */
export interface FigureResult {
  phase: 'loading' | 'done' | 'failed'; walkthrough: FigureWalkthrough | null; text: string; issue: string | null;
  image: SentFigure | null;
  /** From `done`/`error` (CHAT.md "When an answer stops early"): whether the reader paid, and if not, why. Never shown as a count. */
  credits: number | null; charged?: boolean; reason?: string;
}
export const MAX_SECTIONS = 12, MAX_BOXES = 4, MIN_BOX_SIDE = 0.04;

const clean = (value: unknown, limit: number) => typeof value === 'string'
  ? [...value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '').trim()].slice(0, limit).join('') : '';

/** A box inside the image, each side at least 4 %, never the whole image; null otherwise (the section stays). */
export function figureBox(value: unknown): FigureBox | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const v = value as Record<string, unknown>;
  const [x, y, w, h] = [v.x, v.y, v.w, v.h];
  if (![x, y, w, h].every(n => typeof n === 'number' && Number.isFinite(n))) return null;
  const box = { x: x as number, y: y as number, w: w as number, h: h as number };
  const inside = box.x >= 0 && box.y >= 0 && box.w >= MIN_BOX_SIDE && box.h >= MIN_BOX_SIDE && box.x + box.w <= 1.0001 && box.y + box.h <= 1.0001;
  return inside && !(box.w >= 0.9999 && box.h >= 0.9999) ? box : null;
}

/** The `figure` event, as the server relays it (chat-figure-view.ts), checked again: an unusable section is left out, a
 * box that doesn't fit is dropped (its section stays), at most 12 sections and 4 boxes; an unusable event is null
 * (informational, never fatal: the view then shows the words). */
export function parseFigureWalkthrough(value: unknown): FigureWalkthrough | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const v = value as Record<string, unknown>;
  if (v.format !== FIGURE_WALKTHROUGH_FORMAT || !Array.isArray(v.sections)) return null;
  const summary = clean(v.summary, 800);
  const sections: FigureSection[] = [];
  let boxes = 0;
  for (const raw of v.sections) {
    if (sections.length === MAX_SECTIONS) break;
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue;
    const row = raw as Record<string, unknown>;
    const title = clean(row.title, 120), text = clean(row.text, 1_500), label = clean(row.label, 60);
    if (!title || !text) continue;
    const paragraphs = (Array.isArray(row.paragraphs) ? row.paragraphs : [])
      .filter((n): n is number => Number.isSafeInteger(n) && (n as number) >= 1 && (n as number) <= 99_999).slice(0, 8);
    const box = boxes < MAX_BOXES ? figureBox(row.box) : null;
    if (box) boxes++;
    sections.push({ label, title, text, paragraphs: [...new Set(paragraphs)], ...(box ? { box } : {}) });
  }
  return sections.length ? { format: FIGURE_WALKTHROUGH_FORMAT, summary, sections } : null;
}

/** A section's heading as the view shows it: "(a) · The three-stage pipeline", or the title alone. */
export const sectionHeading = (s: Pick<FigureSection, 'label' | 'title'>) => s.label ? `${s.label} · ${s.title}` : s.title;

/** The one user turn the server sees: the figure's name ("Figure 3", "Table 1"), and for `figure_simpler` the part
 * ("Figure 1 Right panel"). Only the action's instructions follow the cached paper. */
export function figureTurn(name: string, part?: string): string {
  const label = part?.trim();
  return label ? `${name} ${label}` : name;
}
/** The figure's name from its caption ("Figure 3"); else its place among the paper's figures. */
export function figureName(bundle: VerifiedBundle, figureID: string): string {
  const figures = bundle.index.figures, i = figures.findIndex(f => f.id === figureID);
  return figureLabel(figures[i]?.caption ?? '') ?? `Figure ${Math.max(1, i + 1)}`;
}

/** A crop as CSS: the whole sent image as the box's background, scaled so the box fills its frame. `aspect` is the
 * box's width over its height in pixels of the sent image. Pure arithmetic, so the crop costs nothing beyond the box. */
export function cropStyle(box: FigureBox, image: { width: number; height: number }): { aspect: number; size: string; position: string } {
  const pct = (n: number) => `${Math.round(n * 10_000) / 100}%`;
  const at = (start: number, side: number) => side >= 1 ? 0 : Math.min(1, Math.max(0, start / (1 - side)));
  return { aspect: (box.w * image.width) / Math.max(1e-6, box.h * image.height), size: `${pct(1 / box.w)} ${pct(1 / box.h)}`,
    position: `${pct(at(box.x, box.w))} ${pct(at(box.y, box.h))}` };
}
/** The box in pixels of the sent image, clamped to it (an outline over the whole figure, or a canvas crop). */
export function cropRect(box: FigureBox, image: { width: number; height: number }): { x: number; y: number; width: number; height: number } {
  const x = Math.min(image.width - 1, Math.max(0, Math.round(box.x * image.width))), y = Math.min(image.height - 1, Math.max(0, Math.round(box.y * image.height)));
  return { x, y, width: Math.max(1, Math.min(image.width - x, Math.round(box.w * image.width))), height: Math.max(1, Math.min(image.height - y, Math.round(box.h * image.height))) };
}

/** Results are kept for the session per paper revision, figure, action (and part) and model (never in plaintext storage). */
export const figureKey = (manifest: string, figureID: string, action: FigureAction, profile: string, part = '') => `${manifest}|${figureID}|${action}|${profile}|${part}`;
