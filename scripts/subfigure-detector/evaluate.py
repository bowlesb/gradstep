#!/usr/bin/env python3
"""App-level evaluation of figure splitting: complete crops, no false splits, correct counts.

Ground truth per figure: `panels` (complete panel boxes incl. letters/ticks/labels/own legend)
and optional `shared` boxes (context serving several panels). Predictions are the final crops
the app would show (after policy), measured *as displayed* (2% margin, outward rounding).

A crop matches a panel when it holds >=90% of that panel's own ink and that panel dominates the
crop's non-shared ink (>=60%); so a whole-figure crop cannot match several panels. A matched
panel is complete when its displayed crop holds >=99.5% of its own ink pixels (ink inside its box and
no other panel's box: overlapping annotation zones are required of neither neighbour).
Paper-level bootstrap gives 95% intervals.
"""
import argparse, collections, json, math, random
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.optimize import linear_sum_assignment

import policy as P

Image.MAX_IMAGE_PIXELS = 200_000_000


def integral(mask):
    return np.pad(mask.astype(np.int64).cumsum(0).cumsum(1), ((1, 0), (1, 0)))


def ink_in(ii, b):
    x0, y0, x1, y1 = [int(round(v)) for v in b]
    H, W = ii.shape[0] - 1, ii.shape[1] - 1
    x0, x1 = max(0, min(W, x0)), max(0, min(W, x1)); y0, y1 = max(0, min(H, y0)), max(0, min(H, y1))
    if x1 <= x0 or y1 <= y0:
        return 0
    return int(ii[y1, x1] - ii[y0, x1] - ii[y1, x0] + ii[y0, x0])


def evaluate_figure(gt, crops, img=None, mask=None):
    if mask is None:
        mask = P.ink_mask(img)
    H, W = mask.shape
    ii = integral(mask)
    panels = gt['panels']
    shared = gt.get('shared') or []
    n = len(panels)
    disp = [P.display_box(c, W, H) for c in crops]
    split = len(disp) >= 2
    out = {'id': gt['id'], 'paper': gt['paper'], 'n_gt': n, 'n_crops': len(disp) if split else 0,
           'compound': n >= 2, 'stratum': gt.get('stratum'), 'source': gt.get('source')}
    if n < 2:
        out['outcome'] = 'correct_whole' if not split else 'false_split'
        out['false_crops'] = len(disp) if split else 0
        return out
    if not split:
        out.update(outcome='not_split', matched=0, complete=0, false_crops=0, coverage=None)
        return out
    # Exclusive ink: where annotated panel boxes overlap (touching panels, a long title over a neighbour's
    # label), that ink is not required of either crop; completeness is measured on each panel's own ink.
    cover = np.zeros(mask.shape, np.int16)
    boxes_px = []
    for p in panels:
        x0, y0, x1, y1 = [int(round(v)) for v in p]
        x0, y0 = max(0, x0), max(0, y0); x1, y1 = min(W, x1), min(H, y1)
        boxes_px.append((x0, y0, x1, y1))
        cover[y0:y1, x0:x1] += 1
    excl = []
    for (x0, y0, x1, y1) in boxes_px:
        e = np.zeros_like(mask)
        e[y0:y1, x0:x1] = mask[y0:y1, x0:x1] & (cover[y0:y1, x0:x1] == 1)
        excl.append(integral(e))
    pin = [max(1, ink_in(e, [0, 0, W, H])) for e in excl]
    comp = np.zeros((n, len(disp)))
    dom = np.zeros((n, len(disp)))
    for j, c in enumerate(disp):
        # Ink of the crop excluding shared context (a crop may legitimately carry a shared legend).
        cin = ink_in(ii, c)
        sh = sum(ink_in(ii, P.inter(c, s)) for s in shared) if shared else 0
        denom = max(1, cin - sh)
        for i, p in enumerate(panels):
            comp[i, j] = ink_in(excl[i], c) / pin[i]
            dom[i, j] = ink_in(ii, P.inter(c, p)) / denom
    ok = (comp >= 0.9) & (dom >= 0.6)
    score = ok * 10 + comp
    r, c = linear_sum_assignment(-score)
    pairs = [(i, j) for i, j in zip(r, c) if ok[i, j]]
    matched = len(pairs)
    complete = sum(1 for i, j in pairs if comp[i, j] >= 0.995)
    false = len(disp) - matched
    # Coverage of all ink by the union of displayed crops (the app's all-pixels invariant).
    cov = np.zeros_like(mask)
    for x0, y0, x1, y1 in disp:
        cov[y0:y1, x0:x1] = True
    total = max(1, int(mask.sum()))
    out.update(matched=matched, complete=complete, false_crops=false, coverage=float((mask & cov).sum() / total),
               completeness=[float(comp[i, j]) for i, j in pairs])
    merged = any(((comp[:, j] >= 0.9).sum() >= 2) for j in range(len(disp)))
    if matched == n and complete == n and false == 0:
        out['outcome'] = 'perfect'
    elif merged:
        out['outcome'] = 'merged_panels'
    elif matched == n and false == 0:
        out['outcome'] = 'clipped'
    elif len(disp) > n:
        out['outcome'] = 'extra_crops'
    elif len(disp) < n:
        out['outcome'] = 'missed_panels'
    else:
        out['outcome'] = 'wrong_boxes'
    return out


def aggregate(rows):
    singles = [r for r in rows if not r['compound']]
    comps = [r for r in rows if r['compound']]
    gt_panels = sum(r['n_gt'] for r in comps)
    split_comps = [r for r in comps if r['n_crops'] >= 2]
    a = {
        'figures': len(rows), 'singles': len(singles), 'compounds': len(comps), 'gt_panels': gt_panels,
        'app_success': (sum(r['outcome'] == 'correct_whole' for r in singles) + sum(r['outcome'] == 'perfect' for r in comps)) / max(1, len(rows)),
        'single_false_split_rate': sum(r['outcome'] == 'false_split' for r in singles) / max(1, len(singles)),
        'compound_split_rate': len(split_comps) / max(1, len(comps)),
        'compound_perfect_rate': sum(r['outcome'] == 'perfect' for r in comps) / max(1, len(comps)),
        'compound_count_correct': sum(r['n_crops'] == r['n_gt'] for r in comps) / max(1, len(comps)),
        'panel_recall': sum(r.get('matched', 0) for r in comps) / max(1, gt_panels),
        'complete_panel_rate': sum(r.get('complete', 0) for r in comps) / max(1, gt_panels),
        'complete_given_matched': sum(r.get('complete', 0) for r in comps) / max(1, sum(r.get('matched', 0) for r in comps)),
        'crop_precision': sum(r.get('matched', 0) for r in comps) / max(1, sum(r['n_crops'] for r in comps)),
        'false_crops_total': sum(r.get('false_crops', 0) for r in rows),
        # Delivered-but-wrong: the app would show crops that are not the figure's complete panels (a kept-whole
        # figure is a safe miss: the reader still sees everything). Lower is better.
        'harmful_rate': sum(r['outcome'] in ('false_split', 'clipped', 'extra_crops', 'merged_panels', 'missed_panels', 'wrong_boxes') for r in rows) / max(1, len(rows)),
        'kept_whole_compound_rate': sum(r['outcome'] == 'not_split' for r in comps) / max(1, len(comps)),
        'full_coverage_rate_when_split': (sum(1 for r in split_comps if (r.get('coverage') or 0) >= 0.999) / max(1, len(split_comps))),
        'outcomes': dict(collections.Counter(r['outcome'] for r in rows)),
    }
    return a


def bootstrap(rows, keys, n=2000, seed=0):
    by = collections.defaultdict(list)
    for r in rows:
        by[r['paper']].append(r)
    papers = list(by)
    rng = random.Random(seed)
    samples = collections.defaultdict(list)
    for _ in range(n):
        pick = [x for _ in papers for x in by[papers[rng.randrange(len(papers))]]]
        a = aggregate(pick)
        for k in keys:
            samples[k].append(a[k])
    return {k: [float(np.percentile(v, 2.5)), float(np.percentile(v, 97.5))] for k, v in samples.items()}


KEYS = ['app_success', 'harmful_rate', 'single_false_split_rate', 'compound_split_rate', 'compound_perfect_rate', 'compound_count_correct',
        'panel_recall', 'complete_panel_rate', 'crop_precision']


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gt', type=Path, required=True)
    ap.add_argument('--pred', type=Path, required=True, help='JSONL {id, predictions:[{class,score,box}]} (raw detector)')
    ap.add_argument('--policy', type=str, default='{}', help='JSON policy config for policy.final_crops')
    ap.add_argument('--gate', type=Path, help='optional JSON {id: compound_probability}')
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--root', type=Path, default=Path('.'))
    ap.add_argument('--bootstrap', type=int, default=2000)
    args = ap.parse_args()
    cfg = json.loads(args.policy)
    gts = [json.loads(l) for l in args.gt.read_text().splitlines() if l.strip()]
    if args.pred.suffix == '.json':
        preds = {r['id']: r['predictions'] for r in json.loads(args.pred.read_text())}
    else:
        preds = {json.loads(l)['id']: json.loads(l)['predictions'] for l in args.pred.read_text().splitlines() if l.strip()}
    gates = json.loads(args.gate.read_text()) if args.gate else {}
    rows = []
    for g in gts:
        img = np.asarray(Image.open(args.root / g['image']).convert('RGB'))
        c = dict(cfg)
        if g['id'] in gates:
            c['gate'] = gates[g['id']]
        crops = P.final_crops(preds.get(g['id'], []), img, c)
        r = evaluate_figure(g, crops, img)
        r['crops'] = [[round(v, 1) for v in b] for b in crops]
        rows.append(r)
    summary = aggregate(rows)
    summary['ci95'] = bootstrap(rows, KEYS, args.bootstrap) if args.bootstrap else {}
    summary['policy'] = cfg
    for stratum in sorted(set(r.get('stratum') or '' for r in rows)):
        sub = [r for r in rows if (r.get('stratum') or '') == stratum]
        summary.setdefault('by_stratum', {})[stratum or 'none'] = {k: v for k, v in aggregate(sub).items() if k != 'outcomes'} | {'outcomes': aggregate(sub)['outcomes']}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({'summary': summary, 'figures': rows}, indent=1))
    brief = {k: round(summary[k], 4) for k in KEYS}
    print(json.dumps(brief))


if __name__ == '__main__':
    main()
