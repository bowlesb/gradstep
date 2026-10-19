#!/usr/bin/env python3
"""Attribute fixed-validation context misses, without qualifying a crop policy.

Uses ground truth to match separate context boxes: an optimistic scoring
diagnostic, not inference or proof that the model associates a legend correctly.
Final-test input is deliberately not an option.
"""
import argparse
import collections
import json
from pathlib import Path

from scipy.optimize import linear_sum_assignment

from crop_policy import crop_metrics
from train import expanded, ious, retained, sha


def context_report(rows, records):
    by_id = {r['id']: r for r in records}
    if (len(by_id) != len(records) or len({r['id'] for r in rows}) != len(rows)
            or set(by_id) != {r['id'] for r in rows}):
        raise ValueError('Prediction set mismatch')
    counts, details, predictions = collections.Counter(), [], []
    for row in rows:
        record = by_id[row['id']]
        if (record['image_sha256'] != row['sha256']
                or (record['width'], record['height']) != (row['width'], row['height'])):
            raise ValueError('Prediction image/geometry mismatch')
        ps = record['predictions']
        predictions.append(ps)
        truth = [b for b in row['boxes'] if b['class'] == 4]
        panels = [b for b in ps if b['class'] == 4 and b['score'] >= .6]
        matches = {}
        if truth and panels:
            matrix = ious([b['box'] for b in truth], [b['box'] for b in panels])
            gi, pi = linear_sum_assignment(-((matrix >= .75).astype(float)*10+matrix))
            matches = {i: j for i, j in zip(gi, pi) if matrix[i, j] >= .75}
        contexts = {b['id']: b for b in row['boxes'] if 'id' in b}
        for i, panel in enumerate(truth):
            for key in panel.get('required_context_ids', []):
                context = contexts[key]
                coverage, best_iou = 0., None
                if i not in matches:
                    reason = 'panel_missed'
                else:
                    crop = expanded(panels[matches[i]]['box'], row['width'], row['height'])
                    coverage = retained(context['box'], crop)
                    candidates = [b for b in ps if b['class'] == context['class'] and b['score'] >= .25]
                    overlap = [float(ious([context['box']], [b['box']])[0, 0]) for b in candidates]
                    best_iou = max([0.]+overlap)
                    eligible = [b for b, score in zip(candidates, overlap) if score >= .5]
                    if coverage >= .99:
                        reason = 'retained_in_panel'
                    else:
                        coverage = max([coverage]+[retained(context['box'], expanded(
                            b['box'], row['width'], row['height'])) for b in eligible])
                        reason = ('retained_separately' if coverage >= .99 else
                                  'detected_context_clipped' if eligible else 'no_usable_context_box')
                counts[reason] += 1
                details.append({'id': row['id'], 'panel': panel.get('id', i), 'context': key,
                                'class': context['class'], 'reason': reason, 'area_retained': coverage,
                                'best_eligible_context_iou': best_iou})
    # Reconcile with the independent existing crop scorer rather than silently
    # replacing its denominator or dropping links belonging to missed panels.
    scored = crop_metrics(rows, predictions, .6)
    if (counts['panel_missed'] != len(details)-scored['required_context_links']
            or counts['detected_context_clipped']+counts['no_usable_context_box']
            != scored['context_links_missing_or_clipped']
            or counts['retained_in_panel']+counts['retained_separately']
            != scored['required_context_links']-scored['context_links_missing_or_clipped']):
        raise ValueError('Context diagnostic disagrees with crop scorer')
    unique = collections.defaultdict(list)
    for detail in details:
        unique[(detail['id'], detail['context'])].append(detail)
    return {
        'split': 'validation', 'panel_threshold': .6, 'context_threshold': .25,
        'panel_iou': .75, 'context_iou': .5, 'area_required': .99,
        'counts': dict(counts), 'required_links': len(details),
        'unique_context_regions': len(unique),
        'unique_context_regions_retained_for_every_panel': sum(
            all(d['reason'].startswith('retained') for d in group) for group in unique.values()),
        'figures_with_missing_context': len({d['id'] for d in details if not d['reason'].startswith('retained')}),
        'by_context_class': {str(c): dict(collections.Counter(d['reason'] for d in details if d['class'] == c))
                             for c in range(4)},
        'details': details,
        'limit': 'Ground-truth scoring diagnostic, not inference or semantic association proof. Existing 2% crop margin.',
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--data', type=Path, required=True)
    p.add_argument('--predictions', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    if args.out.exists():
        raise ValueError('Preserve earlier evidence; choose a new output')
    manifest = json.loads((args.data/'manifest.json').read_text())
    validation = args.data/'validation.jsonl'
    if sha(validation) != manifest['files']['validation.jsonl']:
        raise ValueError('Changed validation set')
    rows = [json.loads(s) for s in validation.read_text().splitlines()]
    result = context_report(rows, json.loads(args.predictions.read_text()))
    result.update(script_sha256=sha(__file__), validation_sha256=sha(validation),
                  predictions_sha256=sha(args.predictions))
    args.out.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('details', 'by_context_class')}))


if __name__ == '__main__':
    main()
