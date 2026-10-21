#!/usr/bin/env python3
"""Simulated check of the completeness post-processor on imprecise *model-written* boxes.

No language model is called. For each validation compound figure, every ground-truth panel box is
perturbed the way generated coordinates typically fail (edges pulled inward or pushed outward by a few
percent of the panel, small shifts). The perturbed boxes are scored as delivered (2% display margin)
with and without `policy.complete`, so the effect of the geometry check on clipped crops and on the
all-pixels coverage invariant can be measured. This is a simulation, not evidence about any model.
"""
import argparse, json, random

import numpy as np

import evaluate as E
import policy as P
import sweep as SW


def perturb(b, W, H, rng, inward, outward):
    w, h = b[2] - b[0], b[3] - b[1]
    out = []
    for k, (v, size) in enumerate(zip(b, (w, h, w, h))):
        sign = -1 if k < 2 else 1   # outward direction for this edge
        if rng.random() < 0.5:
            d = -sign * rng.uniform(0, inward) * size   # clip inward
        else:
            d = sign * rng.uniform(0, outward) * size   # loose outward
        out.append(v + d)
    return [max(0, out[0]), max(0, out[1]), min(W, out[2]), min(H, out[3])]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gt', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--seeds', type=int, default=3)
    args = ap.parse_args()
    gts, cache = SW.load_set(args.gt, '.')
    res = {}
    for level, (inward, outward) in {'mild': (.03, .03), 'moderate': (.06, .04), 'severe': (.12, .06)}.items():
        for mode in ('raw', 'completed'):
            rows = []
            for seed in range(args.seeds):
                rng = random.Random(seed)
                for g, (img, m, comps) in zip(gts, cache):
                    if len(g['panels']) < 2:
                        continue
                    H, W = m.shape
                    boxes = [perturb(b, W, H, rng, inward, outward) for b in g['panels']]
                    if mode == 'completed':
                        boxes = P.complete(boxes, m, comps)
                    r = E.evaluate_figure(dict(g, paper=f"{g['paper']}#{seed}"), boxes, mask=m)
                    rows.append(r)
            a = E.aggregate(rows)
            res[f'{level}-{mode}'] = {k: a[k] for k in ('compound_perfect_rate', 'complete_panel_rate', 'complete_given_matched', 'panel_recall', 'crop_precision', 'full_coverage_rate_when_split')}
            print(level, mode, json.dumps({k: round(v, 4) for k, v in res[f'{level}-{mode}'].items()}), flush=True)
    json.dump(res, open(args.out, 'w'), indent=1)


if __name__ == '__main__':
    main()
