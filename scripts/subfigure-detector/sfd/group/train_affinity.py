#!/usr/bin/env python3
"""Train the pairwise same-panel classifier (histogram gradient boosting) on build.py output.

Figures are split 90/10 by id for an internal check; the model is saved with pickle together with the feature
list, so ports can verify the feature order. Variants: --no-det drops the detector-prior features.
"""
import argparse, json, pickle, time
from pathlib import Path

import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import roc_auc_score

from sfd.group import features as F


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pairs', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--no-det', action='store_true')
    ap.add_argument('--max-iter', type=int, default=400)
    ap.add_argument('--seed', type=int, default=20261023)
    args = ap.parse_args()
    d = np.load(args.pairs)
    X, y, ids = d['X'], d['y'], d['ids']
    cols = [k for k, f in enumerate(F.FEATURES) if not (args.no_det and f.startswith('det_'))]
    X = X[:, cols]
    u = np.unique(ids)
    rng = np.random.default_rng(args.seed)
    held = set(rng.choice(u, size=max(1, len(u) // 10), replace=False))
    te = np.array([i in held for i in ids])
    t0 = time.time()
    m = HistGradientBoostingClassifier(max_iter=args.max_iter, learning_rate=.1, max_leaf_nodes=63, l2_regularization=1.0,
                                       random_state=args.seed, early_stopping=True, validation_fraction=.05)
    m.fit(X[~te], y[~te])
    p = m.predict_proba(X[te])[:, 1]
    rep = {'pairs_train': int((~te).sum()), 'pairs_heldout': int(te.sum()), 'auc_heldout': float(roc_auc_score(y[te], p)),
           'acc_heldout': float(((p >= .5) == y[te]).mean()), 'seconds': time.time() - t0, 'iterations': int(m.n_iter_),
           'features': [F.FEATURES[k] for k in cols]}

    class Model:
        pass
    args.out.mkdir(parents=True, exist_ok=True)
    blob = {'model': m, 'cols': cols, 'features': [F.FEATURES[k] for k in cols]}
    (args.out / 'affinity.pkl').write_bytes(pickle.dumps(blob))
    rep['bytes'] = (args.out / 'affinity.pkl').stat().st_size
    (args.out / 'train-report.json').write_text(json.dumps(rep, indent=1))
    print(json.dumps(rep))


if __name__ == '__main__':
    main()
