"""TexTeller (ViT encoder + TrOCR decoder) through transformers, with the package's own
preprocessing reimplemented: trim the background border, grayscale, resize so the image fits
448 px (shorter side 447 unless the longer side would exceed 448), normalise with the
training mean/std, pad bottom/right to 448x448 after normalisation (fill 0 = mean grey).
"""

from __future__ import annotations

import json
import time
from collections import Counter
from pathlib import Path

from science_reader_pdf.paths import DATA, MODELS, RUNS

IMAGE_MEAN = 0.9545467
IMAGE_STD = 0.15394445
SIZE = 448
MAX_TOKENS = 1024


def _trim_white_border(image):  # type: ignore[no-untyped-def]
    import cv2
    import numpy as np

    corners = [tuple(image[0, 0]), tuple(image[0, -1]), tuple(image[-1, 0]), tuple(image[-1, -1])]
    bg = np.array(Counter(corners).most_common(1)[0][0], dtype=np.uint8)
    diff = cv2.absdiff(image, np.full_like(image, bg))
    mask = cv2.cvtColor(diff, cv2.COLOR_BGR2GRAY)
    _, binary = cv2.threshold(mask, 15, 255, cv2.THRESH_BINARY)
    x, y, w, h = cv2.boundingRect(binary)
    return image[y : y + h, x : x + w] if w and h else image


def preprocess(path: Path):  # type: ignore[no-untyped-def]
    import cv2

    return preprocess_image(cv2.cvtColor(cv2.imread(str(path), cv2.IMREAD_COLOR), cv2.COLOR_BGR2RGB))


def preprocess_image(image):  # type: ignore[no-untyped-def]
    """RGB uint8 array -> [1, 448, 448] normalised tensor (training and inference share this)."""
    import torch
    from torchvision.transforms import v2

    image = _trim_white_border(image)
    pipeline = v2.Compose([
        v2.ToImage(), v2.ToDtype(torch.uint8, scale=True), v2.Grayscale(),
        v2.Resize(size=SIZE - 1, interpolation=v2.InterpolationMode.BICUBIC, max_size=SIZE, antialias=True),
        v2.ToDtype(torch.float32, scale=True), v2.Normalize(mean=[IMAGE_MEAN], std=[IMAGE_STD]),
    ])
    t = pipeline(image)
    return v2.functional.pad(t, padding=[0, 0, SIZE - t.shape[2], SIZE - t.shape[1]])


def run(bench: Path, device: str = "cuda", limit: int = 0, model_dir: Path | None = None, name: str = "texteller", resume: bool = False, beams: int = 1) -> Path:
    import torch
    from transformers import GenerationConfig, RobertaTokenizerFast, VisionEncoderDecoderModel

    from science_reader_pdf.models import pending_rows, resume_state

    model_dir = model_dir or MODELS / "texteller"
    dev = torch.device(device if torch.cuda.is_available() or device == "cpu" else "cpu")
    model = VisionEncoderDecoderModel.from_pretrained(str(model_dir)).to(dev).eval()
    tokenizer = RobertaTokenizerFast.from_pretrained(str(model_dir))
    gen = GenerationConfig(max_new_tokens=MAX_TOKENS, num_beams=beams, do_sample=False, pad_token_id=tokenizer.pad_token_id, eos_token_id=tokenizer.eos_token_id, bos_token_id=tokenizer.bos_token_id)
    out_dir = RUNS / "eval" / name
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{bench.stem}.predictions.jsonl"
    rows = [json.loads(line) for line in bench.read_text().splitlines()]
    if limit:
        rows = rows[:limit]
    done = resume_state(out, resume)
    rows = pending_rows(rows, done)
    root = DATA / "datasets" / bench.parent.name
    t0 = time.monotonic()
    with out.open("a" if done else "w") as f:
        for r in rows:
            t = time.monotonic()
            try:
                pixels = preprocess(root / r["path"]).unsqueeze(0).to(dev)
                with torch.no_grad():
                    ids = model.generate(pixels, generation_config=gen)
                tex, err = tokenizer.batch_decode(ids, skip_special_tokens=True)[0].strip(), ""
            except Exception as exc:
                tex, err = "", f"{type(exc).__name__}: {exc}"[:200]
            f.write(json.dumps({"id": r["id"], "paper": r["paper"], "tex": tex, "seconds": round(time.monotonic() - t, 3), "error": err}, ensure_ascii=False) + "\n")
            f.flush()
    (out_dir / f"{bench.stem}.run.json").write_text(json.dumps({"model": "TexTeller", "model_dir": str(model_dir), "device": str(dev), "beams": beams, "n": len(rows), "resumed_from": len(done), "seconds": round(time.monotonic() - t0, 1)}, indent=1))
    return out


class Recogniser:
    """TexTeller loaded once for the device route. `predict(image)` returns the LaTeX and the
    gate's statistic: the minimum token probability of the greedy decode
    (experiments/2026-10-13-confidence-gate-v0)."""

    def __init__(self, model_dir: Path | None = None, device: str = "cuda", max_new_tokens: int = MAX_TOKENS) -> None:
        import torch
        from transformers import GenerationConfig, RobertaTokenizerFast, VisionEncoderDecoderModel

        self.model_dir = model_dir or MODELS / "texteller-ft-v4"
        self.device = torch.device(device if torch.cuda.is_available() or device == "cpu" else "cpu")
        self.model = VisionEncoderDecoderModel.from_pretrained(str(self.model_dir)).to(self.device).eval()
        self.tokenizer = RobertaTokenizerFast.from_pretrained(str(self.model_dir))
        self.max_new_tokens = max_new_tokens
        self.gen = GenerationConfig(max_new_tokens=max_new_tokens, num_beams=1, do_sample=False, pad_token_id=self.tokenizer.pad_token_id, eos_token_id=self.tokenizer.eos_token_id, bos_token_id=self.tokenizer.bos_token_id)

    def predict(self, image) -> tuple[str, float]:  # type: ignore[no-untyped-def]
        """RGB uint8 array of the crop -> (LaTeX, minimum token probability)."""
        return self.predict_many([image])[0]

    def predict_many(self, images, batch_size: int = 16, keep_probs: list[list[float]] | None = None, truncated: list[bool] | None = None) -> list[tuple[str, float]]:  # type: ignore[no-untyped-def]
        """Crops in batches (every crop is padded to 448 x 448, so a batch costs one forward per
        token for all of them); each sequence's confidence stops at its own end token. With
        `keep_probs` a list, every sequence's token probabilities are appended to it; with
        `truncated` a list, whether the sequence stopped at the token limit without an end token."""
        import torch

        out: list[tuple[str, float]] = []
        for start in range(0, len(images), batch_size):
            chunk = images[start : start + batch_size]
            try:
                out.extend(self._batch(chunk, keep_probs, truncated))
            except torch.cuda.OutOfMemoryError:  # a runaway decode in a batch: one crop at a time, the bad one gives nothing
                torch.cuda.empty_cache()
                for im in chunk:
                    try:
                        out.extend(self._batch([im], keep_probs, truncated))
                    except torch.cuda.OutOfMemoryError:
                        torch.cuda.empty_cache()
                        out.append(("", 0.0))
                        if keep_probs is not None:
                            keep_probs.append([])
                        if truncated is not None:
                            truncated.append(True)
        return out

    def _batch(self, chunk, keep_probs: list[list[float]] | None, truncated: list[bool] | None = None) -> list[tuple[str, float]]:  # type: ignore[no-untyped-def]
        import torch

        eos, pad = self.tokenizer.eos_token_id, self.tokenizer.pad_token_id
        pixels = torch.stack([preprocess_image(im) for im in chunk]).to(self.device)
        with torch.no_grad():
            g = self.model.generate(pixels, generation_config=self.gen, output_scores=True, return_dict_in_generate=True)
            steps = len(g.scores)
            ids = g.sequences[:, 1 : steps + 1]  # the generated tokens, one per score step
            # one step's log-softmax at a time: a 1,024-token decode otherwise holds [B, T, vocab] floats
            tok_p = torch.stack([torch.log_softmax(s.float(), -1).gather(1, ids[:, t : t + 1]).squeeze(1) for t, s in enumerate(g.scores)], dim=1).exp() if steps else torch.zeros(len(chunk), 0, device=self.device)
        out: list[tuple[str, float]] = []
        for b in range(len(chunk)):
            row = ids[b].tolist()
            n = next((i + 1 for i, t in enumerate(row) if t == eos), len(row))
            live = [t for t in row[:n] if t != pad]
            conf = float(tok_p[b, :n].min()) if n else 0.0
            if keep_probs is not None:
                keep_probs.append([round(float(v), 5) for v in tok_p[b, :n].tolist()])
            if truncated is not None:
                truncated.append(eos not in row[:n])
            out.append((self.tokenizer.decode(live, skip_special_tokens=True).strip(), conf))
        return out
