#!/usr/bin/env python3
"""Exports the shared golden fixtures for the apps' figure-crop completeness step (`app_crops.py`) to
`tests/fixtures/figure-crops/cases.json`. The Swift (`FigureCropCompletionTests`) and browser
(`figure-crops.test.ts`) ports must reproduce every expected rectangle within 1 px, the component count, the ink
pixel count and the component digest.

Images: three DPO figures from the app's bundled Mathpix sample (ReaderSamples/cd902bcd…, re-encoded losslessly as
PNG so every decoder reads the same pixels) and one matplotlib figure generated for this purpose
(`letters-shared-legend.png`: panel letters outside the axes and a legend shared by the bottom row).

Usage: python3 scripts/subfigure-detector/export_crop_fixtures.py
"""
import hashlib, json
from pathlib import Path

import numpy as np
from PIL import Image

import app_crops as A
import policy as P

ROOT = Path(__file__).resolve().parents[2]
DIR = ROOT / 'tests/fixtures/figure-crops'

# Boxes are fractions [x0, y0, x1, y1] of the image, as the AI writes them (walkthrough boxes are x, y, w, h: the apps
# convert with x1 = x + w). Each case says what it pins.
CASES = [
    ('clipped-axis-labels', 'dpo-figure-2.png', [[0.06, 0.07, 0.48, 0.86], [0.55, 0.07, 0.99, 0.86]],
     'Two boxes on the plotting areas clip titles, tick labels and axis titles: each grows over them.'),
    ('stray-letters-shared-legend', 'letters-shared-legend.png',
     [[0.10, 0.07, 0.475, 0.38], [0.59, 0.07, 0.97, 0.38], [0.10, 0.52, 0.475, 0.83], [0.59, 0.52, 0.97, 0.83]],
     'Four boxes tile the figure: the panel letters outside the axes attach to their panels; the legend shared by the '
     'bottom row would swallow a panel, so it (with its swatches) stays uncovered and the coverage is below 1.'),
    ('partial-set-no-orphans', 'letters-shared-legend.png', [[0.10, 0.07, 0.475, 0.38], [0.59, 0.52, 0.97, 0.83]],
     'Two of four panels boxed: the boxes do not tile the figure, so nothing unowned is attached to them.'),
    ('cannot-complete', 'dpo-figure-4.png', [[0.0, 0.0, 0.42, 1.0], [0.42, 0.0, 1.0, 1.0]],
     'The first box cuts its own panel and growing would take 8% of the other box: that card shows the whole figure.'),
    ('detail-slice-falls-back', 'dpo-figure-2.png', [[0.70, 0.09, 0.93, 0.18]],
     'One detail box over part of a legend inside a plot: it cuts the plot it lies in, so the whole figure is shown.'),
    ('halves', 'dpo-figure-4.png', [[0.0, 0.0, 0.5, 1.0], [0.5, 0.0, 1.0, 1.0]],
     'Left and right halves (the journey fixture boxes) of a two-plot figure: both complete as they are.'),
    ('filled-frames', 'dpo-figure-1.png', [[0.02, 0.05, 0.55, 0.9], [0.62, 0.05, 0.97, 0.9]],
     'Boxes inside two filled, rounded panels grow to the whole panels.'),
    ('detail-inside-filled-panel', 'dpo-figure-1.png', [[0.25, 0.3, 0.42, 0.6]],
     'Known limit: a filled panel background is one figure-wide ink component, so a box inside it is left as is.'),
]


def digest(comps):
    text = ';'.join(f'{int(c[0])},{int(c[1])},{int(c[2])},{int(c[3])},{int(c[4])}' for c in comps)
    return hashlib.sha256(text.encode()).hexdigest()


def main():
    images, cases = {}, []
    for name, image, boxes, about in CASES:
        if image not in images:
            pixels = np.asarray(Image.open(DIR / image).convert('RGB'))
            mask = P.ink_mask(pixels, A.INK_THRESHOLD)
            images[image] = (mask, P.ink_components(mask, A.RADIUS_FRAC))
        mask, comps = images[image]
        H, W = mask.shape
        rects, tiled, coverage = A.app_crops(boxes, mask, comps)
        cases.append({'name': name, 'about': about, 'image': image, 'width': W, 'height': H, 'boxes': boxes,
                      'expect': {'components': len(comps), 'inkPixels': int(mask.sum()), 'componentDigest': digest(comps),
                                 'tiled': tiled, 'crops': rects, 'inkCoverage': round(coverage, 6),
                                 'padding': A.padding(W, H)}})
    out = {'format': 'figure-crop-fixtures-v1',
           'reference': 'scripts/subfigure-detector/app_crops.py (policy.complete with the app options)',
           'parameters': {'inkThreshold': A.INK_THRESHOLD, 'radiusFraction': A.RADIUS_FRAC, 'maxIterations': A.MAX_ITER,
                          'tileMinCover': A.TILE_MIN_COVER, 'orphanMaxFraction': A.ORPHAN_MAX_FRAC,
                          'figureWideFraction': A.FIGURE_WIDE_FRAC, 'otherOwnerFraction': A.OTHER_OWNER_FRAC,
                          'paddingFraction': A.PADDING_FRAC, 'paddingMinimum': A.PADDING_MIN},
           'tolerancePixels': 1, 'cases': cases}
    (DIR / 'cases.json').write_text(json.dumps(out, indent=1) + '\n')
    for c in cases:
        print(c['name'], c['expect']['crops'], c['expect']['tiled'], c['expect']['inkCoverage'])


if __name__ == '__main__':
    main()
