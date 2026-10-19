#!/usr/bin/env python3
"""Compare saved validation predictions by domain; never inspect the final test.

Fixed operating points prevent hiding new-domain or single-figure failures behind
one aggregate AP. Required context on missed panels is reported separately from
context missing on matched panels. No model deployment is qualified here.
"""
import argparse
import json
from pathlib import Path

from crop_policy import crop_metrics, detection_gate
from train import metrics, sha


def compact(rows, predictions, threshold):
    report = {}
    for name, compound in (('all_figures', False), ('compound_figures', True)):
        m = metrics(rows, predictions, threshold, compounds_only=compound)
        report[name] = {k: m[k] for k in ('images', 'tp', 'fp', 'fn', 'recall', 'precision',
                                        'false_crop_fraction', 'f1')}
    crop = crop_metrics(rows, predictions, threshold)
    total_links = sum(len(b.get('required_context_ids', [])) for r in rows for b in r['boxes'])
    report['context'] = {
        'annotated_links': total_links,
        'links_on_matched_panels': crop['required_context_links'],
        'links_on_missed_panels': total_links-crop['required_context_links'],
        'links_missing_or_clipped_on_matched_panels': crop['context_links_missing_or_clipped'],
        'mean_context_area_retained_on_matched_panels': crop['context_area_retention_mean'],
        'matched_panels': crop['matched_panels'],
        'matched_panels_with_99pct_area_retention': crop['matched_panels_with_99pct_area_retention'],
        'single_figures': crop['single_figures'],
        'single_figures_falsely_split': crop['single_figures_falsely_split'],
    }
    report['detection_gate'] = detection_gate(report['all_figures'], report['compound_figures'])
    return report


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--data', type=Path, required=True)
    p.add_argument('--predictions', type=Path, action='append', required=True)
    p.add_argument('--thresholds', default='.5,.6,.7')
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    if args.out.exists():
        raise ValueError('Preserve existing comparison; choose a new output')
    thresholds = [float(t) for t in args.thresholds.split(',')]
    if not thresholds or any(not 0 <= t <= 1 for t in thresholds):
        raise ValueError('Invalid fixed operating point')
    manifest = json.loads((args.data/'manifest.json').read_text())
    if sha(args.data/'validation.jsonl') != manifest['files']['validation.jsonl']:
        raise ValueError('Changed validation set')
    rows = [json.loads(s) for s in (args.data/'validation.jsonl').read_text().splitlines()]
    if len({r['id'] for r in rows}) != len(rows):
        raise ValueError('Duplicate validation identity')
    cohorts = {'original_validation': [r for r in rows if not r['id'].startswith('arxiv-')],
               'new_arxiv_validation': [r for r in rows if r['id'].startswith('arxiv-')],
               'combined_validation': rows}
    result = {'script_sha256': sha(__file__), 'manifest_sha256': sha(args.data/'manifest.json'),
              'split': 'validation', 'thresholds': thresholds, 'deployment_qualified': False,
              'limitation': 'Development annotations, not independent final-test or critical-text qualification.',
              'runs': {}}
    for path in args.predictions:
        raw = json.loads(path.read_text())
        records = {r['id']: r for r in raw}
        if len(records) != len(raw) or set(records) != {r['id'] for r in rows}:
            raise ValueError('Prediction set mismatch')
        for row in rows:
            item = records[row['id']]
            if item['image_sha256'] != row['sha256'] or (item['width'], item['height']) != (row['width'], row['height']):
                raise ValueError('Prediction image/geometry mismatch')
        name = path.parent.name
        if name in result['runs']:
            raise ValueError('Ambiguous run name')
        run = {'predictions_sha256': sha(path), 'cohorts': {}}
        for cohort, selected in cohorts.items():
            if not selected:
                continue
            predictions = [records[r['id']]['predictions'] for r in selected]
            run['cohorts'][cohort] = {str(t): compact(selected, predictions, t) for t in thresholds}
        result['runs'][name] = run
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2)+'\n')
    for name, run in result['runs'].items():
        for cohort, points in run['cohorts'].items():
            point = points.get('0.6', next(iter(points.values())))
            print(name, cohort, json.dumps(point))


if __name__ == '__main__':
    main()
