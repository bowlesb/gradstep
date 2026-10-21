#!/usr/bin/env python3
"""Pairwise training data for the ink-grouping model.

Each training row (exact panel boxes from vector drawing operations, letter groups, synthetic layouts) is
decomposed into components; a component's truth is the panel box holding >= 90% of its ink pixels, 'shared'
if a shared box holds them, otherwise ambiguous (dropped). Positive pairs: same panel; negatives: different
panels or panel vs shared. Optional detector predictions supply the prior features.
"""
import argparse, json, multiprocessing as mp, random
from pathlib import Path

import numpy as np
from PIL import Image

from sfd.group import features as F

Image.MAX_IMAGE_PIXELS = 200_000_000


def comp_truth(comps, lab, panels, shared):
    H, W = lab.shape
    owner = np.full((H, W), -1, np.int32)
    for k, b in enumerate(shared):
        x0, y0, x1, y1 = [int(round(v)) for v in b]
        owner[max(0, y0):y1, max(0, x0):x1] = -2
    for k, b in enumerate(panels):
        x0, y0, x1, y1 = [int(round(v)) for v in b]
        owner[max(0, y0):y1, max(0, x0):x1] = np.where(owner[max(0, y0):y1, max(0, x0):x1] >= 0, -3, k)  # -3: overlap
    out = []
    for c in comps:
        x0, y0, x1, y1 = [int(v) for v in c['box']]
        sub = lab[y0:y1, x0:x1] == c['label']
        own = owner[y0:y1, x0:x1][sub]
        vals, cnt = np.unique(own, return_counts=True)
        k = int(np.argmax(cnt))
        if cnt[k] >= 0.9 * own.size and vals[k] >= 0:
            out.append(int(vals[k]))
        elif cnt[k] >= 0.9 * own.size and vals[k] == -2:
            out.append(-2)
        else:
            out.append(-1)
    return out


SPLIT = False


def one(task):
    row, det = task
    try:
        img = np.asarray(Image.open(row['image']).convert('RGB'))
    except Exception:
        return None
    mask = F.ink_mask(img)
    sb = None
    if SPLIT and det:
        from sfd.core import policy as Pc
        sb = [b['box'] for b in Pc.suppress([p for p in det if p['class'] == 0 and p['score'] >= .5])]
        sb = [b for b in sb if (b[2] - b[0]) * (b[3] - b[1]) < .85 * mask.shape[0] * mask.shape[1]] or None
    comps, lab = F.components(img, mask, split_boxes=sb)
    if len(comps) < 2 or len(comps) > F.N_COMP_MAX:
        return None
    panels = [b['box'] for b in row['boxes'] if b['class'] == 0]
    shared = [b['box'] for b in row['boxes'] if b['class'] == 1]
    truth = comp_truth(comps, lab, panels, shared)
    pairs = F.candidate_pairs(comps)
    keep = [(i, j) for i, j in pairs if truth[i] != -1 and truth[j] != -1 and not (truth[i] == -2 and truth[j] == -2)]
    if not keep:
        return None
    dboxes = [p['box'] for p in (det or []) if p['class'] == 0 and p['score'] >= .3]
    da = F.det_assign(comps, dboxes) if det is not None else None
    X = F.pair_features(comps, keep, mask, det=da, n_det=len(dboxes))
    y = np.array([1 if truth[i] == truth[j] and truth[i] >= 0 else 0 for i, j in keep], np.int8)
    return row['id'], row.get('source', ''), X, y


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sources', type=Path, required=True, help='JSON list of {path, n, name}')
    ap.add_argument('--det', type=Path, help='detector predictions JSON for these rows (prior features)')
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--workers', type=int, default=20)
    ap.add_argument('--seed', type=int, default=20261023)
    ap.add_argument('--split', action='store_true', help='cut components across detector boxes (as at inference)')
    args = ap.parse_args()
    global SPLIT
    SPLIT = args.split
    rng = random.Random(args.seed)
    rows = []
    for s in json.loads(args.sources.read_text()):
        rr = [json.loads(l) for l in Path(s['path']).read_text().splitlines() if l.strip()]
        rng.shuffle(rr)
        for r in rr[:s.get('n', len(rr))]:
            r['source'] = r.get('source') or s['name']; rows.append(r)
    det = {}
    if args.det:
        det = {r['id']: r['predictions'] for r in json.loads(args.det.read_text())}
    tasks = [(r, det.get(r['id']) if args.det else None) for r in rows]
    Xs, ys, ids, srcs = [], [], [], []
    with mp.Pool(args.workers, maxtasksperchild=200) as pool:
        for res in pool.imap_unordered(one, tasks, chunksize=8):
            if res is None:
                continue
            fid, src, X, y = res
            Xs.append(X); ys.append(y); ids += [fid] * len(y); srcs += [src] * len(y)
    X = np.concatenate(Xs); y = np.concatenate(ys)
    args.out.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(args.out / 'pairs.npz', X=X, y=y, ids=np.array(ids), src=np.array(srcs))
    print(json.dumps({'figures': len(Xs), 'pairs': int(len(y)), 'positive': int(y.sum())}))


if __name__ == '__main__':
    main()
