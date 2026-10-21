#!/usr/bin/env python3
"""Caption-verified whitespace supervision for compound figures that have no plotting-area geometry.

For training-split single-file figures whose caption names >=2 panel letters ((a), (b), ...), the
rendered figure is cut recursively along whitespace gutters (XY-cut) at several gutter widths. Leaves
are 'bodies' (large) or 'small' (letters, subcaptions, labels, legends). Small leaves join their nearest
body unless they span several bodies (shared context). A labelling is accepted only when the number of
bodies equals the caption's letter count; for PDF figures with a text layer, letter tokns found inside
the figure must also fall one per panel ('verified'). Everything else is rejected, never guessed.
"""
import argparse, hashlib, json, math, multiprocessing as mp, re
from pathlib import Path

import numpy as np
import pymupdf
from PIL import Image

from sfd.annotate import candidates as C
from sfd.mine import vector_labels as V

LETTER = re.compile(r'^\(?([a-l])\)?[.:]?$')
VERSION = 'xycut-labels-v2'


def leaves(mask, frac):
    return C.xycut(mask, 0, 0, min_frac=frac)


def group(blocks, W, H):
    bodies, small = [], []
    big_area = max(V.area(b) for b in blocks)
    for b in blocks:
        w, h = b[2] - b[0], b[3] - b[1]
        if V.area(b) >= 0.12 * big_area and (w >= 0.08 * W or h >= 0.08 * H) and min(w, h) >= 0.04 * min(W, H):
            bodies.append(list(map(float, b)))
        else:
            small.append(list(map(float, b)))
    panels = [list(b) for b in bodies]
    shared = []
    if not bodies:
        return bodies, panels, small
    for s in small:
        xs = [j for j, b in enumerate(bodies) if min(s[2], b[2]) - max(s[0], b[0]) > 0.5 * min(s[2] - s[0], b[2] - b[0]) and (s[2] - s[0]) > 0.6 * (b[2] - b[0])]
        span_x = [j for j, b in enumerate(bodies) if min(s[2], b[2]) - max(s[0], b[0]) > 0.3 * (b[2] - b[0])]
        span_y = [j for j, b in enumerate(bodies) if min(s[3], b[3]) - max(s[1], b[1]) > 0.3 * (b[3] - b[1])]
        if len(span_x) >= 2 and (s[3] <= min(bodies[j][1] for j in span_x) + 2 or s[1] >= max(bodies[j][3] for j in span_x) - 2):
            shared.append(s); continue
        if len(span_y) >= 2 and (s[2] <= min(bodies[j][0] for j in span_y) + 2 or s[0] >= max(bodies[j][2] for j in span_y) - 2):
            shared.append(s); continue
        d = sorted((V.gap(s, b), j) for j, b in enumerate(bodies))
        k = d[0][1]
        if len(d) > 1 and d[1][0] - d[0][0] < 0.25 * max(1.0, d[1][0]):
            a, c = bodies[d[0][1]], bodies[d[1][1]]
            # Equidistant between two bodies: a label left of a plot (y ticks/label) belongs to the body on its
            # right; a label between rows (x ticks/label, subcaption) belongs to the body above.
            if min(a[3], c[3]) - max(a[1], c[1]) > 0:   # side by side
                k = d[0][1] if a[0] > c[0] else d[1][1]
            else:                                         # stacked
                k = d[0][1] if a[1] < c[1] else d[1][1]
        panels[k] = V.union(panels[k], s)
    return bodies, panels, shared


def pdf_letters(path, W, H):
    try:
        doc = pymupdf.open(path)
        page = doc[0]
        r = page.rect
        scale = W / r.width
        out = []
        for w in page.get_text('words'):
            if LETTER.match(w[4].strip()):
                out.append(([(w[0] - r.x0) * scale, (w[1] - r.y0) * scale, (w[2] - r.x0) * scale, (w[3] - r.y0) * scale], LETTER.match(w[4].strip()).group(1)))
        return out
    except Exception:
        return None


def label(task):
    try:
        return label_one(task)
    except Exception as e:  # malformed inputs are recorded, never fatal
        return {**task[2], 'reject': 'error', 'error': repr(e)[:160]}


def label_one(task):
    src, dst, rec = task
    try:
        img = C.load_figure(src)
    except Exception as e:
        return {**rec, 'reject': 'load_error'}
    if img is None or min(img.shape[:2]) < 64:
        return {**rec, 'reject': 'load'}
    H, W = img.shape[:2]
    mask = V.ink_mask(img)
    if mask.mean() > 0.6:
        return {**rec, 'reject': 'dense_background'}
    L = len(rec['caption_letters'])
    if L == 0:
        bl = leaves(mask, 0.03)
        if not bl:
            return {**rec, 'reject': 'blank'}
        bodies, panels, shared = group(bl, W, H)
        if len(bodies) != 1:
            return {**rec, 'reject': 'single_ambiguous'}
        ys, xs = np.nonzero(mask)
        Path(dst).parent.mkdir(parents=True, exist_ok=True)
        Image.fromarray(img).save(dst, compress_level=3)
        return {**rec, 'image': dst, 'W': W, 'H': H, 'gutter_frac': 0.03, 'single': True,
                'panels': [[float(xs.min()), float(ys.min()), float(xs.max() + 1), float(ys.max() + 1)]], 'shared': [],
                'letters_verified': None, 'sha256': hashlib.sha256(Path(dst).read_bytes()).hexdigest()}
    result = None
    for frac in (0.03, 0.02, 0.014, 0.009):
        bl = leaves(mask, frac)
        if not bl or len(bl) > 80:
            continue
        bodies, panels, shared = group(bl, W, H)
        if len(bodies) == L:
            result = (frac, bodies, panels, shared)
            break
    if result is None:
        return {**rec, 'reject': 'count_mismatch', 'W': W, 'H': H}
    frac, bodies, panels, shared = result
    for a in range(len(panels)):
        for b in range(a + 1, len(panels)):
            if V.area(V.inter(panels[a], panels[b])) > 0.02 * min(V.area(panels[a]), V.area(panels[b])):
                return {**rec, 'reject': 'overlap'}
    verified = None
    if src.lower().endswith('.pdf'):
        lets = pdf_letters(src, W, H)
        if lets:
            per = [sum(1 for b, _ in lets if V.area(V.inter(b, p)) > 0.5 * V.area(b)) for p in panels]
            verified = len(lets) == len(panels) and all(x == 1 for x in per)
            if len(lets) >= 2 and not verified:
                return {**rec, 'reject': 'letter_layout_mismatch'}
    Path(dst).parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(img).save(dst, compress_level=3)
    return {**rec, 'image': dst, 'W': W, 'H': H, 'gutter_frac': frac, 'panels': panels, 'shared': shared,
            'letters_verified': verified, 'sha256': hashlib.sha256(Path(dst).read_bytes()).hexdigest()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--corpus', type=Path, required=True)
    ap.add_argument('--figures', type=Path, required=True)
    ap.add_argument('--split', type=Path, required=True)
    ap.add_argument('--vector', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--workers', type=int, default=24)
    ap.add_argument('--limit', type=int)
    ap.add_argument('--singles', action='store_true', help='also label unlettered figures that cut into one body')
    args = ap.parse_args()
    split = json.loads(args.split.read_text())['split']
    vec_ok = set()
    for l in args.vector.open():
        r = json.loads(l)
        if not r.get('reject'):
            vec_ok.add(r['id'])
    tasks = []
    for l in args.figures.open():
        f = json.loads(l)
        if split.get(f['paper']) != 'train' or f['n_includes'] != 1 or not f['includes'][0]['file']:
            continue
        nl = len(f['caption_letters'])
        if nl == 1 or nl > 12:
            continue
        if nl == 0 and (not args.singles or f['caption_spatial']):
            continue
        fid = f"{f['paper']}-{f['index']:03d}"
        if fid in vec_ok:
            continue
        fn = f['includes'][0]['file']
        if not fn.lower().endswith(('.pdf', '.png', '.jpg', '.jpeg')):
            continue
        rec = {'id': fid, 'paper': f['paper'], 'file': fn, 'caption_letters': f['caption_letters'], 'caption': f['caption'][:400]}
        tasks.append((str(args.corpus / f['paper'] / 'build' / 'src' / fn), str(args.out / 'images' / f['paper'] / f'{fid}.png'), rec))
        if args.limit and len(tasks) >= args.limit:
            break
    args.out.mkdir(parents=True, exist_ok=True)
    done = set()
    if (args.out / 'labels.jsonl').exists():
        done = {json.loads(l)['id'] for l in (args.out / 'labels.jsonl').open() if l.strip()}
    tasks = [t for t in tasks if t[2]['id'] not in done]
    with mp.Pool(args.workers, maxtasksperchild=100) as pool, (args.out / 'labels.jsonl').open('a') as fo:
        for r in pool.imap_unordered(label, tasks, chunksize=4):
            r['version'] = VERSION
            fo.write(json.dumps(r) + '\n')
    print('tasks', len(tasks))


if __name__ == '__main__':
    main()
