#!/usr/bin/env python3
"""End-to-end golden cases for the on-device integration (validation figures only).

For each figure: image SHA-256 and size, caption letters, OCR lines (if given), the model's raw outputs for both
placements (first `--keep` queries by score, enough to replay decoding), the decoded detections, and the
expected `policy.decide()` result. A port is correct when, given the same raw outputs, it produces the same
parts (ids, order, boxes within 0.5 px) and the same status/reason.
"""
import argparse, hashlib, json
from pathlib import Path

import numpy as np
import torch

from sfd.core import policy as P
from sfd.train import train as T


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', type=Path, required=True)
    ap.add_argument('--checkpoint', type=Path, required=True)
    ap.add_argument('--base', type=Path, required=True)
    ap.add_argument('--arch', default='r50m')
    ap.add_argument('--gt', type=Path, required=True)
    ap.add_argument('--system', type=Path, required=True)
    ap.add_argument('--ocr', type=Path)
    ap.add_argument('--ids', nargs='*')
    ap.add_argument('--n', type=int, default=24)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    system = json.loads(args.system.read_text())
    cfg = dict(system['policy'], agree_iou=system.get('agree_iou'))
    ocr = {}
    if args.ocr:
        for l in args.ocr.read_text().splitlines():
            r = json.loads(l); ocr[r['id']] = r['text']
    gts = [json.loads(l) for l in args.gt.read_text().splitlines() if l.strip()]
    if args.ids:
        gts = [g for g in gts if g['id'] in set(args.ids)]
    else:
        gts = gts[::max(1, len(gts) // args.n)][:args.n]
    model, _, _ = T.build_model(args.repo, args.base, args.arch, 2, 640)
    st = torch.load(args.checkpoint, map_location='cpu', weights_only=False)
    model.load_state_dict(st['model'], strict=False)
    model.eval()
    ck_sha = hashlib.sha256(args.checkpoint.read_bytes()).hexdigest()
    cases = []
    for g in gts:
        im = T.load_rgb(g['image'])
        img = np.asarray(im)
        raw = {}
        dets = {}
        for name, zoom in (('a', 1.0), ('b', .75)):
            canvas, _ = T.letterbox(im, 640, zoom)
            x = torch.from_numpy(np.asarray(canvas, dtype=np.float32).transpose(2, 0, 1)[None].copy() / 255.)
            with torch.inference_mode():
                o = model(x)
            lg, bx = o['pred_logits'][0].numpy(), o['pred_boxes'][0].numpy()
            dets[name] = P.decode_outputs(lg, bx, im.width, im.height, zoom=zoom)
            raw[name] = {'zoom': zoom, 'logits': np.round(lg, 6).tolist(), 'boxes': np.round(bx, 7).tolist()}
        d = P.decide(dets['a'], img, cfg, dets['b'], g.get('caption_letters') or [], text_lines=ocr.get(g['id']))
        cases.append({'id': g['id'], 'image_sha256': hashlib.sha256(Path(g['image']).read_bytes()).hexdigest(),
                      'width': im.width, 'height': im.height, 'caption_letters': g.get('caption_letters') or [],
                      'ocr_lines': ocr.get(g['id']), 'raw_outputs': raw, 'expected': d})
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / 'golden-cases.json').write_text(json.dumps({'checkpoint_sha256': ck_sha, 'policy_revision': P.POLICY_REVISION,
                                                             'system': system, 'cases': cases}))
    print(len(cases), sum(c['expected']['status'] == 'split' for c in cases))


if __name__ == '__main__':
    main()
