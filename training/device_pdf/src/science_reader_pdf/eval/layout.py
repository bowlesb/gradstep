"""Layout bench and scorer (sub-problem 1: typed regions on a page).

Bench rows (`data/datasets/<dataset>/layout-bench-<name>.jsonl`), one per page:
  paper, family, split, page, path (page image), width_px, height_px,
  regions: [{"cls", "box"}]       gold regions in page pixels
  ignore:  [box, ...]             don't-care boxes: text the labels do not cover (running heads,
                                  page numbers, content missing from the HTML) and author lines

Gold regions come from the factory page record: a block's line boxes grouped into column runs
(a paragraph that continues in the next column or after a display is two regions, which is also
what a detector sees), one region per display (its rows and its tag), per table and per figure.

Scoring: per class, predictions are matched greedily by IoU >= 0.5 to unmatched gold regions of
the same class; precision, recall and F1 per class and micro-averaged, plus a class-agnostic
match. Predictions in classes we do not label (page headers, inline formulas) or lying mostly
inside a don't-care box are dropped first, so the numbers describe what the labels can judge.
"""

from __future__ import annotations

import json
import random
import subprocess
import time
from collections import Counter, defaultdict
from collections.abc import Iterable
from datetime import UTC, datetime
from pathlib import Path

from science_reader_pdf.paths import DATA, REPO_ROOT, RUNS, labels_json, plain_pdf

BENCH_DIR = DATA / "datasets"
CLASSES = ["title", "abstract", "heading", "paragraph", "caption", "footnote", "bibitem", "listing", "display", "table", "figure"]
BLOCK_CLASS = {"title": "title", "abstract": "abstract", "heading": "heading", "paragraph": "paragraph", "list_item": "paragraph", "caption": "caption", "footnote": "footnote", "bibitem": "bibitem", "listing": "listing"}
IGNORED_BLOCKS = {"author", "table"}  # author lines are not a class we score; table blocks duplicate L["tables"]
IOU_MATCH = 0.5
MIN_COVERAGE = 0.6  # blocks with less of their text found on the page are left out of the gold (their glyphs become don't-care)
DONT_CARE_COVER = 0.6  # a prediction whose area lies this much inside don't-care boxes is dropped

Box = list[int]


def iou(a: Box, b: Box) -> float:
    ix0, iy0, ix1, iy1 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    inter = max(0, ix1 - ix0) * max(0, iy1 - iy0)
    if inter == 0:
        return 0.0
    return inter / (area(a) + area(b) - inter)


def area(b: Box) -> int:
    return max(0, b[2] - b[0]) * max(0, b[3] - b[1])


def union(boxes: Iterable[Box]) -> Box:
    bs = list(boxes)
    return [min(b[0] for b in bs), min(b[1] for b in bs), max(b[2] for b in bs), max(b[3] for b in bs)]


def _h_overlap(a: Box, b: Box) -> float:
    inter = min(a[2], b[2]) - max(a[0], b[0])
    return inter / max(1, min(a[2] - a[0], b[2] - b[0]))


def column_runs_indexed(lines: list[Box], gap_factor: float = 1.6) -> list[tuple[Box, int]]:
    """Group a block's line boxes into runs of vertically consecutive, horizontally overlapping
    lines; each run is one region, returned with the index (in the given, stream order) of its
    first line, which orders the runs of one block for reading. A new column, or a display
    equation inside the paragraph, starts a new run. Runs grow in parallel, so lines of two
    columns given in top-to-bottom order still form one run per column."""
    runs: list[list[tuple[Box, int]]] = []
    for idx, ln in sorted(enumerate(lines), key=lambda t: (t[1][1], t[1][0])):
        for run in runs:
            prev = run[-1][0]
            h = max(prev[3] - prev[1], ln[3] - ln[1], 1)
            # lines of two columns never overlap horizontally; 0.25 keeps a short last line
            # under a first line that starts late (a caption whose label glyphs went unmatched)
            if _h_overlap(prev, ln) >= 0.25 and -0.5 * h <= ln[1] - prev[3] <= gap_factor * h:
                run.append((ln, idx))
                break
        else:
            runs.append([(ln, idx)])
    return [(union(b for b, _ in r), min(i for _, i in r)) for r in runs]


def column_runs(lines: list[Box], gap_factor: float = 1.6) -> list[Box]:
    return [b for b, _ in column_runs_indexed(lines, gap_factor)]


def largest_cluster(boxes: list[Box]) -> list[Box]:
    """The largest group of boxes linked as table cells: two cells link when they share a row
    (vertical overlap) or sit in the same column on adjacent rows. Cells whose text matched
    elsewhere on the page (a duplicate header in the next table, a number inside a paragraph)
    are dropped this way, so the table region is the table."""
    if len(boxes) <= 2:
        return boxes
    h = sorted(b[3] - b[1] for b in boxes)[len(boxes) // 2]
    parent = list(range(len(boxes)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, a in enumerate(boxes):
        for j in range(i + 1, len(boxes)):
            b = boxes[j]
            v_over = min(a[3], b[3]) - max(a[1], b[1])
            h_over = min(a[2], b[2]) - max(a[0], b[0])
            same_row = v_over >= 0.5 * min(a[3] - a[1], b[3] - b[1])
            same_col = h_over >= 0.5 * min(a[2] - a[0], b[2] - b[0]) and max(a[1], b[1]) - min(a[3], b[3]) <= 1.5 * h
            if same_row or same_col:
                parent[find(i)] = find(j)
    groups: dict[int, list[Box]] = defaultdict(list)
    for i, b in enumerate(boxes):
        groups[find(i)].append(b)
    return max(groups.values(), key=len)


def _inside(a: Box, b: Box, frac: float = 0.9) -> bool:
    ix0, iy0, ix1, iy1 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    return max(0, ix1 - ix0) * max(0, iy1 - iy0) >= frac * area(a)


def figure_regions(rec: dict[str, object], text_regions: list[dict[str, object]]) -> list[dict[str, object]]:
    """Figure gold from the factory's figure boxes, which come from image and drawing placements
    and are loose: a drawing's bounding box can run off the page, and the band above a caption
    can reach up through the previous figure's caption. So: clip to the page; cut the box to
    below any text region inside it that sits above the figure's own caption; and when figures
    nest (subfigures with their own captions), keep the leaves, which is what a detector boxes."""
    w, h = int(rec.get("width_px") or 10**6), int(rec.get("height_px") or 10**6)
    caption_box = {r["id"]: r["box"] for r in text_regions if r["cls"] == "caption"}
    clipped: dict[str, Box] = {}
    for f in rec.get("figures") or []:
        boxes = [[max(0, b[0]), max(0, b[1]), min(w, b[2]), min(h, b[3])] for b in f["boxes"]]
        boxes = [b for b in boxes if b[2] > b[0] and b[3] > b[1]]
        if boxes:
            clipped[f["id"]] = union(boxes)
    out: list[dict[str, object]] = []
    for f in rec.get("figures") or []:
        box = clipped.get(f["id"])
        if box is None:
            continue
        cap = caption_box.get(f.get("caption_block_id"))
        cap_top = cap[1] if cap and cap[1] >= box[1] else box[3]
        # captions of figures nested in this one (subfigure captions) are part of the figure
        sub_caps = {g.get("caption_block_id") for g in rec.get("figures") or [] if g["id"] != f["id"] and g["id"] in clipped and _inside(clipped[g["id"]], box)}
        floor = box[1]
        for r in text_regions:
            rb = r["box"]
            if r["id"] in sub_caps:
                continue
            if rb[3] <= cap_top and rb[1] >= box[1] - 2 and rb[3] <= box[3] and _h_overlap(rb, box) >= 0.5:
                floor = max(floor, rb[3])
        box = [box[0], floor, box[2], min(box[3], cap_top) if cap else box[3]]
        if box[2] > box[0] and box[3] > box[1]:
            out.append({"cls": "figure", "box": box, "id": f["id"]})
    return [r for r in out if not any(o is not r and _inside(o["box"], r["box"]) and area(o["box"]) < area(r["box"]) for o in out)]


def regions_of(rec: dict[str, object]) -> tuple[list[dict[str, object]], list[Box]]:
    """Gold regions and don't-care boxes (author lines) from a factory page record."""
    regions: list[dict[str, object]] = []
    ignore: list[Box] = []
    for blk in rec.get("blocks") or []:
        boxes = [b for b in blk["boxes"] if b[2] > b[0] and b[3] > b[1]]
        if not boxes:
            continue
        if blk["kind"] == "author":
            ignore.extend(column_runs(boxes))
            continue
        cls = BLOCK_CLASS.get(blk["kind"])
        if cls is None:
            continue
        if float(blk.get("coverage", 1.0)) < MIN_COVERAGE:
            continue  # a block whose text was mostly not found on the page: its boxes are fragments matched elsewhere
        no = int(str(blk["id"])[1:]) if str(blk["id"])[1:].isdigit() else 0  # blocks are numbered in document order
        regions.extend({"cls": cls, "box": r, "id": blk["id"], "seq": [no, first], "pdf_class": blk.get("pdf_class", "flow"), "text": blk.get("text", ""), "coverage": float(blk.get("coverage", 1.0))} for r, first in column_runs_indexed(boxes))
    for dm in rec.get("display_math") or []:
        # the body only: detectors box the equation and treat its number as a separate element
        # (PaddleX's formula_number, dropped above), and on single-column publisher pages the
        # number sits far enough right to halve the IoU of a correct body box
        boxes = [b for b in dm["boxes"] if b[2] > b[0] and b[3] > b[1]]
        if boxes:
            regions.append({"cls": "display", "box": union(boxes), "id": dm["id"]})
    for t in rec.get("tables") or []:
        cells = [b for c in t.get("cells") or [] for b in c["boxes"] if b[2] > b[0] and b[3] > b[1]]
        boxes = largest_cluster(cells) if cells else [b for b in t["boxes"] if b[2] > b[0] and b[3] > b[1]]
        if boxes:
            regions.append({"cls": "table", "box": union(boxes), "id": t["id"]})
    regions.extend(figure_regions(rec, regions))
    # a block whose text matched glyphs inside another block (a fragment of a long paragraph
    # found in the title, say) is a label artefact, not a region
    blocks = [r for r in regions if "coverage" in r]
    dup = {id(r) for r in blocks for o in blocks if o is not r and o["id"] != r["id"] and _inside(r["box"], o["box"], 0.6) and area(o["box"]) > area(r["box"]) and float(o["coverage"]) >= float(r["coverage"])}  # type: ignore[arg-type]
    regions = [r for r in regions if id(r) not in dup]
    # a run-in heading (\paragraph{...}) sits on the first line of its paragraph: it is part of
    # that region, not a region a detector could box
    regions = [r for r in regions if not (r["cls"] == "heading" and any(o is not r and _inside(r["box"], o["box"]) for o in regions))]
    # the reference list is one block per column to a detector; entries are split later by
    # text-layer rules, so consecutive bibitem regions merge
    bib = [r for r in regions if r["cls"] == "bibitem"]
    if bib:
        regions = [r for r in regions if r["cls"] != "bibitem"] + [{"cls": "bibitem", "box": b, "id": f"bib{i}"} for i, b in enumerate(column_runs([r["box"] for r in bib]))]
    return regions, ignore


def _lines_of(glyph_boxes: list[Box]) -> list[Box]:
    """Group glyph boxes into lines by vertical overlap, then into blocks of consecutive lines."""
    lines: list[list[Box]] = []
    for g in sorted(glyph_boxes, key=lambda b: (b[1], b[0])):
        for ln in lines:
            lb = union(ln)
            if min(lb[3], g[3]) - max(lb[1], g[1]) > 0.5 * min(lb[3] - lb[1], g[3] - g[1]) and abs(g[0] - lb[2]) < 3 * (g[3] - g[1]):
                ln.append(g)
                break
        else:
            lines.append([g])
    return column_runs([union(ln) for ln in lines])


def uncovered_text(pid: str, page: int, regions: list[dict[str, object]], ignore: list[Box], scale: float) -> list[Box]:
    """Boxes of text-layer lines on the page that no gold region covers: the detector will see
    text there, but the labels say nothing about it."""
    from science_reader_pdf.data.pdftext import read_pages

    pg = read_pages(plain_pdf(pid), [page])[0]
    covered = [r["box"] for r in regions] + ignore
    loose: list[Box] = []
    for g in pg.glyphs:
        if not g.text.strip():
            continue
        b = [int(g.x0 * scale), int(g.top * scale), int(g.x1 * scale + 0.999), int(g.bottom * scale + 0.999)]
        cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        if any(c[0] - 2 <= cx <= c[2] + 2 and c[1] - 2 <= cy <= c[3] + 2 for c in covered):
            continue
        loose.append(b)
    return _lines_of(loose) if loose else []


_labels_cache: dict[str, dict[str, object]] = {}


def labels_of(pid: str) -> dict[str, object]:
    if pid not in _labels_cache:
        _labels_cache.clear()
        _labels_cache[pid] = json.loads(labels_json(pid).read_text())
    return _labels_cache[pid]


def fresh_record(rec: dict[str, object]) -> dict[str, object]:
    """The page record with its structure (blocks, maths, tables, figures) taken from the
    paper's current labels rather than the dataset export, so a relabel reaches the bench
    without a re-export; page images do not change."""
    from science_reader_pdf.data.export import page_records

    L = labels_of(str(rec["paper"]))
    fresh = page_records(L, float(rec["dpi"]) / 72).get(int(rec["page"]), {})
    out = {k: v for k, v in rec.items() if k not in ("blocks", "inline_math", "display_math", "tables", "figures")}
    out.update(fresh)
    return out


def mark_complete(pid: str, page: int, regions: list[dict[str, object]]) -> None:
    """`complete` on a block region: the block lies entirely on this page (its HTML text is then
    the text of these regions; a block continued from or onto another page has more)."""
    pages = {blk["id"]: {int(b["page"]) for b in blk["boxes"]} for blk in labels_of(pid)["blocks"]}  # type: ignore[index]
    for r in regions:
        if str(r["id"]) in pages:
            r["complete"] = pages[str(r["id"])] == {page}


def make_bench(dataset: str, name: str, n_pages: int, split: str = "test", max_unaligned: float = 0.05, per_paper: int = 2, seed: int = 0) -> Path:
    root = BENCH_DIR / dataset
    rng = random.Random(seed)
    cands: list[Path] = []
    for pdir in sorted((root / "pages").iterdir()):
        files = sorted(pdir.glob("p*.json"))
        if not files:
            continue
        first = json.loads(files[0].read_text())
        if first["split"] != split:
            continue
        ok = [f for f in files if (r := json.loads(f.read_text()))["usable"] and (r["unaligned_text_fraction"] or 0) <= max_unaligned]
        rng.shuffle(ok)
        cands.extend(ok[:per_paper])
    rng.shuffle(cands)
    out = root / f"layout-bench-{name}.jsonl"
    n = 0
    with out.open("w") as f:
        for jf in cands:
            if n >= n_pages:
                break
            rec = fresh_record(json.loads(jf.read_text()))
            regions, ignore = regions_of(rec)
            if not regions:
                continue
            scale = rec["dpi"] / 72
            ignore = ignore + uncovered_text(rec["paper"], rec["page"], regions, ignore, scale)
            mark_complete(rec["paper"], rec["page"], regions)
            row = {"paper": rec["paper"], "family": rec["family"], "split": rec["split"], "page": rec["page"], "path": f"pages/{rec['paper']}/{jf.stem}.png",
                   "width_px": rec["width_px"], "height_px": rec["height_px"], "regions": regions, "ignore": ignore}
            f.write(json.dumps(row) + "\n")
            n += 1
    return out


def load_bench(bench: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in bench.read_text().splitlines() if line.strip()]


# --- predictions and scoring -----------------------------------------------------------------

# Detector label -> our class (None: dropped before scoring). PP-DocLayout family (PaddleX).
PADDLE_MAP = {"doc_title": "title", "paragraph_title": "heading", "text": "paragraph", "abstract": "abstract", "reference": "bibitem", "reference_content": "bibitem",
              "figure_title": "caption", "table_title": "caption", "chart_title": "caption", "display_formula": "display", "formula": "display", "table": "table", "image": "figure", "figure": "figure", "chart": "figure",
              "footnote": "footnote", "algorithm": "listing", "content": "paragraph", "aside_text": "paragraph",
              "header": None, "footer": None, "number": None, "inline_formula": None, "formula_number": None, "seal": None, "vertical_text": None, "vision_footnote": None, "header_image": None, "footer_image": None}


def _covered(box: Box, others: list[Box]) -> float:
    """Fraction of `box` covered by the union of `others` (grid count at 4 px)."""
    a = area(box)
    if a == 0 or not others:
        return 0.0
    hits = 0
    total = 0
    step = 4
    for y in range(box[1], box[3], step):
        for x in range(box[0], box[2], step):
            total += 1
            if any(o[0] <= x < o[2] and o[1] <= y < o[3] for o in others):
                hits += 1
    return hits / total if total else 0.0


def _dropped(box: Box, ignore: list[Box]) -> bool:
    a = area(box)
    if a == 0:
        return True
    inter = 0
    for c in ignore:
        ix0, iy0, ix1, iy1 = max(box[0], c[0]), max(box[1], c[1]), min(box[2], c[2]), min(box[3], c[3])
        inter += max(0, ix1 - ix0) * max(0, iy1 - iy0)
    return inter / a >= DONT_CARE_COVER


TEXT_CLASSES = {"paragraph", "caption", "footnote", "bibitem", "listing", "abstract"}


def normalise_predictions(pl: list[dict[str, object]], ignore: list[Box]) -> list[dict[str, object]]:
    """What the pipeline would keep from a detector's output: unmapped classes and boxes inside
    don't-care text go; a formula box lying inside one of the model's own text boxes is inline
    math (the text-layer tagger owns it), not a display."""
    kept = [p for p in pl if p.get("cls") and not _dropped(p["box"], ignore)]
    text_boxes = [p["box"] for p in kept if p["cls"] in TEXT_CLASSES]
    kept = [p for p in kept if not (p["cls"] == "display" and any(_inside(p["box"], t, 0.8) for t in text_boxes))]
    # detectors that box each reference entry are merged per column, like the gold
    bib = [p for p in kept if p["cls"] == "bibitem"]
    if len(bib) > 1:
        merged = [{"label": "reference", "cls": "bibitem", "score": max(p["score"] for p in bib), "box": b} for b in column_runs([p["box"] for p in bib])]
        kept = [p for p in kept if p["cls"] != "bibitem"] + merged
    return kept


def score(rows: list[dict[str, object]], preds: dict[tuple[str, int], list[dict[str, object]]]) -> dict[str, object]:
    tp: Counter[str] = Counter()
    n_gold: Counter[str] = Counter()
    n_pred: Counter[str] = Counter()
    agn_tp = agn_gold = agn_pred = 0
    confusion: Counter[str] = Counter()  # "gold>pred" for class-agnostic matches with the wrong class
    for row in rows:
        gold = list(row["regions"])
        pl = normalise_predictions(preds.get((row["paper"], row["page"]), []), row["ignore"])
        pl.sort(key=lambda p: -p["score"])
        for g in gold:
            n_gold[g["cls"]] += 1
        for p in pl:
            n_pred[p["cls"]] += 1
        # figures are scored by coverage: detectors box panels of a multi-panel figure, so a gold
        # figure counts as found when predicted figure boxes cover half its area, and a predicted
        # figure box is right when half of it lies inside gold figures
        gf = [g["box"] for g in gold if g["cls"] == "figure"]
        pf = [p["box"] for p in pl if p["cls"] == "figure"]
        fig_found = sum(1 for g in gf if _covered(g, pf) >= 0.5)
        fig_wrong = sum(1 for p in pf if _covered(p, gf) < 0.5)
        tp["figure"] += fig_found
        n_pred["figure"] += fig_found + fig_wrong - len(pf)  # the panels of one found figure count as one correct box
        used: set[int] = set()
        for p in pl:
            if p["cls"] == "figure":
                continue
            best, bi = 0.0, -1
            for i, g in enumerate(gold):
                if i in used or g["cls"] != p["cls"]:
                    continue
                v = iou(p["box"], g["box"])
                if v > best:
                    best, bi = v, i
            if best >= IOU_MATCH:
                used.add(bi)
                tp[p["cls"]] += 1
        agn_gold += len(gold)
        agn_pred += len(pl)
        used_a: set[int] = set()
        for p in pl:
            best, bi = 0.0, -1
            for i, g in enumerate(gold):
                if i in used_a:
                    continue
                v = iou(p["box"], g["box"])
                if v > best:
                    best, bi = v, i
            if best >= IOU_MATCH:
                used_a.add(bi)
                agn_tp += 1
                if gold[bi]["cls"] != p["cls"]:
                    confusion[f"{gold[bi]['cls']}>{p['cls']}"] += 1

    def prf(t: int, g: int, p: int) -> dict[str, object]:
        pr = t / p if p else 0.0
        rc = t / g if g else 0.0
        return {"gold": g, "pred": p, "tp": t, "precision": round(pr, 4), "recall": round(rc, 4), "f1": round(2 * pr * rc / (pr + rc), 4) if pr + rc else 0.0}

    summary: dict[str, object] = {c: prf(tp[c], n_gold[c], n_pred[c]) for c in CLASSES if n_gold[c] or n_pred[c]}
    summary["all"] = prf(sum(tp.values()), sum(n_gold.values()), sum(n_pred.values()))
    summary["agnostic"] = prf(agn_tp, agn_gold, agn_pred)
    summary["confusion"] = dict(confusion.most_common(12))
    summary["pages"] = len(rows)
    return summary


def load_predictions(path: Path) -> dict[tuple[str, int], list[dict[str, object]]]:
    out: dict[tuple[str, int], list[dict[str, object]]] = {}
    for line in path.read_text().splitlines():
        if line.strip():
            r = json.loads(line)
            out[(r["paper"], r["page"])] = r["boxes"]
    return out


def predictions_file(out: Path, bench: Path) -> Path:
    """One predictions file per bench under the model's directory (a second bench must not
    overwrite the first bench's run). Files from before the naming carried the bench are renamed
    once, as the arXiv bench's."""
    legacy = out / "predictions.jsonl"
    new = out / f"{bench.stem}.predictions.jsonl"
    if legacy.is_file() and not new.is_file() and bench.stem == "layout-bench-v1":
        legacy.rename(new)
    return new


def run_paddlex(model_name: str, bench: Path, out: Path, device: str = "cpu", limit: int = 0, resume: bool = False, threshold: float = 0.5) -> tuple[Path, float]:
    """Run a PaddleX layout detector over the bench pages; predictions.jsonl keeps the raw label,
    the mapped class, the score and the box."""
    import paddlex

    rows = load_bench(bench)
    if limit:
        rows = rows[:limit]
    out.mkdir(parents=True, exist_ok=True)
    pred_file = predictions_file(out, bench)
    done = set(load_predictions(pred_file)) if resume and pred_file.is_file() else set()
    if not resume and pred_file.exists():
        pred_file.unlink()
    model = paddlex.create_model(model_name=model_name, device=device)
    t0 = time.monotonic()
    n = 0
    unknown: Counter[str] = Counter()
    with pred_file.open("a") as f:
        for row in rows:
            key = (row["paper"], row["page"])
            if key in done:
                continue
            img = bench.parent / row["path"]
            t1 = time.monotonic()
            res = next(iter(model.predict(str(img), batch_size=1, threshold=threshold)))
            boxes = []
            for b in res["boxes"]:
                x0, y0, x1, y1 = (float(v) for v in b["coordinate"])
                if b["label"] not in PADDLE_MAP:
                    unknown[b["label"]] += 1
                boxes.append({"label": b["label"], "cls": PADDLE_MAP.get(b["label"]), "score": round(float(b["score"]), 4), "box": [int(x0), int(y0), int(x1 + 0.999), int(y1 + 0.999)]})
            f.write(json.dumps({"paper": row["paper"], "page": row["page"], "seconds": round(time.monotonic() - t1, 3), "boxes": boxes}) + "\n")
            f.flush()
            n += 1
            if n % 25 == 0:
                print(f"{n} pages, {(time.monotonic() - t0) / n:.2f} s/page", flush=True)
    if unknown:
        print(f"labels without a mapping (dropped): {dict(unknown)}", flush=True)
    return pred_file, time.monotonic() - t0


def run_rtdetr(model_dir: Path, bench: Path, out: Path, device: str = "cuda", limit: int = 0, size: int | None = None, threshold: float | None = None) -> tuple[Path, float]:
    """Run a fine-tuned RT-DETR (`gs train layout`) over the bench pages."""
    import torch
    from transformers import RTDetrImageProcessor, RTDetrV2ForObjectDetection

    from science_reader_pdf.models.train_layout import THRESHOLDS, apply_thresholds, predict

    rows = load_bench(bench)
    if limit:
        rows = rows[:limit]
    out.mkdir(parents=True, exist_ok=True)
    pred_file = predictions_file(out, bench)
    dev = torch.device(device if torch.cuda.is_available() or device == "cpu" else "cpu")
    model = RTDetrV2ForObjectDetection.from_pretrained(str(model_dir)).to(dev)
    processor = RTDetrImageProcessor.from_pretrained(str(model_dir))
    run_info = json.loads((model_dir / "train-run.json").read_text()) if (model_dir / "train-run.json").is_file() else {}
    size = size or int(run_info.get("size", 1024))
    # the dev-selected thresholds (per class, or one float for older checkpoints) travel with the checkpoint
    thresholds: dict[str, float] | float = threshold if threshold is not None else run_info.get("thresholds") or float(run_info.get("threshold", 0.3))
    images = [{"id": i, "file_name": r["path"], "paper": r["paper"], "page": r["page"]} for i, r in enumerate(rows)]
    t0 = time.monotonic()
    preds = apply_thresholds(predict(model, processor, bench.parent, images, size, dev, threshold=min(THRESHOLDS)), thresholds)
    with pred_file.open("w") as f:
        for r in rows:
            f.write(json.dumps({"paper": r["paper"], "page": r["page"], "boxes": preds.get((r["paper"], r["page"]), [])}) + "\n")
    return pred_file, time.monotonic() - t0


def run_fcos(model_dir: Path, bench: Path, out: Path, device: str = "cuda", limit: int = 0) -> tuple[Path, float]:
    """Run a fine-tuned FCOS (`gs train layout --arch fcos`) over the bench pages."""
    import torch

    from science_reader_pdf.models.train_layout import apply_thresholds
    from science_reader_pdf.models.train_layout_fcos import load_checkpoint, predict

    rows = load_bench(bench)
    if limit:
        rows = rows[:limit]
    out.mkdir(parents=True, exist_ok=True)
    pred_file = predictions_file(out, bench)
    dev = torch.device(device if torch.cuda.is_available() or device == "cpu" else "cpu")
    model, info = load_checkpoint(model_dir, dev)
    images = [{"id": i, "file_name": r["path"], "paper": r["paper"], "page": r["page"]} for i, r in enumerate(rows)]
    t0 = time.monotonic()
    preds = apply_thresholds(predict(model, bench.parent, images, dev), info.get("thresholds") or 0.3)
    with pred_file.open("w") as f:
        for r in rows:
            f.write(json.dumps({"paper": r["paper"], "page": r["page"], "boxes": preds.get((r["paper"], r["page"]), [])}) + "\n")
    return pred_file, time.monotonic() - t0


def record(model: str, bench: Path, predictions: Path, summary: dict[str, object], seconds: float | None) -> Path:
    RUNS.mkdir(parents=True, exist_ok=True)
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO_ROOT, capture_output=True, text=True, check=False).stdout.strip()
    row = {"time_utc": datetime.now(UTC).isoformat(), "task": "layout", "model": model, "bench": str(bench.relative_to(DATA)), "predictions": str(predictions.relative_to(DATA)), "commit": commit, "seconds": seconds, "summary": summary}
    with (RUNS / "metrics.jsonl").open("a") as f:
        f.write(json.dumps(row) + "\n")
    return RUNS / "metrics.jsonl"


def overlay(bench: Path, paper: str, page: int, predictions: Path | None, out: Path) -> None:
    """Draw gold regions (green, class label), don't-care boxes (grey) and predictions (red)."""
    from PIL import Image, ImageDraw

    row = next(r for r in load_bench(bench) if r["paper"] == paper and r["page"] == page)
    img = Image.open(bench.parent / row["path"]).convert("RGB")
    d = ImageDraw.Draw(img)
    for b in row["ignore"]:
        d.rectangle(b, outline=(160, 160, 160), width=2)
    for r in row["regions"]:
        d.rectangle(r["box"], outline=(0, 160, 0), width=3)
        d.text((r["box"][0] + 3, r["box"][1] + 2), r["cls"], fill=(0, 120, 0))
    if predictions is not None:
        for p in load_predictions(predictions).get((paper, page), []):
            if not p.get("cls"):
                continue
            d.rectangle(p["box"], outline=(220, 0, 0), width=2)
            d.text((p["box"][2] - 60, p["box"][3] - 14), f"{p['label']} {p['score']:.2f}", fill=(200, 0, 0))
    img.save(out)
