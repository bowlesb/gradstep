"""Finalists, built to be judged: layered icon (background / middle / foreground), small glyph, lockups.
    python3 gen/finalists.py            -> finalists/<name>/..."""
import math, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from geom import *
from marks import Mark, grain, clip_line, PAPER, PAPER_SHADE, DEEP0, DEEP1, INDIGO, SOFT, RIM, WARM, WARM_HI
import wordmark

ROOT = os.path.join(os.path.dirname(__file__), '..', 'finalists')
FIELD = lambda id_: f'<linearGradient id="{id_}" x1="0" y1="0" x2="0.3" y2="1"><stop offset="0" stop-color="{DEEP0}"/><stop offset="1" stop-color="{DEEP1}"/></linearGradient>'


# =====================================================================================================================
# TANGENT. A half-parabola written with a broad nib, and its tangent: a fine amber line resting against the outer edge
# of the ink at one point. Far: a stroke and a line that touch. Near: the true parabola continues as a hairline past
# the ink both ways, two draughtsman's ticks mark the contact, the ink carries a faint tonal sweep, grain.
# =====================================================================================================================
def tangent_mark(ink=PAPER, field=True):
    m = Mark('tangent')
    a = 1.0
    cur = parabola(-0.02, 1.0, 600, a)
    F = fit_frame([cur], box=(268, 196, 776, 790), optical=(-6, 4))
    C = F(cur)
    w = 112.0
    wid = 0.58 * w + 0.42 * w * arc_profile(C, 0.0, 1.0, peak=0.42, start=0.5, end=0.62)   # a gentle swell; ends cut along the normal
    out = stroke_outline(C, wid, 'butt', 10)
    # the contact: in the bend (where the line leaves the ink quickly), on the ink's outer edge; the line's own edge
    # touches it, so its centre sits half its width further out
    LW = 15.0
    i = int(0.24 * len(C)); tdir = C[i + 3] - C[i - 3]; tdir /= np.linalg.norm(tdir)
    nrm = np.array([tdir[1], -tdir[0]]);  nrm = -nrm if nrm[1] < 0 else nrm
    edge = C + normals(C) * 0  # (kept for clarity)
    T = C[i] + nrm * (wid[i] / 2 + LW / 2)
    t0, t1 = clip_line(T, tdir, (96, 96, 928, 928))
    m.defs += [FIELD('tg-field'), grain('tg-grain', 0.05),
               f'<linearGradient id="tg-ink" gradientUnits="userSpaceOnUse" x1="{fmt(C[0][0])}" y1="{fmt(C[0][1])}" x2="{fmt(C[-1][0])}" y2="{fmt(C[-1][1])}"><stop offset="0" stop-color="#FFFFFF"/><stop offset="0.55" stop-color="{PAPER}"/><stop offset="1" stop-color="{PAPER_SHADE}"/></linearGradient>',
               f'<radialGradient id="tg-glow" cx="{fmt(T[0])}" cy="{fmt(T[1])}" r="520" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#4C48C6" stop-opacity="0.42"/><stop offset="1" stop-color="#4C48C6" stop-opacity="0"/></radialGradient>']
    if field:
        m.bg += ['<rect width="1024" height="1024" fill="url(#tg-field)"/>', '<rect width="1024" height="1024" fill="url(#tg-glow)"/>',
                 '<rect width="1024" height="1024" filter="url(#tg-grain)"/>']
    ext = F(parabola(-0.46, 1.10, 120, a))
    m.mid.append(f'<path d="{polyline(ext)}" fill="none" stroke="{SOFT}" stroke-width="2.6" opacity="0.30"/>')
    m.fg.append(f'<path d="{stroke_path_clean(C, wid)}" fill="url(#tg-ink)"/>')
    A, B = T + tdir * t0, T + tdir * t1
    m.fg.append(f'<path d="M{fmt(A[0])} {fmt(A[1])}L{fmt(B[0])} {fmt(B[1])}" stroke="{WARM}" stroke-width="{LW}" stroke-linecap="round"/>')
    for s in (-1, 1):
        q = T + tdir * s * 30
        m.fg.append(f'<path d="M{fmt(q[0] - nrm[0] * 15)} {fmt(q[1] - nrm[1] * 15)}L{fmt(q[0] + nrm[0] * 15)} {fmt(q[1] + nrm[1] * 15)}" stroke="{WARM}" stroke-width="3.2" opacity="0.75"/>')
    # small glyph: heavier ink (lower contrast), a thick tangent, no hairlines
    wg = 0.72 * 156 + 0.28 * 156 * arc_profile(C, 0.0, 1.0, peak=0.42, start=0.5, end=0.62)
    og = stroke_outline(C, wg, 'butt', 10)
    Tg = C[i] + nrm * (wg[i] / 2 + 29 + 6)
    g0, g1 = Tg + tdir * t0 * 0.86, Tg + tdir * t1 * 0.86
    m.glyph += ([f'<rect width="1024" height="1024" fill="{DEEP1}"/>'] if field else []) + [
        f'<path d="{stroke_path_clean(C, wg)}" fill="{ink}"/>',
        f'<path d="M{fmt(g0[0])} {fmt(g0[1])}L{fmt(g1[0])} {fmt(g1[1])}" stroke="{WARM}" stroke-width="58" stroke-linecap="round"/>']
    m.flat = [f'<path d="{stroke_path_clean(C, wg)}" fill="CURRENT"/>',
              f'<path d="M{fmt(g0[0])} {fmt(g0[1])}L{fmt(g1[0])} {fmt(g1[1])}" stroke="{WARM}" stroke-width="58" stroke-linecap="round"/>']
    return m


# =====================================================================================================================
# PILCROW. The paragraph mark the product cites with: its bowl is half a parabola, its vertex resting on the first
# stem where the curve is level; the second stem is the line beside it. Near: the bowl's other half, ghosted, shows
# it is a parabola; the bowl is modelled lighter toward the curve; grain.
# =====================================================================================================================
def pilcrow_mark(amber_stem=True):
    m = Mark('pilcrow')
    top, bottom = 196.0, 828.0
    s1x, s2x, sw, bar = 556.0, 690.0, 62.0, 52.0
    vxr = s1x - sw / 2                         # the bowl's straight side is the first stem
    # the bowl: below its vertex (at the far left) the lower half of a sideways parabola curves down into the stem;
    # above it a quarter-ellipse rises into the top bar. Round at the top-left, tapering into the stem.
    ym, xl, yb = 360.0, 296.0, 640.0
    c = (vxr - xl) / (yb - ym) ** 2
    yl = np.linspace(ym, yb, 240); lower = np.stack([xl + c * (yl - ym) ** 2, yl], 1)
    rx, ry = (vxr - xl) * 0.62, ym - top
    th = np.linspace(1.5 * math.pi, math.pi, 160)
    upper = np.stack([xl + rx + rx * np.cos(th), ym + ry * np.sin(th)], 1)   # from the bar down to the vertex
    bowl = np.vstack([upper, lower[1:], [[vxr + 1, yb], [vxr + 1, top]]])
    # the bowl and the first stem as one outline (one light, no seam): down the bowl, down the stem, up its right side
    glyph1 = np.vstack([upper, lower[1:], [[vxr, bottom], [s1x + sw / 2, bottom], [s1x + sw / 2, top]]])
    yg = np.linspace(ym - (yb - ym) * 0.95, ym, 180); ghost = np.stack([xl + c * (yg - ym) ** 2, yg], 1)
    m.defs += [FIELD('pc-field'), grain('pc-grain', 0.05),
               f'<linearGradient id="pc-bowl" gradientUnits="userSpaceOnUse" x1="{xl}" y1="{top}" x2="{s1x + 60}" y2="{bottom}"><stop offset="0" stop-color="#FFFFFF"/><stop offset="0.5" stop-color="{PAPER}"/><stop offset="1" stop-color="{PAPER_SHADE}"/></linearGradient>',
               # the stem's own light falls the same way, so bowl and stem meet without a seam
               f'<linearGradient id="pc-stem" gradientUnits="userSpaceOnUse" x1="0" y1="{top}" x2="0" y2="{bottom}"><stop offset="0" stop-color="{PAPER}"/><stop offset="1" stop-color="{PAPER_SHADE}"/></linearGradient>',
               f'<linearGradient id="pc-amber" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{WARM_HI}"/><stop offset="1" stop-color="{WARM}"/></linearGradient>',
               f'<radialGradient id="pc-glow" cx="430" cy="360" r="560" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#4C48C6" stop-opacity="0.40"/><stop offset="1" stop-color="#4C48C6" stop-opacity="0"/></radialGradient>']
    m.bg += ['<rect width="1024" height="1024" fill="url(#pc-field)"/>', '<rect width="1024" height="1024" fill="url(#pc-glow)"/>',
             '<rect width="1024" height="1024" filter="url(#pc-grain)"/>']
    # near: the parabola's other half, ghosted, and its axis as a hairline
    m.mid += [f'<path d="{polyline(ghost)}" fill="none" stroke="{SOFT}" stroke-width="2.6" opacity="0.34"/>',
              f'<path d="M{fmt(xl - 70)} {fmt(ym)}H{fmt(vxr)}" stroke="{SOFT}" stroke-width="2" opacity="0.2"/>']
    s2 = 'url(#pc-amber)' if amber_stem else PAPER
    m.fg += [f'<path d="{polyline(glyph1)}Z" fill="url(#pc-bowl)"/>',
             f'<rect x="{fmt(s2x - sw / 2)}" y="{fmt(top)}" width="{fmt(sw)}" height="{fmt(bottom - top)}" fill="{s2}"/>',
             ] + ([] if amber_stem else [f'<rect x="{fmt(s1x)}" y="{fmt(top)}" width="{fmt(s2x + sw / 2 - s1x)}" height="{fmt(bar)}" fill="{PAPER}"/>'])
    # small glyph: stems heavier, the gap kept open so the two strokes stay two at 16 px
    sg = 80.0; s2g = s2x + 14
    g = [f'<path d="{polyline(bowl)}Z" fill="{PAPER}"/>',
         f'<rect x="{fmt(s1x - sg / 2)}" y="{fmt(top)}" width="{fmt(sg)}" height="{fmt(bottom - top)}" fill="{PAPER}"/>',
         f'<rect x="{fmt(s2g - sg / 2)}" y="{fmt(top)}" width="{fmt(sg)}" height="{fmt(bottom - top)}" fill="{WARM if amber_stem else PAPER}"/>',
         f'<rect x="{fmt(vxr)}" y="{fmt(top)}" width="{fmt(s1x + sg / 2 - vxr)}" height="{fmt(bar + 14)}" fill="{PAPER}"/>']
    m.glyph += [f'<rect width="1024" height="1024" fill="{DEEP1}"/>'] + g
    return m


# =====================================================================================================================
# PAGE. The half-parabola divides the icon: the field above, a sheet of graph paper below that lifts at its edge.
# The tangent crosses the paper and touches the edge once, where the curve is steep enough for the two to part
# visibly. Near: occlusion under the lifting edge, a rim of light on the field side, graph hairlines, chords above
# the curve converging on the tangent, grain. Far: two tones and one amber line.
# =====================================================================================================================
def page_mark():
    m = Mark('page')
    vx, vy, ex = 40.0, 820.0, 980.0
    k = vy / (ex - vx) ** 2
    f = lambda x: vy - k * (x - vx) ** 2
    df = lambda x: -2 * k * (x - vx)
    xs = np.linspace(vx, ex + 40, 48); cur = np.stack([xs, f(xs)], 1)
    curve_d = catmull_rom_path(cur)   # the edge as a few dozen Béziers
    region_d = f'M-80 {fmt(vy)}L{fmt(vx)} {fmt(vy)}' + curve_d.replace('M', 'L', 1) + 'L1104 -120L1104 1104L-80 1104Z'
    sky_d = 'M-80 -120L1104 -120L' + catmull_rom_path(cur[::-1])[1:] + f'L{fmt(vx)} {fmt(vy)}L-80 {fmt(vy)}Z'
    region = np.vstack([[[-80, vy]], [[vx, vy]], cur, [[1104, -120], [1104, 1104], [-80, 1104]]])
    sky = np.vstack([[[-80, -120]], [[1104, -120]], cur[::-1], [[vx, vy]], [[-80, vy]]])
    xt = 520.0
    T = np.array([xt, f(xt)]); d = np.array([1.0, df(xt)]); d /= np.linalg.norm(d)
    nrm = np.array([d[1], -d[0]]); nrm = -nrm if nrm[1] < 0 else nrm
    m.defs += [FIELD('pg-field'), grain('pg-grain', 0.05),
               f'<radialGradient id="pg-glow" cx="{fmt(T[0] - 120)}" cy="{fmt(T[1] - 200)}" r="560" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#4A46C0" stop-opacity="0.5"/><stop offset="1" stop-color="#4A46C0" stop-opacity="0"/></radialGradient>',
               f'<clipPath id="pg-paper"><path d="{region_d}"/></clipPath>',
               f'<clipPath id="pg-sky"><path d="{sky_d}"/></clipPath>',
               '<filter id="pg-blur" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="28"/></filter>',
               f'<linearGradient id="pg-sheet" gradientUnits="userSpaceOnUse" x1="{fmt(T[0])}" y1="{fmt(T[1])}" x2="{fmt(T[0] + nrm[0] * 640)}" y2="{fmt(T[1] + nrm[1] * 640)}"><stop offset="0" stop-color="{PAPER_SHADE}"/><stop offset="0.4" stop-color="{PAPER}"/><stop offset="1" stop-color="#FBF9F3"/></linearGradient>']
    m.bg += ['<rect width="1024" height="1024" fill="url(#pg-field)"/>', '<rect width="1024" height="1024" fill="url(#pg-glow)"/>',
             '<rect width="1024" height="1024" filter="url(#pg-grain)"/>']
    grid = ''.join(f'<path d="M{x} -10V1034"/>' for x in range(64, 1024, 64)) + ''.join(f'<path d="M-10 {y}H1034"/>' for y in range(64, 1024, 64))
    m.mid += [f'<path d="{region_d}" fill="url(#pg-sheet)"/>',
              f'<g clip-path="url(#pg-paper)" stroke="{INDIGO}" stroke-width="1.6" opacity="0.08" fill="none">{grid}</g>',
              f'<g clip-path="url(#pg-paper)"><path d="{curve_d}" stroke="#0F0C33" stroke-width="64" fill="none" opacity="0.28" filter="url(#pg-blur)"/></g>',
              f'<g clip-path="url(#pg-sky)"><path d="{curve_d}" stroke="{RIM}" stroke-width="6" fill="none" opacity="0.6"/></g>']
    for i, x2 in enumerate([920.0, 800.0, 700.0, 620.0]):
        Q = np.array([x2, f(x2)]); u = (Q - T) / np.linalg.norm(Q - T)
        a, b = T - u * 60, Q + u * 200
        m.mid.append(f'<path d="M{fmt(a[0])} {fmt(a[1])}L{fmt(b[0])} {fmt(b[1])}" stroke="{SOFT}" stroke-width="2.6" opacity="{0.12 + 0.07 * i:.2f}" clip-path="url(#pg-sky)"/>')
    t0, t1 = clip_line(T, d, (-20, -20, 1044, 1044))
    A, B = T + d * t0, T + d * t1
    m.fg += [f'<path d="M{fmt(A[0])} {fmt(A[1])}L{fmt(B[0])} {fmt(B[1])}" stroke="{WARM}" stroke-width="16"/>',
             f'<circle cx="{fmt(T[0])}" cy="{fmt(T[1])}" r="15" fill="{WARM_HI}" stroke="{WARM}" stroke-width="5"/>']
    m.glyph += [f'<rect width="1024" height="1024" fill="{DEEP1}"/>', f'<path d="{region_d}" fill="{PAPER}"/>',
                f'<path d="M{fmt(A[0])} {fmt(A[1])}L{fmt(B[0])} {fmt(B[1])}" stroke="{WARM}" stroke-width="70"/>']
    m.flat = None
    return m


def lockup(m, dark, name):
    """Glyph (in its rounded square) + wordmark. Height 240; the square is 1.75× the cap height."""
    d, w, cap, em = wordmark.outline(wght=540, opsz=72, cap=100.0)
    H = 240.0; capH = 104.0; sq = capH * 1.75
    sc = capH / cap
    pad = 40; gap = 0.42 * sq
    W = pad * 2 + sq + gap + w * sc
    fg = '#F3F1EA' if dark else '#1A1846'; bgc = '#121035' if dark else '#FAF9F6'
    y0 = (H - sq) / 2; base = y0 + sq / 2 + capH / 2
    glyph = ''.join(m.glyph)
    body = (f'<rect width="{fmt(W)}" height="{fmt(H)}" fill="{bgc}"/>'
            f'<svg x="{pad}" y="{fmt(y0)}" width="{fmt(sq)}" height="{fmt(sq)}" viewBox="0 0 1024 1024"><clipPath id="lk-sq"><rect width="1024" height="1024" rx="229"/></clipPath><g clip-path="url(#lk-sq)">{glyph}</g></svg>'
            f'<g transform="translate({fmt(pad + sq + gap)} {fmt(base)}) scale({fmt(sc)})" fill="{fg}"><path d="{d}"/></g>')
    out = f'<svg xmlns="http://www.w3.org/2000/svg" width="{fmt(W)}" height="{fmt(H)}" viewBox="0 0 {fmt(W)} {fmt(H)}"><title>Gradstep lockup</title>{body}</svg>\n'
    open(name, 'w').write(out)


if __name__ == '__main__':
    os.makedirs(ROOT, exist_ok=True)
    for mk in (tangent_mark(), pilcrow_mark(), page_mark()):
        mk.write(ROOT)
        lockup(mk, True, os.path.join(ROOT, mk.name, 'lockup-dark.svg'))
        lockup(mk, False, os.path.join(ROOT, mk.name, 'lockup-light.svg'))
    print('finalists written')
