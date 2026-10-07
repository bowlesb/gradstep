"""Renders glyph previews (mock tab bars, light and dark) with skia."""
import sys
import skia
import pathops
from glyphs import GLYPHS

INDIGO, PERI, AMBER, INK, PAPER = 0xFF6366F1, 0xFFA5B4FC, 0xFFF2B544, 0xFF1E1C52, 0xFFF7F6F1


def to_skia(p: pathops.Path) -> skia.Path:
    out = skia.Path()
    for verb, pts in p.segments:
        if verb == 'moveTo':
            out.moveTo(*pts[0])
        elif verb == 'lineTo':
            out.lineTo(*pts[0])
        elif verb == 'curveTo':
            out.cubicTo(*pts[0], *pts[1], *pts[2])
        elif verb == 'qCurveTo':
            # TrueType-style: implied on-curve points between consecutive off-curve points
            offs, end = pts[:-1], pts[-1]
            for i, off in enumerate(offs):
                nxt = end if i == len(offs) - 1 else ((off[0] + offs[i + 1][0]) / 2, (off[1] + offs[i + 1][1]) / 2)
                out.quadTo(*off, *nxt)
        elif verb == 'closePath':
            out.close()
    return out


def draw_glyph(canvas, name, x, y, size, line_color, point_color, tile=None):
    layers = GLYPHS[name]()
    canvas.save()
    canvas.translate(x, y)
    canvas.scale(size / 100, size / 100)
    if tile is not None:
        paint = skia.Paint(AntiAlias=True, Color=tile)
        canvas.drawRRect(skia.RRect.MakeRectXY(skia.Rect(-22, -22, 122, 122), 34, 34), paint)
    for layer, path in layers:
        paint = skia.Paint(AntiAlias=True, Color=line_color if layer == 'line' else point_color)
        canvas.drawPath(to_skia(path), paint)
    canvas.restore()


def main(out, names, scale=3):
    rows = [
        ('light', 0xFFFFFFFF, 0xFF3C3C43, INDIGO, AMBER, None),
        ('dark', 0xFF000000, 0xFFEBEBF5, PERI, AMBER, None),
        ('tile light', 0xFFFFFFFF, 0xFF3C3C43, PAPER, AMBER, INK),
        ('tile dark', 0xFF000000, 0xFFEBEBF5, PAPER, AMBER, 0xFF3B39A0),
    ]
    cell, pad = 90, 20
    width = pad * 2 + cell * len(names) + 220
    height = pad * 2 + len(rows) * 150
    surface = skia.Surface(width * scale, height * scale)
    with surface as canvas:
        canvas.scale(scale, scale)
        canvas.clear(0xFFEEEEEE)
        font = skia.Font(None, 11)
        for r, (label, bg, gray, sel, pt, tile) in enumerate(rows):
            y0 = pad + r * 150
            canvas.drawRect(skia.Rect(0, y0 - 10, width, y0 + 140), skia.Paint(Color=bg))
            canvas.drawString(label, 10, y0 + 5, font, skia.Paint(Color=gray))
            for i, name in enumerate(names):
                x = pad + i * cell + 40
                # selected (top) and unselected (bottom) at tab size 22pt
                draw_glyph(canvas, name, x, y0 + 14, 24, sel, pt, tile)
                draw_glyph(canvas, name, x, y0 + 60, 24, gray, gray)
                draw_glyph(canvas, name, x + 30, y0 + 50, 48, sel if tile is None else gray, pt)
                canvas.drawString(name, x - 4, y0 + 125, font, skia.Paint(Color=gray))
    surface.makeImageSnapshot().save(out, skia.kPNG)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2].split(','))
