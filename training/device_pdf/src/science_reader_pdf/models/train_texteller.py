"""Fine-tune TexTeller (ViT encoder + TrOCR decoder) on factory equation crops.

Training data: `data/datasets/<dataset>/equations/index.jsonl`, train split, excluding the
pilot families (bench-v1 and bench-v2 are built on them). Images go through the same
preprocessing as inference (`texteller.preprocess_image`) after light augmentation; targets
are the factory TeX tokenised with the model's own tokenizer. The decoder is fed
`<s> t1 .. tn` and predicts `t1 .. tn </s>`, which is what the pretrained model expects
(decoder start 0 beats 2 on the bench: 37/80 vs 21/80 normalised matches).

Every run writes `data/runs/train/<run>/config.json` and `log.jsonl` (loss per log step, dev
scores per eval), and saves the best checkpoint by dev score to `data/models/<run>/`, loadable
by `gs eval equations texteller --model-dir data/models/<run> --name <run>`.
"""

from __future__ import annotations

import json
import math
import random
import time
from dataclasses import asdict, dataclass
from pathlib import Path

from science_reader_pdf.paths import DATA, MODELS, RUNS


@dataclass
class TrainConfig:
    run: str = "texteller-ft-v1"
    dataset: str = "factory-v2"
    exclude_dataset: str = "factory-v1"  # families used by the benches; never trained on
    base_model: str = "texteller"
    epochs: float = 3.0
    batch_size: int = 16
    grad_accum: int = 2
    lr: float = 3e-5
    encoder_lr_scale: float = 0.5  # the ViT encoder moves at half the decoder's rate
    weight_decay: float = 0.01
    warmup_steps: int = 300
    max_tokens: int = 512  # targets longer than this are dropped (p99 is 97)
    display_weight: float = 3.0  # display crops are 7% of the data; sample them 3x
    long_weight: float = 1.0  # display crops whose TeX is over LONG_TEX characters are sampled this many times as often again (accuracy falls with length; 1 = off)
    augment: bool = True
    masked_mix: float = 0.0  # probability of training on the masked twin of a crop (equations-masked/), when present
    skip_suspect: bool = True  # drop crops flagged by gs label-check (label disagrees with the glyphs)
    eval_every: int = 500
    log_every: int = 20
    dev_per_placement: int = 300
    max_steps: int = 0  # 0 = until epochs are done; small values for smoke tests
    limit_train: int = 0
    seed: int = 0
    num_workers: int = 8
    device: str = "cuda"


# ----------------------------------------------------------------- data


def load_rows(cfg: TrainConfig) -> tuple[list[dict], list[dict]]:
    pilot = set(json.load((DATA / "datasets" / cfg.exclude_dataset / "splits.json").open()).keys())
    rows = [json.loads(line) for line in (DATA / "datasets" / cfg.dataset / "equations" / "index.jsonl").read_text().splitlines()]
    rows = [r for r in rows if r["family"] not in pilot]
    if cfg.skip_suspect:
        from science_reader_pdf.data.labelcheck import load_suspect

        suspect = load_suspect(cfg.dataset)
        rows = [r for r in rows if (r["paper"], r["id"]) not in suspect]
    train = [r for r in rows if r["split"] == "train"]
    dev = [r for r in rows if r["split"] == "dev"]
    masked_index = DATA / "datasets" / cfg.dataset / "equations-masked" / "index.jsonl"
    if cfg.masked_mix > 0 and masked_index.is_file():
        masked = {(m["paper"], m["id"]): m["path"] for m in map(json.loads, masked_index.read_text().splitlines())}
        for r in train:
            r["masked_path"] = masked.get((r["paper"], r["id"]))
    rng = random.Random(cfg.seed)
    rng.shuffle(train)
    if cfg.limit_train:
        train = train[: cfg.limit_train]
    dev_subset: list[dict] = []
    for placement in ("inline", "display"):
        pool = [r for r in dev if r["placement"] == placement]
        rng.shuffle(pool)
        dev_subset += pool[: cfg.dev_per_placement]
    return train, dev_subset


def augment_image(image, rng: random.Random):  # type: ignore[no-untyped-def]
    """Mild photometric and resolution jitter on an RGB uint8 crop. Crops in the app come from
    PDF rendering at varying scale, so the useful variation is blur and scale, not geometry."""
    import cv2
    import numpy as np

    h, w = image.shape[:2]
    if rng.random() < 0.5:  # lower effective resolution (then the 448 fit upsamples it again)
        s = max(rng.uniform(0.45, 1.0), 14 / max(1, h))
        if s < 0.98:
            image = cv2.resize(image, (max(1, int(w * s)), max(1, int(h * s))), interpolation=cv2.INTER_AREA)
    if rng.random() < 0.3:
        sigma = rng.uniform(0.3, 1.0)
        image = cv2.GaussianBlur(image, (0, 0), sigma)
    if rng.random() < 0.3:
        a, b = rng.uniform(0.8, 1.2), rng.uniform(-20, 20)
        image = np.clip(image.astype(np.float32) * a + b, 0, 255).astype(np.uint8)
    if rng.random() < 0.2:
        noise = np.random.default_rng(rng.getrandbits(32)).normal(0, rng.uniform(2, 8), image.shape)
        image = np.clip(image.astype(np.float32) + noise, 0, 255).astype(np.uint8)
    return image


class CropDataset:
    def __init__(self, rows: list[dict], root: Path, tokenizer, max_tokens: int, augment: bool, seed: int, masked_mix: float = 0.0):  # type: ignore[no-untyped-def]
        self.rows, self.root, self.tok, self.max_tokens, self.augment, self.seed, self.masked_mix = rows, root, tokenizer, max_tokens, augment, seed, masked_mix

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, i: int):  # type: ignore[no-untyped-def]
        import cv2

        from science_reader_pdf.models.texteller import preprocess_image

        r = self.rows[i]
        rng = random.Random(hash((self.seed, i, time.time_ns())))
        path = r.get("masked_path") if self.masked_mix > 0 and r.get("masked_path") and rng.random() < self.masked_mix else r["path"]
        image = cv2.imread(str(self.root / path), cv2.IMREAD_COLOR)
        if image is None:  # a crop removed or rewritten under a running trainer: train on another row instead
            return self[rng.randrange(len(self.rows))]
        image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
        if self.augment:
            image = augment_image(image, rng)
        ids = self.tok(r["tex"], add_special_tokens=False)["input_ids"][: self.max_tokens - 1]
        return preprocess_image(image), ids, i


def collate(batch, pad_id: int, bos_id: int, eos_id: int):  # type: ignore[no-untyped-def]
    import torch

    pixels = torch.stack([b[0] for b in batch])
    n = max(len(b[1]) for b in batch) + 1
    dec = torch.full((len(batch), n), pad_id, dtype=torch.long)
    labels = torch.full((len(batch), n), -100, dtype=torch.long)
    mask = torch.zeros((len(batch), n), dtype=torch.long)
    for k, (_, ids, _) in enumerate(batch):
        dec[k, 0] = bos_id
        dec[k, 1 : len(ids) + 1] = torch.tensor(ids)
        labels[k, : len(ids)] = torch.tensor(ids)
        labels[k, len(ids)] = eos_id
        mask[k, : len(ids) + 1] = 1
    return pixels, dec, mask, labels, [b[2] for b in batch]


# ----------------------------------------------------------------- evaluation


def evaluate(model, tokenizer, rows: list[dict], root: Path, device, batch_size: int = 32, max_new_tokens: int = 320) -> dict[str, object]:  # type: ignore[no-untyped-def]
    import torch
    from transformers import GenerationConfig

    from science_reader_pdf.eval.equations import edit_distance, normalize
    from science_reader_pdf.models.texteller import preprocess

    gen = GenerationConfig(max_new_tokens=max_new_tokens, num_beams=1, do_sample=False, pad_token_id=tokenizer.pad_token_id, eos_token_id=tokenizer.eos_token_id, bos_token_id=tokenizer.bos_token_id, decoder_start_token_id=tokenizer.bos_token_id)
    model.eval()
    per: dict[str, list[tuple[bool, float]]] = {"inline": [], "display": []}
    samples: list[dict] = []
    t0 = time.monotonic()
    with torch.no_grad():
        for start in range(0, len(rows), batch_size):
            chunk = rows[start : start + batch_size]
            pixels = torch.stack([preprocess(root / r["path"]) for r in chunk]).to(device)
            with torch.autocast(device_type=device.type, dtype=torch.bfloat16, enabled=device.type == "cuda"):
                ids = model.generate(pixels, generation_config=gen)
            outs = tokenizer.batch_decode(ids, skip_special_tokens=True)
            for r, out in zip(chunk, outs, strict=True):
                ref_n, pred_n = normalize(r["tex"]), normalize(out.strip())
                cer = min(1.0, edit_distance(pred_n, ref_n) / max(1, len(ref_n)))
                per[r["placement"]].append((pred_n == ref_n, cer))
                if len(samples) < 6:
                    samples.append({"id": r["id"], "paper": r["paper"], "ref": r["tex"][:120], "pred": out.strip()[:120]})
    model.train()
    result: dict[str, object] = {"seconds": round(time.monotonic() - t0, 1), "samples": samples}
    for placement, items in per.items():
        if items:
            result[f"{placement}_normalized"] = round(sum(ok for ok, _ in items) / len(items), 4)
            result[f"{placement}_cer"] = round(sum(c for _, c in items) / len(items), 4)
    result["score"] = round(sum(v for k, v in result.items() if k.endswith("_normalized")) / 2, 4)  # type: ignore[misc]
    return result


# ----------------------------------------------------------------- training


LONG_TEX = 120  # characters of reference TeX; v4 reads displays up to this length at 0.95 to 0.97 exact, 240 and over at 0.73


def sample_weight(row: dict[str, object], cfg: "TrainConfig") -> float:
    """Sampling weight of one crop: displays `display_weight` times an inline crop, long displays
    `long_weight` times that again."""
    if row["placement"] != "display":
        return 1.0
    return cfg.display_weight * (cfg.long_weight if len(str(row["tex"])) > LONG_TEX else 1.0)


def train(cfg: TrainConfig) -> Path:
    import torch
    from torch.utils.data import DataLoader, WeightedRandomSampler
    from transformers import RobertaTokenizerFast, VisionEncoderDecoderModel

    torch.manual_seed(cfg.seed)
    random.seed(cfg.seed)
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True
    device = torch.device(cfg.device if torch.cuda.is_available() else "cpu")
    run_dir = RUNS / "train" / cfg.run
    run_dir.mkdir(parents=True, exist_ok=True)
    out_dir = MODELS / cfg.run
    (run_dir / "config.json").write_text(json.dumps(asdict(cfg), indent=1))
    log = (run_dir / "log.jsonl").open("a")

    def emit(**row: object) -> None:
        row = {"time": round(time.time(), 1), **row}
        log.write(json.dumps(row) + "\n")
        log.flush()
        print(json.dumps(row), flush=True)

    base = MODELS / cfg.base_model
    tokenizer = RobertaTokenizerFast.from_pretrained(str(base))
    model = VisionEncoderDecoderModel.from_pretrained(str(base))
    model.config.decoder_start_token_id = tokenizer.bos_token_id
    model.config.pad_token_id = tokenizer.pad_token_id
    model.config.eos_token_id = tokenizer.eos_token_id
    model.generation_config.decoder_start_token_id = tokenizer.bos_token_id
    model.generation_config.use_cache = True
    model.to(device).train()

    train_rows, dev_rows = load_rows(cfg)
    root = DATA / "datasets" / cfg.dataset
    train_rows = [r for r in train_rows if len(tokenizer(r["tex"], add_special_tokens=False)["input_ids"]) < cfg.max_tokens]
    n_display = sum(r["placement"] == "display" for r in train_rows)
    emit(event="data", train=len(train_rows), train_display=n_display, dev=len(dev_rows), device=str(device), with_masked_twin=sum(1 for r in train_rows if r.get("masked_path")))
    ds = CropDataset(train_rows, root, tokenizer, cfg.max_tokens, cfg.augment, cfg.seed, cfg.masked_mix)
    weights = [sample_weight(r, cfg) for r in train_rows]
    steps_per_epoch = math.ceil(len(train_rows) / (cfg.batch_size * cfg.grad_accum))
    total_steps = cfg.max_steps or math.ceil(cfg.epochs * steps_per_epoch)
    sampler = WeightedRandomSampler(weights, num_samples=total_steps * cfg.batch_size * cfg.grad_accum, replacement=True, generator=torch.Generator().manual_seed(cfg.seed))
    loader = DataLoader(ds, batch_size=cfg.batch_size, sampler=sampler, num_workers=cfg.num_workers, collate_fn=lambda b: collate(b, tokenizer.pad_token_id, tokenizer.bos_token_id, tokenizer.eos_token_id), pin_memory=device.type == "cuda", drop_last=True, persistent_workers=cfg.num_workers > 0)

    decay, no_decay = [], []
    for name, p in model.named_parameters():
        (no_decay if p.ndim < 2 or "norm" in name.lower() or name.endswith(".bias") else decay).append((name, p))
    groups = []
    for params, wd in ((decay, cfg.weight_decay), (no_decay, 0.0)):
        for scale, keep in ((cfg.encoder_lr_scale, lambda n: n.startswith("encoder.")), (1.0, lambda n: not n.startswith("encoder."))):
            ps = [p for n, p in params if keep(n)]
            if ps:
                groups.append({"params": ps, "weight_decay": wd, "lr": cfg.lr * scale, "base_lr": cfg.lr * scale})
    opt = torch.optim.AdamW(groups, betas=(0.9, 0.98), eps=1e-8)

    def lr_factor(step: int) -> float:
        if step < cfg.warmup_steps:
            return (step + 1) / cfg.warmup_steps
        progress = (step - cfg.warmup_steps) / max(1, total_steps - cfg.warmup_steps)
        return 0.1 + 0.9 * 0.5 * (1 + math.cos(math.pi * min(1.0, progress)))

    emit(event="start", total_steps=total_steps, steps_per_epoch=steps_per_epoch, params=sum(p.numel() for p in model.parameters()))
    best = -1.0
    step, micro, t0 = 0, 0, time.monotonic()
    running_loss, running_tokens = 0.0, 0
    loss_fn = torch.nn.CrossEntropyLoss(ignore_index=-100, reduction="sum")
    opt.zero_grad(set_to_none=True)
    for pixels, dec, mask, labels, _ in loader:
        pixels, dec, mask, labels = pixels.to(device, non_blocking=True), dec.to(device), mask.to(device), labels.to(device)
        with torch.autocast(device_type=device.type, dtype=torch.bfloat16, enabled=device.type == "cuda"):
            logits = model(pixel_values=pixels, decoder_input_ids=dec, decoder_attention_mask=mask).logits
        n_tok = int((labels != -100).sum())
        loss = loss_fn(logits.float().view(-1, logits.size(-1)), labels.view(-1)) / n_tok
        (loss / cfg.grad_accum).backward()
        running_loss += float(loss.detach()) * n_tok
        running_tokens += n_tok
        micro += 1
        if micro % cfg.grad_accum:
            continue
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        f = lr_factor(step)
        for g in opt.param_groups:
            g["lr"] = g["base_lr"] * f
        opt.step()
        opt.zero_grad(set_to_none=True)
        step += 1
        if step % cfg.log_every == 0:
            emit(event="step", step=step, loss=round(running_loss / max(1, running_tokens), 4), lr=round(cfg.lr * f, 8), epoch=round(step / steps_per_epoch, 3), s_per_step=round((time.monotonic() - t0) / step, 3), gpu_gb=round(torch.cuda.max_memory_allocated() / 1e9, 1) if device.type == "cuda" else 0)
            running_loss, running_tokens = 0.0, 0
        if step % cfg.eval_every == 0 or step == total_steps:
            dev = evaluate(model, tokenizer, dev_rows, root, device)
            emit(event="eval", step=step, **dev)
            if dev["score"] > best:  # type: ignore[operator]
                best = dev["score"]  # type: ignore[assignment]
                model.save_pretrained(str(out_dir))
                tokenizer.save_pretrained(str(out_dir))
                (out_dir / "train-run.json").write_text(json.dumps({"run": cfg.run, "step": step, "dev": dev, "config": asdict(cfg)}, indent=1))
                emit(event="checkpoint", step=step, score=best, path=str(out_dir))
        if step >= total_steps:
            break
    emit(event="done", steps=step, best=best, minutes=round((time.monotonic() - t0) / 60, 1))
    log.close()
    return out_dir
