"""Export a labelled paper set as a training/evaluation dataset.

Layout: data/datasets/<name>/
  splits.json                       family -> train | dev | test (deterministic hash)
  pages/<paper>/p0007.png + .json   page image (150 dpi) and all labels on that page, in pixels
  equations/index.jsonl, equations/<paper>/<id>.png   display and single-line inline crops with LaTeX
  tables/index.jsonl, tables/<paper>/<id>.png         table crops with their grid in crop pixels
Pages excluded by the layout check or with more than 30% unaligned text are written with
usable=false so layout training can skip them while crops from aligned units remain usable.
"""

from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

import pypdfium2 as pdfium
from PIL import Image

from science_reader_pdf.data.papers import family_of
from science_reader_pdf.paths import DATA, labels_json, paper_dir, plain_pdf

DPI = 150
PAD_DISPLAY = 6
PAD_INLINE = (1, 3)  # horizontal, vertical: neighbouring punctuation sits 1-2 px away on the same line
PAD_TABLE = 8


def split_of(family: str) -> str:
    h = int(hashlib.sha256(family.encode()).hexdigest()[:8], 16) % 20
    return "dev" if h == 0 else "test" if h == 1 else "train"


@dataclass
class ExportStats:
    paper: str
    pages: int
    usable_pages: int
    display_crops: int
    inline_crops: int
    table_crops: int


def _px(box: dict[str, float], s: float) -> list[int]:
    return [int(box["x0"] * s), int(box["top"] * s), int(box["x1"] * s + 0.999), int(box["bottom"] * s + 0.999)]


def _on_page(boxes: list[dict[str, float]], page: int, s: float) -> list[list[int]]:
    return [_px(b, s) for b in boxes if int(b["page"]) == page]


def _union(boxes: list[list[int]]) -> list[int]:
    return [min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes)]


def _crop(img: Image.Image, box: list[int], pad: int | tuple[int, int], margin: int = 8) -> Image.Image | None:
    """Crop the box plus a 1 px halo, then surround it with white: recognisers expect a margin,
    and padding with the page's own pixels pulls in parts of neighbouring lines (which models
    read as accents or bold)."""
    px, py = (pad, pad) if isinstance(pad, int) else pad
    px, py = min(px, 1), min(py, 1)
    w, h = img.size
    x0, y0, x1, y1 = max(0, box[0] - px), max(0, box[1] - py), min(w, box[2] + px), min(h, box[3] + py)
    if x1 <= x0 or y1 <= y0:
        return None  # the box lies off the page (a glyph positioned outside the media box)
    tight = img.crop((x0, y0, x1, y1))
    out = Image.new("RGB", (tight.width + 2 * margin, tight.height + 2 * margin), "white")
    out.paste(tight, (margin, margin))
    return out


def page_records(L: dict[str, object], s: float) -> dict[int, dict[str, list[dict[str, object]]]]:
    """The structural part of a page record (blocks, maths, tables, figures) in page pixels at
    scale `s`, from a paper's labels; the bench builder uses it to read fresh labels."""
    by_page: dict[int, dict[str, list[dict[str, object]]]] = defaultdict(lambda: defaultdict(list))
    for blk in L["blocks"]:  # type: ignore[index]
        for p in {int(x["page"]) for x in blk["boxes"]}:
            by_page[p]["blocks"].append({"id": blk["id"], "kind": blk["kind"], "pdf_class": blk["pdf_class"], "boxes": _on_page(blk["boxes"], p, s), "text": blk["text"], "coverage": blk["coverage"]})
    for m in L["inline_math"]:  # type: ignore[index]
        for p in {int(x["page"]) for x in m["boxes"]}:
            by_page[p]["inline_math"].append({"id": m["id"], "block_id": m["block_id"], "tex": m["tex"], "boxes": _on_page(m["boxes"], p, s)})
    for dm in L["display_math"]:  # type: ignore[index]
        for p in {int(x["page"]) for x in dm["boxes"]}:
            by_page[p]["display_math"].append({"id": dm["id"], "rows": dm["rows"], "tags": dm["tags"], "boxes": _on_page(dm["boxes"], p, s), "tag_boxes": _on_page(dm["tag_boxes"], p, s)})
    for t in L["tables"]:  # type: ignore[index]
        for p in {int(x["page"]) for x in t["boxes"]}:
            by_page[p]["tables"].append({"id": t["id"], "boxes": _on_page(t["boxes"], p, s), "n_rows": t["n_rows"], "n_cols": t["n_cols"], "caption_block_id": t["caption_block_id"],
                                          "cells": [{"row": c["row"], "col": c["col"], "rowspan": c["rowspan"], "colspan": c["colspan"], "header": c["header"], "text": c["text"], "boxes": _on_page(c["boxes"], p, s)} for c in t["cells"]]})
    for f in L["figures"]:  # type: ignore[index]
        for p in {int(x["page"]) for x in f["boxes"]}:
            by_page[p]["figures"].append({"id": f["id"], "boxes": _on_page(f["boxes"], p, s), "caption_block_id": f["caption_block_id"]})
    return by_page


def export_pages(pid: str, name: str, family: str, split: str) -> int:
    """Page images and page label records only (no crops), for papers whose labels live
    outside the arXiv tree (PMC articles). Returns the number of pages written."""
    L = json.loads(labels_json(pid).read_text())
    root = DATA / "datasets" / name
    page_dir = root / "pages" / pid
    page_dir.mkdir(parents=True, exist_ok=True)
    doc = pdfium.PdfDocument(str(plain_pdf(pid)))
    s = DPI / 72
    by_page = page_records(L, s)
    n = 0
    for pg in L["pages"]:
        p = pg["number"]
        glyphs = pg["glyphs"]
        page = doc[p]
        img = page.render(scale=s, draw_annots=False).to_pil().convert("RGB")
        img.save(page_dir / f"p{p:04d}.png", optimize=False)
        rec = {"paper": pid, "family": family, "split": split, "page": p, "dpi": DPI, "width_pt": pg["width"], "height_pt": pg["height"],
               "width_px": img.width, "height_px": img.height, "usable": glyphs > 0 and pg["unaligned_text_glyphs"] <= 0.3 * glyphs, "excluded_layout": glyphs == 0,
               "unaligned_text_fraction": round(pg["unaligned_text_glyphs"] / glyphs, 3) if glyphs else None, **{k: v for k, v in by_page[p].items()}}
        (page_dir / f"p{p:04d}.json").write_text(json.dumps(rec, ensure_ascii=False))
        n += 1
    doc.close()
    return n


def export_paper(pid: str, root: Path) -> ExportStats:
    b = paper_dir(pid) / "build"
    L = json.loads((b / "labels.json").read_text())
    fam = family_of(pid)
    split = split_of(fam)
    page_dir = root / "pages" / pid
    eq_dir = root / "equations" / pid
    tb_dir = root / "tables" / pid
    for d in (page_dir, eq_dir, tb_dir):
        d.mkdir(parents=True, exist_ok=True)
    doc = pdfium.PdfDocument(str(b / "plain.pdf"))
    s = DPI / 72
    by_page = page_records(L, s)

    eq_index = (root / "equations" / "index.jsonl").open("a")
    tb_index = (root / "tables" / "index.jsonl").open("a")
    n_disp = n_inl = n_tab = usable = 0
    try:
        for pg in L["pages"]:
            p = pg["number"]
            glyphs = pg["glyphs"]
            is_usable = glyphs > 0 and pg["unaligned_text_glyphs"] <= 0.3 * glyphs
            usable += is_usable
            page = doc[p]
            img = page.render(scale=s, draw_annots=False).to_pil().convert("RGB")
            img.save(page_dir / f"p{p:04d}.png", optimize=False)
            rec = {"paper": pid, "family": fam, "split": split, "page": p, "dpi": DPI, "width_pt": pg["width"], "height_pt": pg["height"],
                   "width_px": img.width, "height_px": img.height, "usable": is_usable, "excluded_layout": glyphs == 0,
                   "unaligned_text_fraction": round(pg["unaligned_text_glyphs"] / glyphs, 3) if glyphs else None, **{k: v for k, v in by_page[p].items()}}
            (page_dir / f"p{p:04d}.json").write_text(json.dumps(rec, ensure_ascii=False))
            if glyphs == 0:
                continue
            for dm in by_page[p]["display_math"]:
                if not dm["boxes"] or len({int(x["page"]) for x in next(d for d in L["display_math"] if d["id"] == dm["id"])["boxes"]}) != 1:
                    continue  # skip displays that span pages
                box = _union(dm["boxes"])  # type: ignore[arg-type]
                name = f"{dm['id']}.png"
                crop = _crop(img, box, PAD_DISPLAY)
                if crop is None:
                    continue
                crop.save(eq_dir / name)
                eq_index.write(json.dumps({"paper": pid, "family": fam, "split": split, "page": p, "placement": "display", "id": dm["id"], "path": f"equations/{pid}/{name}", "box": box, "tex": " \\\\ ".join(dm["rows"]), "rows": dm["rows"], "tags": dm["tags"]}, ensure_ascii=False) + "\n")
                n_disp += 1
            for m in by_page[p]["inline_math"]:
                if len(m["boxes"]) != 1:
                    continue  # line-broken or page-broken inline math has no single crop
                box = m["boxes"][0]  # type: ignore[index]
                if box[2] - box[0] < 4 or box[3] - box[1] < 4:
                    continue
                name = f"{m['id']}.png"
                crop = _crop(img, box, PAD_INLINE)
                if crop is None:
                    continue
                crop.save(eq_dir / name)
                eq_index.write(json.dumps({"paper": pid, "family": fam, "split": split, "page": p, "placement": "inline", "id": m["id"], "path": f"equations/{pid}/{name}", "box": box, "tex": m["tex"], "block_id": m["block_id"]}, ensure_ascii=False) + "\n")
                n_inl += 1
            for t in by_page[p]["tables"]:
                if not t["boxes"]:
                    continue
                box = _union(t["boxes"])  # type: ignore[arg-type]
                name = f"{t['id']}.png"
                crop = _crop(img, box, PAD_TABLE)
                if crop is None:
                    continue
                crop.save(tb_dir / name)
                ox, oy = max(0, box[0] - PAD_TABLE), max(0, box[1] - PAD_TABLE)
                cells = [{**c, "boxes": [[x0 - ox, y0 - oy, x1 - ox, y1 - oy] for x0, y0, x1, y1 in c["boxes"]]} for c in t["cells"]]  # type: ignore[misc]
                tb_index.write(json.dumps({"paper": pid, "family": fam, "split": split, "page": p, "id": t["id"], "path": f"tables/{pid}/{name}", "box": box, "n_rows": t["n_rows"], "n_cols": t["n_cols"], "cells": cells}, ensure_ascii=False) + "\n")
                n_tab += 1
    finally:
        eq_index.close()
        tb_index.close()
        doc.close()
    return ExportStats(pid, len(L["pages"]), usable, n_disp, n_inl, n_tab)


def accepted(pid: str) -> tuple[bool, str]:
    """A paper enters a dataset only if both builds succeeded, the two builds are glyph-identical
    on at least some pages (the layout check), and the recompile has the arXiv PDF's page
    count; otherwise its labels describe a different document. (factory-v2 admitted one paper
    whose instrumented build had lost a page: half of its crops were on the wrong page.)"""
    b = paper_dir(pid) / "build"
    for name in ("plain", "instr"):
        f = b / f"{name}.json"
        if not f.is_file() or not json.loads(f.read_text()).get("ok"):
            return False, f"{name} build failed"
    layout = b / "layout-check.json"
    if not layout.is_file():
        return False, "no layout check"
    lc = json.loads(layout.read_text())
    if not lc.get("identical") and not lc.get("pages_identical"):
        return False, f"builds differ: {lc.get('detail') or 'no identical pages'}"
    cmp = b / "arxiv-compare.json"
    if cmp.is_file():
        d = json.loads(cmp.read_text())
        if d["pages_ours"] != d["pages_arxiv"]:
            return False, f"page count {d['pages_ours']} vs arXiv {d['pages_arxiv']}"
        if d["text_ratio_mean"] < 0.9:
            return False, f"text similarity to arXiv {d['text_ratio_mean']}"
    return True, ""


def resume_indexes(root: Path) -> set[str]:
    """Prepare the indexes of an interrupted export for a resume and return the papers that are
    complete. The last paper of any index may be partial, so its rows are dropped from every
    index and it is redone; rows are deduplicated by (paper, id), which also repairs indexes
    that earlier resumes doubled (factory-v3 held 7.5% duplicate rows: a paper with equations but
    no tables was taken as unfinished and exported again)."""
    rows_of: dict[str, list[dict[str, object]]] = {}
    for sub in ("equations", "tables"):
        idx = root / sub / "index.jsonl"
        rows_of[sub] = [json.loads(line) for line in idx.read_text().splitlines() if line.strip()] if idx.exists() else []
    redo = {str(rows[-1]["paper"]) for rows in rows_of.values() if rows}
    done: set[str] = set()
    for sub, rows in rows_of.items():
        seen: set[tuple[str, str]] = set()
        kept = []
        for r in rows:
            key = (str(r["paper"]), str(r["id"]))
            if r["paper"] in redo or key in seen:
                continue
            seen.add(key)
            kept.append(r)
        if len(kept) != len(rows):
            with (root / sub / "index.jsonl").open("w") as f:
                for r in kept:
                    f.write(json.dumps(r, ensure_ascii=False) + "\n")
        done |= {str(r["paper"]) for r in kept}
    return done


def export_all(ids: list[str], name: str, resume: bool = False) -> list[ExportStats]:
    """`resume` keeps the papers already in the indexes and exports the rest; the last paper of
    each index may be partial (an interrupted run), so its rows are dropped and it is redone."""
    root = DATA / "datasets" / name
    root.mkdir(parents=True, exist_ok=True)
    rejected = {pid: why for pid in ids for ok, why in [accepted(pid)] if not ok}
    ids = [pid for pid in ids if pid not in rejected]
    (root / "rejected.json").write_text(json.dumps(rejected, indent=1, sort_keys=True))
    splits = {family_of(pid): split_of(family_of(pid)) for pid in ids}
    (root / "splits.json").write_text(json.dumps(splits, indent=1, sort_keys=True))
    for sub in ("equations", "tables"):
        (root / sub).mkdir(exist_ok=True)
        if not resume and (root / sub / "index.jsonl").exists():
            (root / sub / "index.jsonl").unlink()
    done = resume_indexes(root) if resume else set()
    return [export_paper(pid, root) for pid in ids if pid not in done]
