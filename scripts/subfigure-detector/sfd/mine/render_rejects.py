#!/usr/bin/env python3
"""Render the lettered training figures the whitespace labeler rejected (count mismatch, overlap, letter
layout, dense background): the hard unlabeled pool for teacher pseudo-labels. Reads the corpus only."""
import json, multiprocessing as mp, sys
from pathlib import Path
from PIL import Image
from sfd.annotate import candidates as C

CORPUS = Path('/home/ben/mathpix/data/arxiv')


def job(r):
    dst = Path('data/hard-pool/images') / r['paper'] / f"{r['id']}.png"
    try:
        img = C.load_figure(str(CORPUS / r['paper'] / 'build' / 'src' / r['file']))
    except Exception:
        return None
    if img is None or min(img.shape[:2]) < 48:
        return None
    dst.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(img).save(dst, compress_level=3)
    return {'id': r['id'], 'paper': r['paper'], 'image': str(dst), 'width': int(img.shape[1]), 'height': int(img.shape[0]),
            'caption_letters': r['caption_letters'], 'xycut_reject': r['reject']}


if __name__ == '__main__':
    rows = [json.loads(l) for l in open('data/xycut-v2/labels.jsonl')]
    rows = [r for r in rows if r.get('reject') in ('count_mismatch', 'overlap', 'letter_layout_mismatch', 'dense_background') and len(r['caption_letters']) >= 2]
    with mp.Pool(16) as pool, open('data/hard-pool/rows.jsonl', 'w') as fo:
        for o in pool.imap_unordered(job, rows, chunksize=8):
            if o:
                fo.write(json.dumps(o) + '\n')
    print(len(rows))
