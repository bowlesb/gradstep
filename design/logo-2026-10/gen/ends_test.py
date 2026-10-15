import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from geom import *
OUT = os.path.join(os.path.dirname(__file__), '..', 'renders', 'ends'); os.makedirs(OUT, exist_ok=True)
cur = parabola(-0.02, 1.0, 600)
F = fit_frame([cur], box=(268, 196, 776, 790), optical=(-6, 4)); C = F(cur); w = 112.0
base = 0.58 * w + 0.42 * w * arc_profile(C, 0.0, 1.0, peak=0.42, start=0.5, end=0.62)
for name, wid, cap in [('a-taper', base * taper(len(C), 0.16, 0.20, 1.0), 'round'), ('b-round', base, 'round'), ('c-butt', base, 'butt'),
                       ('d-taper-long', base * taper(len(C), 0.26, 0.30, 0.8), 'round')]:
    o = stroke_outline(C, wid, cap, 14)
    body = f'<rect width="1024" height="1024" fill="#13103C"/><path d="{catmull_rom_path(o, closed=True)}" fill="#F4F1E8"/>'
    open(os.path.join(OUT, name + '.svg'), 'w').write(svg(body, title=name))
