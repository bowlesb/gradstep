"""Does the device's renderer cost the formula recogniser accuracy? (docs/reviews/DEVICE_PDF_ROUTE_20261021.md)

The desktop's equation bench (factory-v3/bench-v3.jsonl: gold boxes and TeX) cut twice: from the bench's own pdfium pages
(the crops the recogniser was evaluated on) and from the Mac's CoreGraphics renders of the same pages
(data/runs/render-cg-png, made with the app's drawing code, font smoothing off), with the factory's own crop function.
TexTeller (texteller-ft-v4) reads both greedily, as the device does (255 new tokens); scored with the desktop's
normalisation, on the held-out families only (dev and test splits; the recogniser trained on the train split).

Runs on the desktop with the mathpix project's environment, read-only (it writes only under --out):
    CUDA_VISIBLE_DEVICES=0 PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/home/ben/mathpix/src \
      /home/ben/mathpix/.venv/bin/python -B -s cg_equation_bench.py --out /home/ben/science-reader-device-pdf/runs/cg-bench
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
import torch
from PIL import Image

from gradstep.data.export import PAD_DISPLAY, PAD_INLINE, _crop
from gradstep.eval.equations import normalize
from gradstep.models.texteller import preprocess_image

DATA = Path("/home/ben/mathpix/data")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--model", default=str(DATA / "models/texteller-ft-v4"))
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--splits", default="dev,test")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    from transformers import GenerationConfig, RobertaTokenizerFast, VisionEncoderDecoderModel

    rows = [json.loads(l) for l in (DATA / "datasets/factory-v3/bench-v3.jsonl").read_text().splitlines()]
    rows = [r for r in rows if r["split"] in a.splits.split(",")]
    cg_dir = DATA / "runs/render-cg-png/png"
    ref_root = DATA / "datasets/factory-v3"
    pages: dict[tuple[str, int], Image.Image] = {}

    def cg_page(paper: str, page: int, size: tuple[int, int]) -> Image.Image | None:
        key = (paper, page)
        if key not in pages:
            p = cg_dir / f"{paper}-p{page:04d}.png"
            if not p.exists():
                pages[key] = None  # type: ignore[assignment]
            else:
                im = Image.open(p).convert("RGB")
                pages[key] = im.resize(size, Image.LANCZOS) if im.size != size else im
        return pages[key]

    items = []
    for r in rows:
        ref_page = Image.open(ref_root / "pages" / r["paper"] / f"p{int(r['page']):04d}.png")
        pad = PAD_DISPLAY if r["placement"] == "display" else PAD_INLINE
        ref = _crop(ref_page.convert("RGB"), list(r["box"]), pad)
        cg = cg_page(r["paper"], int(r["page"]), ref_page.size)
        cgc = _crop(cg, list(r["box"]), pad) if cg is not None else None
        if ref is None or cgc is None:
            continue
        items.append((r, ref, cgc))
    print(f"{len(items)} crops ({sum(1 for i in items if i[0]['placement'] == 'display')} display) on held-out families", flush=True)

    model = VisionEncoderDecoderModel.from_pretrained(a.model).to("cuda").eval().half()
    tok = RobertaTokenizerFast.from_pretrained(a.model)
    gen = GenerationConfig(max_new_tokens=255, num_beams=1, do_sample=False, pad_token_id=tok.pad_token_id, eos_token_id=tok.eos_token_id,
                           bos_token_id=tok.bos_token_id, decoder_start_token_id=tok.bos_token_id)

    @torch.no_grad()
    def read(images: list[Image.Image]) -> list[str]:
        out: list[str] = []
        for i in range(0, len(images), a.batch):
            px = torch.stack([preprocess_image(np.array(im)) for im in images[i : i + a.batch]]).to("cuda").half()
            ids = model.generate(px, generation_config=gen)
            out += [tok.decode(x, skip_special_tokens=True, clean_up_tokenization_spaces=True).strip() for x in ids]
        return out

    t = time.time()
    ref_pred = read([i[1] for i in items])
    cg_pred = read([i[2] for i in items])
    res: dict[str, dict[str, float]] = {}
    lines = []
    for (r, _, _), p, q in zip(items, ref_pred, cg_pred):
        g = normalize(r["tex"])
        k = r["placement"]
        s = res.setdefault(k, {"n": 0, "pdfium": 0, "cg": 0, "same_output": 0})
        s["n"] += 1; s["pdfium"] += normalize(p) == g; s["cg"] += normalize(q) == g; s["same_output"] += p == q
        lines.append(json.dumps({"paper": r["paper"], "id": r["id"], "placement": k, "gold": r["tex"], "pdfium": p, "cg": q}))
    for s in res.values():
        for k in ("pdfium", "cg", "same_output"):
            s[k] = round(s[k] / s["n"], 4)
    (a.out / "predictions.jsonl").write_text("\n".join(lines) + "\n")
    (a.out / "summary.json").write_text(json.dumps({"model": a.model, "splits": a.splits, "seconds": round(time.time() - t), "result": res}, indent=1))
    print(json.dumps(res, indent=1), flush=True)


if __name__ == "__main__":
    main()
