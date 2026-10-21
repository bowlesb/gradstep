import json, sys
import numpy as np
from PIL import Image
sys.path.insert(0, 'src')
import policy as P
G = [json.loads(l) for l in open('data/eval-test2/gt.jsonl')]
rows = []
for g in G:
    if len(g['panels']) < 2: continue
    img = np.asarray(Image.open(g['image']).convert('RGB')); m = P.ink_mask(img)
    cov = np.zeros_like(m)
    for b in g['panels'] + g['shared']:
        x0,y0,x1,y1 = [int(round(v)) for v in b]; cov[max(0,y0):y1, max(0,x0):x1] = True
    unc = (m & ~cov).sum() / max(1, m.sum())
    ov = sum(1 for i in range(len(g['panels'])) for j in range(i+1, len(g['panels'])) if P.iou(g['panels'][i], g['panels'][j]) > .1)
    rows.append({'image': g['image'], 'gt': g['panels'], 'gt_shared': g['shared'], 'title': f"{g['id']} n={len(g['panels'])} unc={unc:.3f} ov={ov}"})
open('data/eval-test2/gt-review.jsonl', 'w').write(''.join(json.dumps(r) + '\n' for r in rows))
print(len(rows), sorted(r['title'] for r in rows if float(r['title'].split('unc=')[1].split()[0]) > .003))
