"""Fine-tune RT-DETR v2 (Apache-2.0, `PekingU/rtdetr_v2_r18vd`, 20M parameters) on factory pages
for the layout bench's classes.

    gs train layout --run layout-rtdetr-v1 --dataset factory-v3/layout-v1 --steps 8000

Reads the COCO export of `gs layout-export`; don't-care boxes (category `ignore`) are dropped
from the targets. Dev pages are scored with the layout bench's scorer every `eval_every` steps
and the best checkpoint by micro F1 is kept. Log: data/runs/train-<run>.log (JSON lines).
"""

from __future__ import annotations

import json
import math
import random
import time
from pathlib import Path

import torch
from PIL import Image, ImageDraw
from torch.utils.data import DataLoader, Dataset

from science_reader_pdf.eval.layout import CLASSES, score
from science_reader_pdf.paths import DATA, MODELS, RUNS

BASE = "PekingU/rtdetr_v2_r18vd"


def load_coco(path: Path) -> tuple[list[dict[str, object]], dict[int, list[dict[str, object]]], dict[int, str]]:
    d = json.loads(path.read_text())
    names = {c["id"]: c["name"] for c in d["categories"]}
    by_image: dict[int, list[dict[str, object]]] = {}
    for a in d["annotations"]:
        by_image.setdefault(int(a["image_id"]), []).append(a)
    return d["images"], by_image, names


def bench_rows(images: list[dict[str, object]], by_image: dict[int, list[dict[str, object]]], names: dict[int, str]) -> list[dict[str, object]]:
    """Dev pages in the layout bench's row format, so the same scorer applies."""
    rows = []
    for im in images:
        regions, ignore = [], []
        for a in by_image.get(int(im["id"]), []):
            x, y, w, h = a["bbox"]
            box = [int(x), int(y), int(x + w), int(y + h)]
            if names[int(a["category_id"])] == "ignore":
                ignore.append(box)
            else:
                regions.append({"cls": names[int(a["category_id"])], "box": box, "id": str(a.get("id", ""))})
        rows.append({"paper": im["paper"], "page": im["page"], "regions": regions, "ignore": ignore, "path": im["file_name"]})
    return rows


class PageSet(Dataset):
    def __init__(self, root: Path, images: list[dict[str, object]], by_image: dict[int, list[dict[str, object]]], names: dict[int, str], processor, size: int, train: bool, crop: bool = False) -> None:
        self.root, self.images, self.by_image, self.names, self.processor, self.size, self.train, self.crop = root, images, by_image, names, processor, size, train, crop
        # the crop jitter is off by default: a box losing half its area to the crop was dropped
        # while its visible part stayed in the image as background, another source of
        # paragraph-looking background

    def __len__(self) -> int:
        return len(self.images)

    def __getitem__(self, i: int):
        im = self.images[i]
        img = Image.open(self.root / str(im["file_name"])).convert("RGB")
        anns = []
        ignore = []
        for a in self.by_image.get(int(im["id"]), []):
            name = self.names[int(a["category_id"])]
            if name == "ignore":
                ignore.append(a["bbox"])
                continue
            anns.append({"bbox": a["bbox"], "category_id": CLASSES.index(name), "area": a["area"], "iscrowd": 0})
        if self.train and ignore:
            # don't-care text (running heads, page numbers, lines the labels do not cover) looks
            # exactly like paragraph text; left in the image as background it teaches the model
            # to doubt every paragraph (recall on text classes collapsed over training), so it
            # is painted out
            draw = ImageDraw.Draw(img)
            for x, y, w, h in ignore:
                draw.rectangle([x - 2, y - 2, x + w + 2, y + h + 2], fill=(255, 255, 255))
        if self.train and self.crop and random.random() < 0.5:  # mild scale jitter: crop a random 85-100% window
            w, h = img.size
            f = random.uniform(0.85, 1.0)
            cw, ch = int(w * f), int(h * f)
            ox, oy = random.randint(0, w - cw), random.randint(0, h - ch)
            img = img.crop((ox, oy, ox + cw, oy + ch))
            kept = []
            for a in anns:
                x, y, bw, bh = a["bbox"]
                x0, y0, x1, y1 = max(x - ox, 0), max(y - oy, 0), min(x + bw - ox, cw), min(y + bh - oy, ch)
                if x1 - x0 >= 0.5 * bw and y1 - y0 >= 0.5 * bh and x1 > x0 and y1 > y0:
                    kept.append({**a, "bbox": [x0, y0, x1 - x0, y1 - y0], "area": (x1 - x0) * (y1 - y0)})
            anns = kept
        enc = self.processor(images=img, annotations={"image_id": int(im["id"]), "annotations": anns}, return_tensors="pt", size={"height": self.size, "width": self.size})
        return {"pixel_values": enc["pixel_values"][0], "labels": enc["labels"][0], "orig_size": (img.height, img.width), "index": i}


def collate(batch):
    return {"pixel_values": torch.stack([b["pixel_values"] for b in batch]), "labels": [b["labels"] for b in batch], "orig_size": [b["orig_size"] for b in batch], "index": [b["index"] for b in batch]}


THRESHOLDS = (0.01, 0.02, 0.03, 0.05, 0.07, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9)  # up to 0.5 before v3: the thin matcher's scores run higher


def apply_thresholds(preds: dict[tuple[str, int], list[dict[str, object]]], thresholds: dict[str, float] | float) -> dict[tuple[str, int], list[dict[str, object]]]:
    """Keep predictions at or above their class's threshold (a float applies to every class).
    DETR scores are far from calibrated across classes: a table scores 0.9 where a paragraph
    scores 0.05, so one threshold cannot serve both."""
    if isinstance(thresholds, (int, float)):
        return {k: [p for p in v if p["score"] >= thresholds] for k, v in preds.items()}  # type: ignore[operator]
    return {k: [p for p in v if p["score"] >= thresholds.get(str(p["cls"]), 1.0)] for k, v in preds.items()}  # type: ignore[operator]


@torch.no_grad()
def predict(model, processor, root: Path, images: list[dict[str, object]], size: int, device: torch.device, batch_size: int = 8, threshold: float = 0.3) -> dict[tuple[str, int], list[dict[str, object]]]:
    """Predictions above `threshold`; DETR scores are compressed early in training, so the
    threshold is chosen on dev (`sweep`) and stored with the checkpoint."""
    model.eval()
    out: dict[tuple[str, int], list[dict[str, object]]] = {}
    for s in range(0, len(images), batch_size):
        chunk = images[s : s + batch_size]
        pil = [Image.open(root / str(im["file_name"])).convert("RGB") for im in chunk]
        enc = processor(images=pil, return_tensors="pt", size={"height": size, "width": size})
        with torch.autocast(device_type=device.type, dtype=torch.bfloat16, enabled=device.type == "cuda"):
            res = model(pixel_values=enc["pixel_values"].to(device))
        post = processor.post_process_object_detection(res, threshold=threshold, target_sizes=torch.tensor([[p.height, p.width] for p in pil]))
        for im, r in zip(chunk, post, strict=True):
            boxes = []
            for sc, lb, bx in zip(r["scores"].tolist(), r["labels"].tolist(), r["boxes"].tolist(), strict=True):
                name = CLASSES[lb]
                boxes.append({"label": name, "cls": name, "score": round(sc, 4), "box": [int(bx[0]), int(bx[1]), int(bx[2] + 0.999), int(bx[3] + 0.999)]})
            out[(im["paper"], im["page"])] = boxes
    model.train()
    return out


def sweep(model, processor, root: Path, images: list[dict[str, object]], rows: list[dict[str, object]], size: int, device: torch.device) -> tuple[float, dict[str, float], dict[str, object]]:
    """Dev predictions at the lowest threshold once; then, per class, the threshold that
    maximises that class's F1 on dev; returns (micro F1 at those thresholds, thresholds, summary)."""
    low = predict(model, processor, root, images, size, device, threshold=min(THRESHOLDS))
    chosen: dict[str, float] = {}
    for cls in CLASSES:
        best_f1, best_th = -1.0, max(THRESHOLDS)
        for th in THRESHOLDS:
            preds = {k: [p for p in v if p["cls"] == cls and p["score"] >= th] for k, v in low.items()}  # type: ignore[operator]
            f1 = float(score(rows, preds).get(cls, {}).get("f1", 0.0))  # type: ignore[union-attr]
            if f1 > best_f1:
                best_f1, best_th = f1, th
        chosen[cls] = best_th
    summary = score(rows, apply_thresholds(low, chosen))
    return float(summary["all"]["f1"]), chosen, summary  # type: ignore[index]


def train(run: str, dataset: str, steps: int = 8000, batch_size: int = 8, lr: float = 1e-4, backbone_lr: float = 1e-5, size: int = 1024, eval_every: int = 1000, eval_pages: int = 300, workers: int = 6, base: str = BASE, seed: int = 0) -> Path:
    from transformers import RTDetrImageProcessor, RTDetrV2ForObjectDetection

    random.seed(seed)
    torch.manual_seed(seed)
    ds_root = DATA / "datasets" / dataset.split("/")[0]
    coco_dir = DATA / "datasets" / dataset
    out_dir = MODELS / run
    out_dir.mkdir(parents=True, exist_ok=True)
    RUNS.mkdir(parents=True, exist_ok=True)
    log = (RUNS / f"train-{run}.log").open("a")

    def emit(**kw: object) -> None:
        log.write(json.dumps({"time": round(time.time(), 1), **kw}) + "\n")
        log.flush()

    dev = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    processor = RTDetrImageProcessor.from_pretrained(base)
    model = RTDetrV2ForObjectDetection.from_pretrained(base, num_labels=len(CLASSES), id2label={i: c for i, c in enumerate(CLASSES)}, label2id={c: i for i, c in enumerate(CLASSES)}, ignore_mismatched_sizes=True).to(dev)
    tr_images, tr_by, names = load_coco(coco_dir / "train.json")
    dv_images, dv_by, _ = load_coco(coco_dir / "dev.json")
    dv_images = dv_images[:eval_pages]
    dv_rows = bench_rows(dv_images, dv_by, names)
    train_set = PageSet(ds_root, tr_images, tr_by, names, processor, size, train=True)
    loader = DataLoader(train_set, batch_size=batch_size, shuffle=True, num_workers=workers, collate_fn=collate, drop_last=True, persistent_workers=workers > 0)
    backbone = [p for n, p in model.named_parameters() if "backbone" in n]
    rest = [p for n, p in model.named_parameters() if "backbone" not in n]
    opt = torch.optim.AdamW([{"params": backbone, "lr": backbone_lr}, {"params": rest, "lr": lr}], weight_decay=1e-4)
    warm = max(1, min(500, steps // 10))
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1.0, (s + 1) / warm) * 0.5 * (1 + math.cos(math.pi * min(1.0, max(0, s - warm) / max(1, steps - warm)))))
    emit(event="start", run=run, base=base, dataset=dataset, steps=steps, batch_size=batch_size, lr=lr, backbone_lr=backbone_lr, size=size, train_pages=len(tr_images), dev_pages=len(dv_images), device=str(dev))
    best = -1.0
    step = 0
    t0 = time.monotonic()
    model.train()
    while step < steps:
        for batch in loader:
            labels = [{k: v.to(dev) for k, v in lab.items()} for lab in batch["labels"]]
            with torch.autocast(device_type=dev.type, dtype=torch.bfloat16, enabled=dev.type == "cuda"):
                res = model(pixel_values=batch["pixel_values"].to(dev), labels=labels)
            loss = res.loss
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 0.1)
            opt.step()
            sched.step()
            step += 1
            if step % 20 == 0:
                emit(event="step", step=step, loss=round(loss.item(), 4), lr=sched.get_last_lr()[1], s_per_step=round((time.monotonic() - t0) / step, 3), gpu_gb=round(torch.cuda.max_memory_allocated() / 2**30, 1) if dev.type == "cuda" else None)
            if step % eval_every == 0 or step == steps:
                t1 = time.monotonic()
                f1, th, summary = sweep(model, processor, ds_root, dv_images, dv_rows, size, dev)
                emit(event="eval", step=step, seconds=round(time.monotonic() - t1, 1), thresholds=th, all=summary["all"], agnostic=summary["agnostic"], classes={c: summary[c]["f1"] for c in CLASSES if c in summary})  # type: ignore[index]
                if f1 > best:
                    best = f1
                    model.save_pretrained(out_dir)
                    processor.save_pretrained(out_dir)
                    (out_dir / "train-run.json").write_text(json.dumps({"run": run, "base": base, "dataset": dataset, "step": step, "size": size, "thresholds": th, "dev_f1": f1, "classes": CLASSES}, indent=1))
                    emit(event="checkpoint", step=step, score=f1, thresholds=th, path=str(out_dir))
            if step >= steps:
                break
    emit(event="done", run=run, steps=step, best_dev_f1=best, minutes=round((time.monotonic() - t0) / 60, 1))
    log.close()
    return out_dir
