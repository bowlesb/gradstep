#!/usr/bin/env python3
"""Validation sweep over crop policies for one or more prediction files.

For each (GT set, predictions) pair and each policy (threshold x completion x gate) report app metrics.
Writes a JSON table; prints a compact summary. Selection uses validation sets only.
"""
import argparse, hashlib, itertools, json
from pathlib import Path

import numpy as np
from PIL import Image

from sfd.core import evaluate as E
from sfd.core import policy as P

Image.MAX_IMAGE_PIXELS = 200_000_000


def load_set(gt_path, root):
    gts = [json.loads(l) for l in Path(gt_path).read_text().splitlines() if l.strip()]
    cache = []
    for g in gts:
        img = np.asarray(Image.open(Path(root) / g['image']).convert('RGB'))
        m = P.ink_mask(img)
        cache.append((img, m, P.ink_components(m)))
    return gts, cache


agree = P.agree


def run(gts, cache, preds, cfg, gates=None, preds_b=None, ocr=None):
    rows = []
    for g, (img, m, comps) in zip(gts, cache):
        c = dict(cfg, _mask=m, _comps=comps)
        if gates is not None:
            c['gate'] = gates.get(g['id'])
        crops = P.final_crops(preds.get(g['id'], []), img, c)
        L = len(g.get('caption_letters') or [])
        if cfg.get('caption_decode'):
            d = P.decide(preds.get(g['id'], []), img, dict(cfg, agree_iou=cfg.get('agree_iou', .7) if preds_b is not None else None),
                         preds_b.get(g['id'], []) if preds_b is not None else None, g.get('caption_letters') or [], m, comps,
                         (ocr or {}).get(g['id']))
            crops = [p['box'] for p in d['parts']]
            r = E.evaluate_figure(g, crops, mask=m); r['crops'] = crops; r['reason'] = d['reason']; rows.append(r)
            continue
        if cfg.get('caption_count') and L >= 2:
            # The caption names L parts: use the highest confidence threshold that yields exactly L crops;
            # if none does, keep the whole figure (count disagreement = uncertainty).
            crops = []
            if cfg.get('caption_decode'):
                crops = P.caption_decode(preds.get(g['id'], []), L, img, c, cfg.get('decode_min_score', .15)) or []
                if not crops and cfg.get('caption_fallback', 'whole') == 'plain':
                    crops = P.final_crops(preds.get(g['id'], []), img, c)
                if preds_b is not None and crops and cfg.get('decode_agree', True):
                    cb = P.caption_decode(preds_b.get(g['id'], []), L, img, dict(c)) or P.final_crops(preds_b.get(g['id'], []), img, dict(c))
                    if not agree(crops, cb, cfg.get('agree_iou', .7)):
                        crops = []
                r = E.evaluate_figure(g, crops, mask=m); r['crops'] = crops; rows.append(r)
                continue
            cands = {t: P.final_crops(preds.get(g['id'], []), img, dict(c, threshold=t)) for t in (.8, .7, .6, .5, .4, .3)}
            for t, cand in cands.items():
                if len(cand) == L:
                    crops = cand
                    break
            if not crops and cfg.get('caption_group', True):
                # More crops than named parts: lettered rows/columns of plots -> merge by rows/columns.
                for t in (cfg['threshold'], .6, .5, .7):
                    grouped = P.group_to_count(cands.get(t, []), L)
                    if grouped:
                        crops = grouped
                        break
            if crops or cfg.get('caption_fallback', 'whole') == 'whole':
                r = E.evaluate_figure(g, crops, mask=m); r['crops'] = crops; rows.append(r)
                continue
            crops = cands.get(cfg['threshold']) or P.final_crops(preds.get(g['id'], []), img, c)
        if preds_b is not None:
            crops_b = P.final_crops(preds_b.get(g['id'], []), img, dict(c))
            if not agree(crops, crops_b, cfg.get('agree_iou', .7)):
                crops = []  # views disagree: keep the whole figure
        r = E.evaluate_figure(g, crops, mask=m)
        r['crops'] = crops
        rows.append(r)
    return rows


def load_ocr(path):
    if not path:
        return None
    out = {}
    for l in Path(path).read_text().splitlines():
        if l.strip():
            r = json.loads(l)
            out[r['id']] = r['text']
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--set', nargs=3, action='append', metavar=('NAME', 'GT', 'PRED'), required=True)
    ap.add_argument('--root', default='.')
    ap.add_argument('--panel-class', type=int, default=0)
    ap.add_argument('--thresholds', default='.3,.4,.5,.6,.7,.8')
    ap.add_argument('--complete', default='0,1')
    ap.add_argument('--gate', action='append', nargs=2, metavar=('NAME', 'JSON'), help='gate probabilities per set name')
    ap.add_argument('--gate-thresholds', default='')
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--bootstrap', type=int, default=0)
    ap.add_argument('--caption-count', action='store_true', help='use caption letter counts as an on-device gate')
    ap.add_argument('--caption-decode', action='store_true', help='caption-constrained decoding of exactly L boxes')
    ap.add_argument('--letter-group', action='store_true', help='group plotting areas under OCR letters (needs --ocr)')
    ap.add_argument('--ocr', type=Path, help='JSONL of {id, text:[{text, box}]} (Mac Vision OCR)')
    ap.add_argument('--no-decode-agree', action='store_true', help='skip two-view agreement for caption-decoded figures')
    ap.add_argument('--decode-min-score', type=float, default=.15)
    ap.add_argument('--decode-min-cover', type=float, default=.7)
    ap.add_argument('--caption-fallback', default='whole', choices=['whole', 'plain'], help='when no threshold matches the caption count')
    args = ap.parse_args()
    gates = {n: json.loads(Path(p).read_text()) for n, p in (args.gate or [])}
    table = []
    for name, gt, pred in args.set:
        gts, cache = load_set(gt, args.root)
        pred, _, pred_b = pred.partition(',')
        pl = json.loads(Path(pred).read_text())
        preds = {r['id']: r['predictions'] for r in pl}
        preds_b = {r['id']: r['predictions'] for r in json.loads(Path(pred_b).read_text())} if pred_b else None
        gts_list = [None] + [float(x) for x in args.gate_thresholds.split(',') if x]
        for t, comp, gt_thr in itertools.product([float(x) for x in args.thresholds.split(',')], [c == '1' for c in args.complete.split(',')], gts_list):
            cfg = {'threshold': t, 'panel_class': args.panel_class, 'complete': comp, 'caption_count': args.caption_count or args.caption_decode, 'caption_decode': args.caption_decode, 'caption_fallback': args.caption_fallback,
                   'decode_agree': not args.no_decode_agree, 'letter_group': args.letter_group, 'decode_min_score': args.decode_min_score, 'decode_min_cover': args.decode_min_cover}
            if gt_thr is not None:
                cfg['gate_threshold'] = gt_thr
            rows = run(gts, cache, preds, cfg, gates.get(name) if gt_thr is not None else None, preds_b, load_ocr(args.ocr))
            a = E.aggregate(rows)
            if args.bootstrap:
                a['ci95'] = E.bootstrap(rows, E.KEYS, args.bootstrap)
            table.append({'set': name, 'pred': pred, 'threshold': t, 'complete': comp, 'gate_threshold': gt_thr, **a})
            print(f"{name:28s} t={t:.2f} comp={int(comp)} gate={gt_thr} app={a['app_success']:.3f} harm={a['harmful_rate']:.3f} fsplit={a['single_false_split_rate']:.3f} "
                  f"perfect={a['compound_perfect_rate']:.3f} recall={a['panel_recall']:.3f} complete={a['complete_panel_rate']:.3f} prec={a['crop_precision']:.3f}", flush=True)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(table, indent=1))


if __name__ == '__main__':
    main()
