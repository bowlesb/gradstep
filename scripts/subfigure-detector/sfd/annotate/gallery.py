#!/usr/bin/env python3
"""Failure/success galleries: per outcome category, contact sheets with ground-truth panels (green),
shared context (blue) and the delivered crops as displayed (red, 2% margin)."""
import argparse, collections, json
from pathlib import Path

from sfd.annotate import sheet as S
from sfd.core import policy as P
from PIL import Image


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gt', type=Path, required=True)
    ap.add_argument('--rows', type=Path, required=True, help='evaluate rows with crops (breakdown output)')
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--per', type=int, default=12)
    args = ap.parse_args()
    gts = {json.loads(l)['id']: json.loads(l) for l in args.gt.read_text().splitlines() if l.strip()}
    rows = json.loads(args.rows.read_text())
    if isinstance(rows, dict):
        rows = rows['figures']
    by = collections.defaultdict(list)
    for r in rows:
        g = gts[r['id']]
        W, H = g['width'], g['height']
        by[r['outcome']].append({'image': g['image'], 'gt': g['panels'], 'gt_shared': g.get('shared', []),
                                 'pred': [{'box': P.display_box(c, W, H), 'score': 0} for c in r['crops']],
                                 'title': f"{r['id']} {r['outcome']} gt={r['n_gt']} crops={r['n_crops']}"})
    args.out.mkdir(parents=True, exist_ok=True)
    for k, items in by.items():
        f = args.out / f'{k}.jsonl'
        f.write_text(''.join(json.dumps(x) + '\n' for x in items[:args.per]))
        tiles = [S.tile(x, 480, ['gt', 'gt_shared', 'pred'], None) for x in items[:args.per]]
        cols = 4
        rows_n = (len(tiles) + cols - 1) // cols
        im = Image.new('RGB', (cols * 480, rows_n * 480), 'white')
        for i, t in enumerate(tiles):
            im.paste(t, ((i % cols) * 480, (i // cols) * 480))
        im.save(args.out / f'{k}.jpg', quality=85)
        print(k, len(items))


if __name__ == '__main__':
    main()
