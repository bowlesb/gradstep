#!/usr/bin/env python3
"""Weighted box fusion of several prediction files for the same rows (validation selection only).

Boxes of the same class from different models are clustered greedily by IoU >= --iou (highest score
first); a cluster's box is the score-weighted mean, its score the summed score divided by the number of
models (so a box found by one of three models is down-weighted to a third).
"""
import argparse, json
from pathlib import Path

import numpy as np


def iou(a, b):
    x0, y0, x1, y1 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    i = max(0, x1 - x0) * max(0, y1 - y0)
    return i / max(1e-9, (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i)


def fuse(lists, thr, min_score=.1):
    n = len(lists)
    allp = sorted([dict(p, m=k) for k, ps in enumerate(lists) for p in ps if p['score'] >= min_score], key=lambda p: -p['score'])
    clusters = []
    for p in allp:
        for c in clusters:
            if c['class'] == p['class'] and iou(c['box'], p['box']) >= thr and p['m'] not in c['models']:
                c['members'].append(p); c['models'].add(p['m'])
                w = np.array([q['score'] for q in c['members']])
                c['box'] = list((np.array([q['box'] for q in c['members']]) * w[:, None]).sum(0) / w.sum())
                break
        else:
            clusters.append({'class': p['class'], 'box': list(p['box']), 'members': [p], 'models': {p['m']}})
    return [{'class': c['class'], 'box': [float(v) for v in c['box']], 'score': float(sum(q['score'] for q in c['members']) / n)} for c in clusters]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('preds', nargs='+', type=Path)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--iou', type=float, default=.6)
    args = ap.parse_args()
    sets = [{r['id']: r['predictions'] for r in json.loads(p.read_text())} for p in args.preds]
    ids = list(sets[0])
    args.out.write_text(json.dumps([{'id': i, 'predictions': fuse([s.get(i, []) for s in sets], args.iou)} for i in ids]))
    print('fused', len(ids), 'from', len(sets))


if __name__ == '__main__':
    main()
