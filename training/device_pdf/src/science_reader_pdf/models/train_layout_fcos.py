"""Fine-tune torchvision's FCOS (ResNet-50 FPN, COCO weights, BSD/Apache) on factory pages for
the layout bench's classes: the dense, anchor-free alternative to RT-DETR, whose scores stayed
compressed and whose paragraph recall plateaued at 0.70 on the bench.

    gs train layout --arch fcos --run layout-fcos-v3 --dataset factory-v3/layout-v2 --steps 16000 --assign thin

`--assign torchvision` keeps torchvision's matcher (v1 and v2 were trained with it); `thin` is the
document matcher in `match_points`. Same COCO export, same dev scoring by the bench scorer with per-class thresholds, same log and
checkpoint conventions (`data/models/<run>/model.pt` + `train-run.json`).
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
from torchvision.models.detection import fcos_resnet50_fpn
from torchvision.models.detection.fcos import FCOS, FCOSClassificationHead
from torchvision.transforms.functional import to_tensor

from science_reader_pdf.eval.layout import CLASSES, score
from science_reader_pdf.models.train_layout import THRESHOLDS, apply_thresholds, bench_rows, load_coco
from science_reader_pdf.paths import DATA, MODELS, RUNS


def renderer_jitter(img: Image.Image, rng: random.Random) -> Image.Image:
    """Photometric jitter for pages rasterised by another renderer: the app draws pages with
    CoreGraphics (no font smoothing), training pages come from pdfium; the two differ in edge
    antialiasing and gamma, not in geometry. Gamma 0.7 to 1.4 (p 0.5), a down-and-up resample at
    0.6 to 0.95 (p 0.3), Gaussian blur 0.3 to 0.8 px (p 0.3), contrast 0.85 to 1.15 (p 0.2)."""
    import cv2
    import numpy as np

    a = np.asarray(img)
    if rng.random() < 0.5:
        g = rng.uniform(0.7, 1.4)
        a = (np.power(a.astype(np.float32) / 255.0, g) * 255.0).astype(np.uint8)
    if rng.random() < 0.3:
        h, w = a.shape[:2]
        f = rng.uniform(0.6, 0.95)
        a = cv2.resize(cv2.resize(a, (max(1, int(w * f)), max(1, int(h * f))), interpolation=cv2.INTER_AREA), (w, h), interpolation=cv2.INTER_LINEAR)
    if rng.random() < 0.3:
        a = cv2.GaussianBlur(a, (0, 0), rng.uniform(0.3, 0.8))
    if rng.random() < 0.2:
        c = rng.uniform(0.85, 1.15)
        a = np.clip((a.astype(np.float32) - 255.0) * c + 255.0, 0, 255).astype(np.uint8)  # contrast about white: the paper stays white
    return Image.fromarray(a)


class FcosPages(Dataset):
    def __init__(self, root: Path, images: list[dict[str, object]], by_image: dict[int, list[dict[str, object]]], names: dict[int, str], train: bool, augment: bool = False) -> None:
        self.root, self.images, self.by_image, self.names, self.train, self.augment = root, images, by_image, names, train, augment

    def __len__(self) -> int:
        return len(self.images)

    def __getitem__(self, i: int):
        im = self.images[i]
        img = Image.open(self.root / str(im["file_name"])).convert("RGB")
        boxes, labels, ignore = [], [], []
        for a in self.by_image.get(int(im["id"]), []):
            name = self.names[int(a["category_id"])]
            x, y, w, h = a["bbox"]
            if name == "ignore":
                ignore.append((x, y, w, h))
            elif w > 1 and h > 1:
                boxes.append([x, y, x + w, y + h])
                labels.append(CLASSES.index(name) + 1)  # 0 is background
        if self.train and ignore:
            draw = ImageDraw.Draw(img)
            for x, y, w, h in ignore:
                draw.rectangle([x - 2, y - 2, x + w + 2, y + h + 2], fill=(255, 255, 255))
        if self.train and self.augment:
            img = renderer_jitter(img, random.Random(random.getrandbits(32)))
        target = {"boxes": torch.tensor(boxes, dtype=torch.float32).reshape(-1, 4), "labels": torch.tensor(labels, dtype=torch.int64)}
        return to_tensor(img), target, im


def collate(batch):
    return [b[0] for b in batch], [b[1] for b in batch], [b[2] for b in batch]


ASSIGN = ("torchvision", "thin")


def match_points(anchors: torch.Tensor, gt_boxes: torch.Tensor, num_anchors_per_level: list[int], radius: float, assign: str = "thin") -> torch.Tensor:
    """Which ground-truth box (or -1) each feature point is responsible for; FCOS's matcher with
    one change for document regions.

    torchvision assigns a box to a pyramid level by its longest regression distance and takes the
    points within `radius` strides of the centre. A line of text is 20 px tall and 450 px wide,
    so it lands on stride 32 or 64 where at most one row of points, often none, falls inside it:
    on the arXiv bench the v2 model found 59% of regions under 30 px tall against 98% of those
    over 150 px. `thin` picks the level by the short side (a line goes to stride 8) and stretches
    the centre window along each side of the box (35% of the side, at least `radius` strides), so
    a line gets a row of positives instead of one point or none."""
    centers = (anchors[:, :2] + anchors[:, 2:]) / 2
    sizes = anchors[:, 2] - anchors[:, 0]
    gt_centers = (gt_boxes[:, :2] + gt_boxes[:, 2:]) / 2
    gt_wh = gt_boxes[:, 2:] - gt_boxes[:, :2]
    window = radius * sizes[:, None, None]
    if assign == "thin":
        window = torch.maximum(window, 0.35 * gt_wh[None, :, :])
    match = ((centers[:, None, :] - gt_centers[None, :, :]).abs() < window).all(dim=2)
    x, y = centers.unsqueeze(2).unbind(1)
    x0, y0, x1, y1 = gt_boxes.unsqueeze(0).unbind(2)
    dist = torch.stack([x - x0, y - y0, x1 - x, y1 - y], dim=2)
    match &= dist.min(dim=2).values > 0
    lower = sizes * 4
    lower[: num_anchors_per_level[0]] = 0
    upper = sizes * 8
    upper[-num_anchors_per_level[-1] :] = float("inf")
    extent = gt_wh.min(dim=1).values[None, :] if assign == "thin" else dist.max(dim=2).values
    match &= (extent > lower[:, None]) & (extent < upper[:, None])
    areas = gt_wh[:, 0] * gt_wh[:, 1]
    scored = match.to(torch.float32) * (1e8 - areas[None, :])  # several matches: the smallest box wins
    best, idx = scored.max(dim=1)
    idx[best < 1e-5] = -1
    return idx


class ThinFCOS(FCOS):
    """FCOS whose matcher is `match_points(..., assign="thin")`."""

    def compute_loss(self, targets, head_outputs, anchors, num_anchors_per_level):
        matched = []
        for anchors_per_image, t in zip(anchors, targets, strict=True):
            if t["boxes"].numel() == 0:
                matched.append(torch.full((anchors_per_image.size(0),), -1, dtype=torch.int64, device=anchors_per_image.device))
            else:
                matched.append(match_points(anchors_per_image, t["boxes"], num_anchors_per_level, self.center_sampling_radius, "thin"))
        return self.head.compute_loss(targets, head_outputs, anchors, matched)


def build_model(size: int, assign: str = "thin", pretrained: bool = True) -> torch.nn.Module:
    if assign not in ASSIGN:
        raise ValueError(f"assign must be one of {ASSIGN}, not {assign!r}")
    kw = {"min_size": size, "max_size": int(size * 1.4), "detections_per_img": 300, "score_thresh": 0.01}
    base = fcos_resnet50_fpn(weights="DEFAULT" if pretrained else None, weights_backbone=None if not pretrained else "DEFAULT", **kw)
    if assign == "thin":
        model = ThinFCOS(base.backbone, num_classes=91, **kw)
        model.load_state_dict(base.state_dict())
    else:
        model = base
    model.head.classification_head = FCOSClassificationHead(in_channels=256, num_anchors=1, num_classes=len(CLASSES) + 1)
    return model


@torch.no_grad()
def predict(model, root: Path, images: list[dict[str, object]], device: torch.device, batch_size: int = 4) -> dict[tuple[str, int], list[dict[str, object]]]:
    model.eval()
    out: dict[tuple[str, int], list[dict[str, object]]] = {}
    for s in range(0, len(images), batch_size):
        chunk = images[s : s + batch_size]
        tensors = [to_tensor(Image.open(root / str(im["file_name"])).convert("RGB")).to(device) for im in chunk]
        res = model(tensors)  # fp32: bf16 cannot place a box to the pixel at 1024 px (8-bit mantissa)
        for im, r in zip(chunk, res, strict=True):
            boxes = []
            for sc, lb, bx in zip(r["scores"].tolist(), r["labels"].tolist(), r["boxes"].tolist(), strict=True):
                if lb < 1 or lb > len(CLASSES):
                    continue
                name = CLASSES[lb - 1]
                boxes.append({"label": name, "cls": name, "score": round(sc, 4), "box": [int(bx[0]), int(bx[1]), int(bx[2] + 0.999), int(bx[3] + 0.999)]})
            out[(im["paper"], im["page"])] = boxes
    model.train()
    return out


def sweep(model, root: Path, images: list[dict[str, object]], rows: list[dict[str, object]], device: torch.device) -> tuple[float, dict[str, float], dict[str, object]]:
    low = predict(model, root, images, device)
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


def load_checkpoint(model_dir: Path, device: torch.device):
    info = json.loads((model_dir / "train-run.json").read_text())
    model = build_model(int(info.get("size", 1024)), assign=str(info.get("assign", "torchvision")), pretrained=False)
    model.load_state_dict(torch.load(model_dir / "model.pt", map_location="cpu"))
    return model.to(device).eval(), info


def resweep(model_dir: Path, dataset: str, eval_pages: int = 300) -> dict[str, object]:
    """Choose the per-class thresholds again on the dev pages for a saved checkpoint (the grid grew
    after v3 started) and write them to train-run.json; returns the dev summary."""
    dev = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model, info = load_checkpoint(model_dir, dev)
    ds_root = DATA / "datasets" / dataset.split("/")[0]
    dv_images, dv_by, names = load_coco(DATA / "datasets" / dataset / "dev.json")
    dv_images = dv_images[:eval_pages]
    f1, th, summary = sweep(model, ds_root, dv_images, bench_rows(dv_images, dv_by, names), dev)
    info.update({"thresholds": th, "dev_f1": f1, "resweep_pages": len(dv_images)})
    (model_dir / "train-run.json").write_text(json.dumps(info, indent=1))
    return {"dev_f1": f1, "thresholds": th, "classes": {c: summary[c]["f1"] for c in CLASSES if c in summary}}  # type: ignore[index]


def merge_sets(primary_root: Path, primary: tuple[list[dict[str, object]], dict[int, list[dict[str, object]]]], extras: list[tuple[Path, list[dict[str, object]], dict[int, list[dict[str, object]]]]]) -> tuple[list[dict[str, object]], dict[int, list[dict[str, object]]]]:
    """Pages of several COCO exports as one set: extra exports' pages get absolute file names (their
    own root) and fresh image ids after the primary set's, so one loader reads them all."""
    images = [dict(im) for im in primary[0]]
    by: dict[int, list[dict[str, object]]] = {k: list(v) for k, v in primary[1].items()}
    next_id = max((int(im["id"]) for im in images), default=0) + 1
    for root, ex_images, ex_by in extras:
        for im in ex_images:
            new = dict(im, id=next_id, file_name=str((root / str(im["file_name"])).resolve()))
            images.append(new)
            by[next_id] = [dict(a, image_id=next_id) for a in ex_by.get(int(im["id"]), [])]
            next_id += 1
    return images, by


def train(run: str, dataset: str, steps: int = 8000, batch_size: int = 6, lr: float = 0.004, size: int = 1024, eval_every: int = 1000, eval_pages: int = 300, workers: int = 6, assign: str = "thin", seed: int = 0, init: str = "", extra_datasets: tuple[str, ...] = (), extra_repeat: int = 1, augment: bool = False) -> Path:
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
    model = build_model(size, assign=assign, pretrained=not bool(init)).to(dev)
    if init:  # continue from a saved run (a fine-tune on more or different pages)
        model.load_state_dict(torch.load(MODELS / init / "model.pt", map_location="cpu"))
    tr_images, tr_by, names = load_coco(coco_dir / "train.json")
    dv_images, dv_by, _ = load_coco(coco_dir / "dev.json")
    dv_images = dv_images[:eval_pages]
    for extra in extra_datasets:  # e.g. pmc-v2/layout-full: publisher pages join the train set, and their dev pages the dev set
        ex_root, ex_dir = DATA / "datasets" / extra.split("/")[0], DATA / "datasets" / extra
        ex_tr, ex_tr_by, ex_names = load_coco(ex_dir / "train.json")
        assert ex_names == names, f"{extra}: class list differs"
        tr_images, tr_by = merge_sets(ds_root, (tr_images, tr_by), [(ex_root, ex_tr, ex_tr_by)] * max(1, extra_repeat))  # repeated: a few thousand publisher pages against 83k arXiv ones
        ex_dv, ex_dv_by, _ = load_coco(ex_dir / "dev.json")
        dv_images, dv_by = merge_sets(ds_root, (dv_images, dv_by), [(ex_root, ex_dv[:eval_pages], ex_dv_by)])
    dv_rows = bench_rows(dv_images, dv_by, names)
    loader = DataLoader(FcosPages(ds_root, tr_images, tr_by, names, train=True, augment=augment), batch_size=batch_size, shuffle=True, num_workers=workers, collate_fn=collate, drop_last=True, persistent_workers=workers > 0)
    params = [p for p in model.parameters() if p.requires_grad]
    opt = torch.optim.SGD(params, lr=lr, momentum=0.9, weight_decay=1e-4)
    warm = max(1, min(500, steps // 10))
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1.0, (s + 1) / warm) * 0.5 * (1 + math.cos(math.pi * min(1.0, max(0, s - warm) / max(1, steps - warm)))))
    emit(event="start", run=run, arch="fcos_resnet50_fpn", assign=assign, dataset=dataset, init=init, extra_datasets=list(extra_datasets), extra_repeat=extra_repeat, augment=augment, steps=steps, batch_size=batch_size, lr=lr, size=size, train_pages=len(tr_images), dev_pages=len(dv_images), device=str(dev))
    best = -1.0
    step = 0
    t0 = time.monotonic()
    model.train()
    while step < steps:
        for images, targets, metas in loader:
            images = [im.to(dev) for im in images]
            targets = [{k: v.to(dev) for k, v in t.items()} for t in targets]
            losses = model(images, targets)  # fp32 on purpose: under bf16 autocast the loss was NaN from the first steps
            if not torch.isfinite(sum(losses.values())):
                emit(event="skip", step=step + 1, parts={k: float(v) for k, v in losses.items()}, pages=[f"{m['paper']}:{m['page']}" for m in metas], boxes=[int(t["boxes"].shape[0]) for t in targets])
                continue
            loss = sum(losses.values())
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(params, 10.0)
            opt.step()
            sched.step()
            step += 1
            if step % 20 == 0:
                emit(event="step", step=step, loss=round(float(loss), 4), parts={k: round(float(v), 4) for k, v in losses.items()}, lr=sched.get_last_lr()[0], s_per_step=round((time.monotonic() - t0) / step, 3), gpu_gb=round(torch.cuda.max_memory_allocated() / 2**30, 1) if dev.type == "cuda" else None)
            if step % eval_every == 0 or step == steps:
                t1 = time.monotonic()
                f1, th, summary = sweep(model, ds_root, dv_images, dv_rows, dev)
                emit(event="eval", step=step, seconds=round(time.monotonic() - t1, 1), thresholds=th, all=summary["all"], agnostic=summary["agnostic"], classes={c: summary[c]["f1"] for c in CLASSES if c in summary})  # type: ignore[index]
                if f1 > best:
                    best = f1
                    torch.save(model.state_dict(), out_dir / "model.pt")
                    (out_dir / "train-run.json").write_text(json.dumps({"run": run, "arch": "fcos_resnet50_fpn", "assign": assign, "dataset": dataset, "step": step, "size": size, "thresholds": th, "dev_f1": f1, "classes": CLASSES}, indent=1))
                    emit(event="checkpoint", step=step, score=f1, thresholds=th, path=str(out_dir))
            if step >= steps:
                break
    emit(event="done", run=run, steps=step, best_dev_f1=best, minutes=round((time.monotonic() - t0) / 60, 1))
    log.close()
    return out_dir
