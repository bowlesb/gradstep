#!/usr/bin/env python3
"""Sample real arXiv figures (as the app receives them) for the new validation/test sets.

Unit: a figure environment with exactly one included file, i.e. one arXiv HTML figure image.
PDF files are rendered (1280 px long side); raster files are decoded as RGB (long side <= 1600).
For annotation, each candidate gets (a) the vector-derived proposal when the vector labeler
accepted it, and (b) model-free whitespace (XY-cut) blocks that a reviewer groups into panels.
No detector output is used, so labels are not biased toward any model.
"""
import argparse, hashlib, json, random
from pathlib import Path

import numpy as np
import pymupdf
from PIL import Image, ImageDraw, ImageFont

import vector_labels as V

Image.MAX_IMAGE_PIXELS = 200_000_000


def load_figure(path):
    if path.lower().endswith('.pdf'):
        doc = pymupdf.open(path)
        if len(doc) != 1:
            return None
        img, _ = V.render(doc[0])
        return img
    im = Image.open(path)
    if im.mode in ('RGBA', 'LA', 'P'):
        im = im.convert('RGBA')
        bg = Image.new('RGBA', im.size, (255, 255, 255, 255))
        im = Image.alpha_composite(bg, im)
    im = im.convert('RGB')
    s = min(1.0, 1600 / max(im.size))
    if s < 1:
        im = im.resize((round(im.width * s), round(im.height * s)), Image.Resampling.LANCZOS)
    return np.asarray(im).copy()


def gutters(profile, min_run):
    """Runs of empty rows/cols strictly inside the occupied extent."""
    occ = np.nonzero(profile)[0]
    if len(occ) == 0:
        return []
    lo, hi = occ[0], occ[-1]
    runs, start = [], None
    for i in range(lo, hi + 1):
        if profile[i] == 0:
            if start is None:
                start = i
        elif start is not None:
            if i - start >= min_run:
                runs.append((start, i))
            start = None
    return runs


def xycut(mask, x0, y0, depth=0, out=None, min_frac=0.008):
    if out is None:
        out = []
    H, W = mask.shape
    if not mask.any():
        return out
    ys, xs = np.nonzero(mask)
    bx0, by0, bx1, by1 = xs.min(), ys.min(), xs.max() + 1, ys.max() + 1
    sub = mask[by0:by1, bx0:bx1]
    ref = max(mask.shape) if depth else max(H, W)
    g = max(3, int(min_frac * ref))
    if depth < 8:
        rows = gutters(sub.any(1).astype(int), g)
        if rows:
            cuts = [0] + [r for run in rows for r in run] + [sub.shape[0]]
            for a, b in zip(cuts[0::2], cuts[1::2]):
                xycut(sub[a:b], x0 + bx0, y0 + by0 + a, depth + 1, out, min_frac)
            return out
        cols = gutters(sub.any(0).astype(int), g)
        if cols:
            cuts = [0] + [c for run in cols for c in run] + [sub.shape[1]]
            for a, b in zip(cuts[0::2], cuts[1::2]):
                xycut(sub[:, a:b], x0 + bx0 + a, y0 + by0, depth + 1, out, min_frac)
            return out
    out.append([int(x0 + bx0), int(y0 + by0), int(x0 + bx1), int(y0 + by1)])
    return out


def merge_tiny(blocks, W, H, max_blocks=40):
    """Very small fragments (single glyphs) stay separate only up to a budget; beyond it they
    merge into their nearest neighbour so a reviewer can still read the numbering."""
    blocks = [list(b) for b in blocks]
    while len(blocks) > max_blocks:
        k = min(range(len(blocks)), key=lambda i: V.area(blocks[i]))
        b = blocks.pop(k)
        j = min(range(len(blocks)), key=lambda i: V.gap(b, blocks[i]))
        blocks[j] = V.union(blocks[j], b)
    return blocks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--corpus', type=Path, required=True)
    ap.add_argument('--figures', type=Path, required=True)
    ap.add_argument('--split', type=Path, required=True)
    ap.add_argument('--vector', type=Path, required=True, help='vector labels.jsonl over all single-file PDF figures')
    ap.add_argument('--which', choices=['validation', 'test'], required=True)
    ap.add_argument('--n', type=int, default=240)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--seed', type=int, default=20261021)
    args = ap.parse_args()
    split = json.loads(args.split.read_text())['split']
    vec = {}
    for line in args.vector.open():
        r = json.loads(line)
        vec[r['id']] = r
    pool = []
    for line in args.figures.open():
        f = json.loads(line)
        if split.get(f['paper']) != args.which or f['n_includes'] != 1 or not f['includes'][0]['file']:
            continue
        if not f['includes'][0]['file'].lower().endswith(('.pdf', '.png', '.jpg', '.jpeg')):
            continue
        pool.append(f)
    rng = random.Random(args.seed)
    rng.shuffle(pool)
    # Stratify: half with >=2 caption panel letters (likely compound), half natural remainder.
    lettered = [f for f in pool if len(f['caption_letters']) >= 2]
    other = [f for f in pool if len(f['caption_letters']) < 2]
    # At most two figures per paper keeps the sample spread across papers.
    chosen, per_paper = [], {}
    for group, quota in ((lettered, args.n // 2), (other, args.n - args.n // 2)):
        got = 0
        for f in group:
            if got >= quota:
                break
            if per_paper.get(f['paper'], 0) >= 2:
                continue
            per_paper[f['paper']] = per_paper.get(f['paper'], 0) + 1
            f['stratum'] = 'caption_letters' if group is lettered else 'natural_remainder'
            chosen.append(f)
            got += 1
    args.out.mkdir(parents=True, exist_ok=True)
    rows = []
    for f in chosen:
        fid = f"{f['paper']}-{f['index']:03d}"
        path = args.corpus / f['paper'] / 'build' / 'src' / f['includes'][0]['file']
        try:
            img = load_figure(str(path))
        except Exception as e:
            img = None
        if img is None or img.shape[0] < 32 or img.shape[1] < 32:
            continue
        p = args.out / 'images' / f'{fid}.png'
        p.parent.mkdir(parents=True, exist_ok=True)
        Image.fromarray(img).save(p)
        H, W = img.shape[:2]
        mask = V.ink_mask(img)
        blocks = merge_tiny(xycut(mask, 0, 0), W, H)
        v = vec.get(fid)
        rows.append({'id': fid, 'paper': f['paper'], 'figure_index': f['index'], 'file': f['includes'][0]['file'],
                     'stratum': f['stratum'], 'caption': f['caption'][:1500], 'caption_letters': f['caption_letters'],
                     'image': str(p), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'width': W, 'height': H,
                     'blocks': blocks, 'vector': None if not v else {k: v.get(k) for k in (
                         'reject', 'panels', 'panel_boxes', 'shared_boxes', 'W', 'H', 'letters')}})
    with (args.out / 'candidates.jsonl').open('w') as fo:
        for r in rows:
            fo.write(json.dumps(r) + '\n')
    print(args.which, 'pool', len(pool), 'lettered', len(lettered), 'chosen', len(rows))


if __name__ == '__main__':
    main()
