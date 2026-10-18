#!/usr/bin/env python3
"""Freeze paper/duplicate-disjoint research splits; never download private reader data.

The TobiPoni dataset declares MIT but supplies no article-level rights manifest.
Its weights remain research-only. Preserve that distinction in every run manifest.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re

import numpy as np
from PIL import Image
from scipy.fft import dctn

CLASSES = ['shared_legend', 'shared_title', 'shared_x_axis', 'shared_y_axis', 'panel']
REVISION = '6439d75905c5486a17ff9b343239faba5a9c7da2'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def phash(image):
    a = np.asarray(image.convert('L').resize((32, 32), Image.Resampling.LANCZOS), dtype=float)
    f = dctn(a, norm='ortho')[:8, :8].flatten()[1:]
    return int(''.join('1' if x > np.median(f) else '0' for x in f), 2)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    if args.out.exists():
        raise ValueError('Immutable dataset revision already exists; use a new output directory')
    root, source = args.root.resolve(), args.source.resolve()
    rows, rejected, seen = [], [], {}
    for path in sorted((source / 'images').glob('*/*')):
        if not path.is_file() or path.suffix.lower() not in ('.png', '.jpg', '.jpeg'):
            continue
        identifier = path.stem
        if not re.match(r'^[a-f0-9]{32}-', identifier):
            # Upstream mixes generated plots into the same archive. Their generator/family
            # provenance is unavailable; exclude them rather than leak templates into test.
            rejected.append({'id': identifier, 'reason': 'no_source_paper_or_generator_family'}); continue
        labels = source / 'labels' / path.parent.name / (identifier + '.txt')
        if not labels.is_file():
            rejected.append({'id': identifier, 'reason': 'missing_labels'}); continue
        image = Image.open(path).convert('RGB')
        width, height = image.size
        boxes, failure, clipped = [], None, 0
        for line in labels.read_text().splitlines():
            values = list(map(float, line.split()))
            if len(values) != 5 or not np.isfinite(values).all():
                failure = 'malformed_box'; break
            c, x, y, w, h = values
            if c != int(c) or c < 0 or c >= len(CLASSES) or w <= 0 or h <= 0:
                failure = 'invalid_class_or_extent'; break
            box = [(x-w/2)*width, (y-h/2)*height, (x+w/2)*width, (y+h/2)*height]
            # Tolerate subpixel/rounding annotation errors only, recording them.
            if min(box[:2]) < -2 or box[2] > width+2 or box[3] > height+2:
                failure = 'out_of_bounds'; break
            bound = [max(0., box[0]), max(0., box[1]), min(float(width), box[2]), min(float(height), box[3])]
            clipped += box != bound
            boxes.append({'class': int(c), 'box': bound})
        if failure or not any(b['class'] == 4 for b in boxes):
            rejected.append({'id': identifier, 'reason': failure or 'no_panel'}); continue
        digest = sha(path)
        annotation_hash = hashlib.sha256(json.dumps(boxes, sort_keys=True).encode()).hexdigest()
        if digest in seen:
            old = seen[digest]
            if old['annotation_sha256'] != annotation_hash:
                rejected.append({'id': identifier, 'reason': 'conflicting_duplicate_annotation', 'other': old['id']})
            else:
                rejected.append({'id': identifier, 'reason': 'byte_duplicate', 'other': old['id']})
            old.setdefault('duplicate_papers', []).append(identifier.split('-')[0])
            continue
        row = {'id': identifier, 'image': str(path.relative_to(root)), 'sha256': digest,
               'width': width, 'height': height, 'paper': identifier.split('-')[0],
               'source_split': path.parent.name, 'boxes': boxes,
               'annotation_sha256': annotation_hash, 'rounding_clips': clipped,
               'review': 'upstream_annotation_not_independently_reviewed',
               'source': 'TobiPoni/CompoundFigureSeparation', 'phash': phash(image)}
        rows.append(row); seen[digest] = row

    parents = {x['paper']: x['paper'] for x in rows}
    def find(a):
        parents.setdefault(a, a)
        while parents[a] != a:
            parents[a] = parents[parents[a]]; a = parents[a]
        return a
    def join(a, b):
        a, b = find(a), find(b)
        parents[max(a, b)] = min(a, b)
    for row in rows:
        for paper in row.get('duplicate_papers', []): join(row['paper'], paper)
    # Conservatively group visually near-identical figures as well as exact copies.
    near = []
    for i, a in enumerate(rows):
        ar = a['width'] / a['height']
        for b in rows[:i]:
            if a['paper'] == b['paper']: continue
            if abs(ar / (b['width']/b['height']) - 1) <= .08 and (a['phash'] ^ b['phash']).bit_count() <= 4:
                join(a['paper'], b['paper']); near.append([a['id'], b['id']])
    # These six source samples were inspected before splitting, so exclude their papers from final test.
    inspected_ids = {p.stem for p in sorted((source / 'images/train').glob('*'))[:6]}
    reviewed = {x['paper'] for x in rows if x['id'] in inspected_ids}
    reviewed_groups = {find(x) for x in reviewed}
    for row in rows:
        group = find(row['paper'])
        bucket = int(hashlib.sha256(('gradstep-panels-v1:' + group).encode()).hexdigest()[:8], 16) % 100
        row['group'] = group
        row['split'] = 'train' if bucket < 75 or group in reviewed_groups else ('validation' if bucket < 88 else 'test')
        row['phash'] = f"{row['phash']:016x}"
    for split in ('train', 'validation', 'test'):
        if not any(r['split'] == split for r in rows): raise ValueError('Empty split')
    args.out.mkdir(parents=True)
    for split in ('train', 'validation', 'test'):
        selected = [x for x in rows if x['split'] == split]
        (args.out / f'{split}.jsonl').write_text(''.join(json.dumps(x, sort_keys=True)+'\n' for x in selected))
    (args.out / 'rejections.json').write_text(json.dumps(rejected, indent=2)+'\n')
    manifest = {'version': 1, 'classes': CLASSES, 'source_revision': REVISION,
                'source_url': f'https://huggingface.co/datasets/TobiPoni/CompoundFigureSeparation/tree/{REVISION}',
                'archive_sha256': sha(source.parent / 'compound-chart-splitter.zip'),
                'declared_dataset_license': 'MIT', 'article_image_rights': 'not established',
                'distribution_allowed': False, 'annotation_review': 'upstream; source sample visually inspected by Codex only',
                'split_method': 'source paper hash; exact duplicates and pHash<=4 families joined; seed gradstep-panels-v1',
                'near_duplicate_pairs': near, 'excluded_from_test_after_source_review': sorted(reviewed),
                'script_sha256': sha(__file__), 'files': {}, 'counts': {}}
    for split in ('train', 'validation', 'test'):
        selected = [x for x in rows if x['split'] == split]
        manifest['files'][f'{split}.jsonl'] = sha(args.out / f'{split}.jsonl')
        manifest['counts'][split] = {'images': len(selected), 'papers': len({x['paper'] for x in selected}),
            'families': len({x['group'] for x in selected}),
            'boxes': dict(collections.Counter(CLASSES[b['class']] for x in selected for b in x['boxes'])),
            'compound_images': sum(sum(b['class']==4 for b in x['boxes']) > 1 for x in selected)}
    (args.out / 'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(json.dumps({'counts': manifest['counts'], 'rejected': len(rejected), 'near_duplicate_pairs': len(near)}, indent=2))


if __name__ == '__main__': main()
