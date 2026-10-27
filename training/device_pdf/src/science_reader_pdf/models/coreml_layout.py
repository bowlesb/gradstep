"""Core ML export of a fine-tuned FCOS layout detector (`gs export-model layout-coreml`).

The device renders a page onto a fixed 1024 x 1440 canvas (the page scaled to fit, white below
and to the right, the same scale the trainer used: a 150 dpi letter page lands at 1019 x 1440)
and the model returns every feature point's box in canvas pixels and its score for each of the
bench's classes. The app keeps the points above each class's threshold (`thresholds` in
export.json, chosen on dev by the trainer), runs greedy NMS per class at IoU 0.6 and keeps the
300 best. The same canvas and decoding run in PyTorch here (`canvas_predictions`) so the export
contract is scored on the layout bench before anything is copied to a Mac; the Mac side is
`scripts/coreml_latency.py`, which reports milliseconds per page and agreement with the
PyTorch detections shipped in `samples/`.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torch import nn
from torchvision.models.detection.image_list import ImageList
from torchvision.ops import batched_nms
from torchvision.transforms.functional import to_tensor

from science_reader_pdf.eval.layout import CLASSES, load_bench, predictions_file, record, score
from science_reader_pdf.paths import MODELS, RUNS

CANVAS = (1024, 1440)  # width, height
MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)
NMS_IOU = 0.6
MAX_DETECTIONS = 300


class LayoutDetector(nn.Module):
    """FCOS backbone and head with the anchors baked in: image [1, 3, H, W] in 0..1 ->
    boxes [N, 4] (canvas pixels, x0 y0 x1 y1) and scores [N, len(CLASSES)]."""

    def __init__(self, fcos: nn.Module, canvas: tuple[int, int] = CANVAS) -> None:
        super().__init__()
        self.backbone, self.head = fcos.backbone, fcos.head
        w, h = canvas
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))
        self.register_buffer("limit", torch.tensor([w, h, w, h], dtype=torch.float32))
        with torch.no_grad():
            blank = torch.zeros(1, 3, h, w)
            feats = list(fcos.backbone(blank).values())
            anchors = fcos.anchor_generator(ImageList(blank, [(h, w)]), feats)[0]
        self.register_buffer("anchors", anchors)
        self.points_per_level = [int(f.shape[2] * f.shape[3]) for f in feats]

    def forward(self, image: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        x = (image - self.mean) / self.std
        out = self.head(list(self.backbone(x).values()))
        reg, cls, ctr = out["bbox_regression"][0], out["cls_logits"][0], out["bbox_ctrness"][0]
        a = self.anchors
        cx, cy = (a[:, 0] + a[:, 2]) / 2, (a[:, 1] + a[:, 3]) / 2
        aw, ah = a[:, 2] - a[:, 0], a[:, 3] - a[:, 1]
        boxes = torch.stack([cx - reg[:, 0] * aw, cy - reg[:, 1] * ah, cx + reg[:, 2] * aw, cy + reg[:, 3] * ah], dim=1)
        boxes = torch.minimum(boxes.clamp(min=0.0), self.limit)
        scores = torch.sqrt(torch.sigmoid(cls[:, 1:]) * torch.sigmoid(ctr))  # column 0 is background
        return boxes, scores


def to_canvas(img: Image.Image, canvas: tuple[int, int] = CANVAS) -> tuple[Image.Image, float]:
    """The page scaled to fit the canvas at the top left, white elsewhere; returns the scale."""
    w, h = canvas
    s = min(w / img.width, h / img.height)
    page = img.convert("RGB").resize((max(1, round(img.width * s)), max(1, round(img.height * s))), Image.BILINEAR)
    out = Image.new("RGB", (w, h), (255, 255, 255))
    out.paste(page, (0, 0))
    return out, s


def detect(boxes: torch.Tensor, scores: torch.Tensor, thresholds: dict[str, float]) -> list[dict[str, object]]:
    """The device's decoding: per-class thresholds, NMS per class, the best 300; boxes in canvas pixels."""
    th = torch.tensor([thresholds[c] for c in CLASSES], device=scores.device)
    pt, cl = torch.nonzero(scores >= th, as_tuple=True)
    if pt.numel() == 0:
        return []
    sc = scores[pt, cl]
    keep = batched_nms(boxes[pt], sc, cl, NMS_IOU)[:MAX_DETECTIONS]
    return [{"cls": CLASSES[int(cl[k])], "score": round(float(sc[k]), 4), "box": [round(float(v), 1) for v in boxes[pt[k]]]} for k in keep]


def load_detector(model_dir: Path, device: torch.device) -> tuple[LayoutDetector, dict[str, object]]:
    from science_reader_pdf.models.train_layout_fcos import load_checkpoint

    fcos, info = load_checkpoint(model_dir, torch.device("cpu"))
    return LayoutDetector(fcos).to(device).eval(), info


@torch.no_grad()
def page_detections(det: LayoutDetector, img: Image.Image, thresholds: dict[str, float], device: torch.device) -> tuple[list[dict[str, object]], float]:
    canvas, s = to_canvas(img)
    boxes, scores = det(to_tensor(canvas)[None].to(device))
    return detect(boxes, scores, thresholds), s


def canvas_predictions(model_dir: Path, bench: Path, device: str = "cuda", limit: int = 0) -> tuple[Path, dict[str, object], float]:
    """Run the export contract (canvas, baked anchors, device decoding) over a layout bench in
    PyTorch and score it; predictions go under `data/runs/eval/layout/<model>-canvas/`."""
    dev = torch.device(device if torch.cuda.is_available() or device == "cpu" else "cpu")
    det, info = load_detector(model_dir, dev)
    thresholds = {c: float(v) for c, v in dict(info["thresholds"]).items()}  # type: ignore[call-overload]
    rows = load_bench(bench)
    if limit:
        rows = rows[:limit]
    out = RUNS / "eval" / "layout" / f"{model_dir.name}-canvas"
    out.mkdir(parents=True, exist_ok=True)
    pred_file = predictions_file(out, bench)
    t0 = time.monotonic()
    preds: dict[tuple[str, int], list[dict[str, object]]] = {}
    with pred_file.open("w") as f:
        for r in rows:
            found, s = page_detections(det, Image.open(bench.parent / str(r["path"])), thresholds, dev)
            boxes = [{"label": d["cls"], "cls": d["cls"], "score": d["score"], "box": [int(d["box"][0] / s), int(d["box"][1] / s), int(d["box"][2] / s + 0.999), int(d["box"][3] / s + 0.999)]} for d in found]  # type: ignore[index]
            preds[(r["paper"], r["page"])] = boxes
            f.write(json.dumps({"paper": r["paper"], "page": r["page"], "boxes": boxes}) + "\n")
    seconds = time.monotonic() - t0
    summary = score(rows, preds)
    record(f"{model_dir.name}-canvas", bench, pred_file, summary, seconds)
    return pred_file, summary, seconds


def export(model_dir: Path, out_dir: Path, bench: Path | None = None, n_samples: int = 8, int8: bool = True, device: str = "cuda") -> dict[str, object]:
    import coremltools as ct

    out_dir.mkdir(parents=True, exist_ok=True)
    det, info = load_detector(model_dir, torch.device("cpu"))
    thresholds = {c: float(v) for c, v in dict(info["thresholds"]).items()}  # type: ignore[call-overload]
    w, h = CANVAS
    with torch.no_grad():
        traced = torch.jit.trace(det, torch.zeros(1, 3, h, w))
    t0 = time.monotonic()
    ml = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, h, w), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="boxes"), ct.TensorType(name="scores")],
        convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS18,
    )
    ml.save(str(out_dir / "layout.mlpackage"))
    sizes = {"fp16_mb": round(_dir_mb(out_dir / "layout.mlpackage"), 1)}
    if int8:
        from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

        q = linear_quantize_weights(ct.models.MLModel(str(out_dir / "layout.mlpackage"), skip_model_load=True), config=OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")))
        q.save(str(out_dir / "layout-int8.mlpackage"))
        sizes["int8_mb"] = round(_dir_mb(out_dir / "layout-int8.mlpackage"), 1)
    seconds = round(time.monotonic() - t0, 1)
    meta: dict[str, object] = {"kind": "layout", "model_dir": str(model_dir), "arch": info.get("arch"), "step": info.get("step"), "dev_f1": info.get("dev_f1"), "canvas": {"width": w, "height": h},
                               "classes": CLASSES, "thresholds": thresholds, "nms_iou": NMS_IOU, "max_detections": MAX_DETECTIONS, "points_per_level": det.points_per_level,
                               "input": "RGB page scaled to fit the canvas at the top left, white elsewhere; boxes come back in canvas pixels", "conversion_seconds": seconds, **sizes}
    if bench is not None:
        samples_dir = out_dir / "samples"
        samples_dir.mkdir(exist_ok=True)
        rows = load_bench(bench)[:n_samples]
        samples = []
        for r in rows:
            img = Image.open(bench.parent / str(r["path"]))
            canvas, s = to_canvas(img)
            name = f"{r['paper']}-p{int(r['page']):04d}"
            canvas.save(samples_dir / f"{name}.png")
            found, _ = page_detections(det, img, thresholds, torch.device("cpu"))
            samples.append({"file": f"{name}.png", "paper": r["paper"], "page": r["page"], "scale": s, "detections": found})
        meta["samples"] = samples
        _, summary, bench_seconds = canvas_predictions(model_dir, bench, device=device)
        meta["bench"] = {"name": bench.stem, "f1": summary["all"]["f1"], "precision": summary["all"]["precision"], "recall": summary["all"]["recall"], "seconds": round(bench_seconds, 1)}  # type: ignore[index]
    (out_dir / "export.json").write_text(json.dumps(meta, indent=1))
    return meta


def _dir_mb(path: Path) -> float:
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file()) / 1e6


def default_out(model_dir: Path) -> Path:
    return MODELS / f"{model_dir.name}-coreml"


def nms_numpy(boxes: np.ndarray, scores: np.ndarray, iou: float = NMS_IOU) -> list[int]:
    """Greedy NMS for the Mac script (no torch there)."""
    order = np.argsort(-scores)
    keep: list[int] = []
    while order.size:
        i = int(order[0])
        keep.append(i)
        rest = order[1:]
        if not rest.size:
            break
        x0 = np.maximum(boxes[i, 0], boxes[rest, 0])
        y0 = np.maximum(boxes[i, 1], boxes[rest, 1])
        x1 = np.minimum(boxes[i, 2], boxes[rest, 2])
        y1 = np.minimum(boxes[i, 3], boxes[rest, 3])
        inter = np.clip(x1 - x0, 0, None) * np.clip(y1 - y0, 0, None)
        area = lambda b: (b[..., 2] - b[..., 0]) * (b[..., 3] - b[..., 1])  # noqa: E731
        ov = inter / (area(boxes[i]) + area(boxes[rest]) - inter + 1e-9)
        order = rest[ov <= iou]
    return keep
