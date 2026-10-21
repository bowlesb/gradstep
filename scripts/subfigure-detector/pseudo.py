#!/usr/bin/env python3
"""Teacher-student pseudo-labels with agreement filtering (training split only).

Inputs: two prediction files from the same teacher on the same unlabeled rows under different
placements (e.g. zoom 1.0 and 0.75), plus the rows (with caption letters). A figure becomes a
pseudo-labelled training row only when, after the app policy (incl. completion):
  * both views give the same number of crops and every crop matches across views at IoU >= .85;
  * if the caption names k >= 2 letters, the crop count equals k; unlettered splits need panel scores
    >= .85; an unlettered whole figure needs a confident (>= .85) whole-figure box (pseudo single);
  * every kept panel's minimum detector score >= --min-score in both views.
The kept boxes are the completed crops of view 1. No validation/test paper is accepted.
"""
import argparse, json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.optimize import linear_sum_assignment

import policy as P

Image.MAX_IMAGE_PIXELS = 200_000_000


_G = {}


def one(fid):
    args, r, pa, pb = _G['args'], _G['rows'][fid], _G['pa'], _G['pb']
    img = np.asarray(Image.open(r['image']).convert('RGB'))
    m = P.ink_mask(img)
    comps = P.ink_components(m)
    cfg = {'threshold': args.threshold, 'panel_class': 0, 'complete': True, '_mask': m, '_comps': comps}
    ca = P.final_crops(pa.get(fid, []), img, cfg)
    cb = P.final_crops(pb.get(fid, []), img, cfg)
    L = len(r.get('caption_letters') or [])
    if len(ca) != len(cb):
        return 'view_count_disagree', None
    if len(ca) >= 2:
        M = np.array([[P.iou(a, b) for b in cb] for a in ca])
        i, j = linear_sum_assignment(-M)
        if (M[i, j] < .85).any():
            return 'view_box_disagree', None
        if L >= 2 and L != len(ca):
            return 'caption_count_disagree', None
        sa = [p['score'] for p in pa[fid] if p['class'] == 0 and p['score'] >= args.threshold]
        need = args.min_score if L >= 2 else max(args.min_score, .85)
        if min(sorted(sa, reverse=True)[:len(ca)]) < need:
            return 'low_score', None
        boxes = [{'box': b, 'class': 0} for b in ca]
        kind = 'pseudo_compound'
    else:
        if L >= 2:
            return 'lettered_but_whole', None
        H, W = img.shape[:2]
        whole = [p['score'] for p in pa.get(fid, []) if p['class'] == 0 and P.area(p['box']) >= .8 * W * H]
        if not whole or max(whole) < .85:
            return 'unconfident_whole', None
        ys, xs = np.nonzero(m)
        if not len(xs):
            return 'blank', None
        boxes = [{'box': [float(xs.min()), float(ys.min()), float(xs.max() + 1), float(ys.max() + 1)], 'class': 0}]
        kind = 'pseudo_single'
    return kind, {'id': fid, 'image': r['image'], 'width': int(img.shape[1]), 'height': int(img.shape[0]), 'paper': r['paper'],
                  'source': 'pseudo-compound' if len(boxes) > 1 else 'pseudo-single', 'boxes': boxes}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rows', type=Path, required=True)
    ap.add_argument('--pred-a', type=Path, required=True)
    ap.add_argument('--pred-b', type=Path, required=True)
    ap.add_argument('--split', type=Path, required=True)
    ap.add_argument('--threshold', type=float, default=.6)
    ap.add_argument('--min-score', type=float, default=.75)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--workers', type=int, default=24)
    args = ap.parse_args()
    split = json.loads(args.split.read_text())['split']
    rows = {json.loads(l)['id']: json.loads(l) for l in args.rows.read_text().splitlines() if l.strip()}
    pa = {r['id']: r['predictions'] for r in json.loads(args.pred_a.read_text())}
    pb = {r['id']: r['predictions'] for r in json.loads(args.pred_b.read_text())}
    import multiprocessing as mp
    keep = [fid for fid, r in rows.items() if split.get(r['paper']) == 'train']
    _G.update(args=args, rows=rows, pa=pa, pb=pb)
    out, stats = [], {'not_train': len(rows) - len(keep)}
    with mp.get_context('fork').Pool(args.workers) as pool:
        for kind, row in pool.imap_unordered(one, keep, chunksize=16):
            stats[kind] = stats.get(kind, 0) + 1
            if row:
                out.append(row)
    args.out.write_text(''.join(json.dumps(o) + '\n' for o in out))
    print(json.dumps(stats))


if __name__ == '__main__':
    main()
