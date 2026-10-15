"""Twenty concept sketches, each computed (not hand-drawn), rendered on one shared field so they compare fairly.
Output: renders/concepts/<id>.svg. See ../concepts.md for what each means and why it was kept or dropped."""
import math, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from geom import *

OUT = os.path.join(os.path.dirname(__file__), '..', 'renders', 'concepts')
os.makedirs(OUT, exist_ok=True)
INK = '#F3F1EA'; SOFT = '#A9B0FF'; WARM = '#F0B44C'
FIELD = ('<linearGradient id="f" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#26236F"/>'
         '<stop offset="1" stop-color="#121035"/></linearGradient>')


def icon(body, title):
    return svg(f'<rect width="1024" height="1024" fill="url(#f)"/>{body}', FIELD, title=title)


def path(d, fill=INK, extra=''):
    return f'<path d="{d}" fill="{fill}" {extra}/>'


def line_stroke(p0, p1, w, fill=INK, cap='round', n=40, taper_end=0.0):
    c = np.linspace(p0, p1, n)
    wid = np.full(n, w) * (taper(n, 0, taper_end) if taper_end else 1)
    return path(stroke_path(c, wid, cap), fill)


def curve_stroke(pts, w, fill=INK, nib=None, cap='round', taper_ends=(0, 0)):
    wid = np.full(len(pts), w) if nib is None else nib_widths(pts, w * nib[0], w * nib[1], nib[2])
    if any(taper_ends):
        wid = wid * taper(len(pts), *taper_ends)
    return path(stroke_path(pts, wid, cap), fill)


def dot(p, r, fill=INK):
    return f'<circle cx="{fmt(p[0])}" cy="{fmt(p[1])}" r="{fmt(r)}" fill="{fill}"/>'


concepts = {}

# --- A: the owner's theme, a half-parabola with a line ---------------------------------------------------------------
def a1():  # tangent on the flank
    a, xt = 1.0, 0.62
    cur = parabola(0, 1.12, 240, a); p, d, m = tangent(a, xt)
    l0, l1 = p - d * 0.62, p + d * 0.58
    F = fit_frame([cur, [l0, l1]], optical=(0, 10))
    return curve_stroke(F(cur), 62, nib=(0.55, 1.0, 35), taper_ends=(0.0, 0.0)) + line_stroke(F(l0), F(l1), 26)
concepts['A1-tangent'] = a1

def a2():  # tangent at the vertex: the minimum, slope zero
    cur = parabola(0, 1.05, 240)
    l0, l1 = np.array([-0.62, 0]), np.array([0.62, 0])
    F = fit_frame([cur, [l0, l1]], optical=(0, -30))
    return curve_stroke(F(cur), 60, nib=(0.55, 1, 30)) + line_stroke(F(l0), F(l1), 24)
concepts['A2-vertex'] = a2

def a3():  # secants converging to the tangent (the limit)
    a, xt = 1.0, 0.45
    cur = parabola(0, 1.12, 240); p, d, m = tangent(a, xt)
    body = ()
    pts = [cur]
    for i, h in enumerate([0.62, 0.42, 0.27, 0.15]):
        q = np.array([xt + h, (xt + h) ** 2]); u = (q - p) / np.linalg.norm(q - p)
        s0, s1 = p - u * 0.45, q + u * 0.18
        pts.append([s0, s1]); body += ('S', s0, s1, 0.22 + 0.12 * i)
    l0, l1 = p - d * 0.55, p + d * 0.75
    pts.append([l0, l1])
    F = fit_frame(pts, optical=(0, 8))
    out = curve_stroke(F(cur), 58, nib=(0.55, 1, 35))
    for k in range(0, len(body), 4):
        _, s0, s1, op = body[k:k + 4]
        out += line_stroke(F(s0), F(s1), 7, fill=SOFT).replace('/>', f' opacity="{op}"/>')
    return out + line_stroke(F(l0), F(l1), 22)
concepts['A3-secants'] = a3

def a4():  # a gradient step: along the tangent from x0, landing on the curve at x1
    a, x0, eta = 1.0, 1.0, 0.3
    cur = parabola(0, 1.12, 240); p, d, m = tangent(a, x0)
    x1 = x0 - eta * m; q_line = p + np.array([x1 - x0, m * (x1 - x0)]); q = np.array([x1, a * x1 * x1])
    F = fit_frame([cur, [q_line, p]], optical=(0, 0))
    return (curve_stroke(F(cur), 56, nib=(0.55, 1, 35)) + line_stroke(F(p), F(q_line), 22)
            + dot(F(q), 30, WARM) + dot(F(p), 16, INK))
concepts['A4-step'] = a4

def a5():  # a G from a parabola opening right and its axis
    y = np.linspace(-1, 1.0, 260); cur = np.stack([0.9 * y * y, y], 1)
    cur = cur[cur[:, 1] > -0.98]
    # the axis of symmetry from the focus out through the opening
    f = 1 / (4 * 0.9)
    l0, l1 = np.array([f + 0.15, -0.05]), np.array([0.92, -0.05])
    F = fit_frame([cur, [l0, l1]])
    pts = F(cur)
    return curve_stroke(pts[::-1], 66, nib=(0.5, 1, 40)) + line_stroke(F(l0), F(l1), 40, cap='butt')
concepts['A5-G'] = a5

def a6():  # a ruler laid beside the curve: parallel to the tangent, not touching
    a, xt, gap = 1.0, 0.6, 0.16
    cur = parabola(0, 1.12, 240); p, d, m = tangent(a, xt)
    n = np.array([d[1], -d[0]])
    l0, l1 = p + n * gap - d * 0.6, p + n * gap + d * 0.6
    F = fit_frame([cur, [l0, l1]], optical=(0, 10))
    return curve_stroke(F(cur), 60, nib=(0.55, 1, 35)) + line_stroke(F(l0), F(l1), 26)
concepts['A6-beside'] = a6

def a7():  # f and f′: x² beside its derivative, a straight line
    cur = parabola(0, 1, 240); l0, l1 = np.array([1.32, 0]), np.array([1.82, 1])
    F = fit_frame([cur, [l0, l1]], box=(180, 230, 844, 794))
    return curve_stroke(F(cur), 58, nib=(0.55, 1, 35)) + line_stroke(F(l0), F(l1), 58)
concepts['A7-derivative-pair'] = a7

def a8():  # the bowl and the ball: osculating circle at the minimum
    cur = parabola(-1, 1, 300); r = 0.5
    F = fit_frame([cur], optical=(0, -20))
    c = F(np.array([[0, r]]))[0]
    return curve_stroke(F(cur), 52) + dot(c, r * F.s - 34, WARM)
concepts['A8-bowl'] = a8

# --- B: other directions ---------------------------------------------------------------------------------------------
def b1():  # nabla, refined: a true optical triangle, heavier top bar, a descent inside
    t = [np.array([-1, 0.82]), np.array([1, 0.82]), np.array([0, -0.9])]
    F = fit_frame([t], optical=(0, -6))
    P = F(np.array(t))
    tri = f'<path d="M{fmt(P[0][0])} {fmt(P[0][1])}L{fmt(P[1][0])} {fmt(P[1][1])}L{fmt(P[2][0])} {fmt(P[2][1])}Z" fill="none" stroke="{INK}" stroke-width="58" stroke-linejoin="miter" stroke-miterlimit="10"/>'
    path_pts = F(np.array([[-0.35, 0.45], [0.25, 0.22], [-0.08, -0.05], [0.04, -0.3]]))
    return tri + f'<path d="{polyline(path_pts)}" fill="none" stroke="{SOFT}" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/>' + dot(path_pts[-1], 20, WARM)
concepts['B1-nabla'] = b1

def b2():  # contours of a quadratic bowl and one step across them
    out = ''
    F = Frame(512, 512, 340)
    for k, r in enumerate([1.0, 0.68, 0.38]):
        th = np.linspace(0, 2 * math.pi, 200)
        e = np.stack([r * np.cos(th) * 1.0, r * 0.62 * np.sin(th)], 1)
        R = np.array([[math.cos(0.5), -math.sin(0.5)], [math.sin(0.5), math.cos(0.5)]])
        out += curve_stroke(F(e @ R.T), [30, 22, 16][k], fill=[INK, INK, SOFT][k])
    s0, s1 = F(np.array([[-0.7, 0.55]]))[0], F(np.array([[-0.05, 0.03]]))[0]
    return out + line_stroke(s0, s1, 20, fill=INK) + dot(s1, 24, WARM)
concepts['B2-contours'] = b2

def b3():  # a staircase converging to the minimum
    xs = [0]; x = 1.0
    pts = []
    y = 1.0
    for i in range(7):
        x2 = x * 0.55; y2 = x2 * x2
        pts += [(x, y), (x2, y), (x2, y2)]
        x, y = x2, y2
    pts = np.array(pts)
    F = fit_frame([pts], optical=(0, 0))
    P = F(pts)
    return f'<path d="{polyline(P)}" fill="none" stroke="{INK}" stroke-width="40" stroke-linejoin="miter" stroke-linecap="square"/>' + dot(P[-1], 26, WARM)
concepts['B3-staircase'] = b3

def b4():  # a page folded along a parabola; the crease is a tangent
    page = np.array([[-0.8, 1], [0.35, 1], [0.8, 0.55], [0.8, -1], [-0.8, -1]])
    F = fit_frame([page])
    P = F(page)
    body = f'<path d="M{fmt(P[0][0])} {fmt(P[0][1])}L{fmt(P[1][0])} {fmt(P[1][1])}L{fmt(P[2][0])} {fmt(P[2][1])}L{fmt(P[3][0])} {fmt(P[3][1])}L{fmt(P[4][0])} {fmt(P[4][1])}Z" fill="{INK}"/>'
    t = np.linspace(0, 1, 60); fold = np.stack([0.35 + 0.45 * t ** 2 * 0 + 0.45 * t, 1 - 0.45 * t ** 0.6], 1)
    body += curve_stroke(F(fold), 10, fill='#121035')
    lines = ''.join(line_stroke(F(np.array([-0.55, y])), F(np.array([0.5 if y < 0.4 else 0.15, y])), 16, fill='#2B2876') for y in [0.55, 0.25, -0.05, -0.35, -0.65])
    return body + lines
concepts['B4-page'] = b4

def b5():  # a loupe: under the lens a line of text becomes a curve
    F = Frame(512, 512, 300)
    out = ''
    for y in [0.6, 0.2, -0.2, -0.6]:
        out += line_stroke(F(np.array([-1.1, y])), F(np.array([1.1, y])), 18, fill='#3B3896')
    c = F(np.array([[0.1, 0]]))[0]
    out += f'<circle cx="{fmt(c[0])}" cy="{fmt(c[1])}" r="{fmt(0.62 * 300)}" fill="#121035" stroke="{INK}" stroke-width="34"/>'
    cur = parabola(-0.45, 0.45, 100, 1.6) * np.array([1, 1]) + np.array([0.1, -0.25])
    out += curve_stroke(F(cur), 26, fill=WARM)
    out += line_stroke(F(np.array([0.58, -0.48])), F(np.array([1.05, -0.95])), 46)
    return out
concepts['B5-loupe'] = b5

def b6():  # a pilcrow whose bowl is a half parabola
    y = np.linspace(-0.05, 1, 200); x = -0.35 - 0.6 * (1 - ((y - 0.5) / 0.55) ** 2).clip(0) ** 0.5
    bowl = np.stack([x, y], 1)
    F = fit_frame([bowl, [[0.4, 1], [0.4, -1]]], optical=(0, 0))
    out = curve_stroke(F(bowl), 70, nib=(0.4, 1, 0))
    out += line_stroke(F(np.array([-0.35, 1])), F(np.array([-0.35, -1])), 34, cap='butt')
    out += line_stroke(F(np.array([0.12, 1])), F(np.array([0.12, -1])), 34, cap='butt')
    out += line_stroke(F(np.array([-0.4, 1])), F(np.array([0.32, 1])), 34, cap='butt')
    return out
concepts['B6-pilcrow'] = b6

def b7():  # lowercase g: a bowl and a descender hook drawn as a parabola
    th = np.linspace(0, 2 * math.pi, 220); bowl = np.stack([0.48 * np.cos(th), 0.3 + 0.48 * np.sin(th)], 1)
    x = np.linspace(0.48, -0.42, 160); hook = np.stack([x, -0.75 + 1.6 * (x + 0.0) ** 2 * 0.0 + (-0.7 + 0.0 * x)], 1)
    t = np.linspace(0, 1, 160); hook = np.stack([0.48 - 0.0 * t, 0.3 - 1.05 * t ** 0.8], 1)
    tail = parabola(-0.48, 0.48, 120, 1.2) * np.array([1, -1]) + np.array([0, -0.48])
    tail = tail[tail[:, 0] <= 0.48]
    F = fit_frame([bowl, hook, tail])
    return curve_stroke(F(bowl), 44, nib=(0.45, 1, 30)) + curve_stroke(F(hook), 44) + curve_stroke(F(tail)[::-1], 44, nib=(0.45, 1, 30))
concepts['B7-g'] = b7

def b8():  # ∂, drawn: a bowl and a stem that sweeps up and curls back
    th = np.linspace(0.0, 2 * math.pi, 240); bowl = np.stack([0.42 * np.cos(th), -0.45 + 0.42 * np.sin(th)], 1)
    t = np.linspace(0, 1, 220)
    stem = np.stack([0.42 * np.cos(0) - 0.0 * t + 0.08 * np.sin(t * math.pi) - 0.62 * t ** 2.2 + 0.0,
                     -0.45 + 1.55 * t ** 0.9], 1)
    curl = np.stack([stem[-1, 0] - 0.22 * np.sin(np.linspace(0, math.pi * 0.85, 60)), stem[-1, 1] + 0.12 * (1 - np.cos(np.linspace(0, math.pi * 0.85, 60)))], 1)
    F = fit_frame([bowl, stem, curl], optical=(0, 0))
    return (curve_stroke(F(bowl), 54, nib=(0.35, 1, 35)) + curve_stroke(F(np.vstack([stem, curl[1:]])), 54, nib=(0.35, 1, 35), taper_ends=(0, 0.12)))
concepts['B8-partial'] = b8

def b9():  # solid forms: the region above a parabola, and a tangent bar that kisses it
    a, xt = 1.0, 0.5
    x = np.linspace(-1, 1, 200)
    region = np.vstack([np.stack([x, x * x], 1), [[1, 1.25], [-1, 1.25]]])
    p, d, m = tangent(a, xt)
    n = np.array([d[1], -d[0]])
    w = 0.13
    bar = np.array([p - d * 0.9, p + d * 0.75, p + d * 0.75 + n * w, p - d * 0.9 + n * w])
    F = fit_frame([region, bar], optical=(0, 0))
    R = F(region); B = F(bar)
    return (f'<path d="{polyline(R)}Z" fill="{INK}"/>' + f'<path d="{polyline(B)}Z" fill="{WARM}"/>')
concepts['B9-solid-kiss'] = b9

def b10():  # a page curling from the spine: a half parabola and its axis
    cur = parabola(0, 1, 240) [:, ::-1] * np.array([1, 1])  # x = y², opening right... as a page curl
    cur = np.stack([parabola(0, 1, 240)[:, 1] * 0.9, parabola(0, 1, 240)[:, 0] * 1.6], 1)
    spine = [np.array([0, 0]), np.array([0, 1.6])]
    F = fit_frame([cur, spine])
    return curve_stroke(F(cur), 56, nib=(0.5, 1, 20)) + line_stroke(F(spine[0]), F(spine[1]), 34, cap='butt')
concepts['B10-spine'] = b10

def b11():  # a direction field of y' = 2x; one solution drawn
    F = Frame(512, 540, 300)
    out = ''
    for gx in np.linspace(-1.2, 1.2, 9):
        for gy in np.linspace(-0.4, 1.3, 7):
            m = 2 * gx; d = np.array([1, m]) / math.hypot(1, m)
            p0, p1 = np.array([gx, gy]) - d * 0.09, np.array([gx, gy]) + d * 0.09
            out += line_stroke(F(p0), F(p1), 9, fill=SOFT).replace('/>', ' opacity="0.55"/>')
    cur = parabola(-1.15, 1.15, 240) + np.array([0, -0.2])
    return out + curve_stroke(F(cur), 34)
concepts['B11-field'] = b11

def b12():  # a parabolic reflector: parallel rays meet at the focus
    a = 0.8; f = 1 / (4 * a)
    cur = parabola(0, 1.1, 200, a)
    F = fit_frame([cur, [[-0.05, 0], [1.2, 1.1]]])
    out = curve_stroke(F(cur), 40)
    for x in [0.35, 0.65, 0.95]:
        y = a * x * x
        out += line_stroke(F(np.array([x, 1.15])), F(np.array([x, y])), 10, fill=SOFT)
        out += line_stroke(F(np.array([x, y])), F(np.array([0, f])), 10, fill=SOFT)
    return out + dot(F(np.array([[0, f]]))[0], 26, WARM)
concepts['B12-focus'] = b12

for k, fn in concepts.items():
    open(os.path.join(OUT, f'{k}.svg'), 'w').write(icon(fn(), k))
print(len(concepts), 'concepts')
