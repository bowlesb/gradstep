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

CATEGORIES = ('Machine Learning', 'Computer Vision and Pattern Recognition',
              'Artificial Intelligence', 'Computation and Language')
TOPICS = {
    'heatmap': re.compile(r'heat[ -]?maps?|confusion matri|correlation matri|similarity matri|attention maps?', re.I),
    'context': re.compile(r'shared legends?|colou?r[ -]?bars?|legend|shared axes|shared axis', re.I),
    'diagram': re.compile(r'architecture|framework|pipeline|workflow|overview', re.I),
}


def candidate_ids(parser, targeted=False, topics=None):
    """Caption-guided review queue, never semantic labels or model predictions."""
    def raster(node):
        return (len(node['images']) == 1 and node['images'][0]['path']
                and Path(node['images'][0]['path']).suffix.lower() in ('.png', '.jpg', '.jpeg'))
    groups = [g for g in parser.groups() if all(raster(c) for c in g['children'])]
    if not targeted:
        return [g['id'] for g in groups], None
    def matches(caption):
        return any(TOPICS[t].search(caption) for t in (topics or TOPICS))
    groups = [g for g in groups if matches(g['caption'])
              or any(matches(c['caption']) for c in g['children'])]
    singles = [g for g in parser.roots if g['id'] and not g['children'] and raster(g)
               and matches(g['caption'])]
    return [g['id'] for g in groups[:4]], [g['id'] for g in singles[:4]]


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
    p.add_argument('--category', action='append', choices=CATEGORIES,
                   help='Ordered categories to sample; repeat to include more')
    p.add_argument('--targeted', action='store_true', help='Caption-guided heatmap/context/diagram review queue')
    p.add_argument('--topic', action='append', choices=TOPICS, help='Narrow targeted review; repeat to include more')
    p.add_argument('--exclude-sample', action='append', type=Path, default=[],
                   help='Previous immutable copy manifests; exclude their paper families')
    args = p.parse_args()
    if args.topic and not args.targeted:
        p.error('--topic requires --targeted')
    root = args.root.resolve()
    if str(root) != '/home/ben/mathpix':
        raise ValueError('Only the owner-authorized source root is allowed')
    raw = (root/'data/arxiv/papers.jsonl').read_bytes()
    rows = [json.loads(s) for s in raw.splitlines()]
    categories = tuple(dict.fromkeys(args.category or CATEGORIES))
    allowed = {'http://creativecommons.org/licenses/by/4.0/',
               'http://creativecommons.org/publicdomain/zero/1.0/'}
    excluded = {'2610.22350', '2610.14704', '2610.15542', '2610.19844'}
    previous = []
    for path in args.exclude_sample:
        data = path.read_bytes()
        excluded.update(r['family'] for r in json.loads(data)['papers'])
        previous.append({'sha256': hashlib.sha256(data).hexdigest(), 'name': path.name})
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
            group_ids, single_ids = candidate_ids(parser, args.targeted, args.topic)
            if not group_ids and not single_ids:
                skipped['no_targeted_raster_candidate' if args.targeted else 'no_explicit_raster_group'] += 1
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
                             'candidate_groups': group_ids,
                             **({'candidate_singles': single_ids} if single_ids is not None else {})})
            total += sum(sizes)
            count += 1
        skipped[category + ':html_inspected'] = inspected
    print(json.dumps({'version': 1, 'source_root': str(root), 'source_read_only': True,
                      'catalog_sha256': hashlib.sha256(raw).hexdigest(), 'bytes': total,
                      'split_seed': seed, 'training_only': True,
                      'selection': ('2025+ rights-declared papers with caption-guided raster heatmaps/context/diagrams'
                                    if args.targeted else '2025+ rights-declared papers with explicit HTML raster subfigure groups') + '; not representative sampling',
                      'categories': categories, 'excluded_sample_manifests': previous,
                      'target_topics': args.topic or (list(TOPICS) if args.targeted else []),
                      'script_sha256': sha(Path(__file__)), 'parser_sha256': sha(Path(__file__).with_name('source_html.py')),
                      'papers': selected, 'skipped': dict(skipped)}, indent=2))


if __name__ == '__main__':
    main()
