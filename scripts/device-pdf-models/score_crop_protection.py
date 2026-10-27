"""Native cleaner-only protection on source-pinned, previously used factory controls.

Requires numpy, Pillow, scipy and PyMuPDF. No inference, downloads or PDF writes.
The manifest's source-label box supplies the content hint; this is NOT a test of
the tagger, native glyph bounds, fresh held-out accuracy or formula completeness.
The old 150 dpi masks are not resized. Both PDFs are freshly rendered by the
device CoreGraphics path at 216 dpi, then scored in their original pixel frame.

Example (PDFs must already be copied and named PAPER/{plain,instr}.pdf):
  python3 scripts/device-pdf-models/score_crop_protection.py \
    --manifest /path/crops/protection.json --pdf-root /path/crops/protection/pdfs \
    --tool /path/DevicePDFRouteTool --out /path/crops/protection/evaluation

Use --score-only to recheck existing outputs without rendering. An oracle or
alignment failure fails the run; no sample is silently removed from its count.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import subprocess
from collections import Counter
from pathlib import Path

import fitz
import numpy as np
import PIL
import scipy
from PIL import Image
from scipy.ndimage import binary_dilation, label


SCALE = 3  # Native formula presentation: 216 dpi / 72 points per inch.
STRUCTURE = np.ones((3, 3), dtype=bool)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def geometry(page: fitz.Page) -> dict:
    return {"crop_box": list(page.cropbox), "media_box": list(page.mediabox),
            "display_rect": list(page.rect), "rotation": page.rotation}


def prepare(manifest: dict, pdf_root: Path, out: Path) -> tuple[list, list, list]:
    """Hash every PDF and check selected-page geometry before making jobs."""
    sources = {s["paper"]: s for s in manifest["sources"]}
    if len(sources) != len(manifest["sources"]):
        raise ValueError("duplicate source paper")
    documents = {}
    for paper, source in sources.items():
        documents[paper] = {}
        for kind in ("plain", "instr"):
            path = pdf_root / paper / (kind + ".pdf")
            if sha256(path) != source[kind + "_sha256"]:
                raise ValueError(f"source hash mismatch: {path}")
            documents[paper][kind] = fitz.open(path)
        if len(documents[paper]["plain"]) != len(documents[paper]["instr"]):
            raise ValueError(f"page count mismatch: {paper}")

    cleaner, renderer, cases = [], [], []
    seen = set()
    for sample in manifest["samples"]:
        paper, page = sample["paper"], sample["page"]
        key = paper + "-" + sample["id"]
        if key in seen:
            raise ValueError(f"duplicate sample: {key}")
        seen.add(key)
        checks = sample["label_checks"]
        required_checks = ("v3_same_id_text_page_box", "current_same_id_text_and_single_box",
                           "current_box_reproduces_150dpi_box")
        if sample["original_foreign_px"] != 0 or not all(checks.get(k) is True for k in required_checks):
            raise ValueError(f"not a stable clean protection control: {key}")
        for kind in ("plain", "instr"):
            if sample[kind + "_sha256"] != sources[paper][kind + "_sha256"]:
                raise ValueError(f"sample/source hash disagreement: {key}")
        plain_page, instr_page = (documents[paper][k][page] for k in ("plain", "instr"))
        geom = geometry(plain_page)
        if geom != geometry(instr_page) or geom["rotation"] != 0:
            raise ValueError(f"unaligned or rotated page geometry: {key}")
        x0, y0, x1, y1 = sample["source_box_points"]
        if not all(math.isfinite(v) for v in (x0, y0, x1, y1)) or x1 <= x0 or y1 <= y0:
            raise ValueError(f"invalid source box: {key}")
        rect = [math.floor((x0 - 2) * SCALE), math.floor((y0 - 2) * SCALE),
                math.ceil((x1 + 2) * SCALE), math.ceil((y1 + 2) * SCALE)]
        page_width = math.ceil(plain_page.rect.width * SCALE)
        page_height = math.ceil(plain_page.rect.height * SCALE)
        if rect[0] < 0 or rect[1] < 0 or rect[2] > page_width or rect[3] > page_height:
            raise ValueError(f"padded control crosses page edge: {key}")
        oracle_box = [v * SCALE for v in (x0, y0, x1, y1)]
        # Production protects the full crop width; only the unpadded vertical
        # band is ownership evidence. Keep the oracle's identity box separate.
        content = [rect[0], y0 * SCALE, rect[2], y1 * SCALE]
        destination = out / "cases" / key
        destination.mkdir(parents=True, exist_ok=True)
        plain = str(pdf_root / paper / "plain.pdf")
        cleaner.append({"id": key, "pdf": plain, "page": page, "rect": rect,
                        "content": content, "em": (y1 - y0) * SCALE,
                        "margin": 4, "out": str(destination)})
        # Pick a point strictly inside each boundary pixel. This preserves exact
        # integer bounds after render-crops' floor/ceil even for repeating /3 floats.
        render_rect = [(rect[0] + .25) / SCALE, (rect[1] + .25) / SCALE,
                       (rect[2] - .25) / SCALE, (rect[3] - .25) / SCALE]
        for kind in ("plain", "instr"):
            renderer.append({"pdf": str(pdf_root / paper / (kind + ".pdf")),
                             "page": page, "rect": render_rect, "dpi": 216,
                             "out": str(destination / (kind + "-source.png"))})
        cases.append({"id": key, "paper": paper, "formula_id": sample["id"], "page": page,
                      "split": sample["split"], "tex": sample["tex"], "geometry": geom,
                      "source_box_points": sample["source_box_points"], "rect": rect,
                      "content": content, "oracle_source_box_pixels": oracle_box,
                      "em_pixels_estimated_from_box_height": (y1 - y0) * SCALE})
    for pair in documents.values():
        for document in pair.values():
            document.close()
    if len(cases) != manifest["counts"]["samples"]:
        raise ValueError("manifest sample count mismatch")
    return cleaner, renderer, cases


def rgb(path: Path) -> np.ndarray:
    with Image.open(path) as image:
        return np.array(image.convert("RGB"))


def source_frame(image: np.ndarray, rect: list[int], shape: tuple[int, ...]) -> np.ndarray:
    """Undo trim/margin translation; pixels removed by the cleaner become white."""
    x0, y0, x1, y1 = rect
    if image.shape[:2] != (y1 - y0, x1 - x0):
        raise ValueError("image dimensions disagree with returned crop geometry")
    h, w = shape[:2]
    result = np.full(shape, 255, dtype=np.uint8)
    left, top, right, bottom = max(x0, 0), max(y0, 0), min(x1, w), min(y1, h)
    if left < right and top < bottom:
        result[top:bottom, left:right] = image[top - y0:bottom - y0, left - x0:right - x0]
    return result


def own_color_mask(instrumented: np.ndarray, content: list[float]) -> tuple[np.ndarray, np.ndarray]:
    """Historical red inline oracle, local component-center filter and 1px dilation.

    Instrumentation colors a class, not formula identities. Keep only components
    centered in the formula box +/-2 pixels, as the original mask maker did.
    This remains a conservative proxy, not independently reviewed pixel truth.
    """
    pixels = instrumented.astype(np.int16)
    red = (pixels[..., 0] - pixels[..., 1] > 40) & (pixels[..., 0] - pixels[..., 2] > 40)
    components, count = label(red, STRUCTURE)
    selected = np.zeros(red.shape, dtype=bool)
    x0, y0, x1, y1 = content
    for index in range(1, count + 1):
        ys, xs = np.nonzero(components == index)
        center_x, center_y = (xs.min() + xs.max() + 1) / 2, (ys.min() + ys.max() + 1) / 2
        if x0 - 2 <= center_x <= x1 + 2 and y0 - 2 <= center_y <= y1 + 2:
            selected[components == index] = True
    return selected, binary_dilation(selected, STRUCTURE, iterations=1)


def score_case(case: dict, out: Path) -> dict:
    folder = out / "cases" / case["id"]
    raw, plain, instr = (rgb(folder / name) for name in ("raw.png", "plain-source.png", "instr-source.png"))
    if raw.shape != plain.shape or raw.shape != instr.shape or not np.array_equal(raw, plain):
        raise ValueError("independent raw/source rendering is not exactly aligned")
    meta = json.loads((folder / "geometry.json").read_text())
    if meta["id"] != case["id"] or meta["rect"] != case["rect"]:
        raise ValueError("cleaner output belongs to a different job")
    before = source_frame(rgb(folder / "before.png"), meta["before"], raw.shape)
    after = source_frame(rgb(folder / "after.png"), meta["after"], raw.shape)
    rect, hint = case["rect"], case["oracle_source_box_pixels"]
    local_hint = [hint[0] - rect[0], hint[1] - rect[1], hint[2] - rect[0], hint[3] - rect[1]]
    red, oracle = own_color_mask(instr, local_hint)
    dark = raw.min(axis=2) < 90
    visible = raw.min(axis=2) < 245
    own = dark & oracle
    own_visible = visible & oracle
    alignment_hits = red & binary_dilation(visible, STRUCTURE, iterations=1)
    alignment = float(alignment_hits.sum() / max(1, red.sum()))
    # A geometry match alone cannot detect a shifted instrumented typesetting.
    # Fail questionable or empty oracles rather than counting a vacuous pass.
    # Registration uses visible ink, not the <90 core: real gray source text
    # and thin antialiased strokes can have no <90 pixel. Keep those controls
    # and additionally gate their visible ink, rather than dropping them.
    oracle_valid = bool(own_visible.any() and red.any() and alignment >= .95)
    before_dark, after_dark = before.min(axis=2) < 90, after.min(axis=2) < 90
    before_visible, after_visible = before.min(axis=2) < 245, after.min(axis=2) < 245
    missing_before, missing_after = own & ~before_dark, own & ~after_dark
    additional = own & before_dark & ~after_dark
    additional_visible = own_visible & before_visible & ~after_visible
    foreign = dark & ~oracle
    Image.fromarray(oracle.astype(np.uint8) * 255).save(folder / "own-mask.png")
    return {**case, "raw_source_pixels_identical": True, "oracle_valid": oracle_valid,
            "red_pixels": int(red.sum()), "red_to_plain_alignment_fraction": alignment,
            "own_dark_pixels": int(own.sum()), "own_missing_before": int(missing_before.sum()),
            "own_missing_after": int(missing_after.sum()), "additional_own_ink_loss": int(additional.sum()),
            "own_visible_pixels": int(own_visible.sum()),
            "own_visible_missing_before": int((own_visible & ~before_visible).sum()),
            "own_visible_missing_after": int((own_visible & ~after_visible).sum()),
            "additional_own_visible_ink_loss": int(additional_visible.sum()),
            "proxy_foreign_dark_before": int((foreign & before_dark).sum()),
            "proxy_foreign_dark_after": int((foreign & after_dark).sum()),
            "before_rect": meta["before"], "after_rect": meta["after"],
            "changed_pixels": int(np.any(before != after, axis=2).sum()),
            "passes": oracle_valid and not additional.any() and not additional_visible.any()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--pdf-root", required=True, type=Path)
    parser.add_argument("--tool", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--score-only", action="store_true")
    args = parser.parse_args()
    args.out, args.pdf_root, args.tool = args.out.resolve(), args.pdf_root.resolve(), args.tool.resolve()
    manifest = json.loads(args.manifest.read_text())
    if args.out.exists() and not args.score_only:
        parser.error("--out exists; choose a new output or use --score-only for saved renders")
    args.out.mkdir(parents=True, exist_ok=True)
    cleaner, renderer, cases = prepare(manifest, args.pdf_root, args.out)
    identity = {"manifest_sha256": sha256(args.manifest), "tool_sha256": sha256(args.tool),
                "script_sha256": sha256(Path(__file__))}
    if args.score_only:
        saved = json.loads((args.out / "preparation.json").read_text())
        if any(saved[k] != identity[k] for k in ("manifest_sha256", "tool_sha256")):
            raise ValueError("saved renders belong to a different manifest or native tool")
        if json.loads((args.out / "clean-jobs.json").read_text()) != cleaner:
            raise ValueError("saved cleaner jobs differ from current preparation")
        if json.loads((args.out / "render-jobs.json").read_text()) != renderer:
            raise ValueError("saved source jobs differ from current preparation")
    else:
        write_json(args.out / "clean-jobs.json", cleaner)
        write_json(args.out / "render-jobs.json", renderer)
        write_json(args.out / "preparation.json", {**identity, "cases": cases})
        for option, filename in (("--clean-formula-crops", "clean-jobs.json"), ("--render-crops", "render-jobs.json")):
            run = subprocess.run([str(args.tool), option, str(args.out / filename)],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            (args.out / (filename.removesuffix(".json") + ".log")).write_text(run.stdout)
            run.check_returncode()
    results = []
    for case in cases:
        try:
            results.append(score_case(case, args.out))
        except (OSError, ValueError, KeyError) as error:
            results.append({**case, "passes": False, "error": str(error)})
    report = {"schema": "science-reader-crop-protection-score-v1", **identity,
              "scope": "Cleaner-only, stable prior-used source-label controls; not tagger, native-glyph-boundary or fresh accuracy evaluation.",
              "method": {"dpi": 216, "padding_points": 2, "margin_pixels": 4,
                         "em": "source label box height in pixels, estimated rather than native font metadata",
                         "content_hint": "full padded crop width and unpadded source-label vertical bounds; matches the production band policy without testing native glyph extraction",
                         "oracle": "red class components centered in label box +/-2px, 8-connected, dilated 1px",
                         "dark_threshold": 90, "visible_threshold": 245,
                         "minimum_red_to_plain_alignment_fraction": .95,
                         "alignment": "red oracle pixels must overlap source visible ink dilated 1px; using <90 dark core here falsely rejects gray/antialiased text",
                         "gate": "every selected control has valid aligned oracle and exactly zero additional own dark AND visible ink loss vs legacy",
                         "limits": "Same-class neighboring math can share red color; masks cannot establish completeness beyond the supplied box. Prior label stability does not create new accuracy truth."},
              "environment": {"python": platform.python_version(), "numpy": np.__version__,
                              "Pillow": PIL.__version__, "scipy": scipy.__version__, "PyMuPDF": fitz.VersionBind},
              "counts": {"samples": len(cases), "papers": len({c['paper'] for c in cases}),
                         "pages": len({(c['paper'], c['page']) for c in cases}),
                         "splits": dict(Counter(c['split'] for c in cases)),
                         "passing_controls": sum(bool(r["passes"]) for r in results),
                         "invalid_or_errors": sum(not r.get("oracle_valid", False) for r in results),
                         "additional_own_ink_loss": sum(r.get("additional_own_ink_loss", 0) for r in results),
                         "additional_own_visible_ink_loss": sum(r.get("additional_own_visible_ink_loss", 0) for r in results),
                         "changed_controls": sum(r.get("changed_pixels", 0) > 0 for r in results)},
              "passes": bool(results) and all(r["passes"] for r in results), "cases": results}
    write_json(args.out / "results.json", report)
    print(json.dumps({"passes": report["passes"], **report["counts"]}, indent=2))
    raise SystemExit(0 if report["passes"] else 1)


if __name__ == "__main__":
    main()
