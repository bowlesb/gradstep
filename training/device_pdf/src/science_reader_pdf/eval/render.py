"""Render LaTeX strings to ink images in the TeX sandbox and compare prediction against reference.

Every string, reference or prediction, is typeset the same way (article + amsmath + preview
tightpage), so a match means the two strings produce the same marks, whatever their spelling.
Each item is its own tiny document so one invalid prediction cannot spoil the batch; a single
container runs pdflatex over all of them.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import uuid
from pathlib import Path

import numpy as np
import pypdfium2 as pdfium

from science_reader_pdf.data.sandbox import docker_cmd
from science_reader_pdf.eval.equations import strip_delimiters
from science_reader_pdf.paths import RUNS

PREAMBLE = r"""\documentclass{article}
\usepackage{amsmath,amssymb,amsfonts,amsthm,bm,mathtools,mathrsfs,textcomp,upgreek,stmaryrd,dsfont,bbm,xcolor,braket,cancel,esint,nicefrac}
\usepackage[active,tightpage]{preview}
\setlength\PreviewBorder{2pt}
\pagestyle{empty}
\begin{document}
"""
_ROWSEP = re.compile(r"\\\\")


_ALIGN_ENVS = re.compile(r"\\begin\{(?:split|aligned|alignedat|cases|dcases|array|matrix|pmatrix|bmatrix|Bmatrix|vmatrix|Vmatrix|smallmatrix|gathered|multlined|subarray|tabular)")


def wrap(tex: str, display: bool) -> str:
    """Display items go in equation* (split, tag and friends need a display environment);
    rows with & or \\\\ and no alignment environment of their own are wrapped in aligned."""
    t = strip_delimiters(tex)
    if ("&" in t or _ROWSEP.search(t)) and not _ALIGN_ENVS.match(t.lstrip()):  # an inner subarray or cases does not align the rows
        t = "\\begin{aligned}" + t + "\\end{aligned}"
    if display:
        return "\\begin{preview}\\begin{equation*}" + t + "\\end{equation*}\\end{preview}"
    return "\\begin{preview}\\(" + t + "\\)\\end{preview}"


def _key(tex: str, display: bool) -> str:
    return hashlib.sha256(f"{int(display)}:{strip_delimiters(tex)}".encode()).hexdigest()[:20]


def render_many(items: dict[str, tuple[str, bool]], cache: Path, timeout: int = 10800) -> dict[str, Path | None]:
    """items: key -> (tex, display). Returns key -> rendered PDF path (None if it failed).
    Rendered PDFs are cached by content hash so repeated scoring never recompiles."""
    cache = cache.resolve()  # Docker treats a relative mount source as a named volume
    cache.mkdir(parents=True, exist_ok=True)
    # One scratch directory per call: two scorers may render at the same time (two benches,
    # two models), and a shared directory let one wipe the other's batch mid-run.
    work = cache / f"work-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    (work / "items").mkdir(parents=True)
    (work / "out").mkdir()
    pending: dict[str, list[str]] = {}  # hash -> every key with that content
    result: dict[str, Path | None] = {}
    for key, (tex, display) in items.items():
        h = _key(tex, display)
        pdf = cache / f"{h}.pdf"
        fail = cache / f"{h}.fail"
        if pdf.is_file():
            result[key] = pdf
        elif fail.is_file():
            result[key] = None
        else:
            if h not in pending:
                (work / "items" / f"{h}.tex").write_text(PREAMBLE + wrap(tex, display) + "\n\\end{document}\n")
            pending.setdefault(h, []).append(key)
    if pending:
        script = work / "run.sh"
        script.write_text("#!/bin/sh\ncd /paper\nls items/*.tex | xargs -P 4 -I{} sh -c 'timeout 20 pdflatex -interaction=batchmode -halt-on-error -output-directory out {} >/dev/null 2>&1 || true'\n")
        script.chmod(0o755)
        with (cache / "last-run.log").open("w") as log_out:
            proc = subprocess.run(docker_cmd(work, ["sh", "run.sh"], timeout, memory="4g", cpus="4"), stdout=log_out, stderr=subprocess.STDOUT, check=False)
            log_out.write(f"\nexit {proc.returncode}; items {len(pending)}\n")
        for h, keys in pending.items():
            out = work / "out" / f"{h}.pdf"
            if out.is_file() and out.stat().st_size > 0:
                shutil.move(out, cache / f"{h}.pdf")
                for key in keys:
                    result[key] = cache / f"{h}.pdf"
            else:
                log = work / "out" / f"{h}.log"
                if log.is_file():  # a real TeX failure is cached; a missing log means the
                    (cache / f"{h}.fail").write_text(_first_error(log))  # batch never ran it
                for key in keys:
                    result[key] = None
    shutil.rmtree(work, ignore_errors=True)
    return result


def _first_error(log: Path) -> str:
    text = log.read_text(errors="replace")
    for line in text.splitlines():
        if line.startswith("! "):
            return line[:200]
    return text[-300:]


def ink(pdf: Path, dpi: int = 200) -> np.ndarray | None:
    """Grayscale ink array (0 = paper, 1 = ink) trimmed to its bounding box."""
    try:
        doc = pdfium.PdfDocument(str(pdf))
        page = doc[0]
        img = page.render(scale=dpi / 72, draw_annots=False).to_pil().convert("L")
        doc.close()
    except Exception:
        return None
    a = 1.0 - np.asarray(img, dtype=np.float32) / 255.0
    rows = np.where(a.max(axis=1) > 0.2)[0]
    cols = np.where(a.max(axis=0) > 0.2)[0]
    if len(rows) == 0 or len(cols) == 0:
        return None
    return a[rows[0] : rows[-1] + 1, cols[0] : cols[-1] + 1]


def similarity(a: np.ndarray, b: np.ndarray, height: int = 48) -> float:
    """Ink IoU after scaling both to a common height and width. 1.0 means identical marks."""
    from PIL import Image

    def resample(x: np.ndarray, size: tuple[int, int]) -> np.ndarray:
        im = Image.fromarray((x * 255).astype(np.uint8))
        return np.asarray(im.resize(size, Image.BILINEAR), dtype=np.float32) / 255.0

    ha, wa = a.shape
    hb, wb = b.shape
    aspect_a, aspect_b = wa / ha, wb / hb
    if max(aspect_a, aspect_b) / max(1e-6, min(aspect_a, aspect_b)) > 1.5:
        return 0.0
    width = max(8, int(round(height * (aspect_a + aspect_b) / 2)))
    ra, rb = resample(a, (width, height)), resample(b, (width, height))
    ia, ib = ra > 0.35, rb > 0.35
    union = np.logical_or(ia, ib).sum()
    return float(np.logical_and(ia, ib).sum() / union) if union else 0.0


def render_scores(pairs: dict[str, tuple[str, str, bool]], cache: Path | None = None) -> dict[str, dict[str, object]]:
    """pairs: key -> (reference tex, prediction tex, display). Returns per key:
    {ref_ok, pred_ok, sim} where sim is None when either side failed to render."""
    cache = cache or RUNS / "render-cache"
    items: dict[str, tuple[str, bool]] = {}
    for key, (ref, pred, display) in pairs.items():
        items[f"r:{key}"] = (ref, display)
        if pred.strip():
            items[f"p:{key}"] = (pred, display)
    rendered = render_many(items, cache)
    out: dict[str, dict[str, object]] = {}
    for key, (ref, pred, display) in pairs.items():
        rp, pp = rendered.get(f"r:{key}"), rendered.get(f"p:{key}")
        ra = ink(rp) if rp else None
        pa = ink(pp) if pp else None
        sim = structural_similarity(ra, pa) if ra is not None and pa is not None else None
        pix = similarity(ra, pa) if ra is not None and pa is not None else None
        out[key] = {"ref_ok": ra is not None, "pred_ok": pa is not None, "sim": None if sim is None else round(sim, 4), "pixel_iou": None if pix is None else round(pix, 4)}
    return out


def save_report(path: Path, scores: dict[str, dict[str, object]]) -> None:
    path.write_text(json.dumps(scores))


# ------------------------------------------------- structural (blob) comparison

def blobs(a: np.ndarray, min_pixels: int = 4) -> list[dict[str, object]]:
    """Connected ink components, left to right, each with a normalised 16x16 template, its
    height relative to the whole render and its vertical centre."""
    from PIL import Image
    from scipy import ndimage

    binary = a > 0.35
    labels, n = ndimage.label(binary, structure=np.ones((3, 3)))
    H = max(1, a.shape[0])
    out: list[dict[str, object]] = []
    for i, sl in enumerate(ndimage.find_objects(labels), start=1):
        if sl is None:
            continue
        mask = labels[sl] == i
        if mask.sum() < min_pixels:
            continue
        y0, y1, x0, x1 = sl[0].start, sl[0].stop, sl[1].start, sl[1].stop
        tpl = np.asarray(Image.fromarray((mask * 255).astype(np.uint8)).resize((16, 16), Image.BILINEAR), dtype=np.float32) > 100
        out.append({"x": (x0 + x1) / 2, "y": (y0 + y1) / 2 / H, "h": (y1 - y0) / H, "w": (x1 - x0) / H, "tpl": tpl})
    out.sort(key=lambda b: b["x"])  # type: ignore[arg-type, return-value]
    return out


def _blob_match(p: dict[str, object], q: dict[str, object]) -> bool:
    hp, hq = float(p["h"]), float(q["h"])  # type: ignore[arg-type]
    if max(hp, hq) / max(1e-6, min(hp, hq)) > 1.5 or abs(float(p["y"]) - float(q["y"])) > 0.25:  # type: ignore[arg-type]
        return False
    a, b = p["tpl"], q["tpl"]
    union = np.logical_or(a, b).sum()  # type: ignore[arg-type]
    return bool(union) and float(np.logical_and(a, b).sum() / union) >= 0.7  # type: ignore[arg-type]


def structural_similarity(a: np.ndarray, b: np.ndarray) -> float:
    """Fraction of glyph blobs matched by an order-preserving alignment (Needleman-Wunsch
    with unit gap cost), over the larger blob count. Spacing changes cost nothing; each wrong,
    missing or extra glyph costs one."""
    A, B = blobs(a), blobs(b)
    n, m = len(A), len(B)
    if n == 0 or m == 0:
        return 0.0
    score = np.zeros((n + 1, m + 1), dtype=np.int32)
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            match = score[i - 1, j - 1] + (1 if _blob_match(A[i - 1], B[j - 1]) else 0)
            score[i, j] = max(match, score[i - 1, j], score[i, j - 1])
    return float(score[n, m] / max(n, m))
