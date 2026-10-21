// The completeness step for AI-written figure crops (docs/reviews/SUBFIGURE_DETECTOR_20261021.md, integration step 1;
// docs/architecture/FIGURE_VIEW.md "Complete crops"). A port of scripts/subfigure-detector/app_crops.py (and the
// `policy.complete` it calls), checked against the shared fixtures in tests/fixtures/figure-crops/ as the apps'
// ScienceReaderCore/FigureCropCompletion.swift is. Pure geometry on the exact image the request carried: each box grows
// over the ink it cuts (labels, ticks, its own clipped body), unowned context ink joins the nearest box when the boxes
// tile the figure, and a box that still cuts ink shows the whole figure instead. No model, no network.

export const CROP_PARAMETERS = {
  inkThreshold: 235, radiusFraction: 0.003, maxIterations: 4, tileMinCover: 0.7, orphanMaxFraction: 0.5,
  figureWideFraction: 0.5, otherOwnerFraction: 0.5, paddingFraction: 0.02, paddingMinimum: 8,
} as const;

/** [x0, y0, x1, y1]: pixels of the ink image (half-open), or fractions of it. */
export type Rect = [number, number, number, number];
export interface InkComponent { box: Rect; pixels: number }
/** The ink of one image: min(R, G, B) < 235, and its components (ink joined within the dilation radius, 4-connected),
 * in the raster order of their first dilated pixel (scipy.ndimage.label). */
export interface FigureInk { width: number; height: number; mask: Uint8Array; inkPixels: number; components: InkComponent[] }
/** One crop per box: a pixel rectangle of the ink image, or null where the card shows the whole figure. `coverage` is
 * the share of ink inside the presented rectangles (whole-figure cards cover everything). */
export interface CompletedCrops { crops: (Rect | null)[]; tiled: boolean; coverage: number | null }

/** Python's round(): half to even. */
const roundHalfEven = (v: number) => { const f = Math.floor(v), d = v - f; return d > 0.5 ? f + 1 : d < 0.5 ? f : f % 2 === 0 ? f : f + 1; };

/** The image's ink and components. `pixels` is RGBA (canvas ImageData) or RGB (`channels` 3). */
export function figureInk(pixels: ArrayLike<number>, width: number, height: number, channels = 4): FigureInk {
  const n = width * height, mask = new Uint8Array(n);
  let inkPixels = 0;
  for (let i = 0, p = 0; i < n; i++, p += channels) {
    const m = Math.min(pixels[p], pixels[p + 1], pixels[p + 2]);
    if (m < CROP_PARAMETERS.inkThreshold) { mask[i] = 1; inkPixels++; }
  }
  return { width, height, mask, inkPixels, components: components(mask, width, height) };
}

/** Square dilation by r (zero outside the image), then 4-connected labels in raster order; each component's box and
 * count are of its own ink pixels (ndimage.find_objects on the label, masked by the ink). */
function components(mask: Uint8Array, W: number, H: number): InkComponent[] {
  const r = Math.max(1, roundHalfEven(CROP_PARAMETERS.radiusFraction * Math.max(W, H)));
  const across = new Uint8Array(W * H), dilated = new Uint8Array(W * H);
  for (let y = 0; y < H; y++) {
    const row = y * W;
    let count = 0;
    for (let x = 0; x < Math.min(W, r); x++) count += mask[row + x];
    for (let x = 0; x < W; x++) {
      if (x + r < W) count += mask[row + x + r];
      if (x - r - 1 >= 0) count -= mask[row + x - r - 1];
      across[row + x] = count > 0 ? 1 : 0;
    }
  }
  for (let x = 0; x < W; x++) {
    let count = 0;
    for (let y = 0; y < Math.min(H, r); y++) count += across[y * W + x];
    for (let y = 0; y < H; y++) {
      if (y + r < H) count += across[(y + r) * W + x];
      if (y - r - 1 >= 0) count -= across[(y - r - 1) * W + x];
      dilated[y * W + x] = count > 0 ? 1 : 0;
    }
  }
  const seen = new Uint8Array(W * H), stack = new Int32Array(W * H), out: InkComponent[] = [];
  for (let start = 0; start < W * H; start++) {
    if (!dilated[start] || seen[start]) continue;
    let top = 0, x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity, pixels = 0;
    stack[top++] = start; seen[start] = 1;
    while (top) {
      const i = stack[--top], x = i % W, y = (i - x) / W;
      if (mask[i]) { pixels++; if (x < x0) x0 = x; if (x + 1 > x1) x1 = x + 1; if (y < y0) y0 = y; if (y + 1 > y1) y1 = y + 1; }
      if (x > 0 && dilated[i - 1] && !seen[i - 1]) { seen[i - 1] = 1; stack[top++] = i - 1; }
      if (x + 1 < W && dilated[i + 1] && !seen[i + 1]) { seen[i + 1] = 1; stack[top++] = i + 1; }
      if (y > 0 && dilated[i - W] && !seen[i - W]) { seen[i - W] = 1; stack[top++] = i - W; }
      if (y + 1 < H && dilated[i + W] && !seen[i + W]) { seen[i + W] = 1; stack[top++] = i + W; }
    }
    if (pixels) out.push({ box: [x0, y0, x1, y1], pixels });
  }
  return out;
}

const area = (b: Rect) => Math.max(0, b[2] - b[0]) * Math.max(0, b[3] - b[1]);
const inter = (a: Rect, b: Rect): Rect => [Math.max(a[0], b[0]), Math.max(a[1], b[1]), Math.min(a[2], b[2]), Math.min(a[3], b[3])];
const union = (a: Rect, b: Rect): Rect => [Math.min(a[0], b[0]), Math.min(a[1], b[1]), Math.max(a[2], b[2]), Math.max(a[3], b[3])];
const gap = (a: Rect, b: Rect) => Math.hypot(Math.max(0, Math.max(a[0], b[0]) - Math.min(a[2], b[2])), Math.max(0, Math.max(a[1], b[1]) - Math.min(a[3], b[3])));
const same = (a: Rect, b: Rect) => a[0] === b[0] && a[1] === b[1] && a[2] === b[2] && a[3] === b[3];

/** Each component's crop: the original box holding the largest share of it (first on ties), and that share. */
function owners(comps: InkComponent[], orig: Rect[]): { k: number | null; frac: number }[] {
  return comps.map(c => {
    const a = area(c.box);
    let best: number | null = null, frac = 0;
    orig.forEach((o, k) => { const f = area(inter(c.box, o)) / Math.max(1e-9, a); if (f > frac) { best = k; frac = f; } });
    return { k: best, frac };
  });
}

/** policy.complete: grow boxes over the components they cut; optionally attach unowned ink (app options always on). */
function complete(crops: Rect[], ink: FigureInk, attachOrphans: boolean): Rect[] {
  const { width: W, height: H, components: comps } = ink, P = CROP_PARAMETERS;
  const boxes = crops.map(c => [...c] as Rect), orig = crops.map(c => [...c] as Rect), owner = owners(comps, orig);
  const swallows = (k: number, from: Rect, to: Rect) => orig.some((o, j) => j !== k && area(inter(to, o)) - area(inter(from, o)) > 0.08 * area(o));
  for (let iteration = 0; iteration < P.maxIterations; iteration++) {
    let changed = false;
    comps.forEach((c, ci) => {
      const cb = c.box;
      for (let k = 0; k < boxes.length; k++) {
        const b = boxes[k], ov = area(inter(cb, b));
        if (ov <= 0) continue;
        if (area(cb) > 1.5 * area(orig[k])) continue;
        if (ov >= area(cb) - 1e-6) continue;
        const { k: o, frac } = owner[ci];
        if (o !== null && o !== k && frac >= 0.5) continue;
        if (area(cb) > 0.5 * area(orig[k]) && !(o === k && frac >= 0.6)) continue;
        const nb = union(b, cb);
        if (swallows(k, b, nb)) continue;
        if (!same(nb, b)) { boxes[k] = nb; changed = true; }
      }
    });
    if (!changed) break;
  }
  if (attachOrphans && boxes.length) {
    const held: Rect[] = [];
    for (const c of comps) {
      const cb = c.box;
      if (boxes.some(b => area(inter(cb, b)) >= 0.999 * area(cb))) continue;
      if (held.some(h => area(inter(cb, h)) >= 0.999 * area(cb))) continue;
      if (boxes.some(b => area(inter(cb, b)) > 0) && area(cb) > 0.5 * W * H) continue;
      const d = boxes.map((b, k) => ({ dist: gap(cb, b), k })).sort((a, b) => a.dist - b.dist || a.k - b.k);
      const near = [d[0].k];
      for (const { dist, k } of d.slice(1)) if (dist <= d[0].dist * 1.15 + 2) near.push(k);
      let attached = false;
      for (const k of near) {
        if (area(cb) > P.orphanMaxFraction * area(orig[k])) continue;
        const nb = union(boxes[k], cb);
        if (swallows(k, boxes[k], nb)) continue;
        boxes[k] = nb; attached = true;
      }
      if (!attached) held.push(cb);
    }
  }
  return boxes.map(b => [Math.max(0, b[0]), Math.max(0, b[1]), Math.min(W, b[2]), Math.min(H, b[3])] as Rect);
}

/** Share of ink pixels inside the union of half-open rectangles (1 without ink). */
export function inkCoverage(ink: FigureInk, rects: Rect[]): number {
  if (!ink.inkPixels) return 1;
  const { width: W, height: H, mask } = ink;
  let covered = 0;
  for (let y = 0; y < H; y++) {
    const spans = rects.filter(b => y >= b[1] && y < b[3]);
    if (!spans.length) continue;
    for (let x = 0, i = y * W; x < W; x++, i++) if (mask[i] && spans.some(b => x >= b[0] && x < b[2])) covered++;
  }
  return covered / ink.inkPixels;
}

/** Whether crop k's box still cuts a component it may own (figure-wide components and another crop's ink excepted). */
function cuts(ink: FigureInk, owner: { k: number | null; frac: number }[], k: number, b: Rect): boolean {
  const P = CROP_PARAMETERS;
  return ink.components.some((c, ci) => {
    const cb = c.box, ov = area(inter(cb, b));
    if (ov <= 0 || ov >= area(cb) - 1e-6) return false;
    if (area(cb) > P.figureWideFraction * ink.width * ink.height) return false;
    const { k: o, frac } = owner[ci];
    return !(o !== null && o !== k && frac >= P.otherOwnerFraction);
  });
}

/** The app step (app_crops.app_crops): `fractions` are the AI's boxes as [x0, y0, x1, y1] fractions of the image. */
export function completeCrops(ink: FigureInk, fractions: Rect[]): CompletedCrops {
  const { width: W, height: H } = ink;
  const boxes = fractions.map(f => [f[0] * W, f[1] * H, f[2] * W, f[3] * H] as Rect);
  let grown = complete(boxes, ink, false);
  const tiled = boxes.length >= 2 && inkCoverage(ink, grown) >= CROP_PARAMETERS.tileMinCover;
  if (tiled) grown = complete(boxes, ink, true);
  const owner = owners(ink.components, boxes);
  const crops = grown.map((b, k): Rect | null => {
    if (cuts(ink, owner, k, b)) return null;
    const x0 = Math.max(0, Math.floor(b[0])), y0 = Math.max(0, Math.floor(b[1])), x1 = Math.min(W, Math.ceil(b[2])), y1 = Math.min(H, Math.ceil(b[3]));
    return x1 - x0 >= 2 && y1 - y0 >= 2 ? [x0, y0, x1, y1] : null;
  });
  const shown = crops.map(r => r ?? [0, 0, W, H] as Rect);
  return { crops, tiled, coverage: shown.length ? inkCoverage(ink, shown) : null };
}

/** Background around every presented crop (owner, 2026-10-21: "some margin around them"): pixels of the ink image. */
export const cropPadding = (width: number, height: number) =>
  Math.max(CROP_PARAMETERS.paddingMinimum, Math.floor(CROP_PARAMETERS.paddingFraction * Math.min(width, height) + 0.5));

/** A walkthrough/detail box (x, y, w, h) as [x0, y0, x1, y1] fractions. */
export const boxFractions = (b: { x: number; y: number; w: number; h: number }): Rect => [b.x, b.y, b.x + b.w, b.y + b.h];

/** What a card shows: its region (fractions of the image) and the background padding around it (a fraction of the
 * image's width and of its height). `whole` when the crop could not be completed. */
export interface PresentedCrop { region: Rect; whole: boolean; padX: number; padY: number }
export function presented(ink: { width: number; height: number }, crop: Rect | null): PresentedCrop {
  const { width: W, height: H } = ink, p = cropPadding(W, H);
  const r = crop ?? [0, 0, W, H];
  return { region: [r[0] / W, r[1] / H, r[2] / W, r[3] / H], whole: !crop, padX: p / W, padY: p / H };
}

/** The pixels of an image the browser holds, decoded without colour conversion (the image the request carried). */
export async function inkOf(image: Blob): Promise<FigureInk | null> {
  try {
    const bitmap = await createImageBitmap(image, { colorSpaceConversion: 'none' });
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height), ctx = canvas.getContext('2d');
    if (!ctx) { bitmap.close(); return null; }
    ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, bitmap.width, bitmap.height); ctx.drawImage(bitmap, 0, 0); bitmap.close();
    const data = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
    return figureInk(data, canvas.width, canvas.height);
  } catch { return null; }
}
export const base64Blob = (data: string, type = 'image/jpeg') => {
  const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0));
  return new Blob([bytes], { type });
};
