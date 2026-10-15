"""Round 2: the strongest directions from round 1, drawn with care. renders/round2/<id>.svg"""
import math, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from geom import *

OUT = os.path.join(os.path.dirname(__file__), '..', 'renders', 'round2'); os.makedirs(OUT, exist_ok=True)
INK = '#F3F1EA'; SOFT = '#A9B0FF'; WARM = '#F2B248'
DEEP0, DEEP1 = '#2A2774', '#120F38'


def field(defs_extra=''):
    return (f'<linearGradient id="f" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{DEEP0}"/><stop offset="1" stop-color="{DEEP1}"/></linearGradient>'
            + defs_extra)


def write(name, body, defs=''):
    open(os.path.join(OUT, name + '.svg'), 'w').write(svg(f'<rect width="1024" height="1024" fill="url(#f)"/>{body}', field(defs), title=name))


def P(pts): return np.asarray(pts, float)


def line_ends_in_box(p, d, box=(-40, -40, 1064, 1064)):
    """Extend the line through p with direction d to the canvas box."""
    t0, t1 = -1e9, 1e9
    for i, (lo, hi) in enumerate([(box[0], box[2]), (box[1], box[3])]):
        if abs(d[i]) > 1e-9:
            a, b = sorted([(lo - p[i]) / d[i], (hi - p[i]) / d[i]])
            t0, t1 = max(t0, a), min(t1, b)
    return p + d * t0, p + d * t1


def poly_d(pts): return polyline(pts) + 'Z'


# ---- 1. The split field: a half-parabola divides the icon; the tangent touches the boundary once -------------------
def split(name, vertex=(150, 800), reach=(870, 120), xt=0.42, tone='#3B37A0', line=WARM, lw=16, light=False, vertex_tangent=False):
    # curve in canvas coords: x = vx + s*u, y = vy - k*s²u² for u in [0, 1] mapping to reach
    vx, vy = vertex; ex, ey = reach
    u = np.linspace(0, 1, 400)
    xs = vx + (ex - vx) * u; ys = vy - (vy - ey) * u * u
    cur = np.stack([xs, ys], 1)
    # extend the curve past the canvas edge so the region boundary is clean
    u2 = np.linspace(1, 1.25, 60); ext = np.stack([vx + (ex - vx) * u2, vy - (vy - ey) * u2 * u2], 1)
    left = np.array([[vx - 400, vy]])
    region = np.vstack([left, cur, ext, [[1200, -200], [1200, 1300], [-200, 1300], [-200, vy]]])
    body = f'<path d="{poly_d(region)}" fill="{tone}"/>'
    # tangent at parameter xt
    pt = np.array([vx + (ex - vx) * xt, vy - (vy - ey) * xt * xt])
    dydx = -(vy - ey) * 2 * xt / (ex - vx)
    d = np.array([1.0, dydx]); d /= np.linalg.norm(d)
    if vertex_tangent:
        pt = np.array([vx, vy]); d = np.array([1.0, 0.0])
    a, b = line_ends_in_box(pt, d)
    body += f'<path d="M{fmt(a[0])} {fmt(a[1])}L{fmt(b[0])} {fmt(b[1])}" stroke="{line}" stroke-width="{lw}" stroke-linecap="butt"/>'
    body += f'<circle cx="{fmt(pt[0])}" cy="{fmt(pt[1])}" r="{lw * 1.6}" fill="{line}"/>'
    write(name, body)

split('S1-split-tangent')
split('S2-split-vertex', vertex=(150, 760), vertex_tangent=True)
split('S3-split-ink', tone=INK, line='#2A2774', lw=18)

# ---- 2. Calligraphic knee: a broad-nib half-parabola, a long hairline tangent -----------------------------------------
def knee(name, xt=0.38, nib=32, wmin=0.18, wmax=1.0, w=96, lw=18):
    a = 1.0
    cur = parabola(0, 1.0, 400, a)
    p, d, m = tangent(a, xt)
    F = fit_frame([cur], box=(220, 200, 800, 800), optical=(10, 20))
    C = F(cur)
    wid = nib_widths(C, w * wmin, w * wmax, nib) * taper(len(C), 0.06, 0.1)
    body = f'<path d="{stroke_path(C, wid, "round")}" fill="{INK}"/>'
    q = F(np.array([p]))[0]; dd = np.array([d[0], -d[1]])
    A, B = line_ends_in_box(q, dd)
    body += f'<path d="M{fmt(A[0])} {fmt(A[1])}L{fmt(B[0])} {fmt(B[1])}" stroke="{WARM}" stroke-width="{lw}"/>'
    write(name, body)

knee('K1-knee')
knee('K2-knee-flat-nib', nib=0, wmin=0.12)

# ---- 3. ∂: the symbol of differentiation, constructed: an ellipse bowl and a stem that rises and curls back ------
def partial(name, w=84, nib=-35):
    # bowl: slightly tilted ellipse
    th = np.linspace(-0.15, 2 * math.pi - 0.15, 300)
    rx, ry, tilt = 0.40, 0.36, math.radians(-12)
    bowl = np.stack([rx * np.cos(th), ry * np.sin(th)], 1) @ np.array([[math.cos(tilt), -math.sin(tilt)], [math.sin(tilt), math.cos(tilt)]]).T
    bowl += np.array([-0.05, -0.55])
    # stem: from the bowl's right side up, curving left into a hook (a cubic Bézier in math coords)
    p0 = bowl[0]; c1 = p0 + np.array([0.12, 0.55]); c2 = np.array([0.25, 0.95]); p3 = np.array([-0.18, 0.92])
    t = np.linspace(0, 1, 240)[:, None]
    stem = (1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * c1 + 3 * (1 - t) * t * t * c2 + t ** 3 * p3
    whole = np.vstack([bowl[::-1], stem[1:]])
    F = fit_frame([whole], box=(250, 190, 774, 834))
    C = F(whole)
    wid = nib_widths(C, w * 0.28, w, nib) * taper(len(C), 0.0, 0.08)
    write(name, f'<path d="{stroke_path(C, wid, "round")}" fill="{INK}"/>')

partial('D1-partial')

# ---- 4. Pilcrow with a parabolic bowl: the paragraph mark the product cites everything with ---------------------
def pilcrow(name):
    # bowl: region bounded by a sideways parabola x = -c (y-ym)² + x0 (opening left), filled
    ym, h = 0.45, 0.55
    y = np.linspace(ym - h, ym + h, 200)
    x = 0.02 - 0.75 * (1 - ((y - ym) / h) ** 2)
    bowl = np.stack([x, y], 1)
    F = fit_frame([bowl, [[0.6, 1.0], [0.6, -1.0]]], box=(250, 190, 774, 834))
    stems = ''
    for sx in [0.02, 0.38]:
        a, b = F(np.array([[sx, 1.0], [sx, -1.0]]))
        stems += f'<path d="M{fmt(a[0])} {fmt(a[1])}L{fmt(b[0])} {fmt(b[1])}" stroke="{INK}" stroke-width="62"/>'
    top0, top1 = F(np.array([[-0.73, 1.0], [0.6, 1.0]]))
    bar = f'<path d="M{fmt(top0[0])} {fmt(top0[1] + 31)}L{fmt(top1[0])} {fmt(top1[1] + 31)}" stroke="{INK}" stroke-width="62"/>'
    write(name, f'<path d="{poly_d(F(bowl))}" fill="{INK}"/>' + stems)

pilcrow('P1-pilcrow')

# ---- 5. A staircase under a parabola: each step lands on the curve, and they shrink toward the minimum ------------
def stairs(name):
    pts = []; x = 1.0
    for i in range(6):
        x2 = x * 0.52
        pts += [(x, x * x), (x2, x * x), (x2, x2 * x2)]
        x = x2
    pts = np.array(pts)
    cur = parabola(0, 1.0, 200)
    F = fit_frame([cur], box=(220, 220, 804, 804))
    S = F(pts)
    body = f'<path d="{stroke_path(F(cur), np.full(200, 10.0))}" fill="{SOFT}" opacity="0.55"/>'
    body += f'<path d="{polyline(S)}" fill="none" stroke="{INK}" stroke-width="44" stroke-linejoin="miter" stroke-linecap="butt"/>'
    write(name, body)

stairs('T1-stairs')

# ---- 6. The curve and its derivative from one origin: x² and 2x fan out from the same point ------------------------
def pair(name):
    cur = parabola(0, 1.6, 300); lin = np.array([[0, 0], [1.0, 2.0]])
    F = fit_frame([cur, lin], box=(230, 200, 794, 824))
    C = F(cur)
    body = f'<path d="{stroke_path(C, nib_widths(C, 26, 70, 30))}" fill="{INK}"/>'
    a, b = F(lin)
    body += f'<path d="{stroke_path(np.linspace(a, b, 40), np.full(40, 34.0))}" fill="{WARM}"/>'
    write(name, body)

pair('R1-pair-origin')
print('round 2 written')
