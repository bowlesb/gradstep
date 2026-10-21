import json, sys
import numpy as np
from PIL import Image
from scipy import ndimage
sys.path.insert(0, 'src')
import policy as P
Image.MAX_IMAGE_PIXELS = 200_000_000
rows = [json.loads(l) for l in open('data/eval-test/gt.jsonl')]
flag = []
for r in rows:
    if len(r['panels']) < 2: continue
    img = np.asarray(Image.open(r['image']).convert('RGB')); mask = P.ink_mask(img); H, W = mask.shape
    lab, n = ndimage.label(ndimage.binary_dilation(mask, iterations=2))
    lab = lab * mask
    boxes = [('P%d' % i, b) for i, b in enumerate(r['panels'])] + [('S%d' % i, b) for i, b in enumerate(r['shared'])]
    ys, xs = np.nonzero(lab)
    ids = lab[ys, xs]
    inside = {}
    for name, b in boxes:
        x0, y0, x1, y1 = b
        inside[name] = (xs >= x0 - 0.5) & (xs < x1 + 0.5) & (ys >= y0 - 0.5) & (ys < y1 + 0.5)
    counts = np.bincount(ids, minlength=n + 1)
    issues = []
    for name, m in inside.items():
        c = np.bincount(ids[m], minlength=n + 1)
        inside[name] = c
    anyin = np.zeros(n + 1)
    best = np.zeros(n + 1)
    for name, c in inside.items():
        best = np.maximum(best, c)
    for k in range(1, n + 1):
        tot = counts[k]
        if tot < 25: continue
        frac = best[k] / tot
        if frac < 0.995 and (tot - best[k]) >= 15:
            parts = {name: int(c[k]) for name, c in inside.items() if c[k] > 0}
            kys, kxs = ys[ids == k], xs[ids == k]
            issues.append({'bbox': [int(kxs.min()), int(kys.min()), int(kxs.max()) + 1, int(kys.max()) + 1], 'pix': int(tot), 'in': parts})
    ov = []
    for a in range(len(r['panels'])):
        for b in range(a + 1, len(r['panels'])):
            A, B = r['panels'][a], r['panels'][b]
            o = P.area(P.inter(A, B)) / max(1, min(P.area(A), P.area(B)))
            if o > 0.02: ov.append((a, b, round(o, 3)))
    if issues or ov:
        flag.append({'id': r['id'], 'm': r['label_method'], 'W': W, 'H': H, 'issues': sorted(issues, key=lambda x: -x['pix'])[:5], 'nissues': len(issues), 'ov': ov})
print('flagged', len(flag))
for f in flag:
    print(json.dumps(f)[:420])
