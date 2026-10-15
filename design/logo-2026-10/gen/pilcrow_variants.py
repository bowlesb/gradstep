"""Pilcrow bowls: which construction reads as a paragraph mark, stays a parabola, and looks drawn rather than cut."""
import math, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from geom import *
from marks import PAPER, PAPER_SHADE, DEEP0, DEEP1, SOFT, WARM

OUT = os.path.join(os.path.dirname(__file__), '..', 'renders', 'pilcrow-variants'); os.makedirs(OUT, exist_ok=True)
top, bottom, s1x, s2x, sw, bar = 196.0, 828.0, 556.0, 690.0, 62.0, 52.0
vxr = s1x - sw / 2


def write(name, bowl, amber=True, ghost=None):
    stems = (f'<rect x="{fmt(s1x - sw / 2)}" y="{top}" width="{sw}" height="{bottom - top}" fill="{PAPER}"/>'
             f'<rect x="{fmt(s2x - sw / 2)}" y="{top}" width="{sw}" height="{bottom - top}" fill="{WARM if amber else PAPER}"/>'
             f'<rect x="{fmt(vxr - 2)}" y="{top}" width="{fmt(s1x + sw / 2 - vxr + 2 if amber else s2x + sw / 2 - vxr + 2)}" height="{bar}" fill="{PAPER}"/>')
    g = f'<path d="{polyline(ghost)}" fill="none" stroke="{SOFT}" stroke-width="2.6" opacity="0.32"/>' if ghost is not None else ''
    body = (f'<rect width="1024" height="1024" fill="{DEEP1}"/>{g}<path d="{catmull_rom_path(bowl, closed=True)}" fill="{PAPER}"/>{stems}')
    open(os.path.join(OUT, name + '.svg'), 'w').write(svg(body, title=name))

# p2: the D bowl: a sideways parabola x = xl + c (y - ym)² between the top bar and the bowl's bottom, closed by the stem
ym, h, xl = 400.0, 204.0, 300.0
c = (vxr - xl) / h ** 2
y = np.linspace(ym - h, ym + h, 260); x = xl + c * (y - ym) ** 2
bowl = np.vstack([np.stack([x, y], 1), [[vxr, ym + h], [vxr, ym - h]]])
y2 = np.linspace(ym - h * 1.5, ym + h * 1.5, 200)
write('p2-D', np.vstack([np.stack([x, y], 1)[::-1], [[vxr, ym - h]], [[vxr, ym + h]]])[::-1], ghost=np.stack([xl + c * (y2 - ym) ** 2, y2], 1))

# p3: the teardrop: the lower half of that sideways parabola (vertex at the far left, curving down into the stem),
# and above the vertex a quarter-ellipse up into the top bar: round at the top-left, tapering into the stem
ym3, xl3 = 360.0, 296.0; yb3 = 640.0
c3 = (vxr - xl3) / (yb3 - ym3) ** 2
yl = np.linspace(ym3, yb3, 200); lower = np.stack([xl3 + c3 * (yl - ym3) ** 2, yl], 1)
th = np.linspace(math.pi, 1.5 * math.pi, 120)
rx, ry = (vxr - xl3) * 0.62, ym3 - top
cxe, cye = xl3 + rx, ym3
upper = np.stack([cxe + rx * np.cos(th), cye + ry * np.sin(th)], 1)  # from (xl3, ym3) up to (cxe, top)
tear = np.vstack([upper[::-1], lower, [[vxr, yb3]], [[vxr, top]]])
# order: from top (cxe, top) along the ellipse down to the vertex, down the parabola to the stem, up the stem, back
tear = np.vstack([upper[::-1][::-1][::-1], lower[1:], [[vxr, yb3], [vxr, top]]])
yg = np.linspace(ym3 - (yb3 - ym3), ym3, 160)
write('p3-teardrop', np.vstack([[[cxe, top]], upper[::-1][1:][::-1][::-1], lower[1:], [[vxr, yb3], [vxr, top]]]), ghost=np.stack([xl3 + c3 * (yg - ym3) ** 2, yg], 1))

# p4: the half-parabola bowl with its axis vertical and its vertex at the bowl's lowest point under the middle, the
# stem side a straight drop: a softer version of the round-1 cup, the top-left corner eased by the curve's own slope
xv4, yb4 = 430.0, 610.0; c4 = (yb4 - top) / (xv4 - 270) ** 2
xs = np.linspace(270, xv4, 200); left4 = np.stack([xs, yb4 - c4 * (xv4 - xs) ** 2], 1)
bowl4 = np.vstack([left4, [[vxr, yb4], [vxr, top]]])
write('p4-cup-soft', bowl4)
print('variants written')
