#!/usr/bin/env python3
"""Synthetic figures mirroring the 10-21 failure classes (training split panels only; exact labels).

Classes (`--kind`):
  groups    lettered parts made of several plots: L parts, each a row/grid of 2-4 plots under ONE letter;
            the part box is the union of its plots and its letter.
  framed    lettered framed panels (rounded borders, optional tint) joined by arrows; arrows are shared.
  touching  raster images tiled with no gutter, a letter printed inside each tile (compound); with
            --negative-share, the same grids without letters are labelled ONE figure (policy: unlettered
            example grids are single).
  many      5-12 small lettered plots in a grid with narrow gutters.
"""
import argparse, json, math, random
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from sfd.mine import synth_compose as S


def tight(arr, b):
    x0, y0, x1, y1 = [int(round(v)) for v in b]
    sub = arr[max(0, y0):max(0, y1), max(0, x0):max(0, x1)]
    ys, xs = np.nonzero(sub)
    if len(xs) == 0:
        return None
    return [float(max(0, x0) + xs.min()), float(max(0, y0) + ys.min()), float(max(0, x0) + xs.max() + 1), float(max(0, y0) + ys.max() + 1)]


def place_row(canvas, imgs, x, y, h, gap):
    boxes = []
    for im in imgs:
        w = max(8, int(im.width * h / im.height))
        canvas.paste(im.resize((w, h), Image.Resampling.LANCZOS), (x, y))
        boxes.append([x, y, x + w, y + h])
        x += w + gap
    return boxes, x - gap


SIBLINGS = {}


def make_groups(pool, rng):
    L = rng.choice([2, 2, 3, 3, 4])
    k = rng.choice([2, 3, 3, 4])
    layout = rng.choice(['rows', 'cols'])
    style, lf = rng.choice(['paren', 'paren', 'plain', 'upper']), S.font(rng.randint(18, 28), rng)
    # Each lettered part reuses the sibling panels of ONE real compound figure (similar plots, as in papers).
    figs = [f for f, ps in SIBLINGS.items() if len(ps) >= k]
    if len(figs) < L:
        return None
    groups = [[S.load_panel(it) for it in rng.sample(SIBLINGS[f], k)] for f in rng.sample(figs, L)]
    if any(p is None for g in groups for p in g):
        return None
    h = rng.randint(140, 220)
    gap_in = rng.choice([2, 6, 12])
    gap_out = rng.randint(30, 60)
    canvas = Image.new('RGB', (4000, 4000), 'white')
    d = ImageDraw.Draw(canvas)
    parts = []
    x0 = y0 = 10
    for gi, g in enumerate(groups):
        if layout == 'rows':
            lb = S.draw_text_box(d, (x0, y0), S.letter_text(gi, style), lf)
            boxes, xe = place_row(canvas, g, x0, lb[3] + 4, h, gap_in)
            parts.append(lb + [0])
            parts[-1] = [min(lb[0], boxes[0][0]), lb[1], max(xe, lb[2]), boxes[0][3]]
            y0 = boxes[0][3] + gap_out
        else:
            lb = S.draw_text_box(d, (x0, y0), S.letter_text(gi, style), lf)
            yy, xe = lb[3] + 4, x0
            for im in g:
                w = int(im.width * (h * 0.8) / im.height)
                canvas.paste(im.resize((max(8, w), int(h * 0.8)), Image.Resampling.LANCZOS), (x0, yy))
                xe = max(xe, x0 + w)
                yy += int(h * 0.8) + gap_in
            parts.append([x0, lb[1], xe, yy - gap_in])
            x0 = xe + gap_out
    W = int(max(p[2] for p in parts)) + 10
    H = int(max(p[3] for p in parts)) + 10
    canvas = canvas.crop((0, 0, W, H))
    return canvas, parts, []


def rounded(d, b, r, outline, width, fill=None):
    d.rounded_rectangle(b, radius=r, outline=outline, width=width, fill=fill)


def arrow(d, a, b, col, w):
    d.line([a, b], fill=col, width=w)
    ang = math.atan2(b[1] - a[1], b[0] - a[0])
    for s in (2.6, -2.6):
        d.line([b, (b[0] + 12 * math.cos(ang + s), b[1] + 12 * math.sin(ang + s))], fill=col, width=w)


def make_framed(pool, rng):
    n = rng.choice([2, 3, 3, 4])
    imgs = [S.load_panel(rng.choice(pool)) for _ in range(n)]
    if any(p is None for p in imgs):
        return None
    h = rng.randint(180, 280)
    pad, gap = rng.randint(8, 20), rng.randint(36, 70)
    style, lf = rng.choice(['paren', 'paren', 'upper', 'plain']), S.font(rng.randint(16, 24), rng)
    tint = rng.random() < .5
    col = tuple(rng.randint(60, 200) for _ in range(3))
    widths = [max(40, int(im.width * h / im.height)) for im in imgs]
    W = sum(widths) + n * 2 * pad + (n - 1) * gap + 20
    H = h + 2 * pad + 50
    canvas = Image.new('RGB', (W, H), 'white')
    d = ImageDraw.Draw(canvas)
    x, parts, shared = 10, [], []
    for i, (im, w) in enumerate(zip(imgs, widths)):
        box = [x, 10, x + w + 2 * pad, 10 + h + 2 * pad + 30]
        fill = tuple(min(255, c + 150) for c in col) if tint else None
        rounded(d, box, 12, col, 3, fill)
        canvas.paste(im.resize((w, h), Image.Resampling.LANCZOS), (x + pad, 10 + pad + 30))
        S.draw_text_box(d, (x + 8, 14), S.letter_text(i, style) + ' ' + rng.choice(S.WORDS).title(), lf)
        parts.append(box)
        if i < n - 1:
            ya = 10 + (h + 2 * pad + 30) // 2
            a, b = (box[2] + 4, ya), (box[2] + gap - 4, ya)
            arrow(d, a, b, (40, 40, 40), 3)
            shared.append([a[0], ya - 10, b[0], ya + 10])
        x = box[2] + gap
    return canvas, parts, shared


def photo_patch(item, rng):
    im = Image.open(item['image']).convert('RGB')
    W, H = im.size
    f = rng.uniform(.3, .6)
    w, h = max(16, int(W * f)), max(16, int(H * f))
    x, y = rng.randint(0, W - w), rng.randint(0, H - h)
    return im.crop((x, y, x + w, y + h))


def make_touching(pool, rng, lettered=True):
    rows, cols = rng.choice([(1, 3), (2, 2), (2, 3), (2, 4), (3, 3), (1, 4)])
    imgs = [photo_patch(rng.choice(pool), rng) for _ in range(rows * cols)]
    if any(p is None for p in imgs):
        return None
    cw, ch = rng.randint(140, 230), rng.randint(120, 200)
    gap = rng.choice([0, 0, 1, 2])
    W, H = cols * cw + (cols - 1) * gap, rows * ch + (rows - 1) * gap
    canvas = Image.new('RGB', (W, H), 'white')
    d = ImageDraw.Draw(canvas)
    lf = S.font(rng.randint(16, 26), rng)
    style = rng.choice(['plain', 'upper', 'paren'])
    parts = []
    for i, im in enumerate(imgs):
        r, c = divmod(i, cols)
        x, y = c * (cw + gap), r * (ch + gap)
        canvas.paste(im.resize((cw, ch), Image.Resampling.LANCZOS), (x, y))
        if lettered:
            t = S.letter_text(i, style)
            white = rng.random() < .6
            d.text((x + 6, y + 4), t, font=lf, fill=(255, 255, 255) if white else (0, 0, 0),
                   stroke_width=2, stroke_fill=(0, 0, 0) if white else (255, 255, 255))
        parts.append([x, y, x + cw, y + ch])
    if not lettered:
        return canvas, [[0, 0, W, H]], []
    return canvas, parts, []


def make_many(pool, rng):
    n = rng.randint(5, 12)
    cols = rng.choice([c for c in (3, 4, 5, 6) if c <= n])
    imgs = [S.load_panel(rng.choice(pool)) for _ in range(n)]
    if any(p is None for p in imgs):
        return None
    cw, ch = rng.randint(140, 220), rng.randint(110, 170)
    gap = rng.choice([4, 10, 18])
    lf = S.font(rng.randint(13, 18), rng)
    style = rng.choice(['paren', 'plain', 'upper'])
    lh = int(lf.size * 1.4)
    rows = math.ceil(n / cols)
    W, H = cols * cw + (cols - 1) * gap + 10, rows * (ch + lh) + (rows - 1) * gap + 10
    canvas = Image.new('RGB', (W, H), 'white')
    d = ImageDraw.Draw(canvas)
    parts = []
    for i, im in enumerate(imgs):
        r, c = divmod(i, cols)
        x, y = 5 + c * (cw + gap), 5 + r * (ch + lh + gap)
        lb = S.draw_text_box(d, (x, y), S.letter_text(i, style), lf)
        s = min(cw / im.width, ch / im.height)
        w, h = max(8, int(im.width * s)), max(8, int(im.height * s))
        canvas.paste(im.resize((w, h), Image.Resampling.LANCZOS), (x, y + lh))
        parts.append([x, lb[1], x + max(w, lb[2] - x), y + lh + h])
    return canvas, parts, []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pool', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--kind', choices=['groups', 'framed', 'touching', 'many'], required=True)
    ap.add_argument('--n', type=int, default=1500)
    ap.add_argument('--negative-share', type=float, default=0.0)
    ap.add_argument('--seed', type=int, default=20261022)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    pool = [json.loads(l) for l in args.pool.read_text().splitlines() if l.strip()]
    plots = [p for p in pool if p['kind'] in ('vector-single', 'vector-panel')]
    other = [p for p in pool if p['kind'] not in ('vector-single', 'vector-panel')]
    photos = [p for p in other if p.get('ink_fraction', 0) >= 0.7] or other
    for p in pool:
        if p['kind'] == 'vector-panel':
            SIBLINGS.setdefault(p['image'], []).append(p)
    src = {'groups': plots, 'many': plots, 'framed': other + plots, 'touching': photos}[args.kind]
    (args.out / 'images').mkdir(parents=True, exist_ok=True)
    rows, made, tries = [], 0, 0
    while made < args.n and tries < args.n * 5:
        tries += 1
        neg = args.kind == 'touching' and rng.random() < args.negative_share
        try:
            res = {'groups': make_groups, 'framed': make_framed, 'many': make_many}[args.kind](src, rng) \
                if args.kind != 'touching' else make_touching(src, rng, lettered=not neg)
        except (ValueError, OSError):
            res = None
        if res is None:
            continue
        canvas, parts, shared = res
        arr = np.asarray(canvas.convert('L')) < 235
        parts = [tight(arr, b) for b in parts]
        shared = [tight(arr, b) for b in shared]
        if any(p is None for p in parts):
            continue
        if not neg and len(parts) > 1 and any(P_area_overlap(parts[a], parts[b]) for a in range(len(parts)) for b in range(a + 1, len(parts))):
            continue
        fid = f'syn{args.kind[:3]}{args.seed % 100:02d}-{made:05d}'
        path = args.out / 'images' / f'{fid}.png'
        canvas.save(path)
        rows.append({'id': fid, 'image': str(path), 'width': canvas.width, 'height': canvas.height,
                     'paper': f'synthetic-{args.kind}', 'source': f'synthetic-{args.kind}' + ('-negative' if neg else ''),
                     'boxes': [{'box': b, 'class': 0} for b in parts] + [{'box': b, 'class': 1} for b in shared if b]})
        made += 1
    (args.out / 'rows.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    print(args.kind, made, 'of', tries)


def P_area_overlap(a, b):
    w = min(a[2], b[2]) - max(a[0], b[0]); h = min(a[3], b[3]) - max(a[1], b[1])
    if w <= 0 or h <= 0:
        return False
    return w * h > 0.02 * min((a[2] - a[0]) * (a[3] - a[1]), (b[2] - b[0]) * (b[3] - b[1]))


if __name__ == '__main__':
    main()
