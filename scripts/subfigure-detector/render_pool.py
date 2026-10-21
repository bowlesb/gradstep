#!/usr/bin/env python3
"""Render training-split figures the vector labeler could not label (raster files, diagrams without
plotting areas) into the workspace: the pool for synthetic panels, teacher-filtered single-figure
negatives and pseudo-labelled compounds. Reads the corpus only."""
import argparse, hashlib, json, multiprocessing as mp, random
from pathlib import Path

from PIL import Image

import eval_candidates as C


def job(t):
    src, dst, rec = t
    try:
        img = C.load_figure(src)
    except Exception as e:
        return None
    if img is None or img.shape[0] < 48 or img.shape[1] < 48:
        return None
    Path(dst).parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(img).save(dst, compress_level=3)
    return {**rec, 'image': dst, 'width': int(img.shape[1]), 'height': int(img.shape[0])}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--corpus', type=Path, required=True)
    ap.add_argument('--figures', type=Path, required=True)
    ap.add_argument('--split', type=Path, required=True)
    ap.add_argument('--vector', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--n', type=int, default=20000)
    ap.add_argument('--workers', type=int, default=24)
    args = ap.parse_args()
    split = json.loads(args.split.read_text())['split']
    vec = {}
    for l in args.vector.open():
        r = json.loads(l)
        vec[r['id']] = r.get('reject')
    tasks = []
    for l in args.figures.open():
        f = json.loads(l)
        if split.get(f['paper']) != 'train' or f['n_includes'] != 1 or not f['includes'][0]['file']:
            continue
        fn = f['includes'][0]['file']
        fid = f"{f['paper']}-{f['index']:03d}"
        low = fn.lower()
        if low.endswith('.pdf'):
            if vec.get(fid) not in ('no_axes', 'too_many_axes', 'too_many_panels'):
                continue
            kind = 'pdf-' + vec[fid]
        elif low.endswith(('.png', '.jpg', '.jpeg')):
            kind = 'raster'
        else:
            continue
        rec = {'id': fid, 'paper': f['paper'], 'kind': kind, 'caption_letters': f['caption_letters'],
               'caption_spatial': f['caption_spatial'], 'caption': f['caption'][:600]}
        tasks.append((str(args.corpus / f['paper'] / 'build' / 'src' / fn), str(args.out / 'images' / f['paper'] / f'{fid}.png'), rec))
    random.Random(7).shuffle(tasks)
    tasks = tasks[:args.n]
    args.out.mkdir(parents=True, exist_ok=True)
    n = 0
    with mp.Pool(args.workers, maxtasksperchild=100) as pool, (args.out / 'pool.jsonl').open('w') as fo:
        for r in pool.imap_unordered(job, tasks, chunksize=8):
            if r:
                fo.write(json.dumps(r) + '\n'); n += 1
    print('rendered', n, 'of', len(tasks))


if __name__ == '__main__':
    main()
