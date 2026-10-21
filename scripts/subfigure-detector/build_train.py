#!/usr/bin/env python3
"""Assemble training manifests (train2.py row format) and the frozen-validation GT file.

Row: {id, image, width, height, paper, source, boxes:[{box:[x1,y1,x2,y2], class}]}, class 0 = complete
panel, class 1 = shared context. Only papers assigned `train` by split.py enter training rows.
"""
import argparse, collections, json, re, sys
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import policy as P
from pathlib import Path

PAREN = re.compile(r'^\(([a-h])\)$|^([a-h])\)$')


def stats_flag(r):
    return r.get('_grouped', False)


def vector_rows(labels, split, min_shared=0.002):
    stats = collections.Counter()
    out = []
    for line in labels.open():
        r = json.loads(line)
        if split.get(r['paper']) != 'train':
            stats['not_train_split'] += 1; continue
        if r.get('reject'):
            stats['reject:' + r['reject']] += 1; continue
        n = r['panels']
        L = len(r.get('caption_letters') or [])
        toks = {(m.group(1) or m.group(2)) for t in (r.get('letters') or []) for m in [PAREN.match(t['text'].strip())] if m}
        if n == 1 and (L >= 2 or len(toks) >= 2):
            stats['single_but_lettered'] += 1; continue
        if n >= 2 and L >= 2 and n != L:
            grouped = P.group_to_count(r['panel_boxes'], L) if n > L else None
            if not grouped:
                stats['caption_count_mismatch'] += 1; continue
            # Lettered rows/columns of plots: the caption's parts are groups of plotting areas. Shared
            # boxes hugging one group (its row title) join it; printed letters, if any, must be one per group.
            H = r['H']; shared_left = []
            for sb in r['shared_boxes']:
                near = sorted((P.gap(sb, gb), k) for k, gb in enumerate(grouped))
                inside_x = grouped[near[0][1]][0] - 0.05 * r['W'] <= sb[0] and sb[2] <= grouped[near[0][1]][2] + 0.05 * r['W']
                if near[0][0] < 0.03 * H and inside_x and (len(near) == 1 or near[1][0] > near[0][0] + 0.01 * H):
                    grouped[near[0][1]] = P.union(grouped[near[0][1]], sb)
                else:
                    shared_left.append(sb)
            lets = [t['box'] for t in (r.get('letters') or []) if PAREN.match(t['text'].strip())]
            if lets and not (len(lets) == L and all(sum(P.area(P.inter(lb, gb)) > 0.5 * P.area(lb) for lb in lets) == 1 for gb in grouped)):
                stats['grouped_letter_mismatch'] += 1; continue
            if any(P.area(P.inter(grouped[a], grouped[b])) > 0.03 * min(P.area(grouped[a]), P.area(grouped[b])) for a in range(L) for b in range(a + 1, L)):
                stats['grouped_overlap'] += 1; continue
            r = dict(r, panel_boxes=grouped, shared_boxes=shared_left, panels=L, _grouped=True)
            n = L
            stats['caption_grouped'] += 1
        if n >= 2 and len(toks) >= 2 and len(toks) != n:
            stats['letter_token_mismatch'] += 1; continue
        if n > 12 or r['min_panel_area_fraction'] < 0.003:
            stats['too_small_or_many'] += 1; continue
        W, H = r['W'], r['H']
        boxes = [{'box': b, 'class': 0} for b in r['panel_boxes']]
        boxes += [{'box': b, 'class': 1} for b in r['shared_boxes'] if (b[2] - b[0]) * (b[3] - b[1]) >= min_shared * W * H]
        out.append({'id': r['id'], 'image': r['image'], 'width': W, 'height': H, 'paper': r['paper'],
                    'source': ('vector-grouped' if stats_flag(r) else 'vector-compound') if n >= 2 else 'vector-single', 'boxes': boxes,
                    'caption_letters': L})
        stats['kept_compound' if n >= 2 else 'kept_single'] += 1
    return out, stats


def old_rows(path, root):
    out = []
    for line in Path(path).read_text().splitlines():
        r = json.loads(line)
        boxes = [{'box': b['box'], 'class': 0 if b['class'] == 4 else 1} for b in r['boxes']]
        src = r.get('source', '')
        kind = 'generated' if 'generator' in src.lower() else ('arxiv-reviewed' if 'mathpix' in src.lower() else 'sci3000')
        out.append({'id': r['id'], 'image': str(Path(root) / r['image']), 'width': r['width'], 'height': r['height'],
                    'paper': r.get('paper') or r.get('group'), 'source': 'old-' + kind, 'boxes': boxes})
    return out


def gt_rows(path, root, name):
    out = []
    for line in Path(path).read_text().splitlines():
        r = json.loads(line)
        out.append({'id': r['id'], 'image': str(Path(root) / r['image']), 'width': r['width'], 'height': r['height'],
                    'paper': r.get('paper') or r.get('group'), 'split': 'validation', 'source': name,
                    'stratum': 'arxiv' if 'arxiv' in r['id'] else 'sci3000',
                    'panels': [b['box'] for b in r['boxes'] if b['class'] == 4],
                    'shared': [b['box'] for b in r['boxes'] if b['class'] != 4]})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vector', type=Path, required=True)
    ap.add_argument('--split', type=Path, required=True)
    ap.add_argument('--old', type=Path, required=True, help='old manifest dir (targeted-balanced-v1)')
    ap.add_argument('--old-root', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    split = json.loads(args.split.read_text())['split']
    args.out.mkdir(parents=True, exist_ok=True)
    vec, stats = vector_rows(args.vector, split)
    by = collections.defaultdict(list)
    for r in vec:
        by[r['source']].append(r)
    for k, rows in by.items():
        (args.out / f'{k}.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    old = old_rows(args.old / 'train.jsonl', args.old_root)
    byo = collections.defaultdict(list)
    for r in old:
        byo[r['source']].append(r)
    for k, rows in byo.items():
        (args.out / f'{k}.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    gts = gt_rows(args.old / 'validation.jsonl', args.old_root, 'frozen-validation')
    (args.out / 'frozen-validation-gt.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in gts))
    summary = {'vector_filter': stats, 'files': {k: len(v) for k, v in {**by, **byo}.items()}, 'frozen_validation': len(gts)}
    (args.out / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
