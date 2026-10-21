#!/usr/bin/env python3
"""Training rows from the caption-verified whitespace labeler, synthetic compositions and pseudo-labels.

Writes one JSONL per source in train2.py row format. Training-split papers only (re-checked here).
"""
import argparse, collections, glob, json
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--xycut', type=Path, required=True)
    ap.add_argument('--synth', nargs='*', default=[])
    ap.add_argument('--split', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--min-shared', type=float, default=0.002)
    args = ap.parse_args()
    split = json.loads(args.split.read_text())['split']
    args.out.mkdir(parents=True, exist_ok=True)
    groups, stats = collections.defaultdict(list), collections.Counter()
    for l in args.xycut.open():
        r = json.loads(l)
        if r.get('reject'):
            stats['reject:' + r['reject']] += 1
            continue
        if split.get(r['paper']) != 'train':
            stats['not_train'] += 1
            continue
        W, H = r['W'], r['H']
        boxes = [{'box': b, 'class': 0} for b in r['panels']]
        boxes += [{'box': b, 'class': 1} for b in r['shared'] if (b[2] - b[0]) * (b[3] - b[1]) >= args.min_shared * W * H]
        if r.get('single'):
            src = 'xycut-single'
        else:
            src = 'xycut-compound-verified' if r.get('letters_verified') else 'xycut-compound'
        groups[src].append({'id': r['id'], 'image': r['image'], 'width': W, 'height': H, 'paper': r['paper'], 'source': src, 'boxes': boxes})
        stats[src] += 1
    for pattern in args.synth:
        for f in glob.glob(pattern):
            for l in open(f):
                r = json.loads(l)
                if any(split.get(p) != 'train' for p in r.get('source_papers', [])):
                    stats['synth_nontrain_source'] += 1
                    continue
                src = 'synthetic-negative' if r['source'].startswith('synthetic-negative') else 'synthetic-compound'
                groups[src].append(r)
                stats[src] += 1
    for k, rows in groups.items():
        (args.out / f'{k}.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    print(json.dumps(stats, indent=1))


if __name__ == '__main__':
    main()
