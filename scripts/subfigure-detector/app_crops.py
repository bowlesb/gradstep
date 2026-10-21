#!/usr/bin/env python3
"""The completeness step as the apps run it on AI-written crops (review SUBFIGURE_DETECTOR_20261021, integration
step 1). Reference for `FigureCropCompletion.swift` (ScienceReaderCore) and `figure-crops.ts` (browser); the shared
golden fixtures in `tests/fixtures/figure-crops/` are exported from this file by `export_crop_fixtures.py`.

On the exact image the request carried (white background, ink = min(R, G, B) < 235):
1. `policy.complete` grows every AI box over the ink components it cuts (labels, ticks, its own clipped body; never
   more than 8% into another box). Unowned ink is attached to the nearest box(es) only when the boxes are meant to
   tile the figure (two or more boxes that, grown, hold >= 70% of its ink; ink inside a box counts by pixel
   containment of the half-open rectangle) and only when it is context-sized (at most half the receiving box's
   original area); otherwise a single detail box or a partial set would swallow parts the AI did not choose. An
   orphan inside the box of an earlier orphan that could not be attached stays with it (legend swatches stay with a
   shared legend that would swallow a panel if attached).
2. A crop that still cuts a component it may own (not a figure-wide frame/connector/background, not mostly inside
   another box) is not shown cropped: the card shows the whole figure. This also catches a box that is a slice of a
   larger panel, which the growth step leaves alone (its 1.5x "frame" rule).
3. Pixel rectangles round outward. Every presented crop (and a whole-figure card) gets a uniform padding of
   background: max(8, round(2% of the shorter side)) pixels of this image, drawn as background, never as more of the
   image (so a neighbour's ink never shows at an edge).
4. Ink coverage: the share of ink pixels inside the union of the presented rectangles (whole-figure cards cover
   everything). Below 1 the walkthrough says its cards do not cover the whole figure.

Pure geometry; no model, no network.
"""
import math

import numpy as np

import policy as P

INK_THRESHOLD = 235
RADIUS_FRAC = 0.003
MAX_ITER = 4
TILE_MIN_COVER = 0.7
ORPHAN_MAX_FRAC = 0.5
FIGURE_WIDE_FRAC = 0.5
OTHER_OWNER_FRAC = 0.5
PADDING_FRAC = 0.02
PADDING_MIN = 8


def padding(W, H):
    """Background padding in pixels of this image, round half up (as JavaScript's Math.round and Swift .rounded())."""
    return max(PADDING_MIN, int(math.floor(PADDING_FRAC * min(W, H) + 0.5)))


def owners(comps, orig):
    out = []
    for c in comps:
        cb = c[:4]
        a = P.area(cb)
        best, frac = None, 0.0
        for k, o in enumerate(orig):
            f = P.area(P.inter(cb, o)) / max(1e-9, a)
            if f > frac:
                best, frac = k, f
        out.append((best, frac))
    return out


def ink_cover(mask, rects):
    """Share of ink pixels inside the union of half-open pixel rectangles [x0, y0, x1, y1]."""
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return 1.0
    covered = np.zeros(len(xs), bool)
    for b in rects:
        covered |= (xs >= b[0]) & (xs < b[2]) & (ys >= b[1]) & (ys < b[3])
    return float(covered.mean())


def cuts(comps, own, orig, k, b, W, H):
    """Whether box b (crop k) still cuts an ink component it may own. Stricter than the growth step's 1.5x-crop
    "frame" rule: only a figure-wide component (more than half the image, as the orphan step's frame rule) is exempt,
    so a box inside a larger panel (a slice of a plot) falls back to the whole figure."""
    for ci, c in enumerate(comps):
        cb = c[:4]
        ov = P.area(P.inter(cb, b))
        if ov <= 0 or ov >= P.area(cb) - 1e-6:
            continue
        if P.area(cb) > FIGURE_WIDE_FRAC * W * H:
            continue  # a figure-wide frame, connector or background: not panel ink
        o, frac = own[ci]
        if o is not None and o != k and frac >= OTHER_OWNER_FRAC:
            continue  # mostly another crop's ink
        return True
    return False


def app_crops(fractions, mask, comps=None):
    """fractions: AI boxes as [x0, y0, x1, y1] fractions of the image. Returns (rects, tiled, coverage): one integer
    pixel rectangle per box, or None where the card shows the whole figure."""
    H, W = mask.shape
    if comps is None:
        comps = P.ink_components(mask, RADIUS_FRAC)
    boxes = [[f[0] * W, f[1] * H, f[2] * W, f[3] * H] for f in fractions]
    grown = P.complete(boxes, mask, comps, attach_orphans=False, max_iter=MAX_ITER)
    tiled = len(boxes) >= 2 and ink_cover(mask, grown) >= TILE_MIN_COVER
    if tiled:
        grown = P.complete(boxes, mask, comps, attach_orphans=True, max_iter=MAX_ITER, orphan_max_frac=ORPHAN_MAX_FRAC, hold_contained=True)
    own = owners(comps, boxes)
    rects = []
    for k, b in enumerate(grown):
        if cuts(comps, own, boxes, k, b, W, H):
            rects.append(None)
            continue
        x0, y0 = max(0, math.floor(b[0])), max(0, math.floor(b[1]))
        x1, y1 = min(W, math.ceil(b[2])), min(H, math.ceil(b[3]))
        rects.append([int(x0), int(y0), int(x1), int(y1)] if x1 - x0 >= 2 and y1 - y0 >= 2 else None)
    shown = [r if r is not None else [0, 0, W, H] for r in rects]
    return rects, tiled, (ink_cover(mask, shown) if shown else None)
