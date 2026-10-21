#!/usr/bin/env python3
"""Judge queries with known answers from the validation GT, one family per decision type.

single/compound; panel count; letter <-> part (truth = caption letters in reading order; an approximation used
only when the caption names exactly as many letters as there are panels); shared vs panel-owned element;
"same lettered panel?" for two plotting areas; verifying a drawn split (truth = the app metric's 'perfect').
"""
import argparse, json, random
from pathlib import Path

import numpy as np
from PIL import Image

from sfd.core import policy as P
from sfd.group import features as F


def cap(g, n=400):
    c = (g.get('caption') or '').replace('\n', ' ')
    return c[:n]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gt', type=Path, required=True)
    ap.add_argument('--candidates', type=Path, required=True)
    ap.add_argument('--split-rows', type=Path, required=True, help='final_eval output with crops for D6')
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--seed', type=int, default=20261023)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    gts = [json.loads(l) for l in args.gt.read_text().splitlines() if l.strip()]
    cands = {json.loads(l)['id']: json.loads(l) for l in args.candidates.read_text().splitlines() if l.strip()}
    for g in gts:
        g['caption'] = cands.get(g['id'], {}).get('caption', '')
    splits = {r['id']: r for r in json.loads(args.split_rows.read_text())['figures']}
    Q = []

    def add(t, g, prompt, answers, truth, marks=()):
        Q.append({'qid': f"{t}:{g['id']}:{len(Q)}", 'type': t, 'figure': g['id'], 'image': g['image'], 'prompt': prompt,
                  'answers': answers, 'truth': truth, 'marks': list(marks)})
    for g in gts:
        n = len(g['panels'])
        add('compound', g, f"This is a figure from a scientific paper. Caption: \"{cap(g)}\"\nIs the image ONE figure (a single plot, "
            "diagram, table, or an unlabelled grid of examples) or made of SEVERAL separate panels (sub-figures such as (a), (b), "
            "or separately titled plots)?", ['ONE', 'SEVERAL'], 'SEVERAL' if n >= 2 else 'ONE')
        if n >= 2:
            add('count', g, f"This is a figure from a scientific paper. Caption: \"{cap(g)}\"\nHow many separate panels (sub-figures) "
                "does it have? A lettered part counts as one panel even if it contains several small plots.",
                [str(k) for k in range(12, 0, -1)], str(n))
            L = sorted(set(g.get('caption_letters') or []))
            if len(L) == n:
                order = P.reading_order([list(b) for b in g['panels']])
                k = rng.randrange(n)
                add('letter', g, f"Caption: \"{cap(g)}\"\nWhich panel letter belongs to the part inside the red box?",
                    L, L[k], [{'box': order[k], 'color': 'red'}])
            if g.get('shared'):
                s = rng.choice(g['shared'])
                add('shared', g, "The red box marks one element of this scientific figure (a legend, label, title or color bar). Does it belong "
                    "to ONE panel only, or is it SHARED by several panels?", ['ONE', 'SHARED'], 'SHARED', [{'box': s, 'color': 'red'}])
                # an owned text-like element near a panel's edge, from ink components
                img = np.asarray(Image.open(g['image']).convert('RGB'))
                comps, _ = F.components(img)
                own = []
                for c in comps:
                    b = c['box']; h = b[3] - b[1]
                    if h > 0.06 * img.shape[0] or c['ink'] < 30:
                        continue
                    for p in g['panels']:
                        if b[0] >= p[0] and b[1] >= p[1] and b[2] <= p[2] and b[3] <= p[3]:
                            edge = min(b[0] - p[0], p[2] - b[2], b[1] - p[1], p[3] - b[3])
                            if edge < 0.08 * max(p[2] - p[0], p[3] - p[1]):
                                own.append(b)
                if own:
                    add('shared', g, "The red box marks one element of this scientific figure (a legend, label, title or color bar). Does it belong "
                        "to ONE panel only, or is it SHARED by several panels?", ['ONE', 'SHARED'], 'ONE', [{'box': rng.choice(own), 'color': 'red'}])
            v = cands.get(g['id'], {}).get('vector') or {}
            if v and not v.get('reject') and len(v.get('panel_boxes') or []) >= 2:
                sx = g['width'] / v['W']
                vp = [[x * sx for x in b] for b in v['panel_boxes']]

                def home(b):
                    for k, p in enumerate(g['panels']):
                        if P.area(P.inter(b, p)) >= .8 * P.area(b):
                            return k
                    return None
                hs = [home(b) for b in vp]
                same = [(a, b) for a in range(len(vp)) for b in range(a + 1, len(vp)) if hs[a] is not None and hs[a] == hs[b]]
                diff = [(a, b) for a in range(len(vp)) for b in range(a + 1, len(vp)) if hs[a] is not None and hs[b] is not None and hs[a] != hs[b]]
                for pool, truth in ((same, 'SAME'), (diff, 'DIFFERENT')):
                    if pool:
                        a, b = rng.choice(pool)
                        add('same_part', g, f"Caption: \"{cap(g)}\"\nDo the plots in box 1 (red) and box 2 (blue) belong to the SAME panel "
                            "(one part of the figure as its letters or titles define it) or to DIFFERENT panels?", ['SAME', 'DIFFERENT'], truth,
                            [{'box': vp[a], 'color': 'red', 'label': '1'}, {'box': vp[b], 'color': 'blue', 'label': '2'}])
        r = splits.get(g['id'])
        if r and len(r.get('crops') or []) >= 2:
            cols = ['red', 'blue', 'green', 'orange', 'purple', 'teal', 'magenta', 'brown']
            marks = [{'box': c, 'color': cols[k % len(cols)], 'label': str(k + 1)} for k, c in enumerate(r['crops'])]
            add('verify', g, f"Caption: \"{cap(g)}\"\nThe numbered boxes are a proposed split of this figure into panels. It is CORRECT only if "
                "every panel has exactly one box, no box cuts off any part of a panel (its letter, axis labels, ticks, legend), and no box "
                "merges two panels. Is the split CORRECT or WRONG?", ['CORRECT', 'WRONG'], 'CORRECT' if r['outcome'] == 'perfect' else 'WRONG', marks)
    args.out.write_text(''.join(json.dumps(q) + '\n' for q in Q))
    import collections
    print(collections.Counter((q['type'], q['truth']) for q in Q))


if __name__ == '__main__':
    main()
