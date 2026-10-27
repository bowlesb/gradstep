"""Layout fine-tune on numbered displays (science-reader-device-pdf; read-only use of /home/ben/mathpix).

The factory's display boxes are the formula body; its equation number is text no gold region covers, so the export
makes it an `ignore` box, and FcosPages paints ignore boxes white in training. The detector therefore never saw an
equation number while training, and sees one beside every numbered display on a real page. This fine-tune keeps the
numbers on the page (an ignore box level with a display, to its right or left, and narrow, is not painted), and draws
pages that hold numbered displays more often.

    python layout_ft.py eval <model dir> [--split test] [--pages 1500]      displays found, numbered and not
    python layout_ft.py train <run> --init <model dir> [--steps 4000] [--numbered-repeat 2] [--augment]
"""
import argparse, json, math, random, sys, time
from pathlib import Path

import torch  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402
from torch.utils.data import DataLoader  # noqa: E402
from science_reader_pdf.eval.layout import CLASSES  # noqa: E402
from science_reader_pdf.models.train_layout import bench_rows, load_coco  # noqa: E402
from science_reader_pdf.models.train_layout_fcos import FcosPages, build_model, collate, merge_sets, predict, renderer_jitter, sweep  # noqa: E402
from science_reader_pdf.paths import DATA, MODELS, RUNS as RUN_ROOT  # noqa: E402

RUNS = RUN_ROOT / "layout"
FACTORY = "factory-v4/layout-full"
PMC = "pmc-v2/layout-full"


def tags_of(anns, names):
    """Ignore boxes that are equation numbers: level with a display (half their height inside its rows), beside it
    (left of its left edge or right of its right edge), narrow (under 80 px at 150 dpi) and short (under 40 px)."""
    displays = [a["bbox"] for a in anns if names[int(a["category_id"])] == "display"]
    out = []
    for a in anns:
        if names[int(a["category_id"])] != "ignore": continue
        x, y, w, h = a["bbox"]
        if w > 80 or h > 40: continue
        for dx, dy, dw, dh in displays:
            inside = min(y + h, dy + dh) - max(y, dy)
            if inside >= 0.5 * h and (x >= dx + dw - 2 or x + w <= dx + 2):
                out.append(a); break
    return out


class KeepNumbers(FcosPages):
    """FcosPages, with equation numbers left on the page instead of painted white."""

    def __getitem__(self, i):
        im = self.images[i]
        img = Image.open(self.root / str(im["file_name"])).convert("RGB")
        anns = self.by_image.get(int(im["id"]), [])
        keep = {id(a) for a in tags_of(anns, self.names)}
        boxes, labels, ignore = [], [], []
        for a in anns:
            name = self.names[int(a["category_id"])]
            x, y, w, h = a["bbox"]
            if name == "ignore":
                if id(a) not in keep: ignore.append((x, y, w, h))
            elif w > 1 and h > 1:
                boxes.append([x, y, x + w, y + h]); labels.append(CLASSES.index(name) + 1)
        if ignore:
            draw = ImageDraw.Draw(img)
            for x, y, w, h in ignore:
                draw.rectangle([x - 2, y - 2, x + w + 2, y + h + 2], fill=(255, 255, 255))
        if self.augment:
            img = renderer_jitter(img, random.Random(random.getrandbits(32)))
        target = {"boxes": torch.tensor(boxes, dtype=torch.float32).reshape(-1, 4), "labels": torch.tensor(labels, dtype=torch.int64)}
        from torchvision.transforms.functional import to_tensor
        return to_tensor(img), target, im


def iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0])); iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    return inter / max(1e-6, (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter)


def display_report(preds, images, by, names, thresholds):
    """Gold displays found (a predicted display at IoU 0.5), split by numbered; what took a missed one's place."""
    stats = {"numbered": [0, 0], "plain": [0, 0]}; took = {}; pred_n = pred_tp = 0
    for im in images:
        anns = by.get(int(im["id"]), [])
        tags = tags_of(anns, names)
        golds = [a["bbox"] for a in anns if names[int(a["category_id"])] == "display"]
        ps = [p for p in preds.get((im["paper"], im["page"]), []) if p["score"] >= thresholds.get(p["cls"], 0.5)]
        pd = [p["box"] for p in ps if p["cls"] == "display"]
        pred_n += len(pd)
        matched = set()
        for x, y, w, h in golds:
            g = [x, y, x + w, y + h]
            numbered = any(min(t["bbox"][1] + t["bbox"][3], y + h) - max(t["bbox"][1], y) >= 0.5 * t["bbox"][3] for t in tags)
            key = "numbered" if numbered else "plain"
            stats[key][1] += 1
            hit = next((k for k, b in enumerate(pd) if k not in matched and iou(g, b) >= 0.5), None)
            if hit is not None:
                matched.add(hit); stats[key][0] += 1
            else:
                over = max(((iou(g, p["box"]), p["cls"]) for p in ps), default=(0, "none"))
                cls = over[1] if over[0] > 0.05 or any(p["box"][0] <= g[0] + 4 and p["box"][2] >= g[2] - 4 and p["box"][1] <= g[1] + 4 and p["box"][3] >= g[3] - 4 for p in ps) else "none"
                took[f"{key}:{cls}"] = took.get(f"{key}:{cls}", 0) + 1
        pred_tp += len(matched)
    return {"numbered_recall": round(stats["numbered"][0] / max(1, stats["numbered"][1]), 4), "numbered": stats["numbered"][1],
            "plain_recall": round(stats["plain"][0] / max(1, stats["plain"][1]), 4), "plain": stats["plain"][1],
            "display_precision": round(pred_tp / max(1, pred_n), 4), "missed_as": dict(sorted(took.items(), key=lambda kv: -kv[1]))}


def load_model(model_dir):
    info = json.loads((Path(model_dir) / "train-run.json").read_text())
    model = build_model(int(info.get("size", 1024)), assign=str(info.get("assign", "thin")))
    model.load_state_dict(torch.load(Path(model_dir) / "model.pt", map_location="cpu"))
    return model, info


def evaluate(args):
    dev = torch.device("cuda")
    model, info = load_model(args.model); model.to(dev).eval()
    images, by, names = load_coco(DATA / "datasets" / FACTORY / f"{args.split}.json")
    images = images[: args.pages]
    preds = predict(model, DATA / "datasets" / "factory-v4", images, dev)
    rep = display_report(preds, images, by, names, info["thresholds"])
    rep.update({"model": args.model, "split": args.split, "pages": len(images)})
    print(json.dumps(rep))


def train(args):
    random.seed(args.seed); torch.manual_seed(args.seed)
    out = RUNS / args.run; out.mkdir(parents=True, exist_ok=True)
    log = (out / "log.jsonl").open("a")
    def emit(**kw):
        row = {"time": round(time.time(), 1), **kw}; print(json.dumps(row), flush=True); log.write(json.dumps(row) + "\n"); log.flush()
    dev = torch.device("cuda")
    model, info = load_model(args.init); model.to(dev)
    root = DATA / "datasets" / "factory-v4"
    tr, tr_by, names = load_coco(DATA / "datasets" / FACTORY / "train.json")
    dv, dv_by, _ = load_coco(DATA / "datasets" / FACTORY / "dev.json"); dv = dv[: args.eval_pages]
    ex_root = DATA / "datasets" / "pmc-v2"
    ex_tr, ex_tr_by, _ = load_coco(DATA / "datasets" / PMC / "train.json")
    numbered = [im for im in tr if tags_of(tr_by.get(int(im["id"]), []), names)]
    pmc_numbered = [im for im in ex_tr if tags_of(ex_tr_by.get(int(im["id"]), []), names)]
    extras = [(ex_root, ex_tr, ex_tr_by)] * args.pmc_repeat + [(root, numbered, tr_by)] * (args.numbered_repeat - 1) + [(ex_root, pmc_numbered, ex_tr_by)] * (args.numbered_repeat - 1)
    # Hard pages (mine.py): training pages where v5 missed a display or a table, drawn `hard_repeat` more times.
    hard_n = 0
    for f in [x for x in args.hard.split(",") if x]:
        hard = json.loads(Path(f).expanduser().read_text())
        for ds, rows in hard.items():
            ids = {r["id"] for r in rows}
            if ds == FACTORY: pages, by_, r_ = [im for im in tr if int(im["id"]) in ids], tr_by, root
            else: pages, by_, r_ = [im for im in ex_tr if int(im["id"]) in ids], ex_tr_by, ex_root
            extras += [(r_, pages, by_)] * args.hard_repeat; hard_n += len(pages)
    images, by = merge_sets(root, (tr, tr_by), extras)
    ex_dv, ex_dv_by, _ = load_coco(DATA / "datasets" / PMC / "dev.json")
    dv_all, dv_all_by = merge_sets(root, (dv, dv_by), [(ex_root, ex_dv[: args.eval_pages], ex_dv_by)])
    dv_rows = bench_rows(dv_all, dv_all_by, names)
    loader = DataLoader(KeepNumbers(root, images, by, names, train=True, augment=args.augment), batch_size=6, shuffle=True, num_workers=8, collate_fn=collate, drop_last=True, persistent_workers=True)
    params = [p for p in model.parameters() if p.requires_grad]
    opt = torch.optim.SGD(params, lr=args.lr, momentum=0.9, weight_decay=1e-4)
    warm = max(1, min(300, args.steps // 10))
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1.0, (s + 1) / warm) * 0.5 * (1 + math.cos(math.pi * min(1.0, max(0, s - warm) / max(1, args.steps - warm)))))
    emit(event="start", args=vars(args), train_pages=len(images), numbered_pages=len(numbered), pmc_numbered_pages=len(pmc_numbered), hard_pages=hard_n)
    step, best, t0 = 0, -1.0, time.monotonic()
    model.train()
    while step < args.steps:
        for imgs, targets, metas in loader:
            imgs = [i.to(dev) for i in imgs]; targets = [{k: v.to(dev) for k, v in t.items()} for t in targets]
            losses = model(imgs, targets)
            loss = sum(losses.values())
            if not torch.isfinite(loss): continue
            opt.zero_grad(set_to_none=True); loss.backward(); torch.nn.utils.clip_grad_norm_(params, 10.0); opt.step(); sched.step(); step += 1
            if step % 100 == 0: emit(event="step", step=step, loss=round(float(loss), 4), s_per_step=round((time.monotonic() - t0) / step, 3))
            if step % args.eval_every == 0 or step == args.steps:
                f1, th, summary = sweep(model, root, dv_all, dv_rows, dev)
                rep = display_report(predict(model, root, dv, dev), dv, dv_by, names, th)
                emit(event="eval", step=step, f1=f1, thresholds=th, classes={c: summary[c]["f1"] for c in CLASSES if c in summary}, displays=rep)
                model.train()
                torch.save(model.state_dict(), out / f"model-{step}.pt")
                if f1 > best:
                    best = f1
                    torch.save(model.state_dict(), out / "model.pt")
                    (out / "train-run.json").write_text(json.dumps({"run": args.run, "arch": "fcos_resnet50_fpn", "assign": "thin", "dataset": FACTORY, "init": str(args.init), "step": step, "size": 1024, "thresholds": th, "dev_f1": f1, "classes": CLASSES}, indent=1))
            if step >= args.steps: break
    emit(event="done", best=best, minutes=round((time.monotonic() - t0) / 60, 1))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd"); ap.add_argument("target")
    ap.add_argument("--split", default="test"); ap.add_argument("--pages", type=int, default=1500)
    ap.add_argument("--init", default=str(MODELS / "layout-fcos-v5")); ap.add_argument("--steps", type=int, default=4000); ap.add_argument("--lr", type=float, default=0.001)
    ap.add_argument("--numbered-repeat", type=int, default=2); ap.add_argument("--pmc-repeat", type=int, default=4); ap.add_argument("--augment", action="store_true")
    ap.add_argument("--hard", default=""); ap.add_argument("--hard-repeat", type=int, default=4); ap.add_argument("--keep-numbers", type=int, default=1)
    ap.add_argument("--eval-every", type=int, default=1000); ap.add_argument("--eval-pages", type=int, default=300); ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()
    if a.cmd == "eval": a.model = a.target; evaluate(a)
    else: a.run = a.target; train(a)
