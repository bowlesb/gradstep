#!/usr/bin/env python3
"""Where a PDF draws its pictures, page by page, for the weakness report's figure check
(scripts/device-route-weaknesses.mjs, docs/reviews/DEVICE_PDF_WEAKNESSES_20261024.md).

    python3 -E scripts/device-route-graphics.py <paper.pdf> <out.json>

Evaluation only, on this Mac (PyMuPDF): raster images placed on the page, and vector drawings grouped into clusters
(paths within 8 pt of each other), each as [x0, y0, x1, y1, kind, text_share] in points with a top-left origin.
`text_share` is the share of the box covered by text-layer words (a framed algorithm or a coloured box is mostly
text; a plot is not). Rules a table draws (thin lines) are left out. The route never sees any of this: it is the
truth a device figure crop is compared with (IoU), standing in for the HTML figure's place on the page, which the
HTML does not carry.
"""
import json
import sys

import fitz  # PyMuPDF

GAP = 8.0


def merge(rects):
    """Clusters of rectangles closer than GAP (single linkage, repeated until stable)."""
    boxes = [list(r) for r in rects]
    changed = True
    while changed:
        changed = False
        out = []
        for b in boxes:
            for o in out:
                if b[0] - GAP <= o[2] and o[0] - GAP <= b[2] and b[1] - GAP <= o[3] and o[1] - GAP <= b[3]:
                    o[0], o[1], o[2], o[3] = min(o[0], b[0]), min(o[1], b[1]), max(o[2], b[2]), max(o[3], b[3])
                    changed = True
                    break
            else:
                out.append(b)
        boxes = out
    return boxes


def text_share(box, words):
    area = max(1e-6, (box[2] - box[0]) * (box[3] - box[1]))
    covered = 0.0
    for w in words:
        x0, y0, x1, y1 = max(box[0], w[0]), max(box[1], w[1]), min(box[2], w[2]), min(box[3], w[3])
        if x1 > x0 and y1 > y0:
            covered += (x1 - x0) * (y1 - y0)
    return min(1.0, covered / area)


def main(pdf_path, out_path):
    doc = fitz.open(pdf_path)
    pages = []
    for page in doc:
        rect = page.rect
        words = [w[:4] for w in page.get_text("words")]
        found = []
        for info in page.get_image_info():
            b = info.get("bbox")
            if b and (b[2] - b[0]) > 4 and (b[3] - b[1]) > 4:
                found.append([b[0], b[1], b[2], b[3], "image"])
        rects = []
        try:
            drawings = page.get_drawings()
        except Exception:  # a page PyMuPDF cannot walk: images only
            drawings = []
        for d in drawings:
            r = d.get("rect")
            if r is None:
                continue
            w, h = r.x1 - r.x0, r.y1 - r.y0
            # A table's or a footnote's rule, a page-wide background: not a picture.
            if (h < 2.5 and w > 30) or (w < 2.5 and h > 30) or (w > rect.width * 0.95 and h > rect.height * 0.9):
                continue
            rects.append((r.x0, r.y0, r.x1, r.y1))
        for c in merge(rects[:20000]):
            if (c[2] - c[0]) >= 12 and (c[3] - c[1]) >= 12:
                found.append([c[0], c[1], c[2], c[3], "drawing"])
        clipped = []
        for b in found:
            x0, y0, x1, y1 = max(0, b[0]), max(0, b[1]), min(rect.width, b[2]), min(rect.height, b[3])
            if x1 - x0 > 4 and y1 - y0 > 4:
                box = [round(x0, 1), round(y0, 1), round(x1, 1), round(y1, 1)]
                clipped.append(box + [b[4], round(text_share(box, words), 3)])
        pages.append({"width": rect.width, "height": rect.height, "graphics": clipped})
    with open(out_path, "w") as f:
        json.dump({"format": "device-route-graphics-v1", "pages": pages}, f)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
