// The figure view (docs/architecture/FIGURE_VIEW.md): a figure's walkthrough on request — what it shows, then part by
// part, with a crop only where the model chose one — and, per part, the same again more simply. Both are chat actions
// sent exactly as this browser's chat sends a question about the paper, so they read the chat's cached paper.
import type { VerifiedBundle } from './bundle';
import { figureLabel } from './chat-figures';
import type { FigureProgressStage } from './figure-progress';
import type { FigureStructure } from './figure-structure';

export const FIGURE_WALKTHROUGH_FORMAT = 'figure-walkthrough-v1';
/** The walkthrough and one part again, more simply. ("Extract the subfigure and more context", `figure_detail`, was
 * removed on 2026-10-21: the walkthrough is the one figure result; this browser never asks for it, and results an older
 * page kept under its key are never looked up.) */
export type FigureAction = 'figure' | 'figure_simpler';
export const isFigureAction = (action: string | null | undefined): action is FigureAction =>
  action === 'figure' || action === 'figure_simpler';
/** A region of the image that was sent: fractions of its width and height, (x, y) its top-left corner. */
export interface FigureBox { x: number; y: number; w: number; h: number }
export type FigureCardKind = 'panel' | 'concept' | 'related_work';
export interface FigureSection { kind?: FigureCardKind; label: string; title: string; text: string; paragraphs: number[]; box?: FigureBox }
export interface FigureWalkthrough { format: typeof FIGURE_WALKTHROUGH_FORMAT; summary: string; sections: FigureSection[] }
/** The image the request carried (JPEG, base64), kept with the result: a box is cropped from exactly it. `structure`: the
 * figure's own sub-figures in it, when it has several images (figure-structure.ts), described to the model with the
 * caption and shown as exact parts. */
export interface SentFigure { data: string; width: number; height: number; structure?: FigureStructure | null }
/** What the view shows for one request: the walkthrough (or, without one, the model's words) and how it ended. */
export interface FigureResult {
  phase: 'loading' | 'done' | 'failed'; walkthrough: FigureWalkthrough | null; text: string; issue: string | null;
  image: SentFigure | null;
  /** From `done`/`error` (CHAT.md "When an answer stops early"): whether the reader paid, and if not, why. Never shown as a count. */
  credits: number | null; charged?: boolean; reason?: string;
  /** The model that answered, when the server named it (B7). */ model?: string;
  /** While a walkthrough is on its way (FIGURE_VIEW.md "Streamed walkthrough"): where it is, for the progress bar. Only
   * while loading; never kept. */
  progress?: FigureStreamProgress }
/** The progress bar's inputs as the stream gives them (figure-progress.ts adds the expected count and the value last
 * shown): the stage; whether the summary has arrived; the parts shown so far; the walkthrough's characters written (the
 * latest `figure_progress`) and at the summary or the latest part; the number of parts the model announced (else null). */
export interface FigureStreamProgress { stage: FigureProgressStage; summary: boolean; parts: number; characters: number; charactersAtLast: number; announced: number | null }
export const MAX_SECTIONS = 12, MAX_BOXES = 12, MIN_BOX_SIDE = 0.04;

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
  return inside && !(box.w >= 0.95 && box.h >= 0.95) ? box : null;
}

/** One part of a walkthrough checked (each of the `figure` event's sections, and each streamed `figure_section`): null
 * when unusable (no title or no words); a box that doesn't fit, or any box once `boxes` is false (the walkthrough's 12
 * were used), is dropped and the part stays; at most 8 paragraphs, each once. */
export function parseFigureSection(raw: unknown, boxes = true): FigureSection | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const row = raw as Record<string, unknown>;
  const title = clean(row.title, 120), text = clean(row.text, 1_500), label = clean(row.label, 60);
  if (!title || !text) return null;
  const paragraphs = (Array.isArray(row.paragraphs) ? row.paragraphs : [])
    .filter((n): n is number => Number.isSafeInteger(n) && (n as number) >= 1 && (n as number) <= 99_999).slice(0, 8);
  const kind = row.kind === 'concept' || row.kind === 'related_work' || row.kind === 'panel' ? row.kind : undefined;
  const box = (!kind || kind === 'panel') && boxes ? figureBox(row.box) : null;
  return { ...(kind ? { kind } : {}), label, title, text, paragraphs: [...new Set(paragraphs)], ...(box ? { box } : {}) };
}
/** A walkthrough's summary (the `figure` event's, and the streamed `figure_summary`), checked. */
export const figureSummary = (value: unknown) => clean(value, 800);

/** The `figure` event, as the server relays it (chat-figure-view.ts), checked again: an unusable section is left out, a
 * box that doesn't fit is dropped (its section stays), at most 12 sections and 12 boxes; an unusable event is null
 * (informational, never fatal: the view then shows the words). */
export function parseFigureWalkthrough(value: unknown): FigureWalkthrough | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const v = value as Record<string, unknown>;
  if (v.format !== FIGURE_WALKTHROUGH_FORMAT || !Array.isArray(v.sections)) return null;
  const summary = figureSummary(v.summary);
  const sections: FigureSection[] = [];
  let boxes = 0;
  for (const raw of v.sections) {
    if (sections.length === MAX_SECTIONS) break;
    const section = parseFigureSection(raw, boxes < MAX_BOXES);
    if (!section) continue;
    if (section.box) boxes++;
    sections.push(section);
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
/** What a figure page calls its item in "Chat about …": a table's sheet says Table (build 76: tables said "Chat about
 * Figure"); figures, algorithms and everything else say Figure. */
export const figureNoun = (label: string): 'Table' | 'Figure' => /^(?:tables?|tabs?\.)(?![a-z])/i.test(label.trim()) ? 'Table' : 'Figure';
export function figureName(bundle: VerifiedBundle, figureID: string): string {
  const figures = bundle.index.figures, i = figures.findIndex(f => f.id === figureID);
  return figureLabel(figures[i]?.caption ?? '') ?? `Figure ${Math.max(1, i + 1)}`;
}

/** A crop as CSS: the whole sent image as the box's background, scaled so the box fills its frame. `aspect` is the
 * box's width over its height in pixels of the sent image. Pure arithmetic, so the crop costs nothing beyond the box. */
export function displayBox(box: FigureBox): FigureBox {
  const margin = 0.02, x = Math.max(0, box.x - margin), y = Math.max(0, box.y - margin);
  return { x, y, w: Math.min(1, box.x + box.w + margin) - x, h: Math.min(1, box.y + box.h + margin) - y };
}
export function cropStyle(box: FigureBox, image: { width: number; height: number }): { aspect: number; size: string; position: string } {
  const pixels = cropRect(box, image);
  box = { x: pixels.x / image.width, y: pixels.y / image.height, w: pixels.width / image.width, h: pixels.height / image.height };
  const pct = (n: number) => `${Math.round(n * 10_000) / 100}%`;
  const at = (start: number, side: number) => side >= 1 ? 0 : Math.min(1, Math.max(0, start / (1 - side)));
  return { aspect: (box.w * image.width) / Math.max(1e-6, box.h * image.height), size: `${pct(1 / box.w)} ${pct(1 / box.h)}`,
    position: `${pct(at(box.x, box.w))} ${pct(at(box.y, box.h))}` };
}
/** A completed crop (figure-crops.ts `presented`) as CSS for the crop element: its region of the sent image fills the
 * content box, and a margin of white background (the figure's own, as figures are drawn on white) pads it on every side,
 * scaled with the crop (padding percentages are of the width). `aspect` includes the padding. */
export function paddedCropStyle(shown: { region: [number, number, number, number]; padX: number; padY: number }, image: { width: number; height: number }):
  { aspect: number; style: Record<string, string> } {
  const [l, t, r, b] = shown.region, region = cropRect({ x: l, y: t, w: r - l, h: b - t }, image);
  const plain = cropStyle({ x: region.x / image.width, y: region.y / image.height, w: region.width / image.width, h: region.height / image.height }, image);
  const pad = Math.max(1, Math.round(shown.padX * image.width)), outerW = region.width + 2 * pad, outerH = region.height + 2 * pad;
  const pct = (n: number) => `${Math.round(n * 1e6) / 1e4}%`;
  return { aspect: outerW / outerH, style: { boxSizing: 'border-box', padding: pct(pad / outerW),
    backgroundOrigin: 'content-box, border-box', backgroundClip: 'content-box, border-box', backgroundRepeat: 'no-repeat',
    backgroundSize: `${plain.size}, 100% 100%`, backgroundPosition: `${plain.position}, 0% 0%` } };
}
/** The box in pixels of the sent image, clamped to it (an outline over the whole figure, or a canvas crop). */
export function cropRect(box: FigureBox, image: { width: number; height: number }): { x: number; y: number; width: number; height: number } {
  const x = Math.min(image.width - 1, Math.max(0, Math.floor(box.x * image.width + 1e-9))), y = Math.min(image.height - 1, Math.max(0, Math.floor(box.y * image.height + 1e-9)));
  return { x, y, width: Math.max(1, Math.min(image.width - x, Math.ceil((box.x + box.w) * image.width - 1e-9) - x)), height: Math.max(1, Math.min(image.height - y, Math.ceil((box.y + box.h) * image.height - 1e-9) - y)) };
}

/** Results are kept for the session per paper revision, figure, action (and part) and model (never in plaintext storage). */
export const figureKey = (manifest: string, figureID: string, action: FigureAction, profile: string, part = '') => `${manifest}|${figureID}|${action}|${profile}|${part}`;

/** Pixel-exact union of the displayed crops. Overlapping boxes/insets are counted once, not summed.
 * Null means no split. An incomplete split retains the complete figure and must not count as detector success. */
export function cropCoverage(sections: FigureSection[], image: { width: number; height: number }): number | null {
  if (![image.width, image.height].every(n => Number.isSafeInteger(n) && n > 0 && n <= 32768)) return null;
  const rectangles = sections.slice(0, MAX_SECTIONS).flatMap(s => s.box && (!s.kind || s.kind === 'panel') && figureBox(s.box)
    ? [cropRect(displayBox(s.box), image)] : []);
  if (!rectangles.length) return null;
  const xs = [...new Set([0, image.width, ...rectangles.flatMap(r => [r.x, r.x + r.width])])].sort((a, b) => a - b);
  let area = 0;
  for (let i = 1; i < xs.length; i++) {
    const left = xs[i - 1], right = xs[i];
    const ys = rectangles.filter(r => r.x <= left && r.x + r.width >= right).map(r => [r.y, r.y + r.height]).sort((a, b) => a[0] - b[0]);
    let bottom = 0, covered = 0;
    for (const [top, end] of ys) { covered += Math.max(0, end - Math.max(top, bottom)); bottom = Math.max(bottom, end); }
    area += (right - left) * covered;
  }
  return area / (image.width * image.height);
}
export const cardTypeLabel = (s: FigureSection) => s.kind === 'concept' ? 'Concept' : s.kind === 'related_work' ? 'Related work' : 'Panel';
/** The card's heading line: its type, then its label unless the label only repeats the type ("Concept · Concept"). */
export function cardHeadingLabel(s: FigureSection): string {
  const type = cardTypeLabel(s), label = s.label.trim();
  return label && label.toLowerCase() !== type.toLowerCase() ? `${type} · ${label}` : type;
}
