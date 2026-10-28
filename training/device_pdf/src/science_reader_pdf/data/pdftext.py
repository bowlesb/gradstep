"""Read the text layer of compiled PDFs: glyphs with fonts, positions and instrumentation classes.

The instrumented PDF tags each glyph with a fingerprint fill colour (see gradstep-instrument.sty).
Nothing else about the layout differs from the plain PDF, so glyph i on page p is the same glyph
in both files; the class comes from the instrumented one and the image from the plain one.
Coordinates are PDF points with a top-left origin (pdfplumber's `top`/`bottom` convention).
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

import pdfplumber

# Fingerprint colours -> class. Values are the rgb triples written by the .sty, rounded to 3 dp.
CLASS_COLOURS: dict[tuple[float, float, float], str] = {
    (0.996, 0.004, 0.008): "inline_math",
    (0.996, 0.004, 0.024): "inline_math",  # second shade: consecutive inline formulas alternate
    (0.008, 0.004, 0.996): "display_math",
    (0.004, 0.600, 0.012): "equation_tag",
    (0.600, 0.004, 0.600): "float",
    (0.600, 0.300, 0.004): "footnote",
    (0.004, 0.500, 0.500): "table",
    (0.500, 0.500, 0.004): "algorithm",
    (0.300, 0.300, 0.600): "bibliography",
    (0.004, 0.300, 0.600): "abstract",
}
CLASSES = ("text", *sorted(set(CLASS_COLOURS.values())))
INLINE_SHADES: dict[tuple[float, float, float], int] = {(0.996, 0.004, 0.008): 0, (0.996, 0.004, 0.024): 1}


def inline_shade(colour: object) -> int:
    """Which of the two inline shades a glyph carries (0 for anything else). Two consecutive
    inline-math glyphs of different shades belong to different formulas."""
    if isinstance(colour, (list, tuple)) and len(colour) == 3:
        return INLINE_SHADES.get(tuple(round(float(c), 3) for c in colour), 0)  # type: ignore[arg-type]
    return 0


def classify_colour(colour: object) -> str:
    """Fingerprint -> class; black or absent -> text; any other colour -> 'inherit'.

    Author colours (hyperref links, \\textcolor) override the instrumentation colour inside
    their own group, so such glyphs take the class of the preceding glyph on the page.
    """
    if colour is None:
        return "text"
    if isinstance(colour, (int, float)):
        return "text" if float(colour) == 0 else "inherit"
    if isinstance(colour, (list, tuple)):
        vals = [float(c) for c in colour]
        if len(vals) == 3:
            key = tuple(round(v, 3) for v in vals)
            if key in CLASS_COLOURS:
                return CLASS_COLOURS[key]  # type: ignore[index]
        if all(v == 0 for v in vals) or (len(vals) == 4 and vals[:3] == [0, 0, 0]):
            return "text"
        return "inherit"
    return "text"


_MATH = {"inline_math", "display_math", "equation_tag"}
_INHERITABLE = {"float", "table", "footnote"}


def _resolve_inherit(glyphs: list[Glyph]) -> None:
    """An author-coloured glyph (link, \\textcolor) keeps the class of the surrounding
    non-math text when that is a caption, table or footnote; everywhere else it is text.
    Math glyphs always carry a fingerprint colour, so a coloured glyph is never math."""
    prev = "text"
    for g in glyphs:
        if g.cls == "inherit":
            g.cls = prev if prev in _INHERITABLE else "text"
        elif g.cls not in _MATH:
            prev = g.cls


@dataclass(slots=True)
class Glyph:
    text: str
    x0: float
    top: float
    x1: float
    bottom: float
    size: float
    font: str
    cls: str
    upright: bool
    shade: int = 0  # inline-math shade (see inline_shade)


@dataclass(slots=True)
class Page:
    number: int  # zero-based
    width: float
    height: float
    glyphs: list[Glyph]
    images: list[tuple[float, float, float, float]]  # raster image placements
    drawings: list[tuple[float, float, float, float]]  # vector curves/rects/lines bboxes


def _bbox(obj: dict[str, object]) -> tuple[float, float, float, float]:
    return (float(obj["x0"]), float(obj["top"]), float(obj["x1"]), float(obj["bottom"]))  # type: ignore[arg-type]


def _baseline(ch: dict[str, object]) -> float | None:
    """The glyph's baseline in PDF coordinates when the text matrix is a plain scale."""
    m = ch.get("matrix")
    if isinstance(m, (list, tuple)) and len(m) == 6 and float(m[1]) == 0.0 and float(m[2]) == 0.0 and float(m[3]) > 0:
        return float(m[5])
    return None


def _off_baseline(ch: dict[str, object]) -> bool:
    """Some fonts (STIX Two Math in Word-made PDFs) carry metrics that put the whole glyph box
    below its baseline; pdfplumber then reports the glyph a line too low. Trust the metrics
    only when the baseline lies inside the reported box."""
    b = _baseline(ch)
    return b is not None and not (float(ch["y0"]) - 0.05 * float(ch["size"]) <= b <= float(ch["y1"]))


def _top(ch: dict[str, object], height: float) -> float:
    if _off_baseline(ch):
        return height - (float(_baseline(ch)) + 0.75 * float(ch["size"]))  # type: ignore[arg-type]
    return float(ch["top"])


def _bottom(ch: dict[str, object], height: float) -> float:
    if _off_baseline(ch):
        return height - (float(_baseline(ch)) - 0.25 * float(ch["size"]))  # type: ignore[arg-type]
    return float(ch["bottom"])


def read_pages(instr_pdf: Path, pages: Iterable[int] | None = None) -> list[Page]:
    out: list[Page] = []
    with pdfplumber.open(str(instr_pdf)) as pdf:
        wanted = set(pages) if pages is not None else None
        for i, page in enumerate(pdf.pages):
            if wanted is not None and i not in wanted:
                continue
            glyphs = [
                Glyph(
                    text=ch["text"],
                    x0=float(ch["x0"]), top=_top(ch, float(page.height)), x1=float(ch["x1"]), bottom=_bottom(ch, float(page.height)),
                    size=float(ch["size"]), font=str(ch["fontname"]),
                    cls=classify_colour(ch.get("non_stroking_color")),
                    upright=bool(ch.get("upright", True)),
                    shade=inline_shade(ch.get("non_stroking_color")),
                )
                for ch in page.chars
            ]
            _resolve_inherit(glyphs)
            images = [_bbox(im) for im in page.images]
            drawings = [_bbox(o) for o in (page.curves + page.rects + page.lines)]
            out.append(Page(i, float(page.width), float(page.height), glyphs, images, drawings))
    return out


@dataclass(slots=True)
class Run:
    """A maximal sequence of consecutive same-class glyphs on one line."""

    cls: str
    x0: float
    top: float
    x1: float
    bottom: float
    text: str
    start: int  # glyph index range within the page
    end: int


def runs(page: Page, classes: Iterable[str] | None = None) -> list[Run]:
    """Group consecutive glyphs of the same class into line runs.

    Glyph order follows the content stream, which for TeX output is reading order within a line.
    A run breaks when the class changes or the next glyph is not on the same line (vertical overlap)
    or jumps backwards/far horizontally.
    """
    wanted = set(classes) if classes else None
    out: list[Run] = []
    cur: Run | None = None
    for i, g in enumerate(page.glyphs):
        if wanted is not None and g.cls not in wanted:
            if cur is not None:
                out.append(cur)
                cur = None
            continue
        same_line = cur is not None and g.cls == cur.cls and _vertical_overlap(cur, g) and (
            g.x0 >= cur.x0 - 2 and g.x0 - cur.x1 < max(3.0 * g.size, 20)
        )
        if cur is not None and same_line:
            cur.x0, cur.top = min(cur.x0, g.x0), min(cur.top, g.top)
            cur.x1, cur.bottom = max(cur.x1, g.x1), max(cur.bottom, g.bottom)
            cur.text += g.text
            cur.end = i + 1
        else:
            if cur is not None:
                out.append(cur)
            cur = Run(g.cls, g.x0, g.top, g.x1, g.bottom, g.text, i, i + 1)
    if cur is not None:
        out.append(cur)
    return out


def _vertical_overlap(a: Run, g: Glyph) -> bool:
    inter = min(a.bottom, g.bottom) - max(a.top, g.top)
    return inter > 0.3 * min(a.bottom - a.top, g.bottom - g.top)


def class_counts(page: Page) -> dict[str, int]:
    counts = dict.fromkeys(CLASSES, 0)
    for g in page.glyphs:
        counts[g.cls] += 1
    return counts
