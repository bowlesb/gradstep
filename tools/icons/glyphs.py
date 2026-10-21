"""Gradstep tab/header glyphs ("Nabla line"): rounded strokes like the logo, one amber point each.
Design space: 0..100 box, y down. Each glyph = list of (layer, outline Path) where layer is 'line' or 'point'.
"""
import math
import pathops

W = 8.0   # stroke width in design units


def _stroke(build, width=W):
    p = pathops.Path()
    build(p)
    p.stroke(width, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
    p.convertConicsToQuads()
    return p


def poly(points, closed=False, width=W):
    def b(p):
        p.moveTo(*points[0])
        for pt in points[1:]:
            p.lineTo(*pt)
        if closed:
            p.close()
    return _stroke(b, width)


def arc_points(cx, cy, r, a0, a1, n=48):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def arc(cx, cy, r, a0, a1, width=W):
    return poly(arc_points(cx, cy, r, a0, a1), width=width)


def rrect_points(x0, y0, x1, y1, r, n=12):
    pts = []
    for (cx, cy, a) in [(x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)]:
        pts += arc_points(cx, cy, r, a, a + 90, n)
    return pts


def rrect(x0, y0, x1, y1, r, width=W):
    return poly(rrect_points(x0, y0, x1, y1, r), closed=True, width=width)


def disc(cx, cy, r):
    p = pathops.Path()
    k = 0.5522847498 * r
    p.moveTo(cx + r, cy)
    p.cubicTo(cx + r, cy + k, cx + k, cy + r, cx, cy + r)
    p.cubicTo(cx - k, cy + r, cx - r, cy + k, cx - r, cy)
    p.cubicTo(cx - r, cy - k, cx - k, cy - r, cx, cy - r)
    p.cubicTo(cx + k, cy - r, cx + r, cy - k, cx + r, cy)
    p.close()
    return p


def union(paths):
    out = pathops.Path()
    for p in paths:
        out = pathops.op(out, p, pathops.PathOp.UNION)
    return out


def minus(a, b):
    return pathops.op(a, b, pathops.PathOp.DIFFERENCE)


def fill_poly(pts):
    p = pathops.Path()
    p.moveTo(*pts[0])
    for pt in pts[1:]:
        p.lineTo(*pt)
    p.close()
    return p


def fill_rect(x0, y0, x1, y1):
    return fill_poly([(x0, y0), (x1, y0), (x1, y1), (x0, y1)])


def stroke_outline(filled, width=W):
    """Strokes the boundary of a filled (polygonal) shape with round joins."""
    p = pathops.Path()
    for contour in filled.contours:
        pts = list(contour.points)
        p.moveTo(*pts[0])
        for pt in pts[1:]:
            p.lineTo(*pt)
        p.close()
    p.stroke(width, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
    p.convertConicsToQuads()
    return p


def inflate(filled, d):
    return union([stroke_outline(filled, 2 * d), filled])


def rotate(points, cx, cy, deg):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    return [(cx + (x - cx) * c - (y - cy) * s, cy + (x - cx) * s + (y - cy) * c) for x, y in points]


# ---- glyphs -----------------------------------------------------------------------------

def feed():
    """New papers arriving: the feed sign (a point and two arcs); the point is amber."""
    return [('line', union([arc(16, 84, 37, -90, 0), arc(16, 84, 68, -90, 0)])), ('point', disc(16, 84, 10))]


def feed_cards():
    """A stack of papers with a 'new' point."""
    front = rrect(10, 26, 72, 92, 9)
    back = minus(poly([(26, 10), (80, 10)] + arc_points(80, 18, 8, -90, 0)[1:] + [(88, 76)]), fill_rect(4, 18, 80, 98))
    lines = union([poly([(24, 48), (58, 48)]), poly([(24, 64), (58, 64)]), poly([(24, 80), (44, 80)])])
    return [('line', union([back, front, lines])), ('point', disc(88, 92, 0.01))]


def library():
    """Three spines, the last leaning; the point at rest beside it (as in the logo's valley)."""
    b1 = rrect(6, 26, 26, 92, 5)
    b2 = rrect(32, 12, 52, 92, 5)
    lean = poly(rotate(rrect_points(58, 24, 78, 92, 5), 78, 92, -20), closed=True)
    return [('line', union([b1, b2, lean])), ('point', disc(91, 85, 7.5))]


def paper():
    """A page with a folded corner and text; the point marks where you are reading."""
    page = poly([(62, 8), (24, 8)] + arc_points(24, 16, 8, -90, -180)[1:] + [(16, 84)]
                + arc_points(24, 84, 8, 180, 90)[1:] + [(76, 92)] + arc_points(76, 84, 8, 90, 0)[1:]
                + [(84, 30), (62, 8), (62, 30), (84, 30)])
    lines = union([poly([(46, 50), (68, 50)]), poly([(32, 66), (68, 66)]), poly([(32, 80), (54, 80)])])
    return [('line', union([page, lines])), ('point', disc(32, 50, 7))]


def chat():
    """One bubble; inside, an answer arriving: two dots and the amber point."""
    outline = union([fill_poly(rrect_points(6, 10, 94, 74, 26)), fill_poly([(22, 62), (14, 92), (48, 72)])])
    ring = stroke_outline(outline)
    dots = union([disc(31, 42, 6.5), disc(50, 42, 6.5)])
    return [('line', union([ring, dots])), ('point', disc(69, 42, 6.5))]


def chat_two():
    """A question and an answer: two bubbles; the answer's point is amber."""
    front = union([fill_poly(rrect_points(4, 32, 72, 82, 20)), fill_poly([(16, 72), (10, 96), (40, 80)])])
    back = minus(poly(rrect_points(30, 6, 96, 54, 18), closed=True), inflate(front, 9))
    ring = stroke_outline(front)
    return [('line', union([back, ring, disc(24, 57, 5.5), disc(38, 57, 5.5)])), ('point', disc(52, 57, 5.5))]


def settings():
    """Two sliders; one knob is the amber point."""
    t1 = union([poly([(8, 30), (50, 30)]), poly([(78, 30), (92, 30)])])
    k1 = poly(arc_points(64, 30, 11, 0, 360, 64), closed=True)
    t2 = union([poly([(8, 70), (20, 70)]), poly([(52, 70), (92, 70)])])
    return [('line', union([t1, k1, t2])), ('point', disc(36, 70, 12.5))]


def gear():
    """A rounded gear with the amber point at its centre."""
    teeth, ro, ri = 8, 45, 33
    pts = []
    for i in range(teeth):
        a = 360 / teeth * i
        for (da, r) in [(-14, ri), (-8, ro), (8, ro), (14, ri)]:
            pts.append((50 + r * math.cos(math.radians(a + da)), 50 + r * math.sin(math.radians(a + da))))
    return [('line', poly(pts, closed=True)), ('point', disc(50, 50, 11))]


def nabla():
    """The logo mark, simplified for small sizes: the valley and the point at its foot."""
    tri = poly([(8, 12), (92, 12), (50, 86)], closed=True, width=11)
    return [('line', tri), ('point', disc(50, 52, 9))]


def chat_new():
    """New chat: the bubble with a plus."""
    outline = union([fill_poly(rrect_points(6, 10, 94, 74, 26)), fill_poly([(22, 62), (14, 92), (48, 72)])])
    ring = stroke_outline(outline)
    plus = union([poly([(50, 28), (50, 56)]), poly([(36, 42), (64, 42)])])
    return [('line', union([ring, plus])), ('point', disc(0, 0, 0.001))]


def chat_history():
    """Chat history: the bubble with a clock hand."""
    outline = union([fill_poly(rrect_points(6, 10, 94, 74, 26)), fill_poly([(22, 62), (14, 92), (48, 72)])])
    ring = stroke_outline(outline)
    hands = poly([(50, 26), (50, 44), (64, 50)])
    return [('line', union([ring, hands])), ('point', disc(0, 0, 0.001))]


def chats():
    """All chats: a list (owner feedback, build 14: the clock-arrow "looks like a refresh icon, it probably needs to
    have lines in it"). Round bullets and lines; the newest conversation's bullet is the amber point."""
    lines = union([poly([(32, 20), (92, 20)]), poly([(32, 50), (92, 50)]), poly([(32, 80), (80, 80)])])
    bullets = union([disc(12, 50, 7), disc(12, 80, 7)])
    return [('line', union([lines, bullets])), ('point', disc(12, 20, 7))]


def contents():
    """Table of contents: three lines, indented like headings; the point marks the current section."""
    lines = union([poly([(34, 22), (92, 22)]), poly([(48, 50), (92, 50)]), poly([(34, 78), (92, 78)])])
    return [('line', lines), ('point', union([disc(14, 22, 7)]))]


def library_valley():
    """Two spines and a leaning book; the point rests in the valley between them."""
    b1 = rrect(4, 24, 24, 92, 5)
    b2 = rrect(30, 10, 50, 92, 5)
    lean = poly(rotate(rrect_points(58, 22, 78, 92, 5), 58, 92, 20), closed=True)
    return [('line', union([b1, b2, lean])), ('point', disc(63, 64, 6.5))]


def library_amber_spine():
    """Three spines, the last leaning; the middle one carries an amber band (the book you're reading)."""
    b1 = rrect(4, 26, 26, 92, 5)
    b2 = rrect(32, 8, 54, 92, 5)
    lean = poly(rotate(rrect_points(60, 22, 82, 92, 5), 60, 92, 18), closed=True)
    return [('line', union([b1, b2, lean])), ('point', fill_rect(32, 28, 54, 40))]


def library_stack():
    """Books lying in a stack; the point rests on top."""
    b1 = rrect(6, 70, 94, 92, 6)
    b2 = rrect(14, 44, 86, 66, 6)
    return [('line', union([b1, b2])), ('point', disc(50, 26, 10))]


def notes():
    """Notes (2026-10-20): a notebook page holding a captured box and a line of writing; the box's corner handle is the
    amber point (the snippet just drawn)."""
    page = rrect(18, 8, 86, 92, 10)
    rings = union([poly([(8, 28), (26, 28)]), poly([(8, 50), (26, 50)]), poly([(8, 72), (26, 72)])])
    box = rrect(38, 26, 70, 52, 5)
    line = poly([(38, 72), (66, 72)])
    return [('line', union([page, rings, box, line])), ('point', disc(70, 52, 8))]


GLYPHS = {
    'notes': notes,
    'library_valley': library_valley, 'library_amber_spine': library_amber_spine, 'library_stack': library_stack,
    'feed': feed, 'feed_cards': feed_cards, 'library': library, 'paper': paper, 'chat': chat, 'chat_two': chat_two,
    'settings': settings, 'gear': gear, 'nabla': nabla, 'chat_new': chat_new, 'chat_history': chat_history,
    'contents': contents, 'chats': chats,
}
