#!/usr/bin/env python3
"""Validation-only test of a learned single/compound decision before panel crops.

Predicted single figures retain the original overview. A rejected true compound
figure counts as missed panels, including when one panel fills most of the image.
This never changes the raw detector metrics or qualifies a model for release.
"""
import argparse
import json
from pathlib import Path

from train import metrics,sha
from crop_policy import crop_metrics,deduplicate,detection_gate


def apply_policy(predictions,probability,width,height,gate_threshold,panel_threshold,nms=.4):
    if probability<gate_threshold:
        return [{'class':4,'score':1.,'box':[0.,0.,float(width),float(height)],
                 'whole_figure_fallback':True,'reason':'classifier_predicts_single_figure'}]
    eligible=[p for p in predictions if p['score']>=(panel_threshold if p['class']==4 else .25)]
    return deduplicate(eligible,nms)


def score_policy(rows,predictions,threshold):
    # This is solely scoring: apply_policy has no access to reference annotations.
    # An overview of a real compound is an abstention, never a successful subfigure.
    scored=[[p for p in ps if not (p.get('whole_figure_fallback') and sum(b['class']==4 for b in r['boxes'])>1)]
            for r,ps in zip(rows,predictions)]
    all_m=metrics(rows,scored,threshold);compound=metrics(rows,scored,threshold,compounds_only=True)
    return {'all_figures':all_m,'compound_figures':compound,'crops':crop_metrics(rows,scored,threshold),
            'figures_retained_whole':sum(any(p.get('whole_figure_fallback') for p in ps) for ps in predictions),
            'compound_figures_missed_by_gate':sum(sum(b['class']==4 for b in r['boxes'])>1 and
                any(p.get('whole_figure_fallback') for p in ps) for r,ps in zip(rows,predictions)),
            'detection_gate':detection_gate(all_m,compound)}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for field in ('data','predictions','classifier','out'):p.add_argument('--'+field,type=Path,required=True)
    args=p.parse_args()
    rows=[json.loads(s) for s in (args.data/'validation.jsonl').read_text().splitlines()]
    saved=json.loads(args.predictions.read_text());scores=json.loads((args.classifier/'probabilities.json').read_text())
    prediction={r['id']:r for r in saved};score={r['id']:r for r in scores}
    if len(saved)!=len(prediction) or len(scores)!=len(score):raise ValueError('Duplicate image identity')
    for source in (prediction,score):
        if set(source)!={r['id'] for r in rows}:raise ValueError('Validation image set mismatch')
        for r in rows:
            record=source[r['id']]
            if record['image_sha256']!=r['sha256'] or (record['width'],record['height'])!=(r['width'],r['height']):
                raise ValueError('Prediction image identity/geometry mismatch')
    provenance=json.loads((args.classifier/'provenance.json').read_text())
    if provenance['detector_sha256']!=sha(args.predictions.parent/'best.pth'):
        raise ValueError('Classifier and detector must use the same frozen weights')
    reports=[]
    for gate in (.01,.02,.05,.1,.2,.4,.5,.6,.8,.9):
        for threshold in (.4,.5,.6,.65,.7,.75,.8):
            output=[apply_policy(prediction[r['id']]['predictions'],score[r['id']]['compound_probability'],
                r['width'],r['height'],gate,threshold) for r in rows]
            reports.append({'classifier_threshold':gate,'panel_threshold':threshold,
                            'nms_threshold':.4,**score_policy(rows,output,threshold)})
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps({'split':'validation','reports':reports,'deployment_qualified':False,
        'raw_detector_unchanged':True,'provenance':{'script_sha256':sha(__file__),
            'manifest_sha256':sha(args.data/'manifest.json'),'predictions_sha256':sha(args.predictions),
            'classifier_sha256':sha(args.classifier/'best.pth'),
            'probabilities_sha256':sha(args.classifier/'probabilities.json')}},indent=2)+'\n')
    best=max(reports,key=lambda r:min(r['all_figures']['f1'],r['compound_figures']['f1']))
    print(json.dumps({k:best[k] for k in ('classifier_threshold','panel_threshold','detection_gate',
        'figures_retained_whole','compound_figures_missed_by_gate')}))
    for population in ('all_figures','compound_figures'):
        print(population,json.dumps({k:best[population][k] for k in ('tp','fp','fn','recall','precision')}))


if __name__=='__main__':main()
