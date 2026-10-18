#!/usr/bin/env python3
"""Replay detector geometry without inference or network access.

Consumes subfigure-prototype.py's retained JSON. This measures image coverage, not
panel recall, label correctness or model quality. A whole-image detection cannot
count as successful extraction. A split still needs reviewed panel/context labels.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def rectangle(box, width, height, margin):
    if box.get('kind') != 'subplot':
        return None
    values = [box.get(key) for key in ('x', 'y', 'w', 'h')]
    if any(type(n) not in (int, float) or not math.isfinite(n) for n in values):
        return None
    x, y, w, h = values
    if x < 0 or y < 0 or w < .04 or h < .04 or x + w > 1.0001 or y + h > 1.0001:
        return None
    if w >= .95 and h >= .95:
        return None
    left = math.floor(max(0, x - margin) * width + 1e-9)
    top = math.floor(max(0, y - margin) * height + 1e-9)
    right = math.ceil(min(1, x + w + margin) * width - 1e-9)
    bottom = math.ceil(min(1, y + h + margin) * height - 1e-9)
    return left, top, right, bottom


def union_area(rectangles):
    xs = sorted({x for r in rectangles for x in (r[0], r[2])})
    area = 0
    for left, right in zip(xs, xs[1:]):
        intervals = sorted((r[1], r[3]) for r in rectangles if r[0] <= left and r[2] >= right)
        bottom = covered = 0
        for top, end in intervals:
            covered += max(0, end - max(top, bottom))
            bottom = max(bottom, end)
        area += (right - left) * covered
    return area


def measure(image, margin):
    width, height = image['width'], image['height']
    if not all(type(n) is int and 0 < n <= 32768 for n in (width, height)):
        raise ValueError('Invalid image dimensions')
    boxes = image['boxes']
    if len(boxes) > 100:
        raise ValueError('Unbounded detector output')
    rectangles = [r for b in boxes if (r := rectangle(b, width, height, margin))]
    total = width * height
    covered = union_area(rectangles)
    return {'id': image['id'], 'image_sha256': image['image_sha256'], 'width': width, 'height': height,
            'detected_boxes': len(boxes), 'admitted_crops': len(rectangles),
            'covered_pixels': covered, 'total_pixels': total, 'uncovered_pixels': total - covered,
            'coverage': covered / total, 'complete_geometry': len(rectangles) > 1 and covered == total,
            'semantic_split_verified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    raw = args.results.read_bytes()
    source = json.loads(raw)
    report = {'format': 'subfigure-coverage-v1', 'source_sha256': hashlib.sha256(raw).hexdigest(),
              'model': source['model'], 'weights_sha256': source['weights_sha256'],
              'warning': 'Geometry only. No panel/legend ground truth: no extraction success or accuracy claim.',
              'raw': [measure(i, 0) for i in source['images']],
              'display_margin_002': [measure(i, .02) for i in source['images']]}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps([{'id': r['id'], 'crops': r['admitted_crops'], 'coverage_percent': round(100*r['coverage'], 2),
                       'complete_geometry': r['complete_geometry']} for r in report['display_margin_002']], indent=2))


if __name__ == '__main__':
    main()
