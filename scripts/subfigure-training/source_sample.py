#!/usr/bin/env python3
"""Bounded read-only source-asset sample. No PDF processing or archive execution.

Run this from the isolated training workspace, reading only the permitted source
root. Stdout is a copy manifest; this script never writes beneath that root.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re

from source_html import Figures


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def safe(root, path):
    return path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--per-category', type=int, default=6)
    p.add_argument('--max-mib', type=int, default=240)
    p.add_argument('--max-html-per-category', type=int, default=400)
    args = p.parse_args()
    root = args.root.resolve()
    if str(root) != '/home/ben/mathpix':
        raise ValueError('Only the owner-authorized source root is allowed')
    raw = (root/'data/arxiv/papers.jsonl').read_bytes()
    rows = [json.loads(s) for s in raw.splitlines()]
    categories = ('Machine Learning', 'Computer Vision and Pattern Recognition',
                  'Artificial Intelligence', 'Computation and Language')
    allowed = {'http://creativecommons.org/licenses/by/4.0/',
               'http://creativecommons.org/publicdomain/zero/1.0/'}
    excluded = {'2610.22350', '2610.14704', '2610.15542', '2610.19844'}
    seed = 'gradstep-subfigure-mathpix-v1:'
    selected, skipped, total = [], collections.Counter(), 0
    for category in categories:
        ordered = sorted((r for r in rows if r['category'] == category),
                         key=lambda r: hashlib.sha256(('source-assets-v1:' + r['family']).encode()).hexdigest())
        count, inspected = 0, 0
        for r in ordered:
            if count >= args.per_category or inspected >= args.max_html_per_category:
                break
            if (r['family'] in excluded or not re.fullmatch(r'\d{4}\.\d{4,5}v\d+', r['id'])
                    or r['id'][:4] < '2501' or r['license'] not in allowed or not r['trainable']):
                continue
            bucket = int(hashlib.sha256((seed + r['family']).encode()).hexdigest()[:8], 16) % 100
            if bucket >= 75:
                continue  # Do not even read validation or reserved-test HTML.
            directory = root/'data/arxiv'/r['id']
            paths = [directory/f for f in ('arxiv.html', 'abstract.html', 'source.archive',
                                          'build/plain.pdf', 'build/layout-check.json')]
            if any(not safe(root, f) for f in paths):
                skipped['incomplete_or_external'] += 1
                continue
            sizes = [f.stat().st_size for f in paths]
            if sizes[0] > 8*1024**2 or sizes[2] > 16*1024**2 or sizes[3] > 12*1024**2:
                skipped['file_size_bound'] += 1
                continue
            inspected += 1
            parser = Figures(r['id'])
            parser.feed(paths[0].read_text())
            groups = list(parser.groups())
            raster_groups = [g for g in groups if all(
                Path(c['images'][0]['path']).suffix.lower() in ('.png', '.jpg', '.jpeg')
                for c in g['children'])]
            if not raster_groups:
                skipped['no_explicit_raster_group'] += 1
                continue
            if not json.loads(paths[-1].read_text()).get('identical'):
                skipped['layout_check'] += 1
                continue
            if total + sum(sizes) > args.max_mib*1024**2:
                skipped['sample_budget'] += 1
                continue
            records = []
            for path in paths:
                before = path.stat()
                digest = sha(path)
                after = path.stat()
                if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                    records = []
                    break
                records.append({'path': str(path.relative_to(root)), 'bytes': after.st_size,
                                'sha256': digest, 'mtime_ns': after.st_mtime_ns})
            if not records or records[0]['sha256'] != r['html_sha256'] or records[2]['sha256'] != r['source_sha256']:
                skipped['changed_or_catalog_mismatch'] += 1
                continue
            selected.append({**r, 'split': 'train', 'files': records,
                             'candidate_groups': [g['id'] for g in raster_groups]})
            total += sum(sizes)
            count += 1
        skipped[category + ':html_inspected'] = inspected
    print(json.dumps({'version': 1, 'source_root': str(root), 'source_read_only': True,
                      'catalog_sha256': hashlib.sha256(raw).hexdigest(), 'bytes': total,
                      'split_seed': seed, 'training_only': True,
                      'selection': '2025+ rights-declared papers with explicit HTML raster subfigure groups; not representative sampling',
                      'script_sha256': sha(Path(__file__)), 'parser_sha256': sha(Path(__file__).with_name('source_html.py')),
                      'papers': selected, 'skipped': dict(skipped)}, indent=2))


if __name__ == '__main__':
    main()
