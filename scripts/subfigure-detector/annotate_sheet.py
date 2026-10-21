#!/usr/bin/env python3
"""Annotation sheets: each tile shows the figure with numbered whitespace blocks (thin, cycling
colours) and, when present, the vector-derived proposal (thick green panels, blue shared).
A reviewer answers per figure: vector-ok, single, block groups, or exclude."""
import argparse, json, math, textwrap
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

CYCLE = [(220, 0, 0), (0, 0, 220), (200, 0, 200), (0, 150, 150), (230, 120, 0), (90, 90, 90)]


def font(size):
    for p in ('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            pass
    return ImageFont.load_default()


def tile(r, size, mode, grid=False):
    img = Image.open(r['image']).convert('RGB')
    W, H = img.size
    head = 64
    s = min(size / W, (size - head) / H)
    im = img.resize((max(1, int(W * s)), max(1, int(H * s))), Image.Resampling.LANCZOS)
    canvas = Image.new('RGB', (size, size), (250, 250, 250))
    canvas.paste(im, (0, head))
    d = ImageDraw.Draw(canvas)
    f, fs = font(15), font(12)
    letters = ''.join(r.get('caption_letters') or [])
    d.text((3, 2), f"#{r['k']} {r['id']} L={letters}", fill=(0, 0, 0), font=f)
    cap = textwrap.shorten(r.get('caption', ''), 230)
    for i, line in enumerate(textwrap.wrap(cap, 95)[:3]):
        d.text((3, 20 + 14 * i), line, fill=(60, 60, 60), font=fs)
    v = r.get('vector') or {}
    if mode in ('vector', 'both') and v and not v.get('reject') and v.get('panel_boxes'):
        sx = s * W / v['W'] if v.get('W') else s
        for k, b in enumerate(v['panel_boxes']):
            x0, y0, x1, y1 = [c * sx for c in b]
            d.rectangle([x0, y0 + head, x1, y1 + head], outline=(0, 170, 0), width=4)
            d.text((x0 + 4, y0 + head + 2), f'P{k}', fill=(0, 140, 0), font=f)
        for k, b in enumerate(v.get('shared_boxes') or []):
            x0, y0, x1, y1 = [c * sx for c in b]
            d.rectangle([x0, y0 + head, x1, y1 + head], outline=(0, 90, 255), width=3)
            d.rectangle([x1 - 26, y1 + head - 15, x1, y1 + head], fill=(255, 255, 255))
            d.text((x1 - 25, y1 + head - 15), f'S{k}', fill=(0, 70, 230), font=fs)
    if grid:
        for t in range(1, 10):
            gx, gy = t / 10 * W * s, t / 10 * H * s + head
            d.line([gx, head, gx, head + H * s], fill=(255, 150, 150), width=1)
            d.line([0, gy, W * s, gy], fill=(255, 150, 150), width=1)
            d.text((gx + 1, head + 1), f'.{t}', fill=(220, 0, 0), font=fs)
            d.text((1, gy + 1), f'.{t}', fill=(220, 0, 0), font=fs)
    if mode in ('blocks', 'both'):
        for k, b in enumerate(r['blocks']):
            x0, y0, x1, y1 = [c * s for c in b]
            col = CYCLE[k % len(CYCLE)]
            d.rectangle([x0, y0 + head, x1, y1 + head], outline=col, width=1)
            tx, ty = x0 + 1, y0 + head + 1
            d.rectangle([tx, ty, tx + 9 * len(str(k)) + 3, ty + 14], fill=(255, 255, 255))
            d.text((tx + 1, ty), str(k), fill=col, font=fs)
    return canvas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('candidates', type=Path)
    ap.add_argument('out', type=Path)
    ap.add_argument('--mode', choices=['vector', 'blocks', 'both'], default='both')
    ap.add_argument('--ids', type=Path, help='optional list of ids to include (one per line)')
    ap.add_argument('--cols', type=int, default=3)
    ap.add_argument('--per', type=int, default=6)
    ap.add_argument('--size', type=int, default=640)
    ap.add_argument('--grid', action='store_true', help='draw 0.1 coordinate grid for normalized boxes')
    ap.add_argument('--fine', action='store_true', help='show fine whitespace blocks')
    args = ap.parse_args()
    rows = [json.loads(l) for l in args.candidates.read_text().splitlines()]
    for k, r in enumerate(rows):
        r['k'] = k
        if args.fine:
            r['blocks'] = r['blocks_fine']
    if args.ids:
        keep = set(args.ids.read_text().split())
        rows = [r for r in rows if r['id'] in keep]
    args.out.mkdir(parents=True, exist_ok=True)
    for sheet in range(math.ceil(len(rows) / args.per)):
        chunk = rows[sheet * args.per:(sheet + 1) * args.per]
        nr = math.ceil(len(chunk) / args.cols)
        out = Image.new('RGB', (args.cols * args.size, nr * args.size), 'white')
        for k, r in enumerate(chunk):
            out.paste(tile(r, args.size, args.mode, args.grid), ((k % args.cols) * args.size, (k // args.cols) * args.size))
        out.save(args.out / f'sheet-{sheet:03d}.jpg', quality=90)
    print(len(rows), 'figures')


if __name__ == '__main__':
    main()
