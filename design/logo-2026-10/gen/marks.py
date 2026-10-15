"""The developed marks: each as layered SVG (background / middle / foreground) for a large icon, plus a reduced small
glyph. Every coordinate is computed from the curve, its derivative, or a stated proportion.

    python3 gen/marks.py <out_dir>        writes <name>/{icon,background,middle,foreground,glyph}.svg"""
import math, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from geom import *

PAPER = '#F4F1E8'; PAPER_SHADE = '#E6E1D3'
DEEP0, DEEP1 = '#2C2980', '#13103C'
INDIGO = '#2A2774'; SOFT = '#9EA6FF'; RIM = '#8C93FF'
WARM = '#EBA83A'; WARM_HI = '#F7C969'


def clip_line(p, d, box):
    t0, t1 = -1e9, 1e9
    for i, (lo, hi) in enumerate([(box[0], box[2]), (box[1], box[3])]):
        if abs(d[i]) > 1e-9:
            a, b = sorted([(lo - p[i]) / d[i], (hi - p[i]) / d[i]])
            t0, t1 = max(t0, a), min(t1, b)
    return t0, t1


def grain(id_='grain', opacity=0.05, freq=0.85):
    return (f'<filter id="{id_}" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency="{freq}" numOctaves="2" seed="7" stitchTiles="stitch"/>'
            f'<feColorMatrix type="matrix" values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 {opacity} 0"/></filter>')


class Mark:
    def __init__(self, name):
        self.name = name; self.defs = []; self.bg = []; self.mid = []; self.fg = []; self.glyph_defs = []; self.glyph = []

    def write(self, root):
        d = os.path.join(root, self.name); os.makedirs(d, exist_ok=True)
        defs = ''.join(self.defs)
        layers = {'background': self.bg, 'middle': self.mid, 'foreground': self.fg}
        for k, v in layers.items():
            open(os.path.join(d, f'{k}.svg'), 'w').write(svg(f'<g id="{k}">{"".join(v)}</g>', defs, title=f'Gradstep {self.name}: {k}'))
        full = ''.join(f'<g id="{k}">{"".join(v)}</g>' for k, v in layers.items())
        open(os.path.join(d, 'icon.svg'), 'w').write(svg(full, defs, title=f'Gradstep {self.name}: app icon'))
        open(os.path.join(d, 'glyph.svg'), 'w').write(svg(''.join(self.glyph), ''.join(self.glyph_defs), title=f'Gradstep {self.name}: small glyph'))


# =====================================================================================================================
# PAGE: a half-parabola divides the icon. Dark above (the field), paper below (the page, and graph paper up close).
# The tangent at the knee lies in the paper and touches the edge once. Up close: occlusion along the edge (the page
# lifting), a rim light on the dark side, graph-paper hairlines, ghost secants above the curve converging on the
# tangent, fine grain. Far: two tones and one amber line.
# =====================================================================================================================
def page(variant='dark'):
    m = Mark('page' if variant == 'dark' else 'page-light')
    vx, vy = -20.0, 790.0          # vertex just off the left edge: the knee is in view, the flat half is not
    ex = 1000.0                    # the curve leaves the top edge here
    k = vy / (ex - vx) ** 2        # y = vy - k (x - vx)²  reaches y = 0 at x = ex
    f = lambda x: vy - k * (x - vx) ** 2
    df = lambda x: -2 * k * (x - vx)
    xs = np.linspace(vx, ex + 40, 500)
    cur = np.stack([xs, f(xs)], 1)
    region = np.vstack([[[-80, vy]], cur, [[1104, -120], [1104, 1104], [-80, 1104]]])
    xt = 300.0                     # the tangent's point: where the curve visibly bends (slope ≈ -0.49)
    T = np.array([xt, f(xt)]); d = np.array([1.0, df(xt)]); d /= np.linalg.norm(d)
    nrm = np.array([d[1], -d[0]])  # points below/right of the curve (into the paper)
    dark_top, dark_bottom = (DEEP0, DEEP1) if variant == 'dark' else ('#EDE9DE', '#E2DDCF')
    paper = PAPER if variant == 'dark' else '#2A2774'
    m.defs += [
        f'<linearGradient id="pg-field" x1="0" y1="0" x2="0.35" y2="1"><stop offset="0" stop-color="{dark_top}"/><stop offset="1" stop-color="{dark_bottom}"/></linearGradient>',
        f'<radialGradient id="pg-glow" cx="{fmt(T[0] + 120)}" cy="{fmt(T[1] - 260)}" r="560" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#4A46C0" stop-opacity="{0.45 if variant == "dark" else 0.0}"/><stop offset="1" stop-color="#4A46C0" stop-opacity="0"/></radialGradient>',
        f'<clipPath id="pg-paper"><path d="{polyline(region)}Z"/></clipPath>',
        f'<clipPath id="pg-sky"><path d="M-80 -120L{polyline(cur[::-1])[1:]}L-80 {fmt(vy)}Z"/></clipPath>',
        '<filter id="pg-blur" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="30"/></filter>',
        f'<linearGradient id="pg-sheet" gradientUnits="userSpaceOnUse" x1="{fmt(T[0])}" y1="{fmt(T[1])}" x2="{fmt(T[0] + nrm[0] * 700)}" y2="{fmt(T[1] + nrm[1] * 700)}"><stop offset="0" stop-color="{PAPER_SHADE if variant == "dark" else "#221F63"}"/><stop offset="0.35" stop-color="{paper}"/><stop offset="1" stop-color="{paper}"/></linearGradient>',
        grain('pg-grain', 0.05 if variant == 'dark' else 0.035),
    ]
    # background: the field, its glow, grain
    m.bg += ['<rect width="1024" height="1024" fill="url(#pg-field)"/>', '<rect width="1024" height="1024" fill="url(#pg-glow)"/>',
             '<rect width="1024" height="1024" filter="url(#pg-grain)"/>']
    # middle: the page, its shading toward the edge, graph-paper hairlines, occlusion, rim light, ghost secants
    grid = ''.join(f'<path d="M{x} -10V1034" />' for x in range(64, 1024, 64)) + ''.join(f'<path d="M-10 {y}H1034" />' for y in range(64, 1024, 64))
    ink = INDIGO if variant == 'dark' else PAPER
    m.mid += [f'<path d="{polyline(region)}Z" fill="url(#pg-sheet)"/>',
              f'<g clip-path="url(#pg-paper)" stroke="{ink}" stroke-width="1.6" opacity="0.07" fill="none">{grid}</g>',
              f'<g clip-path="url(#pg-paper)"><path d="{polyline(cur)}" stroke="#0F0C33" stroke-width="70" fill="none" opacity="0.30" filter="url(#pg-blur)"/></g>',
              f'<g clip-path="url(#pg-sky)"><path d="{polyline(cur)}" stroke="{RIM if variant == "dark" else "#FFFFFF"}" stroke-width="7" fill="none" opacity="0.55"/></g>']
    # ghost secants: chords from T to points further up the curve, above the curve (in the field), fading in
    for i, x2 in enumerate([760.0, 600.0, 470.0, 390.0]):
        Q = np.array([x2, f(x2)]); u = (Q - T) / np.linalg.norm(Q - T)
        a, b = T - u * 40, Q + u * 120
        m.mid.append(f'<path d="M{fmt(a[0])} {fmt(a[1])}L{fmt(b[0])} {fmt(b[1])}" stroke="{SOFT if variant == "dark" else INDIGO}" stroke-width="3" opacity="{0.10 + 0.06 * i:.2f}" clip-path="url(#pg-sky)"/>')
    # foreground: the tangent, tapered at both ends, touching at T; a bright core at the point of contact
    t0, t1 = -330.0, 470.0
    n = 120
    c = np.array([T + d * t for t in np.linspace(t0, t1, n)])
    prof = np.interp(np.linspace(t0, t1, n), [t0, t0 + 140, 0, t1 - 160, t1], [0, 18, 22, 18, 0])
    # sit the line's upper edge on the curve: shift the centre line half its width into the paper
    c = c + nrm * (prof[:, None] / 2) * 0 + nrm * 11
    m.fg.append(f'<path d="{stroke_path(c, prof, "butt")}" fill="{WARM}"/>')
    m.fg.append(f'<circle cx="{fmt(T[0] + nrm[0] * 11)}" cy="{fmt(T[1] + nrm[1] * 11)}" r="7" fill="{WARM_HI}"/>')
    # ---- the small glyph: two tones and a heavier tangent, nothing else -------------------------------------------
    gk = vy / (ex - vx) ** 2
    m.glyph_defs.append(f'<clipPath id="g-sq"><rect width="1024" height="1024"/></clipPath>')
    tl = [T + d * t + nrm * 30 for t in (-420.0, 560.0)]
    m.glyph += [f'<rect width="1024" height="1024" fill="{DEEP1 if variant == "dark" else "#E9E5D9"}"/>',
                f'<path d="{polyline(region)}Z" fill="{paper}"/>',
                f'<path d="M{fmt(tl[0][0])} {fmt(tl[0][1])}L{fmt(tl[1][0])} {fmt(tl[1][1])}" stroke="{WARM}" stroke-width="64" clip-path="url(#g-sq)"/>']
    return m


# =====================================================================================================================
# NIB: the half-parabola written with a broad nib (thick through the bend, hairline at the ends); the tangent, a fine
# amber line, rests against the stroke's outer edge at one point. Up close: the mathematical curve continues as a
# hairline past the ink, small ticks where the tangent meets it, a rim on the ink.
# =====================================================================================================================
def nib():
    m = Mark('nib')
    a = 1.0
    cur = parabola(-0.04, 1.0, 500, a)
    F = fit_frame([cur], box=(250, 210, 790, 790), optical=(-10, 26))
    C = F(cur)
    w = 104.0
    wid = nib_widths(C, w * 0.10, w, 28) * taper(len(C), 0.05, 0.16, 1.4)
    out = stroke_outline(C, wid, 'round', 8)
    # tangent at u, touching the outer (lower-right) edge of the ink
    i = int(0.36 * len(C)); Tc = C[i]; tdir = C[i + 1] - C[i - 1]; tdir /= np.linalg.norm(tdir)
    nrm = np.array([tdir[1], -tdir[0]])
    if nrm[1] < 0: nrm = -nrm  # toward lower-right (outside of the convex bend)
    T = Tc + nrm * (wid[i] / 2)
    m.defs += [f'<linearGradient id="nb-field" x1="0" y1="0" x2="0.3" y2="1"><stop offset="0" stop-color="{DEEP0}"/><stop offset="1" stop-color="{DEEP1}"/></linearGradient>',
               f'<linearGradient id="nb-ink" gradientUnits="userSpaceOnUse" x1="{fmt(C[0][0])}" y1="{fmt(C[0][1])}" x2="{fmt(C[-1][0])}" y2="{fmt(C[-1][1])}"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="{PAPER_SHADE}"/></linearGradient>',
               grain('nb-grain', 0.05)]
    m.bg += ['<rect width="1024" height="1024" fill="url(#nb-field)"/>', '<rect width="1024" height="1024" filter="url(#nb-grain)"/>']
    # middle: the mathematical curve continuing as a hairline beyond the ink, both ways
    ext = parabola(-0.42, 1.12, 400, a)
    m.mid.append(f'<path d="{polyline(F(ext))}" fill="none" stroke="{SOFT}" stroke-width="3" opacity="0.32"/>')
    m.fg.append(f'<path d="{catmull_rom_path(out, closed=True)}" fill="url(#nb-ink)"/>')
    t0, t1 = clip_line(T, tdir, (60, 60, 964, 964))
    a0, a1 = T + tdir * t0 * 0.92, T + tdir * t1 * 0.92
    m.fg.append(f'<path d="M{fmt(a0[0])} {fmt(a0[1])}L{fmt(a1[0])} {fmt(a1[1])}" stroke="{WARM}" stroke-width="13" stroke-linecap="round"/>')
    # small ticks across the tangent at the contact point (a draughtsman's mark), up close only
    for s in (-1, 1):
        q = T + tdir * s * 26
        m.fg.append(f'<path d="M{fmt(q[0] - nrm[0] * 14)} {fmt(q[1] - nrm[1] * 14)}L{fmt(q[0] + nrm[0] * 14)} {fmt(q[1] + nrm[1] * 14)}" stroke="{WARM}" stroke-width="3" opacity="0.7"/>')
    # glyph: the ink only, heavier, and the tangent thicker
    wg = nib_widths(C, 150 * 0.32, 150, 28) * taper(len(C), 0.03, 0.08, 1.2)
    og = stroke_outline(C, wg, 'round', 8)
    Tg = Tc + nrm * (wg[i] / 2 + 6)
    g0, g1 = Tg + tdir * t0 * 0.8, Tg + tdir * t1 * 0.8
    m.glyph += [f'<rect width="1024" height="1024" fill="{DEEP1}"/>', f'<path d="{catmull_rom_path(og, closed=True)}" fill="{PAPER}"/>',
                f'<path d="M{fmt(g0[0])} {fmt(g0[1])}L{fmt(g1[0])} {fmt(g1[1])}" stroke="{WARM}" stroke-width="54" stroke-linecap="round"/>']
    return m


# =====================================================================================================================
# DESCENT: gradient descent on a parabola, drawn as its steps. Each step is a tangent segment from x_k toward
# x_{k+1} = x_k - η f'(x_k), so the steps shrink geometrically into the minimum, where a point rests. The parabola
# itself is only a hairline up close; far away the steps are the mark.
# =====================================================================================================================
def descent():
    m = Mark('descent')
    a, eta = 1.0, 0.24
    xs = [1.0]
    for _ in range(5): xs.append(xs[-1] - eta * 2 * a * xs[-1])
    cur = parabola(-0.25, 1.08, 300, a)
    F = fit_frame([cur], box=(210, 230, 814, 790), optical=(0, 20))
    m.defs += [f'<linearGradient id="ds-field" x1="0" y1="0" x2="0.3" y2="1"><stop offset="0" stop-color="{DEEP0}"/><stop offset="1" stop-color="{DEEP1}"/></linearGradient>', grain('ds-grain', 0.05)]
    m.bg += ['<rect width="1024" height="1024" fill="url(#ds-field)"/>', '<rect width="1024" height="1024" filter="url(#ds-grain)"/>']
    m.mid.append(f'<path d="{polyline(F(cur))}" fill="none" stroke="{SOFT}" stroke-width="3" opacity="0.35"/>')
    steps = ''; gsteps = ''
    for k in range(len(xs) - 1):
        x0, x1 = xs[k], xs[k + 1]
        p = np.array([x0, a * x0 * x0]); m_ = 2 * a * x0
        q = np.array([x1, a * x0 * x0 + m_ * (x1 - x0)])          # along the tangent to x1 (below the curve)
        P0, Q0 = F(np.array([p, q]))
        gap = 0.13  # each step leaves a small gap before the next begins (the evaluation)
        Pm = P0 + (Q0 - P0) * 0.0; Qm = P0 + (Q0 - P0) * (1 - gap)
        w = max(16, 54 * (0.78 ** k))
        steps += f'<path d="{stroke_path(np.linspace(Pm, Qm, 30), np.full(30, w), "round")}" fill="{PAPER}"/>'
        gsteps += f'<path d="{stroke_path(np.linspace(Pm, Qm, 30), np.full(30, max(40, w * 1.7)), "round")}" fill="{PAPER}"/>' if k < 3 else ''
    xm = F(np.array([[0, 0]]))[0]
    m.fg += [steps, f'<circle cx="{fmt(xm[0])}" cy="{fmt(xm[1])}" r="30" fill="{WARM}"/>']
    m.glyph += [f'<rect width="1024" height="1024" fill="{DEEP1}"/>', gsteps, f'<circle cx="{fmt(xm[0])}" cy="{fmt(xm[1])}" r="62" fill="{WARM}"/>']
    return m


# =====================================================================================================================
# PARTIAL: ∂, the sign of differentiation, constructed like a letter: an oval bowl and a stem rising from its right
# side that bends back to a tapered terminal; broad-nib contrast at 30°.
# =====================================================================================================================
def partial():
    m = Mark('partial')
    tilt = math.radians(-14)
    R = np.array([[math.cos(tilt), -math.sin(tilt)], [math.sin(tilt), math.cos(tilt)]])
    th = np.linspace(0, 2 * math.pi, 360)
    bowl = (np.stack([0.43 * np.cos(th), 0.38 * np.sin(th)], 1) @ R.T) + np.array([-0.08, -0.52])
    # the stem leaves the bowl tangentially at its right-hand side and sweeps up and left (a cubic)
    j = np.argmax(bowl[:, 0]); p0 = bowl[j]
    p1 = p0 + np.array([0.02, 0.62]); p2 = np.array([0.30, 1.02]); p3 = np.array([-0.30, 1.0])
    t = np.linspace(0, 1, 300)[:, None]
    stem = (1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t * t * p2 + t ** 3 * p3
    F = fit_frame([bowl, stem], box=(270, 180, 754, 844), optical=(8, 0))
    B, S = F(bowl), F(stem)
    w = 96.0
    wb = nib_widths(B, w * 0.22, w, 32); ws = nib_widths(S, w * 0.22, w, 32) * taper(len(S), 0, 0.22, 1.3)
    m.defs += [f'<linearGradient id="pt-field" x1="0" y1="0" x2="0.3" y2="1"><stop offset="0" stop-color="{DEEP0}"/><stop offset="1" stop-color="{DEEP1}"/></linearGradient>', grain('pt-grain', 0.05)]
    m.bg += ['<rect width="1024" height="1024" fill="url(#pt-field)"/>', '<rect width="1024" height="1024" filter="url(#pt-grain)"/>']
    ob = stroke_outline(np.vstack([B, B[:4]]), np.concatenate([wb, wb[:4]]), 'butt')
    m.fg += [f'<path d="{catmull_rom_path(stroke_outline(B, wb, "butt"), closed=True)}" fill="{PAPER}"/>',
             f'<path d="{catmull_rom_path(stroke_outline(S, ws, "round"), closed=True)}" fill="{PAPER}"/>']
    m.glyph += [f'<rect width="1024" height="1024" fill="{DEEP1}"/>',
                f'<path d="{catmull_rom_path(stroke_outline(B, nib_widths(B, 150 * 0.4, 150, 32), "butt"), closed=True)}" fill="{PAPER}"/>',
                f'<path d="{catmull_rom_path(stroke_outline(S, nib_widths(S, 150 * 0.4, 150, 32) * taper(len(S), 0, 0.15, 1.3), "round"), closed=True)}" fill="{PAPER}"/>']
    return m


if __name__ == '__main__':
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', 'renders', 'round3')
    for mk in (page('dark'), page('light'), nib(), descent(), partial()):
        mk.write(root)
    print('written to', root)
