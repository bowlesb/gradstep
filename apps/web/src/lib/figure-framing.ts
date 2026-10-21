// How each AI-boxed part of a figure is framed (owner, 2026-10-21: "we present it as a crop of the whole thing, that they
// can expand, rather than an actual crop"; docs/architecture/FIGURE_VIEW.md "Parts as viewports"). A part card is a
// viewport into the whole figure: the figure on its white background, scaled and placed so the part's frame fills the
// card. How tightly it frames the part follows a confidence worked out here from signals the device already has:
// completion (how much the box had to grow, or whether it still cuts ink), the caption's panel letters, and how the parts
// sit against each other (a neighbour's ink inside the frame, slivers); a hook takes the subfigure detector's agreement
// later. High confidence: the part and its margin, as a crop looked; medium: looser, the part outlined; low: the whole
// figure, the part outlined. A caption that names its panels caps the parts: extra ones are outlines on the whole figure.
// A part that is one of the figure's own sub-figures (figure-structure.ts: its images in the bundle) is exact: its band,
// tight. When the AI's parts number neither the caption's lettered panels nor the figure's own sub-figures (count
// disagreement, subfigure detector round 3), its other parts show the whole figure with the part outlined.
// The same rules, numbers and fixtures as ScienceReaderCore/FigureFraming.swift (tests/fixtures/figure-crops/framing.json).
import { completeCrops, cropPadding, inkCoverage, owners, type FigureInk, type Rect } from './figure-crops';

/** Every threshold of the framing, in one place (the Swift port's `FigureFraming.Parameters` holds the same values; the
 * shared fixture states them and both test suites check them). */
export const FRAMING = {
  /** A score at or above `high` frames tightly; at or above `medium`, loosely with an outline; else the whole figure. */
  high: 0.75, medium: 0.45,
  /** Completion growth (area added ÷ the AI box's area): free up to `growthFree` (labels and ticks a model leaves out),
   * then `growthPerUnit` per unit of growth, at most `growthMaxPenalty`. */
  growthFree: 0.5, growthPerUnit: 0.6, growthMaxPenalty: 0.5,
  /** A part's own letter isn't the caption's (the caption names L ≥ 2 panels). */
  countPenalty: 0.3,
  /** Count disagreement: two or more parts, and their number is neither the caption's L ≥ 2 lettered panels nor the
   * figure's own S ≥ 2 sub-figures (whichever it states): every part not exact scores at most this (the whole figure). */
  countCap: 0.3,
  /** A neighbour's ink inside the part: the largest share of an ink component another part owns (holds most of) that lies
   * inside this part's region. Above `intrusionFree` it costs `intrusionBase` (never a tight frame then) plus the share, at most
   * `intrusionMaxPenalty`. Figure-wide components (a frame or a filled background) don't count. */
  intrusionFree: 0.02, intrusionBase: 0.26, intrusionMaxPenalty: 0.4,
  /** A sliver: narrower than `sliverSide` of the figure on either side, or smaller than `sliverArea` of it. */
  sliverSide: 0.08, sliverArea: 0.015, sliverPenalty: 0.3,
  /** The detector's agreement (IoU of its best matching part), when there is one: below `detectorAgree` it costs up to
   * `detectorMaxPenalty`. Not wired yet (integration step 2 of the subfigure detector review). */
  detectorAgree: 0.7, detectorMaxPenalty: 0.4,
  /** Without the pixels to check a box (the image couldn't be decoded): medium. */
  uncheckedScore: 0.6,
  /** Looser framing: each side extended by this share of the part's size (never less than the background margin). */
  looseFraction: 0.18,
  /** The white veil over the rest of the figure at rest: opaque on a tight frame (it looks as a crop did), soft on a loose
   * one, none on the whole figure (an unobtrusive outline only). Once the reader zooms or pans, a tight frame's veil turns
   * soft and its outline shows. */
  veilHigh: 1, veilMedium: 0.4, veilLow: 0, veilRevealed: 0.4,
} as const;

export type FramingLevel = 'high' | 'medium' | 'low';
export type FramingReason = 'cut' | 'grew' | 'count' | 'letter' | 'overlap' | 'sliver' | 'detector' | 'unchecked' | 'extra';
// ('count': the parts' number disagrees with the caption's panels and the figure's own sub-figures; 'extra': a part beyond
// the caption's panels.)

/** One part as a card shows it. Rectangles are fractions of the image (the frame may reach past 0–1 by the margin). */
export interface FramedPart {
  level: FramingLevel;
  /** 0–1; the level follows from it (a cut part and an extra part are 0). */
  score: number;
  reasons: FramingReason[];
  /** What the card frames (its aspect is the card's, in pixels of the image). */
  frame: Rect;
  /** The part itself: its completed crop, or the AI's box where completion couldn't hold it (outlined). */
  region: Rect;
  /** The figure's white margin around the image, as fractions of its width and height (the viewport's canvas). */
  padX: number; padY: number;
  /** The veil's opacity over the rest of the figure, at rest; whether the outline shows at rest. */
  veil: number; outlined: boolean;
  /** A part beyond the caption's panels: an outline on the whole figure, not a crop of its own. */
  extra: boolean;
  /** One of the figure's own sub-figures (its band of the composed image): exact, framed tightly. */
  exact: boolean;
}

/** Distinct panel letters a caption names: "(a)", "a) " and "\textbf{(a)}" (policy.caption_letters). */
export function captionLetters(caption: string): string[] {
  const letters = new Set<string>();
  for (const m of caption.matchAll(/\(([a-hA-H])\)/g)) letters.add(m[1].toLowerCase());
  for (const m of caption.matchAll(/(?<![\w\\])([a-h])\)\s/g)) letters.add(m[1]);
  for (const m of caption.matchAll(/\\textbf\{\s*\(?([a-hA-H])\)?\s*[.:]?\s*\}/g)) letters.add(m[1].toLowerCase());
  return [...letters].sort();
}

/** The panel letter a part's label names: "(b)", "(b) Win rate", "b) Win rate", "b. Win rate", "b", "B", "Panel b" (not
 * "A closer look"). */
export function labelLetter(label: string): string | null {
  const m = /\(([a-hA-H])\)/.exec(label) ?? /^\s*([a-hA-H])[).:]?\s*$/.exec(label) ?? /^\s*([a-h])[).:]\s/.exec(label)
    ?? /\bpanel\s+([a-hA-H])\b/i.exec(label);
  return m ? m[1].toLowerCase() : null;
}

/** Which parts the caption has room for: when it names L ≥ 2 panels and more parts were boxed, the parts whose labels name
 * a caption letter (the first for each), then unlettered parts in order, up to L. Every part otherwise. */
export function keptParts(labels: string[], letters: string[]): boolean[] {
  const L = letters.length;
  if (L < 2 || labels.length <= L) return labels.map(() => true);
  const kept = labels.map(() => false), used = new Set<string>();
  labels.forEach((label, i) => { const c = labelLetter(label); if (c && letters.includes(c) && !used.has(c)) { used.add(c); kept[i] = true; } });
  let room = L - used.size;
  labels.forEach((label, i) => { if (!kept[i] && room > 0 && !labelLetter(label)) { kept[i] = true; room--; } });
  return kept;
}

const area = (b: Rect) => Math.max(0, b[2] - b[0]) * Math.max(0, b[3] - b[1]);
const inter = (a: Rect, b: Rect): Rect => [Math.max(a[0], b[0]), Math.max(a[1], b[1]), Math.min(a[2], b[2]), Math.min(a[3], b[3])];
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
const round6 = (v: number) => Math.round(v * 1e6) / 1e6;

export interface FramingInput {
  /** The AI's boxes, [x0, y0, x1, y1] fractions of the image, in the order shown. */
  boxes: Rect[];
  /** The caption (its panel letters), or '' without one. */
  caption?: string;
  /** Each part's label (to keep the caption's own panels when there are more parts than it names). */
  labels?: string[];
  /** The detector's agreement with each part (IoU 0–1), when it ran: the hook for integration step 2. */
  detector?: (number | null)[];
  /** Each part's exact region when it is one of the figure's own sub-figures (figure-structure.ts `matchSections`), as
   * [x0, y0, x1, y1] fractions; null for a part the AI boxed. */
  exact?: (Rect | null)[];
  /** How many sub-figures the figure's own structure has (0 without one), for the count check. */
  structureParts?: number;
}

/** Every part of one set (a walkthrough's boxes, a chat answer's parts, one extracted part) framed, on the ink of the image
 * the request carried (completed together, extras left out), or unchecked without it (`image` gives the size then). Also
 * the share of the figure's ink the kept parts' completed crops show, the whole figure for a part that couldn't be
 * completed (null without ink or boxes), for the coverage note. */
export function frameParts(ink: FigureInk | null, image: { width: number; height: number }, input: FramingInput): { parts: FramedPart[]; coverage: number | null } {
  const F = FRAMING, W = ink?.width ?? image.width, H = ink?.height ?? image.height, boxes = input.boxes;
  if (!boxes.length || !(W > 0) || !(H > 0)) return { parts: [], coverage: null };
  const pad = cropPadding(W, H), padX = pad / W, padY = pad / H;
  const letters = captionLetters(input.caption ?? ''), labels = boxes.map((_, k) => input.labels?.[k] ?? '');
  // A sub-figure of the figure's own is exact: always kept, its band its region (and its box for completion).
  const exact = boxes.map((_, k) => input.exact?.[k] ?? null), shape = boxes.map((b, k) => exact[k] ?? b);
  const kept = keptParts(labels, letters).map((v, k) => v || !!exact[k]), keptIndex = boxes.flatMap((_, k) => kept[k] ? [k] : []), extras = boxes.length - keptIndex.length;
  // Count disagreement: two or more parts whose number is neither the caption's lettered panels nor the figure's own
  // sub-figures (when either is stated).
  const L = letters.length, S = input.structureParts ?? 0, N = boxes.length;
  const disagree = N >= 2 && (L >= 2 || S >= 2) && !(L >= 2 && N === L) && !(S >= 2 && N === S);
  const px = (b: Rect): Rect => [b[0] * W, b[1] * H, b[2] * W, b[3] * H];
  // Completion of the kept parts together (an extra part never becomes a crop, so it doesn't shape the others).
  const done = ink && keptIndex.length ? completeCrops(ink, keptIndex.map(k => shape[k])) : null;
  const crops = boxes.map((_, k): Rect | null | undefined => done ? done.crops[keptIndex.indexOf(k)] ?? (kept[k] ? null : undefined) : undefined);
  const regions = boxes.map((b, k) => exact[k] ? px(exact[k]!) : crops[k] ?? px(b));
  // Which kept part each ink component belongs to (the AI box holding most of it), for a neighbour's ink in a frame.
  const owner = ink && done ? owners(ink.components, keptIndex.map(k => px(shape[k]))) : [];
  const parts = boxes.map((box, k): FramedPart => {
    const region = regions[k], reasons: FramingReason[] = [];
    let score = 1;
    if (exact[k]) { /* the figure's own sub-figure: exact */ }
    else if (!kept[k]) { reasons.push('extra'); score = 0; }
    else if (!done) { reasons.push('unchecked'); score = F.uncheckedScore; }
    else if (!crops[k]) { reasons.push('cut'); score = 0; }
    else {
      const growth = area(region) / Math.max(1, area(px(box))) - 1;
      const grew = Math.min(F.growthMaxPenalty, Math.max(0, growth - F.growthFree) * F.growthPerUnit);
      if (grew > 0) { reasons.push('grew'); score -= grew; }
    }
    if (score > 0 && !exact[k]) {
      const own = labelLetter(labels[k]);
      if (disagree) reasons.push('count');
      else if (letters.length >= 2 && own && !letters.includes(own)) { reasons.push('letter'); score -= F.countPenalty; }
      if (ink && done) {
        const me = keptIndex.indexOf(k), wide = 0.5 * W * H;
        let intrusion = 0;
        ink.components.forEach((c, ci) => {
          const o = owner[ci];
          if (o.k === null || o.k === me || o.frac < 0.5 || area(c.box) > wide) return;
          intrusion = Math.max(intrusion, area(inter(c.box, region)) / Math.max(1, area(c.box)));
        });
        if (intrusion > F.intrusionFree) { reasons.push('overlap'); score -= Math.min(F.intrusionMaxPenalty, F.intrusionBase + intrusion); }
      }
      const w = (region[2] - region[0]) / W, h = (region[3] - region[1]) / H;
      if (w < F.sliverSide || h < F.sliverSide || w * h < F.sliverArea) { reasons.push('sliver'); score -= F.sliverPenalty; }
      const agreement = input.detector?.[k];
      if (agreement !== undefined && agreement !== null && agreement < F.detectorAgree) {
        reasons.push('detector'); score -= F.detectorMaxPenalty * (F.detectorAgree - agreement) / F.detectorAgree;
      }
      if (disagree) score = Math.min(score, F.countCap);
    }
    score = round6(clamp(score, 0, 1));
    const level: FramingLevel = score >= F.high ? 'high' : score >= F.medium ? 'medium' : 'low';
    let frame: Rect;
    if (level === 'high') frame = [region[0] - pad, region[1] - pad, region[2] + pad, region[3] + pad];
    else if (level === 'medium') {
      const ex = Math.max(pad, F.looseFraction * (region[2] - region[0])), ey = Math.max(pad, F.looseFraction * (region[3] - region[1]));
      frame = [clamp(region[0] - ex, -pad, W + pad), clamp(region[1] - ey, -pad, H + pad), clamp(region[2] + ex, -pad, W + pad), clamp(region[3] + ey, -pad, H + pad)];
    } else frame = [-pad, -pad, W + pad, H + pad];
    const f = (r: Rect): Rect => [round6(r[0] / W), round6(r[1] / H), round6(r[2] / W), round6(r[3] / H)];
    return { level, score, reasons, frame: f(frame), region: f(region), padX, padY,
      veil: level === 'high' ? F.veilHigh : level === 'medium' ? F.veilMedium : F.veilLow, outlined: level !== 'high', extra: !kept[k], exact: !!exact[k] };
  });
  // The share of the ink the kept parts show: an exact part its band, another its completed crop (the whole figure when it
  // couldn't be completed).
  const shown = keptIndex.map((k, i): Rect => exact[k] ? px(exact[k]!) : done?.crops[i] ?? [0, 0, W, H]);
  return { parts, coverage: done && ink ? (extras ? 1 : exact.some(Boolean) ? inkCoverage(ink, shown) : done.coverage) : null };
}

/** The frame's aspect (width ÷ height) in pixels of an image of this size: the card's. */
export const frameAspect = (part: Pick<FramedPart, 'frame'>, image: { width: number; height: number }) =>
  ((part.frame[2] - part.frame[0]) * image.width) / Math.max(1e-6, (part.frame[3] - part.frame[1]) * image.height);

/** The veil and outline as they show: at rest, or once the reader has zoomed or panned (a tight frame's veil turns soft and
 * its outline shows, so what lies around the part reads as context). */
export function framingLook(part: Pick<FramedPart, 'veil' | 'outlined'>, revealed: boolean): { veil: number; outlined: boolean } {
  return revealed ? { veil: Math.min(part.veil, FRAMING.veilRevealed), outlined: true } : { veil: part.veil, outlined: part.outlined };
}
