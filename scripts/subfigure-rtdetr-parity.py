#!/usr/bin/env python3
"""Replay numerical parity from subfigure-rtdetr-export.py; no model or network calls.

DETR query order can change at nearly tied encoder top-k scores. Retain raw errors and
compare a one-to-one assignment of all predictions as well. This is numerical export
acceptance only, never an accuracy score for subfigures or COCO.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from scipy.optimize import linear_sum_assignment


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('report', type=Path)
args = parser.parse_args()
source = json.loads(args.report.read_text())
result = {
    'report_sha256': digest(args.report), 'script_sha256': digest(Path(__file__)),
    'purpose': 'Numerical Core ML export parity; no subfigure-quality claim',
    'assignment_cost': 'L1 normalized cxcywh distance plus maximum class-probability difference',
    'thresholds': {'coordinate': 1 / 640, 'class_probability': 0.001},
    'images': [],
}
for image in source['images']:
    identifier = image['id']
    if Path(identifier).name != identifier:
        raise ValueError('Invalid image identifier')
    path = args.report.parent / f'{identifier}.npz'
    with np.load(path, allow_pickle=False) as data:
        tb, cb = data['torch_boxes'][0], data['coreml_boxes'][0]
        tl, cl = data['torch_logits'][0], data['coreml_logits'][0]
        if tb.shape != (300, 4) or cb.shape != tb.shape or tl.shape != (300, 80) or cl.shape != tl.shape:
            raise ValueError('Unexpected raw prediction shape')
        if not all(np.isfinite(x).all() for x in [tb, cb, tl, cl]):
            raise ValueError('Non-finite predictions')
        tp, cp = [1 / (1 + np.exp(-np.clip(x, -80, 80))) for x in [tl, cl]]
        cost = np.abs(tb[:, None] - cb[None, :]).sum(2) + np.abs(tp[:, None] - cp[None, :]).max(2)
        rows, cols = linear_sum_assignment(cost)
        box_error = float(np.abs(tb[rows] - cb[cols]).max())
        probability_error = float(np.abs(tp[rows] - cp[cols]).max())
        credible = (tp[rows].max(1) >= .25) | (cp[cols].max(1) >= .25)
        row = {
            'id': identifier, 'predictions_sha256': digest(path),
            'raw_max_box_error': float(np.abs(tb - cb).max()),
            'matched_max_box_error': box_error, 'matched_max_probability_error': probability_error,
            'reordered_queries': int(np.count_nonzero(rows != cols)),
            'torch_above_025': int(np.count_nonzero(tp.max(1) >= .25)),
            'coreml_above_025': int(np.count_nonzero(cp.max(1) >= .25)),
            'credible_matched_max_box_error': float(np.abs(tb[rows][credible] - cb[cols][credible]).max()) if credible.any() else None,
            'passes_numerical_gate': box_error <= 1 / 640 and probability_error <= .001,
        }
        result['images'].append(row)
result['all_pass'] = bool(result['images']) and all(x['passes_numerical_gate'] for x in result['images'])
output = args.report.parent / 'parity.json'
output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'precision': source['precision'], 'images': len(result['images']), 'all_pass': result['all_pass'],
                  'matched_max_box_error': max(x['matched_max_box_error'] for x in result['images']),
                  'matched_max_probability_error': max(x['matched_max_probability_error'] for x in result['images'])}))
