#!/usr/bin/env python3
"""Evaluate ink grouping on a GT set with the app metric (same as evaluate.py / final_eval.py)."""
import argparse, json, multiprocessing as mp, pickle
from pathlib import Path

import numpy as np
from PIL import Image

from sfd.core import evaluate as E
from sfd.group import features as F
from sfd.group import group as G

_S = {}


class Wrapped:
    def __init__(self, blob):
        self.m, self.cols = blob['model'], blob['cols']

    def predict_proba(self, X):
        if len(X) == 0:
            return np.zeros((0, 2))
        return self.m.predict_proba(X[:, self.cols])


def one(g):
    img = np.asarray(Image.open(g['image']).convert('RGB'))
    mask = F.ink_mask(img)
    det = _S['det'].get(g['id']) if _S['det'] is not None else None
    crops = G.group_figure(img, _S['model'], det, g.get('caption_letters') if _S['caption'] else (),
                           thr=_S['thr'], floor=_S['floor'], panel_ink=_S['panel_ink'], mask=mask, split=_S['split'])
    r = E.evaluate_figure(g, crops, mask=mask)
    r['crops'] = [[round(v, 1) for v in c] for c in crops]
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gt', type=Path, required=True)
    ap.add_argument('--model', type=Path, required=True)
    ap.add_argument('--det', type=Path)
    ap.add_argument('--caption', action='store_true')
    ap.add_argument('--thr', type=float, default=.5)
    ap.add_argument('--floor', type=float, default=.15)
    ap.add_argument('--panel-ink', type=float, default=.04)
    ap.add_argument('--classes', type=Path)
    ap.add_argument('--split', action='store_true')
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--bootstrap', type=int, default=2000)
    ap.add_argument('--workers', type=int, default=16)
    ap.add_argument('--acknowledge-final-test', action='store_true')
    args = ap.parse_args()
    gts = [json.loads(l) for l in args.gt.read_text().splitlines() if l.strip()]
    if any(g.get('split') == 'test' for g in gts) and not args.acknowledge_final_test:
        raise SystemExit('final test requires --acknowledge-final-test')
    _S.update(model=Wrapped(pickle.loads(args.model.read_bytes())), caption=args.caption, thr=args.thr, floor=args.floor,
              panel_ink=args.panel_ink, split=args.split,
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
    s['config'] = {k: str(v) for k, v in vars(args).items()}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({'summary': s, 'figures': rows}, indent=1))
    print(json.dumps({k: round(s[k], 4) for k in ('app_success', 'harmful_rate', 'single_false_split_rate', 'compound_perfect_rate',
                                                  'panel_recall', 'complete_panel_rate', 'crop_precision', 'compound_groupable_rate')}))


if __name__ == '__main__':
    main()
