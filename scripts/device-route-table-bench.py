# Table grid bench (scripts/device-route-table-bench.mjs): for the factory's labelled tables of one split, the text layer's characters inside each table's box
# (pdfplumber, the device route's text layer reference) and the label's cells in page points.
#   python -I scripts/device-route-table-bench.py <factory dir> <arxiv dir> <split> <out.jsonl> [limit]
import json, sys, collections
import pdfplumber

factory, arxiv, split, out = sys.argv[1:5]
limit = int(sys.argv[5]) if len(sys.argv) > 5 else 0
PAD = 9          # the factory's crop padding (PAD_TABLE), pixels at 150 dpi
K = 72 / 150     # pixels to points
rows = [json.loads(l) for l in open(f"{factory}/tables/index.jsonl")]
rows = [r for r in rows if r["split"] == split]
if limit:
    rows = rows[:limit]
by_paper = collections.defaultdict(list)
for r in rows:
    by_paper[r["paper"]].append(r)
n = 0
with open(out, "w") as f:
    for paper, tables in by_paper.items():
        try:
            pdf = pdfplumber.open(f"{arxiv}/{paper}/arxiv.pdf")
        except Exception as e:
            print(paper, "no pdf", e, file=sys.stderr)
            continue
        with pdf:
            for t in tables:
                try:
                    page = pdf.pages[t["page"]]
                except Exception:
                    continue
                x0, y0, x1, y1 = t["box"]
                ox, oy = max(0, x0 - PAD), max(0, y0 - PAD)
                box = [x0 * K - 1.5, y0 * K - 1.5, x1 * K + 1.5, y1 * K + 1.5]
                glyphs = []
                for c in page.chars:
                    cx, cy = (c["x0"] + c["x1"]) / 2, (c["top"] + c["bottom"]) / 2
                    if box[0] <= cx <= box[2] and box[1] <= cy <= box[3]:
                        glyphs.append([c["text"], round(c["x0"], 3), round(c["top"], 3), round(c["x1"], 3), round(c["bottom"], 3), round(c["size"], 3), c["fontname"], bool(c["upright"])])
                cells = [{"row": c["row"], "col": c["col"], "rowspan": c["rowspan"], "colspan": c["colspan"], "header": c.get("header", False), "text": c["text"],
                          "boxes": [[(a + ox) * K, (b + oy) * K, (cc + ox) * K, (d + oy) * K] for a, b, cc, d in c["boxes"]]} for c in t["cells"]]
                f.write(json.dumps({"paper": paper, "page": t["page"], "id": t["id"], "n_rows": t["n_rows"], "n_cols": t["n_cols"], "box": box, "glyphs": glyphs, "cells": cells}, ensure_ascii=False) + "\n")
                n += 1

print(split, n, "tables", file=sys.stderr)
