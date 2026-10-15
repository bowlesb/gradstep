"""Geometry for the Gradstep mark exploration: exact curves, tangents, and variable-width strokes exported as
smooth SVG outlines (Catmull-Rom through dense samples, converted to cubic Béziers). Nothing here is hand-placed:
every point comes from a curve, a derivative, or a stated proportion."""
from __future__ import annotations
import math
import numpy as np

S = 1024.0  # canvas


def fmt(v: float) -> str:
    s = f"{v:.2f}".rstrip('0').rstrip('.')
    return s if s != '-0' else '0'


def catmull_rom_path(pts: np.ndarray, closed: bool = False, alpha: float = 0.5) -> str:
    """Centripetal Catmull-Rom spline through pts, as cubic Bézier SVG path data."""
    pts = np.asarray(pts, float)
    n = len(pts)
    if n < 2:
        return ''
    if closed:
        P = np.vstack([pts[-1:], pts, pts[:2]])
    else:
        P = np.vstack([2 * pts[0] - pts[1], pts, 2 * pts[-1] - pts[-2]])
    d = [f"M{fmt(pts[0][0])} {fmt(pts[0][1])}"]
    segs = n if closed else n - 1
    for i in range(segs):
        p0, p1, p2, p3 = P[i], P[i + 1], P[i + 2], P[i + 3]
        def tj(ti, a, b):
            return ti + max(np.linalg.norm(b - a), 1e-6) ** alpha
        t0 = 0.0; t1 = tj(t0, p0, p1); t2 = tj(t1, p1, p2); t3 = tj(t2, p2, p3)
        # tangents at p1, p2 (non-uniform Catmull-Rom), scaled to the segment parameter span
        m1 = (t2 - t1) * ((p1 - p0) / (t1 - t0) - (p2 - p0) / (t2 - t0) + (p2 - p1) / (t2 - t1))
        m2 = (t2 - t1) * ((p2 - p1) / (t2 - t1) - (p3 - p1) / (t3 - t1) + (p3 - p2) / (t3 - t2))
        c1 = p1 + m1 / 3.0; c2 = p2 - m2 / 3.0
        d.append(f"C{fmt(c1[0])} {fmt(c1[1])} {fmt(c2[0])} {fmt(c2[1])} {fmt(p2[0])} {fmt(p2[1])}")
    if closed:
        d.append('Z')
    return ''.join(d)


def polyline(pts) -> str:
    pts = np.asarray(pts, float)
    return 'M' + 'L'.join(f"{fmt(x)} {fmt(y)}" for x, y in pts)


def normals(pts: np.ndarray) -> np.ndarray:
    d = np.gradient(pts, axis=0)
    d /= np.maximum(np.linalg.norm(d, axis=1, keepdims=True), 1e-9)
    return np.stack([-d[:, 1], d[:, 0]], axis=1)


def stroke_outline(center: np.ndarray, widths: np.ndarray, cap: str = 'round', cap_steps: int = 10) -> np.ndarray:
    """Closed outline of a variable-width stroke along `center` (N×2) with full widths `widths` (N): the left edge
    forward, the end cap, the right edge back, the start cap."""
    nrm = normals(center)
    h = widths / 2.0
    left = center + nrm * h[:, None]
    right = center - nrm * h[:, None]
    def tan(i):
        return np.array([nrm[i][1], -nrm[i][0]])
    def arc(p, n, t, r, flip):
        if cap == 'butt' or r < 0.5:
            return np.empty((0, 2))
        a = np.linspace(0, math.pi, cap_steps + 2)[1:-1]
        sgn = -1 if flip else 1
        return np.array([p + sgn * (n * math.cos(x) + t * math.sin(x)) * r for x in a])
    end_cap = arc(center[-1], nrm[-1], tan(-1), h[-1], False)
    start_cap = arc(center[0], nrm[0], tan(0), h[0], True)
    return np.vstack([left, end_cap, right[::-1], start_cap])


def stroke_path(center, widths, cap='round', simplify: int = 1) -> str:
    out = stroke_outline(np.asarray(center, float), np.asarray(widths, float), cap)
    if simplify > 1:
        out = out[::simplify]
    return catmull_rom_path(out, closed=True)


def nib_widths(center: np.ndarray, wmin: float, wmax: float, angle_deg: float) -> np.ndarray:
    """Calligraphic contrast: width follows the stroke direction relative to a broad nib held at angle_deg."""
    d = np.gradient(center, axis=0)
    theta = np.arctan2(d[:, 1], d[:, 0])
    a = math.radians(angle_deg)
    # a smooth |sin| (no corner where the stroke turns through the nib's angle), lightly smoothed along the stroke
    k = np.sqrt(np.sin(theta - a) ** 2 + 0.006)
    k = np.convolve(np.pad(k, 20, mode='edge'), np.ones(41) / 41, mode='valid')
    return wmin + (wmax - wmin) * (k - k.min()) / max(k.max() - k.min(), 1e-9) if len(k) > 1 else wmin + (wmax - wmin) * k


def taper(n: int, start: float = 0.0, end: float = 0.0, power: float = 1.6) -> np.ndarray:
    """Multiplier 0..1 easing the ends of a stroke (fraction of the length tapered at each end)."""
    t = np.linspace(0, 1, n)
    m = np.ones(n)
    ease = lambda u: np.sin(np.clip(u, 0, 1) * math.pi / 2) ** (1 / power)   # smooth into the full width
    if start > 0:
        m = np.minimum(m, ease(t / start))
    if end > 0:
        m = np.minimum(m, ease((1 - t) / end))
    return m


# ---- curves -----------------------------------------------------------------------------------------------------
def parabola(x0: float, x1: float, n: int = 200, a: float = 1.0):
    """y = a x² sampled on [x0, x1] in math coordinates (y up)."""
    x = np.linspace(x0, x1, n)
    return np.stack([x, a * x * x], axis=1)


def tangent(a: float, xt: float):
    """Tangent of y = a x² at xt: (point, unit direction, slope)."""
    p = np.array([xt, a * xt * xt]); m = 2 * a * xt
    d = np.array([1.0, m]); d /= np.linalg.norm(d)
    return p, d, m


class Frame:
    """Maps math coordinates (y up) into the 1024 canvas: scale about a center, y flipped."""
    def __init__(self, cx: float, cy: float, scale: float, ox: float = 0.0, oy: float = 0.0):
        self.cx, self.cy, self.s, self.ox, self.oy = cx, cy, scale, ox, oy

    def __call__(self, pts):
        pts = np.asarray(pts, float)
        x = self.cx + (pts[..., 0] - self.ox) * self.s
        y = self.cy - (pts[..., 1] - self.oy) * self.s
        return np.stack([x, y], axis=-1)


def bbox(*arrays):
    allp = np.vstack([np.asarray(a).reshape(-1, 2) for a in arrays])
    return allp.min(0), allp.max(0)


def fit_frame(math_pts_list, box=(212, 212, 812, 812), optical=(0, 0)) -> Frame:
    """A frame that fits the given math-coordinate geometry into box (x0, y0, x1, y1), centered, with an optical
    offset in canvas px (e.g. a slight upward shift for a bottom-heavy form)."""
    lo, hi = bbox(*math_pts_list)
    w, h = hi - lo
    bw, bh = box[2] - box[0], box[3] - box[1]
    s = min(bw / max(w, 1e-9), bh / max(h, 1e-9))
    cxm, cym = (lo + hi) / 2
    return Frame((box[0] + box[2]) / 2 + optical[0], (box[1] + box[3]) / 2 + optical[1], s, cxm, cym)


# ---- svg -------------------------------------------------------------------------------------------------------
def svg(body: str, defs: str = '', size: int = 1024, title: str = '') -> str:
    t = f"<title>{title}</title>" if title else ''
    d = f"<defs>{defs}</defs>" if defs else ''
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">{t}{d}{body}</svg>\n'


def arc_profile(center: np.ndarray, wmin: float, wmax: float, peak: float = 0.62, start: float = 0.18, end: float = 0.30) -> np.ndarray:
    """A designed width along the stroke's arc length: a hairline at both ends, easing (sine) to the full width at
    `peak` (fraction of the length), with the ends' easing spans `start` and `end`. Smooth everywhere."""
    seg = np.linalg.norm(np.diff(center, axis=0), axis=1)
    s = np.concatenate([[0], np.cumsum(seg)]); s /= s[-1]
    up = np.sin(np.clip(s / peak, 0, 1) * math.pi / 2) ** 1.35
    down = np.sin(np.clip((1 - s) / (1 - peak), 0, 1) * math.pi / 2) ** 0.9
    body = np.where(s <= peak, up, down)
    ends = np.minimum(np.sin(np.clip(s / start, 0, 1) * math.pi / 2), np.sin(np.clip((1 - s) / end, 0, 1) * math.pi / 2))
    return wmin * ends + (wmax - wmin) * body * ends


def stroke_path_clean(center: np.ndarray, widths: np.ndarray, nodes: int = 60) -> str:
    """A butt-ended stroke as two smooth edge curves through `nodes` points each, joined by the straight cuts along
    the normal: a few dozen cubic Béziers instead of hundreds of segments."""
    nrm = normals(center); h = widths / 2.0
    left = center + nrm * h[:, None]; right = (center - nrm * h[:, None])[::-1]
    idx = np.unique(np.round(np.linspace(0, len(center) - 1, nodes)).astype(int))
    L, R = left[idx], right[idx]
    dl = catmull_rom_path(L); dr = catmull_rom_path(R)
    return dl + 'L' + dr[1:] + 'Z'
