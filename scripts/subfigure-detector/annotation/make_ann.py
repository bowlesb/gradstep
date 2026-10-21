import json, re, sys
import numpy as np
from PIL import Image
sys.path.insert(0, 'src')
import policy as P
Image.MAX_IMAGE_PIXELS = 200_000_000
T = 'data/eval-test/tmp/'
cands = {}
for l in open('data/eval-test/candidates.jsonl'):
    r = json.loads(l); cands[r['id']] = r
ann, notes = {}, {}
fix_ids = set()
for line in open(T + 'ann_notes.txt'):
    line = line.rstrip('\n')
    if not line.strip() or line.startswith('#'):
        continue
    note = line.split('#', 1)[1].strip() if '#' in line else ''
    body = line.split('#', 1)[0].strip()
    m = re.match(r'^(FIXO|FIX|G|R|EXCLUDE)?\s*(\d{4}\.\d{4,5}v\d+-\d{3})\s*(.*)$', body)
    if not m:
        raise SystemExit('bad line: ' + line)
    tag, fid, rest = m.group(1), m.group(2), m.group(3).strip()
    if fid not in cands:
        raise SystemExit('unknown id ' + fid)
    if note:
        notes[fid] = note
    if tag in ('FIX', 'FIXO', 'G'):
        fix_ids.add(fid); continue
    if tag == 'EXCLUDE':
        ann[fid] = {'label': 'exclude', 'reason': note or 'excluded'}; continue
    if rest == 'vector':
        ann[fid] = {'label': 'vector'}
    elif rest == 'single':
        ann[fid] = {'label': 'single'}
    elif rest.startswith('blocks'):
        ann[fid] = {'label': 'blocks', 'panels': json.loads(rest[len('blocks'):].strip())}
    elif rest.startswith('vgroup'):
        ann[fid] = {'label': 'vgroup', 'panels': json.loads(rest[len('vgroup'):].strip())}
    else:
        raise SystemExit('bad rest: ' + line)
def tight(mask, b):
    H, W = mask.shape
    x0, y0, x1, y1 = int(round(b[0] * W)), int(round(b[1] * H)), int(round(b[2] * W)), int(round(b[3] * H))
    ys, xs = np.nonzero(mask[y0:y1, x0:x1])
    if len(xs) == 0:
        return None
    return [x0 + xs.min(), y0 + ys.min(), x0 + xs.max() + 1, y0 + ys.max() + 1]
report = []
for line in open(T + 'approx.txt'):
    if not line.strip() or line.startswith('#'):
        continue
    fid, panels, shared = [s.strip() for s in line.split('|')]
    c = cands[fid]
    img = np.asarray(Image.open(c['image']).convert('RGB')); mask = P.ink_mask(img); H, W = mask.shape
    def snap(v):
        # Move interior edges to the centre of the longest ink-free run within +-2.5% (a gutter).
        v = list(v)
        for k in range(4):
            e = v[k]
            if e <= 0.001 or e >= 0.999:
                continue
            horiz = k in (1, 3)
            L = H if horiz else W
            lo, hi = max(0, int((e - .025) * L)), min(L, int((e + .025) * L) + 1)
            if horiz:
                a0, a1 = int(v[0] * W), int(v[2] * W)
                prof = mask[lo:hi, a0:a1].any(1)
            else:
                a0, a1 = int(v[1] * H), int(v[3] * H)
                prof = mask[a0:a1, lo:hi].any(0)
            runs, st = [], None
            for i, f in enumerate(list(prof) + [True]):
                if not f and st is None: st = i
                if f and st is not None: runs.append((st, i)); st = None
            if not runs:
                # Framed panels: no fully empty line; use the weakest line if it is nearly empty (frame sides only).
                if horiz:
                    cnt = mask[lo:hi, a0:a1].sum(1)
                else:
                    cnt = mask[a0:a1, lo:hi].sum(0)
                span = max(1, a1 - a0)
                j = int(np.argmin(cnt))
                if cnt[j] <= 0.03 * span:
                    v[k] = (lo + j + 0.5) / L
                continue
            best = max(runs, key=lambda r: (r[1] - r[0], -abs((lo + (r[0] + r[1]) / 2) / L - e)))
            v[k] = (lo + (best[0] + best[1]) / 2) / L
        return v
    def parse(spec):
        out = []
        for part in [p for p in spec.split(';') if p.strip()]:
            boxes = []
            for piece in part.split('+'):
                v = [float(x) for x in piece.split()]
                assert len(v) == 4, (fid, piece)
                v = snap(v)
                t = tight(mask, v)
                if t: boxes.append(t)
            if not boxes:
                report.append((fid, 'empty piece', part)); continue
            u = [min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes)]
            # build_gt re-tightens with a 0.5% pad; pre-shrink so that pad lands back on these ink edges.
            px, py = 0.005 * W, 0.005 * H
            b = [u[0] + px + 0.5, u[1] + py + 0.5, u[2] - px - 0.5, u[3] - py - 0.5]
            if b[2] <= b[0]: b[0] = b[2] = (u[0] + u[2]) / 2
            if b[3] <= b[1]: b[1] = b[3] = (u[1] + u[3]) / 2
            out.append([b[0] / W, b[1] / H, b[2] / W, b[3] / H])
        return out
    pp, ss = parse(panels), parse(shared)
    ann[fid] = {'label': 'boxes', 'panels': [[round(x, 5) for x in b] for b in pp], 'shared': [[round(x, 5) for x in b] for b in ss]}
for fid, n in notes.items():
    if fid in ann and n and ann[fid]['label'] != 'exclude':
        ann[fid]['note'] = n
missing = [k for k in cands if k not in ann]
unresolved = [k for k in fix_ids if k not in ann]
print('entries', len(ann), 'missing', missing, 'unresolved', unresolved, 'report', report)
json.dump(ann, open('data/eval-test/annotations.json', 'w'), indent=1, sort_keys=True)
