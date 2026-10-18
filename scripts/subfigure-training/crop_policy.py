#!/usr/bin/env python3
"""Validation-only policy comparison: duplicate suppression and Mac OCR containment.

The policy consumes image-bound predictions and OCR, never reference annotations.
Ground truth is used only by the scorer. Shared/context boxes remain distinct from
panels; whole-figure presentation is still required outside this experiment.
"""
import argparse
import copy
import json
from pathlib import Path
import math
import re

import numpy as np
from train import ious, metrics, expanded, retained, sha


def deduplicate(predictions, threshold=.9):
    kept=[]
    for p in sorted(predictions,key=lambda x:x['score'],reverse=True):
        if any(k['class']==p['class'] and ious([k['box']],[p['box']])[0,0]>=threshold for k in kept):continue
        kept.append(copy.deepcopy(p))
    return kept


def edge_distance(a,b,width,height):
    dx=max(0.,a[0]-b[2],b[0]-a[2])/width;dy=max(0.,a[1]-b[3],b[1]-a[3])/height
    return math.hypot(dx,dy)


def complete_text(predictions,ocr,width,height,panel_threshold,bounded_margin=False):
    result=copy.deepcopy(predictions)
    panels=[p for p in result if p['class']==4 and p['score']>=panel_threshold]
    for p in result:p['crop']=expanded(p['box'],width,height)
    if bounded_margin:
        for p in result:
            x,y,xx,yy=p['box'];dx=min(width*.02,(xx-x)*.04);dy=min(height*.02,(yy-y)*.04)
            p['crop']=[max(0,math.floor(x-dx)),max(0,math.floor(y-dy)),min(width,math.ceil(xx+dx)),min(height,math.ceil(yy+dy))]
    for text in ocr:
        if text['confidence']<.3 or not panels:continue
        box=text['box'];distances=[edge_distance(p['box'],box,width,height) for p in panels]
        minimum=min(distances)
        # Parenthesized panel letters can precede a narrow photograph by a wide white
        # margin. Ordinary prose keeps the shorter neighborhood to avoid attaching captions.
        panel_tag=text['confidence']>=.8 and re.fullmatch(r'\([a-zA-Z]\)',text['text'].strip()) is not None
        if minimum>(.2 if panel_tag else .08):continue
        owners=[i for i,d in enumerate(distances) if d<=minimum+.004]
        # A line shared by multiple panels is separate common context, not a giant panel box.
        for i in owners:
            p=panels[i]
            if len(owners)>1:
                p.setdefault('shared_text_boxes',[]).append(box);continue
            crop=p['crop'];p['crop']=[max(0,min(crop[0],math.floor(box[0])-2)),max(0,min(crop[1],math.floor(box[1])-2)),
                                     min(width,max(crop[2],math.ceil(box[2])+2)),min(height,max(crop[3],math.ceil(box[3])+2))]
    return result


def crop_metrics(rows,predictions,threshold):
    from scipy.optimize import linear_sum_assignment
    retentions=[];context_retentions=[];lost=[];missing_context=0;requested_context=0
    false_split_singles=0;singles=0
    for row,ps in zip(rows,predictions):
        truths=[b for b in row['boxes'] if b['class']==4];selected=[p for p in ps if p['class']==4 and p['score']>=threshold]
        if len(truths)==1:
            singles+=1;false_split_singles+=int(len(selected)>1)
        if not truths or not selected:continue
        matrix=ious([g['box'] for g in truths],[p['box'] for p in selected])
        gi,pi=linear_sum_assignment(-((matrix>=.75).astype(float)*10+matrix))
        byid={b.get('id'):b for b in row['boxes']}
        for a,b in zip(gi,pi):
            if matrix[a,b]<.75:continue
            g,p=truths[a],selected[b];crop=p.get('crop',expanded(p['box'],row['width'],row['height']))
            value=retained(g['box'],crop);retentions.append(value)
            if value<.99:lost.append({'id':row['id'],'panel':g.get('id',a),'retained':value,'truth':g['box'],'crop':crop})
            # Only explicit source relations are scored. Do not infer ground-truth relations from proximity.
            for context_id in g.get('required_context_ids',[]):
                if context_id not in byid:raise ValueError('Broken source context relation')
                context=byid[context_id];requested_context+=1
                # Context detections are available to every panel as separate crops. OCR shared lines may
                # cover text but do not substitute for an entire color bar or legend annotation here.
                candidates=[q for q in ps if q['class']==context['class'] and q['score']>=.25]
                good=[q for q in candidates if ious([context['box']],[q['box']])[0,0]>=.5]
                coverage=max([retained(context['box'],crop)]+[
                    retained(context['box'],q.get('crop',expanded(q['box'],row['width'],row['height']))) for q in good])
                # A separately retained common text rectangle can preserve an entire title/axis label.
                # It cannot stand in for a legend's colored markers or a heatmap's color bar.
                if context['class'] in (1,2,3):
                    coverage=max([coverage]+[retained(context['box'],box) for box in p.get('shared_text_boxes',[])])
                context_retentions.append(coverage)
                if coverage<.99:missing_context+=1
    return {'matched_panels':len(retentions),'annotated_panel_area_retention_mean':float(np.mean(retentions)) if retentions else None,
            'matched_panels_with_99pct_area_retention':sum(r>=.99 for r in retentions),
            'required_context_links':requested_context,'context_links_missing_or_clipped':missing_context,
            'context_area_retention_mean':float(np.mean(context_retentions)) if context_retentions else None,
            'single_figures':singles,'single_figures_falsely_split':false_split_singles,'undercontained_panels':lost,
            'limitation':'Source panel/context box retention; independent critical-text ground truth still required.'}


def confidence_interval(counts,seed=19):
    a=np.asarray(list(counts.values()),dtype=float)
    if not len(a):return None
    rng=np.random.default_rng(seed);values=[]
    for _ in range(2000):
        tp,fp,fn=a[rng.integers(0,len(a),len(a))].sum(0)
        values.append((tp/max(1,tp+fn),tp/max(1,tp+fp)))
    lower,upper=np.quantile(values,[.025,.975],axis=0)
    return {'unit':'paper/author/duplicate family bootstrap','families':len(a),
            'recall_95pct':[float(lower[0]),float(upper[0])],'precision_95pct':[float(lower[1]),float(upper[1])],
            'note':'A zero-error bootstrap interval does not establish zero population error.'}


def detection_gate(all_figures,compound_figures):
    """A detector must both find compound panels and leave single figures intact."""
    return all(m['recall']>=.95 and m['false_crop_fraction']<.02 for m in (all_figures,compound_figures))


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--data',type=Path,required=True)
    p.add_argument('--predictions',type=Path,required=True);p.add_argument('--ocr',type=Path)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--split',choices=('validation','test'),default='validation')
    p.add_argument('--threshold',type=float);p.add_argument('--policy',choices=('raw','deduplicate','ocr','ocr_bounded'))
    p.add_argument('--nms-threshold',type=float,default=.9,help='Declared overlap-filter ablation; small distinct insets remain')
    args=p.parse_args()
    if args.split=='test' and (args.threshold is None or args.policy is None):raise ValueError('Final test needs a frozen threshold/policy')
    rows=[json.loads(x) for x in (args.data/f'{args.split}.jsonl').read_text().splitlines()]
    saved=json.loads(args.predictions.read_text());bound={x['id']:x for x in saved}
    raw={x['id']:x['predictions'] for x in saved}
    if set(raw)!={r['id'] for r in rows}:raise ValueError('Prediction/image set mismatch')
    if len(saved)!=len(raw):raise ValueError('Duplicate prediction identity')
    if any('image_sha256' not in p for p in saved):
        provenance=json.loads((args.predictions.parent/'provenance.json').read_text())
        if provenance['data_manifest_sha256']!=sha(args.data/'manifest.json'):raise ValueError('Legacy prediction provenance mismatch')
    else:
        for r in rows:
            b=bound[r['id']]
            if b['image_sha256']!=r['sha256'] or (b['width'],b['height'])!=(r['width'],r['height']):
                raise ValueError('Prediction image identity or geometry mismatch')
    ocr={x['id']:x for x in (json.loads(line) for line in args.ocr.read_text().splitlines())} if args.ocr else {}
    if args.ocr:
        if set(ocr)!={r['id'] for r in rows}:raise ValueError('Incomplete OCR; do not silently omit difficult images')
        for r in rows:
            if ocr[r['id']]['imageSHA256']!=r['sha256']:raise ValueError('OCR image identity mismatch')
            if (ocr[r['id']]['width'],ocr[r['id']]['height'])!=(r['width'],r['height']):raise ValueError('OCR dimension mismatch')
    policies=[args.policy] if args.policy else (['raw','deduplicate','ocr','ocr_bounded'] if ocr else ['raw','deduplicate'])
    thresholds=[args.threshold] if args.threshold is not None else [.2,.3,.4,.5,.6,.65,.7,.75,.8,.85,.9]
    reports=[]
    for policy in policies:
        for threshold in thresholds:
            predictions=[]
            for row in rows:
                # Lower-scoring candidates cannot suppress higher-scoring ones. Excluding them
                # before the overlap filter preserves these point-threshold metrics exactly.
                eligible=[p for p in raw[row['id']] if p['score']>=(threshold if p['class']==4 else .25)]
                ps=eligible if policy=='raw' else deduplicate(eligible,args.nms_threshold)
                if policy.startswith('ocr'):ps=complete_text(ps,ocr[row['id']]['text'],row['width'],row['height'],threshold,
                                                            bounded_margin=policy=='ocr_bounded')
                predictions.append(ps)
            m=metrics(rows,predictions,threshold,compounds_only=True)
            all_m=metrics(rows,predictions,threshold)
            c=crop_metrics(rows,predictions,threshold)
            # Also score the actual delivered rectangles at the same IoU .75. Keep raw
            # detector measurements separately; repairing a crop is not a changed detector.
            delivered=[[{**p,'box':p.get('crop',expanded(p['box'],r['width'],r['height'])),
                         'crop':p.get('crop',expanded(p['box'],r['width'],r['height']))} for p in ps]
                       for r,ps in zip(rows,predictions)]
            out_m=metrics(rows,delivered,threshold,compounds_only=True)
            out_all_m=metrics(rows,delivered,threshold)
            out_c=crop_metrics(rows,delivered,threshold)
            report={'policy':policy,'threshold':threshold,'nms_threshold':args.nms_threshold,
                    'panel_population':'compound figures only; all_figures includes single-panel negatives',
                    'panel':m,'all_figures':all_m,'crops':c,'output_all_figures':out_all_m,
                    'output_panel':{k:v for k,v in out_m.items() if not k.startswith('annotated_') and k not in
                                    ('matched_boxes_at_least_99pct_retained','retention_denominator')},'output_crops':out_c,
                    'domains':{domain:metrics([r for r in rows if r.get('domain')==domain],
                        [ps for r,ps in zip(rows,predictions) if r.get('domain')==domain],threshold,compounds_only=True)
                        for domain in sorted({r.get('domain','unknown') for r in rows})}}
            report['detection_gate']=detection_gate(all_m,m)
            report['output_detection_gate']=detection_gate(out_all_m,out_m)
            report['area_gate']=(c['annotated_panel_area_retention_mean'] or 0)>=.99 and c['context_links_missing_or_clipped']==0
            report['family_interval']=confidence_interval(m['paper_group_counts'])
            reports.append(report)
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps({'split':args.split,'reports':reports,'deployment_qualified':False,
        'provenance':{'script_sha256':sha(__file__),'metrics_script_sha256':sha(Path(__file__).with_name('train.py')),
                      'manifest_sha256':sha(args.data/'manifest.json'),'predictions_sha256':sha(args.predictions),
                      'ocr_sha256':sha(args.ocr) if args.ocr else None}},indent=2)+'\n')
    for r in reports:
        print(json.dumps({'policy':r['policy'],'threshold':r['threshold'],'recall':r['panel']['recall'],
            'precision':r['panel']['precision'],'area_retention':r['crops']['annotated_panel_area_retention_mean'],
            'all_figure_recall':r['all_figures']['recall'],'all_figure_precision':r['all_figures']['precision'],
            'context_links_lost':r['crops']['context_links_missing_or_clipped'],
            'false_single_splits':r['crops']['single_figures_falsely_split']}))


if __name__=='__main__':main()
