#!/usr/bin/env python3
"""RT-DETRv2 panel detector training on multi-source data, selected by app-level validation.

Derived from scripts/subfigure-training/train.py (official Apache-2.0 RT-DETRv2, pinned
revision). Changes: two classes (panel, shared context); weighted multi-source manifests;
resolution/JPEG degradation augmentation; per-epoch validation by evaluate.py's app metrics
(complete crops, false splits, counts) through policy.final_crops. Final test is never read here.
"""
import argparse, collections, copy, hashlib, io, json, math, os, random, subprocess, sys, time
from pathlib import Path

import numpy as np
from PIL import Image, ImageEnhance
import torch
from torch.utils.data import Dataset, DataLoader, WeightedRandomSampler

from sfd.core import evaluate as E
from sfd.core import policy as P

Image.MAX_IMAGE_PIXELS = 200_000_000
REPO_REVISION = 'df2a96c8c3a098567a1149bf0248da6efe6d495d'
CONFIGS = {'r18': 'rtdetrv2_r18vd_120e_coco.yml', 'r34': 'rtdetrv2_r34vd_120e_coco.yml',
           'r50m': 'rtdetrv2_r50vd_m_7x_coco.yml', 'r50': 'rtdetrv2_r50vd_6x_coco.yml'}
CLASSES = ['panel', 'shared']


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def write_json(path, value):
    tmp = path.with_suffix('.tmp'); tmp.write_text(json.dumps(value, indent=1) + '\n'); tmp.replace(path)


def letterbox(image, size=640, zoom=1., position=(.5, .5)):
    w, h = image.size
    scale = min(size / w, size / h) * zoom
    rw, rh = max(1, round(w * scale)), max(1, round(h * scale))
    left, top = int((size - rw) * position[0]), int((size - rh) * position[1])
    out = Image.new('RGB', (size, size), 'white')
    out.paste(image.resize((rw, rh), Image.Resampling.BILINEAR), (left, top))
    return out, (rw / w, rh / h, left, top)


def load_rgb(path):
    im = Image.open(path)
    if im.mode in ('RGBA', 'LA', 'P'):
        im = im.convert('RGBA'); bg = Image.new('RGBA', im.size, (255, 255, 255, 255)); im = Image.alpha_composite(bg, im)
    return im.convert('RGB')


class Rows(Dataset):
    def __init__(self, rows, augment=False, size=640, jitter=False):
        self.rows, self.augment, self.size, self.jitter = rows, augment, size, jitter

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, i):
        row = self.rows[i]
        image = load_rgb(row['image'])
        if image.size != (row['width'], row['height']):
            raise ValueError(f"Dimension mismatch {row['id']}")
        if self.augment:
            if random.random() < .25:
                image = ImageEnhance.Contrast(image).enhance(random.uniform(.75, 1.15))
            if random.random() < .15:
                image = image.convert('L').convert('RGB')
            if random.random() < .35:
                f = random.uniform(.3, .8)
                w, h = image.size
                image = image.resize((max(8, int(w * f)), max(8, int(h * f))), Image.Resampling.BILINEAR).resize((w, h), Image.Resampling.BILINEAR)
            if random.random() < .25:
                buf = io.BytesIO(); image.save(buf, 'JPEG', quality=random.randint(35, 90)); buf.seek(0)
                image = Image.open(buf).convert('RGB')
        placement = {}
        if self.augment and self.jitter and random.random() < .6:
            placement = {'zoom': random.uniform(.6, 1.), 'position': (random.random(), random.random())}
        image, tr = letterbox(image, self.size, **placement)
        sx, sy, left, top = tr
        boxes = []
        for b in row['boxes']:
            x1, y1, x2, y2 = b['box']
            boxes.append([((x1 + x2) / 2 * sx + left) / self.size, ((y1 + y2) / 2 * sy + top) / self.size,
                          max(1e-4, (x2 - x1) * sx / self.size), max(1e-4, (y2 - y1) * sy / self.size)])
        target = {'boxes': torch.tensor(boxes, dtype=torch.float32).reshape(-1, 4),
                  'labels': torch.tensor([b['class'] for b in row['boxes']], dtype=torch.int64)}
        data = torch.from_numpy(np.asarray(image, dtype=np.float32).transpose(2, 0, 1).copy() / 255.)
        return data, target, i, tr


def collate(batch):
    images, targets, ids, trs = zip(*batch)
    return torch.stack(images), list(targets), ids, trs


def seed_worker(_):
    s = torch.initial_seed() % 2 ** 32
    random.seed(s); np.random.seed(s)


@torch.inference_mode()
def predict(model, loader, device, min_score=.03):
    model.eval(); results = [None] * len(loader.dataset)
    for images, _, ids, trs in loader:
        out = model(images.to(device, non_blocking=True))
        probs = out['pred_logits'].sigmoid()
        scores, labels = probs.max(-1)
        boxes = out['pred_boxes'].float().cpu().numpy(); scores = scores.float().cpu().numpy(); labels = labels.cpu().numpy()
        for bi, (i, tr) in enumerate(zip(ids, trs)):
            sx, sy, left, top = tr; row = loader.dataset.rows[i]; recs = []
            for s, l, b in zip(scores[bi], labels[bi], boxes[bi]):
                if s < min_score:
                    continue
                cx, cy, bw, bh = b * loader.dataset.size
                raw = [(cx - bw / 2 - left) / sx, (cy - bh / 2 - top) / sy, (cx + bw / 2 - left) / sx, (cy + bh / 2 - top) / sy]
                bb = [max(0., float(raw[0])), max(0., float(raw[1])), min(float(row['width']), float(raw[2])), min(float(row['height']), float(raw[3]))]
                if not np.isfinite(bb).all() or bb[2] <= bb[0] or bb[3] <= bb[1]:
                    continue
                recs.append({'class': int(l), 'score': float(s), 'box': bb})
            results[i] = recs
    return results


def build_model(repo, weights, arch, classes=2, size=640):
    rev = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain', '--untracked-files=no'], text=True)
    if rev != REPO_REVISION or dirty:
        raise ValueError('Expected pinned clean upstream detector')
    sys.path.insert(0, str(repo / 'rtdetrv2_pytorch'))
    from src.core import YAMLConfig
    cfg = YAMLConfig(str(repo / 'rtdetrv2_pytorch/configs/rtdetrv2' / CONFIGS[arch]))
    cfg.yaml_cfg.update(num_classes=classes, remap_mscoco_category=False, eval_spatial_size=[size, size])
    cfg.yaml_cfg['PResNet']['pretrained'] = False
    model = cfg.model
    ck = torch.load(weights, map_location='cpu', weights_only=False)
    src = ck['ema']['module'] if 'ema' in ck else ck['model']
    cur = model.state_dict()
    ok = {k: v for k, v in src.items() if k in cur and v.shape == cur[k].shape}
    missing = [k for k in cur if k not in ok]
    allowed = ('decoder.enc_score_head.', 'decoder.dec_score_head.', 'decoder.denoising_class_embed.', 'decoder.anchors', 'decoder.valid_mask')
    bad = [k for k in missing if not k.startswith(allowed)]
    if bad:
        raise ValueError(f'Unexpected missing parameters: {bad[:10]}')
    model.load_state_dict(ok, strict=False)
    return model, cfg.criterion, missing


def load_rows(spec):
    rows = []
    for src in spec:
        for line in Path(src['path']).read_text().splitlines():
            if not line.strip():
                continue
            r = json.loads(line)
            if src.get('root'):
                r['image'] = str(Path(src['root']) / r['image'])
            r['_weight'] = float(src.get('weight', 1.0)) * (float(src.get('compound_weight', 1.0)) if sum(b['class'] == 0 for b in r['boxes']) > 1 else 1.0)
            r['_source'] = src['name']
            rows.append(r)
    return rows


def gt_to_rows(gts, root):
    rows = []
    for g in gts:
        rows.append({'id': g['id'], 'image': str(Path(root) / g['image']), 'width': g['width'], 'height': g['height'], 'boxes': []})
    return rows


_EVAL = {}


def _eval_one(args):
    t, k = args
    g, p, m = _EVAL['gts'][k], _EVAL['preds'][k], _EVAL['masks'][k]
    cfg = {'threshold': t, 'panel_class': 0, 'complete': True, '_mask': m[1], '_comps': m[2]}
    return E.evaluate_figure(g, P.final_crops(p, m[0], cfg), mask=m[1])


def app_eval(gts, preds, masks, thresholds):
    import multiprocessing as mp
    best = None; table = []
    _EVAL.update(gts=gts, preds=preds, masks=masks)
    with mp.get_context('fork').Pool(16) as pool:
        all_rows = pool.map(_eval_one, [(t, k) for t in thresholds for k in range(len(gts))], chunksize=8)
    for ti, t in enumerate(thresholds):
        rows = all_rows[ti * len(gts):(ti + 1) * len(gts)]
        a = E.aggregate(rows); a['threshold'] = t
        table.append({k: v for k, v in a.items() if k != 'outcomes'} | {'outcomes': a['outcomes']})
        if best is None or a['app_success'] > best['app_success']:
            best = a
    return best, table


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--repo', type=Path, required=True)
    ap.add_argument('--sources', type=Path, required=True, help='JSON list of {name,path,root,weight,compound_weight}')
    ap.add_argument('--val', type=Path, nargs='+', required=True, help='GT JSONL files (evaluate.py format)')
    ap.add_argument('--val-root', type=Path, default=Path('.'))
    ap.add_argument('--weights', type=Path, required=True)
    ap.add_argument('--arch', choices=sorted(CONFIGS), default='r18')
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--epochs', type=int, default=12)
    ap.add_argument('--draws', type=int, default=16000, help='training draws per epoch')
    ap.add_argument('--batch', type=int, default=16)
    ap.add_argument('--workers', type=int, default=12)
    ap.add_argument('--lr', type=float, default=.0002)
    ap.add_argument('--backbone-lr-mult', type=float, default=.1)
    ap.add_argument('--freeze-epochs', type=int, default=1)
    ap.add_argument('--backbone', choices=('frozen', 'last', 'all'), default='all')
    ap.add_argument('--size', type=int, default=640)
    ap.add_argument('--seed', type=int, default=20261021)
    ap.add_argument('--amp', action='store_true')
    ap.add_argument('--jitter', action='store_true')
    ap.add_argument('--max-hours', type=float, default=3)
    ap.add_argument('--patience', type=int, default=5)
    ap.add_argument('--init', type=Path, help='optional fine-tuned checkpoint of the same architecture')
    args = ap.parse_args()
    if args.out.exists():
        raise ValueError('Run directory exists')
    args.out.mkdir(parents=True)
    random.seed(args.seed); np.random.seed(args.seed); torch.manual_seed(args.seed); torch.set_num_threads(4)
    device = torch.device('cuda')
    spec = json.loads(args.sources.read_text())
    train_rows = load_rows(spec)
    vals = []
    for vpath in args.val:
        gts = [json.loads(l) for l in vpath.read_text().splitlines() if l.strip()]
        if any('test' in str(g.get('split', '')) for g in gts):
            raise ValueError('Final-test rows in validation input')
        vals.append((vpath.stem, gts))
    # Paper-level leakage guard against every validation set.
    vpapers = {g['paper'] for _, gts in vals for g in gts}
    leak = [r['id'] for r in train_rows if r.get('paper') in vpapers]
    if leak:
        raise ValueError(f'Training rows from validation papers: {leak[:5]}')
    model, criterion, missing = build_model(args.repo, args.weights, args.arch, len(CLASSES), args.size)
    if args.init:
        st = torch.load(args.init, map_location='cpu', weights_only=False)
        model.load_state_dict(st['model'])
    model.to(device); criterion.to(device)
    meta = {'args': {k: (str(v) if isinstance(v, Path) else [str(x) for x in v] if isinstance(v, list) else v) for k, v in vars(args).items()},
            'started_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'script_sha256': sha(__file__),
            'sources_sha256': sha(args.sources), 'source_files': {s['name']: sha(s['path']) for s in spec},
            'val_sha256': {str(v): sha(v) for v in args.val}, 'weights_sha256': sha(args.weights),
            'upstream_revision': REPO_REVISION, 'classes': CLASSES, 'new_parameters': missing,
            'train_rows': len(train_rows), 'train_by_source': dict(collections.Counter(r['_source'] for r in train_rows)),
            'preprocessing': f'RGB bilinear aspect-fit {args.size} square; white padding; NCHW float32 /255',
            'distribution_allowed': False}
    write_json(args.out / 'provenance.json', meta)
    (args.out / 'training-source.py').write_bytes(Path(__file__).read_bytes())
    for dep in ('policy.py', 'evaluate.py'):
        (args.out / dep).write_bytes((Path(__file__).resolve().parents[1] / 'core' / dep).read_bytes())
    train = Rows(train_rows, augment=True, size=args.size, jitter=args.jitter)
    gen = torch.Generator().manual_seed(args.seed)
    sampler = WeightedRandomSampler([r['_weight'] for r in train_rows], args.draws, replacement=True, generator=gen)
    loader = DataLoader(train, batch_size=args.batch, sampler=sampler, collate_fn=collate, num_workers=args.workers,
                        worker_init_fn=seed_worker, generator=gen, pin_memory=True, drop_last=True, persistent_workers=True)
    val_loaders, val_masks = [], []
    for name, gts in vals:
        ds = Rows(gt_to_rows(gts, args.val_root), size=args.size)
        val_loaders.append(DataLoader(ds, batch_size=32, collate_fn=collate, num_workers=8))
        ms = []
        for g in gts:
            img = np.asarray(load_rgb(Path(args.val_root) / g['image']))
            mk = P.ink_mask(img)
            ms.append((img, mk, P.ink_components(mk)))
        val_masks.append(ms)
    bb, other = [], []
    for n, p in model.named_parameters():
        (bb if n.startswith('backbone.') else other).append(p)
    opt = torch.optim.AdamW([{'params': other, 'lr': args.lr, 'base_lr': args.lr},
                             {'params': bb, 'lr': args.lr * args.backbone_lr_mult, 'base_lr': args.lr * args.backbone_lr_mult}], weight_decay=1e-4)
    ema = copy.deepcopy(model).eval()
    for p in ema.parameters():
        p.requires_grad_(False)
    best, stale, updates, clock = -1., 0, 0, time.monotonic()
    total_steps = args.epochs * (args.draws // args.batch)
    for epoch in range(args.epochs):
        if time.monotonic() - clock > args.max_hours * 3600:
            break
        for n, p in model.backbone.named_parameters():
            on = epoch >= args.freeze_epochs and (args.backbone == 'all' or (args.backbone == 'last' and n.startswith('res_layers.3.')))
            p.requires_grad_(on)
        model.train(); model.backbone.eval()
        t0 = time.monotonic(); losses = []
        for step, (images, targets, _, _) in enumerate(loader):
            g = updates / max(1, total_steps)
            warm = min(1., (updates + 1) / 500)
            factor = warm * (.05 + .95 * (1 + math.cos(math.pi * g)) / 2)
            for pg in opt.param_groups:
                pg['lr'] = pg['base_lr'] * factor
            images = images.to(device, non_blocking=True)
            targets = [{k: v.to(device, non_blocking=True) for k, v in t.items()} for t in targets]
            opt.zero_grad(set_to_none=True)
            with torch.autocast('cuda', dtype=torch.bfloat16, enabled=args.amp):
                out = model(images, targets)

            def fp32(x):
                if isinstance(x, torch.Tensor) and x.is_floating_point():
                    return x.float()
                if isinstance(x, dict):
                    return {k: fp32(v) for k, v in x.items()}
                if isinstance(x, list):
                    return [fp32(v) for v in x]
                return x
            ld = criterion(fp32(out), targets, epoch=epoch, step=step, global_step=updates)
            loss = sum(ld.values())
            if not torch.isfinite(loss):
                raise FloatingPointError('Non-finite loss')
            loss.backward(); torch.nn.utils.clip_grad_norm_(model.parameters(), .1); opt.step()
            updates += 1
            decay = .9999 * (1 - math.exp(-updates / 2000))
            with torch.no_grad():
                ms = model.state_dict()
                for k, v in ema.state_dict().items():
                    if v.is_floating_point():
                        v.mul_(decay).add_(ms[k], alpha=1 - decay)
                    else:
                        v.copy_(ms[k])
            losses.append(float(loss.detach()))
            if step % 200 == 0:
                print(json.dumps({'epoch': epoch, 'step': step, 'loss': round(losses[-1], 4), 'lr': opt.param_groups[0]['lr'],
                                  'vram_gb': round(torch.cuda.max_memory_allocated() / 1e9, 2)}), flush=True)
        train_s = time.monotonic() - t0
        report = {'epoch': epoch, 'loss_mean': float(np.mean(losses)), 'train_seconds': train_s, 'sets': {}}
        scores = []
        for (name, gts), vl, ms in zip(vals, val_loaders, val_masks):
            preds = predict(ema, vl, device)
            best_a, table = app_eval(gts, preds, ms, (.3, .4, .5, .6, .7))
            report['sets'][name] = {'best': {k: v for k, v in best_a.items()}, 'table': table}
            scores.append(best_a['app_success'])
            write_json(args.out / f'pred-{name}-e{epoch:02d}.json', [{'id': g['id'], 'predictions': p} for g, p in zip(gts, preds)])
        score = float(np.mean(scores))
        report['score'] = score
        try:
            vals_ = subprocess.check_output(['nvidia-smi', '--query-gpu=temperature.gpu,power.draw,memory.used,utilization.gpu',
                                             '--format=csv,noheader,nounits'], text=True, timeout=5).strip().split(',')
            report['gpu'] = dict(zip(('temp_c', 'power_w', 'used_mib', 'util'), map(float, vals_)))
            if report['gpu']['temp_c'] >= 85:
                raise RuntimeError('GPU temperature limit')
        except (OSError, subprocess.SubprocessError, ValueError):
            report['gpu'] = None
        with (args.out / 'epochs.jsonl').open('a') as f:
            f.write(json.dumps(report) + '\n')
        print(json.dumps({'epoch': epoch, 'score': round(score, 4), 'loss': round(report['loss_mean'], 4), 'sec': round(train_s),
                          **{n: {k: round(s['best'][k], 4) for k in ('threshold', 'app_success', 'single_false_split_rate', 'compound_perfect_rate', 'panel_recall', 'complete_panel_rate')}
                             for n, s in report['sets'].items()}}), flush=True)
        torch.save({'model': ema.state_dict(), 'epoch': epoch, 'meta': meta}, args.out / f'ema-e{epoch:02d}.pth')
        if score > best:
            best, stale = score, 0
            torch.save({'model': ema.state_dict(), 'epoch': epoch, 'meta': meta}, args.out / 'best.pth')
            write_json(args.out / 'best.json', report)
        else:
            stale += 1
            if stale >= args.patience:
                break
    write_json(args.out / 'completion.json', {'finished_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                                              'elapsed_seconds': time.monotonic() - clock, 'best_score': best,
                                              'peak_vram_bytes': torch.cuda.max_memory_allocated()})


if __name__ == '__main__':
    main()
