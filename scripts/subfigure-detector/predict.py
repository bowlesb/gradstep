#!/usr/bin/env python3
"""Run a saved detector checkpoint over GT rows and write raw predictions (JSON list of {id, predictions}).

Works for this project's 2-class checkpoints and the earlier 5-class ones (`--classes 5`, panel class 4).
Optional test-time augmentation (`--tta`): original + 0.8x zoom-out placement; boxes from both are kept
for downstream fusion/agreement. Never used to select on the final test.
"""
import argparse, json, sys
from pathlib import Path

import torch
from torch.utils.data import DataLoader

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train2 as T


class Placed(T.Rows):
    def __init__(self, rows, size, zoom, position):
        super().__init__(rows, size=size); self.zoom, self.position = zoom, position

    def __getitem__(self, i):
        row = self.rows[i]
        image = T.load_rgb(row['image'])
        image, tr = T.letterbox(image, self.size, self.zoom, self.position)
        data = torch.from_numpy(T.np.asarray(image, dtype=T.np.float32).transpose(2, 0, 1).copy() / 255.)
        return data, {'boxes': torch.zeros(0, 4), 'labels': torch.zeros(0, dtype=torch.int64)}, i, tr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', type=Path, required=True)
    ap.add_argument('--checkpoint', type=Path, required=True)
    ap.add_argument('--base', type=Path, required=True, help='architecture base weights (only for model construction)')
    ap.add_argument('--arch', default='r18')
    ap.add_argument('--classes', type=int, default=2)
    ap.add_argument('--gt', type=Path, required=True)
    ap.add_argument('--root', type=Path, default=Path('.'))
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--size', type=int, default=640)
    ap.add_argument('--zoom', type=float, default=1.0)
    ap.add_argument('--min-score', type=float, default=.03)
    ap.add_argument('--cpu', action='store_true')
    args = ap.parse_args()
    gts = [json.loads(l) for l in args.gt.read_text().splitlines() if l.strip()]
    rows = [{'id': g['id'], 'image': str(args.root / g['image']), 'width': g['width'], 'height': g['height'], 'boxes': []} for g in gts]
    model, _, _ = T.build_model(args.repo, args.base, args.arch, args.classes, args.size)
    st = torch.load(args.checkpoint, map_location='cpu', weights_only=False)
    sd = st['model'] if 'model' in st else st['ema']['module']
    sd = {k: v for k, v in sd.items() if k not in ('decoder.anchors', 'decoder.valid_mask')}
    missing, unexpected = model.load_state_dict(sd, strict=False)
    bad = [k for k in missing if k not in ('decoder.anchors', 'decoder.valid_mask')]
    if bad or unexpected:
        raise ValueError(f'checkpoint mismatch {bad[:5]} {unexpected[:5]}')
    dev = torch.device('cpu' if args.cpu else 'cuda')
    model.to(dev).eval()
    ds = Placed(rows, args.size, args.zoom, (.5, .5))
    preds = T.predict(model, DataLoader(ds, batch_size=32, collate_fn=T.collate, num_workers=8), dev, args.min_score)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps([{'id': r['id'], 'predictions': p} for r, p in zip(rows, preds)]))
    print('wrote', len(preds))


if __name__ == '__main__':
    main()
