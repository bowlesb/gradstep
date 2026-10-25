"""Writes custom SF Symbol templates (Regular, medium scale) for the Gradstep glyphs.

Each glyph has two layers: the line drawing (hierarchical primary) and the amber point
(hierarchical secondary), so `.symbolRenderingMode(.palette)` can colour them separately.

    python3 -m venv /tmp/icons-venv && /tmp/icons-venv/bin/pip install skia-pathops skia-python
    cd tools/icons && /tmp/icons-venv/bin/python gen_symbols.py \\
        ../../apps/apple/ScienceReader/Resources/Assets.xcassets/Symbols
    /tmp/icons-venv/bin/python preview.py /tmp/icons.png feed,library_amber_spine,paper,chat,gear

Glyphs are drawn in glyphs.py (rounded strokes like the Nabla logo, outlined with skia-pathops).
"""
import json
import os
import sys

import pathops
from glyphs import GLYPHS, minus

K = 1.0             # design box (100) → template units (cap height 70.459 at 100 pt)
CENTER = -35.2295   # vertical centre of the cap height
BEARING = 2.0
X0, BASE = 1391.0, 1126.0

TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <!--glyph: "{name}", point size: 100.0, template writer version: "Gradstep icon script 1"-->
 <style>.monochrome-0 {{-sfsymbols-motion-group:0}}
.monochrome-1 {{-sfsymbols-motion-group:1}}
.hierarchical-0:primary {{-sfsymbols-motion-group:0}}
.hierarchical-1:secondary {{-sfsymbols-motion-group:1}}
</style>
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
  <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1953)">{name}</text>
 </g>
 <g id="Guides">
  <line id="Baseline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="696" y2="696"/>
  <line id="Capline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="625.541" y2="625.541"/>
  <line id="Baseline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1126" y2="1126"/>
  <line id="Capline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1055.54" y2="1055.54"/>
  <line id="Baseline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1556" y2="1556"/>
  <line id="Capline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
{margins}
 </g>
 <g id="Symbols">
{groups}
 </g>
</svg>
"""

# Symbol scales: (name, baseline y in the template, size relative to medium). Bar buttons and menus ask
# for small or large glyphs; a template with only Regular-M draws nothing there.
SCALES = [("S", 696.0, 0.8), ("M", 1126.0, 1.0), ("L", 1556.0, 1.25)]
MARGIN = ('  <line id="{side}-margin-Regular-{scale}" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" '
          'x1="{x:.3f}" x2="{x:.3f}" y1="{y0:.0f}" y2="{y1:.0f}"/>')


class SVGPen:
    def __init__(self, transform):
        self.t = transform
        self.d = []

    def _p(self, pt):
        x, y = self.t(pt)
        return f"{x:.3f} {y:.3f}"

    def moveTo(self, pt):
        self.d.append("M" + self._p(pt))

    def lineTo(self, pt):
        self.d.append("L" + self._p(pt))

    def curveTo(self, *pts):
        self.d.append("C" + " ".join(self._p(p) for p in pts))

    def qCurveTo(self, *pts):
        offs, end = pts[:-1], pts[-1]
        for i, off in enumerate(offs):
            nxt = end if i == len(offs) - 1 else ((off[0] + offs[i + 1][0]) / 2, (off[1] + offs[i + 1][1]) / 2)
            self.d.append("Q" + self._p(off) + " " + self._p(nxt))

    def closePath(self):
        self.d.append("Z")

    def endPath(self):
        pass


def bounds(layers):
    boxes = [p.bounds for _, p in layers if p.bounds != (0, 0, 0, 0)]
    return (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))


def symbol_svg(name, layers):
    # The point is drawn on top; cut it out of the line layer so the layers never overlap.
    point = [p for layer, p in layers if layer == 'point'][0]
    line = minus([p for layer, p in layers if layer == 'line'][0], point)
    x0, y0, x1, y1 = bounds([('line', line), ('point', point)])
    # Centre the drawing's own box (not the design box) on the cap height.
    mid = (y0 + y1) / 2

    margins, groups = [], []
    for scale, baseline, size in SCALES:
        k = K * size

        def transform(pt, k=k):
            return ((pt[0] - x0) * k + BEARING, (pt[1] - mid) * k + CENTER)

        paths = []
        for index, (path, level) in enumerate([(line, 'primary'), (point, 'secondary')]):
            if path.bounds == (0, 0, 0, 0) or (path.bounds[2] - path.bounds[0]) < 0.5:
                continue
            pen = SVGPen(transform)
            path.draw(pen)
            paths.append(f'   <path class="monochrome-{index} hierarchical-{index}:{level}" d="{" ".join(pen.d)}"/>')
        width = (x1 - x0) * k + 2 * BEARING
        for side, x in (("left", X0), ("right", X0 + width)):
            margins.append(MARGIN.format(side=side, scale=scale, x=x, y0=baseline - 96, y1=baseline + 24))
        groups.append(f'  <g id="Regular-{scale}" transform="matrix(1 0 0 1 {X0:.3f} {baseline:.0f})">\n'
                      + "\n".join(paths) + "\n  </g>")
    return TEMPLATE.format(name=name, margins="\n".join(margins), groups="\n".join(groups))


def write_symbolset(folder, name, layers):
    path = os.path.join(folder, f"{name}.symbolset")
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, f"{name}.svg"), "w") as f:
        f.write(symbol_svg(name, layers))
    with open(os.path.join(path, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1},
                   "symbols": [{"filename": f"{name}.svg", "idiom": "universal"}]}, f, indent=2)
        f.write("\n")


SYMBOLS = {  # asset name → glyph (GradstepSymbol in Views/Chrome.swift)
    "gradstep.feed": "feed", "gradstep.library": "library_amber_spine", "gradstep.paper": "paper",
    "gradstep.chat": "chat", "gradstep.settings": "gear", "gradstep.chat.new": "chat_new",
    "gradstep.chats": "chats", "gradstep.contents": "contents", "gradstep.mark": "nabla", "gradstep.notes": "notes",
    "gradstep.more": "more",
}

if __name__ == "__main__":
    folder = sys.argv[1]
    # Optional second argument: symbolName=glyphKey,… (a subset or other glyphs, for studies).
    mapping = dict(pair.split("=") for pair in sys.argv[2].split(",")) if len(sys.argv) > 2 else SYMBOLS
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False}}, f, indent=2)
        f.write("\n")
    for symbol, key in mapping.items():
        write_symbolset(folder, symbol, GLYPHS[key]())
        print("wrote", symbol)
