#!/usr/bin/env python3
"""Synthetic compound figures composed from real training-split panels, with exact complete boxes.

Panels come from (a) vector-labelled single figures, (b) complete panels cut from vector-labelled
compound figures, (c) raster/diagram figures (photos, diagrams) from training papers. Layouts:
regular grids, uneven grids, a large panel beside a stack; gutters from none to wide. Panel
letters in many styles/positions, optional subcaptions, shared legend strips, suptitles and
shared rotated y-labels (shared class). Hard negatives: one plot with a pasted inset, a plot
with a large side legend; both are labelled as ONE panel. Every label is renderer-exact.
"""
import argparse, json, random
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

Image.MAX_IMAGE_PIXELS = 200_000_000
FONTS = ['/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
         '/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf', '/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf',
         '/usr/share/fonts/truetype/liberation/LiberationSerif-Bold.ttf', '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf',
         '/usr/share/texmf/fonts/opentype/public/lm/lmroman10-regular.otf', '/usr/share/texmf/fonts/opentype/public/lm/lmroman10-bold.otf',
         '/usr/share/fonts/opentype/urw-base35/NimbusSans-Regular.otf', '/usr/share/fonts/opentype/urw-base35/NimbusRoman-Regular.otf']
WORDS = ('loss accuracy baseline ours training validation test epoch step model method error rate time layer '
         'attention ablation dataset noise scale depth width gradient reward policy prior posterior sample').split()


def font(size, rng):
    for _ in range(4):
        try:
            return ImageFont.truetype(rng.choice(FONTS), size)
        except OSError:
            pass
    return ImageFont.load_default()


def ink_bbox(img):
    a = np.asarray(img.convert('L'))
    ys, xs = np.nonzero(a < 235)
    if len(xs) == 0:
        return None
    return [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]


def load_panel(item):
    im = Image.open(item['image']).convert('RGB')
    if item.get('crop'):
        im = im.crop(tuple(int(round(v)) for v in item['crop']))
    b = ink_bbox(im)
    if b is None:
        return None
    return im.crop(b)


def letter_text(k, style):
    c = 'abcdefghijkl'[k]
    return {'paren': f'({c})', 'plain': c, 'upper': c.upper(), 'paren_upper': f'({c.upper()})', 'close': f'{c})', 'dot': f'{c.upper()}.'}[style]


def draw_text_box(draw, xy, text, fnt, fill=(0, 0, 0)):
    draw.text(xy, text, font=fnt, fill=fill)
    return list(draw.textbbox(xy, text, font=fnt))


def legend_strip(width, rng, n=None):
    n = n or rng.randint(2, 5)
    fnt = font(rng.randint(14, 22), rng)
    items = []
    for _ in range(n):
        items.append((tuple(int(v) for v in rng.choice([(31, 119, 180), (255, 127, 14), (44, 160, 44), (214, 39, 40), (148, 103, 189), (140, 86, 75)])),
                      ' '.join(rng.sample(WORDS, rng.randint(1, 2)))))
    probe = ImageDraw.Draw(Image.new('RGB', (10, 10)))
    widths = [40 + probe.textlength(t, font=fnt) + 30 for _, t in items]
    h = int(fnt.size * 1.8)
    im = Image.new('RGB', (max(int(sum(widths)) + 20, 50), h), 'white')
    d = ImageDraw.Draw(im)
    x = 10
    for (col, t), w in zip(items, widths):
        d.line([x, h // 2, x + 30, h // 2], fill=col, width=3)
        d.text((x + 38, h // 2 - fnt.size // 2 - 2), t, font=fnt, fill=(0, 0, 0))
        x += w
    if rng.random() < .4:
        d.rectangle([1, 1, im.width - 2, im.height - 2], outline=(160, 160, 160), width=1)
    return im


def compose(panels, rng):
    """Row packing: panels in a row share a height (as matplotlib/LaTeX layouts do); gutters vary from
    touching to wide; letters/subcaptions/shared legends/titles/y-labels are drawn and labelled exactly."""
    n = len(panels)
    if n <= 4 and rng.random() < .55:
        per_row = n
    else:
        per_row = rng.choice([c for c in (2, 3, 4) if c < n] or [n])
    rows = [panels[i:i + per_row] for i in range(0, n, per_row)]
    target_w = rng.randint(900, 1500)
    gutter = int(target_w * rng.choice([0.0, 0.004, 0.012, 0.025, 0.04, 0.07]))
    letters = rng.random() < .7
    style = rng.choice(['paren', 'paren', 'plain', 'upper', 'paren_upper', 'close', 'dot'])
    pos = rng.choice(['tl_out', 'tl_in', 'bottom', 'top_center', 'tl_out', 'bottom'])
    subcap = letters and pos == 'bottom' and rng.random() < .6
    lf = font(max(12, int(target_w * rng.uniform(.014, .024))), rng)
    lh = int(lf.size * 1.45) if letters and pos in ('tl_out', 'top_center') else 0
    bh = int(lf.size * 1.6) if letters and pos == 'bottom' else 0
    placed = []  # (panel, x, y, w, h)
    y = 0
    prev_h = None
    widths = []
    for row in rows:
        ars = [p.width / p.height for p in row]
        h = (target_w - gutter * (len(row) - 1)) / sum(ars)
        h = max(40, min(h, target_w * 0.9, prev_h * 1.25 if prev_h else 1e9))
        prev_h = h
        x = 0
        for p, ar in zip(row, ars):
            w = max(20, int(ar * h))
            placed.append((p, x, y + lh, w, int(h)))
            x += w + gutter
        widths.append(x - gutter)
        y += lh + int(h) + bh + max(gutter, int(lf.size * .5) if letters else gutter)
    W0, H0 = max(widths), y
    top_band = int(H0 * rng.choice([.07, .1])) if rng.random() < .3 else 0
    bottom_band = int(lf.size * 2.6) if rng.random() < .25 else 0
    left_band = int(W0 * .05) if rng.random() < .12 else 0
    canvas = Image.new('RGB', (W0 + left_band, H0 + top_band + bottom_band), 'white')
    d = ImageDraw.Draw(canvas)
    boxes, shared = [], []
    row_widths = iter([w for w, row in zip(widths, rows) for _ in row])
    for k, (p, x, yy, w, h) in enumerate(placed):
        rw = next(row_widths)
        off = left_band + (W0 - rw) // 2 if rng.random() < 0.0 else left_band + (W0 - rw) // 2
        px, py = x + off, yy + top_band
        canvas.paste(p.resize((w, h), Image.Resampling.LANCZOS), (px, py))
        box = [px, py, px + w, py + h]
        if letters:
            t = letter_text(k, style)
            if pos == 'tl_out':
                lb = draw_text_box(d, (px, py - lh), t, lf)
            elif pos == 'tl_in':
                lb = draw_text_box(d, (px + 3, py + 3), t, lf)
            elif pos == 'top_center':
                lb = draw_text_box(d, (px + w / 2 - lf.size, py - lh), t, lf)
            else:
                t2 = t + (' ' + ' '.join(rng.sample(WORDS, rng.randint(1, 3))) if subcap else '')
                tw = d.textlength(t2, font=lf)
                lb = draw_text_box(d, (px + w / 2 - tw / 2, py + h + 3), t2, lf)
            box = [min(box[0], lb[0]), min(box[1], lb[1]), max(box[2], lb[2]), max(box[3], lb[3])]
        boxes.append(box)
    W, H = W0, H0
    if top_band:
        if rng.random() < .5:
            leg = legend_strip(W, rng)
            if leg.width > W * .95:
                leg = leg.resize((int(W * .95), max(4, int(leg.height * W * .95 / leg.width))))
            x = left_band + (W - leg.width) // 2; yy = max(0, (top_band - leg.height) // 2)
            canvas.paste(leg, (x, yy)); shared.append([x, yy, x + leg.width, yy + leg.height])
        else:
            tf = font(max(14, int(top_band * .45)), rng)
            t = ' '.join(rng.sample(WORDS, rng.randint(2, 5))).title()
            tw = d.textlength(t, font=tf)
            shared.append(draw_text_box(d, (left_band + W / 2 - tw / 2, top_band * .2), t, tf))
    if bottom_band:
        leg = legend_strip(W, rng)
        if leg.width > W * .95:
            leg = leg.resize((int(W * .95), max(4, int(leg.height * W * .95 / leg.width))))
        x = left_band + (W - leg.width) // 2; yy = top_band + H + max(0, (bottom_band - leg.height) // 2)
        canvas.paste(leg, (x, yy)); shared.append([x, yy, x + leg.width, yy + leg.height])
    if left_band:
        tf = font(max(12, int(left_band * .45)), rng)
        t = ' '.join(rng.sample(WORDS, rng.randint(1, 3)))
        tim = Image.new('RGB', (int(d.textlength(t, font=tf)) + 6, int(tf.size * 1.4)), 'white')
        ImageDraw.Draw(tim).text((3, 0), t, font=tf, fill=(0, 0, 0))
        tim = tim.rotate(90, expand=True)
        yy = top_band + (H - tim.height) // 2
        canvas.paste(tim, (int(left_band * .2), max(0, yy)))
        bb = ink_bbox(tim)
        if bb:
            shared.append([int(left_band * .2) + bb[0], max(0, yy) + bb[1], int(left_band * .2) + bb[2], max(0, yy) + bb[3]])
    arr = np.asarray(canvas.convert('L')) < 235

    def tight(b):
        x0, y0, x1, y1 = [int(v) for v in b]
        sub = arr[max(0, y0):y1, max(0, x0):x1]
        ys, xs = np.nonzero(sub)
        if len(xs) == 0:
            return None
        return [float(max(0, x0) + xs.min()), float(max(0, y0) + ys.min()), float(max(0, x0) + xs.max() + 1), float(max(0, y0) + ys.max() + 1)]
    boxes = [tight(b) for b in boxes]
    shared = [tight(b) for b in shared]
    if any(b is None for b in boxes):
        return None
    for a_ in range(len(boxes)):
        for b_ in range(a_ + 1, len(boxes)):
            A, B = boxes[a_], boxes[b_]
            ov = max(0, min(A[2], B[2]) - max(A[0], B[0])) * max(0, min(A[3], B[3]) - max(A[1], B[1]))
            if ov > 0.01 * min((A[2] - A[0]) * (A[3] - A[1]), (B[2] - B[0]) * (B[3] - B[1])):
                return None
    return canvas, boxes, [x for x in shared if x]


def hard_negative(base, inset, rng):
    """One plot with a pasted inset, or with a large side legend: still ONE panel."""
    W, H = base.size
    canvas = base.copy()
    if inset is not None and rng.random() < .5:
        s = rng.uniform(.22, .35) * min(W / inset.width, H / inset.height)
        iw, ih = max(8, int(inset.width * s)), max(8, int(inset.height * s))
        x = int(rng.choice([.55, .6]) * W); y = int(rng.choice([.1, .15, .5]) * H)
        x = min(x, W - iw - 2); y = min(y, H - ih - 2)
        im = inset.resize((iw, ih), Image.Resampling.LANCZOS)
        canvas.paste(im, (x, y))
        ImageDraw.Draw(canvas).rectangle([x, y, x + iw - 1, y + ih - 1], outline=(0, 0, 0), width=1)
        kind = 'inset'
    else:
        leg = legend_strip(W, rng, rng.randint(3, 6)).rotate(0)
        new = Image.new('RGB', (W + leg.width // 2 + 20, max(H, leg.height)), 'white')
        new.paste(canvas, (0, 0))
        # stacked legend entries to the right
        lg = Image.new('RGB', (leg.width // 2 + 10, leg.height * 3), 'white')
        lg.paste(leg.crop((0, 0, leg.width // 2, leg.height)), (0, 0))
        lg.paste(leg.crop((leg.width // 2, 0, leg.width, leg.height)), (0, leg.height + 4))
        new.paste(lg, (W + 10, H // 3))
        canvas, kind = new, 'side_legend'
    b = ink_bbox(canvas)
    return canvas, [[float(v) for v in b]], kind


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pool', type=Path, required=True, help='JSONL of {image, crop?, kind}')
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--n', type=int, default=4000)
    ap.add_argument('--negatives', type=int, default=800)
    ap.add_argument('--seed', type=int, default=20261021)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    pool = [json.loads(l) for l in args.pool.read_text().splitlines() if l.strip()]
    plots = [p for p in pool if p['kind'] in ('vector-single', 'vector-panel')]
    other = [p for p in pool if p['kind'] not in ('vector-single', 'vector-panel')]
    (args.out / 'images').mkdir(parents=True, exist_ok=True)
    rows, made, tries = [], 0, 0
    while made < args.n and tries < args.n * 4:
        tries += 1
        n = rng.choice([2, 2, 2, 3, 3, 4, 4, 5, 6, 6, 8])
        mix = rng.random()
        src = plots if mix < .45 else (other if mix < .75 else plots + other)
        if len(src) < n:
            continue
        items = rng.sample(src, n)
        panels = [load_panel(it) for it in items]
        if any(p is None for p in panels):
            continue
        if rng.random() < .7:
            # Real compound figures mostly combine panels of similar shape: keep only similar aspects.
            ars = sorted(p.width / p.height for p in panels)
            if ars[-1] / ars[0] > 2.2:
                continue
        if any(p is None or p.width < 30 or p.height < 30 for p in panels):
            continue
        res = compose(panels, rng)
        if res is None:
            continue
        canvas, boxes, shared = res
        fid = f'synth{args.seed % 100:02d}-{made:05d}'
        path = args.out / 'images' / f'{fid}.png'
        canvas.save(path)
        rows.append({'id': fid, 'image': str(path), 'width': canvas.width, 'height': canvas.height,
                     'paper': 'synthetic:' + '|'.join(sorted({it['paper'] for it in items})), 'source': 'synthetic-compound',
                     'source_papers': [it['paper'] for it in items],
                     'boxes': [{'box': b, 'class': 0} for b in boxes] + [{'box': b, 'class': 1} for b in shared]})
        made += 1
    neg = 0
    while neg < args.negatives:
        base = load_panel(rng.choice(plots))
        ins = load_panel(rng.choice(plots + other))
        if base is None or base.width < 120 or base.height < 100:
            continue
        canvas, boxes, kind = hard_negative(base, ins, rng)
        fid = f'synthneg{args.seed % 100:02d}-{neg:05d}'
        path = args.out / 'images' / f'{fid}.png'
        canvas.save(path)
        rows.append({'id': fid, 'image': str(path), 'width': canvas.width, 'height': canvas.height, 'paper': 'synthetic-negative',
                     'source': 'synthetic-negative-' + kind, 'boxes': [{'box': b, 'class': 0} for b in boxes]})
        neg += 1
    (args.out / 'rows.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    print('compound', made, 'negatives', neg)


if __name__ == '__main__':
    main()
