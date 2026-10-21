#!/usr/bin/env python3
"""Contact sheets for visual review: each tile shows an image with numbered boxes.

Input JSONL rows need `image` and any of: `panel_boxes` (green), `shared_boxes` (blue),
`pred` (list of {box, score}) (red), `gt` (list of boxes) (green). Pixel xyxy boxes.
"""
import argparse, json, math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

COLORS = {'panel_boxes': (0, 170, 0), 'gt': (0, 170, 0), 'shared_boxes': (0, 90, 255), 'gt_shared': (0, 90, 255),
          'pred': (230, 0, 0), 'cores': (255, 160, 0)}


def font(size):
    for p in ('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', '/System/Library/Fonts/Supplemental/Arial Bold.ttf'):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            pass
    return ImageFont.load_default()


def tile(row, size, keys, root):
    img = Image.open(root / row['image'] if root else row['image']).convert('RGB')
    W, H = img.size
    s = min(size / W, (size - 28) / H)
    im = img.resize((max(1, int(W * s)), max(1, int(H * s))), Image.Resampling.LANCZOS)
    canvas = Image.new('RGB', (size, size), (245, 245, 245))
    canvas.paste(im, (0, 28))
    d = ImageDraw.Draw(canvas)
    f = font(14)
    title = row.get('title') or f"{row.get('id', '')}"
    d.text((3, 3), title[:70], fill=(0, 0, 0), font=f)
    for key in keys:
        boxes = row.get(key) or []
        for k, b in enumerate(boxes):
            if isinstance(b, dict):
                label = f"{k}:{b.get('score', 0):.2f}" if 'score' in b else str(k)
                b = b['box']
            else:
                label = str(k)
            x0, y0, x1, y1 = [v * s for v in b]
            col = COLORS.get(key, (200, 0, 200))
            w = 3 if key in ('pred',) else 2
            d.rectangle([x0, y0 + 28, x1, y1 + 28], outline=col, width=w)
            d.text((x0 + 3, y0 + 30), label, fill=col, font=f)
    return canvas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rows', type=Path)
    ap.add_argument('out', type=Path)
    ap.add_argument('--keys', default='panel_boxes,shared_boxes')
    ap.add_argument('--cols', type=int, default=3)
    ap.add_argument('--per', type=int, default=9)
    ap.add_argument('--size', type=int, default=520)
    ap.add_argument('--root', type=Path)
    ap.add_argument('--start', type=int, default=0)
    args = ap.parse_args()
    rows = [json.loads(l) for l in args.rows.read_text().splitlines() if l.strip()][args.start:]
    keys = args.keys.split(',')
    args.out.mkdir(parents=True, exist_ok=True)
    for sheet in range(math.ceil(len(rows) / args.per)):
        chunk = rows[sheet * args.per:(sheet + 1) * args.per]
        rows_n = math.ceil(len(chunk) / args.cols)
        out = Image.new('RGB', (args.cols * args.size, rows_n * args.size), 'white')
        for k, r in enumerate(chunk):
            out.paste(tile(r, args.size, keys, args.root), ((k % args.cols) * args.size, (k // args.cols) * args.size))
        out.save(args.out / f'sheet-{sheet + args.start // args.per:03d}.jpg', quality=88)


if __name__ == '__main__':
    main()
