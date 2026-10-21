#!/usr/bin/env python3
"""Turn reviewed annotations into evaluation ground truth (evaluate.py format).

annotations.json: {figure_id: entry}. Entry forms:
  {"label": "vector"}                       accept the vector-derived proposal as is
  {"label": "single"}                       one panel: the whole figure's ink
  {"label": "vgroup", "panels": [[0,1,"s0"],[2]], "shared": [["s1"]]}  regroup vector panels (P<i>) and shared (S<k>)
  {"label": "blocks", "panels": [[0,1],[2]], "shared": [[3]]}   groups of coarse whitespace blocks
  {"label": "fine",   "panels": [[...]],     "shared": [[...]]}   groups of fine whitespace blocks
  {"label": "boxes",  "panels": [[x0,y0,x1,y1],...], "shared": [...]}  normalized boxes, tightened to ink
  {"label": "exclude", "reason": "..."}
Blocks not named in panels/shared become shared context (they still count for coverage).
"""
import argparse, collections, json
from pathlib import Path

import numpy as np
from PIL import Image

from sfd.core import policy as P

Image.MAX_IMAGE_PIXELS = 200_000_000


def tighten(mask, b, pad=0.005):
    H, W = mask.shape
    x0 = max(0, int(b[0] - pad * W)); y0 = max(0, int(b[1] - pad * H))
    x1 = min(W, int(np.ceil(b[2] + pad * W))); y1 = min(H, int(np.ceil(b[3] + pad * H)))
    ys, xs = np.nonzero(mask[y0:y1, x0:x1])
    if len(xs) == 0:
        return None
    return [float(x0 + xs.min()), float(y0 + ys.min()), float(x0 + xs.max() + 1), float(y0 + ys.max() + 1)]


def union_all(bs):
    b = list(bs[0])
    for c in bs[1:]:
        b = P.union(b, c)
    return b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('candidates', type=Path)
    ap.add_argument('annotations', type=Path)
    ap.add_argument('out', type=Path)
    ap.add_argument('--split', required=True)
    ap.add_argument('--annotator', default='Claude visual review (not independent human review)')
    args = ap.parse_args()
    cands = {json.loads(l)['id']: json.loads(l) for l in args.candidates.read_text().splitlines()}
    ann = json.loads(args.annotations.read_text())
    out, stats, missing = [], collections.Counter(), [k for k in cands if k not in ann]
    for fid, a in ann.items():
        c = cands[fid]
        lab = a['label']
        stats[lab] += 1
        if lab == 'exclude':
            continue
        img = np.asarray(Image.open(c['image']).convert('RGB'))
        mask = P.ink_mask(img)
        H, W = mask.shape
        shared = []
        if lab == 'vector':
            v = c['vector']; sx = W / v['W']
            panels = [[x * sx for x in b] for b in v['panel_boxes']]
            shared = [[x * sx for x in b] for b in v['shared_boxes']]
        elif lab == 'vgroup':
            # Groups of vector panels (ints) and vector shared boxes ('s<k>'), e.g. [[0,1,'s2'],[2]].
            v = c['vector']; sx = W / v['W']
            vp = [[x * sx for x in b] for b in v['panel_boxes']]; vs = [[x * sx for x in b] for b in v['shared_boxes']]
            pick = lambda t: vs[int(t[1:])] if isinstance(t, str) else vp[t]
            usedp, useds = set(), set()
            panels = []
            for g in a['panels']:
                panels.append(union_all([pick(t) for t in g]))
                usedp |= {t for t in g if not isinstance(t, str)}; useds |= {int(t[1:]) for t in g if isinstance(t, str)}
            for g in a.get('shared', []):
                shared.append(union_all([pick(t) for t in g]))
                usedp |= {t for t in g if not isinstance(t, str)}; useds |= {int(t[1:]) for t in g if isinstance(t, str)}
            if set(range(len(vp))) - usedp:
                raise ValueError(f'{fid}: vector panels not assigned {set(range(len(vp))) - usedp}')
            shared += [vs[i] for i in range(len(vs)) if i not in useds]
        elif lab == 'single':
            panels = [tighten(mask, [0, 0, W, H], 0)]
        elif lab in ('blocks', 'fine'):
            blocks = c['blocks'] if lab == 'blocks' else c['blocks_fine']
            used = set()
            panels = []
            for g in a['panels']:
                panels.append(union_all([blocks[i] for i in g])); used |= set(g)
            for g in a.get('shared', []):
                shared.append(union_all([blocks[i] for i in g])); used |= set(g)
            shared += [blocks[i] for i in range(len(blocks)) if i not in used]
        elif lab == 'boxes':
            panels = [tighten(mask, [b[0] * W, b[1] * H, b[2] * W, b[3] * H]) for b in a['panels']]
            shared = [tighten(mask, [b[0] * W, b[1] * H, b[2] * W, b[3] * H]) for b in a.get('shared', [])]
            panels = [p for p in panels if p]; shared = [s for s in shared if s]
        else:
            raise ValueError(f'{fid}: unknown label {lab}')
        if lab != 'single' and len(panels) == 1:
            panels = [tighten(mask, [0, 0, W, H], 0)]
            shared = []
        out.append({'id': fid, 'image': c['image'], 'width': W, 'height': H, 'paper': c['paper'], 'split': args.split,
                    'stratum': c['stratum'], 'source': 'arxiv-' + args.split, 'label_method': lab,
                    'panels': panels, 'shared': shared, 'annotator': args.annotator, 'note': a.get('note', ''),
                    'caption_letters': c.get('caption_letters'), 'file': c['file'], 'kind': 'compound' if len(panels) > 1 else 'single'})
    args.out.write_text(''.join(json.dumps(r) + '\n' for r in out))
    print(json.dumps({'labels': stats, 'gt_rows': len(out), 'compound': sum(len(r['panels']) > 1 for r in out),
                      'panels': sum(len(r['panels']) for r in out), 'unannotated': len(missing)}))


if __name__ == '__main__':
    main()
