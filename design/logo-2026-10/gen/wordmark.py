"""The wordmark: "Gradstep" in Fraunces (SIL OFL 1.1; fonts/OFL-Fraunces.txt), shaped by HarfBuzz at a chosen point on
the variable axes, outlined to SVG paths. Returns path data in a box whose cap height is `cap` units."""
import os
import uharfbuzz as hb
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

FONT = os.path.join(os.path.dirname(__file__), '..', 'fonts', 'Fraunces-Variable.ttf')
_cache = {}


def outline(text='Gradstep', wght=560, opsz=72, soft=0, wonk=0, tracking=-0.012, cap=100.0):
    key = (text, wght, opsz, soft, wonk, tracking, cap)
    if key in _cache: return _cache[key]
    axes = {'wght': wght, 'opsz': opsz, 'SOFT': soft, 'WONK': wonk}
    blob = hb.Blob.from_file_path(FONT); face = hb.Face(blob); font = hb.Font(face)
    font.set_variations(axes)
    buf = hb.Buffer(); buf.add_str(text); buf.guess_segment_properties()
    hb.shape(font, buf, {'kern': True, 'liga': True})
    static = instancer.instantiateVariableFont(TTFont(FONT), axes)
    gs = static.getGlyphSet(); order = static.getGlyphOrder()
    upm = static['head'].unitsPerEm
    capH = getattr(static['OS/2'], 'sCapHeight', 0) or 700
    s = cap / capH
    x = 0.0; paths = []
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        name = order[info.codepoint]
        pen = SVGPathPen(gs)
        tp = TransformPen(pen, (s, 0, 0, -s, (x + pos.x_offset) * s, -pos.y_offset * s))
        gs[name].draw(tp)
        paths.append(pen.getCommands())
        x += pos.x_advance + tracking * upm
    width = (x - tracking * upm) * s
    _cache[key] = (' '.join(paths), width, cap, s * upm)
    return _cache[key]


if __name__ == '__main__':
    d, w, cap, em = outline()
    print(round(w, 1), cap, round(em, 1), d[:80])
