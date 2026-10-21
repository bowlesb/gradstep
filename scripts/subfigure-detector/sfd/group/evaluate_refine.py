#!/usr/bin/env python3
"""Evaluate seeded grouping: the detector policy's crops (final_eval output) rebuilt from whole components."""
import argparse, json, multiprocessing as mp, pickle
from pathlib import Path

import numpy as np
from PIL import Image

from sfd.core import evaluate as E
from sfd.group import features as F
from sfd.group import group as G
from sfd.group.evaluate_grouping import Wrapped

_S = {}


def one(g):
    img = np.asarray(Image.open(g['image']).convert('RGB'))
    mask = F.ink_mask(img)
    crops = _S['crops'].get(g['id'], [])
    det = _S['det'].get(g['id']) if _S['det'] is not None else None
    if len(crops) >= 2:
        crops = (G.attach_orphans if _S['mode'] == 'orphans' else G.refine_crops)(img, _S['model'], crops, det, mask)
    r = E.evaluate_figure(g, crops, mask=mask)
    r['crops'] = [[round(v, 1) for v in c] for c in crops]
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gt', type=Path, required=True)
    ap.add_argument('--rows', type=Path, required=True, help='final_eval output whose crops are the seeds')
    ap.add_argument('--model', type=Path, required=True)
    ap.add_argument('--det', type=Path)
    ap.add_argument('--classes', type=Path)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--workers', type=int, default=16)
    ap.add_argument('--bootstrap', type=int, default=2000)
    ap.add_argument('--mode', choices=['orphans', 'reseed'], default='orphans')
    args = ap.parse_args()
    gts = [json.loads(l) for l in args.gt.read_text().splitlines() if l.strip()]
    _S.update(mode=args.mode, model=Wrapped(pickle.loads(args.model.read_bytes())),
              crops={r['id']: r['crops'] for r in json.loads(args.rows.read_text())['figures']},
              det={r['id']: r['predictions'] for r in json.loads(args.det.read_text())} if args.det else None)
    with mp.get_context('fork').Pool(args.workers) as pool:
        rows = pool.map(one, gts, chunksize=4)
    s = E.aggregate(rows)
    if args.bootstrap:
        s['ci95'] = E.bootstrap(rows, E.KEYS, args.bootstrap)
    from sfd.annotate import classes as CL
    cls = json.loads(args.classes.read_text()) if args.classes else {g['id']: CL.tag(g) for g in gts}
    for v in sorted(set(cls.values())):
        sub = [r for r, g in zip(rows, gts) if cls.get(g['id']) == v]
        if sub:
            s.setdefault('by_class', {})[v] = E.aggregate(sub)
    args.out.write_text(json.dumps({'summary': s, 'figures': rows}, indent=1))
    print(json.dumps({k: round(s[k], 4) for k in ('app_success', 'harmful_rate', 'single_false_split_rate', 'compound_perfect_rate',
                                                  'panel_recall', 'complete_panel_rate', 'crop_precision')}), s['outcomes'])


if __name__ == '__main__':
    main()
