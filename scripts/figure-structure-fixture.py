#!/usr/bin/env python3
"""Builds the shared framing fixture's stacked figure (`tests/fixtures/figure-crops/stacked-subfigures.png`): three of the
real figures already in the fixtures (DPO Figures 1, 4 and 2) composed exactly as a multi-image figure is composed for a
request (chat-figures.ts `composeFigure`, ChatFigureFinder.composite: each scaled to the widest one's width, top to
bottom, 2 % of the width of white between them), and prints each image's band as fractions of the composite, for the
`exact` parts of the structure cases in framing.json (FIGURE_VIEW.md "Structure first").

Usage: python3 scripts/figure-structure-fixture.py
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
DIR = ROOT / 'tests/fixtures/figure-crops'
NAMES = ['dpo-figure-1.png', 'dpo-figure-4.png', 'dpo-figure-2.png']


def js_round(v):
    return int(v + 0.5)  # Math.round for positive values (Swift .rounded() agrees)


def main():
    images = [Image.open(DIR / name).convert('RGB') for name in NAMES]
    width = max(i.width for i in images)
    gap = max(1, js_round(width * 0.02))
    heights = [js_round(i.height * width / i.width) for i in images]
    height = sum(heights) + gap * (len(images) - 1)
    out = Image.new('RGB', (width, height), (255, 255, 255))
    top, bands = 0, []
    for image, h in zip(images, heights):
        out.paste(image.resize((width, h), Image.LANCZOS), (0, top))
        bands.append((top, top + h))
        top += h + gap
    out.save(DIR / 'stacked-subfigures.png', optimize=True)
    print(width, height)
    for t, b in bands:
        print([0, round(t / height, 6), 1, round(b / height, 6)])


if __name__ == '__main__':
    main()
