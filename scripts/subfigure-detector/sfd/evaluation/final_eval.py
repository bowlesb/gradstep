#!/usr/bin/env python3
"""Evaluate one frozen system (prediction files + policy) on one GT set, with paper-level bootstrap CIs.

The system is fixed in a JSON file: {"name", "policy": {...}, "agree_iou": .7 | null}. Prediction files
must already exist for this GT set (predict.py; view B optional). A GT file whose rows carry
split == "test" requires --acknowledge-final-test, and the result is written once (no overwrite).
"""
import argparse, json
from pathlib import Path

from sfd.core import evaluate as E
from sfd.evaluation import sweep as SW


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--system', type=Path, required=True)
    ap.add_argument('--gt', type=Path, required=True)
    ap.add_argument('--pred', type=Path, required=True)
    ap.add_argument('--pred-b', type=Path)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--acknowledge-final-test', action='store_true')
    ap.add_argument('--bootstrap', type=int, default=5000)
    ap.add_argument('--ocr', type=Path, help='OCR text lines per figure (needed when the system uses letter_group)')
    ap.add_argument('--classes', type=Path, help='optional {figure_id: failure class} map')
    args = ap.parse_args()
    system = json.loads(args.system.read_text())
    gts, cache = SW.load_set(args.gt, '.')
    if any(g.get('split') == 'test' for g in gts):
        if not args.acknowledge_final_test:
            raise SystemExit('Final test requires --acknowledge-final-test')
        if args.out.exists():
            raise SystemExit('Final-test result already exists; the final test is scored once')
    preds = {r['id']: r['predictions'] for r in json.loads(args.pred.read_text())}
    preds_b = {r['id']: r['predictions'] for r in json.loads(args.pred_b.read_text())} if args.pred_b else None
    cfg = dict(system['policy'])
    if system.get('agree_iou'):
        cfg['agree_iou'] = system['agree_iou']
    rows = SW.run(gts, cache, preds, cfg, None, preds_b if system.get('agree_iou') else None, SW.load_ocr(args.ocr))
    summary = E.aggregate(rows)
    summary['ci95'] = E.bootstrap(rows, E.KEYS + ['full_coverage_rate_when_split'], args.bootstrap)
    for stratum in sorted({g.get('stratum') or 'none' for g in gts}):
        sub = [r for r, g in zip(rows, gts) if (g.get('stratum') or 'none') == stratum]
        summary.setdefault('by_stratum', {})[stratum] = E.aggregate(sub)
    def ftype(g):
        f = (g.get('file') or '').lower()
        return 'vector-pdf' if f.endswith('.pdf') else ('raster' if f else 'n/a')
    def nbucket(g):
        n = len(g['panels'])
        return 'single' if n == 1 else ('2' if n == 2 else ('3-4' if n <= 4 else '5+'))
    for key, fn in (('by_file_type', ftype), ('by_panel_count', nbucket)):
        for v in sorted({fn(g) for g in gts}):
            sub = [r for r, g in zip(rows, gts) if fn(g) == v]
            summary.setdefault(key, {})[v] = E.aggregate(sub)
    from sfd.annotate import classes as CL
    cls = json.loads(args.classes.read_text()) if args.classes else {g['id']: CL.tag(g) for g in gts}
    for v in sorted(set(cls.values())):
        sub = [r for r, g in zip(rows, gts) if cls.get(g['id']) == v]
        if sub:
            summary.setdefault('by_class', {})[v] = E.aggregate(sub)
    for method in sorted({g.get('label_method') or 'n/a' for g in gts}):
        sub = [r for r, g in zip(rows, gts) if (g.get('label_method') or 'n/a') == method]
        summary.setdefault('by_label_method', {})[method] = E.aggregate(sub)
    out = {'system': system, 'gt': str(args.gt), 'gt_sha256': SW.hashlib.sha256(args.gt.read_bytes()).hexdigest() if hasattr(SW, 'hashlib') else None,
           'pred': str(args.pred), 'pred_b': str(args.pred_b) if args.pred_b else None, 'summary': summary,
           'figures': [{k: (v if k != 'crops' else [[round(x, 1) for x in c] for c in v]) for k, v in r.items()} for r in rows]}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(out, indent=1))
    print(json.dumps({k: round(summary[k], 4) for k in E.KEYS}), json.dumps(summary['ci95']))


if __name__ == '__main__':
    main()
